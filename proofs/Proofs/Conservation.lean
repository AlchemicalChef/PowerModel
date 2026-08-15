import Mathlib

/-!
# Cascade load-conservation invariant

Mirrors `lib/power_model/failure/cascade.ex` (`balance/1`): at every point in
a cascade, `served + shed + blackout = original`. The cascade mutates load
through exactly two accounting channels — UFLS/force shedding
(`load_shedding.ex`, `trigger_ufls_for_deficit`) and island blackout
(`solve_islands_timed`'s dead-island arm) — and both move MW between buckets
without creating or destroying it. Generator redispatch / headroom raises
never touch the load buckets.

We model the accounting state abstractly and prove the invariant is preserved
by each transition and hence along every trace.
-/

namespace PowerModel.Conservation

/-- The three load-accounting buckets of `Cascade.balance/1`. -/
structure Acct where
  served : ℝ
  shed : ℝ
  blackout : ℝ

/-- The conserved quantity. -/
def total (a : Acct) : ℝ := a.served + a.shed + a.blackout

/-- All buckets non-negative (loads cannot go negative). -/
def Wf (a : Acct) : Prop := 0 ≤ a.served ∧ 0 ≤ a.shed ∧ 0 ≤ a.blackout

/-- A single cascade accounting transition. `δ` is bounded by the currently
served load: the code sheds fractions of live loads and blacks out live
islands only (already-zeroed loads are never re-counted —
`cascade.ex` island arm filters `p_mw > 0`). -/
inductive Step : Acct → Acct → Prop
  | shed (a : Acct) (δ : ℝ) (h0 : 0 ≤ δ) (hle : δ ≤ a.served) :
      Step a ⟨a.served - δ, a.shed + δ, a.blackout⟩
  | blackout (a : Acct) (δ : ℝ) (h0 : 0 ≤ δ) (hle : δ ≤ a.served) :
      Step a ⟨a.served - δ, a.shed, a.blackout + δ⟩
  | redispatch (a : Acct) :
      Step a a

/-- Each transition preserves the total. -/
theorem Step.total_eq {a b : Acct} (h : Step a b) : total b = total a := by
  cases h <;> simp [total] <;> ring

/-- Each transition preserves well-formedness. -/
theorem Step.wf {a b : Acct} (h : Step a b) (hw : Wf a) : Wf b := by
  obtain ⟨hs, hd, hb⟩ := hw
  cases h with
  | shed δ h0 hle => exact ⟨by linarith, by linarith, hb⟩
  | blackout δ h0 hle => exact ⟨by linarith, hd, by linarith⟩
  | redispatch => exact ⟨hs, hd, hb⟩

/-- Reflexive-transitive closure: a cascade trace. -/
inductive Trace : Acct → Acct → Prop
  | refl (a : Acct) : Trace a a
  | tail {a b c : Acct} : Trace a b → Step b c → Trace a c

/-- **Conservation along every cascade trace**: however many shed, blackout,
and redispatch steps occur, `served + shed + blackout` never changes. This is
the invariant `cascade_test.exs` checks numerically; here it holds for all
real-valued traces. -/
theorem Trace.total_eq {a b : Acct} (h : Trace a b) : total b = total a := by
  induction h with
  | refl => rfl
  | tail _ hstep ih => rw [hstep.total_eq, ih]

theorem Trace.wf {a b : Acct} (h : Trace a b) (hw : Wf a) : Wf b := by
  induction h with
  | refl => exact hw
  | tail _ hstep ih => exact hstep.wf ih

/-- Proportional shedding (`LoadShedding.apply_proportional_shedding`):
shedding the fraction `φ ∈ [0,1]` of the served load is a valid `Step.shed`
with `δ = φ * served`. -/
theorem proportional_shed (a : Acct) (φ : ℝ) (h0 : 0 ≤ φ) (h1 : φ ≤ 1)
    (hs : 0 ≤ a.served) :
    Step a ⟨a.served - φ * a.served, a.shed + φ * a.served, a.blackout⟩ := by
  refine Step.shed a (φ * a.served) (by positivity) ?_
  nlinarith

/-- Deficit-capped shedding never sheds more than the deficit requires:
with `δ = min (φ * served) deficit`, the shed amount is bounded by the
deficit (mirrors the `min(shed_fraction, deficit/total_load)` cap). -/
theorem capped_shed_le_deficit (served φ deficit : ℝ) (hd : 0 ≤ deficit) :
    min (φ * served) deficit ≤ deficit :=
  min_le_right _ _

end PowerModel.Conservation
