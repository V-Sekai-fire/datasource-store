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
#   sync     one transaction: the fence check, the DELTA rows, the PIDX rows, SIZE, LOGN, HEAD;
#            above ONE_TXN_PAGES the DELTA rows go first, STAGE_TXN_PAGES to a transaction, and
#            one last transaction moves the head.
#            A page with a base row is sent as a delta when under a fifth of it changed, else whole
#   truncate drops buffered pages, and clears the PIDX rows past the end at the next commit
#   delete   clears everything under weft/db/<name>/
#
# What it does not do yet, and refuses rather than gets wrong:
#   * no compaction: a fold is not written here, though a store the C folded is read (SHARD rows)
#   * no cached read transaction and no reader that follows the head. It reads ahead, starts groups (weft_txn_begin and the rest)
#     and a writer's open decides the groups the C left staging (recover_groups)
#
# SPDX-License-Identifier: Apache-2.0 OR MIT

from std.ffi import OwnedDLHandle
from std.memory import alloc
from fdb_client import *
from fdb_keys import *
from page_delta import *
from read_ahead import ReadAhead, RA_MAX_PAGES

# What a window says about a page. A prefetch does not fetch every page it covers, and a page it
# never fetched says nothing: reading it as a hole would lose a log-owned page.
comptime RA_UNFETCHED = 0
comptime RA_PRESENT = 1
comptime RA_ABSENT = 2
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
    var group_txnid: Int  # nonzero while this file belongs to an open group: its syncs stage
    var ra: ReadAhead  # how much this file looks like a scan, and the last page read
    var ra_window: List[UInt8]  # ra_count pages, allocated when a scan earns one
    var ra_state: List[UInt8]  # RA_UNFETCHED, RA_PRESENT or RA_ABSENT, a byte a page
    var ra_first: Int
    var ra_count: Int
    var ra_hits: Int  # pages answered from the window
    var ra_fills: Int  # windows filled

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
        self.group_txnid = 0
        self.ra = ReadAhead()
        self.ra_window = List[UInt8]()
        self.ra_state = List[UInt8]()
        self.ra_first = 0
        self.ra_count = 0
        self.ra_hits = 0
        self.ra_fills = 0

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
        self.ra_count = 0  # those pages are not what the window holds any more
        self.pgnos = List[Int]()
        self.pages = List[List[UInt8]]()
        self.where_ = Dict[Int, Int]()


struct Ctx(Movable):
    var fdb_addr: Int
    var files: List[FileState]
    var io_methods: Int
    # The group being built: one at a time, as in the C. Its members are indexes into `files`, and
    # `g_txids` holds the txid each staged under (its head, until it staged something).
    var g_open: Bool
    var g_txnid: Int
    var g_files: List[Int]
    var g_txids: List[Int]

    def __init__(out self, fdb_addr: Int):
        self.fdb_addr = fdb_addr
        self.files = List[FileState]()
        self.io_methods = 0
        self.g_open = False
        self.g_txnid = 0
        self.g_files = List[Int]()
        self.g_txids = List[Int]()


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
    f.ra_count = 0
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


# ── Group recovery ────────────────────────────────────────────────────────────
#
# A group commit stages one intent per database, then writes a record at weft/txn/<id>. Once the
# record is written the group is implicitly committed: every intent is durable, and any process
# that finds the record must finish it, whatever it wanted to do. If an intent is missing the
# group can never commit, so it is prevented. `recover_one` in `fdb_vfs.c` decides a record from
# the record alone, and `ParallelCommit.lean` is the model.
#
# This runs before a writer's open raises the fence or clears the rows above the head. The order
# is not a preference: a fence raised over an implicitly committed group destroys a write that
# was already acknowledged. A reader neither decides records nor raises a fence, so it skips this.
# Every outcome is safe to repeat, so any finder of a record may decide it.

struct GroupPart(Copyable, Movable):
    var name: String
    var txid: Int
    var size: Int
    var present: Bool
    var head: Int
    var pgnos: List[Int]

    def __init__(out self, name: String, txid: Int, size: Int):
        self.name = name.copy()
        self.txid = txid
        self.size = size
        self.present = False
        self.head = 0
        self.pgnos = List[Int]()


# Every row of [begin, end), following `more` until the range is done.
def all_rows(fdb: Fdb, t: Txn, begin: List[UInt8], end: List[UInt8]) raises -> RangeResult:
    var keys = List[List[UInt8]]()
    var values = List[List[UInt8]]()
    var b = begin.copy()
    var after = False
    while True:
        var r = t.range_rows(fdb, b, after, end)
        if r.code != 0:
            return RangeResult(r.code, False, keys^, values^)
        for i in range(len(r.keys)):
            keys.append(r.keys[i].copy())
            values.append(r.values[i].copy())
        if not r.more or len(r.keys) == 0:
            break
        b = r.keys[len(r.keys) - 1].copy()
        after = True
    return RangeResult(0, False, keys^, values^)


