defmodule PowerModel.Solver.LoadModel do
  @moduledoc """
  ZIP load model: voltage-dependent load representation.

  Real and reactive power vary with voltage magnitude:

      P = P0 * (z_pct * V^2 + i_pct * V + p_pct)
      Q = Q0 * (z_pct * V^2 + i_pct * V + p_pct)

  where z_pct + i_pct + p_pct = 1.0.

  - Z (constant impedance): power proportional to V^2
  - I (constant current):   power proportional to V
  - P (constant power):     power independent of V

  At V = 1.0 pu, the ZIP model returns exactly P0 and Q0 regardless of
  coefficients, which is why the DC power flow (V = 1.0 assumption) does
  not need to call this module.
  """

  @type zip_coefficients :: %{z: float(), i: float(), p: float()}

  @doc """
  Default ZIP coefficients by load type.

  - "residential":    z=0.4, i=0.3, p=0.3  (high impedance component: heaters, incandescent lights)
  - "commercial":     z=0.2, i=0.2, p=0.6  (mixed: HVAC, fluorescent, electronics)
  - "industrial":     z=0.1, i=0.1, p=0.8  (motor-dominated, nearly constant power)
  - "constant_power": z=0.0, i=0.0, p=1.0  (legacy default)
  """
  @spec zip_coefficients(String.t() | nil) :: zip_coefficients()
  def zip_coefficients("residential"), do: %{z: 0.4, i: 0.3, p: 0.3}
  def zip_coefficients("commercial"), do: %{z: 0.2, i: 0.2, p: 0.6}
  def zip_coefficients("industrial"), do: %{z: 0.1, i: 0.1, p: 0.8}
  def zip_coefficients(_default), do: %{z: 0.0, i: 0.0, p: 1.0}

  @doc """
  Compute effective load (P, Q) at a given voltage magnitude.

  Given a load map (must have :p_mw and optionally :q_mvar and :load_type)
  and the bus voltage magnitude in per-unit, returns {p_mw, q_mvar} adjusted
  by the ZIP model.

  ## Examples

      iex> load = %{p_mw: 100.0, q_mvar: 30.0, load_type: "residential"}
      iex> PowerModel.Solver.LoadModel.effective_load(load, 1.0)
      {100.0, 30.0}

      iex> load = %{p_mw: 100.0, q_mvar: 30.0, load_type: "residential"}
      iex> {p, _q} = PowerModel.Solver.LoadModel.effective_load(load, 0.95)
      iex> p < 100.0
      true

  """
  @spec effective_load(map(), float()) :: {float(), float()}
  def effective_load(load, vm_pu) do
    p0 = load.p_mw
    q0 = load[:q_mvar] || 0.0
    load_type = load[:load_type]

    %{z: z, i: i, p: p} = zip_coefficients(load_type)
    factor = z * vm_pu * vm_pu + i * vm_pu + p

    {p0 * factor, q0 * factor}
  end

  @doc """
  Compute the derivative of the ZIP scaling factor with respect to voltage.

  d(factor)/dV = 2*z*V + i

  Used by the Newton-Raphson solver to account for voltage-dependent loads
  in the Jacobian (load power changes with voltage).
  """
  @spec dfactor_dv(String.t() | nil, float()) :: float()
  def dfactor_dv(load_type, vm_pu) do
    %{z: z, i: i} = zip_coefficients(load_type)
    2.0 * z * vm_pu + i
  end
end
