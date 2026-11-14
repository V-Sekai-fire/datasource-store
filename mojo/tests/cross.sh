#!/bin/sh
# The Mojo VFS and the C VFS on one store. Each side writes what the other reads, and each
# reads what the other wrote after the C folded it into a shard or left deltas against one.
#
#   SQLRUN=<path to the built sqlrun> sh tests/cross.sh        (from store/mojo, a cluster up)
#
# `sqlrun` is built from the store: cmake --build build --target sqlrun. WEFT_FDB_CLUSTER_FILE
# names the cluster for both sides; WEFT_FDB_LIB names libfdb_c for the Mojo side if needed.
set -eu
: "${SQLRUN:?set SQLRUN to the built sqlrun}"
PRAGMAS="pragma journal_mode=memory; pragma locking_mode=exclusive;"
fail=0

mojo_step() {
	echo "== mojo $1"
	if CROSS_STEP=$1 pixi run mojo run -I src tests/cross_test.mojo >/tmp/step.out 2>&1; then :; else echo "STEP $1 FAILED"; fail=1; fi
	grep -E "^ok|^FAIL|all checks|Unhandled" /tmp/step.out || true
}

# Run SQL through the C VFS and print only the rows (sqlrun puts its timing on stderr).
c_sql() {
	printf '%s\n' "$1" | "$SQLRUN" "$2" 2>/dev/null
}

expect() {  # expect <label> <got> <want>
	if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fail=1; fi
}

mojo_step clean

# Mojo writes, the C reads and extends, and folds on close
mojo_step write-m
out=$(c_sql "$PRAGMAS select count(*), sum(id) from t;" cross-m.db | tail -1)
expect "C reads Mojo's rows: count and sum" "$out" "$(printf '1500\t1125750')"
out=$(c_sql "$PRAGMAS select count(*) from t where v='m-updated';" cross-m.db | tail -1)
expect "C reads Mojo's delta-committed update" "$out" "5"
out=$(c_sql "$PRAGMAS select count(*) from pragma_integrity_check where integrity_check='ok';" cross-m.db | tail -1)
expect "C's integrity_check passes on a store Mojo wrote" "$out" "1"
c_sql "$PRAGMAS insert into t select id+10000, 'c-' || id from t where id <= 500;" cross-m.db >/dev/null
mojo_step read-m

# the C writes and folds; a second C session leaves deltas against the shard; Mojo reads and appends
c_sql "$PRAGMAS create table t(id integer primary key, v text); with recursive c(x) as (select 1 union all select x+1 from c where x<3000) insert into t select x, 'c-' || x from c;" cross-c.db >/dev/null
c_sql "$PRAGMAS update t set v='updated' where id % 150 = 0;" cross-c.db >/dev/null
mojo_step read-c
out=$(c_sql "$PRAGMAS select count(*), sum(id) from t;" cross-c.db | tail -1)
expect "C reads Mojo's appended rows: count and sum" "$out" "$(printf '4000\t10002000')"
out=$(c_sql "$PRAGMAS select count(*) from t where v='updated';" cross-c.db | tail -1)
expect "C still sees its own 19 updates, and Mojo's edit of the twentieth" "$out" "19"
out=$(c_sql "$PRAGMAS select v from t where id=150;" cross-c.db | tail -1)
expect "C reads Mojo's edit" "$out" "mojo-edit"
out=$(c_sql "$PRAGMAS select count(*) from pragma_integrity_check where integrity_check='ok';" cross-c.db | tail -1)
expect "C's integrity_check passes on a store both wrote" "$out" "1"

# Bit equality. The same three sessions through the C VFS and then the Mojo VFS, each from an
# empty store, with fdbcli dumping every key and value in between. The two dumps must be the same
# bytes: the fence, the commit ids, which pages are deltas and what each delta says.
FDBCLI=${FDBCLI:-fdbcli}
CF=${WEFT_FDB_CLUSTER_FILE:-/etc/foundationdb/fdb.cluster}
wipe() { "$FDBCLI" -C "$CF" --exec 'writemode on; clearrange "" \xff' >/dev/null; }
dump() { "$FDBCLI" -C "$CF" --exec 'getrange "" \xff 1000000' | grep -v '^$' | grep -v '^Range limited'; }
SESS1="create table t(id integer primary key, v text); with recursive c(x) as (select 1 union all select x+1 from c where x<400) insert into t select x, 'row-' || x from c;"
SESS2="update t set v='edited' where id % 97 = 0;"
SESS4="update t set v='tail' where id=7;"
SESS5="create table big(id integer primary key, v text); with recursive c(x) as (select 1 union all select x+1 from c where x<2300) insert into big select x, replace(hex(zeroblob(1950)),'0','a') from c;"
SESS6="with recursive c(x) as (select 1 union all select x+1 from c where x<2150) insert into big select x+5000, replace(hex(zeroblob(1950)),'0','a') from c;"
SESS3="insert into t select id+1000, 'late-' || id from t where id <= 40; delete from t where id between 100 and 130;"
echo "== bit equality"
wipe
c_sql "$PRAGMAS $SESS1" eq.db >/dev/null; c_sql "$PRAGMAS $SESS2" eq.db >/dev/null; c_sql "$PRAGMAS $SESS3" eq.db >/dev/null; c_sql "$PRAGMAS $SESS4" eq.db >/dev/null; c_sql "$PRAGMAS $SESS5" eq.db >/dev/null; c_sql "$PRAGMAS $SESS6" eq.db >/dev/null
dump > /tmp/eq-c.txt
wipe
mojo_step eq-1; mojo_step eq-2; mojo_step eq-3; mojo_step eq-4; mojo_step eq-5; mojo_step eq-6
dump > /tmp/eq-m.txt
echo "C wrote $(wc -l < /tmp/eq-c.txt) rows, Mojo wrote $(wc -l < /tmp/eq-m.txt); delta rows in each: $(grep -c "DELTA\|\\xd7" /tmp/eq-c.txt) / $(grep -c "DELTA\|\\xd7" /tmp/eq-m.txt)"
if cmp -s /tmp/eq-c.txt /tmp/eq-m.txt && [ -s /tmp/eq-c.txt ]; then echo "ok    the C and the Mojo VFS left identical bytes in FoundationDB"; else echo "FAIL  the stores differ"; diff /tmp/eq-c.txt /tmp/eq-m.txt | cut -c1-200 | head -20; fail=1; fi

[ "$fail" = 0 ] && echo "cross test passed" || { echo "cross test FAILED"; exit 1; }