# Every record still staging. `weft/txn/NEXT` sorts under the same prefix and is skipped by shape:
# a record's status key is the prefix, an 8 byte txid and "/STATUS".
def sweep_body(fdb: Fdb, t: Txn, mut staging: List[Int]) raises -> Int32:
    staging = List[Int]()
    var begin = key_txn_all()
    var r = all_rows(fdb, t, begin, key_after(begin))
    if r.code != 0:
        return r.code
    var plen = len(begin)
    for i in range(len(r.keys)):
        ref k = r.keys[i]
        if len(k) == plen + 8 + 7 and k[plen + 8] == 0x2F and k[len(k) - 1] == 0x53:
            if len(r.values[i]) == 1 and Int(r.values[i][0]) == TXN_STAGING:
                staging.append(Int(get_be64(k, plen)))
    return 0


# The participants of one record: the database name, the txid it staged under, and the size its
# commit ends with. Recovery has no open handle, so the record carries all it needs.
def read_parts_body(fdb: Fdb, t: Txn, txnid: Int, mut parts: List[GroupPart]) raises -> Int32:
    parts = List[GroupPart]()
    var pre = key_txn_part_prefix(UInt64(txnid))
    var r = all_rows(fdb, t, pre, key_after(pre))
    if r.code != 0:
        return r.code
    for i in range(len(r.keys)):
        if len(r.values[i]) != 16 or len(r.keys[i]) <= len(pre):
            continue
        var name = String()
        for j in range(len(pre), len(r.keys[i])):
            name += chr(Int(r.keys[i][j]))
        parts.append(GroupPart(name, Int(get_be64(r.values[i], 0)), Int(get_be64(r.values[i], 8))))
    return 0


# QueryIntent. A participant staged in one transaction, so its pages are all there or none are.
# One that wrote nothing, or was resolved already, staged at or below its head: nothing can be
# missing. The page numbers come back too, because resolving needs them to write the index.
def query_intent_body(fdb: Fdb, t: Txn, mut p: GroupPart) raises -> Int32:
    p.present = False
    p.pgnos = List[Int]()
    var h = t.get_result(fdb, key_meta(p.name, "HEAD"))
    if h.code != 0:
        return h.code
    p.head = be64_of(h)
    if p.txid <= p.head:
        p.present = True
        return 0
    var pre = key_delta_txid(p.name, UInt64(p.txid))
    var r = all_rows(fdb, t, pre, key_after(pre))
    if r.code != 0:
        return r.code
    for i in range(len(r.keys)):
        if len(r.keys[i]) >= 4:
            p.pgnos.append(pgno_of_key(r.keys[i]))
    p.present = len(r.keys) > 0
    return 0


# Resolve one participant from the record alone: point its index at the staged pages and move
# its size and its head. This is `put_head` without an open file.
def resolve_body(fdb: Fdb, t: Txn, p: GroupPart) raises -> Int32:
    var h = t.get_result(fdb, key_meta(p.name, "HEAD"))
    if h.code != 0:
        return h.code
    if p.txid <= be64_of(h):
        return 0  # somebody resolved it first
    for i in range(len(p.pgnos)):
        t.set(fdb, key_pidx(p.name, UInt32(p.pgnos[i])), u64_value(p.txid))
    t.set(fdb, key_meta(p.name, "SIZE"), u64_value(p.size))
    var l = t.get_result(fdb, key_meta(p.name, "LOGN"))
    if l.code != 0:
        return l.code
    t.set(fdb, key_meta(p.name, "LOGN"), u64_value(be64_of(l) + len(p.pgnos)))
    t.set(fdb, key_meta(p.name, "HEAD"), u64_value(p.txid))
    return 0


# Give up one participant of an aborted group. The pages always go: nothing will ever point at
# them. The fence goes up only for the participant whose intent was missing, which is the write
# that must never land. Raising it on a healthy participant would invalidate every live handle on
# a database that had nothing wrong with it.
def prevent_body(fdb: Fdb, t: Txn, p: GroupPart, fence_it: Bool) raises -> Int32:
    if fence_it:
        var fr = t.get_result(fdb, key_meta(p.name, "FENCE"))
        if fr.code != 0:
            return fr.code
        t.set(fdb, key_meta(p.name, "FENCE"), u64_value((be64_of(fr) + 1) if fr.present else 1))
    var pre = key_delta_txid(p.name, UInt64(p.txid))
    t.clear_range(fdb, pre, key_after(pre))
    return 0


def drop_record_body(fdb: Fdb, t: Txn, txnid: Int) raises -> Int32:
    var pre = key_txn_prefix(UInt64(txnid))
    t.clear_range(fdb, pre, key_after(pre))
    return 0


