# weft store in Mojo

A port of the store's C/C++ to Mojo, one slice at a time. The Lean specs in `../spec` and
`../witness` stay Lean: they are the statement of what the store must do. The Mojo here
is checked against them the way the C and C++ were, and against the C itself.

The C/C++ keeps building while a slice is ported. Nothing here replaces it yet.

## Toolchain

Mojo 1.1.0 through pixi. Call `mojo` through `pixi run`; the bare binary cannot find `std`.

    pixi install
    pixi run test          # parity, then the witness gate

The witness ladder comes from
[`V-Sekai-fire/contract-witness-mojo`](https://github.com/V-Sekai-fire/contract-witness-mojo),
read from `../../witness-mojo` in the workspace. A standalone checkout clones it anywhere
and runs `pixi run mojo run -I src -I <clone>/src tests/keys_witness.mojo`.

## Slices

| # | Slice | C source | Status |
|---|-------|----------|--------|
| 1 | Key layout | `fdb_keys.h` | Done. `src/fdb_keys.mojo` |
| 1 | Key layout witness | `keys-witness/keys_test.cc` | Done. `tests/keys_witness.mojo` replaced it, and witness-cpp and doctest with it |
| 2a | Page delta codec | `fdb_vfs.c` "Page deltas" block, `spec/PageDelta.lean` | Done. `src/page_delta.mojo` |
| 2b | Read-ahead scorer, compaction trigger | `ra_depth`, `should_compact` in `fdb_vfs.c` | Done. `src/read_ahead.mojo` |
| 2c | Commit models | `spec/GroupCommit.lean` and the rest | Not started |
| 3a | SQLite VFS in Mojo, over an in-memory store | `sqlite3_vfs` and `sqlite3_io_methods` of `fdb_vfs.c` | Done. `src/vfs_mem.mojo` |
| 3b | FoundationDB client binding (network thread, transactions) | `fdb_c.h` use in `fdb_vfs.c` | Not started |
| 3c | The two joined: pages in FoundationDB through the Mojo VFS | `fdb_vfs.c` | Not started |
| 4 | Crash and handoff proofs | `prove_*.c`, `integrity.c`, `fdb_floor.c` | Not started |
| 5 | Benchmarks | `bench_vfs.c`, `tpcc.c`, `ycsb_direct.cpp`, `game_load.cpp` | Not started |

## What slice 1 checks

- **Witness gate** (`pixi run keys-witness`): ten properties of the key layout and nine
  planted-false controls. A control runs a wrong encoder or predicate through the same
  machinery and must come back `FOUND`; if one comes back clean, the gate cannot fail.
- **Parity** (`pixi run parity`): `tests/oracle.c` includes the real `../fdb_keys.h`,
  `tests/dump_keys.mojo` runs the port, and the two dumps (895 key lines over five names,
  nine 64-bit and seven 32-bit edge values, and six `key_after` cases, in place and apart)
  must be identical.

Both were run against two mutants of the port (little-endian `put_be32`; a `key_after`
that keeps trailing `0xFF`). Both mutants fail the gate and the parity diff.

## Slice 2a: the page delta codec

`delta_encode`, `delta_apply`, `is_delta` and `delta_base_id` are `static` inside `fdb_vfs.c`, which
needs FoundationDB and SQLite headers to compile. `tests/parity.sh` cuts the block out of that
file with `awk` and compiles it alone (`tests/oracle_delta.c`), so the oracle is the shipping text
and the C is not touched. If the block moves or `PAGE` changes, the script stops.

- `pixi run delta-witness`: four properties and four planted-false controls (round trip with id
  and kind, the bare header for an unchanged page, a cut delta is whole only on a run boundary,
  a run is taken iff it fits the page and its bytes are present).
- Parity: 400 generated pages, 1,543 lines (encoding, header fields, apply, and apply of a
  one-byte-short delta), identical to the C.
- Mutants: the merge gap 8 to 4 changes bytes but not meaning, so only parity catches it; the
  witness catches a little-endian id and a quarter-page cut.

## Slice 2b: the read-ahead scorer and the compaction trigger

`ra_depth` and `should_compact` take an `FdbFile`, so the oracle declares a struct with just the
four fields they read and compiles the blocks cut out of `fdb_vfs.c`.

- `pixi run readahead-witness`: six properties and six planted-false controls. A scan escalates on
  its third page and is at full depth on its fifth; a point read never escalates; a scan holds
  through six random pages and not a seventh; a random page with no scan running costs four points
  and stops at 0; the score stays in 0..12; the log folds when it is as large as the base and never
  when quiet.
- `spec/ReadAhead.lean` models the window a prefetch fills, not the scorer, so these properties
  come from the C's comments and the numbers it cites, not from a proof.
- Parity: 300 access sequences of 60 pages each, and a 9 x 9 grid of log and base sizes, 18,081
  lines, identical to the C.
- Mutants of the port, each caught by the witness: escalate 6 to 5, random decay 4 to 3, scan gap
  8 to 9, step 2 to 3, full depth 10 to 11, and a strict compaction trigger. The generators use the
  model's own numbers, not the port's constants; with the port's constants the gap and decay
  mutants slipped past the witness and only parity saw them.

## Slice 3a: a SQLite VFS written in Mojo

`src/vfs_mem.mojo` registers a VFS with real SQLite and keeps the files in a `MemStore`; slice 3b
replaces that store with FoundationDB. SQLite is loaded from the pixi environment (`sqlite` in
`pixi.toml`), and the C function tables are built in raw memory with Mojo `abi("C")` functions as
the entries; no C shim and no shared library, and it runs under `mojo run`.

- `pixi run vfs-mem`: SQLite creates a table, inserts 1,000 rows, updates, passes `integrity_check`,
  vacuums (through `xTruncate`), is closed, and a second connection sees the same rows, with no
  local file made. Then the file methods are called directly for what SQL does not reach: a short
  read, truncate, delete, and open without CREATE.
- Mutants of the VFS, each caught: a write that drops its last byte, truncate doing nothing, delete
  keeping the file, no short-read error, and open ignoring CREATE.
- Not covered yet: locking (all no-ops, as in `fdb_vfs.c`), `xFileControl`, the dirty-page buffer,
  and everything that makes the store FoundationDB: the fence, the log, the fold.

## Differences from the C header

- A builder returns the key as a `List[UInt8]` instead of writing into a buffer and
  returning a length. `key_after_in_place` keeps the `out == prefix` form so the aliasing
  property still has something to check.
- No truncation: C `snprintf` clips a name at `KEYMAX`; the Mojo key is longer and
  `fits()` says so. `fdb_vfs.c` bounds names at `MAX_NAME`, so shipping code never hits it.
- The witness's numbers mix small values, the whole 64-bit range and the edges at every
  rung. The C++ gate used the ladder's small range for the properties and a wide one only
  for the controls.
- The KEYMAX and "no `/STATUS` suffix" controls run a real mutant (a 700-byte name; a
  suffix-less record key). The C++ versions compared constants and could not fail for the
  reason they named.
- The ladder's RNG is SplitMix64, so a seed repeats a Mojo run, not a C++ run.

## Not yet verified

- `./ci.sh mojo-keys` (job `mojo-keys`) is the only gate on the key layout; the C++ one is gone.
- The ladder is pinned by `WITNESS_MOJO_REV` in `ci.sh`; bump it on purpose.
- Shrinking is off for the compound inputs (`no_shrink`), so a failure prints the input as
  drawn, not a minimum.
- Only macOS arm64 was run. `pixi.toml` lists linux-64 and linux-aarch64 untested.
