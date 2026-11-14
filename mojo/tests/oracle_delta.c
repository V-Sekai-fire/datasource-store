// Runs the page delta codec exactly as `fdb_vfs.c` has it. The codec is cut out of that file
// at test time (tests/parity.sh writes build/delta_extract.h), so this is the shipping code
// and not a copy kept in step by hand. Prints one line per case; tests/dump_delta.mojo prints
// the same lines from the Mojo port, and the two must be identical.
// SPDX-License-Identifier: Apache-2.0 OR MIT
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define PAGE 4096
#include "../build/delta_extract.h"

static uint64_t st;
static uint64_t next(void) {
	st ^= st >> 12;
	st ^= st << 25;
	st ^= st >> 27;
	return st * 0x2545F4914F6CDD1DULL;
}

static uint64_t fnv(const uint8_t *p, int n) {
	uint64_t h = 0xcbf29ce484222325ULL;
	for (int i = 0; i < n; i++) h = (h ^ p[i]) * 0x100000001b3ULL;
	return h;
}

int main(void) {
	static const int maxlens[4] = {1, 8, 40, 300};
	for (int i = 0; i < 400; i++) {
		st = (uint64_t)(i + 1) * 0x9E3779B97F4A7C15ULL;
		int kind = (int)(next() & 3);
		uint64_t id = next();
		uint8_t base[PAGE], page[PAGE], out[PAGE], work[PAGE];
		for (int b = 0; b < PAGE; b++) base[b] = i % 3 == 0 ? 0 : (uint8_t)(next() & 0xFF);
		memcpy(page, base, PAGE);
		int nruns = (int)(next() % 14);
		for (int r = 0; r < nruns; r++) {
			int ml = maxlens[next() & 3];
			int off = (int)(next() % PAGE);
			int len = 1 + (int)(next() % (uint64_t)ml);
			if (off + len > PAGE) len = PAGE - off;
			for (int k = 0; k < len; k++) page[off + k] = (uint8_t)(next() & 0xFF);
		}
		int n = delta_encode(base, page, kind, id, out);
		printf("enc %d %d ", i, n);
		if (n == 0) printf("-");
		for (int k = 0; k < n; k++) printf("%02x", out[k]);
		printf("\n");
		if (n == 0) continue;
		printf("meta %d %d %llx %d\n", i, is_delta(out, n),
		       (unsigned long long)delta_base_id(out), out[1]);
		memcpy(work, base, PAGE);
		int rc = delta_apply(out, n, work);
		printf("apply %d %d %llx\n", i, rc, (unsigned long long)fnv(work, PAGE));
		memcpy(work, base, PAGE);
		rc = delta_apply(out, n - 1, work);
		printf("trunc %d %d %llx\n", i, rc, (unsigned long long)fnv(work, PAGE));
	}
	return 0;
}
