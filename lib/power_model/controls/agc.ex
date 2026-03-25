defmodule PowerModel.Controls.AGC do
  @moduledoc """
  Automatic Generation Control (AGC).

  Operates on a 4-second cycle, adjusting generator P_ref setpoints to
  correct frequency deviation and inter-area flow errors. The control
  signal is the Area Control Error (ACE):

      ACE = (P_actual - P_scheduled) + 10 * B * (f_actual - 60.0)

  where B is the area frequency bias in MW/0.1 Hz, typically set to 1%
  of area peak load.

  AGC distributes corrections proportional to each generator's
  `agc_participation_factor` and respects per-generator ramp rate limits.
  """

  defstruct [
    :ace,         # current Area Control Error (MW)
    :integral,    # accumulated ACE integral (MW*s)
    :generators,  # list of participating generator maps
    :bias_mw,     # area frequency bias B (MW/0.1 Hz)
    :ki,          # integral gain (1/s)
    :p_scheduled  # scheduled net interchange (MW)
  ]

  @doc """
  Initialize AGC state with participating generators.

  Generators with `agc_participation_factor > 0` are included.
  Their participation factors are normalized to sum to 1.0.

  ## Options
    * `:bias_mw` — frequency bias in MW/0.1 Hz (default: 1% of total capacity)
    * `:ki` — integral gain (default: 0.05)
    * `:p_scheduled` — scheduled net interchange MW (default: total dispatch)
  """
  def init(generators, opts \\ []) do
    participating =
      generators
      |> Enum.filter(fn g ->
        factor = Map.get(g, :agc_participation_factor, 0.0) || 0.0
        factor > 0.0
      end)
      |> normalize_participation()

    total_capacity = Enum.sum_by(participating, fn g -> Map.get(g, :p_max_mw, 0.0) end)
    default_bias = total_capacity * 0.01

    bias_mw = Keyword.get(opts, :bias_mw, default_bias)
    ki = Keyword.get(opts, :ki, 0.05)

    default_scheduled =
      Enum.sum_by(participating, fn g ->
        Map.get(g, :dispatch_mw, Map.get(g, :p_max_mw, 0.0))
      end)

    p_scheduled = Keyword.get(opts, :p_scheduled, default_scheduled)

    %__MODULE__{
      ace: 0.0,
      integral: 0.0,
      generators: participating,
      bias_mw: bias_mw,
      ki: ki,
      p_scheduled: p_scheduled
    }
  end

  @doc """
  Execute one AGC cycle.

  Computes ACE from the current frequency and generation/load balance,
  then distributes corrective setpoint adjustments to participating
  generators proportional to their participation factors, respecting
  ramp rate limits.

  Returns `{new_state, gen_adjustments}` where `gen_adjustments` is
  a map of `gen_id => delta_p_mw`.
  """
  def step(%__MODULE__{} = state, frequency_hz, total_gen_mw, total_load_mw, dt_s) do
    # ACE = (P_actual - P_scheduled) + 10 * B * (f_actual - 60.0)
    # P_actual - P_scheduled represents the net interchange error.
    # We treat (total_gen - total_load) as the actual net interchange.
    p_actual = total_gen_mw - total_load_mw
    freq_error = frequency_hz - 60.0

    ace = (p_actual - state.p_scheduled) + 10.0 * state.bias_mw * freq_error

    # PI controller: correction = -Ki * integral(ACE)
    new_integral = state.integral + ace * dt_s
    correction_mw = -state.ki * new_integral

    # Distribute correction proportional to participation factors
    gen_adjustments =
      state.generators
      |> Enum.map(fn gen ->
        factor = Map.get(gen, :agc_participation_factor, 0.0)
        gen_id = Map.get(gen, :id)
        raw_delta = correction_mw * factor

        # Apply ramp rate limit: ramp_rate is MW/min, convert to MW over dt_s
        ramp_rate = Map.get(gen, :ramp_rate_mw_per_min) || :infinity
        max_delta = ramp_limit(ramp_rate, dt_s)

        clamped_delta = clamp_symmetric(raw_delta, max_delta)

        # Respect generator P limits
        current_dispatch = Map.get(gen, :dispatch_mw, Map.get(gen, :p_max_mw, 0.0))
        p_min = Map.get(gen, :p_min_mw, 0.0) || 0.0
        p_max = Map.get(gen, :p_max_mw, 0.0)

        final_delta = clamp_to_limits(clamped_delta, current_dispatch, p_min, p_max)

        {gen_id, final_delta}
      end)
      |> Map.new()

    new_state = %{state | ace: ace, integral: new_integral}
    {new_state, gen_adjustments}
  end

  # Normalize participation factors so they sum to 1.0
  defp normalize_participation(generators) do
    total =
      Enum.sum_by(generators, fn g ->
        Map.get(g, :agc_participation_factor, 0.0) || 0.0
      end)

    if total > 0.0 do
      Enum.map(generators, fn g ->
        factor = (Map.get(g, :agc_participation_factor, 0.0) || 0.0) / total
        Map.put(g, :agc_participation_factor, factor)
      end)
    else
      generators
    end
  end

  defp ramp_limit(:infinity, _dt_s), do: :infinity
  defp ramp_limit(rate_mw_per_min, dt_s), do: rate_mw_per_min * dt_s / 60.0

  defp clamp_symmetric(value, :infinity), do: value
  defp clamp_symmetric(value, limit), do: value |> max(-limit) |> min(limit)

  defp clamp_to_limits(delta, current, p_min, p_max) do
    new_dispatch = current + delta

    cond do
      new_dispatch > p_max -> p_max - current
      new_dispatch < p_min -> p_min - current
      true -> delta
    end
  end
end
