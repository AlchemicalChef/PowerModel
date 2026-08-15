import Mathlib

/-!
# ZIP load model

Mirrors `lib/power_model/solver/load_model.ex`: the voltage-dependence factor

    factor(V) = z*V^2 + i*V + p     with z + i + p = 1

and its derivative `dfactor_dv(V) = 2*z*V + i` (wired into the
Newton-Raphson J2/J4 Jacobian diagonals).

Theorems: the factor is exactly 1 at nominal voltage (so DC solves need no
ZIP correction), and `dfactor_dv` is genuinely the derivative of the factor —
the property that makes the Jacobian terms correct.
-/

namespace PowerModel.Zip

/-- ZIP scaling factor at voltage `V` (`load_model.ex:65`). -/
def factor (z i p V : ℝ) : ℝ := z * V ^ 2 + i * V + p

/-- The implemented derivative (`load_model.ex:81`). -/
def dfactor (z i V : ℝ) : ℝ := 2 * z * V + i

/-- **Nominal identity**: at `V = 1`, every ZIP mix with `z + i + p = 1`
returns exactly the nominal load (`load_model.ex` moduledoc claim). -/
theorem factor_at_nominal {z i p : ℝ} (h : z + i + p = 1) :
    factor z i p 1 = 1 := by
  unfold factor
  ring_nf
  linarith

/-- **The Jacobian term is the true derivative**: `dfactor` is the
derivative of `factor` at every voltage. -/
theorem dfactor_is_deriv (z i p V : ℝ) :
    HasDerivAt (factor z i p) (dfactor z i V) V := by
  have h : HasDerivAt (fun v : ℝ => z * v ^ 2 + i * v + p)
      (z * (2 * V ^ 1) + i * 1) V := by
    have hp : HasDerivAt (fun v : ℝ => v ^ 2) (↑(2 : ℕ) * V ^ (2 - 1)) V :=
      hasDerivAt_pow 2 V
    have hz : HasDerivAt (fun v : ℝ => z * v ^ 2) (z * (2 * V ^ 1)) V := by
      simpa using hp.const_mul z
    have hi : HasDerivAt (fun v : ℝ => i * v) (i * 1) V := by
      simpa using (hasDerivAt_id V).const_mul i
    simpa using (hz.add hi).add_const p
  have hd : z * (2 * V ^ 1) + i * 1 = dfactor z i V := by
    unfold dfactor
    ring
  rw [← hd]
  exact h

/-- Monotone in voltage for physically sensible mixes (`z, i ≥ 0`,
`V ≥ 0`): load rises with voltage. -/
theorem factor_mono {z i p : ℝ} (hz : 0 ≤ z) (hi : 0 ≤ i) :
    MonotoneOn (factor z i p) (Set.Ici (0 : ℝ)) := by
  intro a ha b hb hab
  simp only [Set.mem_Ici] at ha hb
  unfold factor
  have hsq : a ^ 2 ≤ b ^ 2 := by nlinarith
  nlinarith [mul_le_mul_of_nonneg_left hsq hz, mul_le_mul_of_nonneg_left hab hi]

end PowerModel.Zip
