// pager_fdb_stubs.inl — Rung 10 Slice 2c. Included from sqlite3.c in place of
// the pager.c section. Every entry point is a trivial stub.
//
// SPDX-License-Identifier: (Apache-2.0 OR MIT) AND sqlite-blessing

// The typedef `struct Wal Wal` lived inside pager.c; excising pager.c takes
// it out too. Forward-decl here so anything that names `Wal *` compiles.
typedef struct Wal Wal;

// Our Pager is a thin wrapper around one sqlite3_file the VFS opened for us,
// plus a handful of counters SQLite reads through the pager API. The btree
// replacement stores its own state here too until we split it out — the
// meta[] array is the sqlite_master schema cookie / file format / text
// encoding block, and `nextRoot` is the pgno allocator sqlite3BtreeCreateTable
// hands out.
// One row in a table, stored by (rowid, bytes). Rows kept sorted by rowid
// under `WeftTable.rows` so bsearch finds a target key in O(log n).
typedef struct WeftRow {
	i64 rowid;
	u8 *data;
	u32 nData;
} WeftRow;

typedef struct WeftTable {
	Pgno pgno;
	WeftRow *rows;
	u32 n;
	u32 cap;
} WeftTable;

// A tiny table-map hung off Pager. Slice 2f keeps rows in RAM so the shape
// of CREATE TABLE / INSERT / SELECT can be exercised end-to-end; Slice 2g
// spills through `Weft.Backend` calls into the store keyspace so rows
// survive close/reopen.
typedef struct WeftDb {
	WeftTable *tables;
	u32 n;
	u32 cap;
} WeftDb;

struct Pager {
	sqlite3_vfs *pVfs;
	sqlite3_file *fd;
	u32 iDataVersion;
	u32 meta[16];         /* 0=schema cookie, 1=file format, 3=text enc, ... */
	Pgno nextRoot;        /* Monotonic table-root allocator, starts at 2 */
	WeftDb tables;        /* in-memory table map (Slice 2f) */
	u8 readOnly;
	u8 memDb;
	char zFilename[1];    /* flexible: allocated with extra bytes */
};

// Public API defined inside the pager.c section: sqlite3_database_file_object
// is referenced by main.c's sqlite3_api_routines table. Return NULL — no
// caller under the fork actually uses the returned handle.
SQLITE_API sqlite3_file *sqlite3_database_file_object(const char *zName){
	(void)zName;
	return 0;
}

SQLITE_PRIVATE sqlite3_backup ** sqlite3PagerBackupPtr(Pager* a0) {
  (void)a0;
  return 0;
}

SQLITE_PRIVATE int sqlite3PagerBegin(Pager* a0, int exFlag, int a2) {
  (void)a0; (void)exFlag; (void)a2;
  return SQLITE_OK;
}

SQLITE_PRIVATE void sqlite3PagerCacheStat(Pager * a0, int a1, int a2, int * a3) {
  (void)a0; (void)a1; (void)a2; (void)a3;
}

SQLITE_PRIVATE int sqlite3PagerCheckpoint(Pager *pPager, sqlite3* a1, int a2, int* a3, int* a4) {
  (void)pPager; (void)a1; (void)a2; (void)a3; (void)a4;
  return SQLITE_OK;
}

SQLITE_PRIVATE void sqlite3PagerClearCache(Pager* a0) {
  (void)a0;
}

