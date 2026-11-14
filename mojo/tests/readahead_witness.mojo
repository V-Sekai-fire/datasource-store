# The property gate for `read_ahead.mojo`, over `contract-witness-mojo`.
#
# What `fdb_vfs.c` says the scorer does, as properties: a point read pays for no read-ahead,
# a table scan escalates after three pages and reaches full depth at five, a scan holds its
# credit through a little noise but not through a run of it, and the score stays in range.
# `should_compact` fires when the log is as large as the base and never on a quiet actor.
# Each property has a planted-false control: a deliberately wrong scorer, run through the same
# predicate, must come back FOUND. The mutants live in this file, as `depth_v`.
#
# These are claims from the C's comments and the model it cites; `spec/ReadAhead.lean` models
# the window a prefetch fills, not the scorer, so there is no proof here to restate.
#
#   pixi run readahead-witness
#
# SPDX-License-Identifier: Apache-2.0 OR MIT

from witness.ladder import *
from read_ahead import *


# Variant 0 is the port. The others are the controls' wrong scorers.
def depth_v(mut ra: ReadAhead, pgno: Int, variant: Int) -> Int:
    if variant == 0:
        return ra.depth(pgno)
    var gap = pgno - ra.last
    if variant == 3 and gap < 0:
        gap = -gap  # a backward step counts as forward
    if gap > 0 and gap <= RA_GAP:
        ra.score += 1 if variant == 2 else RA_SCORE_STEP
        if variant != 1 and ra.score > RA_SCORE_CAP:
            ra.score = RA_SCORE_CAP
    elif ra.score >= RA_ESCALATE:
        ra.score -= 2 if variant == 4 else RA_DECAY_SCANNING
    else:
        ra.score -= 2 if variant == 5 else RA_DECAY_RANDOM
        if ra.score < 0:
            ra.score = 0
    ra.last = pgno
    if ra.score >= RA_FULL:
        return RA_MAX_PAGES
    if ra.score >= RA_ESCALATE:
        return RA_STEP_PAGES
    return 0


# ── Inputs ────────────────────────────────────────────────────────────────────

@fieldwise_init
struct Pages(Copyable, Movable):
    var pages: List[Int]


@fieldwise_init
struct Scan(Copyable, Movable):
    var gaps: List[Int]  # forward steps of 1 to 8 pages


@fieldwise_init
struct Noisy(Copyable, Movable):
    var gaps: List[Int]  # a scan of 1 to 8 page steps, long enough to reach the cap
    var jumps: List[Int]  # how far each noise jump lands from where the scan was


def show_ints(v: List[Int]) -> String:
    var s = String("[")
    for i in range(len(v)):
        if i > 0:
            s += ", "
        s += String(v[i])
    return s + "]"


def show_pages(x: Pages) -> String:
    return show_ints(x.pages)


def show_scan(x: Scan) -> String:
    return show_ints(x.gaps)


def show_noisy(x: Noisy) -> String:
    return "(scan=" + show_ints(x.gaps) + ", jumps=" + show_ints(x.jumps) + ")"


# Any mix: forward steps, repeats, backward steps, far jumps, the top of the 32-bit range.
def gen_pages(mut r: Run, lvl: Level) -> Pages:
    var v = List[Int]()
    var cur = r.int_range(0, 64)
    for _ in range(r.int_range(1, 60)):
        var k = r.int_range(0, 5)
        if k <= 1:
            cur += r.int_range(1, 8)
        elif k == 2:
            cur += r.int_range(9, 5000)
        elif k == 3:
            cur = cur - r.int_range(0, 40) if cur > 40 else cur
        elif k == 4:
            cur = r.int_range(0, 100000)
        else:
            cur = 0xFFFFFFFF - r.int_range(0, 3)
        v.append(cur)
    return Pages(v^)


# Pages none of which is a forward step of 1 to 8: a repeat, a step back, or a jump of 9+.
def gen_point_reads(mut r: Run, lvl: Level) -> Pages:
    var v = List[Int]()
    var last = 0
    for _ in range(r.int_range(1, 60)):
        var next: Int
        if r.int_range(0, 2) == 0:
            next = last + r.int_range(9, 5000)
        elif r.int_range(0, 1) == 0:
            next = last - r.int_range(0, 8) if last >= 8 else last
        else:
            next = r.int_range(0, 100000)
        var gap = next - last
        if gap > 0 and gap <= 8:
            next = last + 9
        v.append(next)
        last = next
    return Pages(v^)


