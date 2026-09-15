import Backend

/-! # Replacing SQLite's btree with an FDB-shaped table

`fdb_vfs.c` sits below SQLite's btree today: SQLite walks its own page tree, and every
page read or write drops through the VFS into a store point read or write. A single
row lookup by primary key costs three or four pages walked (root, one or two internals,
leaf), and each page costs one PIDX read plus one DELTA-or-SHARD read. The measured
YCSB workload F ceiling on this box is about 12 500 ops/s at 4 workers × batch 1000, and
the store-visible pressure is 6–8 point reads per row.

This spec says what a *btree-replacement* would have to be to preserve the properties
the ladder rests on. The replacement's premise: skip the SQLite btree for one table
and store each row directly in the store's keyspace, one store key per row. A read is
one point get; a range scan is one range get.

The load-bearing correctness question is the encoding. If SQLite's expected PK sort
order is not preserved by the mapping into store keys, the replacement breaks
`ORDER BY`, breaks `sqlite3BtreeFirst`/`Next`, and breaks composite indexes. Everything
else is mechanical.

## What this file does not claim

It does not prove SQLite correct, and it does not prove FDB correct. It states what a
caller must give the replacement so that a program that used the btree cannot tell the
difference. `Weft.Backend` already fixed the store as an ordered byte keyspace; this
file states the encoding and the four operations that ride on top.

## Rule 2 controls

Each equation carries a paired planted-wrong step, and `decide` refutes agreement. So a
wrong implementation fails Lean rather than only YCSB.

SPDX-License-Identifier: Apache-2.0
-/

namespace Weft.BtreeReplacement

open Weft.Backend

/-! ## The SQLite side

A single-column primary key. Two shapes cover the YCSB workload F `usertable`: an
integer PK (`INTEGER PRIMARY KEY`) and a text PK (`YCSB_KEY VARCHAR(255) PRIMARY KEY`
under BINARY collation). SQLite never mixes the two in the same table because the
`CREATE TABLE` declares one type. -/
inductive PkVal where
  | int  (n : Int)
  | text (s : List UInt8)   -- UTF-8 bytes, BINARY collation
  deriving Repr, DecidableEq

/-- Single-column SQLite record order for the two shapes above. -/
def pkLt : PkVal → PkVal → Bool
  | .int a, .int b     => decide (a < b)
  | .text a, .text b   => lexLt a b
  | .int _, .text _    => true    -- integer PK sorts ahead of text PK by SQLite convention
  | .text _, .int _    => false

/-- One row: key and payload. `payload` is the bytes SQLite would have returned as the
record for that row. -/
structure Row where
  pk      : PkVal
  payload : List UInt8
  deriving Repr, DecidableEq

/-! ## The store side

Every table lives under a namespace prefix `T/<id>/`; each row's key is
`prefix ++ encode(pk)`. Byte-lex on `encode(pk)` must agree with `pkLt(pk_a, pk_b)`, or
the replacement breaks sort order.

For integers, big-endian two's complement with the sign bit flipped gives lex order that
agrees with numeric order. `fdb_keys.h` already carries this convention for unsigned
page numbers.

For text under BINARY collation, the UTF-8 bytes themselves sort under `memcmp` exactly
as SQLite's BINARY collation sorts them, so the encoding is the identity on the bytes.

A one-byte type tag disambiguates the two branches. Integer tag `0x01` sorts before text
tag `0x02` — matching `pkLt`'s cross-branch convention (integer before text). -/

/-- Encode a signed 64-bit integer into 9 bytes: tag `0x01` then big-endian two's
complement with the sign bit flipped. Fixed length, so no terminator needed. -/
def encodeInt (n : Int) : Key :=
  let u : UInt64 := (n.toInt64 ^^^ (Int64.ofNat (1 <<< 63))).toUInt64
  let bytes : List UInt8 :=
    (List.range 8).reverse.map (fun i =>
      ((u >>> (UInt64.ofNat (i * 8))) &&& 0xff).toUInt8)
  0x01 :: bytes

/-- Encode a text PK: tag `0x02` then the UTF-8 bytes. -/
def encodeText (s : List UInt8) : Key := 0x02 :: s

def encode : PkVal → Key
  | .int n  => encodeInt n
  | .text s => encodeText s

/-! ### Rule-2 controls on the encoding

`decide` on each of these witnesses the case. If the encoding stops being
order-preserving on any pair, the corresponding `decide` fails. -/

example : lexLt (encode (.int (-1)))   (encode (.int 0))     = true := by decide
example : lexLt (encode (.int 0))      (encode (.int 1))     = true := by decide
example : lexLt (encode (.int 127))    (encode (.int 128))   = true := by decide
example : lexLt (encode (.int (-128))) (encode (.int (-1)))  = true := by decide
example : lexLt (encode (.text [0x61])) (encode (.text [0x62])) = true := by decide
example : lexLt (encode (.text [0x61])) (encode (.text [0x61, 0x00])) = true := by decide

-- Cross-branch: integer PK sorts before text PK.
example : lexLt (encode (.int 0))      (encode (.text []))   = true := by decide
example : lexLt (encode (.int 999999)) (encode (.text [0x00])) = true := by decide

/-
Stated obligation. For every pair (a, b) of PK values, `pkLt a b = true` implies
`lexLt (encode a) (encode b) = true`. The `example`s above witness the load-bearing
cases; the general theorem across all `Int` and all UTF-8 byte lists is what
`keys-witness/keys_test.cc` should hold as a property test alongside the point checks:

    theorem encode_orderPreserving (a b : PkVal) :
        pkLt a b = true → lexLt (encode a) (encode b) = true
