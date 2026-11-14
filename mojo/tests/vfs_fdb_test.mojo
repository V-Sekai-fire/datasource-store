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
from page_delta import is_delta, delta_apply, delta_base_id


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


def stored_present(fdb: Fdb, key: List[UInt8]) raises -> Bool:
    var t = Txn(fdb)
    var r = t.get_result(fdb, key)
    t.destroy(fdb)
    return r.present


def count_rows(fdb: Fdb, prefix: List[UInt8]) raises -> Int:
    var t = Txn(fdb)
    var n = 0
    var begin = prefix.copy()
    var after = False
    var end = key_after(prefix)
    while True:
        var r = t.range_rows(fdb, begin, after, end)
        if r.code != 0 or len(r.keys) == 0:
            break
        n += len(r.keys)
        if not r.more:
            break
        begin = r.keys[len(r.keys) - 1].copy()
        after = True
    t.destroy(fdb)
    return n


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
    # the owner's row is a whole page or a delta against a whole row; rebuild the page either way
    var page0 = row.value.copy()
    if row.present and is_delta(row.value):
        var brow = tp.get_result(obs, key_delta(name, delta_base_id(row.value), 0))
        page0 = brow.value.copy()
        check("a delta row's base is a whole page", brow.present and len(brow.value) == PAGE, failed)
        check("the delta applies to its base", delta_apply(row.value, page0) == 0, failed)
    check("DELTA/<owner>/0 rebuilds to a whole 4096-byte page", row.present and len(page0) == PAGE, failed)
    check("page 0 holds SQLite's header ('SQLite format 3', page size 4096 at byte 16)", len(page0) == PAGE and page0[0] == 0x53 and page0[1] == 0x51 and page0[16] == 0x10 and page0[17] == 0x00, failed)
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

    # Deltas: db3 has read its pages, so each is a base. A small update changes a few bytes of a
    # few pages, and those go to the store as deltas against their bases, not as whole pages.
    check("a small update on the owner", run(lib, db3, "update t set v='delta-test-row' where id=500") == 0, failed)
    var dhead = stored_u64(obs, key_meta(name, "HEAD"))
    var tdl = Txn(obs)
    var n_delta = 0
    var n_whole = 0
    var delta_ok = True
    for pg in range(size // PAGE):
        var r = tdl.get_result(obs, key_delta(name, UInt64(dhead), UInt32(pg)))
        if r.present:
            if len(r.value) == PAGE:
                n_whole += 1
            elif len(r.value) < 820 and r.value[0] == 0xD7:
                n_delta += 1
            else:
                delta_ok = False
    tdl.destroy(obs)
    print("the update's commit wrote", n_delta, "delta row(s) and", n_whole, "whole page(s)")
    check("the commit wrote at least one delta row", n_delta >= 1, failed)
    check("every row is a whole page or a delta under a fifth of one", delta_ok, failed)
    _ = lib.call["sqlite3_close", Int32](db3)
    var db3b = open_db(lib, name, V, 6)
    check("a fresh open reads the delta back", scalar(lib, db3b, "select count(*) from t where v='delta-test-row'") == 1, failed)
    check("and the rest of the page it patched is intact", scalar(lib, db3b, "select count(*) from t where id between 490 and 510") == 21, failed)
    check("integrity_check is ok after a delta commit", scalar(lib, db3b, "select count(*) from pragma_integrity_check where integrity_check='ok'") == 1, failed)
    _ = lib.call["sqlite3_close", Int32](db3b)

    # a read-only open takes no fence and sees the committed state
    var dbr = open_db(lib, name, V, 1)
    check("a read-only open leaves the fence at 4 (the delta test's reopen raised it)", stored_u64(obs, key_meta(name, "FENCE")) == 4, failed)
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

    # The file methods called directly, for the paths SQL does not reach: SQLite keeps its own
    # page cache under EXCLUSIVE locking, so it never reads a dirty page back through the VFS.
    var name2 = String("mojo-vfs-direct")
    var nm2 = name2.copy()
    var vname = V.copy()
    var vfs = lib.call["sqlite3_vfs_find", Int](vname.unsafe_ptr())
    var fobj = alloc[UInt8](24)
    var fa = Int(fobj)
    var tclean = Txn(obs)
    tclean.clear_range(obs, key_meta(name2, ""), key_after(key_meta(name2, "")))
    check("clear the direct test database", tclean.commit(obs) == 0, failed)
    tclean.destroy(obs)
    check("vfs_open", vfs_open(vfs, Int(nm2.unsafe_ptr()), fa, 6, 0) == 0, failed)
    var off = 2 * PAGE + 50  # inside page 2, not at its start: a partial page
    var wbuf = alloc[UInt8](100)
    for i in range(100):
        wbuf[unsafe_offset=i] = UInt8(i + 1)
    check("a partial-page write", fdb_write(fa, Int(wbuf), 100, Int64(off)) == 0, failed)
    var rbuf = alloc[UInt8](100)
    for i in range(100):
        rbuf[unsafe_offset=i] = 0xEE
    check("a read before sync sees the buffered bytes", fdb_read(fa, Int(rbuf), 100, Int64(off)) == 0, failed)
    var same_bytes = True
    for i in range(100):
        same_bytes = same_bytes and rbuf[unsafe_offset=i] == UInt8(i + 1)
    check("and they are the ones written", same_bytes, failed)
    check("nothing is in FoundationDB before sync", stored_u64(obs, key_meta(name2, "HEAD")) == -1, failed)
    check("sync commits", fdb_sync(fa, 0) == 0, failed)
    check("HEAD is 1", stored_u64(obs, key_meta(name2, "HEAD")) == 1, failed)
    check("SIZE is the end of the write", stored_u64(obs, key_meta(name2, "SIZE")) == off + 100, failed)
    # a partial overwrite of a stored page: the store's bytes around it must survive
    var patch = alloc[UInt8](4)
    for i in range(4):
        patch[unsafe_offset=i] = 0xFF
    check("a partial overwrite of a stored page", fdb_write(fa, Int(patch), 4, Int64(off + 10)) == 0, failed)
    check("sync commits it", fdb_sync(fa, 0) == 0, failed)
    for i in range(100):
        rbuf[unsafe_offset=i] = 0xEE
    check("read back after the second commit", fdb_read(fa, Int(rbuf), 100, Int64(off)) == 0, failed)
    var kept = True
    for i in range(100):
        var want = UInt8(0xFF) if (i >= 10 and i < 14) else UInt8(i + 1)
        kept = kept and rbuf[unsafe_offset=i] == want
    check("the patch landed and the bytes around it survived", kept, failed)
    check("pages 0 and 1 were never written, so there is no row for them", not stored_present(obs, key_pidx(name2, 0)) and not stored_present(obs, key_pidx(name2, 1)), failed)
    var past = alloc[UInt8](16)
    check("a read past the end is a short read", fdb_read(fa, Int(past), 16, Int64(10 * PAGE)) == 522, failed)
    # truncate to two pages: page 2's index row goes at the next commit
    check("truncate to two pages", fdb_truncate(fa, Int64(2 * PAGE)) == 0, failed)
    check("sync commits the truncate", fdb_sync(fa, 0) == 0, failed)
    check("SIZE is two pages", stored_u64(obs, key_meta(name2, "SIZE")) == 2 * PAGE, failed)
    check("page 2's index row is gone", not stored_present(obs, key_pidx(name2, 2)), failed)
    check("the file exists to access", stored_u64(obs, key_meta(name2, "SIZE")) > 0, failed)
    check("close", fdb_close(fa) == 0, failed)
    check("vfs_delete", vfs_delete(vfs, Int(nm2.unsafe_ptr()), 0) == 0, failed)
    check("delete cleared every key under the name", stored_u64(obs, key_meta(name2, "HEAD")) == -1 and stored_u64(obs, key_meta(name2, "SIZE")) == -1, failed)

    # A fold: the log is as large as the base, so closing pays it. Every page moves to
    # SHARD/<head>/<pgno>, the marker says how many, and the log rows and the index go.
    var fname = String("mojo-vfs-fold")
    var tfc = Txn(obs)
    tfc.clear_range(obs, key_meta(fname, ""), key_after(key_meta(fname, "")))
    check("clear the fold database", tfc.commit(obs) == 0, failed)
    tfc.destroy(obs)
    var dbf = open_db(lib, fname, V, 6)
    check("fold: create and fill", run(lib, dbf, "pragma journal_mode=memory; pragma locking_mode=exclusive; create table t(id integer primary key, v text); with recursive c(x) as (select 1 union all select x+1 from c where x<600) insert into t select x, 'row-' || x from c") == 0, failed)
    check("no shard yet: the fold is owed, not paid", count_rows(obs, key_prefix(fname, "SHARDN")) == 0, failed)
    _ = lib.call["sqlite3_close", Int32](dbf)
    var fhead = stored_u64(obs, key_meta(fname, "HEAD"))
    var npg = stored_u64(obs, key_meta(fname, "SIZE")) // PAGE
    check("closing paid the fold: SHARDN names the head", stored_u64(obs, key_shardn(fname, UInt64(fhead))) == npg, failed)
    check("SHARD holds every page", count_rows(obs, key_shard_version(fname, UInt64(fhead))) == npg, failed)
    check("the index is gone", count_rows(obs, key_prefix(fname, "PIDX")) == 0, failed)
    check("the log rows are gone", count_rows(obs, key_prefix(fname, "DELTA")) == 0, failed)
    check("LOGN is back to zero", stored_u64(obs, key_meta(fname, "LOGN")) == 0, failed)
    var dbg = open_db(lib, fname, V, 6)
    check("a folded store opens and reads", scalar(lib, dbg, "select count(*) from t") == 600, failed)
    check("integrity_check is ok on a folded store", scalar(lib, dbg, "select count(*) from pragma_integrity_check where integrity_check='ok'") == 1, failed)
    check("an update after the fold", run(lib, dbg, "pragma locking_mode=exclusive; update t set v='after-fold' where id=300") == 0, failed)
    var ahead = stored_u64(obs, key_meta(fname, "HEAD"))
    var tfd = Txn(obs)
    var fd_rows = 0
    var fd_delta = 0
    for pg in range(Int(npg)):
        var rr = tfd.get_result(obs, key_delta(fname, UInt64(ahead), UInt32(pg)))
        if rr.present:
            fd_rows += 1
            if len(rr.value) < PAGE and rr.value[0] == 0xD7 and rr.value[1] == 2:
                fd_delta += 1
    tfd.destroy(obs)
    # page 0 changes by a few bytes and goes as a delta over the shard; the leaf the update
    # rewrote moves more than a fifth of its cells, so it goes whole, as the rule says
    check("the update wrote rows, and at least one is a delta against the shard", fd_rows >= 2 and fd_delta >= 1, failed)
    _ = lib.call["sqlite3_close", Int32](dbg)
    check("the shard stays: a small log does not trip another fold", count_rows(obs, key_shard_version(fname, UInt64(fhead))) == npg, failed)
    var dbh = open_db(lib, fname, V, 6)
    check("a delta over a shard reads back", scalar(lib, dbh, "select count(*) from t where v='after-fold'") == 1, failed)
    _ = lib.call["sqlite3_close", Int32](dbh)
    var tfe = Txn(obs)
    tfe.clear_range(obs, key_meta(fname, ""), key_after(key_meta(fname, "")))
    check("clean up the fold database", tfe.commit(obs) == 0, failed)
    tfe.destroy(obs)

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
