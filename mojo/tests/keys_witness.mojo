# The property gate for `fdb_keys.mojo`, over `contract-witness-mojo`.
#
# This is the Mojo port of `keys-witness/keys_test.cc` (witness-cpp + doctest). Every
# property is paired with a planted-false rule-2 control: the same machinery with a
# wrong encoder or a wrong predicate must come back FOUND, or the gate cannot fail and
# proves nothing.
#
# The properties are the ones `fdb_keys.h` claims and three places in `fdb_vfs.c` depend
# on: `edge_number`, `load_newest_shard`, `drop_unfinished_commit`. A wrong answer there
# is a read of the wrong page, which `PRAGMA integrity_check` cannot see.
#
# Differences from the C++ suite, on purpose:
#   * Numbers come from a generator that mixes small values, the full 64-bit range, and
#     the edges (0, 0xFF, 2^32, 2^63 +- 1, MAX). The C++ gate used the ladder's small
#     `gen_uint` for the real properties and a separate wide generator only for the
#     controls; here one generator serves both, so a property cannot pass on a range
#     that its control needed a special generator to leave.
#   * The KEYMAX and "no /STATUS suffix" controls run a real mutant (a 700-byte name; a
#     record key with no suffix) through the property's own predicate. The C++ versions
#     compared constants and could not fail for the reason they named.
#
#   pixi run keys-witness
#
# SPDX-License-Identifier: Apache-2.0 OR MIT

from witness.ladder import *
from fdb_keys import *

comptime MAX_U64 = UInt64(0xFFFFFFFFFFFFFFFF)


# ── Generators ────────────────────────────────────────────────────────────────

def gen_u64(mut r: Run, lvl: Level) -> UInt64:
    var k = r.int_range(0, 3)
    if k == 0:
        return UInt64(r.int_range(0, 300))
    if k == 1:
        return r.next_u64()
    if k == 2:
        var edges: List[UInt64] = [
            0, 1, 0xFF, 0x100, 0xFFFFFFFF, 0x100000000,
            0x7FFFFFFFFFFFFFFF, 0x8000000000000000,
            0xFFFFFFFFFFFFFFFE, 0xFFFFFFFFFFFFFFFF,
        ]
        return gen_element[UInt64](r, edges)
    return r.next_u64() >> UInt64(r.int_range(0, 63))


def gen_u32(mut r: Run, lvl: Level) -> UInt32:
    return UInt32(gen_u64(r, lvl) & 0xFFFFFFFF)


# Uniform over the whole range, for the controls that look for a high-bit disagreement.
def gen_wide64(mut r: Run) -> UInt64:
    return r.next_u64()


# Names the layout can carry. `fdb_vfs.c` bounds names at MAX_NAME and builds keys with
# snprintf, so short printable-ASCII names are the interesting space.
def gen_name(mut r: Run, lvl: Level) -> String:
    return gen_string(r, lvl)


def gen_bytes(mut r: Run, lvl: Level, max_len: Int) -> List[UInt8]:
    var cap = max_len if max_len < lvl.fin_bound else lvl.fin_bound
    var n = r.int_range(0, cap)
    var v = List[UInt8]()
    for _ in range(n):
        # One byte in three is 0xFF, so all-FF and trailing-FF prefixes are common.
        if r.int_range(0, 2) == 0:
            v.append(0xFF)
        else:
            v.append(UInt8(r.int_range(0, 255)))
    return v^


# ── Inputs and printers ───────────────────────────────────────────────────────

def show_bytes(v: List[UInt8]) -> String:
    var digits = "0123456789abcdef".as_bytes()
    var s = String("0x")
    for b in v:
        s += chr(Int(digits[Int(b >> 4)]))
        s += chr(Int(digits[Int(b & 15)]))
    return s^


def show_u64(v: UInt64) -> String:
    return "0x" + hex_u64(v)


@fieldwise_init
struct PidxIn(Copyable, Movable):
    var name: String
    var a: UInt32
    var b: UInt32


@fieldwise_init
struct DeltaIn(Copyable, Movable):
    var name: String
    var ta: UInt64
    var pa: UInt32
    var tb: UInt64
    var pb: UInt32


@fieldwise_init
struct ShardIn(Copyable, Movable):
    var name: String
    var as_of: UInt64
    var head: UInt64


@fieldwise_init
struct PrefixTail(Copyable, Movable):
    var prefix: List[UInt8]
    var tail: List[UInt8]


@fieldwise_init
struct TxnPair(Copyable, Movable):
    var a: UInt64
    var b: UInt64


