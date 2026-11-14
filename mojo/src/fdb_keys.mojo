# The keys of the store layout. Port of `fdb_keys.h`.
#
# This is layer 1 of the four `fdb_vfs.c` describes, split out so it can be tested
# without FoundationDB or SQLite. Nothing here does I/O or holds state: a key is a
# `List[UInt8]` the caller owns.
#
# A number goes into a key big endian, so the order of the keys is the order of the
# numbers. That is not a convenience. `edge_number` finds the newest shard version and
# the oldest pin by reading the edge of a range, `load_newest_shard` trusts that order,
# and `drop_unfinished_commit` clears a range that starts at a number. If the encoding
# ever stopped being order preserving, each of those would read the wrong row and none of
# them would fail loudly. `tests/keys_witness.mojo` holds that property and the ones
# below.
#
# What differs from the C header: a builder returns the key instead of writing into a
# buffer and returning a length, and it does not truncate. The C `snprintf` clips a long
# name at KEYMAX; here a name that would not fit makes a key longer than KEYMAX, which
# `fits()` reports and the witness checks. `fdb_vfs.c` bounds names at MAX_NAME, so the
# case does not arise in shipping code.
#
# SPDX-License-Identifier: Apache-2.0 OR MIT

# The largest key this layout builds. A name is bounded, and every suffix is a fixed
# number of bytes, so this bounds them all.
comptime KEYMAX = 640

# Status values. They are written as one byte, because the set is closed and a string
# would invite a fifth state that the state machine does not have.
comptime TXN_STAGING = 1
comptime TXN_COMMITTED = 2
comptime TXN_ABORTED = 3


def put_be32(mut out: List[UInt8], v: UInt32):
    for i in range(4):
        out.append(UInt8((v >> UInt32(24 - 8 * i)) & 0xFF))


def put_be64(mut out: List[UInt8], v: UInt64):
    for i in range(8):
        out.append(UInt8((v >> UInt64(56 - 8 * i)) & 0xFF))


def get_be64(data: List[UInt8], at: Int = 0) -> UInt64:
    var v = UInt64(0)
    for i in range(8):
        v = (v << 8) | UInt64(data[at + i])
    return v


def _text(mut out: List[UInt8], s: String):
    for b in s.as_bytes():
        out.append(b)


def _db_prefix(name: String, what: String) -> List[UInt8]:
    var out = List[UInt8]()
    _text(out, "weft/db/")
    _text(out, name)
    _text(out, "/")
    _text(out, what)
    _text(out, "/")
    return out^


def fits(key: List[UInt8]) -> Bool:
    return len(key) <= KEYMAX


def key_meta(name: String, what: String) -> List[UInt8]:
    var out = List[UInt8]()
    _text(out, "weft/db/")
    _text(out, name)
    _text(out, "/")
    _text(out, what)
    return out^


def key_pidx(name: String, pgno: UInt32) -> List[UInt8]:
    var out = _db_prefix(name, "PIDX")
    put_be32(out, pgno)
    return out^


def key_delta(name: String, txid: UInt64, pgno: UInt32) -> List[UInt8]:
    var out = _db_prefix(name, "DELTA")
    put_be64(out, txid)
    put_be32(out, pgno)
    return out^


def key_delta_txid(name: String, txid: UInt64) -> List[UInt8]:
    var out = _db_prefix(name, "DELTA")
    put_be64(out, txid)
    return out^


def key_shard(name: String, as_of: UInt64, pgno: UInt32) -> List[UInt8]:
    var out = _db_prefix(name, "SHARD")
    put_be64(out, as_of)
    put_be32(out, pgno)
    return out^


def key_shard_version(name: String, as_of: UInt64) -> List[UInt8]:
    var out = _db_prefix(name, "SHARD")
    put_be64(out, as_of)
    return out^


def key_shardn(name: String, as_of: UInt64) -> List[UInt8]:
    var out = _db_prefix(name, "SHARDN")
    put_be64(out, as_of)
    return out^


def key_prefix(name: String, what: String) -> List[UInt8]:
    return _db_prefix(name, what)


# ── The transaction record ────────────────────────────────────────────────────
#
# A commit that spans several databases cannot be one database's transaction, and
# `flush` is scoped to one file. So a group of them shares a record, which is what
# ParallelCommits.tla calls the transaction record:
#
#   weft/txn/<txnid>/STATUS        staging, committed, or aborted
#   weft/txn/<txnid>/PART/<name>   a participant, and the txid it staged under
#
# The record lives outside `weft/db/`, because it belongs to no single database. A
# participant row names a database and the staged txid its pages went under, which is
# the only thing recovery needs to find them again.


def key_txn_prefix(txnid: UInt64) -> List[UInt8]:
    var out = List[UInt8]()
    _text(out, "weft/txn/")
    put_be64(out, txnid)
    return out^


def key_txn_status(txnid: UInt64) -> List[UInt8]:
    var out = key_txn_prefix(txnid)
    _text(out, "/STATUS")
    return out^


def key_txn_part_prefix(txnid: UInt64) -> List[UInt8]:
    var out = key_txn_prefix(txnid)
    _text(out, "/PART/")
    return out^


def key_txn_part(txnid: UInt64, name: String) -> List[UInt8]:
    var out = key_txn_part_prefix(txnid)
    _text(out, name)
    return out^


# Every transaction record, so recovery can sweep for the staging ones.
def key_txn_all() -> List[UInt8]:
    var out = List[UInt8]()
    _text(out, "weft/txn/")
    return out^


# The first key after every key with this prefix. FoundationDB calls it strinc. A range
# from a prefix to this covers exactly the keys under that prefix.
#
# Works on `buf` in place and returns the length of the answer, as the C does when
# `out == prefix`; `key_after` is the copying form. The two must agree.
def key_after_in_place(mut buf: List[UInt8], plen: Int) -> Int:
    var n = plen
    while n > 0 and buf[n - 1] == 0xFF:
        n -= 1
    if n > 0:
        buf[n - 1] += 1
    return n


def key_after(prefix: List[UInt8]) -> List[UInt8]:
    var buf = prefix.copy()
    var n = key_after_in_place(buf, len(prefix))
    var out = List[UInt8]()
    for i in range(n):
        out.append(buf[i])
    return out^


# Bytewise, unsigned, shorter-is-smaller on a tie: the order FoundationDB sorts keys by.
def key_cmp(a: List[UInt8], b: List[UInt8]) -> Int:
    var n = len(a) if len(a) < len(b) else len(b)
    for i in range(n):
        if a[i] != b[i]:
            return -1 if a[i] < b[i] else 1
    if len(a) == len(b):
        return 0
    return -1 if len(a) < len(b) else 1


def starts_with(key: List[UInt8], prefix: List[UInt8]) -> Bool:
    if len(prefix) > len(key):
        return False
    for i in range(len(prefix)):
        if key[i] != prefix[i]:
            return False
    return True
