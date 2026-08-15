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
