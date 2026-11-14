# A SQLite VFS in Mojo whose files live in FoundationDB. Step 3 of the VFS port; the callbacks
# are those of `vfs_mem.mojo` and the storage is `fdb_vfs.c`'s layout, through `fdb_client.mojo`
# and the ported `fdb_keys`, `page_delta` modules.
#
# What this first cut does, following `fdb_vfs.c`:
#   open     reads HEAD and SIZE, drops the pages of a commit that never finished, and raises
#            the fence (a reader takes no fence and tidies nothing)
#   read     the dirty buffer first, then PIDX -> DELTA/<txid>/<pgno>, applying a delta to its
#            base row, else the newest shard's SHARD/<as_of>/<pgno> when no commit owns the page;
#            one FoundationDB transaction per call, retried the way FoundationDB asks
#   write    buffers whole pages; a partial page is read from the store first
#   sync     one transaction: the fence check, the DELTA rows, the PIDX rows, SIZE, LOGN, HEAD.
#            A page with a base row is sent as a delta when under a fifth of it changed, else whole
#   truncate drops buffered pages, and clears the PIDX rows past the end at the next commit
#   delete   clears everything under weft/db/<name>/
#
# What it does not do yet, and refuses rather than gets wrong:
#   * no compaction: a fold is not written here, though a store the C folded is read (SHARD rows)
#   * a commit above ONE_TXN_PAGES is refused: staged commits are not here
#   * no read-ahead, no cached read transaction, no cross-database commit, no fold
#
# SPDX-License-Identifier: Apache-2.0 OR MIT

from std.ffi import OwnedDLHandle
from std.memory import alloc
from fdb_client import *
from fdb_keys import *
from page_delta import *
from vfs_mem import (
    peek64, poke64, poke32, poke_i64, cstr, _bytes, _addr,
    F_close, F_rw, F_trunc, F_int, F_ptr, F_ctl, F_one, F_open, F_del, F_acc, F_full, F_rnd,
    io_lock, io_unlock, io_check_reserved, io_file_control, io_sector_size,
    vfs_full_pathname, vfs_randomness, vfs_sleep, vfs_current_time, vfs_last_error,
    FILE_SIZE, MAX_PATH,
)

comptime SQLITE_READONLY = 8
comptime SQLITE_IOERR = 10
comptime SQLITE_IOERR_READ = 266
comptime SQLITE_IOERR_WRITE = 778
comptime SQLITE_IOERR_DELETE = 2570
comptime SQLITE_CANTOPEN = 14
comptime SQLITE_IOERR_SHORT_READ = 522

# FoundationDB caps a transaction at 10 MB, and these follow from it (`fdb_vfs.c`).
comptime FDB_TXN_LIMIT = 10000000
comptime DELTA_ROW = PAGE + KEYMAX
comptime PIDX_ROW = KEYMAX + 8
comptime ONE_TXN_PAGES = FDB_TXN_LIMIT // (DELTA_ROW + PIDX_ROW)
comptime HEAD_TXN_RESERVE = 6 * (KEYMAX + 8)

comptime BASE_TXID = 1
comptime BASE_SHARD = 2

comptime IOCAP_ATOMIC4K = 0x10
comptime IOCAP_SAFE_APPEND = 0x200
comptime IOCAP_SEQUENTIAL = 0x400


# ── State ─────────────────────────────────────────────────────────────────────

# The full row a page's next delta is taken against: a log row by txid, or a shard page by its
# version. `bytes` is that row as stored, so a delta of `bytes` applies to the row. One slot per
# page number modulo BASE_SLOTS, as in the C.
comptime BASE_SLOTS = 4096


@fieldwise_init
struct BaseEntry(Copyable, Movable):
    var pgno: Int
    var kind: Int
    var id: Int
    var bytes: List[UInt8]


