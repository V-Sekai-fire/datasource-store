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
| 3b | FoundationDB client binding (network thread, transactions) | `fdb_c.h` use in `fdb_vfs.c` | Done. `src/fdb_client.mojo` |
| 3c-1 | The two joined, first cut: open, read, write, commit, fence, truncate, delete | `fdb_vfs.c` | Done. `src/vfs_fdb.mojo` |
| 3c-2 | Shard reads, delta writes, and the fold at close | `fdb_vfs.c` | Done. Same bytes as the C: `tests/cross.sh` |
| 3c-3 | Staged commits above one transaction, and recovery of group commits another committer left staging | `fdb_vfs.c` | Done. Same bytes as the C for 2,300-page commits: `tests/cross.sh` |
| 3c-4 | Starting a cross-database group: `weft_txn_begin`, `join`, `commit`, `abort` | `fdb_vfs.c` | Done. The C reads what a Mojo group wrote: `tests/cross.sh` |
| 3c-5 | Read-ahead, readers that follow the head | `fdb_vfs.c` | Not started |
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

## Slice 3b: a FoundationDB client in Mojo

`src/fdb_client.mojo` loads `libfdb_c`, selects API 730, starts the network loop on a thread
(`fdb_run_network` is handed to `pthread_create` as the start routine), and wraps what
`fdb_vfs.c` uses: get, set, clear_range, commit, and the retry decision. Nothing else.

- `pixi run fdb-client` needs a live cluster (`WEFT_FDB_CLUSTER_FILE`, and `WEFT_FDB_LIB` when
  `libfdb_c` is not in the usual place). It writes three page rows under the real key layout, reads
  them back, clears a range and checks the end is exclusive, reads a key never written, and makes
  a real read-write conflict: commit A reads a key B then overwrites, and A's commit fails with
  1020 and FoundationDB says it may be retried.
- CI runs it in the `test` job, which has a FoundationDB.
- Without a server of your own, `tests/fdb_container.sh` runs the whole thing in a Linux container
  with a throwaway server: `podman run --rm -v "$PWD":/src:ro docker.io/library/debian:bookworm-slim
  sh /src/mojo/tests/fdb_container.sh`. With `-e MUTANTS=1` it also breaks the client four ways (a
  short value, swapped range ends, a get that never sees a value, a commit that hides its error)
  and requires the test to fail each time. All four are caught.
- On macOS, `fdbserver` could not start from an agent terminal (`Could not open shared memory`),
  which is why the container exists. Against a missing cluster file the client fails with
  FoundationDB's own error 1515, not a crash.
- Not covered: the retry loop itself (`run_txn`), the cached read transaction, transaction options,
  and futures that outlive their call. Those come with the VFS in 3c.

## Slice 3c-1: SQLite on a Mojo VFS whose files live in FoundationDB

`src/vfs_fdb.mojo` is `vfs_mem.mojo` with `fdb_vfs.c`'s storage: HEAD, SIZE and LOGN, `PIDX/<pgno>`
naming the commit that owns a page, `DELTA/<txid>/<pgno>` holding it, a fence raised on open and
checked in every write, the dirty-page buffer, one-transaction commits, and the retry loop. Page
numbers start at 0, as in the C (`offset / 4096`), so SQLite's header is `PIDX/0`.

- `pixi run vfs-fdb` (needs a cluster): SQLite creates a table, inserts 1,000 rows, updates and
  passes `integrity_check`; the test then reads FoundationDB directly to check HEAD, SIZE, the
  PIDX and DELTA rows and SQLite's header in page 0. A reopen sees the rows; a third open raises
  the fence and the stale handle's commit is refused with HEAD unmoved; a read-only open takes no
  fence; a commit staged above HEAD is cleared by the next open.
- A store the C folded opens (slice 3c-2), pages with a base row go as deltas, and the file folds
  at close. A commit above `ONE_TXN_PAGES` stages its pages `STAGE_TXN_PAGES` to a transaction under a
  txid no read can reach, then one transaction moves the head (slice 3c-3).
