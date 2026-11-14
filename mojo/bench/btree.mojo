# Direct B-tree reads against SQL reads, on one database, through SQLite's own file VFS or the
# Mojo VFS. The idea is the mojo-iouring submission's: a read that needs no SQL engine can walk
# the B-trees with SQLite's own cursor calls, inside a read transaction.
#
#   btree <db> <vfs> <iterations> [direct]
#
# Needs a SQLite built with its internals visible (the amalgamation with -DSQLITE_PRIVATE=),
# named by WEFT_SQLITE_LIB. A fifth word "direct" times only the B-tree reads, for a profile.
#
# Two reads, each done both ways on the same rows, with a checksum of every value read:
#   post by id   a posts row, the users row it names, and its like count (an index range)
#   feed         the 20 newest posts by rowid, each with its user and like count
#
# What keeps the direct path honest:
#   - SQLite's version is pinned. Another version does not run the direct path.
#   - The Btree comes from sqlite3DbNameToBtree, not from a struct offset.
#   - The direct path is checked against SQL on sampled rows and on the feed before it is timed.
#   - The feed is the reverse rowid order only while ids are dense and created_at never falls
#     with id. That is checked with SQL; a violation would turn the direct feed off.
#   - A record that spills to overflow pages is read whole with sqlite3BtreePayload.
#   - Planted faults must be caught: a row out of time order, a wrong decode.
#
# SPDX-License-Identifier: Apache-2.0 OR MIT
from std.ffi import OwnedDLHandle, _DLCallable
from std.memory import alloc
from std.os import getenv
from std.sys import argv
from std.time import perf_counter_ns
from vfs_mem import open_sqlite
from vfs_fdb import register_fdb

# The SQLite the signatures and sizes here were checked against: 3.50.4.
comptime TESTED_VERSION = 3050004
comptime MEM_SIZE = 56  # sizeof(Mem): the unpacked key's values sit this far apart
comptime SLOT = 65536  # one overflow buffer per cursor, so two records stay valid together
comptime INT64_MIN = -9223372036854775807 - 1


def open_db(lib: OwnedDLHandle, name: String, vfs: String) raises -> Int:
    var slot = alloc[Int](1)
    slot[unsafe_offset=0] = 0
    var n = name.copy()
    var v = vfs.copy()
    var rc = lib.call["sqlite3_open_v2", Int32](n.unsafe_ptr(), slot, Int32(6), v.unsafe_ptr())
    if rc != 0:
        raise Error("sqlite3_open_v2 rc " + String(rc))
    return slot[unsafe_offset=0]


# SQL as a pointer and a byte length: no terminator is relied on.
def exec(lib: OwnedDLHandle, db: Int, sql: String) raises:
    var at = Int(sql.unsafe_ptr())
    var end = at + sql.byte_length()
    var stmt = alloc[Int](1)
    var tail = alloc[Int](1)
    while at < end:
        stmt[unsafe_offset=0] = 0
        tail[unsafe_offset=0] = end
        var prc = lib.call["sqlite3_prepare_v2", Int32](db, at, Int32(end - at), stmt, tail)
        if prc != 0:
            raise Error("prepare rc " + String(prc))
        var h = stmt[unsafe_offset=0]
        at = tail[unsafe_offset=0]
        if h == 0:
            continue
        var rc = lib.call["sqlite3_step", Int32](h)
        while rc == 100:
            rc = lib.call["sqlite3_step", Int32](h)
        _ = lib.call["sqlite3_finalize", Int32](h)
        if rc != 101:
            raise Error("step rc " + String(rc))
    _ = sql.byte_length()


def prepare(lib: OwnedDLHandle, db: Int, sql: String) raises -> Int:
    var stmt = alloc[Int](1)
    stmt[unsafe_offset=0] = 0
    var rc = lib.call["sqlite3_prepare_v2", Int32](db, Int(sql.unsafe_ptr()), Int32(sql.byte_length()), stmt, 0)
    if rc != 0:
        raise Error("prepare rc " + String(rc))
    _ = sql.byte_length()
    return stmt[unsafe_offset=0]


def scalar(lib: OwnedDLHandle, db: Int, sql: String) raises -> Int:
    var h = prepare(lib, db, sql)
    _ = lib.call["sqlite3_step", Int32](h)
    var v = Int(lib.call["sqlite3_column_int64", Int64](h, Int32(0)))
    _ = lib.call["sqlite3_finalize", Int32](h)
    return v


