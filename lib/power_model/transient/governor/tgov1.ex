defmodule PowerModel.Transient.Governor.TGOV1 do
  @moduledoc """
  TGOV1 steam turbine governor model.

  A single-time-constant governor-turbine model representing the simplest
  governor response for steam units. One state variable `x_gov` tracks
  the turbine valve position, which directly gives mechanical power output.

  Differential equation:

      dx_gov/dt = (p_ref - (1/R) * (omega - 1) - x_gov) / T1

      p_mech = x_gov

  Where:
    - R   = droop setting (pu, typically 0.04-0.05)
    - T1  = governor-turbine time constant (seconds)
    - p_ref = power reference setpoint (pu)

  Reference: IEEE Standard 421.5, Turbine-Governor Models.
  """

  defstruct [
    :x_gov,    # governor state (valve position, pu)
    :r,        # droop (pu)
    :t1,       # time constant (seconds)
    :p_ref,    # power reference setpoint (pu)
    :p_max,    # maximum mechanical power (pu)
    :p_min     # minimum mechanical power (pu)
  ]

  @doc """
  Initialize governor state from generator parameters.

  Expects a map with:
    - `:droop_pct` — droop in percent (default 5.0)
    - `:gov_time_constant_s` — time constant in seconds (default 0.5)
    - `:p_mech_pu` — initial mechanical power in per-unit

  The initial state is set so that the governor is in steady state
  (dx_gov/dt = 0) at the given operating point with omega = 1.0.
  """
  def init(gen) do
    droop_pct = Map.get(gen, :droop_pct) || 5.0
    r = droop_pct / 100.0
    t1 = Map.get(gen, :gov_time_constant_s) || 0.5
    p_mech_pu = Map.get(gen, :p_mech_pu, 0.0)

    # At steady state with omega = 1.0:
    #   dx_gov/dt = 0  =>  x_gov = p_ref - (1/R)*(omega-1)
    #   With omega = 1.0:  x_gov = p_ref = p_mech
    %__MODULE__{
      x_gov: p_mech_pu,
      r: max(r, 0.001),
      t1: max(t1, 0.01),
      p_ref: p_mech_pu,
      p_max: Map.get(gen, :p_max_pu, 1.5),
      p_min: Map.get(gen, :p_min_pu, 0.0)
    }
  end

  @doc """
  Compute state derivative for the governor.

  Returns `dx_gov/dt` given the current state, rotor speed, and reference.
  """
  def derivative(%__MODULE__{} = gov, omega) do
    speed_error = (1.0 / gov.r) * (omega - 1.0)
    (gov.p_ref - speed_error - gov.x_gov) / gov.t1
  end

  @doc """
  Return current mechanical power output from the governor.

  Output is clamped between p_min and p_max.
  """
  def p_mech(%__MODULE__{} = gov) do
    gov.x_gov
    |> max(gov.p_min)
    |> min(gov.p_max)
  end

  @doc """
  Advance governor state by one timestep using trapezoidal integration.

  Takes the current state, the predicted (Euler) state, current omega,
  predicted omega, and timestep. Returns the corrected governor state.
  """
  def step_trapezoidal(%__MODULE__{} = gov_n, %__MODULE__{} = gov_pred, omega_n, omega_pred, dt) do
    dx_n = derivative(gov_n, omega_n)
    dx_pred = derivative(gov_pred, omega_pred)
    new_x = gov_n.x_gov + dt / 2.0 * (dx_n + dx_pred)

    %{gov_n | x_gov: new_x}
  end

  @doc """
  Advance governor state by one Euler step.
  """
  def step_euler(%__MODULE__{} = gov, omega, dt) do
    dx = derivative(gov, omega)
    %{gov | x_gov: gov.x_gov + dx * dt}
  end
end
