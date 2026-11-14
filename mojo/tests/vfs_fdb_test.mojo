# SQLite on a VFS written in Mojo whose files live in FoundationDB. Needs a cluster
# (WEFT_FDB_CLUSTER_FILE). The checks are on what SQLite sees, on what is in FoundationDB
# (the keys the C layout names), and on the fence refusing a second writer.
# SPDX-License-Identifier: Apache-2.0 OR MIT
from std.ffi import OwnedDLHandle
from std.memory import alloc
from std.os import getenv
from fdb_client import *
from fdb_keys import *
from vfs_mem import open_sqlite
from vfs_fdb import *


def check(label: String, ok: Bool, mut failed: Int):
    if ok:
        print("ok   ", label)
    else:
        print("FAIL ", label)
        failed += 1


def open_db(lib: OwnedDLHandle, name: String, vfs: String, flags: Int) raises -> Int:
    var slot = alloc[Int](1)
    slot[unsafe_offset=0] = 0
    var n = name.copy()
    var v = vfs.copy()
    var rc = lib.call["sqlite3_open_v2", Int32](n.unsafe_ptr(), slot, Int32(flags), v.unsafe_ptr())
    if rc != 0:
        raise Error("sqlite3_open_v2 rc " + String(rc))
    return slot[unsafe_offset=0]


def run(lib: OwnedDLHandle, db: Int, sql: String) raises -> Int32:
    var s = sql.copy()
    return lib.call["sqlite3_exec", Int32](db, s.unsafe_ptr(), 0, 0, 0)


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
        _ = lib.call["sqlite3_finalize", Int32](h)
        raise Error("step rc " + String(step) + " for " + sql)
    var v = lib.call["sqlite3_column_int64", Int64](h, 0)
    _ = lib.call["sqlite3_finalize", Int32](h)
    return Int(v)


def stored_u64(fdb: Fdb, key: List[UInt8]) raises -> Int:
    var t = Txn(fdb)
    var r = t.get_result(fdb, key)
    t.destroy(fdb)
    if r.present and len(r.value) == 8:
        return Int(get_be64(r.value, 0))
    return -1