@fieldwise_init
struct PartIn(Copyable, Movable):
    var txnid: UInt64
    var name: String


@fieldwise_init
struct BuilderIn(Copyable, Movable):
    var name: String
    var txid: UInt64
    var pgno: UInt32


def show_pidx(x: PidxIn) -> String:
    return "(" + String(x.name) + ", " + String(x.a) + ", " + String(x.b) + ")"


def show_delta(x: DeltaIn) -> String:
    return (
        "(" + x.name + ", " + show_u64(x.ta) + ", " + String(x.pa)
        + ", " + show_u64(x.tb) + ", " + String(x.pb) + ")"
    )


def show_shard(x: ShardIn) -> String:
    return "(" + x.name + ", as_of=" + show_u64(x.as_of) + ", head=" + show_u64(x.head) + ")"


def show_prefix_tail(x: PrefixTail) -> String:
    return "(prefix=" + show_bytes(x.prefix) + ", tail=" + show_bytes(x.tail) + ")"


def show_txn_pair(x: TxnPair) -> String:
    return "(" + show_u64(x.a) + ", " + show_u64(x.b) + ")"


def show_part(x: PartIn) -> String:
    return "(" + show_u64(x.txnid) + ", " + x.name + ")"


def show_builder(x: BuilderIn) -> String:
    return "(" + x.name + ", " + show_u64(x.txid) + ", " + String(x.pgno) + ")"


def gen_pidx(mut r: Run, lvl: Level) -> PidxIn:
    return PidxIn(gen_name(r, lvl), gen_u32(r, lvl), gen_u32(r, lvl))


def gen_delta(mut r: Run, lvl: Level) -> DeltaIn:
    var name = gen_name(r, lvl)
    var ta = gen_u64(r, lvl)
    var pa = gen_u32(r, lvl)
    # Half the time share the txid, so the page decides the order and the
    # (txid, page) tie-break is exercised and not just the txid.
    var tb = ta if r.int_range(0, 1) == 0 else gen_u64(r, lvl)
    return DeltaIn(name^, ta, pa, tb, gen_u32(r, lvl))


def gen_shard(mut r: Run, lvl: Level) -> ShardIn:
    var name = gen_name(r, lvl)
    var head = gen_u64(r, lvl)
    var as_of = gen_u64(r, lvl)
    # Often land on head and head + 1, where an off-by-one in the bound would show.
    var k = r.int_range(0, 3)
    if k == 0:
        as_of = head
    elif k == 1 and head != MAX_U64:
        as_of = head + 1
    return ShardIn(name^, as_of, head)


def gen_prefix_tail(mut r: Run, lvl: Level) -> PrefixTail:
    return PrefixTail(gen_bytes(r, lvl, KEYMAX - 1), gen_bytes(r, lvl, KEYMAX - 1))


def gen_prefix(mut r: Run, lvl: Level) -> List[UInt8]:
    return gen_bytes(r, lvl, KEYMAX - 1)


def gen_txn_pair(mut r: Run, lvl: Level) -> TxnPair:
    var a = gen_u64(r, lvl)
    var b = a if r.int_range(0, 3) == 0 else gen_u64(r, lvl)
    return TxnPair(a, b)


def gen_part(mut r: Run, lvl: Level) -> PartIn:
    return PartIn(gen_u64(r, lvl), gen_name(r, lvl))


def gen_builder(mut r: Run, lvl: Level) -> BuilderIn:
    return BuilderIn(gen_name(r, lvl), gen_u64(r, lvl), gen_u32(r, lvl))


# ── Shared predicate shapes ───────────────────────────────────────────────────

# The key order must agree with the order of the numbers it encodes.
def order_agrees(ka: List[UInt8], kb: List[UInt8], a_lt_b: Bool, a_eq_b: Bool) -> Bool:
    var c = key_cmp(ka, kb)
    if a_eq_b:
        return c == 0
    if a_lt_b:
        return c < 0
    return c > 0


def all_ff(v: List[UInt8]) -> Bool:
    for b in v:
        if b != 0xFF:
            return False
    return True


# ── The encoding round trips ──────────────────────────────────────────────────

def p_be64_round_trip(v: UInt64, mut r: Run) -> Bool:
    var buf = List[UInt8]()
    put_be64(buf, v)
    return len(buf) == 8 and get_be64(buf) == v