def recover_one(fdb: Fdb, txnid: Int) raises -> Int32:
    var parts = List[GroupPart]()
    while True:
        var t = Txn(fdb)
        var code = read_parts_body(fdb, t, txnid, parts)
        var r = settle(fdb, t, code, False, Int32(SQLITE_IOERR_READ))
        if r == -1:
            continue
        if r != 0:
            return r
        break
    # Query every intent before changing anything: the decision depends on all of them, and a
    # partial answer is the one thing that must not drive it.
    var all_present = True
    for i in range(len(parts)):
        while True:
            var t = Txn(fdb)
            var code = query_intent_body(fdb, t, parts[i])
            var r = settle(fdb, t, code, False, Int32(SQLITE_IOERR_READ))
            if r == -1:
                continue
            if r != 0:
                return r
            break
        if not parts[i].present:
            all_present = False
    if len(parts) > 0 and all_present:
        # Implicitly committed. Finishing it is not a choice.
        for i in range(len(parts)):
            while True:
                var t = Txn(fdb)
                var code = resolve_body(fdb, t, parts[i])
                var r = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
                if r == -1:
                    continue
                if r != 0:
                    return r
                break
    elif len(parts) > 0:
        for i in range(len(parts)):
            while True:
                var t = Txn(fdb)
                var code = prevent_body(fdb, t, parts[i], not parts[i].present)
                var r = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
                if r == -1:
                    continue
                if r != 0:
                    return r
                break
    # A record with no participants decides nothing and cannot be committed; drop it too.
    while True:
        var t = Txn(fdb)
        var code = drop_record_body(fdb, t, txnid)
        var r = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
        if r == -1:
            continue
        return r


# Decide every staging record. Each pass removes records, so this ends.
def recover_groups(fdb: Fdb) raises -> Int32:
    for _ in range(1000):
        var staging = List[Int]()
        while True:
            var t = Txn(fdb)
            var code = sweep_body(fdb, t, staging)
            var r = settle(fdb, t, code, False, Int32(SQLITE_IOERR_READ))
            if r == -1:
                continue
            if r != 0:
                return r
            break
        if len(staging) == 0:
            return 0
        for i in range(len(staging)):
            var rc = recover_one(fdb, staging[i])
            if rc != 0:
                return rc
    return Int32(SQLITE_IOERR)


def do_open(mut ctx: Ctx, fdb: Fdb, idx: Int) raises -> Int32:
    if not ctx.files[idx].readonly:
        var rec = recover_groups(fdb)
        if rec != 0:
            return rec
    while True:
        var t = Txn(fdb)
        var code = open_body(fdb, t, ctx.files[idx])
        var r = settle(fdb, t, code, True, Int32(SQLITE_IOERR))
        if r != -1:
            return r


# ── Read ──────────────────────────────────────────────────────────────────────

# Fill the window with `count` pages from `first`: the owner of each from one range read of PIDX,
# and the pages the shard holds from one of SHARD. A page a commit owns stays unfetched (DELTA is
# keyed by txid first, so those are scattered), and a page nobody owns with nothing in the shard
# is a hole, which is as good an answer as a page. The window shrinks to what the reads reached: a
# range read that stops early says `more`, and a page past it is outside the window, never absent.
def ra_fill(fdb: Fdb, t: Txn, mut f: FileState, first: Int, count_in: Int) raises -> Int32:
    var count = count_in if count_in < RA_MAX_PAGES else RA_MAX_PAGES
    if len(f.ra_window) == 0:
        f.ra_window = List[UInt8](length=RA_MAX_PAGES * PAGE, fill=0)
        f.ra_state = List[UInt8](length=RA_MAX_PAGES, fill=0)
    for i in range(count):
        f.ra_state[i] = UInt8(RA_UNFETCHED)
    f.ra_first = first
    f.ra_count = count
    var owner = List[Bool](length=count, fill=False)

    var begin = key_pidx(f.name, UInt32(first))
    var end = key_pidx(f.name, UInt32(first + count))
    var after = False
    var reached = first
    while True:
        var r = t.range_rows(fdb, begin, after, end)
        if r.code != 0:
            f.ra_count = 0
            return r.code
        for i in range(len(r.keys)):
            var k = r.keys[i].copy()
            if len(k) < 4 or len(r.values[i]) != 8:
                continue
            var pg = (Int(k[len(k) - 4]) << 24) | (Int(k[len(k) - 3]) << 16) | (Int(k[len(k) - 2]) << 8) | Int(k[len(k) - 1])
            if pg >= first and pg < first + count:
                owner[pg - first] = True
                if pg + 1 > reached:
                    reached = pg + 1
        if not r.more or len(r.keys) == 0:
            break
        begin = r.keys[len(r.keys) - 1].copy()
        after = True
    # PIDX is sparse, so a short answer is ordinary; the loop above followed every `more`.

    if f.has_shard:
        var sb = key_shard(f.name, UInt64(f.shard_as_of), UInt32(first))
        var se = key_shard(f.name, UInt64(f.shard_as_of), UInt32(first + count))
        var safter = False
        var sreached = first
        while True:
            var r = t.range_rows(fdb, sb, safter, se)
            if r.code != 0:
                f.ra_count = 0
                return r.code
            for i in range(len(r.keys)):
                var k = r.keys[i].copy()
                var vl = len(r.values[i])
                if len(k) < 4 or vl > PAGE:
                    continue
                var pg = (Int(k[len(k) - 4]) << 24) | (Int(k[len(k) - 3]) << 16) | (Int(k[len(k) - 2]) << 8) | Int(k[len(k) - 1])
                if pg < first or pg >= first + count:
                    continue
                var j = pg - first
                if owner[j]:
                    continue  # the log's copy is newer than the shard's
                for b in range(PAGE):
                    f.ra_window[j * PAGE + b] = r.values[i][b] if b < vl else UInt8(0)
                f.ra_state[j] = UInt8(RA_PRESENT)
                if pg + 1 > sreached:
                    sreached = pg + 1
            if not r.more or len(r.keys) == 0:
                break
            sb = r.keys[len(r.keys) - 1].copy()
            safter = True
    for i in range(count):
        if owner[i]:
            f.ra_state[i] = UInt8(RA_UNFETCHED)
        elif Int(f.ra_state[i]) != RA_PRESENT:
            f.ra_state[i] = UInt8(RA_ABSENT if f.has_shard else RA_UNFETCHED)
    f.ra_count = count
    f.ra_fills += 1
    return 0