def main() raises:
    var failed = 0
    var cluster = getenv("WEFT_FDB_CLUSTER_FILE")
    if cluster.byte_length() == 0:
        cluster = "/etc/foundationdb/fdb.cluster"
    var lib = open_sqlite()
    var ctx = register_fdb(lib, "weft_mojo_fdb", cluster, False)
    # a second client handle, to look at the store behind the VFS's back
    var name = String("mojo-vfs-actor")
    var obs = Fdb(cluster)
    var V = String("weft_mojo_fdb")

    # start clean
    var t0 = Txn(obs)
    t0.clear_range(obs, key_meta(name, ""), key_after(key_meta(name, "")))
    check("clear the test database", t0.commit(obs) == 0, failed)
    t0.destroy(obs)

    var db = open_db(lib, name, V, 6)
    check("an empty database has fence 1", stored_u64(obs, key_meta(name, "FENCE")) == 1, failed)
    # the two pragmas `fdb_vfs.c` says a caller must set
    check("journal_mode=MEMORY", run(lib, db, "pragma journal_mode=memory") == 0, failed)
    check("locking_mode=EXCLUSIVE", run(lib, db, "pragma locking_mode=exclusive") == 0, failed)
    check("create table", run(lib, db, "create table t(id integer primary key, v text)") == 0, failed)
    check("insert 1000 rows", run(lib, db, "with recursive c(x) as (select 1 union all select x+1 from c where x<1000) insert into t select x, 'row-' || x from c") == 0, failed)
    check("count is 1000", scalar(lib, db, "select count(*) from t") == 1000, failed)
    check("sum is 500500", scalar(lib, db, "select sum(id) from t") == 500500, failed)
    check("an update lands", run(lib, db, "update t set v='changed' where id=7") == 0, failed)
    check("integrity_check is ok", scalar(lib, db, "select count(*) from pragma_integrity_check where integrity_check='ok'") == 1, failed)

    # what FoundationDB holds: the layout `fdb_vfs.c` documents
    var head = stored_u64(obs, key_meta(name, "HEAD"))
    var size = stored_u64(obs, key_meta(name, "SIZE"))
    print("HEAD", head, "SIZE", size)
    check("HEAD advanced once per commit", head >= 3, failed)
    check("SIZE is whole pages", size > 0 and size % PAGE == 0, failed)
    var pages = size // PAGE
    var tp = Txn(obs)
    # pages are numbered from 0 in the layout: byte offset / 4096, so SQLite's header is page 0
    var p0 = tp.get_result(obs, key_pidx(name, 0))
    check("PIDX/0 names a txid at or below HEAD", p0.present and Int(get_be64(p0.value, 0)) <= head and Int(get_be64(p0.value, 0)) >= 1, failed)
    var owner = Int(get_be64(p0.value, 0))
    var row = tp.get_result(obs, key_delta(name, UInt64(owner), 0))
    check("DELTA/<owner>/0 is a whole 4096-byte page", row.present and len(row.value) == PAGE, failed)
    check("page 0 holds SQLite's header ('SQLite format 3', page size 4096 at byte 16)", row.present and row.value[0] == 0x53 and row.value[1] == 0x51 and row.value[15] == 0x00 and row.value[16] == 0x10 and row.value[17] == 0x00, failed)
    var p1 = tp.get_result(obs, key_pidx(name, 1))
    check("and PIDX/1 exists for the second page", p1.present, failed)
    var last = tp.get_result(obs, key_pidx(name, UInt32(pages - 1)))
    var beyond = tp.get_result(obs, key_pidx(name, UInt32(pages)))
    check("a PIDX row for the last page and none past it", last.present and not beyond.present, failed)
    tp.destroy(obs)
    _ = lib.call["sqlite3_close", Int32](db)

    # a handoff: close, open again, nothing copied
    var db2 = open_db(lib, name, V, 6)
    check("reopening raises the fence to 2", stored_u64(obs, key_meta(name, "FENCE")) == 2, failed)
    check("the reopened database has 1000 rows", scalar(lib, db2, "select count(*) from t") == 1000, failed)
    check("the update reads back", scalar(lib, db2, "select count(*) from t where v='changed'") == 1, failed)

    # the fence: a second writer opens, so the first handle is refused
    var db3 = open_db(lib, name, V, 6)
    check("a third open raises the fence to 3", stored_u64(obs, key_meta(name, "FENCE")) == 3, failed)
    var before = stored_u64(obs, key_meta(name, "HEAD"))
    var rc = run(lib, db2, "insert into t values (5000, 'stale writer')")
    check("the stale writer's commit is refused", rc != 0, failed)
    check("and HEAD did not move", stored_u64(obs, key_meta(name, "HEAD")) == before, failed)
    check("the new owner writes", run(lib, db3, "insert into t values (5001, 'owner')") == 0, failed)
    check("and HEAD moved", stored_u64(obs, key_meta(name, "HEAD")) > before, failed)
    _ = lib.call["sqlite3_close", Int32](db2)
    _ = lib.call["sqlite3_close", Int32](db3)

    # a read-only open takes no fence and sees the committed state
    var dbr = open_db(lib, name, V, 1)
    check("a read-only open leaves the fence at 3", stored_u64(obs, key_meta(name, "FENCE")) == 3, failed)
    check("and sees the owner's row", scalar(lib, dbr, "select count(*) from t where v='owner'") == 1, failed)
    check("the stale writer's row never landed", scalar(lib, dbr, "select count(*) from t where id=5000") == 0, failed)
    _ = lib.call["sqlite3_close", Int32](dbr)

    # a commit that never finished: pages staged above HEAD are cleared by the next open
    var th = stored_u64(obs, key_meta(name, "HEAD"))
    var ts = Txn(obs)
    ts.set(obs, key_delta(name, UInt64(th + 1), 77), List[UInt8](length=PAGE, fill=0xAA))
    check("stage an unfinished commit", ts.commit(obs) == 0, failed)
    ts.destroy(obs)
    var db4 = open_db(lib, name, V, 6)
    var tq = Txn(obs)
    check("opening drops the unfinished commit's pages", not tq.get_result(obs, key_delta(name, UInt64(th + 1), 77)).present, failed)
    tq.destroy(obs)
    _ = lib.call["sqlite3_close", Int32](db4)

    # leave nothing behind
    check("the database exists", stored_u64(obs, key_meta(name, "SIZE")) > 0, failed)
    var tdel = Txn(obs)
    tdel.clear_range(obs, key_meta(name, ""), key_after(key_meta(name, "")))
    check("clean up", tdel.commit(obs) == 0, failed)
    tdel.destroy(obs)

    obs.close()
    print()
    if failed > 0:
        raise Error(String(failed) + " check(s) failed")
    print("all checks passed")
