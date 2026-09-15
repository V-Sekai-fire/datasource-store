// btree_fdb_impl.inl — Rung 10 Slice 2b real bodies. Grows as sessions land
// each entry-point group; anything not implemented here falls through to the
// trivial stubs in btree_fdb_stubs.inl. Included from btree_fdb_stubs.inl at
// the very top so its `SQLITE_PRIVATE` definitions win over the stubs by
// preprocessor order (the stubs `#ifndef`-guard each name against a macro
// this file defines).
//
// The plan is to pick off one group per session in this order:
//   G_lifetime  (Open, Close)                          — this file, below
//   B_txn       (Begin/Commit/Rollback/TxnState/Meta)  — this file, below
//   D_cursor    (Cursor, CloseCursor, TripAll)         — future session
//   A_row_io    (Insert/Delete/First/Next/Payload)     — future session
//   C_schema    (CreateTable/DropTable/ClearTable)     — future session
//
// spec/BtreeReplacement.lean owns the four-op semantics; btree-fdb/encode.h
// owns the encoding; fdb_vfs.c owns the FDB helpers this file calls into.
//
// SPDX-License-Identifier: (Apache-2.0 OR MIT) AND sqlite-blessing

// ── Per-btree state ─────────────────────────────────────────────────
//
// One WeftState hangs off Btree.pBt via a pointer cast — BtShared.pPager is
// the field VDBE reads via `iBDataVersion`, so we point that at a small
// stand-in struct whose only field is `iDataVersion`. Everything else about
// BtShared and Pager is opaque to the fork; we allocate them large enough
// for the amalgamation's typed field accesses and leave the rest zeroed.

// The `struct Pager` layout comes from pager_fdb_stubs.inl — this file is
// #include'd after that section so the fields are visible here.
struct WeftState {
	int refs;
	// TODO: FdbFile handle from fdb_vfs.c goes here once row I/O lands.
};

// The stubs file marks these three as "impl provided" so its own stubs skip
// them via the #ifdef guards below.
#define WEFT_IMPL_sqlite3BtreeOpen 1
#define WEFT_IMPL_sqlite3BtreeClose 1
#define WEFT_IMPL_sqlite3BtreeBeginTrans 1
#define WEFT_IMPL_sqlite3BtreeCommitPhaseOne 1
#define WEFT_IMPL_sqlite3BtreeCommitPhaseTwo 1
#define WEFT_IMPL_sqlite3BtreeCommit 1
#define WEFT_IMPL_sqlite3BtreeRollback 1
#define WEFT_IMPL_sqlite3BtreeTxnState 1
#define WEFT_IMPL_sqlite3BtreeGetMeta 1
#define WEFT_IMPL_sqlite3BtreeUpdateMeta 1
#define WEFT_IMPL_sqlite3BtreeSchema 1
#define WEFT_IMPL_sqlite3BtreeSchemaLocked 1
#define WEFT_IMPL_sqlite3BtreeGetPageSize 1
#define WEFT_IMPL_sqlite3BtreeGetFilename 1
#define WEFT_IMPL_sqlite3BtreeGetJournalname 1
#define WEFT_IMPL_sqlite3BtreePager 1
#define WEFT_IMPL_sqlite3BtreeCreateTable 1
#define WEFT_IMPL_sqlite3BtreeLastPage 1
#define WEFT_IMPL_sqlite3BtreeIntegrityCheck 1
#define WEFT_IMPL_sqlite3BtreeCursorSize 1
#define WEFT_IMPL_sqlite3BtreeCursorZero 1
#define WEFT_IMPL_sqlite3BtreeCursor 1
#define WEFT_IMPL_sqlite3BtreeCloseCursor 1
#define WEFT_IMPL_sqlite3BtreeFirst 1
#define WEFT_IMPL_sqlite3BtreeLast 1
#define WEFT_IMPL_sqlite3BtreeNext 1
#define WEFT_IMPL_sqlite3BtreePrevious 1
#define WEFT_IMPL_sqlite3BtreeEof 1
#define WEFT_IMPL_sqlite3BtreeIntegerKey 1
#define WEFT_IMPL_sqlite3BtreePayloadSize 1
#define WEFT_IMPL_sqlite3BtreeInsert 1
#define WEFT_IMPL_sqlite3BtreeDelete 1
#define WEFT_IMPL_sqlite3BtreeTableMoveto 1
#define WEFT_IMPL_sqlite3BtreeIndexMoveto 1
#define WEFT_IMPL_sqlite3BtreePayload 1
#define WEFT_IMPL_sqlite3BtreePayloadFetch 1
#define WEFT_IMPL_sqlite3BtreePayloadChecked 1
#define WEFT_IMPL_sqlite3BtreeCount 1
#define WEFT_IMPL_sqlite3BtreeMaxRecordSize 1

