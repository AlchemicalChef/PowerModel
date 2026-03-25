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
  - "constant_power": z=0.0, i=0.0, p=1.0  (backward-compatible pure constant power)
  - nil / other:      z=0.3, i=0.3, p=0.4  (typical system-wide average mix)
  """
  @spec zip_coefficients(String.t() | nil) :: zip_coefficients()
  def zip_coefficients("residential"), do: %{z: 0.4, i: 0.3, p: 0.3}
  def zip_coefficients("commercial"), do: %{z: 0.2, i: 0.2, p: 0.6}
  def zip_coefficients("industrial"), do: %{z: 0.1, i: 0.1, p: 0.8}
  def zip_coefficients("constant_power"), do: %{z: 0.0, i: 0.0, p: 1.0}
  def zip_coefficients(_default), do: %{z: 0.3, i: 0.3, p: 0.4}

  @doc """
  Default ZIP Q (reactive) coefficients by load type.

  Reactive power has a higher impedance component than active power
  because reactive loads (magnetizing branches, capacitor banks) are
  inherently voltage-dependent.

  - "residential":    z=0.9, i=0.05, p=0.05  (largely impedance: heating, lighting)
  - "commercial":     z=0.5, i=0.2,  p=0.3   (mixed: HVAC, lighting, electronics)
  - "industrial":     z=0.6, i=0.1,  p=0.3   (motors: magnetizing current is Z-type)
  - nil / other:      z=0.5, i=0.2,  p=0.3   (typical system-wide average)
  """
  @spec zip_q_coefficients(String.t() | nil) :: zip_coefficients()
  def zip_q_coefficients("residential"), do: %{z: 0.9, i: 0.05, p: 0.05}
  def zip_q_coefficients("commercial"), do: %{z: 0.5, i: 0.2, p: 0.3}
  def zip_q_coefficients("industrial"), do: %{z: 0.6, i: 0.1, p: 0.3}
  def zip_q_coefficients("constant_power"), do: %{z: 0.0, i: 0.0, p: 1.0}
  def zip_q_coefficients(_default), do: %{z: 0.5, i: 0.2, p: 0.3}

  @doc """
  Compute effective load (P, Q) at a given voltage magnitude.

  Given a load map (must have :p_mw and optionally :q_mvar and :load_type)
  and the bus voltage magnitude in per-unit, returns {p_mw, q_mvar} adjusted
  by the ZIP model. P and Q use separate ZIP coefficients because reactive
  power loads have different voltage sensitivity than active power loads.

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
    q0 = Map.get(load, :q_mvar) || 0.0
    load_type = Map.get(load, :load_type)

    %{z: zp, i: ip, p: pp} = zip_coefficients(load_type)
    %{z: zq, i: iq, p: pq} = zip_q_coefficients(load_type)

    p_factor = zp * vm_pu * vm_pu + ip * vm_pu + pp
    q_factor = zq * vm_pu * vm_pu + iq * vm_pu + pq

    {p0 * p_factor, q0 * q_factor}
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
