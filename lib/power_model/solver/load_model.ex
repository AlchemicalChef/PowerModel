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

  ## Distribution reactive compensation

  A second, separate term sits on the reactive side: the capacitors a
  distribution system carries behind its transmission bus.

      Q_net(V) = Q0 * zip_factor(V)  -  k * Q0 * V^2

  This is NOT expressible as a ZIP coefficient. A capacitor is a constant-
  IMPEDANCE device while the load it compensates may be constant power, so the
  two have different voltage exponents and need different terms; folding them
  into one triple would make the compensation vanish or the load fade with it.

  It is modelled here rather than as a bus shunt (`buses.bs_mvar`) because
  compensation must be SHED WITH ITS LOAD. Shedding mutates load rows and never
  touches `bs_mvar`, so a bus shunt would keep injecting into a collapsing
  island after its feeders were dropped — manufacturing exactly the
  over-voltage that light-load fixed capacitance already causes. Keying off the
  live `q_mvar` means proportional shedding scales the compensation with it for
  free, and a fully lost bus (`q_mvar` zeroed) carries none.

  `bs_mvar` remains transmission-level plant: the EHV line-end reactors and
  substation capacitor banks that `Ingestion.ParameterEstimator` synthesizes.

  ## What the active-front-end form does NOT claim

  "Constant power factor at any voltage" holds only inside the converter's
  OPERATING RANGE. Real PFC front ends do not degrade gracefully below it —
  they ride through to roughly 0.85-0.90 pu for a few cycles and then drop out,
  the UPS transferring to battery or the load disconnecting (the ITIC/CBEMA
  envelope, the same territory as the PRC-024 and IEEE 1547 ride-through
  curves).

  So the honest shape has three regions and this model has two: constant power
  factor down to the ride-through limit, and then ZERO, with the campus taking
  its P away as well as its Q. Below about 0.85 pu this term is therefore
  OPTIMISTIC — it keeps a 900 MW campus connected and drawing where the real
  one would already have transferred.

  To be precise about WHICH mechanism is missing: what is absent is
  EQUIPMENT-side dropout, the load disconnecting itself on its own envelope.
  Utility-side shedding does exist and does fire — `Failure.LoadShedding` runs
  timer-integrated per-bus UVLS at 0.92/0.89/0.86 pu for 8/5/3 s, and BTM
  inverters carry IEEE 1547 voltage trips. Equipment dropout is a different
  mechanism on top: faster than a UVLS timer, on per-load-type thresholds
  rather than a utility program, and self-initiated. For a datacenter fleet it
  is also large — 19.7 GW leaving at 0.85 pu is a stabilising step no UVLS
  stage would produce.

  Adding it needs a ride-through envelope per load type and belongs with the
  protection/ride-through model, not bolted onto a compensation term. Recorded
  here so the boundary of what this term claims is visible rather than inferred.

  It applies to EVERY load type, datacenters included. Their `q_mvar` is
  written by `Grid.map_datacenters_to_grid/0` at the same 0.3287 ratio the
  estimator uses, so it carries the same 0.95 fiction rather than a measured
  net — and a hyperscale campus is if anything compensated HARDER than a mixed
  distribution feeder, since modern UPS and power-supply front ends are
  specified at better than 0.99 input power factor and large-load tariffs
  require correction. Compensating them to the same conservative target is
  therefore an understatement, not an overreach. Datacenter loads also run flat
  (`Demand.scale_loads/3` exempts them from the hourly curve), so their
  compensation is flat too, which is correct for on-site correction sized to a
  constant load.
  """

  @type zip_coefficients :: %{z: float(), i: float(), p: float()}

  # Power factor the load estimator synthesizes at: q_mvar = 0.329 * p_mw.
  @synthesized_pf 0.95

  # Loads whose correction is an ACTIVE front end rather than passive shunt
  # capacitors. See `compensation_mvar/5` for why the distinction changes the
  # voltage dependence and not just the amount.
  @active_pfc_load_type "datacenter"

  # Power factor the transmission-to-distribution interface is compensated TO.
  #
  # WHY THIS IS NOT 0.95: a 0.95 interface is a modelling fiction. Distribution
  # systems carry their own capacitors and utilities operate the interface near
  # unity, because reactive power imported over the bulk network is pure loss.
  # Capacitor application practice places banks to correct the substation power
  # factor toward unity (IEEE Std 1036, "IEEE Guide for the Application of
  # Shunt Power Capacitors"), and 0.95 is conventionally the PENALTY THRESHOLD
  # in utility power-factor tariffs rather than an operating target — systems
  # run above it, not at it.
  #
  # 0.98 is a deliberately conservative choice inside the 0.95-to-unity band,
  # not a figure lifted from a standard, and it is stated that way on purpose.
  # MEASURED: the AC loadability ceiling saturates before unity anyway (ERCOT
  # gains nothing from 0.99 to 1.00, Western nothing from 0.98 to 0.99), so
  # there is no accuracy argument for pushing it higher and the conservative
  # end costs nothing.
  @interface_pf 0.98

  # Fraction of a load's reactive demand met by its own distribution
  # capacitors. Derived, not tuned:
  #
  #     k = 1 - tan(acos(pf_target)) / tan(acos(pf_synthesized))
  #
  # so that at V = 1.0 the net interface power factor is exactly @interface_pf.
  # 0.98 -> 0.382, 0.99 -> 0.567, 1.00 -> 1.000.
  @compensation_fraction 1.0 -
                           :math.tan(:math.acos(@interface_pf)) /
                             :math.tan(:math.acos(@synthesized_pf))

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

  The reactive value is NET of distribution compensation, so at V = 1.0 it is
  `Q0 * (1 - k)` rather than `Q0`. See the moduledoc.

  ## Examples

      iex> load = %{p_mw: 100.0, q_mvar: 30.0, load_type: "residential"}
      iex> {p, _q} = PowerModel.Solver.LoadModel.effective_load(load, 1.0)
      iex> p
      100.0

      iex> load = %{p_mw: 100.0, q_mvar: 30.0, load_type: "residential"}
      iex> {p, _q} = PowerModel.Solver.LoadModel.effective_load(load, 0.95)
      iex> p < 100.0
      true

  """
  @spec effective_load(map(), float(), float()) :: {float(), float()}
  def effective_load(load, vm_pu, k \\ @compensation_fraction) do
    # Map.get, not Access ([]): loads arrive both as plain maps (tests) and
    # as %Load{} structs (production), and structs don't implement Access.
    p0 = load.p_mw
    q0 = Map.get(load, :q_mvar) || 0.0
    load_type = Map.get(load, :load_type)

    %{z: z, i: i, p: p} = zip_coefficients(load_type)
    factor = z * vm_pu * vm_pu + i * vm_pu + p

    {p0 * factor, q0 * factor - compensation_mvar(q0, vm_pu, k, load_type, factor)}
  end

  @doc """
  Reactive output of a load's own correction plant at `vm_pu`, in MVAr.

  Capacitive, so the caller SUBTRACTS it from the reactive demand. The voltage
  dependence is a property of the DEVICE, and the two kinds behave oppositely
  in a sag:

    * **passive shunt capacitors** — the banks on a distribution feeder.
      Output is `k * Q0 * V^2`, so it FADES as the bus sags, faster than the
      constant-power load it was installed to offset. Net reactive draw
      therefore RISES into a voltage depression, which is the self-reinforcing
      half of voltage collapse. Modelling this by simply raising the load's
      power factor would delete that mechanism.

    * **active front ends** — the power-factor-corrected PSU and UPS rectifiers
      a datacenter campus is built from. These are controlled converters that
      hold near-unity input power factor across their whole operating voltage
      range, so their correction does NOT fade; it tracks the load itself
      (`k * Q0 * zip_factor(V)`) and the campus presents a constant power
      factor at any voltage.

  Giving a datacenter the passive V^2 treatment would have it draw ~12% more
  reactive power at 0.9 pu than its converters actually do, overstating the
  collapse risk at exactly the buses that now carry 19.7 GW at 230-500 kV.
  """
  @spec compensation_mvar(float(), float(), float(), String.t() | nil, float()) :: float()
  def compensation_mvar(q0, vm_pu, k \\ @compensation_fraction, load_type \\ nil, factor \\ nil)

  def compensation_mvar(q0, vm_pu, k, load_type, factor)
      when is_number(q0) and is_number(vm_pu) do
    k * q0 * compensation_voltage_term(load_type, vm_pu, factor)
  end

  def compensation_mvar(_q0, _vm_pu, _k, _load_type, _factor), do: 0.0

  # V^2 for passive plant; the load's own ZIP factor for an active front end.
  defp compensation_voltage_term(@active_pfc_load_type, vm_pu, nil),
    do: zip_factor(@active_pfc_load_type, vm_pu)

  defp compensation_voltage_term(@active_pfc_load_type, _vm_pu, factor), do: factor
  defp compensation_voltage_term(_load_type, vm_pu, _factor), do: vm_pu * vm_pu

  @doc "ZIP scaling factor for a load type at `vm_pu`."
  @spec zip_factor(String.t() | nil, float()) :: float()
  def zip_factor(load_type, vm_pu) do
    %{z: z, i: i, p: p} = zip_coefficients(load_type)
    z * vm_pu * vm_pu + i * vm_pu + p
  end

  @doc "Fraction of load reactive demand met by distribution compensation."
  @spec compensation_fraction() :: float()
  def compensation_fraction, do: @compensation_fraction

  @doc "Power factor the interface is compensated to at V = 1.0 pu."
  @spec interface_pf() :: float()
  def interface_pf, do: @interface_pf

  @doc """
  Compute the derivative of the ZIP scaling factor with respect to voltage.

  d(factor)/dV = 2*z*V + i

  Used by the Newton-Raphson solver to account for voltage-dependent loads
  in the Jacobian (load power changes with voltage). This is the REAL-power
  sensitivity; the reactive side has its own term and must use
  `dq_load_dv/2`.
  """
  @spec dfactor_dv(String.t() | nil, float()) :: float()
  def dfactor_dv(load_type, vm_pu) do
    %{z: z, i: i} = zip_coefficients(load_type)
    2.0 * z * vm_pu + i
  end

  @doc """
  d(P_load)/dV in MW per per-unit volt.
  """
  @spec dp_load_dv(map(), float()) :: float()
  def dp_load_dv(load, vm_pu) do
    load.p_mw * dfactor_dv(Map.get(load, :load_type), vm_pu)
  end

  @doc """
  d(Q_net_load)/dV in MVAr per per-unit volt.

  Two terms with different signs, which is why the reactive side cannot reuse
  `dfactor_dv/2` alone:

      d/dV [ Q0*factor(V) - k*Q0*V^2 ]  =  Q0*factor'(V) - 2*k*Q0*V

  The compensation term is nonzero even for a constant-power load, where
  `factor'(V) == 0` — so a caller that skips this whenever `dfactor_dv/2`
  returns zero would silently drop the compensation on every load in the
  network. Every load in this database is `constant_power`.
  """
  @spec dq_load_dv(map(), float(), float()) :: float()
  def dq_load_dv(load, vm_pu, k \\ @compensation_fraction) do
    q0 = Map.get(load, :q_mvar) || 0.0
    load_type = Map.get(load, :load_type)
    df = dfactor_dv(load_type, vm_pu)

    # The compensation's derivative follows its DEVICE, exactly as its value
    # does: 2*k*Q0*V for passive banks, and k*Q0*factor'(V) for an active front
    # end, which for a constant-power campus is zero — its power factor does
    # not move with voltage at all.
    dcomp =
      case load_type do
        @active_pfc_load_type -> k * q0 * df
        _ -> 2.0 * k * q0 * vm_pu
      end

    q0 * df - dcomp
  end
end
