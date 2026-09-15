// The order-preserving encoding stated in `spec/BtreeReplacement.lean`.
//
// A single-column SQLite primary key is written into store bytes so that
// `memcmp` on the bytes gives the same order as SQLite's record comparator
// for that key. FoundationDB's keyspace is a byte-lex map, so the encoding
// is what makes a raw FDB `get_range` return rows in the order SQLite
// expects.
//
// Two branches cover the shapes YCSB workload F's `usertable` uses:
//   INTEGER PRIMARY KEY  -> `WEFT_PK_INT`
//   TEXT PRIMARY KEY     -> `WEFT_PK_TEXT`  (BINARY collation)
//
// A one-byte tag disambiguates. The tags are ordered so that integer PKs
// sort ahead of text PKs, matching the Lean spec's `pkLt` cross-branch
// convention.
//
// SPDX-License-Identifier: Apache-2.0
#ifndef WEFT_BTREE_FDB_ENCODE_H
#define WEFT_BTREE_FDB_ENCODE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// One byte, chosen so 0x01 < 0x02 under memcmp.
enum { WEFT_TAG_INT = 0x01, WEFT_TAG_TEXT = 0x02 };

// Fixed-length integer encoding: 1 tag byte + 8 payload bytes.
enum { WEFT_ENCODE_INT_BYTES = 9 };

// Write the integer PK encoding for `n` into `out`, which must have at least
// `WEFT_ENCODE_INT_BYTES` bytes. Returns the count written.
//
// The payload is `n` reinterpreted as a signed 64-bit integer, XORed with
// `1 << 63` so that the sign bit flips (negative numbers get their high bit
// cleared, positives get theirs set), then big-endian bytes. This gives
// `memcmp`-order equal to signed-integer order.
int weft_encode_int(uint8_t *out, int64_t n);

// Write the text PK encoding for `bytes[0..len)` into `out`, which must have
// at least `1 + len` bytes. Returns the count written (`1 + len`).
//
// The payload is the input bytes verbatim — SQLite's BINARY collation is
// byte-lex on the UTF-8 form, which is what memcmp gives.
int weft_encode_text(uint8_t *out, const uint8_t *bytes, size_t len);

#ifdef __cplusplus
}
#endif

#endif