# Is this page already in the window? `present` is False for a hole the prefetch saw.
def ra_hit(mut f: FileState, pgno: Int, mut page: List[UInt8], mut present: Bool) -> Bool:
    if f.ra_count == 0 or pgno < f.ra_first or pgno >= f.ra_first + f.ra_count:
        return False
    var i = pgno - f.ra_first
    var st = Int(f.ra_state[i])
    if st == RA_ABSENT:
        present = False
        f.ra_hits += 1
        return True
    if st != RA_PRESENT:
        return False
    page = List[UInt8](length=PAGE, fill=0)
    for b in range(PAGE):
        page[b] = f.ra_window[i * PAGE + b]
    present = True
    f.ra_hits += 1
    return True


# One page from the store: PIDX names the commit that owns it, and that commit's row is the page,
# or a delta against a full row. `present` stays False when no commit holds the page.
def page_from_store(
    fdb: Fdb, t: Txn, mut f: FileState, pgno: Int, mut page: List[UInt8], mut present: Bool
) raises -> Int32:
    present = False
    # A window holds shard pages only, so a hit is a full shard row.
    if ra_hit(f, pgno, page, present):
        if present:
            f.base_put(pgno, BASE_SHARD, f.shard_as_of, page)
        return 0
    var depth = f.ra.depth(pgno)
    if depth > 0:
        var pre = ra_fill(fdb, t, f, pgno, depth)
        if pre != 0:
            return pre
        if ra_hit(f, pgno, page, present):
            if present:
                f.base_put(pgno, BASE_SHARD, f.shard_as_of, page)
            return 0
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


# The pages of the commit under a txid no read can reach yet: pages lo..hi of the dirty buffer.
# A page with a base row goes as a delta when under a fifth of it changed, else whole. This
# sets as_delta for each page it sends, which the commit reads afterwards.
def put_delta_pages(fdb: Fdb, t: Txn, mut f: FileState, txid: Int, lo: Int, hi: Int) raises:
    for i in range(lo, hi):
        var pgno = UInt32(f.pgnos[i])
        var row = List[UInt8]()
        # borrow the base entry: it is a 4 KB row, and a copy per page costs more than the encode
        var slot = f.pgnos[i] % BASE_SLOTS
        if slot in f.bases:
            ref be = f.bases[slot]
            if be.pgno == f.pgnos[i] and be.kind != 0:
                row = delta_encode(be.bytes, f.pages[i], be.kind, UInt64(be.id))
        if len(row) > 0:
            f.as_delta[i] = True
            t.set(fdb, key_delta(f.name, UInt64(txid), pgno), row)
        else:
            f.as_delta[i] = False
            t.set(fdb, key_delta(f.name, UInt64(txid), pgno), f.pages[i])


# What makes a commit visible: PIDX points at the new txid, the size moves, and the head
# advances. All of it lands together or none of it does.
def put_head(fdb: Fdb, t: Txn, f: FileState, txid: Int) raises:
    for i in range(len(f.pgnos)):
        t.set(fdb, key_pidx(f.name, UInt32(f.pgnos[i])), u64_value(txid))
    if f.trunc_pages >= 0:
        var from_k = key_pidx(f.name, UInt32(f.trunc_pages))
        t.clear_range(fdb, from_k, key_after(key_prefix(f.name, "PIDX")))
    t.set(fdb, key_meta(f.name, "SIZE"), u64_value(f.size))
    t.set(fdb, key_meta(f.name, "LOGN"), u64_value(f.log_pages + len(f.pgnos)))
    t.set(fdb, key_meta(f.name, "HEAD"), u64_value(txid))


