defmodule PowerModel.Controls.OLTC do
  @moduledoc """
  On-Load Tap Changer (OLTC) controller.

  Discrete voltage regulator that adjusts transformer tap ratio in steps.
  When the secondary bus voltage deviates from the target by more than the
  deadband for a configured delay period, the tap is stepped up or down by
  one step (typically 1.25%).

  After the first tap change, subsequent changes use a shorter delay
  (`step_delay_s`) to allow rapid correction of large deviations while
  avoiding hunting under normal conditions.

  The tap ratio is clamped to `[tap_min, tap_max]` (typically 0.9 to 1.1),
  representing +/-10% regulation range in 16 steps.
  """

  defstruct [
    :tap,            # current tap ratio (pu)
    :timer,          # accumulated time outside deadband (seconds)
    :enabled,        # whether the OLTC is active
    :v_target_pu,    # voltage setpoint (pu)
    :v_deadband_pu,  # voltage error threshold (pu, +/-)
    :tap_step_pct,   # tap step size (percent)
    :tap_min,        # minimum tap ratio
    :tap_max,        # maximum tap ratio
    :delay_s,        # delay before first tap change (seconds)
    :step_delay_s,   # delay between successive tap changes (seconds)
    :first_step_done # whether the first tap change has occurred
  ]

  @default_params %{
    v_target_pu: 1.0,
    v_deadband_pu: 0.02,
    tap_step_pct: 1.25,
    tap_min: 0.9,
    tap_max: 1.1,
    delay_s: 30.0,
    step_delay_s: 10.0
  }

  @doc """
  Initialize OLTC state from a transformer map.

  The initial tap ratio is taken from the transformer's `tap_ratio` field
  (default 1.0). Parameters can be overridden via the transformer map
  or default to standard values.
  """
  def init(transformer) do
    tap = Map.get(transformer, :tap_ratio) || 1.0

    %__MODULE__{
      tap: tap,
      timer: 0.0,
      enabled: Map.get(transformer, :oltc_enabled, true),
      v_target_pu: Map.get(transformer, :v_target_pu) || @default_params.v_target_pu,
      v_deadband_pu: Map.get(transformer, :v_deadband_pu) || @default_params.v_deadband_pu,
      tap_step_pct: Map.get(transformer, :tap_step_pct) || @default_params.tap_step_pct,
      tap_min: Map.get(transformer, :tap_min) || @default_params.tap_min,
      tap_max: Map.get(transformer, :tap_max) || @default_params.tap_max,
      delay_s: Map.get(transformer, :delay_s) || @default_params.delay_s,
      step_delay_s: Map.get(transformer, :step_delay_s) || @default_params.step_delay_s,
      first_step_done: false
    }
  end

  @doc """
  Advance the OLTC by `dt_s` seconds given the current secondary voltage.

  Returns `{new_state, action}` where action is either:
    * `:no_change` — voltage within deadband or delay not yet elapsed
    * `{:tap_change, new_tap}` — tap ratio has been stepped

  The timer accumulates when voltage is outside the deadband and resets
  when voltage returns within the deadband. The first tap change uses
  `delay_s`; subsequent changes use the shorter `step_delay_s`.
  """
  def step(%__MODULE__{enabled: false} = state, _v_secondary_pu, _dt_s) do
    {state, :no_change}
  end

  def step(%__MODULE__{} = state, v_secondary_pu, dt_s) do
    error = v_secondary_pu - state.v_target_pu

    if abs(error) > state.v_deadband_pu do
      new_timer = state.timer + dt_s
      required_delay = if state.first_step_done, do: state.step_delay_s, else: state.delay_s

      if new_timer >= required_delay do
        # Determine step direction: if voltage is low, increase tap; if high, decrease tap
        step_pu = state.tap_step_pct / 100.0
        direction = if error < 0, do: 1, else: -1
        new_tap = state.tap + direction * step_pu

        # Clamp to limits
        new_tap = new_tap |> max(state.tap_min) |> min(state.tap_max)

        if new_tap == state.tap do
          # At limit, no further action possible
          {%{state | timer: 0.0}, :no_change}
        else
          new_state = %{state |
            tap: new_tap,
            timer: 0.0,
            first_step_done: true
          }
          {new_state, {:tap_change, new_tap}}
        end
      else
        {%{state | timer: new_timer}, :no_change}
      end
    else
      # Within deadband — reset timer
      {%{state | timer: 0.0}, :no_change}
    end
  end
end