struct FileState(Movable):
    var name: String
    var head: Int
    var size: Int
    var sent_size: Int
    var fence: Int
    var readonly: Bool
    var trunc_pages: Int
    var log_pages: Int
    var has_shard: Bool
    var compact_due: Bool
    var shard_as_of: Int
    var base_pages: Int
    var pidx_row: Int
    var pgnos: List[Int]
    var pages: List[List[UInt8]]
    var where_: Dict[Int, Int]
    var short_read: Bool
    var bases: Dict[Int, BaseEntry]
    var as_delta: List[Bool]

    def __init__(out self, name: String, readonly: Bool):
        self.name = name.copy()
        self.head = 0
        self.size = 0
        self.sent_size = 0
        self.fence = 0
        self.readonly = readonly
        self.trunc_pages = -1
        self.log_pages = 0
        self.has_shard = False
        self.compact_due = False
        self.shard_as_of = 0
        self.base_pages = 0
        self.pidx_row = len(key_pidx(name, 0)) + 8
        self.pgnos = List[Int]()
        self.pages = List[List[UInt8]]()
        self.where_ = Dict[Int, Int]()
        self.short_read = False
        self.bases = Dict[Int, BaseEntry]()
        self.as_delta = List[Bool]()

    def base_get(self, pgno: Int) -> Optional[BaseEntry]:
        var e = self.bases.get(pgno % BASE_SLOTS)
        if e and e.value().pgno == pgno and e.value().kind != 0:
            return e.value().copy()
        return None

    # A reader keeps no bases: it never writes a delta.
    def base_put(mut self, pgno: Int, kind: Int, id: Int, bytes: List[UInt8]):
        if self.readonly:
            return
        self.bases[pgno % BASE_SLOTS] = BaseEntry(pgno, kind, id, bytes.copy())

    def clear_dirty(mut self):
        self.pgnos = List[Int]()
        self.pages = List[List[UInt8]]()
        self.where_ = Dict[Int, Int]()


struct Ctx(Movable):
    var fdb_addr: Int
    var files: List[FileState]
    var io_methods: Int

    def __init__(out self, fdb_addr: Int):
        self.fdb_addr = fdb_addr
        self.files = List[FileState]()
        self.io_methods = 0


def _ctx(addr: Int) -> Pointer[Ctx, MutAnyOrigin]:
    return Pointer[Ctx, MutAnyOrigin](unsafe_from_address=addr)


def _fdb(addr: Int) -> Pointer[Fdb, MutAnyOrigin]:
    return Pointer[Fdb, MutAnyOrigin](unsafe_from_address=addr)


# ── Transactions ──────────────────────────────────────────────────────────────

# Finish one attempt of a retry loop. A body answers 0, a FoundationDB error (above 0), or the
# negative of a SQLite code it will not have retried (a refused write). Returns 0 when done,
# -1 to go round again, or the SQLite code to give up with.
def settle(fdb: Fdb, t: Txn, code: Int32, commit: Bool, fail: Int32) raises -> Int32:
    var c = code
    if c < 0:
        t.destroy(fdb)
        return -c
    if c == 0 and commit:
        c = t.commit(fdb)
    if c == 0:
        t.destroy(fdb)
        return 0
    var again = t.on_error(fdb, c)
    t.destroy(fdb)
    if again:
        return -1
    return fail


def be64_of(r: GetResult) -> Int:
    if r.present and len(r.value) == 8:
        return Int(get_be64(r.value, 0))
    return 0


def u64_value(v: Int) -> List[UInt8]:
    var out = List[UInt8]()
    put_be64(out, UInt64(v))
    return out^


# The fence this handle holds must still be the store's, or the write is refused and not retried.
def check_fence(fdb: Fdb, t: Txn, f: FileState) raises -> Int32:
    var r = t.get_result(fdb, key_meta(f.name, "FENCE"))
    if r.code != 0:
        return r.code
    if not r.present or be64_of(r) != f.fence:
        return Int32(-SQLITE_READONLY)
    return 0


# ── Open ──────────────────────────────────────────────────────────────────────

