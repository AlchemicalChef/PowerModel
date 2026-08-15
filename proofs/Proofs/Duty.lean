import Mathlib

/-!
# Relay duty-integral accounting

Mirrors the per-branch relay accounting in `lib/power_model/failure/cascade.ex`
(`relay_duty`): a branch under overload accumulates duty `d += δ / t` where
`t` is its inverse-time trip time at the current loading and `δ` the step's
time advance; it trips when duty reaches 1. The step advance is
`δ = min over branches of t_i * (1 - d_i)`.

Theorems: advancing a branch by its own remaining time completes its duty
exactly; under constant loading the duty model reduces to plain elapsed
time; two equal concurrent overloads complete in ONE trip-time interval
(the pre-fix elapsed-seconds model double-counted this); and the
changing-loading case matches the ∫dt/t(M(t)) integral semantics.
-/

namespace PowerModel.Duty

/-- Remaining wall-clock time for a branch with trip time `t` and duty `d`. -/
noncomputable def remaining (t d : ℝ) : ℝ := t * (1 - d)

/-- Duty after advancing `δ` seconds at trip time `t`. -/
noncomputable def advance (t d δ : ℝ) : ℝ := d + δ / t

/-- **Completion**: advancing a branch by exactly its remaining time brings
its duty to 1, regardless of the current duty. This is the invariant that
makes "trip the branch whose remaining hit the minimum" correct. -/
theorem advance_remaining_completes {t : ℝ} (ht : t ≠ 0) (d : ℝ) :
    advance t d (remaining t d) = 1 := by
  unfold advance remaining
  field_simp
  ring

/-- **Constant-loading equivalence**: with a fixed trip time `t`, duty after
elapsed time `τ` is `τ / t` — the duty model degenerates to the simple
elapsed-time model, so nothing was lost by generalizing. -/
theorem constant_loading (t τ : ℝ) :
    advance t 0 τ = τ / t := by
  unfold advance
  ring

/-- **Concurrent overloads complete in one interval**: two branches with
equal trip time `t` and zero duty have equal remaining time `t`; the step
advance `min` is `t`, and both duties complete simultaneously. The cascade
timeline advances by `t` once — not once per branch. -/
theorem concurrent_equal_overloads {t : ℝ} (ht : t ≠ 0) :
    min (remaining t 0) (remaining t 0) = remaining t 0 ∧
      advance t 0 (remaining t 0) = 1 ∧ advance t 0 (remaining t 0) = 1 := by
  refine ⟨min_self _, ?_, ?_⟩ <;> exact advance_remaining_completes ht 0

/-- **Changing loading** (the review's scenario): a branch that spent time
`τ` at trip time `t₁` and then continues at trip time `t₂` completes after a
further `t₂ * (1 - τ / t₁)` — e.g. half-aged at 73.4 s (110% loading) then
raised to 200% (10 s curve) trips after 5 more seconds, not instantly and
not after a fresh 10 s. -/
theorem changing_loading {t₁ t₂ : ℝ} (h2 : t₂ ≠ 0) (τ : ℝ) :
    advance t₂ (advance t₁ 0 τ) (remaining t₂ (advance t₁ 0 τ)) = 1 :=
  advance_remaining_completes h2 _

/-- The remaining time after partial aging is proportional to the *unspent
duty fraction*, on the *new* curve time. -/
theorem remaining_after_aging (t₁ t₂ τ : ℝ) :
    remaining t₂ (advance t₁ 0 τ) = t₂ * (1 - τ / t₁) := by
  unfold remaining advance
  ring_nf

/-- **Monotone accumulation**: duty never decreases while a branch stays
overloaded (`δ ≥ 0`, `t > 0`). -/
theorem advance_mono {t δ : ℝ} (ht : 0 < t) (hδ : 0 ≤ δ) (d : ℝ) :
    d ≤ advance t d δ := by
  unfold advance
  have : 0 ≤ δ / t := by positivity
  linarith

end PowerModel.Duty
