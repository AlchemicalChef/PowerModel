defmodule PowerModel.Controls.SVCController do
  @moduledoc """
  Static VAR Compensator (SVC) controller.

  Continuous reactive power injection for voltage regulation. The SVC
  adjusts its reactive output based on the deviation of bus voltage
  from the setpoint, divided by the slope (droop):

      Q_inject = (V_set - V_bus) / slope
      Q_inject = clamp(Q_inject, Q_min, Q_max)

  A first-order lag with time constant `tau_s` (default ~50 ms, i.e.
  2-3 power system cycles) models the thyristor firing delay.

  When the bus voltage is within the deadband of the setpoint, the SVC
  holds its current output. Outside the deadband, it adjusts toward the
  steady-state target with the configured time constant.
  """

  defstruct [
    # current reactive injection (MVAr, positive = capacitive)
    :q_inject,
    # voltage setpoint (pu)
    :v_set,
    # droop slope (pu voltage / pu reactive on device base)
    :slope,
    # minimum reactive output (MVAr, typically negative = inductive)
    :q_min,
    # maximum reactive output (MVAr, typically positive = capacitive)
    :q_max,
    # response time constant (seconds)
    :tau_s
  ]

  @doc """
  Initialize SVC controller from an SVC schema map.

  Expects fields:
    * `:q_max_mvar` — maximum reactive output (MVAr)
    * `:q_min_mvar` — minimum reactive output (MVAr)
    * `:v_set_pu` — voltage setpoint (pu), default 1.0
    * `:slope_pct` — slope in percent, default 3.0

  ## Options
    * `:tau_s` — response time constant (default 0.05 s)
  """
  def init(svc, opts \\ []) do
    q_max = Map.get(svc, :q_max_mvar, 100.0)
    q_min = Map.get(svc, :q_min_mvar, -100.0)
    v_set = Map.get(svc, :v_set_pu) || 1.0
    slope_pct = Map.get(svc, :slope_pct) || 3.0
    tau_s = Keyword.get(opts, :tau_s, 0.05)

    # Convert slope from percent to per-unit
    # slope_pct = 3% means 3% voltage change for full reactive range
    slope = slope_pct / 100.0

    %__MODULE__{
      q_inject: 0.0,
      v_set: v_set,
      slope: slope,
      q_min: q_min,
      q_max: q_max,
      tau_s: max(tau_s, 0.001)
    }
  end

  @doc """
  Compute SVC reactive injection for the current bus voltage.

  Uses a first-order lag to model thyristor response dynamics:

      dQ/dt = (Q_target - Q_current) / tau

  Returns `{new_state, q_inject_mvar}`.
  """
  def step(%__MODULE__{} = state, v_bus_pu, dt_s \\ 0.01) do
    # Steady-state target
    # slope is in pu: represents the pu voltage change for full reactive range.
    # Q_target = v_error / slope * Q_range (MVAr)
    v_error = state.v_set - v_bus_pu
    q_range = state.q_max - state.q_min
    q_target = v_error / state.slope * q_range

    # Clamp to reactive limits
    q_target = q_target |> max(state.q_min) |> min(state.q_max)

    # First-order lag response
    alpha = 1.0 - :math.exp(-dt_s / state.tau_s)
    new_q = state.q_inject + alpha * (q_target - state.q_inject)

    # Final clamping
    new_q = new_q |> max(state.q_min) |> min(state.q_max)

    new_state = %{state | q_inject: new_q}
    {new_state, new_q}
  end
end
