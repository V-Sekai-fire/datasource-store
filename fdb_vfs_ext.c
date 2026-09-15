// SQLite loadable-extension entry point for the FoundationDB VFS.
// Lets sqlite-jdbc pick the VFS up through SELECT load_extension(...)
// so `jdbc:sqlite:file:...?vfs=fdb_vfs` opens the FDB-backed store
// without a JNI shim; the YCSB round in
// entities-vsk-database-roundtable calls it that way.

#include <sqlite3ext.h>
#include <stdlib.h>
#include <string.h>
SQLITE_EXTENSION_INIT1

int weft_fdb_start(const char *cluster_file);
int weft_vfs_register(int make_default);

// Roundtable Rung 3: set a big page cache on any connection that opened against the
// weft_fdb VFS. `fdb_vfs.c` already requires `locking_mode=EXCLUSIVE`, so SQLite's own
// cache is trusted across statements — the cache hit skips the whole VFS, and one main-
// memory read at ~100 ns replaces a same-DC round trip that costs 500 µs plus the FDB
// storage server's ~90 µs work. 256 MiB holds the Zipfian hot set for a workload F run
// with recordcount up to a few million rows.
//
// Legality — and why the ladder does not try to lift the single-writer contract.
//
// The correctness argument for caching at all is made by SQLite's own architecture:
// "An EXCLUSIVE lock is needed in order to write to the database file. Only one
// EXCLUSIVE lock is allowed on the file and no other locks of any kind are allowed to
// coexist with an EXCLUSIVE lock." (sqlite.org/lockingv3.html). SQLite is single-writer
// per file, by architecture, not by choice. Every distributed-SQLite system reaches the
// same conclusion and picks its own serialiser:
//   * LiteFS (Fly.io):   "SQLite operates as a single-writer database which means only
//                         one transaction can write at a time." Consul lease as primary.
//   * rqlite / dqlite:   Raft leader.
//   * Turso / libSQL:    virtual-WAL coordinator.
//   * weft:              FDB fence + raise_fence() in `fdb_vfs.c:open_body`. Same shape.
// `spec/ParallelCommit.lean` is the *Cockroach* parallel-commits protocol — parallel
// writes across DIFFERENT databases, not concurrent writers to ONE database. Each
// participant is still single-writer.
//
// So the page cache is legal under the same contract that makes EXCLUSIVE legal. This
// enlarges an already-trusted cache from SQLite's 2 MiB default to 256 MiB and adds no
// new hazard. Weft.Actor tears down the old actor process on handoff, so no stale reader
// serves cached bytes past the fence bump.
//
// `cache_spill` is deliberately not touched. Setting it to 0 would force every dirty
// page to sit in SQLite's cache until commit; under weft_fdb `xWrite` already keeps
// dirty pages in the same process's DirtyPage buffer, so cache_spill=0 gains nothing
// and turns a large transaction into SQLITE_FULL when the working set exceeds the cache.
//
// The pragma is gated on the VFS name so that a plain :memory: or unix VFS opened in
// the same JVM does not inherit the big cache.
static int weft_apply_defaults(
		sqlite3 *db, const char **pzErr, const struct sqlite3_api_routines *pApi) {
	(void)pzErr;
	SQLITE_EXTENSION_INIT2(pApi);
	sqlite3_vfs *vfs = NULL;
	if (sqlite3_file_control(db, "main", SQLITE_FCNTL_VFSNAME, &vfs) != SQLITE_OK || !vfs) {
		return SQLITE_OK;
	}
	// SQLITE_FCNTL_VFSNAME writes a mallocated string, not a sqlite3_vfs *. Cast back.
	const char *name = (const char *)vfs;
	if (name && strcmp(name, "weft_fdb") == 0) {
		sqlite3_exec(db,
			"PRAGMA cache_size = -262144;",    // 256 MiB, negative = KiB
			NULL, NULL, NULL);
	}
	sqlite3_free((void *)name);
	return SQLITE_OK;
}

int sqlite3_weftfdbvfs_init(
		sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi) {
	(void)db;
	SQLITE_EXTENSION_INIT2(pApi);
	int rc = weft_fdb_start(getenv("WEFT_FDB_CLUSTER_FILE"));
	if (rc) {
		*pzErrMsg = sqlite3_mprintf("weft_fdb_start failed: %d", rc);
		return SQLITE_ERROR;
	}
	if (weft_vfs_register(0)) return SQLITE_ERROR;
	// Fire the pragma-setter on every future connection in this process.
	sqlite3_auto_extension((void (*)(void))weft_apply_defaults);
	return SQLITE_OK;
}
