defmodule PowerModel.Controls.HVDCController do
  @moduledoc """
  High-Voltage DC (HVDC) link controller.

  HVDC converters can modulate active power transfer in response to
  system conditions, providing valuable inter-area support. Three
  operating modes are supported:

  ## Constant Power Mode
  Maintains a fixed scheduled power transfer regardless of AC system
  frequency. This is the normal operating mode.

  ## Frequency Support Mode
  Modulates power order based on frequency deviation:

      P_order = P_schedule + K_freq * (f_actual - 60.0)

  This provides fast frequency response by increasing/decreasing power
  transfer to help the receiving/sending system. The frequency gain
  `K_freq` is typically 100-500 MW/Hz.

  ## Emergency Runback Mode
  Rapidly reduces power transfer to zero when triggered, with a
  configurable ramp rate. Used during severe contingencies to prevent
  commutation failure or voltage collapse at converter terminals.

  All modes enforce ramp rate limits and clamp output to [0, P_max].
  """

  defstruct [
    # current power order (MW)
    :p_order_mw,
    # scheduled power transfer (MW)
    :p_schedule_mw,
    # maximum power rating (MW)
    :p_max_mw,
    # frequency droop gain (MW/Hz)
    :k_freq,
    # ramp rate limit (MW/s)
    :ramp_rate_mw_s,
    # :constant_power | :frequency_support | :emergency_runback
    :mode,
    # target MW for runback (usually 0)
    :runback_target
  ]

  @doc """
  Initialize HVDC controller from an HvdcLine schema map.

  Expects fields from the `HVDCLine` schema:
    * `:rated_mw` — maximum power rating
    * `:p_schedule_mw` — scheduled power transfer
    * `:control_mode` — `"constant_power"` or `"frequency_support"`

  ## Options
    * `:k_freq` — frequency gain in MW/Hz (default: 5% of rated MW)
    * `:ramp_rate_mw_s` — ramp rate in MW/s (default: 10% of rated per second)
  """
  def init(hvdc_line, opts \\ []) do
    rated = Map.get(hvdc_line, :rated_mw, 500.0)
    p_schedule = Map.get(hvdc_line, :p_schedule_mw) || rated * 0.8

    mode =
      case Map.get(hvdc_line, :control_mode, "constant_power") do
        "frequency_support" -> :frequency_support
        "emergency_runback" -> :emergency_runback
        _ -> :constant_power
      end

    k_freq = Keyword.get(opts, :k_freq, rated * 0.05)
    ramp_rate = Keyword.get(opts, :ramp_rate_mw_s, rated * 0.1)

    %__MODULE__{
      p_order_mw: p_schedule,
      p_schedule_mw: p_schedule,
      p_max_mw: rated,
      k_freq: k_freq,
      ramp_rate_mw_s: ramp_rate,
      mode: mode,
      runback_target: 0.0
    }
  end

  @doc """
  Advance the HVDC controller by one timestep.

  Computes the new power order based on the operating mode and
  applies ramp rate limiting.

  Returns `{new_state, p_inject_mw}` where `p_inject_mw` is the
  active power to inject at the receiving bus (positive = power
  transfer in scheduled direction).
  """
  def step(%__MODULE__{mode: :constant_power} = state, _frequency_hz, dt_s) do
    target = state.p_schedule_mw
    new_p = ramp_limited(state.p_order_mw, target, state.ramp_rate_mw_s, dt_s)
    new_p = new_p |> max(0.0) |> min(state.p_max_mw)

    {%{state | p_order_mw: new_p}, new_p}
  end

  def step(%__MODULE__{mode: :frequency_support} = state, frequency_hz, dt_s) do
    freq_deviation = frequency_hz - 60.0
    target = state.p_schedule_mw + state.k_freq * freq_deviation
    target = target |> max(0.0) |> min(state.p_max_mw)

    new_p = ramp_limited(state.p_order_mw, target, state.ramp_rate_mw_s, dt_s)
    new_p = new_p |> max(0.0) |> min(state.p_max_mw)

    {%{state | p_order_mw: new_p}, new_p}
  end

  def step(%__MODULE__{mode: :emergency_runback} = state, _frequency_hz, dt_s) do
    target = state.runback_target
    new_p = ramp_limited(state.p_order_mw, target, state.ramp_rate_mw_s, dt_s)
    new_p = max(new_p, 0.0)

    {%{state | p_order_mw: new_p}, new_p}
  end

  @doc """
  Switch the controller to a new operating mode.

  ## Modes
    * `:constant_power` — hold scheduled power
    * `:frequency_support` — modulate based on frequency
    * `:emergency_runback` — ramp down to zero
  """
  def set_mode(%__MODULE__{} = state, mode)
      when mode in [:constant_power, :frequency_support, :emergency_runback] do
    %{state | mode: mode}
  end

  # Ramp-limited step toward target
  defp ramp_limited(current, target, ramp_rate, dt_s) do
    max_change = ramp_rate * dt_s
    delta = target - current

    cond do
      delta > max_change -> current + max_change
      delta < -max_change -> current - max_change
      true -> target
    end
  end
end
