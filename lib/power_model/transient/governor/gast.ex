defmodule PowerModel.Transient.Governor.GAST do
  @moduledoc """
  GAST gas turbine governor model.

  A single-time-constant governor similar to TGOV1 but with a faster
  response (typical of gas turbines) and a temperature/load limit that
  prevents the turbine from exceeding its exhaust temperature rating.

  One state variable `x_gov` tracks the fuel valve position.

  Differential equation:

      dx_gov/dt = (p_ref - (1/R) * (omega - 1) - x_gov) / T1

      p_mech = min(x_gov, load_limit)

  Where:
    - R  = droop (pu, typically 0.04-0.05)
    - T1 = fuel system time constant (seconds, typically 0.1-0.4)
    - load_limit = exhaust temperature limit (pu, typically 1.0-1.1)

  Gas turbines respond faster than steam (smaller T1) but are typically
  temperature-limited, preventing full droop response at high loads.

  Reference: IEEE Committee Report, "Dynamic Models for Steam and
  Hydro Turbines in Power System Studies," 1973.
  """

  defstruct [
    :x_gov,        # governor state (fuel valve position, pu)
    :r,            # droop (pu)
    :t1,           # fuel system time constant (seconds)
    :p_ref,        # power reference setpoint (pu)
    :p_max,        # maximum mechanical power (pu)
    :p_min,        # minimum mechanical power (pu)
    :load_limit    # exhaust temperature limit (pu)
  ]

  @doc """
  Initialize gas turbine governor state from generator parameters.

  Expects a map with:
    - `:droop_pct` — droop in percent (default 5.0)
    - `:gov_time_constant_s` — fuel system time constant (default 0.2)
    - `:load_limit_pu` — temperature limit (default 1.1)
    - `:p_mech_pu` — initial mechanical power in per-unit

  At steady state: x_gov = p_mech, omega = 1.0.
  """
  def init(gen) do
    droop_pct = Map.get(gen, :droop_pct) || 5.0
    r = droop_pct / 100.0
    t1 = Map.get(gen, :gov_time_constant_s) || 0.2
    p_mech_pu = Map.get(gen, :p_mech_pu, 0.0)

    %__MODULE__{
      x_gov: p_mech_pu,
      r: max(r, 0.001),
      t1: max(t1, 0.01),
      p_ref: p_mech_pu,
      p_max: Map.get(gen, :p_max_pu, 1.5),
      p_min: Map.get(gen, :p_min_pu, 0.0),
      load_limit: Map.get(gen, :load_limit_pu, 1.1)
    }
  end

  @doc """
  Compute state derivative for the gas turbine governor.

  Returns `dx_gov/dt`.
  """
  def derivative(%__MODULE__{} = gov, omega) do
    speed_error = (1.0 / gov.r) * (omega - 1.0)
    (gov.p_ref - speed_error - gov.x_gov) / gov.t1
  end

  @doc """
  Return current mechanical power output from the gas turbine governor.

  Output is clamped by both the load limit (exhaust temperature) and
  the mechanical min/max limits.
  """
  def p_mech(%__MODULE__{} = gov) do
    gov.x_gov
    |> min(gov.load_limit)
    |> max(gov.p_min)
    |> min(gov.p_max)
  end

  @doc """
  Advance gas turbine governor by one Euler step.
  """
  def step_euler(%__MODULE__{} = gov, omega, dt) do
    dx = derivative(gov, omega)
    %{gov | x_gov: gov.x_gov + dx * dt}
  end

  @doc """
  Advance gas turbine governor by one trapezoidal corrector step.
  """
  def step_trapezoidal(%__MODULE__{} = gov_n, %__MODULE__{} = gov_pred, omega_n, omega_pred, dt) do
    dx_n = derivative(gov_n, omega_n)
    dx_pred = derivative(gov_pred, omega_pred)
    new_x = gov_n.x_gov + dt / 2.0 * (dx_n + dx_pred)

    %{gov_n | x_gov: new_x}
  end
end