def open_body(fdb: Fdb, t: Txn, mut f: FileState) raises -> Int32:
    f.head = 0
    f.size = 0
    var h = t.get_result(fdb, key_meta(f.name, "HEAD"))
    if h.code != 0:
        return h.code
    f.head = be64_of(h)
    var s = t.get_result(fdb, key_meta(f.name, "SIZE"))
    if s.code != 0:
        return s.code
    f.size = be64_of(s)
    var l = t.get_result(fdb, key_meta(f.name, "LOGN"))
    if l.code != 0:
        return l.code
    f.log_pages = be64_of(l)

    # The newest shard version at or below the head: the base a read falls through to when no
    # commit owns the page. `fdb_vfs.c` calls this load_newest_shard.
    f.has_shard = False
    f.shard_as_of = 0
    f.base_pages = 0
    var from_k = key_prefix(f.name, "SHARDN")
    var e = t.edge(fdb, from_k, key_shardn(f.name, UInt64(f.head + 1)), True)
    if e.code != 0:
        return e.code
    if e.found:
        f.has_shard = True
        f.shard_as_of = Int(get_be64(e.key, len(e.key) - 8))
        var bp = t.get_result(fdb, key_shardn(f.name, UInt64(f.shard_as_of)))
        if bp.code != 0:
            return bp.code
        f.base_pages = be64_of(bp)

    if f.readonly:
        f.sent_size = f.size
        return 0
    # The pages of a commit that never finished are unreachable: clear them.
    var drop_from = key_delta_txid(f.name, UInt64(f.head + 1))
    t.clear_range(fdb, drop_from, key_after(key_prefix(f.name, "DELTA")))
    # Take ownership; a writer that opened earlier now holds a stale number.
    var fr = t.get_result(fdb, key_meta(f.name, "FENCE"))
    if fr.code != 0:
        return fr.code
    f.fence = (be64_of(fr) + 1) if fr.present else 1
    t.set(fdb, key_meta(f.name, "FENCE"), u64_value(f.fence))
    f.sent_size = f.size
    return 0


def do_open(mut ctx: Ctx, fdb: Fdb, idx: Int) raises -> Int32:
    while True:
        var t = Txn(fdb)
        var code = open_body(fdb, t, ctx.files[idx])
        var r = settle(fdb, t, code, True, Int32(SQLITE_IOERR))
        if r != -1:
            return r


# ── Read ──────────────────────────────────────────────────────────────────────

# One page from the store: PIDX names the commit that owns it, and that commit's row is the page,
# or a delta against a full row. `present` stays False when no commit holds the page.
def page_from_store(
    fdb: Fdb, t: Txn, mut f: FileState, pgno: Int, mut page: List[UInt8], mut present: Bool
) raises -> Int32:
    present = False
    var owner = t.get_result(fdb, key_pidx(f.name, UInt32(pgno)))
    if owner.code != 0:
        return owner.code
    if not owner.present:
        # No commit owns the page: it is in the shard, or it is a hole.
        if f.has_shard:
            var sh = t.get_result(fdb, key_shard(f.name, UInt64(f.shard_as_of), UInt32(pgno)))
            if sh.code != 0:
                return sh.code
            if sh.present:
                present = True
                page = sh.value.copy()
                if len(page) == PAGE:
                    f.base_put(pgno, BASE_SHARD, f.shard_as_of, page)
        return 0
    var row = t.get_result(fdb, key_delta(f.name, UInt64(be64_of(owner)), UInt32(pgno)))
    if row.code != 0:
        return row.code
    if not row.present:
        return 2000  # PIDX points at a row that is not there: not retryable
    present = True
    var otx = be64_of(owner)
    if not is_delta(row.value):
        page = row.value.copy()
        if len(page) == PAGE:
            f.base_put(pgno, BASE_TXID, otx, page)
        return 0
    # A delta is read against its base, which is always a full row.
    var kind = Int(row.value[1])
    var bid = delta_base_id(row.value)
    var base_key: List[UInt8]
    if kind == BASE_TXID:
        base_key = key_delta(f.name, bid, UInt32(pgno))
    elif kind == BASE_SHARD:
        base_key = key_shard(f.name, bid, UInt32(pgno))
    else:
        return 2000
    var base = t.get_result(fdb, base_key)
    if base.code != 0:
        return base.code
    if not base.present or len(base.value) != PAGE:
        return 2000
    page = base.value.copy()
    f.base_put(pgno, kind, Int(bid), page)
    if delta_apply(row.value, page) != 0:
        return 2000
    return 0


