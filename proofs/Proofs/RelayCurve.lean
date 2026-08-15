import Mathlib

/-!
# IEC 60255-151 standard-inverse relay curve

Mirrors `lib/power_model/failure/protection.ex` (`overcurrent_trip_time/2`):

    t(M) = k / (M ^ 0.02 - 1)   for current multiple M > 1, k > 0.

Theorems: trip time is strictly positive and strictly decreasing in the
overload multiple. (The pre-fix code used the linear denominator `M - 1`
with the IEC constant `k = 0.14`, producing times 50-70x too fast; these
proofs are about the corrected curve's qualitative behavior — positivity
and monotonicity — which any inverse-time relay model must satisfy.)
-/

namespace PowerModel.RelayCurve

noncomputable def tripTime (k M : ℝ) : ℝ := k / (M ^ (0.02 : ℝ) - 1)

/-- For `M > 1` the denominator is strictly positive. -/
lemma denom_pos {M : ℝ} (hM : 1 < M) : 0 < M ^ (0.02 : ℝ) - 1 := by
  have h1 : (1 : ℝ) < M ^ (0.02 : ℝ) := by
    have := Real.one_lt_rpow_iff_of_pos (x := M) (y := (0.02 : ℝ)) (by linarith)
    rw [this]
    left
    exact ⟨hM, by norm_num⟩
  linarith

/-- **Positivity**: an overloaded branch always has a finite positive trip
time. -/
theorem tripTime_pos {k M : ℝ} (hk : 0 < k) (hM : 1 < M) :
    0 < tripTime k M := by
  unfold tripTime
  exact div_pos hk (denom_pos hM)

/-- **Strict monotonicity**: a heavier overload trips strictly sooner. -/
theorem tripTime_strictAnti {k M₁ M₂ : ℝ} (hk : 0 < k)
    (h1 : 1 < M₁) (h12 : M₁ < M₂) :
    tripTime k M₂ < tripTime k M₁ := by
  unfold tripTime
  have hd1 : 0 < M₁ ^ (0.02 : ℝ) - 1 := denom_pos h1
  have hpow : M₁ ^ (0.02 : ℝ) < M₂ ^ (0.02 : ℝ) := by
    apply Real.rpow_lt_rpow (by linarith) h12 (by norm_num)
  have hd2 : 0 < M₂ ^ (0.02 : ℝ) - 1 := by linarith
  apply div_lt_div_of_pos_left hk hd1
  linarith

/-- Boundary sanity: just above rated loading the denominator is tiny but
still positive, so trip times are large but finite (no division by zero is
reachable for `M > 1`). -/
theorem denom_ne_zero {M : ℝ} (hM : 1 < M) : M ^ (0.02 : ℝ) - 1 ≠ 0 :=
  ne_of_gt (denom_pos hM)

end PowerModel.RelayCurve
