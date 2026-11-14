// Prints every key builder in ../../fdb_keys.h for a fixed set of inputs, one hex line each.
// tests/dump_keys.mojo prints the same lines from the Mojo port; the two must be identical.
// SPDX-License-Identifier: Apache-2.0 OR MIT
#include "../../fdb_keys.h"
#include <stdlib.h>

static void hex(const char *label, const uint8_t *k, int n) {
	printf("%s ", label);
	for (int i = 0; i < n; i++) printf("%02x", k[i]);
	printf("\n");
}

int main(void) {
	char longname[101];
	memset(longname, 'n', 100);
	longname[100] = 0;
	const char *names[] = {"", "a", "main.db", "x/y z", longname};
	const uint64_t u64s[] = {0, 1, 255, 256, 0xFFFFFFFFull, 0x100000000ull,
		0x7FFFFFFFFFFFFFFFull, 0x8000000000000000ull, 0xFFFFFFFFFFFFFFFFull};
	const uint32_t u32s[] = {0, 1, 255, 256, 0x7FFFFFFFu, 0x80000000u, 0xFFFFFFFFu};
	uint8_t k[KEYMAX];
	char label[64];
	for (int ni = 0; ni < 5; ni++) {
		const char *nm = names[ni];
		hex("meta", k, key_meta(k, nm, "HEAD"));
		hex("prefix", k, key_prefix(k, nm, "PIDX"));
		for (int p = 0; p < 7; p++) {
			snprintf(label, sizeof label, "pidx %u", u32s[p]);
			hex(label, k, key_pidx(k, nm, u32s[p]));
		}
		for (int t = 0; t < 9; t++) {
			snprintf(label, sizeof label, "delta_txid %llx", (unsigned long long)u64s[t]);
			hex(label, k, key_delta_txid(k, nm, u64s[t]));
			snprintf(label, sizeof label, "shard_version %llx", (unsigned long long)u64s[t]);
			hex(label, k, key_shard_version(k, nm, u64s[t]));
			snprintf(label, sizeof label, "shardn %llx", (unsigned long long)u64s[t]);
			hex(label, k, key_shardn(k, nm, u64s[t]));
			for (int p = 0; p < 7; p++) {
				snprintf(label, sizeof label, "delta %llx %u", (unsigned long long)u64s[t], u32s[p]);
				hex(label, k, key_delta(k, nm, u64s[t], u32s[p]));
				snprintf(label, sizeof label, "shard %llx %u", (unsigned long long)u64s[t], u32s[p]);
				hex(label, k, key_shard(k, nm, u64s[t], u32s[p]));
			}
		}
	}
	for (int t = 0; t < 9; t++) {
		unsigned long long id = (unsigned long long)u64s[t];
		snprintf(label, sizeof label, "txn_status %llx", id);
		hex(label, k, key_txn_status(k, u64s[t]));
		snprintf(label, sizeof label, "txn_part_prefix %llx", id);
		hex(label, k, key_txn_part_prefix(k, u64s[t]));
		snprintf(label, sizeof label, "txn_prefix %llx", id);
		hex(label, k, key_txn_prefix(k, u64s[t]));
		for (int ni = 0; ni < 5; ni++) {
			snprintf(label, sizeof label, "txn_part %llx %d", id, ni);
			hex(label, k, key_txn_part(k, u64s[t], names[ni]));
		}
	}
	hex("txn_all", k, key_txn_all(k));
	const uint8_t cases[][6] = {{'a','b'}, {'a',0xff}, {0xff,0xff}, {'a',0xff,0xfe}, {0xfe}, {0, 0xff, 0xff}};
	const int lens[] = {2, 2, 2, 3, 1, 3};
	for (int c = 0; c < 6; c++) {
		uint8_t out[KEYMAX];
		snprintf(label, sizeof label, "after %d", c);
		hex(label, out, key_after(out, cases[c], lens[c]));
		uint8_t buf[KEYMAX];
		memcpy(buf, cases[c], (size_t)lens[c]);
		snprintf(label, sizeof label, "after_in_place %d", c);
		hex(label, buf, key_after(buf, buf, lens[c]));
	}
	return 0;
}
