# The benchmark driver in Mojo: plain SQLite or the Mojo FoundationDB VFS, running a plan file.
#
#   bench <plan> <db> <vfs> <pragmas> <label>
#
# <vfs> is "unix" for SQLite's own file VFS, or "weft_mojo_fdb" for the Mojo VFS (registered
# here). Output has the same columns as bench_c.c, from the same plan.
#
# SPDX-License-Identifier: Apache-2.0 OR MIT
from std.ffi import OwnedDLHandle
from std.memory import alloc
from std.os import getenv
from std.sys import argv
from std.time import perf_counter_ns
from vfs_mem import open_sqlite
from vfs_fdb import register_fdb


def open_db(lib: OwnedDLHandle, name: String, vfs: String) raises -> Int:
    var slot = alloc[Int](1)
    slot[unsafe_offset=0] = 0
    var n = name.copy()
    var v = vfs.copy()
    var rc = lib.call["sqlite3_open_v2", Int32](n.unsafe_ptr(), slot, Int32(6), v.unsafe_ptr())
    if rc != 0:
        raise Error("sqlite3_open_v2 rc " + String(rc))
    return slot[unsafe_offset=0]


# SQL is a pascal string here: a pointer and a byte length, never a terminator. A String cut out
# of a larger one need not end in NUL, so every SQLite call takes the length (nByte) and walks a
# multi-statement text by the tail pointer SQLite hands back.
def run(lib: OwnedDLHandle, db: Int, sql: String) raises:
    var at = Int(sql.unsafe_ptr())
    var end = at + sql.byte_length()
    var stmt = alloc[Int](1)
    var tail = alloc[Int](1)
    while at < end:
        stmt[unsafe_offset=0] = 0
        tail[unsafe_offset=0] = end
        var prc = lib.call["sqlite3_prepare_v2", Int32](db, at, Int32(end - at), stmt, tail)
        if prc != 0:
            raise Error("prepare rc " + String(prc) + ": " + String(sql[byte=0:min(120, sql.byte_length())]))
        var h = stmt[unsafe_offset=0]
        at = tail[unsafe_offset=0]
        if h == 0:
            continue  # white space or a comment
        var rc = lib.call["sqlite3_step", Int32](h)
        while rc == 100:
            rc = lib.call["sqlite3_step", Int32](h)
        _ = lib.call["sqlite3_finalize", Int32](h)
        if rc != 101:
            raise Error("step rc " + String(rc) + ": " + String(sql[byte=0:min(120, sql.byte_length())]))


def scalar(lib: OwnedDLHandle, db: Int, sql: String) raises -> Int:
    var stmt = alloc[Int](1)
    stmt[unsafe_offset=0] = 0
    _ = lib.call["sqlite3_prepare_v2", Int32](db, Int(sql.unsafe_ptr()), Int32(sql.byte_length()), stmt, 0)
    var h = stmt[unsafe_offset=0]
    _ = lib.call["sqlite3_step", Int32](h)
    var v = lib.call["sqlite3_column_int64", Int64](h, 0)
    _ = lib.call["sqlite3_finalize", Int32](h)
    return Int(v)


def main() raises:
    var args = argv()
    if len(args) < 6:
        raise Error("usage: bench <plan> <db> <vfs> <pragmas> <label>")
    var plan = String(args[1])
    var path = String(args[2])
    var vfs = String(args[3])
    var pragmas = String(args[4])
    var label = String(args[5])

    var lib = open_sqlite()
    if vfs != "unix":
        var cluster = getenv("WEFT_FDB_CLUSTER_FILE")
        if cluster.byte_length() == 0:
            cluster = "/etc/foundationdb/fdb.cluster"
        _ = register_fdb(lib, vfs, cluster, False)
    var db = open_db(lib, path, vfs)
    run(lib, db, pragmas)

    var text: String
    with open(plan, "r") as f:
        text = f.read()
    for raw in text.split("\n"):
        if raw.byte_length() == 0:
            continue
        # kind|name|iterations|per transaction|sql, and the sql may hold a '|'
        var parts = String(raw).split("|", 4)
        if len(parts) < 5:
            continue
        var kind = String(parts[0])
        var name = String(parts[1])
        var iters = Int(String(parts[2]))
        var per = Int(String(parts[3]))
        var sql = String(parts[4])

        var t0 = perf_counter_ns()
        if kind == "exec":
            run(lib, db, "BEGIN")
            run(lib, db, sql)
            run(lib, db, "COMMIT")
            iters = 1
        else:
            var stmt = alloc[Int](1)
            stmt[unsafe_offset=0] = 0
            var prc = lib.call["sqlite3_prepare_v2", Int32](db, Int(sql.unsafe_ptr()), Int32(sql.byte_length()), stmt, 0)
            if prc != 0:
                raise Error("prepare rc " + String(prc))
            var h = stmt[unsafe_offset=0]
            # Resolved once. `lib.call` looks the symbol up on every call, and a feed takes 21
            # steps; a dtrace profile put a quarter of this driver's time in dyld doing that.
            var f_step = lib.get_function[Int32]("sqlite3_step")
            var f_reset = lib.get_function[Int32]("sqlite3_reset")
            for i in range(iters):
                if per > 1 and i % per == 0:
                    run(lib, db, "BEGIN")
                while f_step(h) == 100:
                    pass
                if f_reset(h) != 0:
                    raise Error("step failed")
                if per > 1 and (i % per == per - 1 or i == iters - 1):
                    run(lib, db, "COMMIT")
            _ = lib.call["sqlite3_finalize", Int32](h)
        var dt = Float64(perf_counter_ns() - t0) * 1e-9
        print(label, name, iters, dt, Float64(iters) / dt, dt / Float64(iters) * 1e6, sep="\t")

    var u = scalar(lib, db, "select count(*) from users")
    var p = scalar(lib, db, "select count(*) from posts")
    var l = scalar(lib, db, "select count(*) from likes")
    print(label, "rows", String(u) + "/" + String(p) + "/" + String(l), sep="\t")
    # closing pays a fold that is owed: the log has grown as large as the base
    var tc = perf_counter_ns()
    _ = lib.call["sqlite3_close", Int32](db)
    var dc = Float64(perf_counter_ns() - tc) * 1e-9
    print(label, "close (pays the owed fold)", 1, dc, 1.0 / dc, dc * 1e6, sep="\t")