SQLITE_PRIVATE int sqlite3PagerClose(Pager *pPager, sqlite3* a1) {
  (void)pPager; (void)a1;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerCloseWal(Pager *pPager, sqlite3* a1) {
  (void)pPager; (void)a1;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerCommitPhaseOne(Pager* a0, const char *zSuper, int a2) {
  (void)a0; (void)zSuper; (void)a2;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerCommitPhaseTwo(Pager* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE u32 sqlite3PagerDataVersion(Pager* p) {
  return p ? p->iDataVersion : 0;
}

SQLITE_PRIVATE int sqlite3PagerDirectReadOk(Pager *pPager, Pgno pgno) {
  (void)pPager; (void)pgno;
  return SQLITE_OK;
}

SQLITE_PRIVATE void sqlite3PagerDontWrite(DbPage* a0) {
  (void)a0;
}

SQLITE_PRIVATE int sqlite3PagerExclusiveLock(Pager* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE sqlite3_file * sqlite3PagerFile(Pager* p) {
  return p ? p->fd : 0;
}

SQLITE_PRIVATE const char * sqlite3PagerFilename(const Pager* p, int nullIfMemDb) {
  (void)nullIfMemDb;
  return p ? p->zFilename : "";
}

SQLITE_PRIVATE int sqlite3PagerFlush(Pager* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerGet(Pager *pPager, Pgno pgno, DbPage **ppPage, int clrFlag) {
  (void)pPager; (void)pgno; (void)ppPage; (void)clrFlag;
  return SQLITE_OK;
}

SQLITE_PRIVATE void * sqlite3PagerGetData(DbPage * a0) {
  (void)a0;
  return 0;
}

SQLITE_PRIVATE void * sqlite3PagerGetExtra(DbPage * a0) {
  (void)a0;
  return 0;
}

SQLITE_PRIVATE int sqlite3PagerGetJournalMode(Pager* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerIsMemdb(Pager* p) {
  return p ? p->memDb : 0;
}

SQLITE_PRIVATE u8 sqlite3PagerIsreadonly(Pager* p) {
  return p ? p->readOnly : 0;
}

SQLITE_PRIVATE int sqlite3PagerIswriteable(DbPage* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE i64 sqlite3PagerJournalSizeLimit(Pager * a0, i64 a1) {
  (void)a0; (void)a1;
  return 0;
}

SQLITE_PRIVATE const char * sqlite3PagerJournalname(Pager* a0) {
  (void)a0;
  return 0;
}

SQLITE_PRIVATE sqlite3_file * sqlite3PagerJrnlFile(Pager* a0) {
  (void)a0;
  return 0;
}

SQLITE_PRIVATE int sqlite3PagerLockingMode(Pager * a0, int a1) {
  (void)a0; (void)a1;
  return SQLITE_OK;
}

SQLITE_PRIVATE DbPage * sqlite3PagerLookup(Pager *pPager, Pgno pgno) {
  (void)pPager; (void)pgno;
  return 0;
}

SQLITE_PRIVATE Pgno sqlite3PagerMaxPageCount(Pager* a0, Pgno a1) {
  (void)a0; (void)a1;
  return 0;
}

SQLITE_PRIVATE int sqlite3PagerMemUsed(Pager* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerMovepage(Pager* a0, DbPage* a1, Pgno a2, int a3) {
  (void)a0; (void)a1; (void)a2; (void)a3;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerOkToChangeJournalMode(Pager* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerOpen(sqlite3_vfs* a0, Pager **ppPager, const char* a2, int a3, int a4, int a5, void(*a6)(DbPage*)) {
  (void)a0; (void)ppPager; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerOpenSavepoint(Pager *pPager, int n) {
  (void)pPager; (void)n;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerOpenWal(Pager *pPager, int *pisOpen) {
  (void)pPager; (void)pisOpen;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerPageRefcount(DbPage* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE void sqlite3PagerPagecount(Pager* a0, int* a1) {
  (void)a0; (void)a1;
}

SQLITE_PRIVATE Pgno sqlite3PagerPagenumber(DbPage* a0) {
  (void)a0;
  return 0;
}

SQLITE_PRIVATE int sqlite3PagerReadFileheader(Pager* a0, int a1, unsigned char* a2) {
  (void)a0; (void)a1; (void)a2;
  return SQLITE_OK;
}

SQLITE_PRIVATE void sqlite3PagerRef(DbPage* a0) {
  (void)a0;
}

SQLITE_PRIVATE int sqlite3PagerRefcount(Pager* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE void sqlite3PagerRefdump(Pager* a0) {
  (void)a0;
}

SQLITE_PRIVATE void sqlite3PagerRekey(DbPage* a0, Pgno a1, u16 a2) {
  (void)a0; (void)a1; (void)a2;
}

SQLITE_PRIVATE int sqlite3PagerRollback(Pager* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerSavepoint(Pager *pPager, int op, int iSavepoint) {
  (void)pPager; (void)op; (void)iSavepoint;
  return SQLITE_OK;
}

SQLITE_PRIVATE void sqlite3PagerSetBusyHandler(Pager* a0, int(*a1)(void *), void * a2) {
  (void)a0; (void)a1; (void)a2;
}

SQLITE_PRIVATE void sqlite3PagerSetCachesize(Pager* a0, int a1) {
  (void)a0; (void)a1;
}

SQLITE_PRIVATE void sqlite3PagerSetFlags(Pager* a0, unsigned a1) {
  (void)a0; (void)a1;
}

SQLITE_PRIVATE int sqlite3PagerSetJournalMode(Pager * a0, int a1) {
  (void)a0; (void)a1;
  return SQLITE_OK;
}

SQLITE_PRIVATE void sqlite3PagerSetMmapLimit(Pager * a0, sqlite3_int64 a1) {
  (void)a0; (void)a1;
}

SQLITE_PRIVATE int sqlite3PagerSetPagesize(Pager* a0, u32* a1, int a2) {
  (void)a0; (void)a1; (void)a2;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerSetSpillsize(Pager* a0, int a1) {
  (void)a0; (void)a1;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerSharedLock(Pager *pPager) {
  (void)pPager;
  return SQLITE_OK;
}

SQLITE_PRIVATE void sqlite3PagerShrink(Pager* a0) {
  (void)a0;
}

SQLITE_PRIVATE int sqlite3PagerSnapshotCheck(Pager *pPager, sqlite3_snapshot *pSnapshot) {
  (void)pPager; (void)pSnapshot;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerSnapshotGet(Pager* a0, sqlite3_snapshot **ppSnapshot) {
  (void)a0; (void)ppSnapshot;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerSnapshotOpen(Pager* a0, sqlite3_snapshot *pSnapshot) {
  (void)a0; (void)pSnapshot;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerSnapshotRecover(Pager *pPager) {
  (void)pPager;
  return SQLITE_OK;
}

SQLITE_PRIVATE void sqlite3PagerSnapshotUnlock(Pager *pPager) {
  (void)pPager;
}

SQLITE_PRIVATE int * sqlite3PagerStats(Pager* a0) {
  (void)a0;
  return 0;
}

SQLITE_PRIVATE int sqlite3PagerSync(Pager *pPager, const char *zSuper) {
  (void)pPager; (void)zSuper;
  return SQLITE_OK;
}

SQLITE_PRIVATE void * sqlite3PagerTempSpace(Pager* a0) {
  (void)a0;
  return 0;
}

SQLITE_PRIVATE void sqlite3PagerTruncateImage(Pager* a0, Pgno a1) {
  (void)a0; (void)a1;
}

SQLITE_PRIVATE void sqlite3PagerUnref(DbPage* a0) {
  (void)a0;
}

SQLITE_PRIVATE void sqlite3PagerUnrefNotNull(DbPage* a0) {
  (void)a0;
}

SQLITE_PRIVATE void sqlite3PagerUnrefPageOne(DbPage* a0) {
  (void)a0;
}

SQLITE_PRIVATE sqlite3_vfs * sqlite3PagerVfs(Pager* p) {
  return p ? p->pVfs : 0;
}

SQLITE_PRIVATE int sqlite3PagerWalCallback(Pager *pPager) {
  (void)pPager;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerWalFramesize(Pager *pPager) {
  (void)pPager;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerWalSupported(Pager *pPager) {
  (void)pPager;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3PagerWrite(DbPage* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3SectorSize(sqlite3_file * a0) {
  (void)a0;
  return SQLITE_OK;
}