def gen_scan(mut r: Run, lvl: Level) -> Scan:
    var v = List[Int]()
    for _ in range(r.int_range(1, 12)):
        v.append(r.int_range(1, 8))
    return Scan(v^)


# A scan long enough to reach the cap, then noise.
def gen_noisy(mut r: Run, lvl: Level) -> Noisy:
    var gaps = List[Int]()
    for _ in range(r.int_range(6, 12)):
        gaps.append(r.int_range(1, 8))
    var jumps = List[Int]()
    for _ in range(r.int_range(0, 9)):
        jumps.append(r.int_range(0, 5000))
    return Noisy(gaps^, jumps^)


# ── The score stays in range, and the depth follows it ────────────────────────

def _depth_of(score: Int) -> Int:
    if score >= 10:
        return 256
    if score >= 6:
        return 32
    return 0


def p_invariants_v(x: Pages, variant: Int, mut r: Run) -> Bool:
    var ra = ReadAhead()
    for p in x.pages:
        var d = depth_v(ra, p, variant)
        if ra.score < 0 or ra.score > 12 or ra.last != p:
            return False
        if d != _depth_of(ra.score):
            return False
    return True


def p_invariants(x: Pages, mut r: Run) -> Bool:
    return p_invariants_v(x, 0, r)


def p_invariants_no_cap(x: Pages, mut r: Run) -> Bool:
    return p_invariants_v(x, 1, r)


# ── A table scan escalates after three pages and is at full depth by the fifth ─

def p_scan_v(x: Scan, variant: Int, mut r: Run) -> Bool:
    var ra = ReadAhead()
    var pg = 0
    for i in range(len(x.gaps)):
        pg += x.gaps[i]
        var d = depth_v(ra, pg, variant)
        var n = i + 1
        var want = 0
        if n >= 5:
            want = 256
        elif n >= 3:
            want = 32
        if d != want:
            return False
    return True


def p_scan(x: Scan, mut r: Run) -> Bool:
    return p_scan_v(x, 0, r)


def p_scan_slow_step(x: Scan, mut r: Run) -> Bool:
    return p_scan_v(x, 2, r)


# ── A point read pays for no read-ahead ───────────────────────────────────────

def p_point_v(x: Pages, variant: Int, mut r: Run) -> Bool:
    var ra = ReadAhead()
    for p in x.pages:
        if depth_v(ra, p, variant) != 0:
            return False
    return True


def p_point(x: Pages, mut r: Run) -> Bool:
    return p_point_v(x, 0, r)


def p_point_backward_counts(x: Pages, mut r: Run) -> Bool:
    return p_point_v(x, 3, r)


# ── A random page with no scan running costs four points, and the score stops at 0 ──

# Depth cannot show this: the thresholds are even and an extra point is odd. So it reads the
# score. After one or two forward steps (2 or 4 points) a random page leaves exactly 0.
def p_random_decay_v(x: Scan, variant: Int, mut r: Run) -> Bool:
    var ra = ReadAhead()
    var pg = 0
    var steps = 1 + len(x.gaps) % 2
    for i in range(steps):
        pg += x.gaps[i % len(x.gaps)]
        _ = depth_v(ra, pg, variant)
    _ = depth_v(ra, pg + 9 + x.gaps[0], variant)
    return ra.score == 0


def p_random_decay(x: Scan, mut r: Run) -> Bool:
    return p_random_decay_v(x, 0, r)


def p_random_decay_two(x: Scan, mut r: Run) -> Bool:
    return p_random_decay_v(x, 5, r)


# ── A scan holds its credit through noise, but only a little ──────────────────

# From the cap of 12, each random page costs 1 while the scan is running, so six of them
# leave it escalated and the seventh ends it.
def p_noise_v(x: Noisy, variant: Int, mut r: Run) -> Bool:
    var ra = ReadAhead()
    var pg = 0
    for g in x.gaps:
        pg += g
        _ = depth_v(ra, pg, variant)
    if ra.score != 12:
        return True  # a short scan never reached the cap; nothing to say
    for k in range(len(x.jumps)):
        var d = depth_v(ra, pg + 9 + x.jumps[k], variant)
        pg = ra.last
        if (d > 0) != (k + 1 <= 6):
            return False
    return True


def p_noise(x: Noisy, mut r: Run) -> Bool:
    return p_noise_v(x, 0, r)


def p_noise_fast_decay(x: Noisy, mut r: Run) -> Bool:
    return p_noise_v(x, 4, r)


# ── The compaction trigger ────────────────────────────────────────────────────

