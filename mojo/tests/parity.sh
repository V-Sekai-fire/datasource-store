#!/bin/sh
# The C is the oracle: build it, run the Mojo port on the same inputs, diff.
# Run from store/mojo:  pixi run parity
#
# Two oracles. The key layout is the real `../fdb_keys.h`. The page delta codec is a static
# block of `../fdb_vfs.c`, which needs FoundationDB and SQLite headers to compile whole, so
# the block is cut out of that file here and compiled alone. It is the shipping text, not a
# copy; if the block moves or the page size changes, this stops rather than testing a stale one.
set -eu
mkdir -p build

compare() {
	name=$1
	test -s build/oracle_$name.txt
	if diff build/oracle_$name.txt build/mojo_$name.txt > build/parity_$name.diff; then
		echo "parity $name: $(wc -l < build/oracle_$name.txt) lines identical"
	else
		head -20 build/parity_$name.diff
		echo "parity $name: FAIL"
		exit 1
	fi
}

cc -std=c11 -Wall -Wextra -o build/oracle tests/oracle.c
./build/oracle > build/oracle_keys.txt
mojo run -I src tests/dump_keys.mojo > build/mojo_keys.txt
compare keys

grep -q '^#define PAGE 4096$' ../fdb_vfs.c || { echo "fdb_vfs.c PAGE is not 4096"; exit 1; }
awk '/^#define DELTA_MAGIC/ {p = 1} /^static int base_key/ {p = 0} p' ../fdb_vfs.c > build/delta_extract.h
for sym in delta_encode delta_apply delta_base_id is_delta DELTA_GAP; do
	grep -q "$sym" build/delta_extract.h || { echo "delta block lost $sym"; exit 1; }
done
cc -std=c11 -Wall -Wextra -Wno-unused-function -o build/oracle_delta tests/oracle_delta.c
./build/oracle_delta > build/oracle_delta.txt
mojo run -I src tests/dump_delta.mojo > build/mojo_delta.txt
compare delta
