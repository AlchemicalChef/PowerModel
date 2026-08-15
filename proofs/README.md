# PowerModel Proofs

Machine-checked (Lean 4 + Mathlib) proofs of the mathematics behind the
cascade simulator. Each module formalizes the *specification* of a piece of
the Elixir implementation and proves the properties that this codebase's
math audit found violated — the theorems are the bug classes, made
impossible.

Build: `cd proofs && lake build` (first build fetches the Mathlib cache).
Zero `sorry`/`Admitted` — every stated theorem is fully proved.

## Theorem ↔ code map

| Module | Mirrors | Key theorems |
|---|---|---|
| `Proofs/Swing.lean` | `lib/power_model/solver/frequency.ex` imbalance + Euler step | `stepDf_mono_shed` (shedding never deepens the decline — the sign bug, stated and refuted via `buggyImbalance_anti_shed`), `imbalance_anti_df` (damping opposes deviation), `stepDf_fixed` + `stepDf_sub_dfStar` (unique equilibrium, exact `(1-β)` error recursion), `stepDf_contracts` + `beta_lt_two_iff` (stability iff `dt < 4HS/(D·Pload)`) |
| `Proofs/Conservation.lean` | `cascade.ex` `balance/1` accounting (pre-BTM — see divergence note) | `Trace.total_eq` (served + shed + blackout invariant along every cascade trace), `Trace.wf` (buckets stay non-negative), `proportional_shed` (the proportional-shedding transition is well-formed) |
| `Proofs/Ufls.lean` | `frequency.ex` `@ufls_stages` / `protection.ex` `ufls_schedule/1` | `schedule_antitone`, `schedule_le` (≤ 30%), `schedule_eq_zero` (nothing above 59.3 Hz), `schedule_at_bottom` (exactly 30% below 58.1 Hz) |
| `Proofs/RelayCurve.lean` | `protection.ex` `overcurrent_trip_time/2` (IEC 60255-151 SI) | `tripTime_pos`, `tripTime_strictAnti` (heavier overload trips strictly sooner), `denom_ne_zero` (no division by zero for M > 1) |
| `Proofs/Duty.lean` | `cascade.ex` `relay_duty` accounting | `advance_remaining_completes` (min-remaining selection is exact), `constant_loading` (reduces to elapsed time), `concurrent_equal_overloads` (one interval, not two — the double-count bug), `changing_loading` / `remaining_after_aging` (∫dt/t semantics) |
| `Proofs/Zip.lean` | `load_model.ex` ZIP factor | `factor_at_nominal` (V=1 ⇒ factor 1), `dfactor_is_deriv` (`dfactor_dv` is the true derivative — correctness of the NR Jacobian terms), `factor_mono` |

## Fidelity caveat

The proofs are about faithful transcriptions of the implemented formulas
(cited by file:line in each module's docstring), not the Elixir code itself.
If a formula in the code changes, the corresponding Lean definition must be
updated by hand — treat a divergence between the two as a red flag in review.

**Known divergence — UFLS linearization (`Proofs/Swing.lean`)**: the Lean
model holds `Pload` constant, while `frequency.ex` now (ENE-6) sheds each
UFLS stage as a fraction of the *currently-connected* load and applies load
damping to the *remaining* load (`Pload − shed`). Each individual Euler step
still matches the Lean `imbalance`/`stepDf` exactly when `Params.Pload` is
instantiated as that step's remaining load, so the per-step lemmas
(`stepDf_mono_shed`, `stepDf_sub_dfStar`, `stepDf_contracts`) apply
step-by-step with a `Pload` that shrinks as stages trip; since
`beta = dt·D·Pload/(2HS)` only decreases as `Pload` shrinks, the stability
bound `beta_lt_two_iff` checked at simulation start remains the worst case.
The constant-`Pload` transcription, however, no longer matches the code
verbatim across a trajectory once shedding begins.

**Known divergence — deliverable primary response (`Proofs/Swing.lean`)**:
`Swing.lean` takes `gov` as a FREE real argument of `imbalance`/`stepDf`, so
every per-step lemma holds for whatever governor megawatts the code computes
for that step — and ROADMAP item 14 only changed how that number is computed
(governor duty, a per-fuel duty share, a governor deadband, a sustained
primary-response ceiling and a MW/s delivery rate limit). `stepDf_mono_shed`,
`imbalance_anti_df` and `stepDf_shed_diff` therefore transcribe the code
exactly, step by step, unchanged.

What the change does touch is the two equilibrium results.
`stepDf_fixed`/`stepDf_sub_dfStar` characterise `dfStar` and the exact
`(1-β)` error recursion **at constant `gov`**. The implemented governor is a
function of `df`, so in its linear region (deadband exceeded, no cap binding)
the recursion is really

    df' = (1 - β - γ)·df + const,   γ = dt·f0·k/(2HS),
    k = Σᵢ dutyᵢ·P_ratedᵢ / (R·f0)   (MW per Hz),

with the per-step `γ` further scaled down by the first-order governor lag
(`min(dt/T_gov, 1)`) and clipped by the delivery rate limit. Two consequences,
stated rather than proved:

* The unique equilibrium is no longer `dfStar` at the step's `gov`; it is the
  fixed point of the *closed loop*, which is exactly what makes β = ΔP/Δf a
  meaningful interconnection-level number.
* `beta_lt_two_iff` bounds `β` alone. Contraction of the closed loop needs
  `0 < β + γ < 2`, so a large enough governor gain could in principle break
  a step that the checked `β ≤ 1` accepts. Measured on the three ingested
  interconnections at `dt = 0.1 s` (2026-08-15): `β` = 0.011–0.014 and `γ` =
  0.056–0.098, falling to 0.009–0.013 once the governor lag is applied — two
  orders below the bound, so `β ≤ 1` remains comfortable in practice.
  Extending `beta_lt_two_iff` to `β + γ` is the natural next Lean step and is
  the honest gap here.

**Known divergence — persistent frequency state (`Proofs/Swing.lean`,
`Proofs/Ufls.lean`)**: ROADMAP item 15 lets `Frequency.simulate_with_state/4`
resume a segment from a previous one's final state. On the swing side this
costs nothing: `lost`, `gov`, `shed` and `df` are all free parameters of
`stepDf`, and resuming instantiates them from the carried state instead of
from `(lost, 0, 0, 0)`. `Params.Pload` is instantiated as the segment's load
base (currently connected + already shed), which can only shrink across
segments, so `β = dt·D·Pload/(2HS)` is non-increasing and the bound checked at
the first segment stays the worst case — the same argument as the UFLS
linearization note above, extended across segments rather than across steps.
Each resumed call re-checks `β` regardless.

Two consequences of `cascade.ex` driving those segments (ROADMAP items 15–16)
are worth recording beside it, neither of which touches a proved statement.
First, the `lost` a resumed segment is handed is a SIGNED DELTA: the cascade
computes the imbalance the island physically has and subtracts the one the
carried state already implies, so a segment in which reserves replaced
governor response, or in which the cascade's own force-shed tier closed part
of the gap, is told a NEGATIVE new imbalance. `stepDf` takes `lost` as a free
real parameter, so every step lemma applies unchanged; what is not formalized
is the cascade's bookkeeping identity itself (that
`lost_told − cumulative_shed = physical imbalance` at every segment
boundary), which is pinned by tests only. Second, an island that splits hands
BOTH halves the parent's state with the cumulative quantities apportioned by
load share, so each child's `Params.Pload` is a fraction of the parent's — the
monotonicity argument above still holds, in the direction it already needed.