- Runs in CI's `test` job with the client test, and in `tests/fdb_container.sh` against a throwaway
  server. With `MUTANTS=1` the script breaks the client five ways and the VFS five ways (no fence
  check, no index rows, an unfinished commit left behind, no fence raise, HEAD not advanced, a read
  that ignores the buffer) and requires the matching test to fail each time.
- Not yet compared with the C byte for byte: writing a store with `fdb_vfs.c` and reading it from
  Mojo, and the reverse, is the next check.

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

## Slice 3c-2: the same bytes as the C

`tests/cross.sh` (run by `CROSS=1 sh tests/fdb_container.sh`) runs one SQL workload through the C VFS
and then through the Mojo VFS, each from an empty store, and compares every key and value
`fdbcli` can read: the fence, the commit ids, the shard pages, the delta rows and their bases. The
workload is four sessions: create and fill (a fold at close), a small update, more rows and a
delete (a second fold), and a last small update left as PIDX and DELTA rows. Both sides use one
SQLite library, because SQLite writes its version number into page 0. The step failed before the
fold was ported (20 rows against 9), so it can fail. The same script reads in both directions:
Mojo reads a store the C wrote and folded, with deltas against its shard, and the C reads what
Mojo wrote.

The fold reads and writes a window of pages at a time, as the C does: every logged page's row is
requested at once, then every base row, and up to four windows' commits are in flight while the next
window is read. Closing a database of 100,600 posts and 101,200 likes (about 6,000 pages) in a
container on one single-node in-memory FoundationDB, two runs each, one fresh container per run:

| Close, paying the owed fold | Run 1 | Run 2 |
|---|---|---|
| Mojo VFS, a window at a time and each get waited on | 1.217 s | 1.272 s |
| Mojo VFS, pipelined | 0.187 s | 0.201 s |
| C VFS | 0.184 s | 0.191 s |

`BENCH=1 ONLY=both USERS=25000 POSTS=100000 LIKES=200000 sh tests/fdb_container.sh` reproduces it.
A wipe of a large store leaves the storage server busy, so `bench.sh` waits after each wipe; before
that wait a Mojo run that followed a C run read 2.5 s, which was the wipe and not the fold.

## Benchmark

`bench/` runs the $12-server challenge's operations on plain SQLite, the C VFS and the Mojo VFS
(`BENCH=1 sh tests/fdb_container.sh`). Measured in the container on one single-node in-memory
FoundationDB: single commits are equal, batched writes are 93 to 98 percent of the C's, and a
feed read after the writes was about 75 percent of it because the Mojo driver, not the VFS, was
slower: it looked up `sqlite3_step` and `sqlite3_reset` by name on every call, which a dtrace
profile on the Mac put at 987 of 3,975 samples in dyld (the C run took 2,737 samples in all). With
the symbols resolved once the feed after the writes runs at 68,000 to 71,400 reads a second against
52,000 before, and the C driver's 74,500 to 76,500; SQLite's own time still differs by about a tenth
between runs, because `random()` makes each run's data different. Read rows from before this fix
include that driver cost. The fold at close is within about 5 percent of the C's (table above).

## Slice 3c-3: big commits and other committers

A commit above `ONE_TXN_PAGES` (1,857 pages) stages. Its pages go first, `STAGE_TXN_PAGES` (2,100)
to a transaction, each transaction checking the fence, and one last transaction writes the index,
the size and the head. A process that dies between leaves rows above the head that nothing points
at, and the next open clears them.

Other committers matter here. A group commit stages one intent per database, then writes a record
at `weft/txn/<id>`. After that record lands the group is committed, whether or not its writer
survives. So a writer's open decides every staging record before it raises the fence or clears the
rows above the head, as `recover_one` does in the C: all intents durable finishes the group, a
missing intent aborts it and raises the fence of the participant that lacked one, and no other. A
reader skips this. A group participant must stage in one transaction, as in the C, so a group
never takes the chunked path: a member with more pages than that is refused at its sync.

This VFS starts groups too (slice 3c-4). `weft_txn_begin` takes the next id from a counter in the
store, `weft_txn_join` marks a database so its syncs stage instead of committing, and
`weft_txn_commit` writes the record in one transaction that also reads every member's fence, then
moves each head and drops the record. An abort writes nothing: the staged pages stay unreachable
and the next open clears them. One difference from the C: it holds a lock from begin to commit, so
a second begin waits; this VFS has none to hold, and a second begin answers `SQLITE_BUSY`.

