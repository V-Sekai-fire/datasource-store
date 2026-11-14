# The property gate for `page_delta.mojo`, over `contract-witness-mojo`.
#
# What `spec/PageDelta.lean` proves about the model, checked on the byte format the C
# actually writes: a delta applied to the page it was taken from gives the new page
# (`patch_diff`), a delta says which base it needs, and a damaged delta is refused rather
# than half read. Each property has a planted-false control: a wrong encoder or a wrong
# decoder run through the same predicate must come back FOUND, or the gate proves nothing.
#
#   pixi run delta-witness
#
# SPDX-License-Identifier: Apache-2.0 OR MIT

from witness.ladder import *
from page_delta import *


# ── Inputs ────────────────────────────────────────────────────────────────────

@fieldwise_init
struct Pages(Copyable, Movable):
    var base: List[UInt8]
    var page: List[UInt8]
    var kind: Int
    var id: UInt64


@fieldwise_init
struct RunSpec(Copyable, Movable):
    var off: Int
    var length: Int
    var have: Int  # bytes actually present after the run header


def gen_pages(mut r: Run, lvl: Level) -> Pages:
    var base = List[UInt8](length=PAGE, fill=0)
    # A third of the bases are all zeros, as a fresh page is.
    if r.int_range(0, 2) != 0:
        for i in range(PAGE):
            base[i] = UInt8(r.int_range(0, 255))
    var page = base.copy()
    var maxlens: List[Int] = [1, 8, 40, 300, 900]
    var nruns = r.int_range(0, 14)
    for _ in range(nruns):
        var ml = maxlens[r.int_range(0, 4)]
        var off = r.int_range(0, PAGE - 1)
        var length = r.int_range(1, ml)
        if off + length > PAGE:
            length = PAGE - off
        for k in range(length):
            page[off + k] = UInt8(r.int_range(0, 255))
    return Pages(base^, page^, r.int_range(0, 3), r.next_u64())


def gen_run_spec(mut r: Run, lvl: Level) -> RunSpec:
    # Near the page edge and near the byte count, where an off-by-one would live.
    var off = r.int_range(0, PAGE + 100)
    var length = r.int_range(0, PAGE + 100)
    if r.int_range(0, 1) == 0:
        off = PAGE - r.int_range(0, 40)
        length = r.int_range(0, 60)
    var have = length + r.int_range(-3, 3)
    if have < 0:
        have = 0
    return RunSpec(off, length, have)


def show_pages(x: Pages) -> String:
    var changed = 0
    for i in range(PAGE):
        if x.base[i] != x.page[i]:
            changed += 1
    return "(kind=" + String(x.kind) + ", id=0x" + hex_u64(x.id) + ", changed_bytes=" + String(changed) + ")"


def show_run_spec(x: RunSpec) -> String:
    return "(off=" + String(x.off) + ", len=" + String(x.length) + ", have=" + String(x.have) + ")"


# ── Helpers ───────────────────────────────────────────────────────────────────

def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


# The offsets at which a delta may end and still be whole: after the header and after each
# run. Read off the delta's own run headers, so it is not the decoder's loop.
def boundaries(val: List[UInt8]) -> List[Int]:
    var out = List[Int]()
    var n = DELTA_HDR
    out.append(n)
    while n + 4 <= len(val):
        n += 4 + ((Int(val[n + 2]) << 8) | Int(val[n + 3]))
        if n <= len(val):
            out.append(n)
    return out^


def has(v: List[Int], x: Int) -> Bool:
    for e in v:
        if e == x:
            return True
    return False


