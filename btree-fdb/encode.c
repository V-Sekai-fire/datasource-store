// The encoding stated in `spec/BtreeReplacement.lean`. Two branches, one
// tag byte each.
//
// SPDX-License-Identifier: Apache-2.0
#include "encode.h"

#include <string.h>

int weft_encode_int(uint8_t *out, int64_t n) {
	// Sign-flip: XOR with 1 << 63 so that after cast to unsigned, negative
	// values land in the lower half of the u64 range and positives in the
	// upper. memcmp on the big-endian bytes then matches signed order.
	uint64_t u = ((uint64_t)n) ^ ((uint64_t)1 << 63);
	out[0] = (uint8_t)WEFT_TAG_INT;
	// Big-endian.
	for (int i = 0; i < 8; ++i) {
		out[1 + i] = (uint8_t)((u >> (8 * (7 - i))) & 0xff);
	}
	return WEFT_ENCODE_INT_BYTES;
}

int weft_encode_text(uint8_t *out, const uint8_t *bytes, size_t len) {
	out[0] = (uint8_t)WEFT_TAG_TEXT;
	if (len) memcpy(out + 1, bytes, len);
	return (int)(1 + len);
}
