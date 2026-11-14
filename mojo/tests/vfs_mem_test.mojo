# Opens a database through the Mojo VFS and runs SQL on it. The checks are on what SQLite
# sees (rows, a second connection after close) and on what the store holds (pages written,
# a 4096-byte multiple), and that no file appeared on the local disk.
# SPDX-License-Identifier: Apache-2.0 OR MIT
from std.ffi import OwnedDLHandle
from std.memory import alloc
from std.os import path
from vfs_mem import *


def check(label: String, ok: Bool, mut failed: Int):
    if ok:
        print("ok   ", label)
    else:
        print("FAIL ", label)
        failed += 1


def open_db(lib: OwnedDLHandle, name: String, vfs: String) raises -> Int:
    var slot = alloc[Int](1)
    slot[unsafe_offset=0] = 0
    var n = name.copy()
    var v = vfs.copy()
    var rc = lib.call["sqlite3_open_v2", Int32](n.unsafe_ptr(), slot, 6, v.unsafe_ptr())  # READWRITE | CREATE
    if rc != 0:
        raise Error("sqlite3_open_v2 rc " + String(rc))
    return slot[unsafe_offset=0]


def run(lib: OwnedDLHandle, db: Int, sql: String) raises -> Int32:
    var s = sql.copy()
    return lib.call["sqlite3_exec", Int32](db, s.unsafe_ptr(), 0, 0, 0)


# One integer from a one-row query.
def scalar(lib: OwnedDLHandle, db: Int, sql: String) raises -> Int:
    var s = sql.copy()
    var stmt = alloc[Int](1)
    stmt[unsafe_offset=0] = 0
    var rc = lib.call["sqlite3_prepare_v2", Int32](db, s.unsafe_ptr(), -1, stmt, 0)
    if rc != 0:
        raise Error("prepare rc " + String(rc) + " for " + sql)
    var h = stmt[unsafe_offset=0]
    var step = lib.call["sqlite3_step", Int32](h)
    if step != 100:
        raise Error("step rc " + String(step))
    var v = lib.call["sqlite3_column_int64", Int64](h, 0)
    _ = lib.call["sqlite3_finalize", Int32](h)
    return Int(v)


def main() raises:
    var failed = 0
    var lib = open_sqlite()
    var store = register(lib, "weft_mojo", False)

    var db = open_db(lib, "actor-1.db", "weft_mojo")
    check("create table", run(lib, db, "create table t(id integer primary key, v text)") == 0, failed)
    check("insert 1000 rows", run(lib, db, "with recursive c(x) as (select 1 union all select x+1 from c where x<1000) insert into t select x, 'row-' || x from c") == 0, failed)
    check("count is 1000", scalar(lib, db, "select count(*) from t") == 1000, failed)
    check("sum is 500500", scalar(lib, db, "select sum(id) from t") == 500500, failed)
    check("an update lands", run(lib, db, "update t set v='changed' where id=7") == 0, failed)
    check("and reads back", scalar(lib, db, "select count(*) from t where v='changed'") == 1, failed)
    check("integrity_check is ok", scalar(lib, db, "select count(*) from pragma_integrity_check where integrity_check='ok'") == 1, failed)
    check("the rollback journal is deleted after a commit", store_file_size(store, "actor-1.db-journal") < 0, failed)
    var before = store_file_size(store, "actor-1.db")
    check("delete most rows", run(lib, db, "delete from t where id > 10") == 0, failed)
    check("vacuum shrinks the file through xTruncate", run(lib, db, "vacuum") == 0 and store_file_size(store, "actor-1.db") < before, failed)
    check("and the rows left are 10", scalar(lib, db, "select count(*) from t") == 10, failed)
    _ = lib.call["sqlite3_close", Int32](db)

    var size = store_file_size(store, "actor-1.db")
    print("store holds actor-1.db:", size, "bytes,", size // 4096, "pages")
    check("the store holds whole 4096-byte pages", size > 0 and size % 4096 == 0, failed)

    # a second connection, as a handoff would be: same store, nothing copied
    var db2 = open_db(lib, "actor-1.db", "weft_mojo")
    check("a second connection sees the 10 rows", scalar(lib, db2, "select count(*) from t") == 10, failed)
    check("and the update", scalar(lib, db2, "select count(*) from t where v='changed'") == 1, failed)
    _ = lib.call["sqlite3_close", Int32](db2)

    check("no local file was made", not path.exists("actor-1.db") and not path.exists("actor-1.db-journal"), failed)

    # a database that was never created through the store is refused when CREATE is absent
    var slot = alloc[Int](1)
    slot[unsafe_offset=0] = 0
    var nm = String("absent.db")
    var vf = String("weft_mojo")
    var rc = lib.call["sqlite3_open_v2", Int32](nm.unsafe_ptr(), slot, 2, vf.unsafe_ptr())  # READWRITE only
    var h = slot[unsafe_offset=0]
    var rc2 = Int32(0)
    if rc == 0:
        rc2 = run(lib, h, "select count(*) from sqlite_master")
    check("opening a missing database without CREATE fails", rc != 0 or rc2 != 0, failed)

    # The io methods called directly, for the cases SQL does not reach.
    var vfs = lib.call["sqlite3_vfs_find", Int](vf.unsafe_ptr())
    var fobj = alloc[UInt8](FILE_SIZE)
    var fa = Int(fobj)
    var nm2 = String("direct.bin")
    check("vfs_open creates with CREATE", vfs_open(vfs, Int(nm2.unsafe_ptr()), fa, 0x4, 0) == 0, failed)
    var wbuf = alloc[UInt8](32)
    for i in range(32):
        wbuf[unsafe_offset=i] = UInt8(i + 1)
    check("write 10 bytes", io_write(fa, Int(wbuf), 10, 0) == 0 and store_file_size(store, "direct.bin") == 10, failed)
    var rbuf = alloc[UInt8](32)
    for i in range(32):
        rbuf[unsafe_offset=i] = 0xEE
    check("a read past the end is a short read", io_read(fa, Int(rbuf), 20, 0) == Int32(SQLITE_IOERR_SHORT_READ), failed)
    var head_ok = True
    for i in range(10):
        head_ok = head_ok and rbuf[unsafe_offset=i] == UInt8(i + 1)
    var tail_zero = True
    for i in range(10, 20):
        tail_zero = tail_zero and rbuf[unsafe_offset=i] == 0
    check("a short read returns the bytes there and zeros after", head_ok and tail_zero, failed)
    check("a read inside the file is whole", io_read(fa, Int(rbuf), 10, 0) == 0, failed)
    check("truncate to 4", io_truncate(fa, 4) == 0 and store_file_size(store, "direct.bin") == 4, failed)
    check("vfs_delete removes it", vfs_delete(vfs, Int(nm2.unsafe_ptr()), 0) == 0 and store_file_size(store, "direct.bin") < 0, failed)
    var nm3 = String("never-made.bin")
    check("vfs_open without CREATE refuses a missing file", vfs_open(vfs, Int(nm3.unsafe_ptr()), fa, 0x2, 0) == Int32(SQLITE_CANTOPEN), failed)

    print()
    if failed > 0:
        raise Error(String(failed) + " check(s) failed")
    print("all checks passed")
