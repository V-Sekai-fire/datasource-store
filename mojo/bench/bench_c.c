// The benchmark driver in C: plain SQLite or the C FoundationDB VFS, running a plan file.
//
//   bench_c <plan> <db> <vfs> <pragmas> <label>
//
// <vfs> is "unix" for SQLite's own file VFS, or "weft_fdb" for the C VFS (started here). The
// driver prints one line per step: label, step, operations, seconds, operations per second and
// microseconds per operation. bench.mojo does the same through the Mojo VFS, from the same plan.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "weft_fdb_vfs.h"

static double now(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static void die(sqlite3 *db, const char *what) {
	fprintf(stderr, "%s: %s\n", what, db ? sqlite3_errmsg(db) : "?");
	exit(1);
}

static void run(sqlite3 *db, const char *sql) {
	char *err = NULL;
	if (sqlite3_exec(db, sql, 0, 0, &err)) {
		fprintf(stderr, "exec failed: %s\n  %.120s\n", err, sql);
		exit(1);
	}
}

int main(int argc, char **argv) {
	if (argc < 6) {
		fprintf(stderr, "usage: bench_c <plan> <db> <vfs> <pragmas> <label>\n");
		return 2;
	}
	const char *plan = argv[1], *path = argv[2], *vfs = argv[3], *pragmas = argv[4], *label = argv[5];
	if (strcmp(vfs, "weft_fdb") == 0) {
		if (weft_fdb_start(getenv("WEFT_FDB_CLUSTER_FILE"))) { fprintf(stderr, "FoundationDB did not start\n"); return 1; }
		weft_vfs_register(0);
	}
	sqlite3 *db = NULL;
	if (sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, vfs)) die(db, "open");
	run(db, pragmas);

	FILE *fp = fopen(plan, "r");
	if (!fp) { perror(plan); return 1; }
	char *line = NULL;
	size_t cap = 0;
	while (getline(&line, &cap, fp) > 0) {
		line[strcspn(line, "\n")] = 0;
		char *kind = line, *name = strchr(kind, '|');
		if (!name) continue;
		*name++ = 0;
		char *iters_s = strchr(name, '|'); *iters_s++ = 0;
		char *per_s = strchr(iters_s, '|'); *per_s++ = 0;
		char *sql = strchr(per_s, '|'); *sql++ = 0;
		int iters = atoi(iters_s), per = atoi(per_s);

		double t0 = now();
		if (strcmp(kind, "exec") == 0) {
			run(db, "BEGIN");
			run(db, sql);
			run(db, "COMMIT");
			iters = 1;
		} else {
			sqlite3_stmt *st = NULL;
			if (sqlite3_prepare_v2(db, sql, -1, &st, NULL)) die(db, "prepare");
			for (int i = 0; i < iters; i++) {
				if (per > 1 && i % per == 0) run(db, "BEGIN");
				while (sqlite3_step(st) == SQLITE_ROW) {}
				if (sqlite3_reset(st)) die(db, "step");
				if (per > 1 && (i % per == per - 1 || i == iters - 1)) run(db, "COMMIT");
			}
			sqlite3_finalize(st);
		}
		double dt = now() - t0;
		printf("%s\t%s\t%d\t%.4f\t%.0f\t%.1f\n", label, name, iters, dt, iters / dt, dt / iters * 1e6);
		fflush(stdout);
	}
	// the row counts, so two backends are known to have done the same work
	sqlite3_stmt *st;
	sqlite3_prepare_v2(db, "SELECT (SELECT count(*) FROM users), (SELECT count(*) FROM posts), (SELECT count(*) FROM likes)", -1, &st, NULL);
	if (sqlite3_step(st) == SQLITE_ROW)
		printf("%s\trows\t%lld/%lld/%lld\n", label, (long long)sqlite3_column_int64(st, 0), (long long)sqlite3_column_int64(st, 1), (long long)sqlite3_column_int64(st, 2));
	sqlite3_finalize(st);
	// closing pays a fold that is owed: the log has grown as large as the base
	double tc = now();
	sqlite3_close(db);
	double dc = now() - tc;
	printf("%s\tclose (pays the owed fold)\t1\t%.4f\t%.2f\t%.0f\n", label, dc, 1.0 / dc, dc * 1e6);
	return 0;
}