# The whole commit in one transaction: the pages and the head together. A commit that fits one
# transaction needs no staging, because its pages are never visible before the head moves.
def commit_body(fdb: Fdb, t: Txn, mut f: FileState, txid: Int) raises -> Int32:
    var fc = check_fence(fdb, t, f)
    if fc != 0:
        return fc
    put_delta_pages(fdb, t, f, txid, 0, len(f.pgnos))
    put_head(fdb, t, f, txid)
    return 0


# One staging transaction of a commit too large for one: pages lo..hi, under a txid above the
# head. Every staging transaction checks the fence, so a stale writer stops at its first chunk.
def delta_body(fdb: Fdb, t: Txn, mut f: FileState, txid: Int, lo: Int, hi: Int) raises -> Int32:
    var fc = check_fence(fdb, t, f)
    if fc != 0:
        return fc
    put_delta_pages(fdb, t, f, txid, lo, hi)
    return 0


# The transaction that makes a staged commit real: PIDX, SIZE, LOGN and HEAD together.
def head_body(fdb: Fdb, t: Txn, f: FileState, txid: Int) raises -> Int32:
    var fc = check_fence(fdb, t, f)
    if fc != 0:
        return fc
    put_head(fdb, t, f, txid)
    return 0


# ── Compaction ────────────────────────────────────────────────────────────────
#
# A fold turns the log into a new shard version, as `compact_at` in `fdb_vfs.c` does: every page
# at the head is written to SHARD/<head>/<pgno>, and one last transaction sets SHARDN/<head>,
# clears every PIDX and DELTA row and every older shard version, and zeroes LOGN. It is owed when
# the log is as large as the base, and paid when the file closes. This one reads and writes a
# window at a time, with up to FOLD_DEPTH windows' commits in flight while the next is read, as the C does.

comptime STAGE_TXN_PAGES = FDB_TXN_LIMIT // DELTA_ROW
comptime FOLD_WINDOW_PAGES = STAGE_TXN_PAGES // 4
comptime FOLD_DEPTH = 4


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

    # Every logged page's row is read at once, as the C does: a round trip a page was ten
    # seconds at close for a 25,000 row table. A delta needs its base, a second wave in flight.
    var first = List[Int]()
    for i in range(n):
        if owner[i] == 0:
            first.append(0)
        else:
            first.append(t.get_start(fdb, key_delta(f.name, UInt64(owner[i]), UInt32(lo + i))))
    var err = Int32(0)
    var rows = List[List[UInt8]]()  # a delta row, kept until its base arrives
    for i in range(n):
        rows.append(List[UInt8]())
    for i in range(n):
        if first[i] == 0:
            continue
        var row = t.get_finish(fdb, first[i])  # every future is finished, even after an error
        if row.code != 0:
            if err == 0:
                err = row.code
            continue
        if not row.present:
            continue
        if is_delta(row.value):
            rows[i] = row.value.copy()
        else:
            var v = row.value.copy()
            if len(v) > PAGE:
                v.resize(PAGE, 0)
            w.pages[i] = v^
            w.present[i] = True
    var second = List[Int]()
    for i in range(n):
        second.append(0)
        if err != 0 or len(rows[i]) == 0:
            continue
        var kind = Int(rows[i][1])
        var bid = delta_base_id(rows[i])
        if kind == BASE_TXID:
            second[i] = t.get_start(fdb, key_delta(f.name, bid, UInt32(lo + i)))
        elif kind == BASE_SHARD:
            second[i] = t.get_start(fdb, key_shard(f.name, bid, UInt32(lo + i)))
        else:
            err = Int32(2000)
    for i in range(n):
        if second[i] == 0:
            continue
        var base = t.get_finish(fdb, second[i])
        if base.code != 0:
            if err == 0:
                err = base.code
            continue
        if not base.present or len(base.value) != PAGE:
            if err == 0:
                err = Int32(2000)  # a base is a full row
            continue
        var page = base.value.copy()
        if delta_apply(rows[i], page) != 0:
            if err == 0:
                err = Int32(2000)
            continue
        w.pages[i] = page^
        w.present[i] = True
    return err


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


# A window whose commit is in flight. `sent` says it has rows to settle; `fut` is 0 when the
# commit could not be started and the window goes the slow way, through the retry loop.
struct FoldSlot(Movable):
    var w: FoldWindow
    var tr: Int
    var fut: Int
    var sent: Bool
    var lo: Int

    def __init__(out self):
        self.w = FoldWindow()
        self.tr = 0
        self.fut = 0
        self.sent = False
        self.lo = 0


# Wait for a window's commit. One that failed goes again through the retry loop, which knows
# which errors may be retried and checks the fence; the rows are the same rows under a shard
# version no read uses yet, so writing them twice is harmless.
def fold_settle(fdb: Fdb, f: FileState, as_of: Int, mut s: FoldSlot, mut kept: Int) raises -> Int32:
    if not s.sent:
        return 0
    var again = True
    if s.fut != 0:
        var rc = Txn(handle=s.tr).commit_finish(fdb, s.fut)
        again = rc != 0
        s.fut = 0
    if s.tr != 0:
        Txn(handle=s.tr).destroy(fdb)
        s.tr = 0
    s.sent = False
    if again:
        while True:
            var t = Txn(fdb)
            var code = fold_write_body(fdb, t, f, as_of, s.lo, s.w)
            var r = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
            if r == -1:
                continue
            if r != 0:
                return r
            break
    for i in range(len(s.w.present)):
        if s.w.present[i]:
            kept += 1
    return 0