def read_body(fdb: Fdb, t: Txn, mut f: FileState, buf: Int, amt: Int, off: Int) raises -> Int32:
    var out = _bytes(buf)
    for i in range(amt):
        out[unsafe_offset=i] = 0
    f.short_read = False
    if not f.readonly:
        var fc = check_fence(fdb, t, f)
        if fc < 0:
            return Int32(-SQLITE_IOERR_READ)
        if fc != 0:
            return fc
    var done = 0
    while done < amt:
        var at = off + done
        var pgno = at // PAGE
        var within = at % PAGE
        var want = amt - done
        if want > PAGE - within:
            want = PAGE - within
        var d = f.where_.get(pgno)
        if d:
            ref src = f.pages[d.value()]
            for i in range(want):
                out[unsafe_offset=done + i] = src[within + i]
            done += want
            continue
        var page = List[UInt8]()
        var present = False
        var err = page_from_store(fdb, t, f, pgno, page, present)
        if err != 0:
            return err
        if present:
            var have = len(page) - within
            var n = have if have < want else want
            for i in range(n if n > 0 else 0):
                out[unsafe_offset=done + i] = page[within + i]
            if have < want:
                f.short_read = True
        else:
            f.short_read = True
        done += want
    return 0


# Read [off, off + amt) into `buf`. SQLITE_OK, or IOERR_SHORT_READ when the store holds less.
def read_range(fdb: Fdb, mut f: FileState, buf: Int, amt: Int, off: Int) raises -> Int32:
    while True:
        var t = Txn(fdb)
        var code = read_body(fdb, t, f, buf, amt, off)
        var r = settle(fdb, t, code, False, Int32(SQLITE_IOERR_READ))
        if r != -1:
            if r == 0 and f.short_read:
                return Int32(SQLITE_IOERR_SHORT_READ)
            return r


# ── Write and commit ──────────────────────────────────────────────────────────

def dirty_page(mut f: FileState, pgno: Int) -> Int:
    var d = f.where_.get(pgno)
    if d:
        return d.value()
    f.pgnos.append(pgno)
    f.pages.append(List[UInt8](length=PAGE, fill=0))
    var slot = len(f.pgnos) - 1
    f.where_[pgno] = slot
    return slot


def do_write(mut ctx: Ctx, idx: Int, buf: Int, amt: Int, off: Int) raises -> Int32:
    ref fdb = _fdb(ctx.fdb_addr)[]
    ref f = ctx.files[idx]
    var src = _bytes(buf)
    var done = 0
    while done < amt:
        var at = off + done
        var pgno = at // PAGE
        var within = at % PAGE
        var want = amt - done
        if want > PAGE - within:
            want = PAGE - within
        var have = f.where_.get(pgno)
        var slot: Int
        if have:
            slot = have.value()
        else:
            # The index rows of this commit must fit the one transaction that moves the head.
            if (len(f.pgnos) + 1) * f.pidx_row > FDB_TXN_LIMIT - HEAD_TXN_RESERVE:
                return Int32(SQLITE_IOERR_WRITE)
            var whole = within == 0 and want == PAGE
            var stored = alloc[UInt8](PAGE)
            if not whole:
                var rc = read_range(fdb, f, Int(stored), PAGE, pgno * PAGE)
                if rc != 0 and rc != SQLITE_IOERR_SHORT_READ:
                    return rc
            slot = dirty_page(f, pgno)
            if not whole:
                for i in range(PAGE):
                    f.pages[slot][i] = stored[unsafe_offset=i]
        for i in range(want):
            f.pages[slot][within + i] = src[unsafe_offset=done + i]
        done += want
    if off + amt > f.size:
        f.size = off + amt
    return 0


def commit_body(fdb: Fdb, t: Txn, mut f: FileState, txid: Int) raises -> Int32:
    var fc = check_fence(fdb, t, f)
    if fc != 0:
        return fc
    f.as_delta = List[Bool]()
    for i in range(len(f.pgnos)):
        var pgno = UInt32(f.pgnos[i])
        var row = List[UInt8]()
        # borrow the base entry: it is a 4 KB row, and a copy per page costs more than the encode
        var slot = f.pgnos[i] % BASE_SLOTS
        if slot in f.bases:
            ref be = f.bases[slot]
            if be.pgno == f.pgnos[i] and be.kind != 0:
                row = delta_encode(be.bytes, f.pages[i], be.kind, UInt64(be.id))
        if len(row) > 0:
            f.as_delta.append(True)
            t.set(fdb, key_delta(f.name, UInt64(txid), pgno), row)
        else:
            f.as_delta.append(False)
            t.set(fdb, key_delta(f.name, UInt64(txid), pgno), f.pages[i])
    for i in range(len(f.pgnos)):
        t.set(fdb, key_pidx(f.name, UInt32(f.pgnos[i])), u64_value(txid))
    if f.trunc_pages >= 0:
        var from_k = key_pidx(f.name, UInt32(f.trunc_pages))
        t.clear_range(fdb, from_k, key_after(key_prefix(f.name, "PIDX")))
    t.set(fdb, key_meta(f.name, "SIZE"), u64_value(f.size))
    t.set(fdb, key_meta(f.name, "LOGN"), u64_value(f.log_pages + len(f.pgnos)))
    t.set(fdb, key_meta(f.name, "HEAD"), u64_value(txid))
    return 0