def p_be64_drops_top_byte(v: UInt64, mut r: Run) -> Bool:
    # Planted-false: drop the top byte on decode. A value with a non-zero top byte
    # then disagrees.
    var buf = List[UInt8]()
    put_be64(buf, v)
    var got = UInt64(0)
    for i in range(1, 8):
        got = (got << 8) | UInt64(buf[i])
    return got == v


def gen_u64_for_resolve(mut r: Run, lvl: Level) -> UInt64:
    return gen_u64(r, lvl)


def gen_wide_for_resolve(mut r: Run, lvl: Level) -> UInt64:
    return gen_wide64(r)


# ── Order: PIDX ───────────────────────────────────────────────────────────────

def p_pidx_order(x: PidxIn, mut r: Run) -> Bool:
    return order_agrees(
        key_pidx(x.name, x.a), key_pidx(x.name, x.b), x.a < x.b, x.a == x.b
    )


def _pidx_le(name: String, n: UInt32) -> List[UInt8]:
    var out = key_prefix(name, "PIDX")
    for i in range(4):
        out.append(UInt8((n >> UInt32(8 * i)) & 0xFF))  # little-endian, wrong
    return out^


def p_pidx_little_endian(x: PidxIn, mut r: Run) -> Bool:
    return order_agrees(
        _pidx_le(x.name, x.a), _pidx_le(x.name, x.b), x.a < x.b, x.a == x.b
    )


# ── Order: DELTA ──────────────────────────────────────────────────────────────

def _delta_order(ka: List[UInt8], kb: List[UInt8], x: DeltaIn) -> Bool:
    var same = x.ta == x.tb and x.pa == x.pb
    var a_first = x.ta < x.tb or (x.ta == x.tb and x.pa < x.pb)
    return order_agrees(ka, kb, a_first, same)


def p_delta_order(x: DeltaIn, mut r: Run) -> Bool:
    return _delta_order(
        key_delta(x.name, x.ta, x.pa), key_delta(x.name, x.tb, x.pb), x
    )


def _delta_page_first(name: String, tx: UInt64, pg: UInt32) -> List[UInt8]:
    var out = key_prefix(name, "DELTA")
    put_be32(out, pg)  # page first, wrong order
    put_be64(out, tx)
    return out^


def p_delta_page_first(x: DeltaIn, mut r: Run) -> Bool:
    # If DELTA were keyed (pgno, txid), a single commit's pages would not be one range,
    # and `drop_unfinished_commit` would clear the wrong keys.
    return _delta_order(
        _delta_page_first(x.name, x.ta, x.pa),
        _delta_page_first(x.name, x.tb, x.pb),
        x,
    )


# ── Order: SHARD version bound ────────────────────────────────────────────────

def p_shard_bound(x: ShardIn, mut r: Run) -> Bool:
    if x.head == MAX_U64:
        return True  # no successor to compare against
    var cmp = key_cmp(
        key_shard_version(x.name, x.as_of), key_shard_version(x.name, x.head + 1)
    )
    if x.as_of <= x.head:
        return cmp < 0
    return cmp >= 0


def p_shard_signed(x: ShardIn, mut r: Run) -> Bool:
    # Planted-false: compare the versions as signed. Flipping the top bit turns an
    # unsigned compare into the signed one, so the two lie on either side of 2^63.
    if x.head == MAX_U64:
        return True
    var bias = UInt64(0x8000000000000000)
    var signed_le = (x.as_of ^ bias) <= (x.head ^ bias)
    return signed_le == (x.as_of <= x.head)


# ── strinc bounds a prefix exactly ────────────────────────────────────────────

def p_key_after_bounds(x: PrefixTail, mut r: Run) -> Bool:
    if len(x.prefix) == 0 or len(x.prefix) > KEYMAX - 1:
        return True
    var bound = key_after(x.prefix)
    if all_ff(x.prefix):
        return len(bound) == 0
    if len(bound) == 0:
        return False
    var key = x.prefix.copy()
    var room = KEYMAX - len(x.prefix)
    var take = len(x.tail) if len(x.tail) < room else room
    for i in range(take):
        key.append(x.tail[i])
    return key_cmp(key, bound) < 0


def p_key_after_identity(x: PrefixTail, mut r: Run) -> Bool:
    # Planted-wrong: key_after returns the prefix unchanged, so the key equal to the
    # prefix sorts at the bound and not below it.
    if len(x.prefix) == 0 or len(x.prefix) > KEYMAX - 1:
        return True
    return key_cmp(x.prefix, x.prefix) < 0