def byte_at(base: Int, i: Int) -> Int:
    return Int(Pointer[UInt8, MutAnyOrigin](unsafe_from_address=base)[unsafe_offset=i])


def peek(addr: Int) -> Int:
    return Pointer[Int, MutAnyOrigin](unsafe_from_address=addr)[unsafe_offset=0]


def peek32(addr: Int) -> Int:
    return Int(Pointer[Int32, MutAnyOrigin](unsafe_from_address=addr)[unsafe_offset=0])


# A SQLite varint at an address: returns the value, and the byte count in `used`.
def varint(base: Int, mut used: Int) -> Int:
    var v = 0
    for i in range(8):
        var b = byte_at(base, i)
        v = (v << 7) | (b & 0x7F)
        if b < 128:
            used = i + 1
            return v
    v = (v << 8) | byte_at(base, 8)
    used = 9
    return v


# The column at index `want` of a record at `base`: its serial type, and the address of its bytes.
def column(base: Int, want: Int, mut ty: Int, mut at: Int):
    var used = 0
    var hdr = varint(base, used)
    var h = used
    var data = base + hdr
    var i = 0
    while h < hdr:
        var t = varint(base + h, used)
        h += used
        if i == want:
            ty = t
            at = data
            return
        if t >= 12:
            data += (t - 12) // 2
        elif t == 1:
            data += 1
        elif t == 2:
            data += 2
        elif t == 3:
            data += 3
        elif t == 4:
            data += 4
        elif t == 5:
            data += 6
        elif t == 6 or t == 7:
            data += 8
        i += 1
    ty = 0
    at = data


def as_int(ty: Int, at: Int) -> Int:
    if ty == 8:
        return 0
    if ty == 9:
        return 1
    var n = 0
    if ty == 1:
        n = 1
    elif ty == 2:
        n = 2
    elif ty == 3:
        n = 3
    elif ty == 4:
        n = 4
    elif ty == 5:
        n = 6
    elif ty == 6:
        n = 8
    var v = 0
    for i in range(n):
        v = (v << 8) | byte_at(at, i)
    if n > 0 and n < 8 and byte_at(at, 0) >= 128:
        v -= 1 << (8 * n)
    return v


def text_len(ty: Int) -> Int:
    return (ty - 13) // 2


def byte_sum(at: Int, n: Int) -> Int:
    var s = 0
    for i in range(n):
        s += byte_at(at, i)
    return s


# Where everything the direct path points at lives: plain addresses, so a struct can hold them.
struct State(Movable):
    var posts: Int  # cursor over posts
    var users: Int
    var likes_idx: Int  # cursor over likes_post_id_idx
    var res: Int  # an int for out-parameters
    var amt: Int
    var scratch: Int  # three overflow buffers
    var rec: Int  # the unpacked key for the likes index
    var mem0: Int
    var mem1: Int

    def __init__(out self):
        self.posts = 0
        self.users = 0
        self.likes_idx = 0
        self.res = Int(alloc[Int32](2))
        self.amt = Int(alloc[Int32](2))
        self.scratch = Int(alloc[UInt8](3 * SLOT))
        self.rec = 0
        self.mem0 = 0
        self.mem1 = 0


# Open the three cursors under a read transaction, and the key the likes index is searched with.
def open_state(
    lib: OwnedDLHandle, db: Int, posts_root: Int, users_root: Int, idx_root: Int
) raises -> State:
    var bt = lib.call["sqlite3DbNameToBtree", Int](db, "main".unsafe_ptr())
    if bt == 0:
        raise Error("sqlite3DbNameToBtree found no main database")
    var brc = lib.call["sqlite3BtreeBeginTrans", Int32](bt, Int32(0), 0)
    if brc != 0:
        raise Error("BtreeBeginTrans rc " + String(brc))
    var s = State()
    var cur_size = Int(lib.call["sqlite3BtreeCursorSize", Int32]())
    s.posts = Int(alloc[UInt8](cur_size))
    s.users = Int(alloc[UInt8](cur_size))
    s.likes_idx = Int(alloc[UInt8](cur_size))
    for c in range(3):
        var cur = s.posts if c == 0 else (s.users if c == 1 else s.likes_idx)
        for i in range(cur_size):
            Pointer[UInt8, MutAnyOrigin](unsafe_from_address=cur)[unsafe_offset=i] = 0
        lib.call["sqlite3BtreeCursorZero", NoneType](cur)
    var ki = lib.call["sqlite3KeyInfoAlloc", Int](db, Int32(2), Int32(0))
    var cr = lib.call["sqlite3BtreeCursor", Int32](bt, Int32(posts_root), Int32(0), 0, s.posts)
    cr += lib.call["sqlite3BtreeCursor", Int32](bt, Int32(users_root), Int32(0), 0, s.users)
    cr += lib.call["sqlite3BtreeCursor", Int32](bt, Int32(idx_root), Int32(0), ki, s.likes_idx)
    if cr != 0:
        raise Error("BtreeCursor failed")
    s.rec = lib.call["sqlite3VdbeAllocUnpackedRecord", Int](ki)
    s.mem0 = peek(s.rec + 8)  # UnpackedRecord.aMem, the second field
    s.mem1 = s.mem0 + MEM_SIZE
    # AllocUnpackedRecord leaves its values uninitialized. SetInt64 reads the old flags to see
    # whether there is memory to release, so start each as a NULL that owns none (MEM_Null = 1).
    lib.call["sqlite3VdbeMemInit", NoneType](s.mem0, db, Int32(1))
    lib.call["sqlite3VdbeMemInit", NoneType](s.mem1, db, Int32(1))
    return s^


