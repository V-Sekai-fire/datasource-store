# The sqllogictest corpus, run as a difference test on the VFS.
#
#   slt <file.test> <db> <vfs> <pragmas>
#
# sqllogictest is SQLite's own cross-engine suite. Each record is a statement or a query. This
# runner does not compare against the file's expected results, which test SQLite. It prints one
# line per record, the outcome and a hash of every value the record returned, so the same file run
# through SQLite's own file VFS ("unix") and through the Mojo VFS ("weft_mojo_fdb") can be diffed.
# Any line that differs is the VFS changing what SQLite answers.
#
# SQL goes to SQLite as a pointer and a byte length, never a terminator.
#
# SPDX-License-Identifier: Apache-2.0 OR MIT
from std.ffi import OwnedDLHandle
from std.memory import alloc
from std.os import getenv
from std.sys import argv
from std.time import perf_counter_ns
from vfs_mem import open_sqlite
from vfs_fdb import register_fdb
from fdb_client import Fdb, Txn


def open_db(lib: OwnedDLHandle, name: String, vfs: String) raises -> Int:
    var slot = alloc[Int](1)
    slot[unsafe_offset=0] = 0
    var n = name.copy()
    var v = vfs.copy()
    var rc = lib.call["sqlite3_open_v2", Int32](n.unsafe_ptr(), slot, Int32(6), v.unsafe_ptr())
    if rc != 0:
        raise Error("sqlite3_open_v2 rc " + String(rc))
    return slot[unsafe_offset=0]


def byte_at(base: Int, i: Int) -> UInt8:
    return Pointer[UInt8, MutAnyOrigin](unsafe_from_address=base)[unsafe_offset=i]


# FNV-1a over a run of bytes at an address.
def mix(h: UInt64, base: Int, n: Int) -> UInt64:
    var x = h
    for i in range(n):
        x = (x ^ UInt64(byte_at(base, i))) * UInt64(1099511628211)
    return x


def mix_text(h: UInt64, s: String) -> UInt64:
    return mix(h, Int(s.unsafe_ptr()), s.byte_length())


# Does the line at [s, e) start with `lit`?
def starts(base: Int, s: Int, e: Int, lit: String) -> Bool:
    var n = lit.byte_length()
    if e - s < n:
        return False
    var p = Int(lit.unsafe_ptr())
    for i in range(n):
        if byte_at(base, s + i) != byte_at(p, i):
            return False
    return True


# One record. Returns "ok", "error" or "rows <n> <hash>". A query hashes the type of each value
# and the value: integers as text, floats as SQLite's own double, text and blobs byte for byte.
def run_record(lib: OwnedDLHandle, db: Int, at: Int, nbyte: Int) raises -> String:
    var stmt = alloc[Int](1)
    stmt[unsafe_offset=0] = 0
    var prc = lib.call["sqlite3_prepare_v2", Int32](db, at, Int32(nbyte), stmt, 0)
    if prc != 0:
        return String("error")
    var h = stmt[unsafe_offset=0]
    if h == 0:
        return String("ok")
    var hash = UInt64(14695981039346656037)
    var rows = 0
    var rc = lib.call["sqlite3_step", Int32](h)
    while rc == 100:
        var nc = Int(lib.call["sqlite3_column_count", Int32](h))
        for c in range(nc):
            var t = Int(lib.call["sqlite3_column_type", Int32](h, Int32(c)))
            hash = mix_text(hash, String(t) + ":")
            if t == 1:
                hash = mix_text(hash, String(lib.call["sqlite3_column_int64", Int64](h, Int32(c))))
            elif t == 2:
                hash = mix_text(hash, String(lib.call["sqlite3_column_double", Float64](h, Int32(c))))
            elif t == 3 or t == 4:
                var p = Int(0)
                if t == 3:
                    p = lib.call["sqlite3_column_text", Int](h, Int32(c))
                else:
                    p = lib.call["sqlite3_column_blob", Int](h, Int32(c))
                var n = Int(lib.call["sqlite3_column_bytes", Int32](h, Int32(c)))
                hash = mix(hash, p, n)
            hash = mix_text(hash, String(","))
        rows += 1
        rc = lib.call["sqlite3_step", Int32](h)
    _ = lib.call["sqlite3_finalize", Int32](h)
    if rc != 101:
        return String("error")
    return "rows " + String(rows) + " " + String(hash)


