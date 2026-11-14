# Drives a live FoundationDB from Mojo: the network thread, a write transaction, a read back
# in a second transaction, a range clear, a missing key, and a commit that conflicts. Needs a
# cluster; WEFT_FDB_CLUSTER_FILE names its file, as it does for the C programs.
# SPDX-License-Identifier: Apache-2.0 OR MIT
from std.os import getenv
from fdb_client import *
from fdb_keys import *


def check(label: String, ok: Bool, mut failed: Int):
    if ok:
        print("ok   ", label)
    else:
        print("FAIL ", label)
        failed += 1


def same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def bytes_of(s: String) -> List[UInt8]:
    var v = List[UInt8]()
    for b in s.as_bytes():
        v.append(b)
    return v^


def main() raises:
    var failed = 0
    var cluster = getenv("WEFT_FDB_CLUSTER_FILE")
    if cluster.byte_length() == 0:
        cluster = "/etc/foundationdb/fdb.cluster"
    var fdb = Fdb(cluster)
    print("libfdb_c:", fdb.path)

    # keys from the layout the store really uses, under a name nobody else writes
    var name = String("mojo-client-test")
    var k1 = key_pidx(name, 1)
    var k2 = key_pidx(name, 2)
    var k3 = key_pidx(name, 3)
    var v1 = bytes_of("page-one")
    var v2 = bytes_of("page-two")
    var v3 = bytes_of("page-three")
    var lo = key_prefix(name, "PIDX")
    var hi = key_after(lo)

    # start clean
    var t0 = Txn(fdb)
    t0.clear_range(fdb, lo, hi)
    check("clear the test range", t0.commit(fdb) == 0, failed)
    t0.destroy(fdb)

    var t1 = Txn(fdb)
    t1.set(fdb, k1, v1)
    t1.set(fdb, k2, v2)
    t1.set(fdb, k3, v3)
    check("commit three pages", t1.commit(fdb) == 0, failed)
    t1.destroy(fdb)

    var t2 = Txn(fdb)
    var g1 = t2.get(fdb, k1)
    var g2 = t2.get(fdb, k2)
    check("read page 1 back", Bool(g1) and same(g1.value(), v1), failed)
    check("read page 2 back", Bool(g2) and same(g2.value(), v2), failed)
    var missing = t2.get(fdb, key_pidx(name, 99))
    check("a key never written is absent", not Bool(missing), failed)
    t2.destroy(fdb)

    # the order of the keys is the order FoundationDB stores them in: clear [1, 3) leaves page 3
    var t3 = Txn(fdb)
    t3.clear_range(fdb, k1, k3)
    check("clear pages 1 and 2 by range", t3.commit(fdb) == 0, failed)
    t3.destroy(fdb)
    var t4 = Txn(fdb)
    check("page 1 is gone", not Bool(t4.get(fdb, k1)), failed)
    check("page 2 is gone", not Bool(t4.get(fdb, k2)), failed)
    var g3 = t4.get(fdb, k3)
    check("page 3 stays: the range end is exclusive", Bool(g3) and same(g3.value(), v3), failed)
    t4.destroy(fdb)

    # a read-write conflict: A reads k3 and writes k1; B overwrites k3 and commits first
    var ta = Txn(fdb)
    _ = ta.get(fdb, k3)
    ta.set(fdb, k1, bytes_of("a-wrote-this"))
    var tb = Txn(fdb)
    tb.set(fdb, k3, bytes_of("b-wrote-this"))
    check("B commits", tb.commit(fdb) == 0, failed)
    tb.destroy(fdb)
    var rc = ta.commit(fdb)
    check("A's commit conflicts (1020 not_committed)", rc == 1020, failed)
    var retry = ta.on_error(fdb, rc)
    check("and FoundationDB says the conflict may be retried", retry, failed)
    ta.destroy(fdb)

    # leave nothing behind
    var tz = Txn(fdb)
    tz.clear_range(fdb, lo, hi)
    check("clean up", tz.commit(fdb) == 0, failed)
    tz.destroy(fdb)

    fdb.close()
    print()
    if failed > 0:
        raise Error(String(failed) + " check(s) failed")
    print("all checks passed")
