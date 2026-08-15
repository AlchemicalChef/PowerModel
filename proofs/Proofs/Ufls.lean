import Mathlib

/-!
# UFLS schedule properties

Mirrors the canonical UFLS program in `lib/power_model/solver/frequency.ex`
(`@ufls_stages`) and its static cumulative view
`PowerModel.Failure.Protection.ufls_schedule/1`: stages at 59.3 / 58.9 /
58.5 / 58.1 Hz, each shedding a further 7.5% of load.

Theorems: the cumulative schedule is antitone in frequency (lower frequency
never sheds less), is capped at 30%, and vanishes above the first stage.
-/

namespace PowerModel.Ufls

/-- Cumulative shed fraction as a function of frequency
(`protection.ex` `ufls_schedule/1`): every stage whose threshold the
frequency fell below contributes its incremental fraction. -/
noncomputable def schedule (f : ℝ) : ℝ :=
  (if f < 59.3 then 0.075 else 0) + (if f < 58.9 then 0.075 else 0) +
    (if f < 58.5 then 0.075 else 0) + (if f < 58.1 then 0.075 else 0)

/-- A single stage's contribution is antitone in frequency. -/
private lemma stage_antitone (c k : ℝ) (hk : 0 ≤ k) :
    Antitone fun f : ℝ => if f < c then k else 0 := by
  intro a b hab
  show (if b < c then k else 0) ≤ if a < c then k else 0
  by_cases hb : b < c
  · rw [if_pos hb, if_pos (lt_of_le_of_lt hab hb)]
  · rw [if_neg hb]
    split_ifs with ha
    · exact hk
    · exact le_rfl

/-- **Antitone**: as frequency falls, the scheduled shed fraction can only
grow. -/
theorem schedule_antitone : Antitone schedule := by
  have h1 := stage_antitone 59.3 0.075 (by norm_num)
  have h2 := stage_antitone 58.9 0.075 (by norm_num)
  have h3 := stage_antitone 58.5 0.075 (by norm_num)
  have h4 := stage_antitone 58.1 0.075 (by norm_num)
  unfold schedule
  exact Antitone.add (Antitone.add (Antitone.add h1 h2) h3) h4

/-- **Non-negative** at every frequency. -/
theorem schedule_nonneg (f : ℝ) : 0 ≤ schedule f := by
  unfold schedule
  split_ifs <;> norm_num

/-- **Capped at 30%**: the program can never schedule more than the sum of
all four stages. -/
theorem schedule_le (f : ℝ) : schedule f ≤ 0.30 := by
  unfold schedule
  split_ifs <;> norm_num

/-- **No shedding above the first stage** (59.3 Hz). -/
theorem schedule_eq_zero (f : ℝ) (h : 59.3 ≤ f) : schedule f = 0 := by
  unfold schedule
  have h1 : ¬ f < 59.3 := not_lt.mpr h
  have h2 : ¬ f < 58.9 := by intro hc; linarith
  have h3 : ¬ f < 58.5 := by intro hc; linarith
  have h4 : ¬ f < 58.1 := by intro hc; linarith
  simp [h1, h2, h3, h4]

/-- **All stages in** below the last threshold: exactly 30%. -/
theorem schedule_at_bottom (f : ℝ) (h : f < 58.1) : schedule f = 0.30 := by
  unfold schedule
  have h1 : f < 59.3 := by linarith
  have h2 : f < 58.9 := by linarith
  have h3 : f < 58.5 := by linarith
  simp [h1, h2, h3, h]
  norm_num

end PowerModel.Ufls