The conservation identity is UNCHANGED by these items. Generator
under-frequency trips (item 15) can now take an island's whole fleet, but a
tripped machine moves no load: the megawatts it was serving leave through the
already-formalized shed and blackout transitions, so
`served + shed + blackout = original + btm_tripped` holds in exactly the
shape `Conservation.lean` and the BTM note below describe.

`Ufls.lean` is a different matter. It formalizes the STATIC map from nadir to
cumulative shed fraction (`protection.ex ufls_schedule/1`). With state
threaded, `LoadShedding.remaining_schedule/2` returns only the stages still
ARMED — a stage that opened at the first disturbance cannot open again at the
second. So:

* `schedule_le` (≤ 30%) and `schedule_eq_zero` (nothing above 59.3 Hz) still
  bound the implemented function: a subset of the stages sums to no more than
  all of them, and no stage arms above the first threshold.
* `schedule_antitone` holds **within one segment** — at a fixed prior state,
  a deeper nadir still selects a superset of stages — but NOT across segments.
  A deeper nadir at the second disturbance can legitimately return a smaller
  fraction than a shallower nadir did at the first, because the breakers the
  first one opened are already open. That is the intended physics and the
  reason the Lean statement no longer reads as a global property of the
  system; formalizing it means giving `Ufls.lean` the armed/tripped state as
  an argument and re-proving antitonicity pointwise in that state.

**Not machine-checked — PRC-024 generator frequency envelopes**:
`Protection.generator_frequency_trips/2` (item 15) is pure and has two
properties worth a proof, currently pinned by tests only: time-in-band is
monotone in both excursion depth and excursion duration, so a worse excursion
never trips fewer units; and each unit appears at most once, reported against
the most severe band it violated. Neither is stated in Lean.

**Known divergence — behind-the-meter trip accounting (`Proofs/Conservation.lean`)**:
`Conservation.lean` formalizes the PRE-BTM transition system, in which the
only transitions move load between three buckets and `Trace.total_eq` proves
the closed invariant `served + shed + blackout = original`. `cascade.ex` now
(ROADMAP item 31) carries a fourth quantity: when IEEE 1547 legacy inverters
trip, behind-the-meter solar output appears at the bus as load that was never
in `original`, because `original` was computed from EIA-930 demand already
metered net of it. The implemented identity is therefore

    served + shed + blackout = original + btm_tripped

with `btm_tripped` an additive SOURCE term, not a redistribution among the
existing buckets. This is a conservative extension rather than a
contradiction: every proved transition is unchanged and still preserves the
Lean invariant, and setting `btm_tripped = 0` — no layer, night, an
all-1547-2018 fleet — recovers `Trace.total_eq` exactly. Once a megawatt has
entered through the new term it is ordinary load, shed and blacked out by the
already-formalized transitions.

What is NOT machine-checked is the new term itself: that a BTM trip adds
exactly the island's legacy share once, that the tripped set is monotone (no
reconnection re-credits a bucket), and that `btm_tripped` is therefore
non-decreasing. Formalizing that means adding a `btmTrip` transition to the
Lean transition system and re-proving `Trace.total_eq` against the extended
identity — a good candidate for the next Lean pass, and the reason this
divergence is recorded here rather than left implicit.

## Stretch goals (not yet formalized)

- LU factorization with partial pivoting: `P·A = L·U` for the algorithm in
  `native/sparse_solver/src/lib.rs` (the l-swap bug class).
- Nonsingularity of the reduced DC susceptance matrix B′: for a connected
  network with positive branch susceptances, the slack-reduced Laplacian is
  positive definite (solvability of the DC power flow).
- Convergence of the Q-limit outer loop under monotone switching.
