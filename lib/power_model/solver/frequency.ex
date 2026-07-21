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

  # Nominal frequency (Hz)
  @f0 60.0

  # Default inertia constants by fuel type (seconds)
  @default_inertia %{
    "nuclear" => 6.0,
    "coal" => 4.0,
    "gas" => 3.5,
    "hydro" => 3.0,
    "wind" => 0.0,
    "solar" => 0.0,
    "import" => 0.0
  }

  # Governor time constants by prime mover / fuel type (seconds)
  @default_gov_time %{
    # steam turbine, slow
    "nuclear" => 5.0,
    # steam turbine, slow
    "coal" => 5.0,
    # gas turbine, fast
    "gas" => 0.5,
    # hydro governor
    "hydro" => 2.0,
    # no governor response
    "wind" => 999.0,
    # no governor response
    "solar" => 999.0,
    # tie-line imports have no local governor response
    "import" => 999.0
  }

  # Droop coefficient (5% means 5% frequency deviation -> 100% power change)
  @droop 0.05

  # Load damping coefficient (D = 1.0 means 1% load reduction per 1% freq drop)
  @load_damping 1.0

  # UFLS stages: {threshold_hz, shed_fraction, arming_delay_s}
  # NERC PRC-006-style regional program: staged shedding beginning at 59.3 Hz,
  # each stage shedding a further 7.5% of load — ~30% cumulative by 58.1 Hz.
  @ufls_stages [
    {59.3, 0.075, 0.1},
    {58.9, 0.075, 0.1},
    {58.5, 0.075, 0.1},
    {58.1, 0.075, 0.1}
  ]

  @doc """
  The canonical UFLS program: `{threshold_hz, shed_fraction, arming_delay_s}`
  per stage, shed fractions incremental. Single source of truth — the static
  nadir-based schedule in `PowerModel.Failure.Protection.ufls_schedule/1`
  derives its cumulative fractions from this table.
  """
  def ufls_stages, do: @ufls_stages

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
    # Compute system parameters
    online_gens =
      Enum.filter(generators, fn g ->
        (Map.get(g, :capacity_factor) || 1.0) > 0.0 and (Map.get(g, :p_max_mw) || 0.0) > 0.0
      end)

    {h_sys, s_sys} = system_inertia(online_gens)
    total_load_mw = Enum.sum(Enum.map(loads, & &1.p_mw))

    # If there's no inertia (all renewables), use a small default to avoid division by zero
    h_sys = if h_sys < 0.01, do: 0.5, else: h_sys
    s_sys = if s_sys < 0.01, do: max(total_load_mw, 1.0), else: s_sys

    # Build governor model for each generator
    gov_units = build_governor_units(online_gens)

    # Initial conditions
    freq = @f0
    # frequency deviation (Hz)
    df = 0.0
    total_steps = round(duration_seconds / dt_seconds)

    # Governor state: each unit tracks its current mechanical power adjustment
    gov_state = Enum.map(gov_units, fn _unit -> 0.0 end)

    # UFLS state: track which stages have been armed and tripped
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

          # 1. Governor response: each unit ramps up based on droop and time constant
          {new_gov_state, total_gov_mw} =
            update_governors(gov_units, state.gov_state, state.df, dt_seconds)

          # 2. UFLS check
          {new_ufls_state, new_shed_mw} =
            update_ufls(state.ufls_state, state.freq, t, state.total_load_mw)

          cumulative_shed = state.cumulative_shed_mw + new_shed_mw

          # 3. Compute power balance
          # P_mech = (total generation - lost_mw) + governor pickup
          # P_elec = total load + frequency damping - UFLS shedding
          # governor response to compensate for lost generation
          p_mech = total_gov_mw

          # Load damping: load decreases below nominal frequency and increases above it
          # P_load_actual = P_load * (1 + D * df/f0)
          load_damping_mw = state.total_load_mw * @load_damping * state.df / @f0

          # Net imbalance: positive means generation > load (frequency rises)
          # lost_mw is subtracted from generation
          # gov pickup adds to generation
          # load damping is part of electrical load; UFLS shedding subtracts from it
          p_imbalance = -lost_mw + p_mech - load_damping_mw + cumulative_shed

          # 4. Swing equation: df/dt = f0 * P_imbalance / (2 * H_sys * S_sys)
          # Using MW and seconds, H is in seconds, S_sys in MW
          dfdt = @f0 * p_imbalance / (2.0 * h_sys * s_sys)

          # 5. Euler integration
          new_df = state.df + dfdt * dt_seconds
          new_freq = @f0 + new_df

          # Clamp frequency to physical bounds
          new_freq = max(new_freq, 55.0) |> min(65.0)
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
        # Inertia rides on the machine MVA base (≈ nameplate MW), not the
        # currently dispatched output — a half-loaded machine spins with its
        # full rotor.
        s = nameplate_mw(gen)
        {ws + h * s, ts + s}
      end)

    if total_s > 0.0 do
      {weighted_sum / total_s, total_s}
    else
      {0.0, 0.0}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp inertia_for(gen) do
    fuel = normalize_fuel(Map.get(gen, :fuel_type))
    Map.get(@default_inertia, fuel, 3.5)
  end

  defp gov_time_for(gen) do
    fuel = normalize_fuel(Map.get(gen, :fuel_type))
    Map.get(@default_gov_time, fuel, 2.0)
  end

  defp normalize_fuel(nil), do: "gas"

  defp normalize_fuel(fuel) when is_binary(fuel) do
    f = String.downcase(fuel)

    cond do
      String.contains?(f, "nuclear") or String.contains?(f, "nuc") ->
        "nuclear"

      String.contains?(f, "coal") or String.contains?(f, "bit") ->
        "coal"

      String.contains?(f, "import") ->
        "import"

      String.contains?(f, "gas") or String.contains?(f, "ng") or String.contains?(f, "ct") ->
        "gas"

      String.contains?(f, "hydro") or String.contains?(f, "wat") ->
        "hydro"

      String.contains?(f, "wind") or String.contains?(f, "wnd") ->
        "wind"

      String.contains?(f, "solar") or String.contains?(f, "sun") or String.contains?(f, "pv") ->
        "solar"

      true ->
        "gas"
    end
  end

  # Real dispatch and nameplate capability. The cascade reshapes generators
  # for the DC solver (p_max_mw = dispatched MW, capacity_factor = 1.0), which
  # read naively would zero the governor headroom and shrink the inertia base
  # to the dispatched MW; it attaches the physical values as :p_dispatch_mw /
  # :p_nameplate_mw so the frequency dynamics stay physical.
  defp dispatch_mw(gen) do
    Map.get(gen, :p_dispatch_mw) ||
      gen.p_max_mw * (Map.get(gen, :capacity_factor) || 1.0)
  end

  defp nameplate_mw(gen) do
    Map.get(gen, :p_nameplate_mw) || gen.p_max_mw
  end

  defp build_governor_units(generators) do
    Enum.map(generators, fn gen ->
      p_dispatch = dispatch_mw(gen)
      p_nameplate = nameplate_mw(gen)
      t_gov = gov_time_for(gen)
      h = inertia_for(gen)

      # Governor headroom: how much more the generator can ramp up from its
      # current operating point toward nameplate capability
      headroom = p_nameplate - p_dispatch

      %{
        # Droop responds on the machine base (nameplate), not current output
        p_rated: p_nameplate,
        p_max: p_nameplate,
        p_dispatch: p_dispatch,
        headroom: max(headroom, 0.0),
        t_gov: t_gov,
        droop: @droop,
        has_governor: h > 0.0 and t_gov < 100.0
      }
    end)
  end

  defp update_governors(gov_units, gov_state, df, dt) do
    {new_states, total} =
      Enum.zip(gov_units, gov_state)
      |> Enum.map_reduce(0.0, fn {unit, current_dp}, total_mw ->
        if not unit.has_governor do
          {current_dp, total_mw + current_dp}
        else
          # Desired governor response based on droop
          # dp_target = -(df / f0) / R * P_rated
          # Negative df (underfrequency) -> positive dp (more generation)
          dp_target = -(df / @f0) / unit.droop * unit.p_rated

          # Clamp upward response to headroom and backing down to dispatched output
          dp_target = max(-unit.p_dispatch, min(dp_target, unit.headroom))

          # First-order lag: dp approaches dp_target with time constant T_gov
          # dp_new = dp_old + (dp_target - dp_old) * dt / T_gov
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
            # Already tripped, no new shedding
            {stage_state, shed_acc}

          freq < threshold ->
            case stage_state.armed_at do
              nil ->
                # Arm the stage
                {%{stage_state | armed_at: time}, shed_acc}

              armed_time when time - armed_time >= delay ->
                # Delay elapsed, trip the stage
                shed_mw = total_load_mw * shed_frac
                {%{stage_state | tripped: true}, shed_acc + shed_mw}

              _armed_time ->
                # Still waiting for delay
                {stage_state, shed_acc}
            end

          true ->
            # Frequency above threshold, reset arming if not tripped
            {%{stage_state | armed_at: nil}, shed_acc}
        end
      end)

    {new_state, total_new_shed}
  end
end
