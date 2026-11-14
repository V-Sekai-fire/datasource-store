# SQLite on a VFS written in Mojo whose files live in FoundationDB. Needs a cluster
# (WEFT_FDB_CLUSTER_FILE). The checks are on what SQLite sees, on what is in FoundationDB
# (the keys the C layout names), and on the fence refusing a second writer.
# SPDX-License-Identifier: Apache-2.0 OR MIT
from std.time import perf_counter_ns
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


# Open and report the SQLite code instead of raising, so a refusal is a failed check.
def open_rc(lib: OwnedDLHandle, name: String, vfs: String, flags: Int, mut handle: Int) raises -> Int32:
    var slot = alloc[Int](1)
    slot[unsafe_offset=0] = 0
    var n = name.copy()
    var v = vfs.copy()
    var rc = lib.call["sqlite3_open_v2", Int32](n.unsafe_ptr(), slot, Int32(flags), v.unsafe_ptr())
    handle = slot[unsafe_offset=0]
    return rc


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

    # A commit too large for one transaction stages: its pages go first, under a txid above the
    # head, and one last transaction moves the head. ONE_TXN_PAGES is about 1,850 pages and a staging
    # transaction holds about 2,100, so 2,300 rows of 3,900 bytes in one SQLite transaction (a page
    # each) take two staging transactions and the head's.
    var gname = String("mojo-vfs-staged")
    var tgc = Txn(obs)
    tgc.clear_range(obs, key_meta(gname, ""), key_after(key_meta(gname, "")))
    check("clear the staged-commit database", tgc.commit(obs) == 0, failed)
    tgc.destroy(obs)
    var dbs = open_db(lib, gname, V, 6)
    check("staged: create", run(lib, dbs, "pragma journal_mode=memory; pragma locking_mode=exclusive; create table s(id integer primary key, v blob)") == 0, failed)
    var shead0 = stored_u64(obs, key_meta(gname, "HEAD"))
    check("staged: 2300 rows of 3900 bytes in one transaction", run(lib, dbs, "with recursive c(x) as (select 1 union all select x+1 from c where x<2300) insert into s select x, zeroblob(3900) from c") == 0, failed)
    var shead1 = stored_u64(obs, key_meta(gname, "HEAD"))
    var spages = stored_u64(obs, key_meta(gname, "SIZE")) // PAGE
    check("staged: the head moved once for the whole commit", shead1 == shead0 + 1, failed)
    var sdelta = count_rows(obs, key_delta_txid(gname, UInt64(shead1)))
    check("staged: more page rows than one transaction holds (" + String(sdelta) + " against " + String(ONE_TXN_PAGES) + ")", sdelta > ONE_TXN_PAGES, failed)
    check("staged: every page has an index row", count_rows(obs, key_prefix(gname, "PIDX")) == Int(spages), failed)
    check("staged: nothing is left above the head", count_rows(obs, key_delta_txid(gname, UInt64(shead1 + 1))) == 0, failed)
    check("staged: integrity_check is ok", scalar(lib, dbs, "select count(*) from pragma_integrity_check where integrity_check='ok'") == 1, failed)
    check("staged: all 2300 rows read back", scalar(lib, dbs, "select count(*) from s where length(v)=3900") == 2300, failed)
    _ = lib.call["sqlite3_close", Int32](dbs)
    check("staged: closing folded a staged commit (SHARD holds every page)", count_rows(obs, key_shard_version(gname, UInt64(stored_u64(obs, key_meta(gname, "HEAD"))))) == Int(spages), failed)
    var dbt = open_db(lib, gname, V, 6)
    check("staged: a reopened, folded store reads all 2300 rows", scalar(lib, dbt, "select count(*) from s where length(v)=3900") == 2300, failed)
    _ = lib.call["sqlite3_close", Int32](dbt)

    # a stale writer's big commit stops at the first chunk: nothing is staged, the head stays
    var dba = open_db(lib, gname, V, 6)
    check("stale: the old owner opens", run(lib, dba, "pragma locking_mode=exclusive; select 1") == 0, failed)
    var dbb = open_db(lib, gname, V, 6)
    check("stale: a new owner opens and raises the fence", run(lib, dbb, "pragma locking_mode=exclusive; select 1") == 0, failed)
    var shead2 = stored_u64(obs, key_meta(gname, "HEAD"))
    check("stale: the old owner's big commit is refused", run(lib, dba, "begin; with recursive c(x) as (select 1 union all select x+1 from c where x<2200) insert into s select x+10000, zeroblob(3900) from c; commit") != 0, failed)
    check("stale: the head did not move", stored_u64(obs, key_meta(gname, "HEAD")) == shead2, failed)
    check("stale: no page was staged above the head", count_rows(obs, key_delta_txid(gname, UInt64(shead2 + 1))) == 0, failed)
    _ = lib.call["sqlite3_close", Int32](dba)
    _ = lib.call["sqlite3_close", Int32](dbb)
    var tge = Txn(obs)
    tge.clear_range(obs, key_meta(gname, ""), key_after(key_meta(gname, "")))
    check("clean up the staged-commit database", tge.commit(obs) == 0, failed)
    tge.destroy(obs)

    # Another committer's group record. A group staged across databases is implicitly committed
    # once every intent is durable and its record is written, and any process that finds it must
    # finish it: opening raises the fence and clears the rows above the head, which would destroy
    # a commit the protocol says must happen. So a writer's open decides every staging record first.
    var gone = Txn(obs)
    gone.clear_range(obs, key_txn_all(), key_after(key_txn_all()))
    _ = gone.commit(obs)
    gone.destroy(obs)
    var g1 = String("mojo-vfs-group")
    var gA = String("mojo-vfs-abortA")
    var gB = String("mojo-vfs-abortB")
    for nm in List[String]([g1, gA, gB]):
        var tc = Txn(obs)
        tc.clear_range(obs, key_meta(nm, ""), key_after(key_meta(nm, "")))
        _ = tc.commit(obs)
        tc.destroy(obs)
        var dbc = open_db(lib, nm, V, 6)
        _ = run(lib, dbc, "pragma journal_mode=memory; pragma locking_mode=exclusive; create table q(id integer primary key); insert into q values (1)")
        _ = lib.call["sqlite3_close", Int32](dbc)

    # 1. implicitly committed: the record names one participant and its intent is durable
    var h1 = stored_u64(obs, key_meta(g1, "HEAD"))
    var s1 = stored_u64(obs, key_meta(g1, "SIZE"))
    var l1 = stored_u64(obs, key_meta(g1, "LOGN"))
    var f1 = stored_u64(obs, key_meta(g1, "FENCE"))
    var ts1 = Txn(obs)
    var staging = List[UInt8]()
    staging.append(UInt8(TXN_STAGING))
    ts1.set(obs, key_txn_status(777), staging)
    var part1 = List[UInt8]()
    put_be64(part1, UInt64(h1 + 1))
    put_be64(part1, UInt64(s1))
    ts1.set(obs, key_txn_part(777, g1), part1)
    ts1.set(obs, key_delta(g1, UInt64(h1 + 1), 0), List[UInt8](length=PAGE, fill=UInt8(9)))
    check("group: stage a committed group (record and one durable intent)", ts1.commit(obs) == 0, failed)
    ts1.destroy(obs)
    var hd1 = 0
    var rc1 = open_rc(lib, g1, V, 6, hd1)
    check("group: a writer opens over a committed group", rc1 == 0, failed)
    check("group: its open finished the group: HEAD moved to the staged txid", stored_u64(obs, key_meta(g1, "HEAD")) == h1 + 1, failed)
    check("group: PIDX/0 points at the staged txid", stored_u64(obs, key_pidx(g1, 0)) == h1 + 1, failed)
    check("group: SIZE is the size the record carried", stored_u64(obs, key_meta(g1, "SIZE")) == s1, failed)
    check("group: LOGN grew by the staged pages", stored_u64(obs, key_meta(g1, "LOGN")) == l1 + 1, failed)
    check("group: the staged page is still there", stored_present(obs, key_delta(g1, UInt64(h1 + 1), 0)), failed)
    check("group: the record is dropped", count_rows(obs, key_txn_prefix(777)) == 0, failed)
    check("group: the open raised the fence once", stored_u64(obs, key_meta(g1, "FENCE")) == f1 + 1, failed)
    if rc1 == 0:
        _ = lib.call["sqlite3_close", Int32](hd1)

    # 2. aborted: A's intent is durable, B's is missing, so the group can never commit
    var hA = stored_u64(obs, key_meta(gA, "HEAD"))
    var sA = stored_u64(obs, key_meta(gA, "SIZE"))
    var fA = stored_u64(obs, key_meta(gA, "FENCE"))
    var hB = stored_u64(obs, key_meta(gB, "HEAD"))
    var sB = stored_u64(obs, key_meta(gB, "SIZE"))
    var fB = stored_u64(obs, key_meta(gB, "FENCE"))
    var ts2 = Txn(obs)
    ts2.set(obs, key_txn_status(778), staging)
    var partA = List[UInt8]()
    put_be64(partA, UInt64(hA + 1))
    put_be64(partA, UInt64(sA))
    ts2.set(obs, key_txn_part(778, gA), partA)
    var partB = List[UInt8]()
    put_be64(partB, UInt64(hB + 1))
    put_be64(partB, UInt64(sB))
    ts2.set(obs, key_txn_part(778, gB), partB)
    ts2.set(obs, key_delta(gA, UInt64(hA + 1), 0), List[UInt8](length=PAGE, fill=UInt8(9)))
    check("group: stage an aborted group (A's intent durable, B's missing)", ts2.commit(obs) == 0, failed)
    ts2.destroy(obs)
    var hd2 = 0
    var rc2 = open_rc(lib, gA, V, 6, hd2)
    check("group: a writer opens over an aborted group", rc2 == 0, failed)
    check("group: A's head did not move", stored_u64(obs, key_meta(gA, "HEAD")) == hA, failed)
    check("group: B's head did not move", stored_u64(obs, key_meta(gB, "HEAD")) == hB, failed)
    check("group: A's staged page is cleared", not stored_present(obs, key_delta(gA, UInt64(hA + 1), 0)), failed)
    check("group: the record is dropped", count_rows(obs, key_txn_prefix(778)) == 0, failed)
    check("group: B, whose intent was missing, has its fence raised", stored_u64(obs, key_meta(gB, "FENCE")) == fB + 1, failed)
    check("group: A, a healthy participant, has only the open's fence (not the abort's too)", stored_u64(obs, key_meta(gA, "FENCE")) == fA + 1, failed)
    if rc2 == 0:
        _ = lib.call["sqlite3_close", Int32](hd2)

    # a reader neither decides a record nor raises a fence
    var ts3 = Txn(obs)
    ts3.set(obs, key_txn_status(779), staging)
    var part3 = List[UInt8]()
    put_be64(part3, UInt64(h1 + 5))
    put_be64(part3, UInt64(s1))
    ts3.set(obs, key_txn_part(779, g1), part3)
    check("group: stage a record for a reader to leave alone", ts3.commit(obs) == 0, failed)
    ts3.destroy(obs)
    var f3 = stored_u64(obs, key_meta(g1, "FENCE"))
    var hd3 = 0
    check("group: a reader opens", open_rc(lib, g1, V, 1, hd3) == 0, failed)
    check("group: and leaves the record and the fence alone", count_rows(obs, key_txn_prefix(779)) > 0 and stored_u64(obs, key_meta(g1, "FENCE")) == f3, failed)
    _ = lib.call["sqlite3_close", Int32](hd3)
    var tz = Txn(obs)
    tz.clear_range(obs, key_txn_all(), key_after(key_txn_all()))
    for nm in List[String]([g1, gA, gB]):
        tz.clear_range(obs, key_meta(nm, ""), key_after(key_meta(nm, "")))
    check("clean up the group databases", tz.commit(obs) == 0, failed)
    tz.destroy(obs)

    # The fence check of a staging chunk, with no read in the way. Through SQL a stale writer is
    # stopped by a read's fence check before it reaches a chunk, so write the pages through the file
    # methods: 2,200 pages need two staging transactions, and each must refuse a stale owner.
    var sname = String("mojo-vfs-stale-direct")
    var tsc = Txn(obs)
    tsc.clear_range(obs, key_meta(sname, ""), key_after(key_meta(sname, "")))
    _ = tsc.commit(obs)
    tsc.destroy(obs)
    var snm = sname.copy()
    var svfs = lib.call["sqlite3_vfs_find", Int](V.copy().unsafe_ptr())
    var sold = alloc[UInt8](24)
    var snew = alloc[UInt8](24)
    check("stale-direct: the old owner opens", vfs_open(svfs, Int(snm.unsafe_ptr()), Int(sold), 6, 0) == 0, failed)
    var spage = alloc[UInt8](PAGE)
    for i in range(PAGE):
        spage[unsafe_offset=i] = 7
    var swrote = True
    for pg in range(2200):
        if fdb_write(Int(sold), Int(spage), Int32(PAGE), Int64(pg * PAGE)) != 0:
            swrote = False
    check("stale-direct: 2,200 pages buffered", swrote, failed)
    check("stale-direct: a new owner opens and raises the fence", vfs_open(svfs, Int(snm.unsafe_ptr()), Int(snew), 6, 0) == 0, failed)
    check("stale-direct: the old owner's sync is refused", fdb_sync(Int(sold), 0) != 0, failed)
    check("stale-direct: the head never moved", stored_u64(obs, key_meta(sname, "HEAD")) == -1, failed)
    check("stale-direct: no chunk of the refused commit was staged", count_rows(obs, key_delta_txid(sname, 1)) == 0, failed)
    _ = fdb_close(Int(sold))
    _ = fdb_close(Int(snew))
    var tse = Txn(obs)
    tse.clear_range(obs, key_meta(sname, ""), key_after(key_meta(sname, "")))
    check("clean up the stale-direct database", tse.commit(obs) == 0, failed)
    tse.destroy(obs)

    # A group commit started here, across two databases. Each statement's sync stages its pages
    # under a txid no read can reach; the commit writes a record, then moves both heads together.
    var gone2 = Txn(obs)
    gone2.clear_range(obs, key_txn_all(), key_after(key_txn_all()))
    _ = gone2.commit(obs)
    gone2.destroy(obs)
    var ga = String("mojo-vfs-grpA")
    var gb = String("mojo-vfs-grpB")
    for nm in List[String]([ga, gb]):
        var tc = Txn(obs)
        tc.clear_range(obs, key_meta(nm, ""), key_after(key_meta(nm, "")))
        _ = tc.commit(obs)
        tc.destroy(obs)
        var dbc = open_db(lib, nm, V, 6)
        _ = run(lib, dbc, "pragma journal_mode=memory; pragma locking_mode=exclusive; create table q(id integer primary key); insert into q values (1)")
        _ = lib.call["sqlite3_close", Int32](dbc)
    var gda = open_db(lib, ga, V, 6)
    var gdb = open_db(lib, gb, V, 6)
    _ = run(lib, gda, "pragma locking_mode=exclusive; select 1")
    _ = run(lib, gdb, "pragma locking_mode=exclusive; select 1")
    var ha0 = stored_u64(obs, key_meta(ga, "HEAD"))
    var hb0 = stored_u64(obs, key_meta(gb, "HEAD"))
    var gid = 0
    var gdummy = 0
    check("group: begin", weft_txn_begin(ctx, gid) == 0 and gid > 0, failed)
    check("group: a second begin while one is open is refused", weft_txn_begin(ctx, gdummy) == Int32(SQLITE_BUSY), failed)
    check("group: join A", weft_txn_join(lib, ctx, gda, gid) == 0, failed)
    check("group: join B", weft_txn_join(lib, ctx, gdb, gid) == 0, failed)
    check("group: joining under another id is refused", weft_txn_join(lib, ctx, gda, gid + 1) == Int32(SQLITE_MISUSE), failed)
    check("group: write A", run(lib, gda, "insert into q values (2)") == 0, failed)
    check("group: write B", run(lib, gdb, "insert into q values (2)") == 0, failed)
    check("group: a sync staged and did not commit: A's head stays", stored_u64(obs, key_meta(ga, "HEAD")) == ha0, failed)
    check("group: B's head stays", stored_u64(obs, key_meta(gb, "HEAD")) == hb0, failed)
    check("group: A's pages are staged above its head", count_rows(obs, key_delta_txid(ga, UInt64(ha0 + 1))) > 0, failed)
    var hd = 0
    check("group: a reader opens mid-group", open_rc(lib, ga, V, 1, hd) == 0, failed)
    check("group: and does not see the staged row", scalar(lib, hd, "select count(*) from q") == 1, failed)
    _ = lib.call["sqlite3_close", Int32](hd)
    check("group: commit", weft_txn_commit(ctx, gid) == 0, failed)
    check("group: A's head moved", stored_u64(obs, key_meta(ga, "HEAD")) == ha0 + 1, failed)
    check("group: B's head moved", stored_u64(obs, key_meta(gb, "HEAD")) == hb0 + 1, failed)
    check("group: the record is dropped", count_rows(obs, key_txn_prefix(UInt64(gid))) == 0, failed)
    check("group: the connection sees its own rows", scalar(lib, gda, "select count(*) from q") == 2, failed)
    var hr = 0
    check("group: a new reader opens", open_rc(lib, ga, V, 1, hr) == 0, failed)
    check("group: and sees the committed row in A", scalar(lib, hr, "select count(*) from q") == 2, failed)
    _ = lib.call["sqlite3_close", Int32](hr)
    var hr2 = 0
    check("group: and in B", open_rc(lib, gb, V, 1, hr2) == 0 and scalar(lib, hr2, "select count(*) from q") == 2, failed)
    _ = lib.call["sqlite3_close", Int32](hr2)
    check("group: after commit a sync commits again", run(lib, gda, "insert into q values (3)") == 0 and stored_u64(obs, key_meta(ga, "HEAD")) == ha0 + 2, failed)

    # abort: nothing was recorded, the staged pages are unreachable, and the next open clears them
    var ha1 = stored_u64(obs, key_meta(ga, "HEAD"))
    var gid2 = 0
    check("group: begin again", weft_txn_begin(ctx, gid2) == 0, failed)
    check("group: join A for an abort", weft_txn_join(lib, ctx, gda, gid2) == 0, failed)
    check("group: write A", run(lib, gda, "insert into q values (4)") == 0, failed)
    check("group: abort", weft_txn_abort(ctx, gid2) == 0, failed)
    check("group: A's head did not move", stored_u64(obs, key_meta(ga, "HEAD")) == ha1, failed)
    check("group: no record was written", count_rows(obs, key_txn_prefix(UInt64(gid2))) == 0, failed)
    check("group: the staged pages are still above the head, unreachable", count_rows(obs, key_delta_txid(ga, UInt64(ha1 + 1))) > 0, failed)
    # As in the C, an abort does not roll back what SQLite was told was committed: the member's
    # buffered pages stay and its next sync commits them, in the ordinary way.
    check("group: the member's next sync commits its buffered row", run(lib, gda, "insert into q values (6)") == 0 and stored_u64(obs, key_meta(ga, "HEAD")) == ha1 + 1, failed)
    _ = lib.call["sqlite3_close", Int32](gda)
    _ = lib.call["sqlite3_close", Int32](gdb)
    var hc = 0
    check("group: reopen", open_rc(lib, ga, V, 6, hc) == 0, failed)
    check("group: the rows the abort left are there", scalar(lib, hc, "select count(*) from q where id in (4, 6)") == 2, failed)
    _ = lib.call["sqlite3_close", Int32](hc)

    # a participant that lost ownership while staging stops the whole group before any record
    var dba2 = open_db(lib, ga, V, 6)
    var dbb2 = open_db(lib, gb, V, 6)
    _ = run(lib, dba2, "pragma locking_mode=exclusive; select 1")
    _ = run(lib, dbb2, "pragma locking_mode=exclusive; select 1")
    var ha2 = stored_u64(obs, key_meta(ga, "HEAD"))
    var hb2 = stored_u64(obs, key_meta(gb, "HEAD"))
    var gid3 = 0
    _ = weft_txn_begin(ctx, gid3)
    _ = weft_txn_join(lib, ctx, dba2, gid3)
    _ = weft_txn_join(lib, ctx, dbb2, gid3)
    _ = run(lib, dba2, "insert into q values (5)")
    _ = run(lib, dbb2, "insert into q values (5)")
    var hsteal = 0
    _ = open_rc(lib, gb, V, 6, hsteal)  # a new owner of B raises its fence
    check("group: a commit with a stale participant is refused", weft_txn_commit(ctx, gid3) != 0, failed)
    check("group: no record was written", count_rows(obs, key_txn_prefix(UInt64(gid3))) == 0, failed)
    check("group: A's head did not move", stored_u64(obs, key_meta(ga, "HEAD")) == ha2, failed)
    check("group: B's head did not move", stored_u64(obs, key_meta(gb, "HEAD")) == hb2, failed)
    _ = weft_txn_abort(ctx, gid3)
    _ = lib.call["sqlite3_close", Int32](dba2)
    _ = lib.call["sqlite3_close", Int32](dbb2)
    _ = lib.call["sqlite3_close", Int32](hsteal)

    # a participant must stage in one transaction: more pages than that is refused at the sync
    var dbbig = open_db(lib, ga, V, 6)
    _ = run(lib, dbbig, "pragma locking_mode=exclusive; select 1")
    var gid4 = 0
    _ = weft_txn_begin(ctx, gid4)
    _ = weft_txn_join(lib, ctx, dbbig, gid4)
    check("group: a participant above one transaction's pages is refused", run(lib, dbbig, "create table big(id integer primary key, v blob); with recursive c(x) as (select 1 union all select x+1 from c where x<2300) insert into big select x, zeroblob(3900) from c") != 0, failed)
    _ = weft_txn_abort(ctx, gid4)
    _ = lib.call["sqlite3_close", Int32](dbbig)
    var tgz = Txn(obs)
    tgz.clear_range(obs, key_txn_all(), key_after(key_txn_all()))
    for nm in List[String]([ga, gb]):
        tgz.clear_range(obs, key_meta(nm, ""), key_after(key_meta(nm, "")))
    check("clean up the group-commit databases", tgz.commit(obs) == 0, failed)
    tgz.destroy(obs)

    # The read-ahead window. A scan fills it from the shard in a few range reads instead of a page
    # at a time, and a commit, a fold or a truncate must drop it: a window read against a store
    # that changed is free to be wrong. 600 rows of 3,900 bytes are about 600 pages, folded into a
    # shard when the first connection closes, and a ten page cache sends every read to the VFS.
    var rname = String("mojo-vfs-readahead")
    var trc = Txn(obs)
    trc.clear_range(obs, key_meta(rname, ""), key_after(key_meta(rname, "")))
    _ = trc.commit(obs)
    trc.destroy(obs)
    var dbw = open_db(lib, rname, V, 6)
    _ = run(lib, dbw, "pragma journal_mode=memory; pragma locking_mode=exclusive; create table r(id integer primary key, v blob)")
    check("read-ahead: write 600 pages", run(lib, dbw, "with recursive c(x) as (select 1 union all select x+1 from c where x<600) insert into r select x, zeroblob(3900) from c") == 0, failed)
    check("read-ahead: mark each row", run(lib, dbw, "update r set v = printf('%0*d', 3900, id)") == 0, failed)
    _ = lib.call["sqlite3_close", Int32](dbw)
    check("read-ahead: close folded the store into a shard", count_rows(obs, key_shard_version(rname, UInt64(stored_u64(obs, key_meta(rname, "HEAD"))))) > 400, failed)
    var rh = 0
    check("read-ahead: reopen", open_rc(lib, rname, V, 6, rh) == 0, failed)
    _ = run(lib, rh, "pragma cache_size=10; pragma locking_mode=exclusive")
    var fills0 = ra_fills_total(ctx)
    var hits0 = ra_hits_total(ctx)
    var tscan = Int(perf_counter_ns())
    var rsum = scalar(lib, rh, "select sum(length(v)) from r")
    print("scan of 600 pages:", (Int(perf_counter_ns()) - tscan) // 1000000, "ms")
    check("read-ahead: a scan reads every row", rsum == 600 * 3900, failed)
    check("read-ahead: the scan filled windows", ra_fills_total(ctx) > fills0, failed)
    check("read-ahead: and most of its pages came from them (" + String(ra_hits_total(ctx) - hits0) + ")", ra_hits_total(ctx) - hits0 > 300, failed)
    var rcheck = scalar(lib, rh, "select count(*) from r where v = printf('%0*d', 3900, id)")
    check("read-ahead: every page held the right bytes", rcheck == 600, failed)
    # a commit changes pages the window holds: the next scan must see the new bytes
    # A window outlives the transaction that filled it, so the commit must drop it: read a run of
    # pages to fill one, then commit, and the window must be empty.
    _ = scalar(lib, rh, "select sum(length(v)) from r where id between 100 and 140")
    check("read-ahead: a short scan left a window (" + String(ra_window_pages(lib, ctx, rh)) + " pages)", ra_window_pages(lib, ctx, rh) > 0, failed)
    check("read-ahead: update rows across the table", run(lib, rh, "update r set v = printf('%0*d', 3900, id + 1000) where id % 7 = 0") == 0, failed)
    check("read-ahead: the commit dropped the window", ra_window_pages(lib, ctx, rh) == 0, failed)
    var rnew = scalar(lib, rh, "select count(*) from r where v = printf('%0*d', 3900, id + 1000)")
    check("read-ahead: a scan after the commit sees the new bytes, not the window's (" + String(rnew) + ")", rnew == 85, failed)
    var rold = scalar(lib, rh, "select count(*) from r where v = printf('%0*d', 3900, id)")
    check("read-ahead: and the rows it did not change are as they were", rold == 600 - 85, failed)
    # a delete shrinks the file: the next scan must not return pages past the end
    check("read-ahead: delete the tail", run(lib, rh, "delete from r where id > 300") == 0, failed)
    check("read-ahead: a scan after the delete sees 300 rows", scalar(lib, rh, "select count(*) from r") == 300, failed)
    check("read-ahead: and integrity_check is ok", scalar(lib, rh, "select count(*) from pragma_integrity_check where integrity_check='ok'") == 1, failed)
    _ = lib.call["sqlite3_close", Int32](rh)
    var rr = Txn(obs)
    rr.clear_range(obs, key_meta(rname, ""), key_after(key_meta(rname, "")))
    check("clean up the read-ahead database", rr.commit(obs) == 0, failed)
    rr.destroy(obs)

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
