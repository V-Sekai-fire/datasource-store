# Prints the same lines as tests/oracle.c from the Mojo port of `fdb_keys.h`.
# SPDX-License-Identifier: Apache-2.0 OR MIT
from fdb_keys import *


def hex_of(v: List[UInt8]) -> String:
    var digits = "0123456789abcdef".as_bytes()
    var s = String()
    for b in v:
        s += chr(Int(digits[Int(b >> 4)]))
        s += chr(Int(digits[Int(b & 15)]))
    return s^


def line(label: String, k: List[UInt8]):
    print(label, hex_of(k))


def hx(v: UInt64) -> String:
    if v == 0:
        return "0"
    var digits = "0123456789abcdef".as_bytes()
    var rev = List[Int]()
    var x = v
    while x != 0:
        rev.append(Int(x & 15))
        x >>= 4
    var out = String()
    for i in range(len(rev) - 1, -1, -1):
        out += chr(Int(digits[rev[i]]))
    return out^


def main():
    var longname = String()
    for _ in range(100):
        longname += "n"
    var names: List[String] = ["", "a", "main.db", "x/y z", longname]
    var u64s: List[UInt64] = [
        0, 1, 255, 256, 0xFFFFFFFF, 0x100000000, 0x7FFFFFFFFFFFFFFF,
        0x8000000000000000, 0xFFFFFFFFFFFFFFFF,
    ]
    var u32s: List[UInt32] = [0, 1, 255, 256, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF]
    for ni in range(5):
        var nm = names[ni]
        line("meta", key_meta(nm, "HEAD"))
        line("prefix", key_prefix(nm, "PIDX"))
        for p in range(7):
            line("pidx " + String(u32s[p]), key_pidx(nm, u32s[p]))
        for t in range(9):
            var ts = hx(u64s[t])
            line("delta_txid " + ts, key_delta_txid(nm, u64s[t]))
            line("shard_version " + ts, key_shard_version(nm, u64s[t]))
            line("shardn " + ts, key_shardn(nm, u64s[t]))
            for p in range(7):
                var ps = String(u32s[p])
                line("delta " + ts + " " + ps, key_delta(nm, u64s[t], u32s[p]))
                line("shard " + ts + " " + ps, key_shard(nm, u64s[t], u32s[p]))
    for t in range(9):
        var ts = hx(u64s[t])
        line("txn_status " + ts, key_txn_status(u64s[t]))
        line("txn_part_prefix " + ts, key_txn_part_prefix(u64s[t]))
        line("txn_prefix " + ts, key_txn_prefix(u64s[t]))
        for ni in range(5):
            line("txn_part " + ts + " " + String(ni), key_txn_part(u64s[t], names[ni]))
    line("txn_all", key_txn_all())
    var cases: List[List[UInt8]] = [
        [97, 98], [97, 0xFF], [0xFF, 0xFF], [97, 0xFF, 0xFE], [0xFE], [0, 0xFF, 0xFF],
    ]
    for c in range(6):
        line("after " + String(c), key_after(cases[c]))
        var buf = cases[c].copy()
        var n = key_after_in_place(buf, len(buf))
        var out = List[UInt8]()
        for i in range(n):
            out.append(buf[i])
        line("after_in_place " + String(c), out)
