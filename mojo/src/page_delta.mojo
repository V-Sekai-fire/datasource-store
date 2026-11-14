# The page delta codec. Port of the "Page deltas" block of `fdb_vfs.c`.
#
# A page is stored as its difference from a full row when under a fifth of it changed.
# `spec/PageDelta.lean` models the rule: the base of a delta is always a full row, so a
# read touches at most two rows. A full row is exactly PAGE bytes; a delta is shorter and
# starts with DELTA_MAGIC, then the base's kind and id, then runs of offset, length and
# bytes. The base comes from the writer's memory, so a commit adds no read.
#
# Pure: no I/O, no state. A refused encode is an empty list, where the C returns 0.
#
# SPDX-License-Identifier: Apache-2.0 OR MIT

# SQLite's page size. This is not a choice.
comptime PAGE = 4096

comptime DELTA_MAGIC = 0xD7
comptime DELTA_HDR = 10
comptime DELTA_CUT = 5
comptime DELTA_GAP = 8


def is_delta(val: List[UInt8]) -> Bool:
    return len(val) != PAGE and len(val) >= DELTA_HDR and val[0] == DELTA_MAGIC


def _put_be16(mut out: List[UInt8], v: Int):
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))


def _get_be16(p: List[UInt8], at: Int) -> Int:
    return (Int(p[at]) << 8) | Int(p[at + 1])


# The delta of `page` against `base`, or an empty list when it would not be under the cut.
def delta_encode(
    base: List[UInt8], page: List[UInt8], kind: Int, id: UInt64
) -> List[UInt8]:
    var limit = PAGE // DELTA_CUT
    var out = List[UInt8]()
    out.append(UInt8(DELTA_MAGIC))
    out.append(UInt8(kind & 0xFF))
    for s in range(8):
        out.append(UInt8((id >> UInt64(56 - 8 * s)) & 0xFF))
    var n = DELTA_HDR
    var i = 0
    while i < PAGE:
        if base[i] == page[i]:
            i += 1
            continue
        var end = i + 1
        var same = 0
        var j = i + 1
        while j < PAGE and same < DELTA_GAP:
            if base[j] == page[j]:
                same += 1
            else:
                same = 0
                end = j + 1
            j += 1
        var length = end - i
        if n + 4 + length > limit:
            return List[UInt8]()
        _put_be16(out, i)
        _put_be16(out, length)
        for k in range(length):
            out.append(page[i + k])
        n += 4 + length
        i = end
    return out^


def delta_base_id(val: List[UInt8]) -> UInt64:
    var id = UInt64(0)
    for s in range(8):
        id = (id << 8) | UInt64(val[2 + s])
    return id


# Apply a delta to `page`, which holds its base. Returns 0, or -1 for a malformed delta.
# A malformed delta may have patched part of the page before it is refused, as in the C.
def delta_apply(val: List[UInt8], mut page: List[UInt8]) -> Int:
    var vlen = len(val)
    var n = DELTA_HDR
    while n < vlen:
        if n + 4 > vlen:
            return -1
        var off = _get_be16(val, n)
        var length = _get_be16(val, n + 2)
        if off + length > PAGE or n + 4 + length > vlen:
            return -1
        for k in range(length):
            page[off + k] = val[n + 4 + k]
        n += 4 + length
    return 0
