#!/bin/sh
# Pure SQLite, the C VFS and the Mojo VFS on the same workload, in one container with one
# SQLite library and one throwaway FoundationDB. Run by fdb_container.sh with BENCH=1, from
# store/mojo, after the C library is built at /tmp/cbuild and the Mojo benchmark at build/bench.
#
# Rows of the table:
#   pure sqlite, the challenge's pragmas   a local file, WAL, synchronous NORMAL, driven from C
#   pure sqlite, same pragmas as the VFSs  a local file, memory journal, exclusive, synchronous
#                                          FULL (a commit is durable, as one to FoundationDB is)
#                                          driven from C, and again from Mojo as the control
#   C VFS                                  fdb_vfs.c, through the C driver
#   Mojo VFS                               vfs_fdb.mojo, through the Mojo driver
# Every row has a 32 MiB page cache.
#
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -eu
FDBCLI=${FDBCLI:-fdbcli}
CF=${WEFT_FDB_CLUSTER_FILE:-/etc/foundationdb/fdb.cluster}
OUT=${OUT:-/tmp/bench.tsv}
sh bench/make_plan.sh > /tmp/plan.txt

wipe() { "$FDBCLI" -C "$CF" --exec 'writemode on; clearrange "" \xff' >/dev/null; }
WAL="pragma journal_mode=wal; pragma synchronous=normal; pragma cache_size=-32768"
SAME="pragma journal_mode=memory; pragma locking_mode=exclusive; pragma synchronous=full; pragma cache_size=-32768"
VFSP="pragma journal_mode=memory; pragma locking_mode=exclusive; pragma cache_size=-32768"

: > "$OUT"
rm -f /tmp/b-*.db*
echo "pure sqlite, challenge pragmas (C driver)"
./build/bench_c /tmp/plan.txt /tmp/b-wal.db unix "$WAL" "1 pure WAL" >> "$OUT"
echo "pure sqlite, VFS pragmas (C driver)"
./build/bench_c /tmp/plan.txt /tmp/b-same.db unix "$SAME" "2 pure, as the VFSs (C driver)" >> "$OUT"
echo "pure sqlite, VFS pragmas (Mojo driver)"
./build/bench /tmp/plan.txt /tmp/b-same2.db unix "$SAME" "3 pure, as the VFSs (Mojo driver)" >> "$OUT"
echo "C VFS"
wipe
./build/bench_c /tmp/plan.txt bench.db weft_fdb "$VFSP" "4 C VFS over FoundationDB" >> "$OUT"
echo "Mojo VFS"
wipe
./build/bench /tmp/plan.txt bench.db weft_mojo_fdb "$VFSP" "5 Mojo VFS over FoundationDB" >> "$OUT"

# The same rows in every run, or the comparison is not one.
echo "== row counts (users/posts/likes) after the run"
grep -P "\trows\t" "$OUT" 2>/dev/null || grep "	rows	" "$OUT"

# one table: a row per step, a column per backend, operations per second
awk -F'\t' '
$2=="rows" { next }
{
	step=$2; if (step ~ /^seed /) step="seed (bulk load, 2,000 rows a commit)"
	if (!(step in seen)) { seen[step]=1; order[++n]=step }
	lab[$1]=1
	if ($2 ~ /^seed /) { secs[step,$1]+=$4; ops[step,$1]+=1 } else { secs[step,$1]=$4; ops[step,$1]=$3 }
}
END {
	m=0; for (l in lab) labs[++m]=l
	for (i=1;i<=m;i++) for (j=i+1;j<=m;j++) if (labs[j]<labs[i]) { t=labs[i]; labs[i]=labs[j]; labs[j]=t }
	printf "%-44s", "operations per second"
	for (i=1;i<=m;i++) printf " | %-8s", substr(labs[i],1,1)
	printf "\n"
	for (k=1;k<=n;k++) {
		s=order[k]; printf "%-44s", substr(s,1,44)
		for (i=1;i<=m;i++) { v=ops[s,labs[i]]/secs[s,labs[i]]; printf " | %-8.0f", v }
		printf "\n"
	}
	printf "\n"
	for (i=1;i<=m;i++) printf "  %s\n", labs[i]
}' "$OUT"
