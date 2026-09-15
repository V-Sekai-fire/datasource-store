#!/usr/bin/env python3
# Emit a patched SQLite amalgamation whose btree.c AND pager.c sections are
# replaced by `#include`s of the stub files. Used from the weft_sqlite3 target
# when `WEFT_BTREE_FDB` is on. The vendored `sqlite3.c` stays pristine so a
# reader can diff against sqlite.org.
#
# SPDX-License-Identifier: Apache-2.0
import argparse, sys

# Each section pairs the amalgamation's begin/end markers with the CLI flag
# that carries the replacement path and a human label for the header comment.
SECTIONS = [
    {"begin": "Begin file btree.c ", "end": "End of btree.c ", "arg": "btree_stubs", "label": "btree.c"},
    {"begin": "Begin file pager.c ", "end": "End of pager.c ", "arg": "pager_stubs", "label": "pager.c"},
    # wal.c is excised too because pager.c's typedef of struct Wal lives
    # inside pager.c, and wal.c depends on that typedef. Only one function
    # (sqlite3WalDefaultHook) is called from outside pager.c/wal.c, so the
    # stub file only needs to carry that one plus a forward typedef.
    {"begin": "Begin file wal.c ",   "end": "End of wal.c ",   "arg": "wal_stubs",   "label": "wal.c"},
]

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--btree-stubs", required=True)
    ap.add_argument("--pager-stubs", required=True)
    ap.add_argument("--wal-stubs", required=True)
    args = ap.parse_args()
    stubs = {"btree_stubs": args.btree_stubs,
             "pager_stubs": args.pager_stubs,
             "wal_stubs": args.wal_stubs}

    with open(args.src) as fin, open(args.out, "w") as fout:
        active = None
        for line in fin:
            if active is None:
                for s in SECTIONS:
                    if s["begin"] in line:
                        fout.write(f'/* {s["label"]} replaced by weft. */\n')
                        fout.write(f'#include "{stubs[s["arg"]]}"\n')
                        active = s
                        break
                else:
                    fout.write(line)
            else:
                if active["end"] in line:
                    active = None
    return 0

if __name__ == "__main__":
    sys.exit(main())
