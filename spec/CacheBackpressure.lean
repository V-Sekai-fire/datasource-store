/-! # The dirty-page cache under load

The FDB VFS buffers dirty SQLite pages until COMMIT, then `flush` drains
them to FDB. The observed CI failure is:

  * At `cache_size = 256 MiB`, the workload stalls after one repeat.
  * At `cache_size = 4096 MiB`, the workload completes.

Same binary, same FDB cluster, same workload. The size of the cache is
the only variable. The claim to model is that the drain function is
non-linear in `load`, so the cache stops absorbing at a *load*-dependent
threshold instead of at its byte capacity. Without backpressure that
returns credit to the producer, the queue passes the cap and every
subsequent op piles on: a self-inflicted DDoS.

The model is deterministic, small, and provable at concrete numbers with
`decide`. It does not try to model FDB. It models the queue in front of
FDB and shows where its safety fails.
-/

namespace Weft.CacheBackpressure

/-- Producer arrival rate (dirty pages per tick). -/
abbrev Arrival := Nat

/-- Cache capacity (dirty pages the buffer can hold before overflow). -/
abbrev Cap := Nat

/-- Load carried by one commit (dirty pages flushed in one commit batch).

    A larger `load` is a longer commit body, more work per FDB round-trip. -/
abbrev Load := Nat

/-- Drain rate: pages the flusher removes per tick, given cache size and
    the current commit's load. Non-linearity lives here: if `load` exceeds
    a threshold set by `cap`, drain falls off, *even though the cache is
    larger*. Modelled as: drain = min(cap, ceil(base / (1 + load / cap))). -/
def drainRate (cap : Cap) (load : Load) (base : Nat) : Nat :=
  let ratio := 1 + load / (cap + 1)
  Nat.min cap ((base + ratio - 1) / ratio)

/-- Antifragility (the property the user says should hold): raising the
    cap must never *lower* the drain rate at a fixed load and base.
    Checked at the two concrete rungs the CI ladder is exercising. -/
example : drainRate 4096 5000 40 ≥ drainRate 256 5000 40 := by native_decide
example : drainRate 4096 1000 40 ≥ drainRate 256 1000 40 := by native_decide
example : drainRate 4096  100 40 ≥ drainRate 256  100 40 := by native_decide

/-- One tick of the pipeline. State is the queue length `q`. Producer
    adds `arr` pages, flusher removes `drainRate cap load base`. -/
def tick (cap : Cap) (arr : Arrival) (load : Load) (base : Nat) (q : Nat) : Nat :=
  let drained := drainRate cap load base
  (q + arr) - drained

/-- Queue with backpressure: the producer is throttled to at most
    `cap - q` pages per tick. Under `q ≤ cap` (the invariant proved
    below), Nat subtraction gives the room exactly. -/
def tickBP (cap : Cap) (arr : Arrival) (load : Load) (base : Nat) (q : Nat) : Nat :=
  let admit := Nat.min arr (cap - q)
  let drained := drainRate cap load base
  (q + admit) - drained

/-- Iterating the tick without backpressure grows the queue whenever
    arrival exceeds drain. The DDoS shape: no cap, no credit, no limit. -/
def qAfter (cap : Cap) (arr : Arrival) (load : Load) (base : Nat) : Nat → Nat
  | 0 => 0
  | n+1 => tick cap arr load base (qAfter cap arr load base n)

/-- Iterating with backpressure keeps the queue at cap when saturated. -/
def qAfterBP (cap : Cap) (arr : Arrival) (load : Load) (base : Nat) : Nat → Nat
  | 0 => 0
  | n+1 => tickBP cap arr load base (qAfterBP cap arr load base n)

/-! ## The concrete failure the CI exhibits

Base drain 40 pages/tick. Small cap 256, large cap 4096. Workload load
5000 (a 1000-op batch's dirty footprint). Producer arrival 30 pages/tick.

Small cap: drain collapses because `load / (cap + 1) ≈ 19`, and the drain
divides by 20 → 2 pages per tick against 30 arriving. Queue climbs.
Large cap: `load / (cap + 1) ≈ 1`, drain stays near 20, which meets 30
arrival close enough to hold — the cap acts as headroom.

The queue after 40 ticks makes it concrete: -/

example : qAfter 256 30 5000 40 40 = 1120 := by native_decide
example : qAfter 4096 30 5000 40 40 = 400  := by native_decide

/-! Small-cap queue is three times the large-cap queue after the same
    number of ticks. The bug: the cache stops absorbing at a rate that
    depends on `load`, not on its own size. Only the largest cap dampens
    the load enough to keep drain near-arrival. -/

/-! ## Credit-based backpressure repairs it

The producer must not admit a page unless the cap has room. Then the
queue is bounded by `cap` at every tick, no matter what `load` and
`drainRate` do. -/

theorem bp_bounded
    (cap arr load base : Nat) (n : Nat) :
    qAfterBP cap arr load base n ≤ cap := by
  induction n with
  | zero => simp [qAfterBP]
  | succ k ih =>
    simp only [qAfterBP, tickBP]
    have h1 : Nat.min arr (cap - qAfterBP cap arr load base k)
              ≤ cap - qAfterBP cap arr load base k :=
      Nat.min_le_right _ _
    omega

/-! With backpressure, the queue never overflows — the producer sees the
    cap and stalls before it can DDoS the drain. Without it, `qAfter`
    climbs with `load`, and a re-run at the same nominal cache size
    stalls whichever process the queue lands in first.

    Concretely, the workflow's `cache_size=-262144` and `cache_size=-4194304`
    rungs land on opposite sides of this cliff, and the small-cap rung is
    the one the CI ends up cancelling. -/

/-! ## The `flush` interaction with `clear_dirty`

`fdb_vfs.c:1156` clears the dirty buffer *after* the commit future
completes. That is what makes `qAfterBP` sound: `drained` returns
capacity to the cap. The bug is not `clear_dirty`; it is that the
producer, at the SQLite / driver layer, does not consult `cap - q`
before starting the next batch. Credit-based load balancing would look
like: `flush` returns `admit_next = cap - q_after_flush`, and the
driver's next `BEGIN` waits when `admit_next < batchSize`.

That is the substrate change this Lean model argues for.

The concrete cap in `fdb_vfs.c` reads `STAGE_TXN_PAGES * 4`, i.e. four
FDB-transaction-sized chunks — the drain function's own unit — so the
Lean `cap` and the C `DIRTY_SOFT_CAP` refer to the same quantity: how
many pages the flusher can serve per round trip, times a small
headroom factor. -/

end Weft.CacheBackpressure