# ── Compaction ────────────────────────────────────────────────────────────────
#
# A fold turns the log into a new shard version, as `compact_at` in `fdb_vfs.c` does: every page
# at the head is written to SHARD/<head>/<pgno>, and one last transaction sets SHARDN/<head>,
# clears every PIDX and DELTA row and every older shard version, and zeroes LOGN. It is owed when
# the log is as large as the base, and paid when the file closes. This one reads and writes a
# window at a time and waits for each; the C keeps four windows' commits in flight.

comptime STAGE_TXN_PAGES = FDB_TXN_LIMIT // DELTA_ROW
comptime FOLD_WINDOW_PAGES = STAGE_TXN_PAGES // 4


def should_compact(f: FileState) -> Bool:
    return f.log_pages > 0 and f.base_pages <= f.log_pages


struct FoldWindow(Movable):
    var pages: List[List[UInt8]]
    var present: List[Bool]

    def __init__(out self):
        self.pages = List[List[UInt8]]()
        self.present = List[Bool]()


def pgno_of_key(key: List[UInt8]) -> Int:
    var n = len(key)
    return (Int(key[n - 4]) << 24) | (Int(key[n - 3]) << 16) | (Int(key[n - 2]) << 8) | Int(key[n - 1])


# Read a window of pages with the answers a read gives: the page's owner in PIDX, its row in
# DELTA (rebuilt against its base when it is a delta), else its row in the shard.
def fold_read_body(fdb: Fdb, t: Txn, f: FileState, lo: Int, hi: Int, mut w: FoldWindow) raises -> Int32:
    var fc = check_fence(fdb, t, f)
    if fc != 0:
        return fc
    var n = hi - lo
    w = FoldWindow()
    var owner = List[Int]()
    for _ in range(n):
        w.pages.append(List[UInt8]())
        w.present.append(False)
        owner.append(0)

    var begin = key_pidx(f.name, UInt32(lo))
    var end = key_pidx(f.name, UInt32(hi))
    var after = False
    while True:
        var r = t.range_rows(fdb, begin, after, end)
        if r.code != 0:
            return r.code
        for i in range(len(r.keys)):
            var pg = pgno_of_key(r.keys[i])
            if pg >= lo and pg < hi and len(r.values[i]) == 8:
                owner[pg - lo] = Int(get_be64(r.values[i], 0))
        if not r.more or len(r.keys) == 0:
            break
        begin = r.keys[len(r.keys) - 1].copy()
        after = True

    if f.has_shard:
        begin = key_shard(f.name, UInt64(f.shard_as_of), UInt32(lo))
        end = key_shard(f.name, UInt64(f.shard_as_of), UInt32(hi))
        after = False
        while True:
            var r = t.range_rows(fdb, begin, after, end)
            if r.code != 0:
                return r.code
            for i in range(len(r.keys)):
                var pg = pgno_of_key(r.keys[i])
                if pg >= lo and pg < hi and owner[pg - lo] == 0:
                    var v = r.values[i].copy()
                    if len(v) > PAGE:
                        v.resize(PAGE, 0)
                    w.pages[pg - lo] = v^
                    w.present[pg - lo] = True
            if not r.more or len(r.keys) == 0:
                break
            begin = r.keys[len(r.keys) - 1].copy()
            after = True

    for i in range(n):
        if owner[i] == 0:
            continue
        var pgno = lo + i
        var row = t.get_result(fdb, key_delta(f.name, UInt64(owner[i]), UInt32(pgno)))
        if row.code != 0:
            return row.code
        if not row.present:
            continue
        if is_delta(row.value):
            var kind = Int(row.value[1])
            var bid = delta_base_id(row.value)
            var bk = List[UInt8]()
            if kind == BASE_TXID:
                bk = key_delta(f.name, bid, UInt32(pgno))
            elif kind == BASE_SHARD:
                bk = key_shard(f.name, bid, UInt32(pgno))
            else:
                return Int32(2000)
            var base = t.get_result(fdb, bk)
            if base.code != 0:
                return base.code
            if not base.present or len(base.value) != PAGE:
                return Int32(2000)  # a base is a full row
            var page = base.value.copy()
            if delta_apply(row.value, page) != 0:
                return Int32(2000)
            w.pages[i] = page^
            w.present[i] = True
        else:
            var v = row.value.copy()
            if len(v) > PAGE:
                v.resize(PAGE, 0)
            w.pages[i] = v^
            w.present[i] = True
    return 0