## SQLite's own test corpus

`bench/slt.mojo` runs sqllogictest files, the corpus SQLite ships for checking engines against each
other, through SQLite's own file VFS and through the Mojo VFS, and `bench/slt.sh` diffs the two,
record by record. It does not compare with the file's expected results, which test SQLite. It
compares what SQLite answers over this VFS with what it answers over its own, so any line that
differs is the VFS changing an answer.

    SLT=1 sh tests/fdb_container.sh     # with the corpus mounted at /slt

The corpus is `github.com/gregrahn/sqllogictest`. The run uses 23 files: `select1` to `select5`, the
`evidence` files, and one `index` file for each of six index operations. That is 72,112 records,
and the two sides agree on all of them.

Both sides run with a ten page cache, so reads go back through the VFS. With SQLite's own cache a
single session never reads a page back, and a fault in what the VFS stored would pass. The control
that shows this: with the PIDX rows left out of every commit, the suite passes at the default cache
and fails both files tried at ten pages (`SLT_SED` plants a fault in `vfs_fdb.mojo` first). The
price is time: `select4` takes 119 s through the Mojo VFS, against 1.8 s on a local file.

Each file reports its time in milliseconds from the runner's own clock, and from FoundationDB's:
`Txn.read_version` in `fdb_client.mojo`. A read version is the newest commit's, and advances about
1,000,000 a second while commits happen, so the difference of two is a duration the database
agrees with.

## Direct B-tree reads

`bench/btree.mojo` reads two things both ways on one database, over SQLite's own file VFS and over
the Mojo VFS: through SQL, and through SQLite's B-tree cursor calls inside a read transaction, as
the mojo-iouring submission to the $12 server challenge does. A post by id is a posts row, its
user and its like count. The feed is the 20 newest posts, each the same way.

    BTREE=1 BTREE_MUTANTS=1 sh tests/fdb_container.sh

Measured in the container, three runs each, on 5,000 users, 20,000 posts and about 40,000 likes,
SQL against direct reads in operations a second:

| Read | VFS | SQL | Direct |
|---|---|---|---|
| Post by id | SQLite's file VFS | 1.28 M | 2.45 M |
| Post by id | Mojo VFS over FoundationDB | 1.26 M | 2.34 M to 2.48 M |
| Feed, 20 posts | SQLite's file VFS | 91 k to 94 k | 233 k to 253 k |
| Feed, 20 posts | Mojo VFS over FoundationDB | 88 k to 93 k | 252 k to 253 k |

The VFS does not matter: reads come from SQLite's page cache. The gain is the SQL engine, which
the direct path skips. A profile of the SQL path shows the B-tree seek as the largest item, then
mutex lock and unlock, `VdbeExec` and `VdbeHalt`, and cursor open and close, which the direct path
does not pay. A profile of the direct path alone is about 70 percent `sqlite3BtreeTableMoveto`.

What it costs, and how the driver guards it:

- It needs SQLite's internals, so the amalgamation is built with `-DSQLITE_PRIVATE=`. The version is
  pinned to 3.50.4; any other version does not run the direct path.
- It takes the Btree from `sqlite3DbNameToBtree`, not from a struct offset. One size is assumed,
  `sizeof(Mem)` of 56, for the key of the likes index; the checks below fail if it is wrong.
- Before timing, 2,000 posts and the feed are checked against SQL, value for value.
- The feed is reverse rowid order only while ids are dense and `created_at` never falls with id.
  SQL checks both; a planted post older than its predecessor must be seen.
- A record on overflow pages is read whole with `sqlite3BtreePayload`, tested with an 8,000 byte
  body.
- Five planted faults are each caught: a like counted twice, an overflow record not followed, the
  index search skipping a step, a user read from the wrong row, and a wrong version pin. The
  unmutated driver must pass first, or a failure proves nothing. The first version of this check
  passed for a wrong reason: the driver crashed in the container on an uninitialized key, which
  failed every mutant alike.