# Start a window's commit and return without waiting for it.
def fold_send(fdb: Fdb, f: FileState, as_of: Int, mut s: FoldSlot) raises -> Int32:
    s.sent = True
    var t = Txn(fdb)
    var code = fold_write_body(fdb, t, f, as_of, s.lo, s.w)
    if code < 0:
        t.destroy(fdb)
        s.sent = False
        return -code
    if code != 0:
        t.destroy(fdb)  # the slow way, at settle
        return 0
    s.tr = t.tr
    s.fut = t.commit_start(fdb)
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
    var slots = List[FoldSlot]()
    for _ in range(FOLD_DEPTH):
        slots.append(FoldSlot())
    var kept = 0
    var rc = Int32(0)
    var k = 0
    var lo = 0
    while lo < npages and rc == 0:
        ref s = slots[k % FOLD_DEPTH]
        rc = fold_settle(fdb, f, as_of, s, kept)
        if rc != 0:
            break
        s.lo = lo
        var hi = lo + window
        if hi > npages:
            hi = npages
        while True:
            var t = Txn(fdb)
            var code = fold_read_body(fdb, t, f, lo, hi, s.w)
            var r = settle(fdb, t, code, False, Int32(SQLITE_IOERR_READ))
            if r == -1:
                continue
            rc = r
            break
        if rc != 0:
            break
        rc = fold_send(fdb, f, as_of, s)
        lo += window
        k += 1
    # Every window settles, even after a failure, so no commit is left in flight.
    for i in range(FOLD_DEPTH):
        ref s = slots[i]
        if rc == 0:
            rc = fold_settle(fdb, f, as_of, s, kept)
        else:
            if s.fut != 0:
                _ = Txn(handle=s.tr).commit_finish(fdb, s.fut)
                s.fut = 0
            if s.tr != 0:
                Txn(handle=s.tr).destroy(fdb)
                s.tr = 0
    if rc != 0:
        return rc
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
    f.ra_count = 0  # the window points at a shard version that is no longer the one read
    f.base_pages = kept
    f.log_pages = 0
    # The fold deleted every log row and the old shard, which is every base this handle knew.
    f.bases = Dict[Int, BaseEntry]()
    return 0


def do_flush(mut ctx: Ctx, idx: Int) raises -> Int32:
    # A file that joined a group does not commit when SQLite says so. It stages, and the group's
    # record is what commits it. This has to happen here, in xSync: by the time a caller could ask
    # to stage, an ordinary flush would already have moved the head.
    if ctx.files[idx].group_txnid != 0:
        return stage_here(ctx, idx)
    ref fdb = _fdb(ctx.fdb_addr)[]
    ref f = ctx.files[idx]
    if len(f.pgnos) == 0 and f.trunc_pages < 0 and f.size == f.sent_size:
        return 0
    var txid = f.head + 1
    f.as_delta = List[Bool]()
    for _ in range(len(f.pgnos)):
        f.as_delta.append(False)
    var r = Int32(0)
    if len(f.pgnos) <= ONE_TXN_PAGES:
        while True:
            var t = Txn(fdb)
            var code = commit_body(fdb, t, f, txid)
            r = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
            if r == -1:
                continue
            break
    else:
        # Too large for one transaction: the pages first, STAGE_TXN_PAGES to a transaction under
        # a txid no read can reach, then one transaction that moves the head. A process that dies
        # in between leaves pages nothing points at, and the next open clears them.
        var lo = 0
        while lo < len(f.pgnos) and r == 0:
            var hi = lo + STAGE_TXN_PAGES
            if hi > len(f.pgnos):
                hi = len(f.pgnos)
            while True:
                var t = Txn(fdb)
                var code = delta_body(fdb, t, f, txid, lo, hi)
                r = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
                if r == -1:
                    continue
                break
            lo += STAGE_TXN_PAGES
        if r == 0:
            while True:
                var t = Txn(fdb)
                var code = head_body(fdb, t, f, txid)
                r = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
                if r == -1:
                    continue
                break
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


# ── Group commit ──────────────────────────────────────────────────────────────
#
# A group spans databases. Each member stages its pages under a txid above its head, where no read
# can reach them; one transaction then writes the record, naming every member, and from that
# moment the group is committed whether or not this process survives (see Group recovery above).
# Then each head moves and the record is dropped. `fdb_vfs.c` is the model: weft_txn_begin, join,
# commit and abort, and `spec/ParallelCommit.lean`.
#
# One difference: the C holds a lock from begin to commit, so a second begin waits. This VFS has
# no lock to hold, and a second begin answers SQLITE_BUSY.