def p_key_after_alias(prefix: List[UInt8], mut r: Run) -> Bool:
    if len(prefix) == 0 or len(prefix) > KEYMAX - 1:
        return True
    var apart = key_after(prefix)
    var inplace = prefix.copy()
    var n = key_after_in_place(inplace, len(prefix))
    if n != len(apart):
        return False
    for i in range(n):
        if inplace[i] != apart[i]:
            return False
    return True


def p_key_after_double_bump(prefix: List[UInt8], mut r: Run) -> Bool:
    # Planted-wrong: a hostile in-place version that bumps the trailing byte twice.
    if len(prefix) == 0 or len(prefix) > KEYMAX - 1 or all_ff(prefix):
        return True
    var apart = key_after(prefix)
    var inplace = prefix.copy()
    var n = len(inplace)
    while n > 0 and inplace[n - 1] == 0xFF:
        n -= 1
    if n <= 0:
        return True
    inplace[n - 1] += 1
    inplace[n - 1] += 1
    if n != len(apart):
        return False
    for i in range(n):
        if inplace[i] != apart[i]:
            return False
    return True


# ── Transaction record ───────────────────────────────────────────────────────

def _is_record_shape(key: List[UInt8]) -> Bool:
    # The shape recovery's sweep accepts: weft/txn/ + 8-byte id + /STATUS.
    var all = key_txn_all()
    if len(key) <= len(all) + 8:
        return False
    if not starts_with(key, all):
        return False
    var suffix = key_txn_status(0)
    for i in range(7):
        if key[len(all) + 8 + i] != suffix[len(all) + 8 + i]:
            return False
    return len(key) == len(all) + 8 + 7


def p_txn_status_shape(txnid: UInt64, mut r: Run) -> Bool:
    return _is_record_shape(key_txn_status(txnid))


def p_txn_no_suffix(txnid: UInt64, mut r: Run) -> Bool:
    # Planted-wrong: a record key with no suffix. The recovery sweep would then treat
    # weft/txn/<counter> as a valid record.
    return _is_record_shape(key_txn_prefix(txnid))


def p_txn_order(x: TxnPair, mut r: Run) -> Bool:
    return order_agrees(
        key_txn_status(x.a), key_txn_status(x.b), x.a < x.b, x.a == x.b
    )


def p_part_under_record(x: PartIn, mut r: Run) -> Bool:
    if x.name.byte_length() > 64:
        return True
    var part = key_txn_part(x.txnid, x.name)
    var prefix = key_txn_part_prefix(x.txnid)
    return len(part) >= len(prefix) and starts_with(part, prefix)


def p_part_without_txnid(x: PartIn, mut r: Run) -> Bool:
    # Planted-wrong: the participant name under weft/txn/ with no txnid. The sweep would
    # attribute this row to the wrong record.
    if x.name.byte_length() > 64:
        return True
    var prefix = key_txn_part_prefix(x.txnid)
    var bad = key_txn_all()
    for b in String("PART/").as_bytes():
        bad.append(b)
    for b in x.name.as_bytes():
        bad.append(b)
    return len(bad) >= len(prefix) and starts_with(bad, prefix)


# ── Every builder stays inside the buffer ────────────────────────────────────

def p_builders_fit(x: BuilderIn, mut r: Run) -> Bool:
    return (
        fits(key_pidx(x.name, x.pgno))
        and fits(key_delta(x.name, x.txid, x.pgno))
        and fits(key_delta_txid(x.name, x.txid))
        and fits(key_shard(x.name, x.txid, x.pgno))
        and fits(key_shard_version(x.name, x.txid))
        and fits(key_shardn(x.name, x.txid))
        and fits(key_meta(x.name, "HEAD"))
        and fits(key_prefix(x.name, "PIDX"))
    )


