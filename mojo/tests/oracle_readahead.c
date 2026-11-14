// Runs the read-ahead scorer and the compaction trigger exactly as `fdb_vfs.c` has them. Both
// are cut out of that file at test time (tests/parity.sh writes build/readahead_extract.h),
// so this is the shipping text. Prints one line per call; tests/dump_readahead.mojo prints the
// same lines from the Mojo port, and the two must be identical.
// SPDX-License-Identifier: Apache-2.0 OR MIT
#include <stdint.h>
#include <stdio.h>

// The two fields and two counters the extracted code reads; the rest of FdbFile is not here.
typedef struct {
	int ra_score;
	uint32_t ra_last;
	uint64_t base_pages;
	uint64_t log_pages;
} FdbFile;
#include "../build/readahead_extract.h"

static uint64_t st;
static uint64_t next(void) {
	st ^= st >> 12;
	st ^= st << 25;
	st ^= st >> 27;
	return st * 0x2545F4914F6CDD1DULL;
}

int main(void) {
	for (int i = 0; i < 300; i++) {
		st = (uint64_t)(i + 1) * 0x9E3779B97F4A7C15ULL;
		FdbFile f = {0, 0, 0, 0};
		int mode = i % 4;  // scan, random, a scan with noise, and edges of the page range
		uint32_t pg = (uint32_t)(next() % 64);
		for (int j = 0; j < 60; j++) {
			uint64_t r = next();
			if (mode == 0) {
				pg += 1 + (uint32_t)(r % 8);
			} else if (mode == 1) {
				pg = (uint32_t)(r % 100000);
			} else if (mode == 2) {
				pg = r % 5 == 0 ? (uint32_t)(next() % 100000) : pg + 1 + (uint32_t)(r % 9);
			} else {
				static const uint32_t edge[] = {0, 1, 7, 8, 9, 0x7FFFFFFFu, 0x80000000u, 0xFFFFFFFEu, 0xFFFFFFFFu};
				pg = edge[r % 9];
			}
			uint32_t d = ra_depth(&f, pg);
			printf("ra %d %d %u %d %u\n", i, j, d, f.ra_score, f.ra_last);
		}
	}
	static const uint64_t v[] = {0, 1, 2, 3, 100, 0x100000000ULL, 0x7FFFFFFFFFFFFFFFULL,
	                             0x8000000000000000ULL, 0xFFFFFFFFFFFFFFFFULL};
	for (int a = 0; a < 9; a++)
		for (int b = 0; b < 9; b++) {
			FdbFile f = {0, 0, v[b], v[a]};
			printf("compact log=%llx base=%llx %d\n", (unsigned long long)v[a],
			       (unsigned long long)v[b], should_compact(&f));
		}
	return 0;
}
