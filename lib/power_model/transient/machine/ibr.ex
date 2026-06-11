defmodule PowerModel.Transient.Machine.IBR do
  @moduledoc """
  Inverter-Based Resource (IBR) model for transient stability.

  Supports two operating modes:

  ## Grid-Following (GFL)
  The default mode for solar PV and Type-4 wind turbines. Injects constant
  active power (at dispatch setpoint) and constant reactive power (based on
  voltage setpoint). No inertial response — the inverter tracks the grid
  frequency via a PLL.

  Under low terminal voltage, the inverter reduces current injection per
  IEEE 1547-2018 LVRT requirements:
    - V < 0.15 pu for > 0.16 s → trip
    - V < 0.45 pu for > 1.0 s  → trip
    - V < 0.70 pu → reduce output proportionally

  ## Grid-Forming (GFM)
  Virtual Synchronous Machine (VSM) mode. Emulates a synchronous generator
  with synthetic inertia and virtual impedance. Uses the same swing equation
  as the classical machine model but with:
    - Synthetic inertia H (typically 2-5 s)
    - Virtual impedance X_v instead of X'd
    - Faster droop response

  Grid-forming inverters are being deployed for weak-grid applications and
  are expected to become mandatory for large-scale IBR interconnections.
  """

  defstruct [
    # :grid_following or :grid_forming
    :mode,
    # active power setpoint (pu)
    :p_set_pu,
    # reactive power setpoint (pu)
    :q_set_pu,
    # current active power injection (pu)
    :p_inject_pu,
    # current reactive power injection (pu)
    :q_inject_pu,
    # last terminal voltage magnitude (pu)
    :v_terminal,
    # whether the IBR has tripped offline
    :tripped,
    # accumulated time below LVRT thresholds (seconds)
    :low_v_timer,
    # which LVRT tier is active (:none, :tier1, :tier2)
    :low_v_threshold,

    # Grid-forming parameters (VSM mode)
    # virtual rotor angle (radians)
    :delta,
    # virtual rotor speed (pu)
    :omega,
    # synthetic inertia constant (seconds)
    :h_synthetic,
    # virtual damping coefficient
    :d_virtual,
    # virtual impedance (pu)
    :x_virtual_pu,
    # power reference for droop (pu)
    :p_ref,
    # frequency droop (pu)
    :droop
  ]

  @omega_base 2.0 * :math.pi() * 60.0

  # LVRT thresholds per IEEE 1547-2018 Category III
  # voltage threshold for fast trip
  @lvrt_tier1_v 0.15
  # time limit for tier 1 (seconds)
  @lvrt_tier1_t 0.16
  # voltage threshold for slow trip
  @lvrt_tier2_v 0.45
  # time limit for tier 2 (seconds)
  @lvrt_tier2_t 1.0
  # voltage below which output is reduced
  @lvrt_reduce_v 0.70

  # Fuel types that indicate IBR technology
  # Note: WDS (wood/wood waste) is a conventional steam plant, NOT an IBR
  @ibr_fuel_types ["SUN", "WND", "MWH", "BAT", "AB"]

  @doc """
  Initialize IBR state from generator parameters.

  Determines operating mode based on fuel type and parameters:
    - Solar (SUN), Wind (WND), Battery (MWH, BAT) → grid-following by default
    - If `:ibr_mode` is explicitly set to `:grid_forming`, uses VSM mode

  Expects a map with:
    - `:fuel_type` — determines default mode
    - `:p_mech_pu` — initial active power injection (pu)
    - `:q_set_pu` — reactive power setpoint (pu, default 0.0)
    - `:ibr_mode` — `:grid_following` or `:grid_forming` (optional)
    - `:h_synthetic` — synthetic inertia for GFM mode (default 3.0 s)
    - `:x_virtual_pu` — virtual impedance for GFM mode (default 0.15 pu)
  """
  def init(gen) do
    p_set = Map.get(gen, :p_mech_pu, 0.0)
    q_set = Map.get(gen, :q_set_pu, 0.0)

    mode =
      case Map.get(gen, :ibr_mode) do
        :grid_forming ->
          :grid_forming

        :grid_following ->
          :grid_following

        nil ->
          # Default: IBR fuel types get grid-following
          fuel = Map.get(gen, :fuel_type, "")
          if fuel in @ibr_fuel_types, do: :grid_following, else: :grid_following
      end

    base = %__MODULE__{
      mode: mode,
      p_set_pu: p_set,
      q_set_pu: q_set,
      p_inject_pu: p_set,
      q_inject_pu: q_set,
      v_terminal: 1.0,
      tripped: false,
      low_v_timer: 0.0,
      low_v_threshold: :none,
      delta: 0.0,
      omega: 1.0,
      h_synthetic: Map.get(gen, :h_synthetic, 3.0),
      d_virtual: Map.get(gen, :d_virtual, 2.0),
      x_virtual_pu: Map.get(gen, :x_virtual_pu, 0.15),
      p_ref: p_set,
      droop: Map.get(gen, :droop, 0.05)
    }

    case mode do
      :grid_forming ->
        # Initialize virtual angle from steady-state power flow
        # At steady state: P = E*V*sin(delta)/X_v => delta = asin(P*X_v/(E*V))
        sin_arg = p_set * base.x_virtual_pu
        sin_arg = max(-1.0, min(1.0, sin_arg))
        %{base | delta: :math.asin(sin_arg)}

      :grid_following ->
        base
    end
  end

  @doc """
  Advance IBR state by one timestep.

  Returns `{new_state, p_inject, q_inject}`.

  For grid-following: checks LVRT, adjusts power output.
  For grid-forming: integrates swing equation with synthetic inertia.
  """
  def step(%__MODULE__{tripped: true} = ibr, _v_terminal, _dt) do
    {ibr, 0.0, 0.0}
  end

  def step(%__MODULE__{mode: :grid_following} = ibr, v_terminal, dt) do
    ibr = %{ibr | v_terminal: v_terminal}

    # Check LVRT
    ibr = check_lvrt(ibr, v_terminal, dt)

    if ibr.tripped do
      {ibr, 0.0, 0.0}
    else
      # Scale output based on terminal voltage
      {p_inject, q_inject} = compute_gfl_injection(ibr, v_terminal)
      ibr = %{ibr | p_inject_pu: p_inject, q_inject_pu: q_inject}
      {ibr, p_inject, q_inject}
    end
  end

  def step(%__MODULE__{mode: :grid_forming} = ibr, v_terminal, dt) do
    ibr = %{ibr | v_terminal: v_terminal}

    # Check LVRT (grid-forming also has voltage ride-through limits)
    ibr = check_lvrt(ibr, v_terminal, dt)

    if ibr.tripped do
      {ibr, 0.0, 0.0}
    else
      # Virtual synchronous machine swing equation
      # P_elec approximation: P = V * sin(delta) / X_v (simplified)
      p_elec = v_terminal * :math.sin(ibr.delta) / max(ibr.x_virtual_pu, 0.001)

      # Droop: P_ref adjusted by frequency deviation
      p_ref_droop = ibr.p_ref - 1.0 / max(ibr.droop, 0.001) * (ibr.omega - 1.0)

      # Swing equation: d_omega/dt = (P_ref - P_elec - D*(omega-1)) / (2*H)
      d_omega =
        (p_ref_droop - p_elec - ibr.d_virtual * (ibr.omega - 1.0)) / (2.0 * ibr.h_synthetic)

      d_delta = @omega_base * (ibr.omega - 1.0)

      # Euler integration (sufficient for IBR with synthetic inertia)
      new_omega = ibr.omega + d_omega * dt
      new_delta = ibr.delta + d_delta * dt

      # Current injection
      p_inject = v_terminal * :math.sin(new_delta) / max(ibr.x_virtual_pu, 0.001)
      q_inject = ibr.q_set_pu

      ibr = %{
        ibr
        | omega: new_omega,
          delta: new_delta,
          p_inject_pu: p_inject,
          q_inject_pu: q_inject
      }

      {ibr, p_inject, q_inject}
    end
  end

  @doc """
  Check whether the IBR has tripped offline.
  """
  def tripped?(%__MODULE__{tripped: tripped}), do: tripped

  @doc """
  Determine if a generator should use the IBR model based on fuel type.
  """
  def ibr_candidate?(gen) do
    fuel = Map.get(gen, :fuel_type, "")
    fuel in @ibr_fuel_types
  end

  # --- Private ---

  defp check_lvrt(%__MODULE__{} = ibr, v_terminal, dt) do
    cond do
      v_terminal < @lvrt_tier1_v ->
        # Severe voltage depression — fast trip timer
        new_timer =
          if ibr.low_v_threshold == :tier1 do
            ibr.low_v_timer + dt
          else
            dt
          end

        if new_timer >= @lvrt_tier1_t do
          %{ibr | tripped: true, low_v_timer: new_timer, low_v_threshold: :tier1}
        else
          %{ibr | low_v_timer: new_timer, low_v_threshold: :tier1}
        end

      v_terminal < @lvrt_tier2_v ->
        # Moderate voltage depression — slow trip timer
        new_timer =
          if ibr.low_v_threshold in [:tier1, :tier2] do
            ibr.low_v_timer + dt
          else
            dt
          end

        if new_timer >= @lvrt_tier2_t do
          %{ibr | tripped: true, low_v_timer: new_timer, low_v_threshold: :tier2}
        else
          %{ibr | low_v_timer: new_timer, low_v_threshold: :tier2}
        end

      true ->
        # Voltage recovered — reset timer
        %{ibr | low_v_timer: 0.0, low_v_threshold: :none}
    end
  end

  defp compute_gfl_injection(%__MODULE__{} = ibr, v_terminal) do
    if v_terminal < @lvrt_reduce_v do
      # Proportional current reduction below 0.7 pu
      # I_max = I_rated, so P = V * I ≈ V/V_nom * P_set
      scale = v_terminal / @lvrt_reduce_v
      {ibr.p_set_pu * scale, ibr.q_set_pu * scale}
    else
      {ibr.p_set_pu, ibr.q_set_pu}
    end
  end
end
