# A SQLite VFS in Mojo whose files live in FoundationDB. Step 3 of the VFS port; the callbacks
# are those of `vfs_mem.mojo` and the storage is `fdb_vfs.c`'s layout, through `fdb_client.mojo`
# and the ported `fdb_keys`, `page_delta` modules.
#
# What this first cut does, following `fdb_vfs.c`:
#   open     reads HEAD and SIZE, drops the pages of a commit that never finished, and raises
#            the fence (a reader takes no fence and tidies nothing)
#   read     the dirty buffer first, then PIDX -> DELTA/<txid>/<pgno>, applying a delta to its
#            base row; one FoundationDB transaction per call, retried the way FoundationDB asks
#   write    buffers whole pages; a partial page is read from the store first
#   sync     one transaction: the fence check, the DELTA rows, the PIDX rows, SIZE, LOGN, HEAD
#   truncate drops buffered pages, and clears the PIDX rows past the end at the next commit
#   delete   clears everything under weft/db/<name>/
#
# What it does not do yet, and refuses rather than gets wrong:
#   * a database that has a shard version (a compaction ran) is not opened: there is no shard read
#   * a commit above ONE_TXN_PAGES is refused: staged commits are not here
#   * pages are written whole, never as a delta (the codec is ported; the base cache is not)
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

struct FileState(Movable):
    var name: String
    var head: Int
    var size: Int
    var sent_size: Int
    var fence: Int
    var readonly: Bool
    var trunc_pages: Int
    var log_pages: Int
    var pidx_row: Int
    var pgnos: List[Int]
    var pages: List[List[UInt8]]
    var where_: Dict[Int, Int]
    var short_read: Bool

    def __init__(out self, name: String, readonly: Bool):
        self.name = name.copy()
        self.head = 0
        self.size = 0
        self.sent_size = 0
        self.fence = 0
        self.readonly = readonly
        self.trunc_pages = -1
        self.log_pages = 0
        self.pidx_row = len(key_pidx(name, 0)) + 8
        self.pgnos = List[Int]()
        self.pages = List[List[UInt8]]()
        self.where_ = Dict[Int, Int]()
        self.short_read = False

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

    # A compacted database keeps pages in SHARD rows, which this cut cannot read. Refuse to open
    # it; reading its pages as holes would be silent corruption.
    var from_k = key_prefix(f.name, "SHARDN")
    var e = t.edge(fdb, from_k, key_shardn(f.name, UInt64(f.head + 1)), True)
    if e.code != 0:
        return e.code
    if e.found:
        return Int32(-SQLITE_CANTOPEN)

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
    fdb: Fdb, t: Txn, f: FileState, pgno: Int, mut page: List[UInt8], mut present: Bool
) raises -> Int32:
    present = False
    var owner = t.get_result(fdb, key_pidx(f.name, UInt32(pgno)))
    if owner.code != 0:
        return owner.code
    if not owner.present:
        return 0
    var row = t.get_result(fdb, key_delta(f.name, UInt64(be64_of(owner)), UInt32(pgno)))
    if row.code != 0:
        return row.code
    if not row.present:
        return 2000  # PIDX points at a row that is not there: not retryable
    present = True
    if not is_delta(row.value):
        page = row.value.copy()
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
    for i in range(len(f.pgnos)):
        var pgno = UInt32(f.pgnos[i])
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
        f.head = txid
        f.sent_size = f.size
        f.log_pages += len(f.pgnos)
        f.trunc_pages = -1
        f.clear_dirty()
        return 0


# ── sqlite3_io_methods ────────────────────────────────────────────────────────

def _file_ctx(file: Int) -> Pointer[Ctx, MutAnyOrigin]:
    return _ctx(peek64(file + 8))


def fdb_close(file: Int) abi("C") -> Int32:
    try:
        var idx = peek64(file + 16)
        var rc = do_flush(_file_ctx(file)[], idx)
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
