import Mathlib

/-!
# Swing-equation step: stability of the discrete frequency dynamics

Mirrors `lib/power_model/solver/frequency.ex` (`simulate/5`): the corrected
per-step power imbalance

    p_imbalance = -lost_mw + gov_mw - (Pload * D / f0) * df + shed_mw

and the explicit-Euler update

    df' = df + dt * f0 * p_imbalance / (2 * H * S).

The theorems pin exactly the properties the pre-fix code violated:
shedding load and load damping must *stabilize* the frequency (the old code
had both signs inverted, so UFLS deepened the decline), and the update
contracts toward a unique equilibrium whenever `dt < 4*H*S / (D * Pload)`.
-/

namespace PowerModel.Swing

/-- System parameters, all strictly positive. `Pload` is the (damped)
electrical load, `D` the damping coefficient, `H`/`S` the inertia constant
and MVA base, `f0` nominal frequency, `dt` the Euler step. -/
structure Params where
  f0 : ℝ
  H : ℝ
  S : ℝ
  D : ℝ
  Pload : ℝ
  dt : ℝ
  hf0 : 0 < f0
  hH : 0 < H
  hS : 0 < S
  hD : 0 < D
  hP : 0 < Pload
  hdt : 0 < dt

/-- Corrected power imbalance (`frequency.ex:178`):
generation minus electrical load, with load damping (`Pload*D*df/f0`)
subtracted and cumulative UFLS shed added back. -/
noncomputable def imbalance (p : Params) (lost gov shed df : ℝ) : ℝ :=
  -lost + gov - p.Pload * p.D * df / p.f0 + shed

/-- The pre-fix imbalance (both correction terms sign-inverted), kept to
state what the bug did. -/
noncomputable def buggyImbalance (p : Params) (lost gov shed df : ℝ) : ℝ :=
  -lost + gov + p.Pload * p.D * df / p.f0 - shed

/-- One explicit-Euler step of the frequency deviation
(`frequency.ex:182-185`). -/
noncomputable def stepDf (p : Params) (lost gov shed df : ℝ) : ℝ :=
  df + p.dt * (p.f0 * imbalance p lost gov shed df / (2 * p.H * p.S))

/-- Changing only the shed changes the next deviation by the (positive)
gain times the shed difference. -/
theorem stepDf_shed_diff (p : Params) (lost gov df a b : ℝ) :
    stepDf p lost gov b df - stepDf p lost gov a df =
      p.dt * p.f0 / (2 * p.H * p.S) * (b - a) := by
  have hH := p.hH.ne'
  have hS := p.hS.ne'
  have hf0 := p.hf0.ne'
  unfold stepDf imbalance
  field_simp
  ring

/-- **Shedding stabilizes**: the next frequency deviation is monotone in the
cumulative shed — shedding more load can never deepen the decline. This is
the property the sign bug violated. -/
theorem stepDf_mono_shed (p : Params) (lost gov df : ℝ) :
    Monotone fun shed => stepDf p lost gov shed df := by
  intro a b hab
  have hdiff := stepDf_shed_diff p lost gov df a b
  have hdt := p.hdt
  have hf0 := p.hf0
  have hH := p.hH
  have hS := p.hS
  have hgain : 0 ≤ p.dt * p.f0 / (2 * p.H * p.S) * (b - a) := by
    have hba : 0 ≤ b - a := by linarith
    positivity
  simp only []
  linarith

/-- **The bug, stated**: under the pre-fix imbalance, shedding load *lowers*
the imbalance — UFLS pushed the frequency further down. -/
theorem buggyImbalance_anti_shed (p : Params) (lost gov df : ℝ) :
    Antitone fun shed => buggyImbalance p lost gov shed df := by
  intro a b hab
  unfold buggyImbalance
  simp only []
  linarith

