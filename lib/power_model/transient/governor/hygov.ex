defmodule PowerModel.Transient.Governor.HYGOV do
  @moduledoc """
  Simplified hydraulic turbine governor model (HYGOV).

  Models a hydro governor with water column inertia effects. The model
  captures the characteristic initial inverse response of hydro units:
  when gate opens, water pressure momentarily drops before building up,
  causing a brief *decrease* in power output before the expected increase.

  Two state variables:
    - `x_gate` — gate position (controlled by governor)
    - `x_water` — water column power output (turbine)

  Differential equations:

      dx_gate/dt  = (p_ref - (1/R) * (omega - 1) - x_gate) / TG
      dx_water/dt = (1.0 - x_water / max(x_gate, 0.01)) / TW

      p_mech = x_water

  Where:
    - R  = droop (pu, typically 0.04-0.05)
    - TG = gate servo time constant (seconds, typically 0.2-0.5)
    - TW = water starting time (seconds, typically 1.0-3.0)

  The water starting time TW governs the duration of the initial
  inverse response. Larger TW = longer inverse response.

  Reference: IEEE Std 1207-2011, "Guidelines for the Evaluation of
  Hydroelectric Power Station Turbine Governing and Dam Safety."
  """

  defstruct [
    :x_gate,   # gate position state (pu)
    :x_water,  # water column power state (pu)
    :dx_gate,  # gate position rate of change (pu/s) for water column effect
    :r,        # droop (pu)
    :tg,       # gate servo time constant (seconds)
    :tw,       # water starting time (seconds)
    :p_ref,    # power reference setpoint (pu)
    :p_max,    # maximum mechanical power (pu)
    :p_min     # minimum mechanical power (pu)
  ]

  @doc """
  Initialize hydro governor state from generator parameters.

  Expects a map with:
    - `:droop_pct` — droop in percent (default 5.0)
    - `:gov_time_constant_s` — gate servo time constant (default 0.3)
    - `:tw_s` — water starting time (default 1.5)
    - `:p_mech_pu` — initial mechanical power in per-unit

  At steady state: x_gate = x_water = p_mech, omega = 1.0.
  """
  def init(gen) do
    droop_pct = Map.get(gen, :droop_pct) || 5.0
    r = droop_pct / 100.0
    tg = Map.get(gen, :gov_time_constant_s) || 0.3
    tw = Map.get(gen, :tw_s) || 1.5
    p_mech_pu = Map.get(gen, :p_mech_pu, 0.0)

    %__MODULE__{
      x_gate: p_mech_pu,
      x_water: p_mech_pu,
      dx_gate: 0.0,
      r: max(r, 0.001),
      tg: max(tg, 0.01),
      tw: max(tw, 0.1),
      p_ref: p_mech_pu,
      p_max: Map.get(gen, :p_max_pu, 1.5),
      p_min: Map.get(gen, :p_min_pu, 0.0)
    }
  end

  @doc """
  Compute state derivatives for both gate and water column.

  Returns `{dx_gate, dx_water}`.
  """
  def derivatives(%__MODULE__{} = gov, omega) do
    speed_error = (1.0 / gov.r) * (omega - 1.0)
    dx_gate = (gov.p_ref - speed_error - gov.x_gate) / gov.tg

    # Water column dynamics: water follows gate with lag and inverse response
    gate_clamp = max(gov.x_gate, 0.01)
    dx_water = (1.0 - gov.x_water / gate_clamp) / gov.tw

    {dx_gate, dx_water}
  end

  @doc """
  Return current mechanical power output from the hydro governor.

  Output is clamped between p_min and p_max.
  """
  def p_mech(%__MODULE__{} = gov) do
    # Include non-minimum-phase water column effect:
    # P = gate_position - Tw * d(gate)/dt
    # When gate opens (dx_gate > 0), the -Tw*dx_gate term causes an initial
    # power dip before the gate position increase takes over.
    (gov.x_gate - gov.tw * gov.dx_gate)
    |> max(gov.p_min)
    |> min(gov.p_max)
  end

  @doc """
  Advance hydro governor by one Euler step.
  """
  def step_euler(%__MODULE__{} = gov, omega, dt) do
    {dx_gate, dx_water} = derivatives(gov, omega)

    %{gov |
      x_gate: gov.x_gate + dx_gate * dt,
      x_water: gov.x_water + dx_water * dt,
      dx_gate: dx_gate
    }
  end

  @doc """
  Advance hydro governor by one trapezoidal corrector step.

  Takes current state, Euler-predicted state, current and predicted omega.
  """
  def step_trapezoidal(%__MODULE__{} = gov_n, %__MODULE__{} = gov_pred, omega_n, omega_pred, dt) do
    {dx_gate_n, dx_water_n} = derivatives(gov_n, omega_n)
    {dx_gate_pred, dx_water_pred} = derivatives(gov_pred, omega_pred)

    avg_dx_gate = (dx_gate_n + dx_gate_pred) / 2.0

    %{gov_n |
      x_gate: gov_n.x_gate + dt * avg_dx_gate,
      x_water: gov_n.x_water + dt / 2.0 * (dx_water_n + dx_water_pred),
      dx_gate: avg_dx_gate
    }
  end
end