def close_state(lib: OwnedDLHandle, s: State):
    _ = lib.call["sqlite3BtreeCloseCursor", Int32](s.posts)
    _ = lib.call["sqlite3BtreeCloseCursor", Int32](s.users)
    _ = lib.call["sqlite3BtreeCloseCursor", Int32](s.likes_idx)


# The whole record under the cursor. It is on the page when it fits, and read through the overflow
# pages into the cursor's own buffer when it does not.
def row_at(
    size: _DLCallable[UInt32, _], fetch: _DLCallable[Int, _], payload: _DLCallable[Int32, _],
    s: State, cur: Int, slot: Int,
) raises -> Int:
    # PayloadSize parses the cell first, which PayloadFetch needs
    var total = Int(size(cur))
    var p = fetch(cur, s.amt)
    if peek32(s.amt) >= total:
        return p
    if total > SLOT:
        raise Error("a record of " + String(total) + " bytes does not fit the overflow buffer")
    var buf = s.scratch + slot * SLOT
    var rc = payload(cur, Int32(0), Int32(total), buf)
    if rc != 0:
        raise Error("BtreePayload rc " + String(rc))
    return buf


def seek(moveto: _DLCallable[Int32, _], s: State, cur: Int, rowid: Int) raises -> Bool:
    var rc = moveto(cur, Int64(rowid), Int32(0), s.res)
    if rc != 0:
        raise Error("TableMoveto rc " + String(rc))
    return peek32(s.res) == 0


# How many likes name this post: the entries of likes_post_id_idx whose first column is the id.
# The search key is (post_id, the smallest integer), which sorts before every entry of the post.
def count_likes(
    size: _DLCallable[UInt32, _], fetch: _DLCallable[Int, _], payload: _DLCallable[Int32, _],
    setint: _DLCallable[Int32, _], idxmoveto: _DLCallable[Int32, _], next: _DLCallable[Int32, _],
    s: State, post_id: Int,
) raises -> Int:
    _ = setint(s.mem0, Int64(post_id))
    _ = setint(s.mem1, Int64(INT64_MIN))
    var rc = idxmoveto(s.likes_idx, s.rec, s.res)
    if rc != 0:
        raise Error("IndexMoveto rc " + String(rc))
    var n = 0
    if peek32(s.res) < 0:
        if next(s.likes_idx, Int32(0)) != 0:
            return 0
    while True:
        var p = row_at(size, fetch, payload, s, s.likes_idx, 2)
        var ty = 0
        var at = 0
        column(p, 0, ty, at)
        if as_int(ty, at) != post_id:
            break
        n += 1
        if next(s.likes_idx, Int32(0)) != 0:
            break
    return n


# user_id, the body's length and bytes, and the username's length, for the post record `p`.
def post_sum(
    size: _DLCallable[UInt32, _], fetch: _DLCallable[Int, _], payload: _DLCallable[Int32, _],
    moveto: _DLCallable[Int32, _], s: State, p: Int,
) raises -> Int:
    var ty = 0
    var at = 0
    column(p, 1, ty, at)
    var uid = as_int(ty, at)
    var sum = uid
    column(p, 2, ty, at)
    sum += text_len(ty) + byte_sum(at, text_len(ty))
    if not seek(moveto, s, s.users, uid):
        return -1
    var u = row_at(size, fetch, payload, s, s.users, 1)
    column(u, 1, ty, at)
    sum += text_len(ty)
    return sum