def fold_write_body(fdb: Fdb, t: Txn, f: FileState, as_of: Int, lo: Int, w: FoldWindow) raises -> Int32:
    _ = t.priority_batch(fdb)
    var fc = check_fence(fdb, t, f)
    if fc != 0:
        return fc
    for i in range(len(w.pages)):
        if w.present[i]:
            t.set(fdb, key_shard(f.name, UInt64(as_of), UInt32(lo + i)), w.pages[i])
    return 0


# Make the new shard version the one a read uses, and drop what it replaced, in one transaction.
def fold_finish_body(fdb: Fdb, t: Txn, f: FileState, as_of: Int, kept: Int) raises -> Int32:
    _ = t.priority_batch(fdb)
    var fc = check_fence(fdb, t, f)
    if fc != 0:
        return fc
    t.set(fdb, key_shardn(f.name, UInt64(as_of)), u64_value(kept))
    var pidx = key_prefix(f.name, "PIDX")
    t.clear_range(fdb, pidx, key_after(pidx))
    var delta = key_prefix(f.name, "DELTA")
    t.clear_range(fdb, delta, key_after(delta))
    t.clear_range(fdb, key_shard_version(f.name, 0), key_shard_version(f.name, UInt64(as_of)))
    t.clear_range(fdb, key_shardn(f.name, 0), key_shardn(f.name, UInt64(as_of)))
    t.set(fdb, key_meta(f.name, "LOGN"), u64_value(0))
    return 0


def do_compact(mut ctx: Ctx, idx: Int) raises -> Int32:
    ref fdb = _fdb(ctx.fdb_addr)[]
    ref f = ctx.files[idx]
    var as_of = f.head
    var npages = (f.size + PAGE - 1) // PAGE
    if npages == 0:
        return 0
    var window = FOLD_WINDOW_PAGES
    if window > npages:
        window = npages
    var kept = 0
    var lo = 0
    while lo < npages:
        var hi = lo + window
        if hi > npages:
            hi = npages
        var w = FoldWindow()
        while True:
            var t = Txn(fdb)
            var code = fold_read_body(fdb, t, f, lo, hi, w)
            var r = settle(fdb, t, code, False, Int32(SQLITE_IOERR_READ))
            if r == -1:
                continue
            if r != 0:
                return r
            break
        while True:
            var t = Txn(fdb)
            var code = fold_write_body(fdb, t, f, as_of, lo, w)
            var r = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
            if r == -1:
                continue
            if r != 0:
                return r
            break
        for i in range(len(w.present)):
            if w.present[i]:
                kept += 1
        lo = hi
    while True:
        var t = Txn(fdb)
        var code = fold_finish_body(fdb, t, f, as_of, kept)
        var r = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
        if r == -1:
            continue
        if r != 0:
            return r
        break
    f.has_shard = True
    f.shard_as_of = as_of
    f.base_pages = kept
    f.log_pages = 0
    # The fold deleted every log row and the old shard, which is every base this handle knew.
    f.bases = Dict[Int, BaseEntry]()
    return 0


def do_flush(mut ctx: Ctx, idx: Int) raises -> Int32:
    ref fdb = _fdb(ctx.fdb_addr)[]
    ref f = ctx.files[idx]
    if len(f.pgnos) == 0 and f.trunc_pages < 0 and f.size == f.sent_size:
        return 0
    if len(f.pgnos) > ONE_TXN_PAGES:
        return Int32(SQLITE_IOERR_WRITE)  # a staged commit is not here yet
    var txid = f.head + 1
    while True:
        var t = Txn(fdb)
        var code = commit_body(fdb, t, f, txid)
        var r = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
        if r == -1:
            continue
        if r != 0:
            return r
        for i in range(len(f.pgnos)):
            if not f.as_delta[i]:
                var whole = f.pages[i].copy()
                f.base_put(f.pgnos[i], BASE_TXID, txid, whole)
        f.head = txid
        f.sent_size = f.size
        f.log_pages += len(f.pgnos)
        f.trunc_pages = -1
        f.clear_dirty()
        # A fold is noted, not done, on the commit that trips the ratio: it is paid at close.
        if should_compact(f):
            f.compact_due = True
        return 0


