// SQLite loadable-extension entry point for the FoundationDB VFS.
// Lets sqlite-jdbc pick the VFS up through SELECT load_extension(...)
// so `jdbc:sqlite:file:...?vfs=fdb_vfs` opens the FDB-backed store
// without a JNI shim; the YCSB round in
// entities-vsk-database-roundtable calls it that way.

#include <sqlite3ext.h>
#include <stdlib.h>
SQLITE_EXTENSION_INIT1

int weft_fdb_start(const char *cluster_file);
int weft_vfs_register(int make_default);

int sqlite3_weftfdbvfs_init(
		sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi) {
	(void)db;
	SQLITE_EXTENSION_INIT2(pApi);
	int rc = weft_fdb_start(getenv("WEFT_FDB_CLUSTER_FILE"));
	if (rc) {
		*pzErrMsg = sqlite3_mprintf("weft_fdb_start failed: %d", rc);
		return SQLITE_ERROR;
	}
	return weft_vfs_register(0) ? SQLITE_ERROR : SQLITE_OK;
}