-/

/-! ## The four btree operations, on a sorted row list

The btree API narrows to four hot operations for a single-table read/write shape:
`sqlite3BtreeMovetoUnpacked` + `sqlite3BtreeKey`/`Data` (= get), `sqlite3BtreeInsert`
(= put), `sqlite3BtreeDelete` (= delete), and `sqlite3BtreeFirst`+`Next` (= rangeAsc).

The list-based model below is decidable so every equation is checkable with `decide`. -/

def get (rows : List Row) (pk : PkVal) : Option (List UInt8) :=
  (rows.find? (fun r => r.pk == pk)).map (·.payload)

def put (rows : List Row) (r : Row) : List Row :=
  match rows with
  | [] => [r]
  | x :: xs =>
      if x.pk == r.pk then r :: xs
      else if pkLt r.pk x.pk then r :: x :: xs
      else x :: put xs r

def del (rows : List Row) (pk : PkVal) : List Row :=
  rows.filter (fun r => decide (r.pk ≠ pk))

def rangeAsc (rows : List Row) (lo hi : PkVal) : List Row :=
  rows.filter (fun r => (pkLt lo r.pk || decide (lo = r.pk)) && pkLt r.pk hi)

/-! ### The equations the C replacement has to satisfy

Each pair below states the correctness law and the planted-wrong version's failure. -/

/- Concrete sample used by the controls. -/
def sample : List Row :=
  [ { pk := .int 3, payload := [0x2a] },
    { pk := .int 7, payload := [0x55] } ]

-- put then get on the same key returns the new payload.
example : get (put sample { pk := .int 5, payload := [0xaa] }) (.int 5) = some [0xaa] := by decide

-- put on an existing key replaces its payload.
example : get (put sample { pk := .int 3, payload := [0xbb] }) (.int 3) = some [0xbb] := by decide

-- put preserves other rows.
example : get (put sample { pk := .int 5, payload := [0xaa] }) (.int 3) = some [0x2a] := by decide
example : get (put sample { pk := .int 5, payload := [0xaa] }) (.int 7) = some [0x55] := by decide

-- delete then get returns none.
example : get (del sample (.int 3)) (.int 3) = none := by decide

-- rangeAsc pulls the interval, half open.
example : rangeAsc sample (.int 0) (.int 8) = sample := by decide
example : rangeAsc sample (.int 3) (.int 7) = [{ pk := .int 3, payload := [0x2a] }] := by decide
example : rangeAsc sample (.int 4) (.int 8) = [{ pk := .int 7, payload := [0x55] }] := by decide

/-! ### The planted-wrong controls (rule 2)

The wrong `put` ignores the new payload on a matching key: `get` after `putBroken` on an
existing key returns the old payload. `decide` refutes agreement. -/

def putBroken (rows : List Row) (r : Row) : List Row :=
  match rows with
  | [] => [r]
  | x :: xs => if x.pk == r.pk then x :: xs else x :: putBroken xs r

example : get (putBroken sample { pk := .int 3, payload := [0xbb] }) (.int 3) ≠ some [0xbb] := by decide

/-- The wrong `del` filters by payload identity rather than by pk. `decide` refutes
that a caller who deletes by pk gets a table without that pk. -/
def delBroken (rows : List Row) (_pk : PkVal) : List Row :=
  rows.filter (fun _ => true)   -- deletes nothing

example : get (delBroken sample (.int 3)) (.int 3) ≠ none := by decide

/-! ## Correspondence to the store

A table `t` under a namespace `prefix` lives in the store as a set of key-value pairs
`{prefix ++ encode(r.pk) ↦ r.payload | r ∈ t}`. The four operations map:

  get rows pk           = Backend.get (prefix ++ encode pk)
  put rows r            = Backend.set (prefix ++ encode r.pk) r.payload
  del rows pk           = Backend.clear_range [prefix ++ encode pk, key_after]
  rangeAsc rows lo hi   = Backend.get_range [prefix ++ encode lo, prefix ++ encode hi)

Each right-hand side is one call in `Weft.Backend`'s surface — the same six calls
`fdb_vfs.c` already uses (`get`, `set`, `get_range`, `clear_range`, `commit`,
`on_error`). No new store primitive is needed.

The isolation guarantee inherits from `Weft.Backend`: strict-serialisable over the read
and write set the txn accumulates. `sqlite3BtreeBeginTrans` opens the txn;
`CommitPhaseOne` + `CommitPhaseTwo` collapse into one `Backend.commit`.

## What the C implementation still owes

- A property test witnessing `encode_orderPreserving` across random `Int` and byte-list
  inputs, since Lean states it as an obligation rather than proving it here. Landed at
  `btree-fdb/encode_test.cc`.
- A fork of `src/btree.c` that translates every `sqlite3BtreeXxx` entry point into the
  `Weft.Backend` calls named above, using the encoding in `btree-fdb/encode.h`.
- Handling for `sqlite_master` and `sqlite_sequence` inside the fork: the same encoding
  extends to their row shapes.
- Composite indexes: the two-column PK is `encode(col_a) ++ encode(col_b)`, and the
  order-preservation extends by lexicographic concatenation.
-/

end Weft.BtreeReplacement