comptime SQLITE_BUSY = 5
comptime SQLITE_MISUSE = 21
comptime SQLITE_TOOBIG = 18
comptime SQLITE_FULL = 13
comptime TXN_MAX_PARTS = 16
comptime SQLITE_FCNTL_FILE_POINTER = 7


# A participant's intent: its dirty pages, under head + 1, in one transaction so that it is all or
# nothing and recovery can decide it by reading one key. The buffer is kept: this process still
# sees its own writes, and resolving needs the page numbers.
def stage_here(mut ctx: Ctx, idx: Int) raises -> Int32:
    ref fdb = _fdb(ctx.fdb_addr)[]
    var txid = 0
    var r = Int32(0)
    var staged = False
    var head = 0
    if True:
        ref f = ctx.files[idx]
        if len(f.pgnos) == 0 and f.trunc_pages < 0 and f.size == f.sent_size:
            return 0
        if len(f.pgnos) > ONE_TXN_PAGES:
            return Int32(SQLITE_TOOBIG)
        head = f.head
        txid = f.head + 1
        f.as_delta = List[Bool]()
        for _ in range(len(f.pgnos)):
            f.as_delta.append(False)
        if len(f.pgnos) > 0:
            while True:
                var t = Txn(fdb)
                var code = delta_body(fdb, t, f, txid, 0, len(f.pgnos))
                r = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
                if r == -1:
                    continue
                break
            staged = True
    if r != 0:
        return r
    for i in range(len(ctx.g_files)):
        if ctx.g_files[i] == idx:
            ctx.g_txids[i] = txid if staged else head
            return 0
    # a file flagged as a member that is not in the group is a bug in the bookkeeping
    return Int32(SQLITE_MISUSE)


def seq_body(fdb: Fdb, t: Txn, mut txnid: Int) raises -> Int32:
    # the next group id, from a counter in the store: a read and a write in one transaction, so
    # two stores cannot choose the same one
    var key = key_txn_all()
    key.append(UInt8(78))  # N
    key.append(UInt8(69))  # E
    key.append(UInt8(88))  # X
    key.append(UInt8(84))  # T
    var r = t.get_result(fdb, key)
    if r.code != 0:
        return r.code
    txnid = (be64_of(r) + 1) if r.present else 1
    t.set(fdb, key, u64_value(txnid))
    return 0


def release_group(mut c: Ctx):
    for i in range(len(c.g_files)):
        c.files[c.g_files[i]].group_txnid = 0
    c.g_files = List[Int]()
    c.g_txids = List[Int]()
    c.g_open = False
    c.g_txnid = 0


def weft_txn_begin(ctx_addr: Int, mut txnid: Int) raises -> Int32:
    ref c = _ctx(ctx_addr)[]
    if c.g_open:
        return Int32(SQLITE_BUSY)
    ref fdb = _fdb(c.fdb_addr)[]
    var id = 0
    var r = Int32(0)
    while True:
        var t = Txn(fdb)
        var code = seq_body(fdb, t, id)
        r = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
        if r == -1:
            continue
        break
    if r != 0:
        return r
    c.g_open = True
    c.g_txnid = id
    c.g_files = List[Int]()
    c.g_txids = List[Int]()
    txnid = id
    return 0


# Join a database to the group, before it is written to: from here its syncs stage.
def weft_txn_join(lib: OwnedDLHandle, ctx_addr: Int, db: Int, txnid: Int) raises -> Int32:
    ref c = _ctx(ctx_addr)[]
    if not c.g_open or c.g_txnid != txnid:
        return Int32(SQLITE_MISUSE)
    if len(c.g_files) >= TXN_MAX_PARTS:
        return Int32(SQLITE_FULL)
    var slot = alloc[Int](1)
    slot[unsafe_offset=0] = 0
    var rc = lib.call["sqlite3_file_control", Int32](db, "main".unsafe_ptr(), Int32(SQLITE_FCNTL_FILE_POINTER), slot)
    var file = slot[unsafe_offset=0]
    # the file must be this VFS's, or its bytes mean nothing here
    if rc != 0 or file == 0 or peek64(file) != c.io_methods or peek64(file + 8) != ctx_addr:
        return Int32(SQLITE_MISUSE)
    var idx = peek64(file + 16)
    for i in range(len(c.g_files)):
        if c.g_files[i] == idx:
            return 0
    c.g_files.append(idx)
    c.g_txids.append(c.files[idx].head)
    c.files[idx].group_txnid = txnid
    return 0


# The commit: one transaction writes the record as staging. The fence of every member is read in
# it, so a member that lost ownership while staging cannot be carried into the group. The record
# names each member, the txid it staged under, and the size its commit ends with: recovery has no
# open handle, and the size is nowhere else.
def record_body(fdb: Fdb, t: Txn, c: Ctx, txnid: Int) raises -> Int32:
    for i in range(len(c.g_files)):
        var fc = check_fence(fdb, t, c.files[c.g_files[i]])
        if fc != 0:
            return fc
    for i in range(len(c.g_files)):
        ref f = c.files[c.g_files[i]]
        var val = u64_value(c.g_txids[i])
        var sz = u64_value(f.size)
        for j in range(len(sz)):
            val.append(sz[j])
        t.set(fdb, key_txn_part(UInt64(txnid), f.name), val)
    var st = List[UInt8]()
    st.append(UInt8(TXN_STAGING))
    t.set(fdb, key_txn_status(UInt64(txnid)), st)
    return 0


