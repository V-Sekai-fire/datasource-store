#!/bin/sh
# Check that the Mojo VFS exports the entry points it says it exports.
#
#   check_mojo_surface.sh            check mojo/src/vfs_fdb.mojo against mojo/vfs_fdb.sigs
#   check_mojo_surface.sh --self-test  prove the check can fail (see below)
#
# `check_surface.sh` guards what the C store asks of FoundationDB. This guards the other
# side: what the Mojo store offers to SQLite and to callers. The surface is every `def` in
# vfs_fdb.mojo that is
#   * `abi("C")`: the file methods and the VFS methods SQLite calls through a function
#     pointer, so no Mojo caller names them and a removal fails only at run time;
#   * named `weft_*` or `register_fdb`: the group-commit calls and the registration, the
#     names the C store exports and the Mojo port must keep.
# Other helpers are not the surface and are not listed.
#
# Read from the source, not a build, so it needs no Mojo toolchain and runs first.
#
# SPDX-License-Identifier: Apache-2.0
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Names of the exported defs in file $1, one per line, sorted. A def may span lines, so
# the signature is joined up to its closing colon before it is tested.
surface_of() {
	awk '
		/^def / { sig = $0; open = 1 }
		open && !/^def / { sig = sig " " $0 }
		open && /:[ \t]*$/ {
			open = 0
			name = sig; sub(/^def /, "", name); sub(/[(\[].*/, "", name)
			if (sig ~ /abi\("C"\)/ || name ~ /^weft_/ || name == "register_fdb") print name
		}
	' "$1" | sort -u
}
# Names listed in contract $1, comments and blanks dropped.
listed_in() {
	sed 's/#.*//' "$1" | tr -d ' \t' | grep -v '^$' | sort -u
}
# Compare surface of source $1 with contract $2. Prints the differences, returns 1 on any.
compare() {
	work=$(mktemp -d)
	surface_of "$1" > "$work/actual"
	listed_in "$2" > "$work/listed"
	# A source that yields nothing is a check with nothing to check, not a clean surface.
	if [ ! -s "$work/actual" ]; then
		echo "check_mojo_surface: no exported defs found in $1"
		rm -rf "$work"
		return 1
	fi
	rc=0
	comm -23 "$work/actual" "$work/listed" | sed 's/^/exported but not in the contract: /' > "$work/out"
	comm -13 "$work/actual" "$work/listed" | sed 's/^/in the contract but not exported: /' >> "$work/out"
	if [ -s "$work/out" ]; then cat "$work/out"; rc=1; fi
	rm -rf "$work"
	return $rc
}

src="$here/mojo/src/vfs_fdb.mojo"
sigs="$here/mojo/vfs_fdb.sigs"
[ -f "$src" ] || { echo "check_mojo_surface: no $src"; exit 1; }
[ -f "$sigs" ] || { echo "check_mojo_surface: no $sigs"; exit 1; }

if [ "${1:-}" = "--self-test" ]; then
	# A gate that has only ever passed has not been shown to gate. Plant each fault and
	# require a failure: an export added without a listing, and a listing with no export.
	t=$(mktemp -d)
	trap 'rm -rf "$t"' EXIT
	compare "$src" "$sigs" >/dev/null || { echo "self-test: the real surface does not pass"; exit 1; }
	{ cat "$src"; printf '\ndef weft_planted(x: Int) raises -> Int32:\n    return 0\n'; } > "$t/added.mojo"
	if compare "$t/added.mojo" "$sigs" >/dev/null; then echo "self-test: an added export went unnoticed"; exit 1; fi
	{ cat "$src"; printf '\ndef fdb_planted(x: Int) abi("C") -> Int32:\n    return 0\n'; } > "$t/abi.mojo"
	if compare "$t/abi.mojo" "$sigs" >/dev/null; then echo "self-test: an added abi(C) def went unnoticed"; exit 1; fi
	{ cat "$sigs"; echo "weft_planted"; } > "$t/extra.sigs"
	if compare "$src" "$t/extra.sigs" >/dev/null; then echo "self-test: a listing with no export went unnoticed"; exit 1; fi
	grep -v '^weft_txn_abort$' "$sigs" > "$t/short.sigs"
	if compare "$src" "$t/short.sigs" >/dev/null; then echo "self-test: a dropped listing went unnoticed"; exit 1; fi
	echo "check_mojo_surface: self-test passed (4 planted faults caught)"
	exit 0
fi

if compare "$src" "$sigs"; then
	echo "check_mojo_surface: $(listed_in "$sigs" | wc -l | tr -d ' ') entry points, contract matches"
else
	echo "check_mojo_surface: mojo/src/vfs_fdb.mojo and mojo/vfs_fdb.sigs disagree"
	exit 1
fi
