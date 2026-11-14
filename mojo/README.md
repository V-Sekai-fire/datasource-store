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
| 1 | Key layout witness | `keys-witness/keys_test.cc` | Done. `tests/keys_witness.mojo` (replaces witness-cpp and doctest) |
| 2 | Page-delta, read-ahead and commit models | `spec/*.lean` checked against `fdb_vfs.c` | Not started |
| 3 | `weft_fdb_vfs` (SQLite VFS over FoundationDB) | `fdb_vfs.c` | Not started. Needs an FDB C client and a `sqlite3_vfs` binding through Mojo's C interop |
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

- The C++ `keys-witness` stage still runs beside the Mojo one (`./ci.sh mojo-keys`, job `mojo-keys`); neither replaces the other yet.
- `ci.sh mojo-keys` clones contract-witness-mojo `main` when no sibling checkout exists, so the ladder is not pinned.
- Shrinking is off for the compound inputs (`no_shrink`), so a failure prints the input as
  drawn, not a minimum.
- Only macOS arm64 was run. `pixi.toml` lists linux-64 and linux-aarch64 untested.