// ── G_lifetime ──────────────────────────────────────────────────────
//
// sqlite3BtreeOpen allocates the Btree and its shared state. VDBE calls
// this once per attached database. On our fork the Btree carries no page
// cache — it's a light wrapper around what will become an fdb_transaction
// pointer in Slice 2c.

// Open the file through the VFS and stash the handle so sqlite3PagerFile
// returns it. Without this the amalgamation's sqlite3_file_control asserts
// against NULL and dereferences it in Release builds.
SQLITE_PRIVATE int sqlite3BtreeOpen(
	sqlite3_vfs *pVfs,
	const char *zFilename,
	sqlite3 *db,
	Btree **ppBtree,
	int flags,
	int vfsFlags
){
	(void)flags;
	Btree *p = sqlite3MallocZero(sizeof(Btree));
	if (!p) return SQLITE_NOMEM_BKPT;
	BtShared *pBt = sqlite3MallocZero(sizeof(BtShared));
	if (!pBt) { sqlite3_free(p); return SQLITE_NOMEM_BKPT; }

	// Filename byte size for the flexible tail. Empty string means memdb.
	const char *zName = zFilename ? zFilename : "";
	int nName = (int)strlen(zName);
	int nAlloc = (int)(sizeof(struct Pager) + nName + 1);
	Pager *pPager = sqlite3MallocZero(nAlloc);
	if (!pPager) {
		sqlite3_free(pBt); sqlite3_free(p);
		return SQLITE_NOMEM_BKPT;
	}
	pPager->pVfs = pVfs;
	pPager->memDb = (nName == 0);
	pPager->readOnly = (vfsFlags & SQLITE_OPEN_READONLY) ? 1 : 0;
	memcpy(pPager->zFilename, zName, (size_t)nName + 1);

	if (!pPager->memDb) {
		int szFile = pVfs ? pVfs->szOsFile : 0;
		pPager->fd = sqlite3MallocZero(szFile);
		if (!pPager->fd) {
			sqlite3_free(pPager); sqlite3_free(pBt); sqlite3_free(p);
			return SQLITE_NOMEM_BKPT;
		}
		int outFlags = 0;
		int rc = sqlite3OsOpen(pVfs, zName, pPager->fd,
		                       vfsFlags | SQLITE_OPEN_MAIN_DB, &outFlags);
		if (rc != SQLITE_OK) {
			sqlite3_free(pPager->fd);
			sqlite3_free(pPager); sqlite3_free(pBt); sqlite3_free(p);
			return rc;
		}
	}

	pBt->pPager = pPager;
	pBt->pageSize = 4096;
	pBt->usableSize = 4096;
	pBt->db = db;
	p->db = db;
	p->pBt = pBt;
	p->inTrans = TRANS_NONE;
	*ppBtree = p;
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeClose(Btree *p){
	if (!p) return SQLITE_OK;
	if (p->pBt) {
		if (p->pBt->pPager) {
			Pager *pPager = p->pBt->pPager;
			if (pPager->fd) {
				sqlite3OsClose(pPager->fd);
				sqlite3_free(pPager->fd);
			}
			sqlite3_free(pPager);
		}
		sqlite3_free(p->pBt);
	}
	sqlite3_free(p);
	return SQLITE_OK;
}

// ── B_txn ───────────────────────────────────────────────────────────
//
// These map onto fdb_vfs.c's txn helpers in Slice 2c. For now they just
// track Btree.inTrans so TxnState reports the right value back to VDBE
// and `sqlite3_txn_state()` on the connection stays consistent.

SQLITE_PRIVATE int sqlite3BtreeBeginTrans(Btree *p, int wrflag, int *pSchemaVersion){
	// Return the current schema cookie so OP_Transaction's iMeta check
	// converges (sqlite3.c:93645). meta[1] is BTREE_SCHEMA_VERSION; our
	// UpdateMeta/GetMeta already agree on that slot. Without this,
	// sqlite3_step's reprepare loop (SQLITE_MAX_SCHEMA_RETRY=50) never
	// terminates after a DDL bumps the cookie.
	if (pSchemaVersion) {
		*pSchemaVersion = (p && p->pBt && p->pBt->pPager)
		                  ? (int)p->pBt->pPager->meta[1]
		                  : 0;
	}
	p->inTrans = (u8)(wrflag ? TRANS_WRITE : TRANS_READ);
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeCommitPhaseOne(Btree *p, const char *zMaster){
	(void)p; (void)zMaster;
	// TODO(Slice 2c): fdb_transaction_commit here.
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeCommitPhaseTwo(Btree *p, int bCleanup){
	(void)bCleanup;
	p->inTrans = TRANS_NONE;
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeCommit(Btree *p){
	int rc = sqlite3BtreeCommitPhaseOne(p, 0);
	if (rc == SQLITE_OK) rc = sqlite3BtreeCommitPhaseTwo(p, 0);
	return rc;
}

SQLITE_PRIVATE int sqlite3BtreeRollback(Btree *p, int tripCode, int writeOnly){
	(void)tripCode; (void)writeOnly;
	p->inTrans = TRANS_NONE;
	// TODO(Slice 2c): fdb_transaction_reset here.
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeTxnState(Btree *p){
	return p ? (int)p->inTrans : SQLITE_TXN_NONE;
}

// ── C_schema (Meta and Schema pointer only for now) ─────────────────
//
// GetMeta / UpdateMeta read/write ten integers SQLite keeps in the
// database header (schema cookie, user_version, etc.). Our fork stores
// them in an in-memory array on BtShared for now; Slice 2c will persist
// them under weft/db/<name>/HEADER/<idx> keys through fdb_vfs.c.

// (GetMeta / UpdateMeta moved below alongside CreateTable — same section.)

SQLITE_PRIVATE void *sqlite3BtreeSchema(Btree *p, int nBytes, void(*xFree)(void*)){
	(void)xFree;
	if (!p->pBt->pSchema && nBytes) {
		p->pBt->pSchema = sqlite3MallocZero(nBytes);
	}
	return p->pBt->pSchema;
}

SQLITE_PRIVATE int sqlite3BtreeSchemaLocked(Btree *p){
	(void)p;
	return SQLITE_OK;
}

// ── E_pager passthroughs the amalgamation reads even before row I/O ─

SQLITE_PRIVATE int sqlite3BtreeGetPageSize(Btree *p){
	return p && p->pBt ? (int)p->pBt->pageSize : 4096;
}

SQLITE_PRIVATE const char *sqlite3BtreeGetFilename(Btree *p){
	(void)p;
	return "weft_fdb";
}

SQLITE_PRIVATE const char *sqlite3BtreeGetJournalname(Btree *p){
	(void)p;
	return 0;
}

SQLITE_PRIVATE Pager *sqlite3BtreePager(Btree *p){
	return p && p->pBt ? p->pBt->pPager : 0;
}

// ── B_txn add-ons ──────────────────────────────────────────────────
// GetMeta and UpdateMeta persist the ten integers SQLite tracks in the
// database header. Our Pager carries the array directly; Slice 2f will
// spill them to weft/db/<name>/HEADER/<idx> keys.

SQLITE_PRIVATE void sqlite3BtreeGetMeta(Btree *p, int idx, u32 *pValue){
	if (!p || !p->pBt || !p->pBt->pPager || idx < 0 || idx >= 16) {
		*pValue = 0; return;
	}
	*pValue = p->pBt->pPager->meta[idx];
}

SQLITE_PRIVATE int sqlite3BtreeUpdateMeta(Btree *p, int idx, u32 iMeta){
	if (!p || !p->pBt || !p->pBt->pPager || idx < 0 || idx >= 16) return SQLITE_MISUSE;
	p->pBt->pPager->meta[idx] = iMeta;
	return SQLITE_OK;
}

// ── C_schema ───────────────────────────────────────────────────────
// A CreateTable request wants a fresh root pgno. We keep a monotonic
// counter on the Pager. Real persistence lives in Slice 2f under
// weft/db/<name>/T/<pgno>/.

SQLITE_PRIVATE int sqlite3BtreeCreateTable(Btree *p, Pgno *piTable, int flags){
	(void)flags;
	if (!p || !p->pBt || !p->pBt->pPager) return SQLITE_MISUSE;
	if (p->pBt->pPager->nextRoot < 2) p->pBt->pPager->nextRoot = 2;
	*piTable = p->pBt->pPager->nextRoot++;
	return SQLITE_OK;
}

SQLITE_PRIVATE Pgno sqlite3BtreeLastPage(Btree *p){
	if (!p || !p->pBt || !p->pBt->pPager) return 0;
	Pgno n = p->pBt->pPager->nextRoot;
	return n > 0 ? n - 1 : 0;
}

// ── F_introspection ────────────────────────────────────────────────
SQLITE_PRIVATE char *sqlite3BtreeIntegrityCheck(sqlite3 *db, Btree *p, Pgno *aRoot,
                                                int nRoot, int mxErr, int *pnErr){
	(void)db; (void)p; (void)aRoot; (void)nRoot; (void)mxErr;
	if (pnErr) *pnErr = 0;
	return 0;
}

// ── D_cursor + A_row_io ─────────────────────────────────────────────
// A cursor sits inside VDBE's `BtCursor` allocation. We store two extra
// pieces of state in fields VDBE leaves alone: `pKey` holds a pointer to
// the current WeftRow, and `nKey` carries its rowid.
//
// Rows live in a WeftDb hung off pBt->pPager (defined in
// pager_fdb_stubs.inl). Each table is a sorted array of (rowid, bytes).
// Slice 2f keeps everything in RAM; persistence to the FDB keyspace is
// Slice 2g.

static WeftTable *weft_table_get(Pager *pPager, Pgno pgno, int create) {
	if (!pPager) return 0;
	for (u32 i = 0; i < pPager->tables.n; ++i) {
		if (pPager->tables.tables[i].pgno == pgno) return &pPager->tables.tables[i];
	}
	if (!create) return 0;
	if (pPager->tables.n == pPager->tables.cap) {
		u32 nc = pPager->tables.cap ? pPager->tables.cap * 2 : 4;
		WeftTable *nt = sqlite3_realloc(pPager->tables.tables, (int)(nc * sizeof(WeftTable)));
		if (!nt) return 0;
		memset(nt + pPager->tables.cap, 0, (nc - pPager->tables.cap) * sizeof(WeftTable));
		pPager->tables.tables = nt;
		pPager->tables.cap = nc;
	}
	WeftTable *t = &pPager->tables.tables[pPager->tables.n++];
	memset(t, 0, sizeof(*t));
	t->pgno = pgno;
	return t;
}

// bsearch for a rowid; returns the index that either matches or is the
// insertion point. `*pFound` is 1 on exact match, else 0.
static u32 weft_row_locate(WeftTable *t, i64 rowid, int *pFound) {
	u32 lo = 0, hi = t->n;
	while (lo < hi) {
		u32 mid = lo + (hi - lo) / 2;
		if (t->rows[mid].rowid < rowid) lo = mid + 1;
		else if (t->rows[mid].rowid > rowid) hi = mid;
		else { *pFound = 1; return mid; }
	}
	*pFound = 0;
	return lo;
}

static int weft_row_insert(WeftTable *t, i64 rowid, const u8 *data, u32 n) {
	int found = 0;
	u32 idx = weft_row_locate(t, rowid, &found);
	if (found) {
		sqlite3_free(t->rows[idx].data);
		u8 *copy = sqlite3_malloc(n ? (int)n : 1);
		if (!copy) return SQLITE_NOMEM_BKPT;
		if (n) memcpy(copy, data, n);
		t->rows[idx].data = copy;
		t->rows[idx].nData = n;
		return SQLITE_OK;
	}
	if (t->n == t->cap) {
		u32 nc = t->cap ? t->cap * 2 : 8;
		WeftRow *nr = sqlite3_realloc(t->rows, (int)(nc * sizeof(WeftRow)));
		if (!nr) return SQLITE_NOMEM_BKPT;
		t->rows = nr;
		t->cap = nc;
	}
	if (idx < t->n) memmove(&t->rows[idx + 1], &t->rows[idx], (t->n - idx) * sizeof(WeftRow));
	u8 *copy = sqlite3_malloc(n ? (int)n : 1);
	if (!copy) return SQLITE_NOMEM_BKPT;
	if (n) memcpy(copy, data, n);
	t->rows[idx].rowid = rowid;
	t->rows[idx].data = copy;
	t->rows[idx].nData = n;
	t->n++;
	return SQLITE_OK;
}

static Pager *weft_pager_of(BtCursor *pCur) {
	if (!pCur || !pCur->pBtree || !pCur->pBtree->pBt) return 0;
	return pCur->pBtree->pBt->pPager;
}

// pCur->pKey stores the current WeftRow*; nKey stores its rowid. This uses
// two BtCursor fields VDBE does not touch when reading through the payload
// API — VDBE calls sqlite3BtreeIntegerKey and sqlite3BtreePayload*
// exclusively for that state.

SQLITE_PRIVATE int sqlite3BtreeCursorSize(void){
	return (int)sizeof(BtCursor);
}

SQLITE_PRIVATE void sqlite3BtreeCursorZero(BtCursor *pCur){
	memset(pCur, 0, sizeof(BtCursor));
}

SQLITE_PRIVATE int sqlite3BtreeCursor(Btree *p, Pgno iTable, int wrFlag,
                                      struct KeyInfo *pKeyInfo, BtCursor *pCur){
	if (!p || !pCur) return SQLITE_MISUSE;
	memset(pCur, 0, sizeof(BtCursor));
	pCur->pBtree = p;
	pCur->pBt = p->pBt;
	pCur->pgnoRoot = iTable;
	pCur->pKeyInfo = pKeyInfo;
	pCur->eState = 1;  /* CURSOR_INVALID */
	if (wrFlag) pCur->curFlags |= 0x01;  /* BTCF_WriteFlag */
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeCloseCursor(BtCursor *pCur){
	if (pCur) { pCur->pKey = 0; pCur->eState = 1; }
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeFirst(BtCursor *pCur, int *pRes){
	Pager *pg = weft_pager_of(pCur);
	WeftTable *t = weft_table_get(pg, pCur->pgnoRoot, 0);
	if (!t || t->n == 0) { pCur->pKey = 0; pCur->eState = 1; *pRes = 1; return SQLITE_OK; }
	pCur->pKey = &t->rows[0];
	pCur->nKey = t->rows[0].rowid;
	pCur->ix = 0;
	pCur->eState = 0;  /* CURSOR_VALID */
	*pRes = 0;
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeLast(BtCursor *pCur, int *pRes){
	Pager *pg = weft_pager_of(pCur);
	WeftTable *t = weft_table_get(pg, pCur->pgnoRoot, 0);
	if (!t || t->n == 0) { pCur->pKey = 0; pCur->eState = 1; *pRes = 1; return SQLITE_OK; }
	u32 idx = t->n - 1;
	pCur->pKey = &t->rows[idx];
	pCur->nKey = t->rows[idx].rowid;
	pCur->ix = (u16)(idx < 0xffffu ? idx : 0xffffu);
	pCur->eState = 0;
	pCur->curFlags |= 0x08;  /* BTCF_AtLast */
	*pRes = 0;
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeNext(BtCursor *pCur, int flags){
	(void)flags;
	Pager *pg = weft_pager_of(pCur);
	WeftTable *t = weft_table_get(pg, pCur->pgnoRoot, 0);
	if (!t || pCur->eState != 0) return SQLITE_DONE;
	u32 idx = (u32)pCur->ix + 1;
	if (idx >= t->n) { pCur->pKey = 0; pCur->eState = 1; return SQLITE_DONE; }
	pCur->pKey = &t->rows[idx];
	pCur->nKey = t->rows[idx].rowid;
	pCur->ix = (u16)(idx < 0xffffu ? idx : 0xffffu);
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreePrevious(BtCursor *pCur, int flags){
	(void)flags;
	Pager *pg = weft_pager_of(pCur);
	WeftTable *t = weft_table_get(pg, pCur->pgnoRoot, 0);
	if (!t || pCur->eState != 0 || pCur->ix == 0) {
		pCur->pKey = 0; pCur->eState = 1; return SQLITE_DONE;
	}
	u32 idx = (u32)pCur->ix - 1;
	pCur->pKey = &t->rows[idx];
	pCur->nKey = t->rows[idx].rowid;
	pCur->ix = (u16)idx;
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeEof(BtCursor *pCur){
	return pCur ? (pCur->eState != 0) : 1;
}

SQLITE_PRIVATE i64 sqlite3BtreeIntegerKey(BtCursor *pCur){
	return pCur ? pCur->nKey : 0;
}

SQLITE_PRIVATE u32 sqlite3BtreePayloadSize(BtCursor *pCur){
	if (!pCur || !pCur->pKey) return 0;
	WeftRow *r = (WeftRow *)pCur->pKey;
	return r->nData;
}

SQLITE_PRIVATE sqlite3_int64 sqlite3BtreeMaxRecordSize(BtCursor *pCur){
	(void)pCur;
	return 1000000;  /* generous upper bound; SQLite uses this for planner cost */
}

SQLITE_PRIVATE int sqlite3BtreeTableMoveto(BtCursor *pCur, i64 intKey, int biasRight,
                                           int *pRes){
	(void)biasRight;
	Pager *pg = weft_pager_of(pCur);
	WeftTable *t = weft_table_get(pg, pCur->pgnoRoot, 0);
	if (!t || t->n == 0) { pCur->pKey = 0; pCur->eState = 1; *pRes = -1; return SQLITE_OK; }
	int found = 0;
	u32 idx = weft_row_locate(t, intKey, &found);
	if (idx >= t->n) idx = t->n - 1;
	pCur->pKey = &t->rows[idx];
	pCur->nKey = t->rows[idx].rowid;
	pCur->ix = (u16)(idx < 0xffffu ? idx : 0xffffu);
	pCur->eState = 0;
	if (found) *pRes = 0;
	else if (t->rows[idx].rowid < intKey) *pRes = -1;
	else *pRes = 1;
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeIndexMoveto(BtCursor *pCur, UnpackedRecord *pIdxKey,
                                           int *pRes){
	(void)pIdxKey;
	/* Indexes not implemented in Slice 2f; behave as empty. */
	pCur->pKey = 0; pCur->eState = 1; *pRes = -1;
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreePayload(BtCursor *pCur, u32 offset, u32 amt, void *pBuf){
	if (!pCur || !pCur->pKey) return SQLITE_ERROR;
	WeftRow *r = (WeftRow *)pCur->pKey;
	if (offset + amt > r->nData) return SQLITE_CORRUPT_BKPT;
	memcpy(pBuf, r->data + offset, amt);
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreePayloadChecked(BtCursor *pCur, u32 offset, u32 amt, void *pBuf){
	return sqlite3BtreePayload(pCur, offset, amt, pBuf);
}

SQLITE_PRIVATE const void *sqlite3BtreePayloadFetch(BtCursor *pCur, u32 *pAmt){
	if (!pCur || !pCur->pKey) { *pAmt = 0; return 0; }
	WeftRow *r = (WeftRow *)pCur->pKey;
	*pAmt = r->nData;
	return r->data;
}

SQLITE_PRIVATE int sqlite3BtreeInsert(BtCursor *pCur, const BtreePayload *pX,
                                      int flags, int seekResult){
	(void)flags; (void)seekResult;
	if (!pCur) return SQLITE_MISUSE;
	Pager *pg = weft_pager_of(pCur);
	if (!pg) return SQLITE_MISUSE;
	WeftTable *t = weft_table_get(pg, pCur->pgnoRoot, 1);
	if (!t) return SQLITE_NOMEM_BKPT;
	int rc = weft_row_insert(t, pX->nKey, (const u8 *)pX->pData, (u32)pX->nData);
	if (rc == SQLITE_OK) {
		/* Re-anchor cursor on the new row so IntegerKey / PayloadFetch work. */
		int found = 0;
		u32 idx = weft_row_locate(t, pX->nKey, &found);
		pCur->pKey = &t->rows[idx];
		pCur->nKey = pX->nKey;
		pCur->ix = (u16)(idx < 0xffffu ? idx : 0xffffu);
		pCur->eState = 0;
	}
	return rc;
}

SQLITE_PRIVATE int sqlite3BtreeDelete(BtCursor *pCur, u8 flags){
	(void)flags;
	if (!pCur || !pCur->pKey || pCur->eState != 0) return SQLITE_MISUSE;
	Pager *pg = weft_pager_of(pCur);
	WeftTable *t = weft_table_get(pg, pCur->pgnoRoot, 0);
	if (!t) return SQLITE_MISUSE;
	u32 idx = (u32)pCur->ix;
	if (idx >= t->n) return SQLITE_MISUSE;
	sqlite3_free(t->rows[idx].data);
	if (idx + 1 < t->n) memmove(&t->rows[idx], &t->rows[idx + 1],
	                            (t->n - idx - 1) * sizeof(WeftRow));
	t->n--;
	pCur->pKey = 0;
	pCur->eState = 1;
	return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeCount(sqlite3 *db, BtCursor *pCur, i64 *pnEntry){
	(void)db;
	Pager *pg = weft_pager_of(pCur);
	WeftTable *t = weft_table_get(pg, pCur->pgnoRoot, 0);
	*pnEntry = t ? (i64)t->n : 0;
	return SQLITE_OK;
}