def set_status_body(fdb: Fdb, t: Txn, txnid: Int, status: Int) raises -> Int32:
    var st = List[UInt8]()
    st.append(UInt8(status))
    t.set(fdb, key_txn_status(UInt64(txnid)), st)
    return 0


# Move one member's head, which is what makes its staged pages reachable. It may run more than
# once and from more than one process, so it is safe to repeat.
def resolve_part(mut c: Ctx, i: Int) raises -> Int32:
    ref fdb = _fdb(c.fdb_addr)[]
    var idx = c.g_files[i]
    var staged = c.g_txids[i]
    ref f = c.files[idx]
    if staged <= f.head:
        return 0  # already resolved by somebody
    var r = Int32(0)
    while True:
        var t = Txn(fdb)
        var code = head_body(fdb, t, f, staged)
        r = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
        if r == -1:
            continue
        break
    if r != 0:
        return r
    f.head = staged
    f.sent_size = f.size
    f.log_pages += len(f.pgnos)
    f.trunc_pages = -1
    f.clear_dirty()
    return 0


def weft_txn_commit(ctx_addr: Int, txnid: Int) raises -> Int32:
    ref c = _ctx(ctx_addr)[]
    if not c.g_open or c.g_txnid != txnid:
        return Int32(SQLITE_MISUSE)
    ref fdb = _fdb(c.fdb_addr)[]
    var r = Int32(0)
    while True:
        var t = Txn(fdb)
        var code = record_body(fdb, t, c, txnid)
        r = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
        if r == -1:
            continue
        break
    if r != 0:
        release_group(c)
        return r
    # Implicitly committed from here. Resolving moves the heads, and a failure to resolve is not
    # a failure to commit: the next open's recovery finishes it.
    var done = True
    for i in range(len(c.g_files)):
        if done and resolve_part(c, i) != 0:
            done = False
    if done:
        while True:
            var t = Txn(fdb)
            var code = set_status_body(fdb, t, txnid, TXN_COMMITTED)
            var r2 = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
            if r2 == -1:
                continue
            break
        # the record has done its work; keeping it would make the recovery sweep grow without bound
        while True:
            var t = Txn(fdb)
            var code = drop_record_body(fdb, t, txnid)
            var r3 = settle(fdb, t, code, True, Int32(SQLITE_IOERR_WRITE))
            if r3 == -1:
                continue
            break
    release_group(c)
    return 0


# Give up a group that was begun and not committed. No record was written, so there is nothing to
# decide: the staged pages are unreachable, and the next open clears them. A member's buffered
# pages stay, as in the C, so its next sync commits them in the ordinary way.
def weft_txn_abort(ctx_addr: Int, txnid: Int) raises -> Int32:
    ref c = _ctx(ctx_addr)[]
    if not c.g_open or c.g_txnid != txnid:
        return Int32(SQLITE_MISUSE)
    release_group(c)
    return 0


# ── sqlite3_io_methods ────────────────────────────────────────────────────────

def _file_ctx(file: Int) -> Pointer[Ctx, MutAnyOrigin]:
    return _ctx(peek64(file + 8))


def fdb_close(file: Int) abi("C") -> Int32:
    try:
        var idx = peek64(file + 16)
        var rc = do_flush(_file_ctx(file)[], idx)
        if rc == 0 and _file_ctx(file)[].files[idx].compact_due and _file_ctx(file)[].files[idx].group_txnid == 0:
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
    f.ra_count = 0
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


# How many pages the read-ahead windows have answered, and how many were filled, over every file.
def ra_hits_total(ctx_addr: Int) -> Int:
    var n = 0
    for i in range(len(_ctx(ctx_addr)[].files)):
        n += _ctx(ctx_addr)[].files[i].ra_hits
    return n


def ra_fills_total(ctx_addr: Int) -> Int:
    var n = 0
    for i in range(len(_ctx(ctx_addr)[].files)):
        n += _ctx(ctx_addr)[].files[i].ra_fills
    return n


# The pages the file's read-ahead window holds now, for the file a connection has open.
def ra_window_pages(lib: OwnedDLHandle, ctx_addr: Int, db: Int) raises -> Int:
    var slot = alloc[Int](1)
    slot[unsafe_offset=0] = 0
    var rc = lib.call["sqlite3_file_control", Int32](db, "main".unsafe_ptr(), Int32(SQLITE_FCNTL_FILE_POINTER), slot)
    var file = slot[unsafe_offset=0]
    slot.free()
    if rc != 0 or file == 0:
        return -1
    return _ctx(ctx_addr)[].files[peek64(file + 16)].ra_count
