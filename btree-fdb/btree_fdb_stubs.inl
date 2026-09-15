// btree_fdb_stubs.inl — Rung 10 Slice 2 skeleton. Included from sqlite3.c
// in place of the btree.c section (SQLITE_PRIVATE = static across one TU).
// spec/BtreeReplacement.lean owns the semantics; btree-fdb/encode.h owns the
// encoding. Stubs return trivial values — the build links but no SQL runs
// correctly until each body is filled in.
//
// Config-gated names not emitted here (declarations already handled by
// btree.h):
//   macros in production build: Sharable, SeekCount, ConnectionCount, Enter,
//     Leave (all six variants), HoldsMutex, HoldsAllMutexes, SchemaMutexHeld
//   not declared (NDEBUG / no SQLITE_TEST): CursorIsValid, CursorInfo, CursorList
//   defined outside btree.c: CopyFile (backup.c)
//
// SPDX-License-Identifier: (Apache-2.0 OR MIT) AND sqlite-blessing

#include "btree_fdb_impl.inl"

// ── Group A: row I/O ─────────────────────────────────────────

#ifndef WEFT_IMPL_sqlite3BtreeTableMoveto
SQLITE_PRIVATE int sqlite3BtreeTableMoveto(BtCursor* a0, i64 intKey, int bias, int *pRes) {
  (void)a0; (void)intKey; (void)bias; (void)pRes;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeIndexMoveto
SQLITE_PRIVATE int sqlite3BtreeIndexMoveto(BtCursor* a0, UnpackedRecord *pUnKey, int *pRes) {
  (void)a0; (void)pUnKey; (void)pRes;
  return SQLITE_OK;
}
#endif

SQLITE_PRIVATE int sqlite3BtreeCursorHasMoved(BtCursor* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeCursorRestore(BtCursor* a0, int* a1) {
  (void)a0; (void)a1;
  return SQLITE_OK;
}

#ifndef WEFT_IMPL_sqlite3BtreeFirst
SQLITE_PRIVATE int sqlite3BtreeFirst(BtCursor* a0, int *pRes) {
  (void)a0; (void)pRes;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeLast
SQLITE_PRIVATE int sqlite3BtreeLast(BtCursor* a0, int *pRes) {
  (void)a0; (void)pRes;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeNext
SQLITE_PRIVATE int sqlite3BtreeNext(BtCursor* a0, int flags) {
  (void)a0; (void)flags;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreePrevious
SQLITE_PRIVATE int sqlite3BtreePrevious(BtCursor* a0, int flags) {
  (void)a0; (void)flags;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeEof
SQLITE_PRIVATE int sqlite3BtreeEof(BtCursor* a0) {
  (void)a0;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeInsert
SQLITE_PRIVATE int sqlite3BtreeInsert(BtCursor* a0, const BtreePayload *pPayload, int flags, int seekResult) {
  (void)a0; (void)pPayload; (void)flags; (void)seekResult;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeDelete
SQLITE_PRIVATE int sqlite3BtreeDelete(BtCursor* a0, u8 flags) {
  (void)a0; (void)flags;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreePayload
SQLITE_PRIVATE int sqlite3BtreePayload(BtCursor* a0, u32 offset, u32 amt, void* a3) {
  (void)a0; (void)offset; (void)amt; (void)a3;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreePayloadChecked
SQLITE_PRIVATE int sqlite3BtreePayloadChecked(BtCursor* a0, u32 offset, u32 amt, void* a3) {
  (void)a0; (void)offset; (void)amt; (void)a3;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreePayloadFetch
SQLITE_PRIVATE const void * sqlite3BtreePayloadFetch(BtCursor* a0, u32 *pAmt) {
  (void)a0; (void)pAmt;
  return 0;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreePayloadSize
SQLITE_PRIVATE u32 sqlite3BtreePayloadSize(BtCursor* a0) {
  (void)a0;
  return 0;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeMaxRecordSize
SQLITE_PRIVATE sqlite3_int64 sqlite3BtreeMaxRecordSize(BtCursor* a0) {
  (void)a0;
  return 0;
}
#endif

SQLITE_PRIVATE int sqlite3BtreePutData(BtCursor* a0, u32 offset, u32 amt, void* a3) {
  (void)a0; (void)offset; (void)amt; (void)a3;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeTransferRow(BtCursor* a0, BtCursor* a1, i64 a2) {
  (void)a0; (void)a1; (void)a2;
  return SQLITE_OK;
}

#ifndef WEFT_IMPL_sqlite3BtreeCount
SQLITE_PRIVATE int sqlite3BtreeCount(sqlite3* a0, BtCursor* a1, i64* a2) {
  (void)a0; (void)a1; (void)a2;
  return SQLITE_OK;
}
#endif

SQLITE_PRIVATE i64 sqlite3BtreeRowCountEst(BtCursor* a0) {
  (void)a0;
  return 0;
}

// ── Group B: transactions ────────────────────────────────────

#ifndef WEFT_IMPL_sqlite3BtreeBeginTrans
SQLITE_PRIVATE int sqlite3BtreeBeginTrans(Btree* a0, int a1, int* a2) {
  (void)a0; (void)a1; (void)a2;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeCommitPhaseOne
SQLITE_PRIVATE int sqlite3BtreeCommitPhaseOne(Btree* a0, const char* a1) {
  (void)a0; (void)a1;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeCommitPhaseTwo
SQLITE_PRIVATE int sqlite3BtreeCommitPhaseTwo(Btree* a0, int a1) {
  (void)a0; (void)a1;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeCommit
SQLITE_PRIVATE int sqlite3BtreeCommit(Btree* a0) {
  (void)a0;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeRollback
SQLITE_PRIVATE int sqlite3BtreeRollback(Btree* a0, int a1, int a2) {
  (void)a0; (void)a1; (void)a2;
  return SQLITE_OK;
}
#endif

SQLITE_PRIVATE int sqlite3BtreeBeginStmt(Btree* a0, int a1) {
  (void)a0; (void)a1;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeSavepoint(Btree * a0, int a1, int a2) {
  (void)a0; (void)a1; (void)a2;
  return SQLITE_OK;
}

#ifndef WEFT_IMPL_sqlite3BtreeTxnState
SQLITE_PRIVATE int sqlite3BtreeTxnState(Btree* a0) {
  (void)a0;
  return SQLITE_OK;
}
#endif

SQLITE_PRIVATE int sqlite3BtreeIsInBackup(Btree* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeCheckpoint(Btree* a0, int a1, int * a2, int * a3) {
  (void)a0; (void)a1; (void)a2; (void)a3;
  return SQLITE_OK;
}

// ── Group C: schema / table lifecycle ────────────────────────

#ifndef WEFT_IMPL_sqlite3BtreeCreateTable
SQLITE_PRIVATE int sqlite3BtreeCreateTable(Btree* a0, Pgno* a1, int flags) {
  (void)a0; (void)a1; (void)flags;
  return SQLITE_OK;
}
#endif

SQLITE_PRIVATE int sqlite3BtreeDropTable(Btree* a0, int a1, int* a2) {
  (void)a0; (void)a1; (void)a2;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeClearTable(Btree* a0, int a1, i64* a2) {
  (void)a0; (void)a1; (void)a2;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeClearTableOfCursor(BtCursor* a0) {
  (void)a0;
  return SQLITE_OK;
}

#ifndef WEFT_IMPL_sqlite3BtreeGetMeta
SQLITE_PRIVATE void sqlite3BtreeGetMeta(Btree *pBtree, int idx, u32 *pValue) {
  (void)pBtree; (void)idx; (void)pValue;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeUpdateMeta
SQLITE_PRIVATE int sqlite3BtreeUpdateMeta(Btree* a0, int idx, u32 value) {
  (void)a0; (void)idx; (void)value;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeSchema
SQLITE_PRIVATE void * sqlite3BtreeSchema(Btree * a0, int a1, void(*a2)(void *)) {
  (void)a0; (void)a1; (void)a2;
  return 0;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeSchemaLocked
SQLITE_PRIVATE int sqlite3BtreeSchemaLocked(Btree *pBtree) {
  (void)pBtree;
  return SQLITE_OK;
}
#endif

SQLITE_PRIVATE int sqlite3BtreeLockTable(Btree *pBtree, int iTab, u8 isWriteLock) {
  (void)pBtree; (void)iTab; (void)isWriteLock;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeNewDb(Btree *p) {
  (void)p;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeIncrVacuum(Btree * a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeSetAutoVacuum(Btree * a0, int a1) {
  (void)a0; (void)a1;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeGetAutoVacuum(Btree * a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeSetVersion(Btree *pBt, int iVersion) {
  (void)pBt; (void)iVersion;
  return SQLITE_OK;
}

// ── Group D: cursor lifecycle ────────────────────────────────

#ifndef WEFT_IMPL_sqlite3BtreeCursor
SQLITE_PRIVATE int sqlite3BtreeCursor(Btree* a0, Pgno iTable, int wrFlag, struct KeyInfo* a3, BtCursor *pCursor) {
  (void)a0; (void)iTable; (void)wrFlag; (void)a3; (void)pCursor;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeCursorSize
SQLITE_PRIVATE int sqlite3BtreeCursorSize(void) {
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeCursorZero
SQLITE_PRIVATE void sqlite3BtreeCursorZero(BtCursor* a0) {
  (void)a0;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeCloseCursor
SQLITE_PRIVATE int sqlite3BtreeCloseCursor(BtCursor* a0) {
  (void)a0;
  return SQLITE_OK;
}
#endif

SQLITE_PRIVATE void sqlite3BtreeClearCursor(BtCursor * a0) {
  (void)a0;
}

SQLITE_PRIVATE void sqlite3BtreeCursorPin(BtCursor* a0) {
  (void)a0;
}

SQLITE_PRIVATE void sqlite3BtreeCursorUnpin(BtCursor* a0) {
  (void)a0;
}

SQLITE_PRIVATE void sqlite3BtreeCursorHint(BtCursor* a0, int a1, ...) {
  (void)a0; (void)a1;
}

SQLITE_PRIVATE void sqlite3BtreeCursorHintFlags(BtCursor* a0, unsigned a1) {
  (void)a0; (void)a1;
}

SQLITE_PRIVATE int sqlite3BtreeCursorHasHint(BtCursor* a0, unsigned int mask) {
  (void)a0; (void)mask;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeCursorIsValidNN(BtCursor* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeTripAllCursors(Btree* a0, int a1, int a2) {
  (void)a0; (void)a1; (void)a2;
  return SQLITE_OK;
}

SQLITE_PRIVATE void sqlite3BtreeIncrblobCursor(BtCursor * a0) {
  (void)a0;
}

SQLITE_PRIVATE BtCursor * sqlite3BtreeFakeValidCursor(void) {
  return 0;
}

// ── Group E: pager configuration passthroughs ────────────────

SQLITE_PRIVATE int sqlite3BtreeSetCacheSize(Btree* a0, int a1) {
  (void)a0; (void)a1;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeSetSpillSize(Btree* a0, int a1) {
  (void)a0; (void)a1;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeSetMmapLimit(Btree* a0, sqlite3_int64 a1) {
  (void)a0; (void)a1;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeSetPagerFlags(Btree* a0, unsigned a1) {
  (void)a0; (void)a1;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeSetPageSize(Btree *p, int nPagesize, int nReserve, int eFix) {
  (void)p; (void)nPagesize; (void)nReserve; (void)eFix;
  return SQLITE_OK;
}

#ifndef WEFT_IMPL_sqlite3BtreeGetPageSize
SQLITE_PRIVATE int sqlite3BtreeGetPageSize(Btree* a0) {
  (void)a0;
  return SQLITE_OK;
}
#endif

SQLITE_PRIVATE Pgno sqlite3BtreeMaxPageCount(Btree* a0, Pgno a1) {
  (void)a0; (void)a1;
  return 0;
}

#ifndef WEFT_IMPL_sqlite3BtreeLastPage
SQLITE_PRIVATE Pgno sqlite3BtreeLastPage(Btree* a0) {
  (void)a0;
  return 0;
}
#endif

SQLITE_PRIVATE int sqlite3BtreeSecureDelete(Btree* a0, int a1) {
  (void)a0; (void)a1;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeGetRequestedReserve(Btree* a0) {
  (void)a0;
  return SQLITE_OK;
}

SQLITE_PRIVATE int sqlite3BtreeGetReserveNoMutex(Btree *p) {
  (void)p;
  return SQLITE_OK;
}

#ifndef WEFT_IMPL_sqlite3BtreePager
SQLITE_PRIVATE struct Pager * sqlite3BtreePager(Btree* a0) {
  (void)a0;
  return 0;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeGetFilename
SQLITE_PRIVATE const char * sqlite3BtreeGetFilename(Btree * a0) {
  (void)a0;
  return 0;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeGetJournalname
SQLITE_PRIVATE const char * sqlite3BtreeGetJournalname(Btree * a0) {
  (void)a0;
  return 0;
}
#endif

SQLITE_PRIVATE void sqlite3BtreeClearCache(Btree* a0) {
  (void)a0;
}

// ── Group F: introspection ───────────────────────────────────

#ifndef WEFT_IMPL_sqlite3BtreeIntegerKey
SQLITE_PRIVATE i64 sqlite3BtreeIntegerKey(BtCursor* a0) {
  (void)a0;
  return 0;
}
#endif

SQLITE_PRIVATE i64 sqlite3BtreeOffset(BtCursor* a0) {
  (void)a0;
  return 0;
}

SQLITE_PRIVATE int sqlite3BtreeIsReadonly(Btree *pBt) {
  (void)pBt;
  return SQLITE_OK;
}

#ifndef WEFT_IMPL_sqlite3BtreeIntegrityCheck
SQLITE_PRIVATE char * sqlite3BtreeIntegrityCheck(sqlite3* a0, Btree* a1, Pgno*aRoot, int nRoot, int a4, int* a5) {
  (void)a0; (void)a1; (void)aRoot; (void)nRoot; (void)a4; (void)a5;
  return 0;
}
#endif

SQLITE_PRIVATE int sqlite3HeaderSizeBtree(void) {
  return SQLITE_OK;
}

// ── Group G: mutex / shared-cache / lifetime ─────────────────

#ifndef WEFT_IMPL_sqlite3BtreeOpen
SQLITE_PRIVATE int sqlite3BtreeOpen(sqlite3_vfs *pVfs, const char *zFilename, sqlite3 *db, Btree **ppBtree, int flags, int vfsFlags) {
  (void)pVfs; (void)zFilename; (void)db; (void)ppBtree; (void)flags; (void)vfsFlags;
  return SQLITE_OK;
}
#endif

#ifndef WEFT_IMPL_sqlite3BtreeClose
SQLITE_PRIVATE int sqlite3BtreeClose(Btree* a0) {
  (void)a0;
  return SQLITE_OK;
}
#endif