/-- **Damping opposes the deviation**: the imbalance is antitone in `df`,
so a deeper under-frequency produces a larger restoring imbalance. -/
theorem imbalance_anti_df (p : Params) (lost gov shed : ℝ) :
    Antitone fun df => imbalance p lost gov shed df := by
  intro a b hab
  have hf0 := p.hf0
  have hP := p.hP
  have hD := p.hD
  have h1 : p.Pload * p.D * a ≤ p.Pload * p.D * b := by
    have hPD : 0 ≤ p.Pload * p.D := by positivity
    exact mul_le_mul_of_nonneg_left hab hPD
  have h2 : p.Pload * p.D * a * p.f0⁻¹ ≤ p.Pload * p.D * b * p.f0⁻¹ :=
    mul_le_mul_of_nonneg_right h1 (inv_nonneg.mpr hf0.le)
  unfold imbalance
  simp only [div_eq_mul_inv]
  linarith

/-- The unique equilibrium deviation: where the imbalance vanishes. -/
noncomputable def dfStar (p : Params) (lost gov shed : ℝ) : ℝ :=
  p.f0 * (-lost + gov + shed) / (p.D * p.Pload)

theorem imbalance_at_dfStar (p : Params) (lost gov shed : ℝ) :
    imbalance p lost gov shed (dfStar p lost gov shed) = 0 := by
  have hf0 := p.hf0.ne'
  have hD := p.hD.ne'
  have hP := p.hP.ne'
  unfold imbalance dfStar
  field_simp
  ring

/-- The equilibrium is a fixed point of the Euler step. -/
theorem stepDf_fixed (p : Params) (lost gov shed : ℝ) :
    stepDf p lost gov shed (dfStar p lost gov shed) = dfStar p lost gov shed := by
  unfold stepDf
  rw [imbalance_at_dfStar]
  simp

/-- The effective per-step gain `β = dt * D * Pload / (2 * H * S)`. -/
noncomputable def beta (p : Params) : ℝ := p.dt * p.D * p.Pload / (2 * p.H * p.S)

theorem beta_pos (p : Params) : 0 < beta p := by
  have hdt := p.hdt
  have hD := p.hD
  have hP := p.hP
  have hH := p.hH
  have hS := p.hS
  unfold beta
  positivity

/-- **Exact error recursion**: each step scales the distance to equilibrium
by `(1 - β)`. -/
theorem stepDf_sub_dfStar (p : Params) (lost gov shed df : ℝ) :
    stepDf p lost gov shed df - dfStar p lost gov shed =
      (1 - beta p) * (df - dfStar p lost gov shed) := by
  have h1 : p.f0 ≠ 0 := p.hf0.ne'
  have h2 : p.H ≠ 0 := p.hH.ne'
  have h3 : p.S ≠ 0 := p.hS.ne'
  have h4 : p.D ≠ 0 := p.hD.ne'
  have h5 : p.Pload ≠ 0 := p.hP.ne'
  unfold stepDf imbalance dfStar beta
  field_simp
  ring

/-- **Contraction / Euler stability bound**: when `β < 2` — equivalently
`dt < 4*H*S / (D * Pload)` — every step strictly shrinks the distance to
equilibrium. -/
theorem stepDf_contracts (p : Params) (lost gov shed df : ℝ)
    (hβ : beta p < 2) (hne : df ≠ dfStar p lost gov shed) :
    |stepDf p lost gov shed df - dfStar p lost gov shed| <
      |df - dfStar p lost gov shed| := by
  rw [stepDf_sub_dfStar, abs_mul]
  have hb := beta_pos p
  have habs : |1 - beta p| < 1 := by
    rw [abs_lt]
    constructor <;> nlinarith
  have hz : 0 < |df - dfStar p lost gov shed| :=
    abs_pos.mpr (sub_ne_zero.mpr hne)
  calc |1 - beta p| * |df - dfStar p lost gov shed|
      < 1 * |df - dfStar p lost gov shed| := mul_lt_mul_of_pos_right habs hz
    _ = |df - dfStar p lost gov shed| := one_mul _

/-- The stability condition in engineering terms: `β < 2 ↔ dt < 4HS/(D·P)`. -/
theorem beta_lt_two_iff (p : Params) :
    beta p < 2 ↔ p.dt < 4 * p.H * p.S / (p.D * p.Pload) := by
  have hH := p.hH
  have hS := p.hS
  have hD := p.hD
  have hP := p.hP
  unfold beta
  rw [div_lt_iff₀ (by positivity), lt_div_iff₀ (by positivity)]
  constructor <;> intro h <;> nlinarith

end PowerModel.Swing