def direct_post(
    size: _DLCallable[UInt32, _], fetch: _DLCallable[Int, _], payload: _DLCallable[Int32, _],
    moveto: _DLCallable[Int32, _], setint: _DLCallable[Int32, _], idxmoveto: _DLCallable[Int32, _],
    next: _DLCallable[Int32, _], s: State, id: Int,
) raises -> Int:
    if not seek(moveto, s, s.posts, id):
        return -1
    var p = row_at(size, fetch, payload, s, s.posts, 0)
    var sum = post_sum(size, fetch, payload, moveto, s, p)
    return sum + count_likes(size, fetch, payload, setint, idxmoveto, next, s, id)


def direct_feed(
    size: _DLCallable[UInt32, _], fetch: _DLCallable[Int, _], payload: _DLCallable[Int32, _],
    moveto: _DLCallable[Int32, _], setint: _DLCallable[Int32, _], idxmoveto: _DLCallable[Int32, _],
    next: _DLCallable[Int32, _], last: _DLCallable[Int32, _], prev: _DLCallable[Int32, _],
    keyof: _DLCallable[Int64, _], s: State,
) raises -> Int:
    var rc = last(s.posts, s.res)
    var sum = 0
    for _ in range(20):
        var p = row_at(size, fetch, payload, s, s.posts, 0)
        var id = Int(keyof(s.posts))
        sum += post_sum(size, fetch, payload, moveto, s, p)
        sum += count_likes(size, fetch, payload, setint, idxmoveto, next, s, id)
        rc = prev(s.posts, Int32(0))
        if rc != 0:
            break
    return sum


# user_id, the body's length and bytes, the username's length, and the like count.
def sql_cols(
    col_int: _DLCallable[Int64, _], col_text: _DLCallable[Int, _], col_bytes: _DLCallable[Int32, _], h: Int
) -> Int:
    var sum = Int(col_int(h, Int32(2)))
    var body = col_text(h, Int32(1))
    var bl = Int(col_bytes(h, Int32(1)))
    sum += bl + byte_sum(body, bl)
    _ = col_text(h, Int32(3))
    sum += Int(col_bytes(h, Int32(3)))
    sum += Int(col_int(h, Int32(4)))
    return sum


def ops(n: Int, ns: Int) -> Int:
    return Int(Float64(n) * 1.0e9 / Float64(ns))