def main() raises:
    var args = argv()
    if len(args) < 5:
        raise Error("usage: slt <file.test> <db> <vfs> <pragmas>")
    var path = String(args[1])
    var dbname = String(args[2])
    var vfs = String(args[3])
    var pragmas = String(args[4])
    var lib = open_sqlite()
    if vfs != "unix":
        var cluster = getenv("WEFT_FDB_CLUSTER_FILE")
        if cluster.byte_length() == 0:
            cluster = "/etc/foundationdb/fdb.cluster"
        _ = register_fdb(lib, vfs, cluster, False)
    # FoundationDB's own clock, read through our client: versions advance about 1,000,000 a second
    var clock_fdb = Optional[Fdb]()
    var v_start = -1
    if vfs != "unix":
        var cf = getenv("WEFT_FDB_CLUSTER_FILE")
        if cf.byte_length() == 0:
            cf = "/etc/foundationdb/fdb.cluster"
        clock_fdb = Fdb(cf)
        ref cl = clock_fdb.value()
        var tv = Txn(cl)
        v_start = tv.read_version(cl)
        tv.destroy(cl)
    var db = open_db(lib, dbname, vfs)
    var pg = pragmas.copy()
    if pg.byte_length() > 0:
        var pstmt = alloc[Int](1)
        var ptail = alloc[Int](1)
        var pat = Int(pg.unsafe_ptr())
        var pend = pat + pg.byte_length()
        while pat < pend:
            pstmt[unsafe_offset=0] = 0
            ptail[unsafe_offset=0] = pend
            _ = lib.call["sqlite3_prepare_v2", Int32](db, pat, Int32(pend - pat), pstmt, ptail)
            var ph = pstmt[unsafe_offset=0]
            pat = ptail[unsafe_offset=0]
            if ph != 0:
                _ = lib.call["sqlite3_step", Int32](ph)
                _ = lib.call["sqlite3_finalize", Int32](ph)

    var t_start = perf_counter_ns()
    var content = open(path, "r").read()
    var base = Int(content.unsafe_ptr())
    var total = content.byte_length()
    # line starts and ends
    var ls = List[Int]()
    var le = List[Int]()
    var s = 0
    for i in range(total):
        if byte_at(base, i) == 10:
            ls.append(s)
            # the corpus has CRLF line ends: a blank line is "\r", and must read as blank
            if i > s and byte_at(base, i - 1) == 13:
                le.append(i - 1)
            else:
                le.append(i)
            s = i + 1
    if s < total:
        ls.append(s)
        le.append(total)
    var n = len(ls)
    var i = 0
    var skip = False
    var records = 0
    var failed = 0
    while i < n:
        var a = ls[i]
        var b = le[i]
        if b == a or byte_at(base, a) == 35:
            i += 1
            continue
        if starts(base, a, b, "skipif sqlite"):
            skip = True
            i += 1
            continue
        if starts(base, a, b, "onlyif ") and not starts(base, a, b, "onlyif sqlite"):
            skip = True
            i += 1
            continue
        if starts(base, a, b, "halt"):
            # "onlyif mssql" then "halt" stops that engine, not this one
            if skip:
                skip = False
                i += 1
                continue
            break
        var is_stmt = starts(base, a, b, "statement")
        var is_query = starts(base, a, b, "query")
        if not is_stmt and not is_query:
            i += 1
            continue
        var line = i + 1
        i += 1
        var sql_a = ls[i] if i < n else total
        var sql_e = sql_a
        while i < n and le[i] > ls[i] and not starts(base, ls[i], le[i], "----"):
            sql_e = le[i]
            i += 1
        if i < n and starts(base, ls[i], le[i], "----"):
            while i < n and le[i] > ls[i]:
                i += 1
        if skip:
            skip = False
            continue
        records += 1
        var out = run_record(lib, db, base + sql_a, sql_e - sql_a)
        if out == "error":
            failed += 1
        print(String(line) + " " + out)
    _ = lib.call["sqlite3_close", Int32](db)
    # `base` and `pat` are bare addresses, so nothing but this use keeps the buffers they point
    # into alive: Mojo ends a value's life at its last use, and a read through a freed buffer
    # gave each run different records.
    _ = content.byte_length()
    _ = pg.byte_length()
    print("records " + String(records) + " errors " + String(failed))
    # last line, so a diff can leave it out: the time this file took, in milliseconds
    print("elapsed_ms " + String(Int((perf_counter_ns() - t_start) // 1000000)))
    var fdb_ms = -1
    if clock_fdb:
        ref cl2 = clock_fdb.value()
        var tv2 = Txn(cl2)
        var v_end = tv2.read_version(cl2)
        tv2.destroy(cl2)
        if v_start >= 0 and v_end >= 0:
            fdb_ms = (v_end - v_start) // 1000
    print("fdb_ms " + String(fdb_ms))