@fieldwise_init
struct Sizes(Copyable, Movable):
    var log: UInt64
    var base: UInt64


def gen_sizes(mut r: Run, lvl: Level) -> Sizes:
    var log = UInt64(r.int_range(0, 300))
    if r.int_range(0, 3) == 0:
        log = r.next_u64()
    var base = log
    var k = r.int_range(0, 4)
    if k == 1:
        base = UInt64(r.int_range(0, 300))
    elif k == 2 and log != 0xFFFFFFFFFFFFFFFF:
        base = log + 1
    elif k == 3 and log != 0:
        base = log - 1
    elif k == 4:
        base = r.next_u64()
    return Sizes(log, base)


def show_sizes(x: Sizes) -> String:
    return "(log=" + String(x.log) + ", base=" + String(x.base) + ")"


def p_compact(x: Sizes, mut r: Run) -> Bool:
    r.classify(x.log == x.base, "log equals base")
    r.classify(x.log == 0, "quiet")
    if x.log == 0:
        return not should_compact(x.log, x.base)  # a quiet actor never compacts
    if x.log >= x.base:
        return should_compact(x.log, x.base)  # as large as the base, or larger
    return not should_compact(x.log, x.base)


def p_compact_strict(x: Sizes, mut r: Run) -> Bool:
    # Planted-false: fold only when the log is strictly larger. At equal sizes it would wait.
    var strict = x.log > 0 and x.base < x.log
    if x.log == 0:
        return not strict
    if x.log >= x.base:
        return strict
    return not strict


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

    g.expect("[readahead] the score stays in 0..12 and the depth follows it",
        resolve[Pages]("score range, last page, and depth thresholds hold on any access mix",
            gen_pages, p_invariants, no_shrink[Pages], show_pages), hold)
    g.expect("[readahead] rule-2 control: a scorer with no cap is caught",
        resolve[Pages]("an uncapped score stays in range",
            gen_pages, p_invariants_no_cap, no_shrink[Pages], show_pages), found)

    g.expect("[readahead] a scan escalates on its third page and is at full depth on its fifth",
        resolve[Scan]("depth after n forward steps is 0, 0, 32, 32, then 256",
            gen_scan, p_scan, no_shrink[Scan], show_scan), hold)
    g.expect("[readahead] rule-2 control: a scorer that steps by one is caught",
        resolve[Scan]("a one-point step escalates on the third page",
            gen_scan, p_scan_slow_step, no_shrink[Scan], show_scan), found)

    g.expect("[readahead] a point read pays for no read-ahead",
        resolve[Pages]("no run of repeats, steps back and far jumps ever escalates",
            gen_point_reads, p_point, no_shrink[Pages], show_pages), hold)
    g.expect("[readahead] rule-2 control: a scorer that counts a step back as forward is caught",
        resolve[Pages]("backward steps never escalate",
            gen_point_reads, p_point_backward_counts, no_shrink[Pages], show_pages), found)

    g.expect("[readahead] a random page with no scan running costs four points and stops at 0",
        resolve[Scan]("after one or two forward steps a random page leaves score 0",
            gen_scan, p_random_decay, no_shrink[Scan], show_scan), hold)
    g.expect("[readahead] rule-2 control: a decay of two is caught",
        resolve[Scan]("a two-point random decay leaves score 0 after two forward steps",
            gen_scan, p_random_decay_two, no_shrink[Scan], show_scan), found)

    g.expect("[readahead] a scan holds through six random pages and not a seventh",
        resolve[Noisy]("from the cap, depth is above 0 for exactly six random pages",
            gen_noisy, p_noise, no_shrink[Noisy], show_noisy), hold)
    g.expect("[readahead] rule-2 control: a scorer that decays by two is caught",
        resolve[Noisy]("a two-point decay holds through six random pages",
            gen_noisy, p_noise_fast_decay, no_shrink[Noisy], show_noisy), found)

    g.expect("[readahead] the log folds when it is as large as the base, and never when quiet",
        resolve[Sizes]("should_compact is log > 0 and base <= log",
            gen_sizes, p_compact, no_shrink[Sizes], show_sizes), hold)
    g.expect("[readahead] rule-2 control: a strict comparison is caught",
        resolve[Sizes]("a strict trigger folds at equal sizes",
            gen_sizes, p_compact_strict, no_shrink[Sizes], show_sizes), found)

    print()
    print(g.passed, "passed,", g.failed, "failed")
    if g.failed > 0:
        raise Error("read-ahead witness failed")