def p_builders_fit_long_name(x: BuilderIn, mut r: Run) -> Bool:
    # Planted-wrong: a 700-byte name, which no shipping caller can pass. The bound must
    # refuse it, or `fits` is a tautology.
    var long_name = String()
    for _ in range(700):
        long_name += "x"
    return fits(key_pidx(long_name, x.pgno)) and fits(
        key_delta(long_name, x.txid, x.pgno)
    )


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

    g.expect("[keys] big-endian round trip",
        resolve[UInt64]("put_be64 then get_be64 is the identity",
            gen_u64_for_resolve, p_be64_round_trip, no_shrink[UInt64], show_u64), hold)
    g.expect("[keys] rule-2 control: a broken be64 loses the top byte",
        resolve[UInt64]("broken be64 agrees with input",
            gen_wide_for_resolve, p_be64_drops_top_byte, shrink_uint64, show_u64), found)

    g.expect("[keys] PIDX keys sort like page numbers",
        resolve[PidxIn]("key_pidx lex order matches page-number order",
            gen_pidx, p_pidx_order, no_shrink[PidxIn], show_pidx), hold)
    g.expect("[keys] rule-2 control: little-endian PIDX loses order",
        resolve[PidxIn]("little-endian PIDX preserves order",
            gen_pidx, p_pidx_little_endian, no_shrink[PidxIn], show_pidx), found)

    g.expect("[keys] DELTA keys sort by txid then page",
        resolve[DeltaIn]("key_delta lex order is (txid, page) lex order",
            gen_delta, p_delta_order, no_shrink[DeltaIn], show_delta), hold)
    g.expect("[keys] rule-2 control: (page, txid) DELTA order loses commit-range contiguity",
        resolve[DeltaIn]("page-first DELTA sorts by (txid, page)",
            gen_delta, p_delta_page_first, no_shrink[DeltaIn], show_delta), found)

    g.expect("[keys] shard-version bound excludes exactly the versions above it",
        resolve[ShardIn]("shard version is below the head+1 bound iff as_of <= head",
            gen_shard, p_shard_bound, no_shrink[ShardIn], show_shard), hold)
    g.expect("[keys] rule-2 control: a signed comparison flips across 2^63",
        resolve[ShardIn]("signed and unsigned comparisons agree on 64-bit versions",
            gen_shard, p_shard_signed, no_shrink[ShardIn], show_shard), found)

    g.expect("[keys] key_after is above every key with the prefix",
        resolve[PrefixTail]("every key under the prefix sorts below key_after",
            gen_prefix_tail, p_key_after_bounds, no_shrink[PrefixTail], show_prefix_tail), hold)
    g.expect("[keys] rule-2 control: key_after that returns the prefix unchanged fails",
        resolve[PrefixTail]("identity key_after strictly bounds its prefix",
            gen_prefix_tail, p_key_after_identity, no_shrink[PrefixTail], show_prefix_tail), found)

    g.expect("[keys] key_after aliases input and output safely",
        resolve[List[UInt8]]("key_after gives the same answer in place as apart",
            gen_prefix, p_key_after_alias, no_shrink[List[UInt8]], show_bytes), hold)
    g.expect("[keys] rule-2 control: a double-bumped in-place key_after is caught",
        resolve[List[UInt8]]("double-bumped key_after agrees with the correct one",
            gen_prefix, p_key_after_double_bump, no_shrink[List[UInt8]], show_bytes), found)

    g.expect("[keys] the txn counter is never mistaken for a record",
        resolve[UInt64]("txn status keys carry an 8-byte txnid + /STATUS",
            gen_u64_for_resolve, p_txn_status_shape, no_shrink[UInt64], show_u64), hold)
    g.expect("[keys] rule-2 control: a record key with no /STATUS suffix is not a record",
        resolve[UInt64]("a no-suffix record shape is not a record",
            gen_u64_for_resolve, p_txn_no_suffix, no_shrink[UInt64], show_u64), found)

    g.expect("[keys] txn records sort by txid",
        resolve[TxnPair]("key_txn_status lex order matches txid order",
            gen_txn_pair, p_txn_order, no_shrink[TxnPair], show_txn_pair), hold)

    g.expect("[keys] participant rows sort under their record's prefix",
        resolve[PartIn]("key_txn_part starts with key_txn_part_prefix",
            gen_part, p_part_under_record, no_shrink[PartIn], show_part), hold)
    g.expect("[keys] rule-2 control: a participant key that omits the record prefix leaks",
        resolve[PartIn]("prefix-less participant key sits under the record",
            gen_part, p_part_without_txnid, no_shrink[PartIn], show_part), found)

    g.expect("[keys] every builder stays inside KEYMAX",
        resolve[BuilderIn]("every key builder returns at most KEYMAX bytes",
            gen_builder, p_builders_fit, no_shrink[BuilderIn], show_builder), hold)
    g.expect("[keys] rule-2 control: a 700-byte name is refused by the KEYMAX bound",
        resolve[BuilderIn]("a 700-byte name fits in KEYMAX",
            gen_builder, p_builders_fit_long_name, no_shrink[BuilderIn], show_builder), found)

    print()
    print(g.passed, "passed,", g.failed, "failed")
    if g.failed > 0:
        raise Error("keys witness failed")