# ── sqlite3_io_methods ────────────────────────────────────────────────────────

def _file_ctx(file: Int) -> Pointer[Ctx, MutAnyOrigin]:
    return _ctx(peek64(file + 8))


def fdb_close(file: Int) abi("C") -> Int32:
    try:
        var idx = peek64(file + 16)
        var rc = do_flush(_file_ctx(file)[], idx)
        if rc == 0 and _file_ctx(file)[].files[idx].compact_due:
            _file_ctx(file)[].files[idx].compact_due = False
            rc = do_compact(_file_ctx(file)[], idx)
        _file_ctx(file)[].files[idx].clear_dirty()
        return rc
    except:
        return Int32(SQLITE_IOERR)


def fdb_read(file: Int, buf: Int, amt: Int32, ofst: Int64) abi("C") -> Int32:
    try:
        ref c = _file_ctx(file)[]
        return read_range(_fdb(c.fdb_addr)[], c.files[peek64(file + 16)], buf, Int(amt), Int(ofst))
    except:
        return Int32(SQLITE_IOERR_READ)


def fdb_write(file: Int, buf: Int, amt: Int32, ofst: Int64) abi("C") -> Int32:
    try:
        return do_write(_file_ctx(file)[], peek64(file + 16), buf, Int(amt), Int(ofst))
    except:
        return Int32(SQLITE_IOERR_WRITE)


def fdb_truncate(file: Int, size: Int64) abi("C") -> Int32:
    ref f = _file_ctx(file)[].files[peek64(file + 16)]
    var npages = (Int(size) + PAGE - 1) // PAGE
    # drop the buffered pages the truncate removes
    var keep_n = List[Int]()
    var keep_p = List[List[UInt8]]()
    for i in range(len(f.pgnos)):
        if f.pgnos[i] < npages:
            keep_n.append(f.pgnos[i])
            keep_p.append(f.pages[i].copy())
    f.clear_dirty()
    for i in range(len(keep_n)):
        f.where_[keep_n[i]] = i
    f.pgnos = keep_n^
    f.pages = keep_p^
    if f.trunc_pages < 0 or npages < f.trunc_pages:
        f.trunc_pages = npages
    f.size = Int(size)
    return 0


def fdb_sync(file: Int, flags: Int32) abi("C") -> Int32:
    try:
        return do_flush(_file_ctx(file)[], peek64(file + 16))
    except:
        return Int32(SQLITE_IOERR_WRITE)


def fdb_file_size(file: Int, res: Int) abi("C") -> Int32:
    poke_i64(res, Int64(_file_ctx(file)[].files[peek64(file + 16)].size))
    return 0


def fdb_device_chars(file: Int) abi("C") -> Int32:
    return Int32(IOCAP_ATOMIC4K | IOCAP_SAFE_APPEND | IOCAP_SEQUENTIAL)


# ── sqlite3_vfs ───────────────────────────────────────────────────────────────

def vfs_open(vfs: Int, zname: Int, file: Int, flags: Int32, out_flags: Int) abi("C") -> Int32:
    try:
        ref c = _ctx(peek64(vfs + 32))[]
        var name = cstr(zname) if zname != 0 else String("anonymous")
        var readonly = (Int(flags) & 0x1) != 0
        c.files.append(FileState(name, readonly))
        var idx = len(c.files) - 1
        var rc = do_open(c, _fdb(c.fdb_addr)[], idx)
        if rc != 0:
            return rc
        poke64(file, c.io_methods)
        poke64(file + 8, peek64(vfs + 32))
        poke64(file + 16, idx)
        if out_flags != 0:
            poke32(out_flags, flags)
        return 0
    except:
        return Int32(SQLITE_CANTOPEN)


