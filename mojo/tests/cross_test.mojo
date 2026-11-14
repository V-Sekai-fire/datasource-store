# One step of the cross test: the Mojo VFS and the C VFS on the same FoundationDB store. The
# step comes from CROSS_STEP, and tests/cross.sh runs the steps in turn with the C `sqlrun`
# between them. A step prints a line per check and exits non-zero if one fails.
#
#   clean    clear both databases
#   write-m  Mojo creates cross-m.db: 1,500 rows ('m-<id>')
#   read-m   Mojo reads cross-m.db after the C folded and extended it: 2,000 rows
#   read-c   Mojo reads cross-c.db, which the C wrote, folded, then updated: 3,000 rows and 20
#            updates, the first as pages in a shard and the second as deltas against it; Mojo then
#            appends 1,000 rows of its own, as deltas against the C's bases
#
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


def open_db(lib: OwnedDLHandle, name: String, vfs: String) raises -> Int:
    var slot = alloc[Int](1)
    slot[unsafe_offset=0] = 0
    var n = name.copy()
    var v = vfs.copy()
    var rc = lib.call["sqlite3_open_v2", Int32](n.unsafe_ptr(), slot, Int32(6), v.unsafe_ptr())
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


def integrity_ok(lib: OwnedDLHandle, db: Int) raises -> Bool:
    return scalar(lib, db, "select count(*) from pragma_integrity_check where integrity_check='ok'") == 1


def pragmas(lib: OwnedDLHandle, db: Int) raises:
    _ = run(lib, db, "pragma journal_mode=memory")
    _ = run(lib, db, "pragma locking_mode=exclusive")