def main() raises:
    var args = argv()
    if len(args) < 4:
        raise Error("usage: btree <db> <vfs> <iterations> [direct]")
    var dbname = String(args[1])
    var vfs = String(args[2])
    var iters = Int(String(args[3]))
    var only_direct = len(args) > 4 and String(args[4]) == "direct"
    var lib = open_sqlite()
    var version = Int(lib.call["sqlite3_libversion_number", Int32]())
    if version != TESTED_VERSION:
        print("direct path off: SQLite is " + String(version) + " and it was checked against " + String(TESTED_VERSION))
        return
    if vfs != "unix":
        var cluster = getenv("WEFT_FDB_CLUSTER_FILE")
        if cluster.byte_length() == 0:
            cluster = "/etc/foundationdb/fdb.cluster"
        _ = register_fdb(lib, vfs, cluster, False)
    var db = open_db(lib, dbname, vfs)
    exec(lib, db, "pragma journal_mode=memory; pragma locking_mode=exclusive; pragma cache_size=-32768; pragma mmap_size=0")
    exec(lib, db, "create table users (id integer primary key, username text not null unique, created_at text not null); create table posts (id integer primary key, user_id integer not null, body text not null, created_at text not null); create table likes (user_id integer not null, post_id integer not null, created_at text not null, primary key (user_id, post_id)); create index likes_post_id_idx on likes (post_id); create index posts_created_at_id_idx on posts (created_at desc, id desc)")
    exec(lib, db, "begin; with recursive c(x) as (select 1 union all select x+1 from c where x<5000) insert into users select x, 'user' || x, printf('2026-01-01T00:00:%06d', x) from c; with recursive c(x) as (select 1 union all select x+1 from c where x<20000) insert into posts select x, 1 + (x * 7919) % 5000, 'post number ' || x || ' ' || hex(randomblob(40)), printf('2026-01-01T%02d:%02d:%02d', x / 3600, (x / 60) % 60, x % 60) from c; with recursive c(x) as (select 0 union all select x+1 from c where x<39999) insert or ignore into likes select 1 + (x * 31) % 5000, 1 + (x * x) % 20000, '2026-01-01' from c; commit")

    var f_size = lib.get_function[UInt32]("sqlite3BtreePayloadSize")
    var f_fetch = lib.get_function[Int]("sqlite3BtreePayloadFetch")
    var f_payload = lib.get_function[Int32]("sqlite3BtreePayload")
    var f_moveto = lib.get_function[Int32]("sqlite3BtreeTableMoveto")
    var f_idxmoveto = lib.get_function[Int32]("sqlite3BtreeIndexMoveto")
    var f_next = lib.get_function[Int32]("sqlite3BtreeNext")
    var f_last = lib.get_function[Int32]("sqlite3BtreeLast")
    var f_prev = lib.get_function[Int32]("sqlite3BtreePrevious")
    var f_keyof = lib.get_function[Int64]("sqlite3BtreeIntegerKey")
    var f_setint = lib.get_function[Int32]("sqlite3VdbeMemSetInt64")
    var f_bind = lib.get_function[Int32]("sqlite3_bind_int64")
    var f_step = lib.get_function[Int32]("sqlite3_step")
    var f_reset = lib.get_function[Int32]("sqlite3_reset")
    var f_cint = lib.get_function[Int64]("sqlite3_column_int64")
    var f_ctext = lib.get_function[Int]("sqlite3_column_text")
    var f_cbytes = lib.get_function[Int32]("sqlite3_column_bytes")

    # root pages, from the schema
    var rp = prepare(lib, db, "select name, rootpage from sqlite_master where name in ('posts','users','likes_post_id_idx')")
    var posts_root = 0
    var users_root = 0
    var idx_root = 0
    while f_step(rp) == 100:
        var nm = f_ctext(rp, Int32(0))
        var root = Int(f_cint(rp, Int32(1)))
        if byte_at(nm, 0) == 112:  # posts
            posts_root = root
        elif byte_at(nm, 0) == 117:  # users
            users_root = root
        else:
            idx_root = root
    _ = lib.call["sqlite3_finalize", Int32](rp)

    var by_id = prepare(lib, db, "select p.id, p.body, p.user_id, u.username, (select count(*) from likes l where l.post_id = p.id) from posts p join users u on u.id = p.user_id where p.id = ?1")
    var feed = prepare(lib, db, "select p.id, p.body, p.user_id, u.username, (select count(*) from likes l where l.post_id = p.id) from posts p join users u on u.id = p.user_id order by p.created_at desc, p.id desc limit 20")

    # a read transaction, then the B-trees under it
    exec(lib, db, "begin")
    var s = open_state(lib, db, posts_root, users_root, idx_root)
    var failures = 0

    # 1. the direct path agrees with SQL on sampled posts and on the feed
    var bad = 0
    for k in range(1, 2001):
        var id = 1 + (k * 7) % 20000
        _ = f_bind(by_id, Int32(1), Int64(id))
        _ = f_step(by_id)
        var a = sql_cols(f_cint, f_ctext, f_cbytes, by_id)
        _ = f_reset(by_id)
        if a != direct_post(f_size, f_fetch, f_payload, f_moveto, f_setint, f_idxmoveto, f_next, s, id):
            bad += 1
    print("agree: post by id " + String(2000 - bad) + " of 2000")
    if bad != 0:
        failures += 1
    var fa = 0
    while f_step(feed) == 100:
        fa += sql_cols(f_cint, f_ctext, f_cbytes, feed)
    _ = f_reset(feed)
    var fb = direct_feed(f_size, f_fetch, f_payload, f_moveto, f_setint, f_idxmoveto, f_next, f_last, f_prev, f_keyof, s)
    print("agree: feed " + String(fa == fb))
    if fa != fb:
        failures += 1

    # 2. the feed's ordering assumption, checked with SQL: dense ids, created_at never falling
    var dense = scalar(lib, db, "select count(*) = max(id) from posts")
    var inorder = scalar(lib, db, "select count(*) = 0 from posts a join posts b on b.id = a.id + 1 where b.created_at < a.created_at")
    print("ordering holds: dense ids " + String(dense == 1) + ", created_at in id order " + String(inorder == 1))
    if dense != 1 or inorder != 1:
        failures += 1

    # 3. planted faults. A post older than its predecessor must be seen by the ordering check.
    var seen = scalar(lib, db, "select count(*) > 0 from (select id, case when id = 100 then '2025-01-01' else created_at end c from posts) a join (select id, case when id = 100 then '2025-01-01' else created_at end c from posts) b on b.id = a.id + 1 where b.c < a.c")
    print("planted: a post older than its predecessor is seen by the ordering check: " + String(seen == 1))
    if seen != 1:
        failures += 1
    #    and a checksum one off must be told apart from the right one
    _ = f_bind(by_id, Int32(1), Int64(7))
    _ = f_step(by_id)
    var sql7 = sql_cols(f_cint, f_ctext, f_cbytes, by_id)
    _ = f_reset(by_id)
    var dir7 = direct_post(f_size, f_fetch, f_payload, f_moveto, f_setint, f_idxmoveto, f_next, s, 7)
    print("planted: a checksum one off is told apart: " + String(sql7 != dir7 + 1 and sql7 == dir7))
    if sql7 == dir7 + 1 or sql7 != dir7:
        failures += 1

    # 4. the timed reads
    var t0 = perf_counter_ns()
    var s1 = 0
    for k in range(0 if only_direct else iters):
        _ = f_bind(by_id, Int32(1), Int64(1 + (k * 7) % 20000))
        _ = f_step(by_id)
        s1 += sql_cols(f_cint, f_ctext, f_cbytes, by_id)
        _ = f_reset(by_id)
    var sql_id = Int(perf_counter_ns() - t0)
    t0 = perf_counter_ns()
    var s2 = 0
    for k in range(iters):
        s2 += direct_post(f_size, f_fetch, f_payload, f_moveto, f_setint, f_idxmoveto, f_next, s, 1 + (k * 7) % 20000)
    var dir_id = Int(perf_counter_ns() - t0)
    t0 = perf_counter_ns()
    var s3 = 0
    for _ in range(0 if only_direct else iters // 20):
        while f_step(feed) == 100:
            s3 += sql_cols(f_cint, f_ctext, f_cbytes, feed)
        _ = f_reset(feed)
    var sql_feed = Int(perf_counter_ns() - t0)
    t0 = perf_counter_ns()
    var s4 = 0
    for _ in range(iters // 20):
        s4 += direct_feed(f_size, f_fetch, f_payload, f_moveto, f_setint, f_idxmoveto, f_next, f_last, f_prev, f_keyof, s)
    var dir_feed = Int(perf_counter_ns() - t0)
    if not only_direct:
        print("checksums equal over the timed loops: " + String(s1 == s2) + " " + String(s3 == s4))
        if s1 != s2 or s3 != s4:
            failures += 1
        print("post by id   SQL " + String(ops(iters, sql_id)) + " ops/s   B-tree " + String(ops(iters, dir_id)) + " ops/s")
        print("feed (20)    SQL " + String(ops(iters // 20, sql_feed)) + " ops/s   B-tree " + String(ops(iters // 20, dir_feed)) + " ops/s")
    close_state(lib, s)
    exec(lib, db, "commit")

    # 5. an overflow record: a body of about 8 KB, larger than a page, read whole by both paths.
    #    This needs a write, so it comes after the read transaction.
    exec(lib, db, "insert into posts values (20001, 1, (select group_concat(hex(randomblob(500)), '') from (select 1 union all select 2 union all select 3 union all select 4 union all select 5 union all select 6 union all select 7 union all select 8)), '2026-12-31T00:00:00')")
    exec(lib, db, "begin")
    var s5 = open_state(lib, db, posts_root, users_root, idx_root)
    _ = f_bind(by_id, Int32(1), Int64(20001))
    _ = f_step(by_id)
    var big_len = Int(f_cbytes(by_id, Int32(1)))
    var sql_big = sql_cols(f_cint, f_ctext, f_cbytes, by_id)
    _ = f_reset(by_id)
    var dir_big = direct_post(f_size, f_fetch, f_payload, f_moveto, f_setint, f_idxmoveto, f_next, s5, 20001)
    print("overflow: a " + String(big_len) + " byte body, SQL and direct agree: " + String(sql_big == dir_big))
    if sql_big != dir_big or big_len < 4096:
        failures += 1
    close_state(lib, s5)
    exec(lib, db, "commit")
    _ = lib.call["sqlite3_close", Int32](db)
    print("direct path checks failed: " + String(failures))
    if failures != 0:
        raise Error("direct path checks failed")