def head(v: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(v[i])
    return out^


# A delta as one run: header, then off, len and `have` bytes.
def one_run(off: Int, length: Int, have: Int) -> List[UInt8]:
    var v = List[UInt8]()
    v.append(UInt8(DELTA_MAGIC))
    for _ in range(9):
        v.append(0)
    v.append(UInt8((off >> 8) & 0xFF))
    v.append(UInt8(off & 0xFF))
    v.append(UInt8((length >> 8) & 0xFF))
    v.append(UInt8(length & 0xFF))
    for _ in range(have):
        v.append(0xAB)
    return v^


# Round trip, id, kind, size and shape of an encoded delta. `enc` is passed in so a
# control can hand the same predicate a damaged encoding.
def roundtrip_ok(x: Pages, enc: List[UInt8], mut r: Run) -> Bool:
    r.classify(len(enc) == 0, "refused")
    r.classify(len(enc) == DELTA_HDR, "identical")
    if len(enc) == 0:
        return True  # refused: the page is stored whole, and `patch_diff` is not in play
    # A fifth of the page, as `spec/PageDelta.lean` and mvSQLite have it; not the port's own constant.
    if len(enc) > 819 or not is_delta(enc):
        return False
    if delta_base_id(enc) != x.id or Int(enc[1]) != x.kind:
        return False
    var work = x.base.copy()
    if delta_apply(enc, work) != 0:
        return False
    return _same(work, x.page)


# ── Round trip (`patch_diff`) ─────────────────────────────────────────────────

def p_round_trip(x: Pages, mut r: Run) -> Bool:
    return roundtrip_ok(x, delta_encode(x.base, x.page, x.kind, x.id), r)


def p_round_trip_drops_last_run(x: Pages, mut r: Run) -> Bool:
    # Planted-false: an encoder that loses its final run. Any page with a change then
    # reads back as the old page.
    var enc = delta_encode(x.base, x.page, x.kind, x.id)
    if len(enc) > DELTA_HDR:
        var b = boundaries(enc)
        enc = head(enc, b[len(b) - 2])
    return roundtrip_ok(x, enc, r)


# ── An unchanged page is a header and nothing else ────────────────────────────

def p_identical_page(x: Pages, mut r: Run) -> Bool:
    var enc = delta_encode(x.base, x.base, x.kind, x.id)
    var work = x.base.copy()
    return len(enc) == DELTA_HDR and delta_apply(enc, work) == 0 and _same(work, x.base)


def p_identical_page_pads(x: Pages, mut r: Run) -> Bool:
    # Planted-false: an encoder that emits a run for nothing.
    var enc = delta_encode(x.base, x.base, x.kind, x.id)
    enc.append(0)
    return len(enc) == DELTA_HDR


# ── A damaged delta is refused, never half read ───────────────────────────────

# A cut delta is whole only where it ends on a run boundary; anywhere else it is refused.
def p_truncation(x: Pages, mut r: Run) -> Bool:
    var enc = delta_encode(x.base, x.page, x.kind, x.id)
    if len(enc) <= DELTA_HDR:
        return True
    var b = boundaries(enc)
    var k = r.int_range(DELTA_HDR, len(enc) - 1)
    var work = x.base.copy()
    var rc = delta_apply(head(enc, k), work)
    return (rc == 0) == has(b, k)


def p_truncation_unchecked(x: Pages, mut r: Run) -> Bool:
    # Planted-false: a decoder that does not check a run against the bytes it was handed
    # accepts every cut. The decision here is what it would answer for a cut mid-run.
    var enc = delta_encode(x.base, x.page, x.kind, x.id)
    if len(enc) <= DELTA_HDR:
        return True
    var b = boundaries(enc)
    var k = r.int_range(DELTA_HDR, len(enc) - 1)
    var accepts_everything = True
    return accepts_everything == has(b, k)


# A run is taken iff it fits the page and the bytes it names are all there.
def p_run_bounds(x: RunSpec, mut r: Run) -> Bool:
    var page = List[UInt8](length=PAGE, fill=0)
    var rc = delta_apply(one_run(x.off, x.length, x.have), page)
    var want = x.off + x.length <= PAGE and x.have == x.length
    return (rc == 0) == want


def p_run_bounds_no_page_check(x: RunSpec, mut r: Run) -> Bool:
    # Planted-false: a decoder that skips the `off + len <= PAGE` test. It would write
    # past the page, so the model only asks what it would answer.
    var want = x.off + x.length <= PAGE and x.have == x.length
    var would_accept = x.have == x.length
    return would_accept == want


# ── Gate ─────────────────────────────────────────────────────────────────────

struct Gate(Movable):
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def expect(mut self, label: String, t: Trial, want: Outcome):
        if t.outcome == want:
            self.passed += 1
            print("ok   ", label)
        else:
            self.failed += 1
            print("FAIL ", label)
        print("       ", t.message)


def main() raises:
    var g = Gate()
    var hold = Outcome.PROVABLY_NONE
    var found = Outcome.FOUND

    g.expect("[delta] a delta applied to its base gives the new page",
        resolve[Pages]("encode then apply is the identity, and id and kind survive",
            gen_pages, p_round_trip, no_shrink[Pages], show_pages), hold)
    g.expect("[delta] rule-2 control: an encoder that drops its last run is caught",
        resolve[Pages]("a delta missing its last run still reads back",
            gen_pages, p_round_trip_drops_last_run, no_shrink[Pages], show_pages), found)

    g.expect("[delta] an unchanged page encodes to the header alone",
        resolve[Pages]("identical pages give a bare header that applies to nothing",
            gen_pages, p_identical_page, no_shrink[Pages], show_pages), hold)
    g.expect("[delta] rule-2 control: a padded header is caught",
        resolve[Pages]("a header with a stray byte is still a bare header",
            gen_pages, p_identical_page_pads, no_shrink[Pages], show_pages), found)

    g.expect("[delta] a cut delta is whole only on a run boundary",
        resolve[Pages]("apply accepts a prefix iff it ends between runs",
            gen_pages, p_truncation, no_shrink[Pages], show_pages), hold)
    g.expect("[delta] rule-2 control: a decoder that accepts every cut is caught",
        resolve[Pages]("accepting every prefix agrees with the run boundaries",
            gen_pages, p_truncation_unchecked, no_shrink[Pages], show_pages), found)

    g.expect("[delta] a run is taken iff it fits the page and its bytes are all there",
        resolve[RunSpec]("apply answers 0 exactly for a whole, in-page run",
            gen_run_spec, p_run_bounds, no_shrink[RunSpec], show_run_spec), hold)
    g.expect("[delta] rule-2 control: a decoder with no page bound is caught",
        resolve[RunSpec]("a run past the page end is taken when its bytes are there",
            gen_run_spec, p_run_bounds_no_page_check, no_shrink[RunSpec], show_run_spec), found)

    print()
    print(g.passed, "passed,", g.failed, "failed")
    if g.failed > 0:
        raise Error("delta witness failed")
