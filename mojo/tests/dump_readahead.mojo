# Prints the same lines as tests/oracle_readahead.c from the Mojo port of the scorer. The
# generator is the C one, step for step, with page numbers held to 32 bits as the C does.
# SPDX-License-Identifier: Apache-2.0 OR MIT
from read_ahead import *


struct Rng:
    var st: UInt64

    def __init__(out self, seed: UInt64):
        self.st = seed

    def next(mut self) -> UInt64:
        self.st ^= self.st >> 12
        self.st ^= self.st << 25
        self.st ^= self.st >> 27
        return self.st * 0x2545F4914F6CDD1D


def hex_u64(v: UInt64) -> String:
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
    var edge: List[UInt32] = [
        0, 1, 7, 8, 9, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFE, 0xFFFFFFFF,
    ]
    for i in range(300):
        var rng = Rng(UInt64(i + 1) * 0x9E3779B97F4A7C15)
        var f = ReadAhead()
        var mode = i % 4
        var pg = UInt32(rng.next() % 64)
        for j in range(60):
            var r = rng.next()
            if mode == 0:
                pg += 1 + UInt32(r % 8)
            elif mode == 1:
                pg = UInt32(r % 100000)
            elif mode == 2:
                if r % 5 == 0:
                    pg = UInt32(rng.next() % 100000)
                else:
                    pg = pg + 1 + UInt32(r % 9)
            else:
                pg = edge[Int(r % 9)]
            var d = f.depth(Int(pg))
            print("ra", i, j, d, f.score, f.last)

    var v: List[UInt64] = [
        0, 1, 2, 3, 100, 0x100000000, 0x7FFFFFFFFFFFFFFF,
        0x8000000000000000, 0xFFFFFFFFFFFFFFFF,
    ]
    for a in range(9):
        for b in range(9):
            print(
                "compact log=" + hex_u64(v[a]) + " base=" + hex_u64(v[b]),
                1 if should_compact(v[a], v[b]) else 0,
            )