def vfs_delete(vfs: Int, zname: Int, sync_dir: Int32) abi("C") -> Int32:
    try:
        ref c = _ctx(peek64(vfs + 32))[]
        ref fdb = _fdb(c.fdb_addr)[]
        var name = cstr(zname)
        var prefix = key_meta(name, "")
        while True:
            var t = Txn(fdb)
            t.clear_range(fdb, prefix, key_after(prefix))
            var r = settle(fdb, t, 0, True, Int32(SQLITE_IOERR_DELETE))
            if r != -1:
                return r
    except:
        return Int32(SQLITE_IOERR_DELETE)


# A database exists once it has size.
def vfs_access(vfs: Int, zname: Int, flags: Int32, res: Int) abi("C") -> Int32:
    try:
        ref c = _ctx(peek64(vfs + 32))[]
        ref fdb = _fdb(c.fdb_addr)[]
        var key = key_meta(cstr(zname), "SIZE")
        while True:
            var t = Txn(fdb)
            var r = t.get_result(fdb, key)
            var exists = r.code == 0 and r.present and be64_of(r) > 0
            var s = settle(fdb, t, r.code, False, Int32(SQLITE_IOERR))
            if s == -1:
                continue
            poke32(res, Int32(1) if (s == 0 and exists) else Int32(0))
            return 0
    except:
        poke32(res, 0)
        return 0


# ── Registration ──────────────────────────────────────────────────────────────

def register_fdb(lib: OwnedDLHandle, name: String, cluster_file: String, make_default: Bool) raises -> Int:
    var fdb_slot = alloc[Fdb](1)
    fdb_slot.unsafe_write(Fdb(cluster_file))
    var ctx_slot = alloc[Ctx](1)
    ctx_slot.unsafe_write(Ctx(Int(fdb_slot)))
    var ctx_addr = Int(ctx_slot)

    var io = alloc[UInt8](112)
    for i in range(112):
        io[unsafe_offset=i] = 0
    var ia = Int(io)
    poke32(ia, 1)
    poke64(ia + 8, _addr[F_close](fdb_close))
    poke64(ia + 16, _addr[F_rw](fdb_read))
    poke64(ia + 24, _addr[F_rw](fdb_write))
    poke64(ia + 32, _addr[F_trunc](fdb_truncate))
    poke64(ia + 40, _addr[F_int](fdb_sync))
    poke64(ia + 48, _addr[F_ptr](fdb_file_size))
    poke64(ia + 56, _addr[F_int](io_lock))
    poke64(ia + 64, _addr[F_int](io_unlock))
    poke64(ia + 72, _addr[F_ptr](io_check_reserved))
    poke64(ia + 80, _addr[F_ctl](io_file_control))
    poke64(ia + 88, _addr[F_one](io_sector_size))
    poke64(ia + 96, _addr[F_one](fdb_device_chars))
    _ctx(ctx_addr)[].io_methods = ia

    var v = alloc[UInt8](192)
    for i in range(192):
        v[unsafe_offset=i] = 0
    var va = Int(v)
    var leaked = alloc[UInt8](name.byte_length() + 1)
    for i in range(name.byte_length()):
        leaked[unsafe_offset=i] = name.as_bytes()[i]
    leaked[unsafe_offset=name.byte_length()] = 0
    poke32(va, 1)
    poke32(va + 4, Int32(FILE_SIZE))
    poke32(va + 8, Int32(MAX_PATH))
    poke64(va + 24, Int(leaked))
    poke64(va + 32, ctx_addr)
    poke64(va + 40, _addr[F_open](vfs_open))
    poke64(va + 48, _addr[F_del](vfs_delete))
    poke64(va + 56, _addr[F_acc](vfs_access))
    poke64(va + 64, _addr[F_full](vfs_full_pathname))
    poke64(va + 104, _addr[F_rnd](vfs_randomness))
    poke64(va + 112, _addr[F_int](vfs_sleep))
    poke64(va + 120, _addr[F_ptr](vfs_current_time))
    poke64(va + 128, _addr[F_rnd](vfs_last_error))
    var rc = lib.call["sqlite3_vfs_register", Int32](va, 1 if make_default else 0)
    if rc != 0:
        raise Error("sqlite3_vfs_register failed: " + String(rc))
    return ctx_addr


# The state of an open file, for a test to look at.
def file_head(ctx_addr: Int, idx: Int) -> Int:
    return _ctx(ctx_addr)[].files[idx].head
