# Prints the same lines as tests/oracle_delta.c from the Mojo port of the page delta codec.
# The generator below is the C one, step for step, so both sides see the same pages.
# SPDX-License-Identifier: Apache-2.0 OR MIT
from page_delta import *


struct Rng:
    var st: UInt64

    def __init__(out self, seed: UInt64):
        self.st = seed

    def next(mut self) -> UInt64:
        self.st ^= self.st >> 12
        self.st ^= self.st << 25
        self.st ^= self.st >> 27
        return self.st * 0x2545F4914F6CDD1D


def fnv(p: List[UInt8]) -> UInt64:
    var h = UInt64(0xCBF29CE484222325)
    for b in p:
        h = (h ^ UInt64(b)) * 0x100000001B3
    return h


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


def hex_of(v: List[UInt8]) -> String:
    var digits = "0123456789abcdef".as_bytes()
    var s = String()
    for b in v:
        s += chr(Int(digits[Int(b >> 4)]))
        s += chr(Int(digits[Int(b & 15)]))
    return s^


def main():
    var maxlens: List[Int] = [1, 8, 40, 300]
    for i in range(400):
        var rng = Rng(UInt64(i + 1) * 0x9E3779B97F4A7C15)
        var kind = Int(rng.next() & 3)
        var id = rng.next()
        var base = List[UInt8](length=PAGE, fill=0)
        for b in range(PAGE):
            base[b] = 0 if i % 3 == 0 else UInt8(rng.next() & 0xFF)
        var page = base.copy()
        var nruns = Int(rng.next() % 14)
        for _ in range(nruns):
            var ml = maxlens[Int(rng.next() & 3)]
            var off = Int(rng.next() % UInt64(PAGE))
            var length = 1 + Int(rng.next() % UInt64(ml))
            if off + length > PAGE:
                length = PAGE - off
            for k in range(length):
                page[off + k] = UInt8(rng.next() & 0xFF)
        var enc = delta_encode(base, page, kind, id)
        var n = len(enc)
        print("enc", i, n, "-" if n == 0 else hex_of(enc))
        if n == 0:
            continue
        print("meta", i, 1 if is_delta(enc) else 0, hex_u64(delta_base_id(enc)), Int(enc[1]))
        var work = base.copy()
        var rc = delta_apply(enc, work)
        print("apply", i, rc, hex_u64(fnv(work)))
        work = base.copy()
        var cut = List[UInt8]()
        for k in range(n - 1):
            cut.append(enc[k])
        rc = delta_apply(cut, work)
        print("trunc", i, rc, hex_u64(fnv(work)))
