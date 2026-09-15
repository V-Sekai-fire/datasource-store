// wal_fdb_stubs.inl — Rung 10 Slice 2c stub for the wal.c section.
// wal.c only exported one function outside its own TU
// (`sqlite3WalDefaultHook`), and *that* function is actually defined in
// main.c further down the amalgamation, not in wal.c. So excising wal.c
// leaves nothing to stub; this file only carries the `Wal` type tag so
// forward-decl uses elsewhere resolve.
//
// SPDX-License-Identifier: (Apache-2.0 OR MIT) AND sqlite-blessing

struct Wal { int _unused; };
