defmodule PowerModel.Solver.Frequency do
  @moduledoc """
  Frequency dynamics simulation using the swing equation with governor response.

  Models the system frequency response after a power imbalance event (e.g.,
  generator trip or sudden load change) by integrating:

      d(df)/dt = (P_mech - P_elec) / (2 * H_sys * S_sys)

  Key components:
  - **System inertia (H)**: Weighted average of generator inertia constants.
    Determines the initial rate of frequency decline. Wind/solar contribute
    zero inertia.
  - **Governor droop**: Generators increase mechanical output proportional to
    frequency drop, with a first-order time delay (governor time constant).
  - **Load damping**: Loads naturally reduce ~D% per 1% frequency drop
    (D coefficient, typically ~1.0).
  - **UFLS**: Under-Frequency Load Shedding at staged thresholds with time
    delays to prevent nuisance tripping.
  """

  @f0 60.0

  @default_inertia %{
    "nuclear" => 6.0,
    "coal" => 4.0,
    "gas" => 3.5,
    "hydro" => 3.0,
    "wind" => 0.0,
    "solar" => 0.0,
    "import" => 0.0
  }

  @default_gov_time %{
    "nuclear" => 999.0,
    "coal" => 8.0,
    "gas" => 1.5,
    "hydro" => 3.0,
    "wind" => 999.0,
    "solar" => 999.0
  }

  @droop 0.05

  # NERC BAL-003 governor deadband: +/- 0.036 Hz
  @governor_deadband_hz 0.036

  @load_damping 1.0

  # NERC PRC-006 aligned UFLS stages: {threshold_hz, shed_fraction, delay_s}
  @ufls_stages [
    {59.5, 0.10, 0.3},
    {59.0, 0.10, 0.3},
    {58.5, 0.10, 0.3},
    {58.0, 0.05, 0.3}
  ]

  @doc """
  Simulate the system frequency response after a power imbalance event.

  ## Parameters

  - `generators` - list of generator maps (must have :p_max_mw, :capacity_factor;
    optionally :fuel_type for inertia/governor lookup)
  - `loads` - list of load maps (must have :p_mw)
  - `lost_mw` - MW of generation lost (positive) or load lost (negative)
  - `dt_seconds` - simulation time step (default 0.1s)
  - `duration_seconds` - total simulation duration (default 30.0s)

  ## Returns

  A list of time-step maps:
      %{
        time: float(),          # seconds
        frequency: float(),     # Hz
        gov_response_mw: float(), # total governor MW pickup
        load_shed_mw: float()   # cumulative UFLS shed MW
      }
  """
  @spec simulate(list(map()), list(map()), float(), float(), float()) :: list(map())
  def simulate(generators, loads, lost_mw, dt_seconds \\ 0.1, duration_seconds \\ 30.0) do
    online_gens =
      Enum.filter(generators, fn g ->
        (Map.get(g, :capacity_factor) || 1.0) > 0.0 and (Map.get(g, :p_max_mw) || 0.0) > 0.0
      end)

    {h_sys, s_sys} = system_inertia(online_gens)
    total_load_mw = Enum.sum(Enum.map(loads, & &1.p_mw))

    h_sys = if h_sys < 0.01, do: 0.5, else: h_sys
    s_sys = if s_sys < 0.01, do: total_load_mw, else: s_sys

    gov_units = build_governor_units(online_gens)

    freq = @f0
    df = 0.0
    total_steps = round(duration_seconds / dt_seconds)

    gov_state = Enum.map(gov_units, fn _unit -> 0.0 end)

    ufls_state = Enum.map(@ufls_stages, fn _ -> %{armed_at: nil, tripped: false} end)

    cumulative_shed_mw = 0.0

    initial_record = %{
      time: 0.0,
      frequency: @f0,
      gov_response_mw: 0.0,
      load_shed_mw: 0.0
    }

    {trajectory, _} =
      Enum.reduce(
        1..total_steps,
        {[initial_record],
         %{
           freq: freq,
           df: df,
           gov_state: gov_state,
           ufls_state: ufls_state,
           cumulative_shed_mw: cumulative_shed_mw,
           total_load_mw: total_load_mw
         }},
        fn step, {records, state} ->
          t = step * dt_seconds

          {new_gov_state, total_gov_mw} =
            update_governors(gov_units, state.gov_state, state.df, dt_seconds)

          {new_ufls_state, new_shed_mw} =
            update_ufls(state.ufls_state, state.freq, t, state.total_load_mw)

          cumulative_shed = state.cumulative_shed_mw + new_shed_mw

          p_mech = total_gov_mw
          # Load shedding reduces electrical demand and therefore RELIEVES
          # the generation deficit (positive contribution to imbalance).
          p_elec_adjustment = cumulative_shed

          # Load damping: when frequency drops (df < 0), loads decrease,
          # which REDUCES the deficit (stabilizing effect).
          # P_elec = P_load0 * (1 + D * df/f0), so the reduction in load is:
          # delta_P_load = -P_load0 * D * df/f0 (positive when df < 0)
          load_damping_mw = -state.total_load_mw * @load_damping * state.df / @f0

          p_imbalance = -lost_mw + p_mech + load_damping_mw + p_elec_adjustment

          dfdt = @f0 * p_imbalance / (2.0 * h_sys * s_sys)

          new_df = state.df + dfdt * dt_seconds
          new_freq = @f0 + new_df

          # Below 57 Hz, all conventional generation has tripped on relay 81 —
          # the grid is collapsed and cannot recover.
          new_freq = if new_freq < 57.0, do: 0.0, else: min(new_freq, 65.0)
          new_df = new_freq - @f0

          record = %{
            time: Float.round(t, 4),
            frequency: Float.round(new_freq, 6),
            gov_response_mw: Float.round(total_gov_mw, 2),
            load_shed_mw: Float.round(cumulative_shed, 2)
          }

          {[record | records],
           %{
             freq: new_freq,
             df: new_df,
             gov_state: new_gov_state,
             ufls_state: new_ufls_state,
             cumulative_shed_mw: cumulative_shed,
             total_load_mw: state.total_load_mw
           }}
        end
      )

    Enum.reverse(trajectory)
  end

  @doc """
  Return the frequency nadir (minimum frequency) from a simulation trajectory.
  """
  @spec nadir(list(map())) :: float()
  def nadir(trajectory) do
    trajectory
    |> Enum.min_by(& &1.frequency)
    |> Map.get(:frequency)
  end

  @doc """
  Return the settling frequency (final value) from a simulation trajectory.
  """
  @spec settling_frequency(list(map())) :: float()
  def settling_frequency(trajectory) do
    trajectory
    |> List.last()
    |> Map.get(:frequency)
  end

  @doc """
  Compute the system-wide inertia constant H_sys and total MVA base S_sys.

      H_sys = sum(H_i * S_i) / sum(S_i)

  where H_i is the inertia constant and S_i is the MVA rating (approximated
  as p_max_mw for each generator).
  """
  @spec system_inertia(list(map())) :: {float(), float()}
  def system_inertia(generators) do
    {weighted_sum, total_s} =
      Enum.reduce(generators, {0.0, 0.0}, fn gen, {ws, ts} ->
        h = inertia_for(gen)
        s = gen.p_max_mw
        {ws + h * s, ts + s}
      end)

    if total_s > 0.0 do
      {weighted_sum / total_s, total_s}
    else
      {0.0, 0.0}
    end
  end

  defp inertia_for(gen) do
    case Map.get(gen, :inertia_h) do
      h when is_number(h) and h > 0 ->
        h

      _ ->
        fuel = normalize_fuel(Map.get(gen, :fuel_type))
        Map.get(@default_inertia, fuel, 3.5)
    end
  end

  defp gov_time_for(gen) do
    case Map.get(gen, :gov_time_constant_s) do
      t when is_number(t) and t > 0 ->
        t

      _ ->
        fuel = normalize_fuel(Map.get(gen, :fuel_type))
        Map.get(@default_gov_time, fuel, 2.0)
    end
  end

  defp normalize_fuel(nil), do: "gas"

  defp normalize_fuel(fuel) when is_binary(fuel) do
    f = String.downcase(fuel)

    cond do
      String.contains?(f, "nuclear") or String.contains?(f, "nuc") ->
        "nuclear"

      String.contains?(f, "coal") or String.contains?(f, "bit") or
        String.contains?(f, "col") or String.contains?(f, "sub") or
          String.contains?(f, "lig") ->
        "coal"

      String.contains?(f, "gas") or String.contains?(f, "ng") or String.contains?(f, "ct") ->
        "gas"

      String.contains?(f, "hydro") or String.contains?(f, "wat") or
          String.contains?(f, "wh") ->
        "hydro"

      String.contains?(f, "wind") or String.contains?(f, "wnd") ->
        "wind"

      String.contains?(f, "solar") or String.contains?(f, "sun") or String.contains?(f, "pv") ->
        "solar"

      true ->
        "gas"
    end
  end

  defp build_governor_units(generators) do
    Enum.map(generators, fn gen ->
      p_rated = gen.p_max_mw * (Map.get(gen, :capacity_factor) || 1.0)
      t_gov = gov_time_for(gen)
      h = inertia_for(gen)

      droop =
        case Map.get(gen, :droop_pct) do
          d when is_number(d) and d > 0 -> d / 100.0
          _ -> @droop
        end

      headroom = gen.p_max_mw - p_rated

      %{
        p_rated: p_rated,
        p_max: gen.p_max_mw,
        headroom: max(headroom, 0.0),
        t_gov: t_gov,
        droop: droop,
        has_governor: h > 0.0 and t_gov < 100.0
      }
    end)
  end

  defp update_governors(gov_units, gov_state, df, dt) do
    {new_states, total} =
      Enum.zip(gov_units, gov_state)
      |> Enum.map_reduce(0.0, fn {unit, current_dp}, total_mw ->
        if not unit.has_governor or abs(df) < @governor_deadband_hz do
          {current_dp, total_mw + current_dp}
        else
          dp_target = -(df / @f0) / unit.droop * unit.p_rated

          # Allow negative dp_target for overfrequency (generator reduces output)
          # but don't go below negative of current dispatch
          dp_target = min(dp_target, unit.headroom)
          dp_target = max(-unit.p_rated, dp_target)

          dp_new = current_dp + (dp_target - current_dp) * min(dt / unit.t_gov, 1.0)

          {dp_new, total_mw + dp_new}
        end
      end)

    {new_states, total}
  end

  defp update_ufls(ufls_state, freq, time, total_load_mw) do
    {new_state, total_new_shed} =
      Enum.zip(@ufls_stages, ufls_state)
      |> Enum.map_reduce(0.0, fn {{threshold, shed_frac, delay}, stage_state}, shed_acc ->
        cond do
          stage_state.tripped ->
            {stage_state, shed_acc}

          freq < threshold ->
            case stage_state.armed_at do
              nil ->
                {%{stage_state | armed_at: time}, shed_acc}

              armed_time when time - armed_time >= delay ->
                shed_mw = total_load_mw * shed_frac
                {%{stage_state | tripped: true}, shed_acc + shed_mw}

              _armed_time ->
                {stage_state, shed_acc}
            end

          true ->
            {%{stage_state | armed_at: nil}, shed_acc}
        end
      end)

    {new_state, total_new_shed}
  end
end
