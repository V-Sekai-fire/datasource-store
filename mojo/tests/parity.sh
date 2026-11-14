#!/bin/sh
# The C header is the oracle: build it, run the Mojo port on the same inputs, diff.
# Run from store/mojo:  pixi run parity
set -eu
cc -std=c11 -Wall -Wextra -o build/oracle tests/oracle.c
./build/oracle > build/oracle.txt
mojo run -I src tests/dump_keys.mojo > build/mojo.txt
test -s build/oracle.txt
if diff build/oracle.txt build/mojo.txt > build/parity.diff; then
	echo "parity: $(wc -l < build/oracle.txt) lines identical"
else
	head -20 build/parity.diff
	echo "parity: FAIL"
	exit 1
fi