def main() raises:
    var failed = 0
    var step = getenv("CROSS_STEP")
    var cluster = getenv("WEFT_FDB_CLUSTER_FILE")
    if cluster.byte_length() == 0:
        cluster = "/etc/foundationdb/fdb.cluster"
    var lib = open_sqlite()
    var V = String("weft_mojo_fdb")
    var ctx = register_fdb(lib, V, cluster, False)

    if step == "clean":
        var obs = Fdb(cluster)
        var t = Txn(obs)
        for name in List[String](["cross-m.db", "cross-c.db", "eq.db", "cross-g1.db", "cross-g2.db"]):
            t.clear_range(obs, key_meta(name, ""), key_after(key_meta(name, "")))
        check("clear both databases", t.commit(obs) == 0, failed)
        t.destroy(obs)
    elif step == "write-m":
        var db = open_db(lib, "cross-m.db", V)
        pragmas(lib, db)
        check("create table", run(lib, db, "create table t(id integer primary key, v text)") == 0, failed)
        check("insert 1500 rows", run(lib, db, "with recursive c(x) as (select 1 union all select x+1 from c where x<1500) insert into t select x, 'm-' || x from c") == 0, failed)
        check("update a few rows, as a delta commit", run(lib, db, "update t set v='m-updated' where id % 300 = 0") == 0, failed)
        _ = lib.call["sqlite3_close", Int32](db)
    elif step == "group-m":
        # a group commit across two databases, started here; the C reads both afterwards
        var d1 = open_db(lib, "cross-g1.db", V)
        var d2 = open_db(lib, "cross-g2.db", V)
        pragmas(lib, d1)
        pragmas(lib, d2)
        check("create the two tables", run(lib, d1, "create table t(id integer primary key, v text)") == 0 and run(lib, d2, "create table t(id integer primary key, v text)") == 0, failed)
        var gid = 0
        check("begin a group", weft_txn_begin(ctx, gid) == 0, failed)
        check("join both", weft_txn_join(lib, ctx, d1, gid) == 0 and weft_txn_join(lib, ctx, d2, gid) == 0, failed)
        check("write 800 rows to each", run(lib, d1, "with recursive c(x) as (select 1 union all select x+1 from c where x<800) insert into t select x, 'g1-' || x from c") == 0 and run(lib, d2, "with recursive c(x) as (select 1 union all select x+1 from c where x<800) insert into t select x, 'g2-' || x from c") == 0, failed)
        check("commit the group", weft_txn_commit(ctx, gid) == 0, failed)
        _ = lib.call["sqlite3_close", Int32](d1)
        _ = lib.call["sqlite3_close", Int32](d2)
    elif step == "read-m":
        # the C read this database, appended 500 rows, and folded it into a shard on close
        var db = open_db(lib, "cross-m.db", V)
        pragmas(lib, db)
        check("2000 rows: Mojo's 1500 and the C's 500", scalar(lib, db, "select count(*) from t") == 2000, failed)
        check("the sum of the ids is 6251000", scalar(lib, db, "select sum(id) from t") == 6251000, failed)
        check("Mojo's update survived the C's fold", scalar(lib, db, "select count(*) from t where v='m-updated'") == 5, failed)
        check("the C's rows are there", scalar(lib, db, "select count(*) from t where v like 'c-%'") == 500, failed)
        check("integrity_check is ok", integrity_ok(lib, db), failed)
        _ = lib.call["sqlite3_close", Int32](db)
    elif step == "read-c":
        var db = open_db(lib, "cross-c.db", V)
        pragmas(lib, db)
        check("3000 rows written by the C", scalar(lib, db, "select count(*) from t") == 3000, failed)
        check("the sum of the ids is 4501500", scalar(lib, db, "select sum(id) from t") == 4501500, failed)
        check("the C's 20 updates, written as deltas against its shard, read back", scalar(lib, db, "select count(*) from t where v='updated'") == 20, failed)
        check("integrity_check is ok", integrity_ok(lib, db), failed)
        check("Mojo appends 1000 rows", run(lib, db, "with recursive c(x) as (select 5001 union all select x+1 from c where x<6000) insert into t select x, 'mojo-' || x from c") == 0, failed)
        check("and updates one of the C's rows", run(lib, db, "update t set v='mojo-edit' where id=150") == 0, failed)
        _ = lib.call["sqlite3_close", Int32](db)
    elif step == "eq-1":
        # Bit equality: three sessions on a fresh store, the SQL tests/cross.sh also gives the C.
        # Each session is its own open, so each raises the fence and sends deltas against the last.
        var db = open_db(lib, "eq.db", V)
        pragmas(lib, db)
        check("create and fill", run(lib, db, "create table t(id integer primary key, v text); with recursive c(x) as (select 1 union all select x+1 from c where x<400) insert into t select x, 'row-' || x from c") == 0, failed)
        _ = lib.call["sqlite3_close", Int32](db)
    elif step == "eq-2":
        var db = open_db(lib, "eq.db", V)
        pragmas(lib, db)
        check("a small update", run(lib, db, "update t set v='edited' where id % 97 = 0") == 0, failed)
        _ = lib.call["sqlite3_close", Int32](db)
    elif step == "eq-3":
        var db = open_db(lib, "eq.db", V)
        pragmas(lib, db)
        check("more rows and a delete", run(lib, db, "insert into t select id+1000, 'late-' || id from t where id <= 40; delete from t where id between 100 and 130") == 0, failed)
        _ = lib.call["sqlite3_close", Int32](db)
    elif step == "eq-4":
        # a last small update, left as log rows: PIDX and DELTA over the shard, no fold owed
        var db = open_db(lib, "eq.db", V)
        pragmas(lib, db)
        check("a last small update", run(lib, db, "update t set v='tail' where id=7") == 0, failed)
        _ = lib.call["sqlite3_close", Int32](db)
    elif step == "eq-5":
        # a commit too large for one transaction: about 2,300 pages, staged, then folded at close
        var db = open_db(lib, "eq.db", V)
        pragmas(lib, db)
        check("a staged commit of about 2300 pages", run(lib, db, "create table big(id integer primary key, v text); with recursive c(x) as (select 1 union all select x+1 from c where x<2300) insert into big select x, replace(hex(zeroblob(1950)),'0','a') from c") == 0, failed)
        _ = lib.call["sqlite3_close", Int32](db)
    elif step == "eq-6":
        # a second staged commit, smaller than the base, so no fold is owed and its staged rows stay
        var db = open_db(lib, "eq.db", V)
        pragmas(lib, db)
        check("a second staged commit, left as log rows", run(lib, db, "with recursive c(x) as (select 1 union all select x+1 from c where x<2150) insert into big select x+5000, replace(hex(zeroblob(1950)),'0','a') from c") == 0, failed)
        _ = lib.call["sqlite3_close", Int32](db)
    else:
        raise Error("CROSS_STEP is not one of clean, write-m, read-m, read-c")

    print()
    if failed > 0:
        raise Error(String(failed) + " check(s) failed")
    print("all checks passed")
