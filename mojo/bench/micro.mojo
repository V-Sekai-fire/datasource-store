# Times the pieces of a commit that need no FoundationDB: the delta encoder and the key builders.
# SPDX-License-Identifier: Apache-2.0 OR MIT
from std.time import perf_counter_ns
from page_delta import delta_encode
from fdb_keys import key_delta, key_pidx


def main() raises:
    var base = List[UInt8](length=4096, fill=UInt8(7))
    for i in range(4096):
        base[i] = UInt8((i * 31) % 251)
    var page = base.copy()
    page[100] = 1
    page[2000] = 2
    page[3000] = 3
    var n = 20000
    var t0 = perf_counter_ns()
    var total = 0
    for _ in range(n):
        total += len(delta_encode(base, page, 1, UInt64(5)))
    var t1 = perf_counter_ns()
    print("delta_encode of a 3-byte change:", Float64(t1 - t0) / Float64(n) / 1000.0, "us per page (rows", total // n, "bytes)")
    var name = String("bench.db")
    t0 = perf_counter_ns()
    var k = 0
    for i in range(n):
        k += len(key_delta(name, UInt64(i), UInt32(i % 900))) + len(key_pidx(name, UInt32(i % 900)))
    t1 = perf_counter_ns()
    print("key_delta + key_pidx:", Float64(t1 - t0) / Float64(n) / 1000.0, "us per page")
    t0 = perf_counter_ns()
    var c = 0
    for _ in range(n):
        var cp = base.copy()
        c += len(cp)
    t1 = perf_counter_ns()
    print("a 4 KB list copy:", Float64(t1 - t0) / Float64(n) / 1000.0, "us")
