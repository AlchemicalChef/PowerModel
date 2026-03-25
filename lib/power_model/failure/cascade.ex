defmodule PowerModel.Failure.Cascade do
  @moduledoc """
  Cascading failure simulation engine.

  Implements four realism improvements:

  1. **Timed cascade** -- Uses conductor thermal model to determine trip timing.
     Only the fastest-tripping component is removed per step; the power flow is
     re-solved and remaining overloads are re-evaluated.

  2. **Generator redispatch** -- After a generator or line trips, the lost
     power is redistributed among online generators based on headroom.

  3. **Unit commitment** -- Only generators that would realistically be online
     participate in the simulation (must-run + merit-order to 115% of load).

  4. **Generator protection relays** -- Underfrequency relay 81 trips generators
     when frequency drops below fuel-type-specific thresholds, creating the
     critical feedback loop of real cascading failures.
  """

  require Logger

  alias PowerModel.Solver.{DCPowerFlow, NewtonRaphson, EconomicDispatch, UnitCommitment, LODF, OPF}
  alias PowerModel.Solver.Frequency
  alias PowerModel.Solver.Stability.{CPF, SmallSignal}
  alias PowerModel.Solver.Harmonics.Scenario, as: HarmonicsScenario
  alias PowerModel.Failure.{Protection, LoadShedding, Scenarios}
  alias PowerModel.Simulation.Cascading.IslandDetector
  alias PowerModel.Controls.{AGC, OLTC, SVCController, FACTSController, HVDCController, RAS}

  @max_steps 50

  defstruct [
    :buses,
    :lines,
    :transformers,
    :generators,
    :loads,
    :water_facilities,
    :critical_facilities,
    :base_mva,
    :tripped_lines,
    :tripped_generators,
    :tripped_transformers,
    :offline_generators,
    :affected_water_facilities,
    :affected_critical_facilities,
    :base_overloaded,
    :base_line_loading,
    :events,
    :step,
    :stable,
    :solution,
    :simulated_time,
    :dispatch,
    :frequency_hz,
    :use_ac,
    :use_transient,
    :last_solution,
    # Layer 2 controls
    :agc_state,
    :oltc_states,
    :svc_states,
    :svc_devices,
    :facts_states,
    :facts_devices,
    :hvdc_states,
    :hvdc_lines,
    :ras_schemes,
    :last_agc_time,
    :lodf_state,
    # Solver integration fields
    :scenario,
    :use_opf,
    :opf_result,
    :lmps,
    :congested_lines,
    :run_cpf,
    :voltage_margin_mw,
    :critical_bus_id,
    :cpf_result,
    :run_small_signal,
    :stability_modes,
    :small_signal_stable,
    :small_signal_result,
    :run_harmonics,
    :harmonics_result,
    :harmonics_worst_thd,
    :harmonics_violations
  ]

  @doc """
  Initialize cascade state from a grid snapshot.

  Performs unit commitment to determine which generators are online,
  then dispatches them to meet load via merit-order economic dispatch.

  ## Options
    * `:use_ac` - use Newton-Raphson AC power flow instead of DC (default false)
    * `:use_transient` - run transient stability check after each trip (default false)
    * `:scenario` - a `%Scenarios{}` struct to apply initial conditions (default nil)
    * `:use_opf` - use OPF instead of economic dispatch (default false)
    * `:run_cpf` - run CPF after cascade stabilizes (default false)
    * `:run_small_signal` - run small-signal analysis after stabilization (default false)
    * `:run_harmonics` - run harmonics analysis after stabilization (default false)
  """
  def init(snapshot, base_mva \\ 100.0, opts \\ []) do
    use_ac = Keyword.get(opts, :use_ac, false)
    use_transient = Keyword.get(opts, :use_transient, false)
    scenario = Keyword.get(opts, :scenario, nil)
    use_opf = Keyword.get(opts, :use_opf, false)
    run_cpf = Keyword.get(opts, :run_cpf, false)
    run_small_signal = Keyword.get(opts, :run_small_signal, false)
    run_harmonics = Keyword.get(opts, :run_harmonics, false)
    total_load = Enum.sum_by(snapshot.loads, & &1.p_mw)

    # Unit commitment: only commit enough generators to cover load + 15% reserve
    {online_gens, offline_ids} = UnitCommitment.commit(snapshot.generators, total_load)

    # Integration 2: OPF replaces EconomicDispatch when use_opf is true
    {dispatch, opf_result, lmps, congested_lines} =
      if use_opf do
        try do
          committed_snap = %{snapshot | generators: online_gens}
          result = OPF.solve(committed_snap, base_mva: base_mva)
          {result.dispatch, result, result.lmps, result.congested_lines}
        rescue
          e ->
            Logger.warning("[CASCADE INIT] OPF failed, falling back to EconomicDispatch: #{inspect(e)}")
            {EconomicDispatch.dispatch(online_gens, total_load), nil, nil, nil}
        end
      else
        {EconomicDispatch.dispatch(online_gens, total_load), nil, nil, nil}
      end

    committed_snapshot = %{snapshot | generators: online_gens}

    # Solve DC once to get base-case line flows
    {base_solution, raw_loading} = compute_base_solution(committed_snapshot, dispatch, base_mva)

    # Apply SIL limits FIRST (physical constraint), then calibrate artifacts.
    # Ordering matters: SIL can reduce ratings below the raw MATPOWER value,
    # so calibration must run AFTER to handle any remaining >200% overloads.
    sil_lines = apply_sil_limits(snapshot.lines, base_mva)

    # Recompute loading with SIL-adjusted ratings to get accurate percentages
    sil_loading = recompute_line_loading_map(base_solution, sil_lines)

    calibrated_lines = calibrate_ratings(sil_lines, sil_loading)
    calibrated_xfmrs = calibrate_transformer_ratings(Map.get(snapshot, :transformers, []), raw_loading)

    # Recompute loading percentages with fully calibrated ratings (no re-solve needed —
    # theta is the same because impedances and injections haven't changed)
    {base_overloaded, base_loading} = recompute_loading_from_solution(
      base_solution, calibrated_lines, calibrated_xfmrs
    )

    # Initialize LODF for fast cascade steps (if base solution is available)
    lodf_state = if base_solution do
      try do
        LODF.init(
          %{buses: snapshot.buses, lines: calibrated_lines,
            transformers: calibrated_xfmrs, generators: online_gens,
            loads: snapshot.loads},
          base_solution, base_mva: base_mva)
      rescue
        _ -> nil
      end
    else
      nil
    end

    # Initialize Layer 2 controls from snapshot data
    agc_state = init_agc(online_gens, dispatch)

    oltc_states = calibrated_xfmrs
    |> Enum.filter(fn x -> Map.get(x, :tap_ratio) != nil end)
    |> Map.new(fn x -> {x.id, OLTC.init(x)} end)

    svcs = Map.get(snapshot, :svcs, [])
    svc_states = Map.new(svcs, fn s -> {s.id, SVCController.init(s)} end)

    facts = Map.get(snapshot, :facts_devices, [])
    facts_states = Map.new(facts, fn f -> {f.id, FACTSController.init(f)} end)

    hvdcs = Map.get(snapshot, :hvdc_lines, [])
    hvdc_states = Map.new(hvdcs, fn h -> {h.id, HVDCController.init(h)} end)

    ras_schemes = RAS.init(Keyword.get(opts, :ras_schemes, []))

    state = %__MODULE__{
      buses: snapshot.buses,
      lines: calibrated_lines,
      transformers: calibrated_xfmrs,
      generators: snapshot.generators,
      loads: snapshot.loads,
      water_facilities: Map.get(snapshot, :water_facilities, []),
      critical_facilities: Map.get(snapshot, :critical_facilities, []),
      base_mva: base_mva,
      tripped_lines: MapSet.new(),
      tripped_generators: MapSet.new(),
      tripped_transformers: MapSet.new(),
      offline_generators: offline_ids,
      affected_water_facilities: MapSet.new(),
      affected_critical_facilities: MapSet.new(),
      base_overloaded: base_overloaded,
      base_line_loading: base_loading,
      events: [],
      step: 0,
      stable: false,
      solution: base_solution,
      simulated_time: 0.0,
      dispatch: dispatch,
      frequency_hz: 60.0,
      use_ac: use_ac,
      use_transient: use_transient,
      last_solution: nil,
      agc_state: agc_state,
      oltc_states: oltc_states,
      svc_states: svc_states,
      svc_devices: svcs,
      facts_states: facts_states,
      facts_devices: facts,
      hvdc_states: hvdc_states,
      hvdc_lines: hvdcs,
      ras_schemes: ras_schemes,
      last_agc_time: 0.0,
      lodf_state: lodf_state,
      # Solver integration fields
      scenario: scenario,
      use_opf: use_opf,
      opf_result: opf_result,
      lmps: lmps,
      congested_lines: congested_lines,
      run_cpf: run_cpf,
      voltage_margin_mw: nil,
      critical_bus_id: nil,
      cpf_result: nil,
      run_small_signal: run_small_signal,
      stability_modes: nil,
      small_signal_stable: nil,
      small_signal_result: nil,
      run_harmonics: run_harmonics,
      harmonics_result: nil,
      harmonics_worst_thd: nil,
      harmonics_violations: nil
    }

    # Integration 1: Apply scenario if provided
    state = if scenario do
      try do
        state = Scenarios.apply_scenario(state, scenario)
        # Record scenario in events
        event = %{
          step: 0,
          component_type: "system",
          component_id: nil,
          failure_cause: "scenario_applied",
          details: %{description: scenario.description}
        }
        # Re-dispatch after scenario modifications (loads/ratings changed)
        active_gens = active_generators(state)
        new_total_load = Enum.sum_by(state.loads, & &1.p_mw)
        new_dispatch = if use_opf do
          try do
            snap = build_active_snapshot(state)
            result = OPF.solve(snap, base_mva: base_mva)
            result.dispatch
          rescue
            _ -> EconomicDispatch.dispatch(active_gens, new_total_load)
          end
        else
          EconomicDispatch.dispatch(active_gens, new_total_load)
        end
        %{state | dispatch: new_dispatch, events: [event | state.events]}
      rescue
        e ->
          Logger.warning("[CASCADE INIT] Scenario application failed: #{inspect(e)}")
          state
      end
    else
      state
    end

    state
  end

  defp init_agc(online_gens, dispatch) do
    agc_gens = Enum.filter(online_gens, fn g ->
      (Map.get(g, :agc_participation_factor) || 0.0) > 0.0
    end)

    if Enum.empty?(agc_gens) do
      nil
    else
      gens_with_dispatch = Enum.map(agc_gens, fn g ->
        Map.put(g, :dispatch_mw, Map.get(dispatch, g.id, 0.0))
      end)
      AGC.init(gens_with_dispatch)
    end
  end

  # Solve DC once and return {solution, loading_map}
  defp compute_base_solution(snapshot, dispatch, base_mva) do
    dispatched_gens = Enum.map(snapshot.generators, fn g ->
      d = Map.get(dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))
      %{g | p_max_mw: d, capacity_factor: 1.0}
    end)

    base_snapshot = %{
      buses: snapshot.buses,
      lines: snapshot.lines,
      transformers: Map.get(snapshot, :transformers, []),
      generators: dispatched_gens,
      loads: snapshot.loads
    }

    try do
      solution = DCPowerFlow.solve(base_snapshot, base_mva: base_mva)

      base_loading = Map.new(solution.line_flows, fn {key, flow} ->
        {key, flow.loading_pct}
      end)

      {solution, base_loading}
    catch
      :throw, {:error, reason} ->
        Logger.warning("[CASCADE INIT] base solve failed: #{inspect(reason)}")
        {nil, %{}}
      kind, reason ->
        Logger.error("[CASCADE INIT] base solve unexpected failure: #{kind} #{inspect(reason)}")
        {nil, %{}}
    end
  end

  # Recompute just line loading percentages (for intermediate calibration steps).
  # Returns a map of {:line, id} => loading_pct.
  defp recompute_line_loading_map(nil, _lines), do: %{}
  defp recompute_line_loading_map(solution, lines) do
    line_rating_map = Map.new(lines, fn l -> {l.id, l.rating_a_mva} end)

    solution.line_flows
    |> Enum.filter(fn {{type, _}, _} -> type == :line end)
    |> Map.new(fn {{:line, id} = key, flow} ->
      rating = Map.get(line_rating_map, id)
      loading_pct = if rating && rating > 0 do
        abs(flow.p_flow_mw) / rating * 100.0
      else
        0.0
      end
      {key, loading_pct}
    end)
  end

  # Recompute loading percentages from an existing solution with updated ratings.
  # No re-solve needed — theta and flows in MW are the same, only loading_pct changes.
  defp recompute_loading_from_solution(nil, _lines, _xfmrs), do: {MapSet.new(), %{}}
  defp recompute_loading_from_solution(solution, lines, transformers) do
    line_rating_map = Map.new(lines, fn l -> {l.id, l.rating_a_mva} end)
    xfmr_rating_map = Map.new(transformers, fn x -> {x.id, x.rated_mva} end)

    base_loading = Map.new(solution.line_flows, fn {{type, id} = key, flow} ->
      rating = case type do
        :line -> Map.get(line_rating_map, id)
        :transformer -> Map.get(xfmr_rating_map, id)
        _ -> nil
      end

      loading_pct = if rating && rating > 0 do
        abs(flow.p_flow_mw) / rating * 100.0
      else
        0.0
      end

      {key, loading_pct}
    end)

    overloaded_set =
      base_loading
      |> Enum.filter(fn {_key, pct} -> pct > 100.0 end)
      |> Enum.map(fn {key, _pct} -> key end)
      |> MapSet.new()

    {overloaded_set, base_loading}
  end

  @doc """
  Calibrate line ratings for clear data artifacts in the base case.

  Only inflates ratings for lines whose base-case loading exceeds 200% —
  these are clearly data artifacts (wrong rating or impedance) rather than
  genuinely constrained corridors. Lines at 100-200% may be legitimately
  stressed and should participate in cascade simulation.

  For artifact lines (>200%), the rating is bumped so base flow sits at 80%
  loading, leaving 20% headroom for real failures to push them past 100%.
  """
  def calibrate_ratings(lines, base_loading) do
    Enum.map(lines, fn line ->
      key = {:line, line.id}
      base_pct = Map.get(base_loading, key, 0.0)

      if base_pct > 200.0 and line.rating_a_mva != nil and line.rating_a_mva > 0 do
        scale = base_pct / 80.0
        new_a = line.rating_a_mva * scale
        updates = %{line | rating_a_mva: new_a}

        updates = if Map.get(line, :rating_b_mva) do
          %{updates | rating_b_mva: line.rating_b_mva * scale}
        else
          updates
        end

        if Map.get(line, :rating_c_mva) do
          %{updates | rating_c_mva: line.rating_c_mva * scale}
        else
          updates
        end
      else
        line
      end
    end)
  end

  @doc """
  Calibrate transformer ratings for clear data artifacts in the base case.

  Same threshold logic as `calibrate_ratings/2` but for transformers, which
  were previously ignored — a major source of the 9,900% loading values.

  For transformers at >200% loading, bumps `rated_mva` so the base flow
  sits at 80% loading.
  """
  def calibrate_transformer_ratings(transformers, base_loading) do
    Enum.map(transformers, fn xfmr ->
      key = {:transformer, xfmr.id}
      base_pct = Map.get(base_loading, key, 0.0)

      if base_pct > 200.0 and xfmr.rated_mva != nil and xfmr.rated_mva > 0 do
        scale = base_pct / 80.0
        %{xfmr | rated_mva: xfmr.rated_mva * scale}
      else
        xfmr
      end
    end)
  end

  @doc """
  Trip a transmission line and run cascade.
  Returns {final_state, all_step_results} for streaming.
  """
  def trip_line(%__MODULE__{} = state, line_id) do
    state = %{state |
      tripped_lines: MapSet.put(state.tripped_lines, line_id),
      events: [trip_event("transmission_line", line_id) | state.events]
    }
    run_cascade(state)
  end

  @doc """
  Trip a generator and run cascade.

  Simulates the frequency transient BEFORE redispatch to capture the nadir
  that occurs while governors are still responding.  Only the generation
  pickup achievable within the governor response window (~10 s) is credited
  to the first redispatch; the remaining deficit propagates into the cascade
  loop where AGC and subsequent redispatch steps close it over time.
  """
  def trip_generator(%__MODULE__{} = state, gen_id) do
    lost_mw = Map.get(state.dispatch, gen_id, 0.0)

    # Invalidate LODF state: LODF only models topology changes (line outages),
    # not injection changes.  A generator trip changes the P-injection vector,
    # so a full DC re-solve is required to compute the new line flows correctly.
    state = %{state |
      tripped_generators: MapSet.put(state.tripped_generators, gen_id),
      events: [trip_event("generator", gen_id) | state.events],
      lodf_state: nil
    }

    # --- Frequency transient: compute nadir BEFORE redispatch ---
    # The frequency nadir occurs in the first few seconds after the trip,
    # while governors are still ramping.  We must evaluate it with the
    # full deficit, not after it has been magically covered.
    active_gens = active_generators(state)

    # Set capacity_factor to dispatch/p_max so the frequency simulator
    # sees the correct operating point and governor headroom.
    # Without this, CF=1.0 means p_rated=p_max and headroom=0.
    freq_gens = Enum.map(active_gens, fn g ->
      dispatch_mw = Map.get(state.dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))
      cf = if g.p_max_mw > 0, do: dispatch_mw / g.p_max_mw, else: 1.0
      %{g | capacity_factor: min(cf, 0.95)}  # cap at 95% to ensure some headroom
    end)

    nadir_hz = if lost_mw > 0.0 do
      try do
        trajectory = Frequency.simulate(freq_gens, state.loads, lost_mw, 0.1, 30.0)
        Frequency.nadir(trajectory)
      rescue
        _ -> 60.0
      end
    else
      60.0
    end

    state = %{state | frequency_hz: nadir_hz}

    # Record frequency event when nadir is significant
    state = if nadir_hz < 59.95 do
      freq_event = %{
        step: 0,
        component_type: "system",
        component_id: nil,
        failure_cause: "frequency_excursion",
        details: %{
          nadir_hz: Float.round(nadir_hz, 3),
          lost_mw: Float.round(lost_mw, 1),
          tripped_gen_id: gen_id
        }
      }
      %{state | events: [freq_event | state.events]}
    else
      state
    end

    # --- Check generator relay 81 trips at the nadir frequency ---
    # This creates the critical feedback loop: gen trip -> freq drop ->
    # more gen trips -> deeper freq drop -> UFLS
    gen_relay_trips = Protection.check_generator_relays(active_gens, nadir_hz)
    gen_relay_trips = Enum.reject(gen_relay_trips, fn t ->
      MapSet.member?(state.tripped_generators, t.component_id)
    end)

    # Apply relay-tripped generators
    relay_lost_mw = Enum.sum_by(gen_relay_trips, fn t ->
      Map.get(state.dispatch, t.component_id, 0.0)
    end)
    state = apply_trips(state, gen_relay_trips)

    total_lost_mw = lost_mw + relay_lost_mw

    # --- Redispatch with realistic ramp-rate constraints ---
    # Use a 5-minute window representing the AGC response time.
    # Generators can only pick up what their ramp rates allow in 5 minutes.
    # Any remaining deficit triggers UFLS in the redispatch function.
    state = redispatch(state, total_lost_mw, 5.0)

    run_cascade(state)
  end

  @doc """
  Trip multiple generators simultaneously (common-mode failure).

  Unlike sequential `trip_generator` calls, this evaluates the combined
  frequency impact of ALL tripped generators at once, producing realistic
  frequency nadirs for N-k events.
  """
  def trip_generators(%__MODULE__{} = state, gen_ids) when is_list(gen_ids) do
    total_lost = Enum.sum_by(gen_ids, fn id -> Map.get(state.dispatch, id, 0.0) end)

    state = Enum.reduce(gen_ids, state, fn id, s ->
      %{s |
        tripped_generators: MapSet.put(s.tripped_generators, id),
        events: [trip_event("generator", id) | s.events],
        lodf_state: nil
      }
    end)

    # Frequency transient for the COMBINED deficit
    active_gens = active_generators(state)
    freq_gens = Enum.map(active_gens, fn g ->
      d = Map.get(state.dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))
      cf = if g.p_max_mw > 0, do: d / g.p_max_mw, else: 1.0
      %{g | capacity_factor: min(cf, 0.95)}
    end)

    nadir_hz = if total_lost > 0.0 do
      try do
        trajectory = Frequency.simulate(freq_gens, state.loads, total_lost, 0.1, 30.0)
        Frequency.nadir(trajectory)
      rescue
        _ -> 60.0
      end
    else
      60.0
    end

    state = %{state | frequency_hz: nadir_hz}

    state = if nadir_hz < 59.95 do
      event = %{step: 0, component_type: "system", component_id: nil,
                failure_cause: "frequency_excursion",
                details: %{nadir_hz: Float.round(nadir_hz, 3), lost_mw: Float.round(total_lost, 1)}}
      %{state | events: [event | state.events]}
    else
      state
    end

    # Generator relay 81 trips
    gen_relay_trips = Protection.check_generator_relays(active_gens, nadir_hz)
    |> Enum.reject(fn t -> MapSet.member?(state.tripped_generators, t.component_id) end)

    relay_lost = Enum.sum_by(gen_relay_trips, fn t -> Map.get(state.dispatch, t.component_id, 0.0) end)
    state = apply_trips(state, gen_relay_trips)

    state = redispatch(state, total_lost + relay_lost, 5.0)
    run_cascade(state)
  end

  @doc """
  Run cascade loop until stable or max steps reached.
  Yields each step result for streaming via callback.
  """
  def run_cascade(state, callback \\ nil) do
    do_cascade(state, [], callback)
  end

  @doc """
  Redistribute `deficit_mw` (positive = need more generation) among online
  generators proportionally to their available headroom.

  If total headroom is insufficient, the remaining deficit triggers UFLS
  load shedding and the corresponding events are appended to the state.

  Returns the updated cascade state with modified `dispatch` (and possibly
  modified `loads` / `events` when UFLS fires).
  """
  def redispatch(state, deficit_mw, time_window_min \\ :infinity)

  def redispatch(%__MODULE__{} = state, deficit_mw, _time_window_min)
      when deficit_mw <= 0.0 do
    state
  end

  def redispatch(%__MODULE__{} = state, deficit_mw, time_window_min) do
    # Integration 2: Use OPF for redispatch when use_opf is true
    if state.use_opf do
      try do
        snapshot = build_active_snapshot(state)
        result = OPF.solve(snapshot, base_mva: state.base_mva)
        %{state | dispatch: result.dispatch, opf_result: result,
          lmps: result.lmps, congested_lines: result.congested_lines}
      rescue
        _ ->
          # Fall back to standard redispatch on OPF failure
          do_standard_redispatch(state, deficit_mw, time_window_min)
      end
    else
      do_standard_redispatch(state, deficit_mw, time_window_min)
    end
  end

  defp do_standard_redispatch(state, deficit_mw, time_window_min) do
    # Only redispatch among online generators (exclude tripped AND offline)
    all_inactive = MapSet.union(state.tripped_generators, state.offline_generators || MapSet.new())

    {new_dispatch, remaining} =
      EconomicDispatch.redispatch(
        state.dispatch,
        state.generators,
        all_inactive,
        deficit_mw,
        time_window_min
      )

    state = %{state | dispatch: new_dispatch}

    if remaining > 0.5 do
      trigger_ufls_for_deficit(state, remaining)
    else
      state
    end
  end

  defp trigger_ufls_for_deficit(state, deficit_mw) do
    total_load = Enum.sum_by(state.loads, & &1.p_mw)
    online_gens = active_generators(state)
    total_gen = Enum.sum_by(online_gens, fn g -> Map.get(state.dispatch, g.id, 0.0) end)

    {shed_loads, shed_events} =
      LoadShedding.apply_ufls(state.loads, online_gens, total_gen, total_load)

    {shed_loads, shed_events} =
      if deficit_mw > 0 do
        shed_so_far =
          shed_events |> Enum.sum_by(fn e -> Map.get(e.details, :shed_mw, 0.0) end)

        if shed_so_far < deficit_mw * 0.9 and total_load > 0 do
          shed_fraction = min(deficit_mw / total_load, 1.0)
          LoadShedding.apply_proportional_shedding(
            shed_loads, shed_fraction, total_gen, total_load
          )
        else
          {shed_loads, shed_events}
        end
      else
        {shed_loads, shed_events}
      end

    shed_map = Map.new(shed_loads, &{&1.id, &1})
    updated_loads = Enum.map(state.loads, fn l -> Map.get(shed_map, l.id, l) end)

    events_with_step = Enum.map(shed_events, &Map.put(&1, :step, state.step))

    # Invalidate LODF: load shedding changes the injection vector
    %{state |
      loads: updated_loads,
      events: events_with_step ++ state.events,
      lodf_state: nil
    }
  end

  defp do_cascade(%{step: step} = state, step_results, _callback) when step >= @max_steps do
    {%{state | stable: false}, Enum.reverse(step_results)}
  end

  defp do_cascade(state, step_results, callback) do
    state = %{state | step: state.step + 1}

    # --- RAS: check triggers before solve ---
    state = run_ras(state)

    # --- HVDC: update power injections based on frequency ---
    state = run_hvdc_controllers(state)

    active_lines = Enum.reject(state.lines, &MapSet.member?(state.tripped_lines, &1.id))
    active_xfmrs = Enum.reject(state.transformers, &MapSet.member?(state.tripped_transformers, &1.id))
    active_gens = active_generators(state)

    # --- FACTS: modify line impedances before solve ---
    active_lines = apply_facts_to_lines(state.facts_states, state.facts_devices, active_lines)

    # Invalidate LODF if FACTS modified any line impedances
    state = if facts_changed_impedances?(state.facts_states, state.facts_devices) do
      %{state | lodf_state: nil}
    else
      state
    end

    dispatched_gens = apply_dispatch(active_gens, state.dispatch)

    bus_ids = Enum.map(state.buses, & &1.id)
    islands = IslandDetector.detect(bus_ids, active_lines, active_xfmrs)

    # Try LODF fast path for single-island, single-trip cascade steps
    {non_thermal_trips, island_results, updated_loads, timed_overloads, island_frequency, state} =
      if state.lodf_state != nil and length(islands) == 1 and not LODF.needs_refactorize?(state.lodf_state) do
        try_lodf_solve(state, islands, active_lines, active_xfmrs, dispatched_gens)
      else
        {trips, results, lds, overloads, freq} =
          solve_islands_timed(islands, state.buses, active_lines, active_xfmrs,
                              dispatched_gens, state.loads, state.base_mva,
                              state.base_overloaded, state.use_ac, state.last_solution)
        {trips, results, lds, overloads, freq, state}
      end

    # Update system frequency (use worst island frequency)
    state = %{state | frequency_hz: island_frequency}

    # --- OLTC: check voltages after solve, update taps ---
    state = run_oltc_controllers(state, island_results)

    # --- SVC: update reactive injection from solved voltages ---
    state = run_svc_controllers(state, island_results)

    # --- AGC: adjust dispatch every 4 seconds ---
    state = run_agc(state)

    # Check generator protection relays based on island frequency
    gen_relay_trips = Protection.check_generator_relays(dispatched_gens, island_frequency)

    # Filter out already-tripped generators
    gen_relay_trips = Enum.reject(gen_relay_trips, fn t ->
      MapSet.member?(state.tripped_generators, t.component_id)
    end)

    # Merge generator relay trips into timed overloads for unified handling
    all_timed = timed_overloads ++ gen_relay_trips

    {water_trips, newly_affected} = check_water_facility_impacts(
      state.water_facilities, state.affected_water_facilities, islands,
      active_gens, state.buses
    )

    {ci_trips, newly_affected_ci} = check_critical_facility_impacts(
      state.critical_facilities, state.affected_critical_facilities, islands,
      active_gens, state.buses
    )

    # Separate actionable trips (that cause further cascade propagation) from
    # non-actionable events (e.g. voltage violations on buses, load blackouts).
    # Non-actionable events are still recorded but don't prevent stabilization.
    actionable_trips = Enum.filter(non_thermal_trips, fn t ->
      Map.get(t, :component_type, "transmission_line") in
        ["transmission_line", "transformer", "generator"]
    end)

    if Enum.empty?(actionable_trips) and Enum.empty?(all_timed) do
      # Apply non-actionable events (blackouts, voltage violations) even when stable
      state = if Enum.empty?(non_thermal_trips), do: state, else: apply_trips(state, non_thermal_trips)

      step_result = %{
        step: state.step,
        simulated_time: state.simulated_time,
        frequency_hz: state.frequency_hz,
        islands: length(islands),
        trips: non_thermal_trips ++ water_trips ++ ci_trips,
        water_facility_ids: MapSet.to_list(MapSet.union(state.affected_water_facilities, newly_affected)),
        critical_facility_ids: MapSet.to_list(MapSet.union(state.affected_critical_facilities, newly_affected_ci)),
        solution: island_results
      }
      if callback, do: callback.(step_result)

      stable_state = %{state | stable: true, loads: updated_loads,
         affected_water_facilities: MapSet.union(state.affected_water_facilities, newly_affected),
         affected_critical_facilities: MapSet.union(state.affected_critical_facilities, newly_affected_ci)}
      stable_state = run_post_stabilization(stable_state)
      {stable_state, Enum.reverse([step_result | step_results])}
    else
      state = apply_trips(state, non_thermal_trips)
      state = %{state | loads: updated_loads}

      {tripped_component, trip_time_s} = pick_fastest_trip(all_timed)

      {fastest_trips, state} =
        if tripped_component do
          {[tripped_component],
           %{state | simulated_time: state.simulated_time + trip_time_s}}
        else
          {[], state}
        end

      all_trips_this_step = non_thermal_trips ++ fastest_trips ++ water_trips ++ ci_trips
      state = %{state |
        affected_water_facilities: MapSet.union(state.affected_water_facilities, newly_affected),
        affected_critical_facilities: MapSet.union(state.affected_critical_facilities, newly_affected_ci)
      }

      step_result = %{
        step: state.step,
        simulated_time: state.simulated_time,
        frequency_hz: state.frequency_hz,
        islands: length(islands),
        trips: all_trips_this_step,
        water_facility_ids: MapSet.to_list(state.affected_water_facilities),
        critical_facility_ids: MapSet.to_list(state.affected_critical_facilities),
        solution: island_results
      }

      if callback, do: callback.(step_result)
      step_results = [step_result | step_results]

      # Store the best solution for warm-starting next NR iteration
      best_solution = List.first(island_results)
      state = if best_solution, do: %{state | last_solution: best_solution}, else: state

      if Enum.empty?(fastest_trips) and Enum.empty?(actionable_trips) do
        stable_state = run_post_stabilization(%{state | stable: true})
        {stable_state, Enum.reverse(step_results)}
      else
        state = apply_trips(state, fastest_trips)

        # Integration 3: Auto-enable transient stability for large disturbances
        state = if should_check_transient?(state, fastest_trips) do
          check_transient_stability(state, fastest_trips)
        else
          state
        end

        state = maybe_redispatch_after_trip(state, trip_time_s)

        do_cascade(state, step_results, callback)
      end
    end
  end

  defp maybe_redispatch_after_trip(state, trip_time_s) do
    active_gens = active_generators(state)

    total_dispatch = Enum.sum_by(active_gens, fn g -> Map.get(state.dispatch, g.id, 0.0) end)

    total_load = Enum.sum_by(state.loads, & &1.p_mw)
    deficit = total_load - total_dispatch

    if deficit > 0.5 do
      # Convert trip time (seconds) to minutes for ramp rate enforcement
      time_window = if trip_time_s > 0.0, do: trip_time_s / 60.0, else: 5.0
      # Invalidate LODF: redispatch changes the injection vector
      state = %{state | lodf_state: nil}
      redispatch(state, deficit, time_window)
    else
      state
    end
  end

  defp solve_islands_timed(islands, buses, lines, transformers, generators, loads, base_mva, base_overloaded, use_ac, last_solution) do
    # Fast path: single island means the whole grid is connected — skip filtering
    if length(islands) == 1 do
      [island] = islands
      {trips, results, lds, overloads, freq} =
        solve_single_island(island, buses, lines, transformers, generators, loads, base_mva, base_overloaded, use_ac, last_solution)
      {trips, results, lds, overloads, freq}
    else
      {trips, results, lds, overloads, min_freq} =
        Enum.reduce(islands, {[], [], loads, [], 60.0}, fn island, {trips, results, lds, overloads, freq} ->
          {new_trips, new_results, new_lds, new_overloads, island_freq} =
            solve_single_island(island, buses, lines, transformers, generators, lds, base_mva, base_overloaded, use_ac, last_solution)

          worst_freq = min(freq, island_freq)

          {trips ++ new_trips, new_results ++ results, new_lds, overloads ++ new_overloads, worst_freq}
        end)

      {trips, results, lds, overloads, min_freq}
    end
  end

  defp solve_single_island(island_set, buses, lines, transformers, generators, loads, base_mva, base_overloaded, use_ac, last_solution) do
    island_buses = Enum.filter(buses, &MapSet.member?(island_set, &1.id))
    island_lines = Enum.filter(lines, fn l ->
      MapSet.member?(island_set, l.from_bus_id) and MapSet.member?(island_set, l.to_bus_id)
    end)
    island_xfmrs = Enum.filter(transformers, fn t ->
      MapSet.member?(island_set, t.from_bus_id) and MapSet.member?(island_set, t.to_bus_id)
    end)
    island_gens = Enum.filter(generators, &MapSet.member?(island_set, &1.bus_id))
    island_loads = Enum.filter(loads, &MapSet.member?(island_set, &1.bus_id))

    if length(island_buses) < 2 or Enum.empty?(island_gens) do
      new_trips = Enum.map(island_loads, fn load ->
        %{component_type: "load", component_id: load.id,
          failure_cause: "island_blackout", details: %{}}
      end)
      {new_trips, [], loads, [], 60.0}
    else
      gen_mw = Enum.sum_by(island_gens, fn g ->
        g.p_max_mw * (g.capacity_factor || 1.0)
      end)
      load_mw = Enum.sum_by(island_loads, & &1.p_mw)

      if load_mw > gen_mw do
        {shed_loads, shed_events} =
          LoadShedding.apply_ufls(island_loads, island_gens, gen_mw, load_mw)

        shed_map = Map.new(shed_loads, &{&1.id, &1})
        updated_loads = Enum.map(loads, fn l -> Map.get(shed_map, l.id, l) end)

        # Compute frequency for this deficit island
        freq = estimate_island_frequency(island_gens, island_loads, gen_mw, load_mw)

        {shed_events, [], updated_loads, [], freq}
      else
        solve_island_power_flow(island_buses, island_lines, island_xfmrs,
                                island_gens, island_loads, loads, base_mva, base_overloaded, use_ac, last_solution)
      end
    end
  end

  defp solve_island_power_flow(island_buses, island_lines, island_xfmrs,
                               island_gens, island_loads, loads, base_mva, base_overloaded,
                               use_ac, last_solution) do
    snapshot = %{
      buses: island_buses, lines: island_lines,
      transformers: island_xfmrs, generators: island_gens,
      loads: island_loads
    }

    try do
      solution = solve_power_flow(snapshot, base_mva, use_ac, last_solution)

      # Build line lookup for thermal model parameters
      line_map = Map.new(island_lines, &{&1.id, &1})

      timed = compute_timed_overloads(solution.line_flows, base_overloaded, line_map)

      voltage_trips = Protection.check_voltage_violations(
        solution.bus_ids, solution.vm_pu
      )

      bus_index = solution.bus_ids
        |> Enum.with_index()
        |> Map.new()
      zone3_trips = Protection.check_zone3_encroachment(
        solution.line_flows, island_lines ++ island_xfmrs,
        island_buses, solution.vm_pu, solution.va_rad, bus_index
      )

      zone3_timed = Enum.map(zone3_trips, fn t ->
        Map.put(t, :trip_time_s, 0.5)
      end)

      # UVLS: apply under-voltage load shedding when AC voltages are available
      {updated_loads, uvls_events} = if use_ac do
        bus_voltages = Map.new(Enum.zip(solution.bus_ids, solution.vm_pu))
        {uvls_loads, uvls_evts} = LoadShedding.apply_uvls(island_loads, bus_voltages)
        shed_map = Map.new(uvls_loads, &{&1.id, &1})
        new_loads = Enum.map(loads, fn l -> Map.get(shed_map, l.id, l) end)
        {new_loads, uvls_evts}
      else
        {loads, []}
      end

      # Compute island frequency from gen/load balance
      gen_mw = Enum.sum_by(island_gens, fn g ->
        g.p_max_mw * (g.capacity_factor || 1.0)
      end)
      load_mw = Enum.sum_by(island_loads, & &1.p_mw)
      freq = estimate_island_frequency(island_gens, island_loads, gen_mw, load_mw)

      all_non_thermal = voltage_trips ++ uvls_events
      {all_non_thermal, [solution], updated_loads, timed ++ zone3_timed, freq}
    catch
      kind, reason ->
        Logger.warning("island solve failed: #{kind} #{inspect(reason)}")
        {[], [], loads, [], 60.0}
    end
  end

  # Solve power flow using either DC or AC (Newton-Raphson) method.
  # Falls back to DC on NR failure.
  defp solve_power_flow(snapshot, base_mva, false, _last_solution) do
    DCPowerFlow.solve(snapshot, base_mva: base_mva)
  end

  defp solve_power_flow(snapshot, base_mva, true, last_solution) do
    try do
      case NewtonRaphson.solve(snapshot,
             base_mva: base_mva,
             warm_start: last_solution,
             max_iterations: 20,
             tolerance: 1.0e-3) do
        {:ok, solution} ->
          if solution.converged do
            solution
          else
            Logger.debug("NR did not converge, falling back to DC")
            DCPowerFlow.solve(snapshot, base_mva: base_mva)
          end

        {:error, _reason} ->
          DCPowerFlow.solve(snapshot, base_mva: base_mva)
      end
    rescue
      _ -> DCPowerFlow.solve(snapshot, base_mva: base_mva)
    end
  end

  defp compute_timed_overloads(line_flows, base_overloaded, line_map) do
    line_flows
    |> Enum.filter(fn {{_type, _id} = key, flow} ->
      flow.loading_pct > 100.0 and not MapSet.member?(base_overloaded, key)
    end)
    |> Enum.map(fn {{type, id}, flow} ->
      # Look up line for thermal model parameters
      line = Map.get(line_map, id)

      trip_time = Protection.overcurrent_trip_time(flow.loading_pct,
        voltage_kv: line && Map.get(line, :voltage_kv),
        rating_a_mva: line && Map.get(line, :rating_a_mva),
        rating_c_mva: line && Map.get(line, :rating_c_mva)
      )

      %{
        component_type: component_type_string(type),
        component_id: id,
        failure_cause: "thermal_overload",
        details: %{
          loading_pct: flow.loading_pct,
          p_flow_mw: flow.p_flow_mw,
          trip_time_s: trip_time
        },
        trip_time_s: trip_time
      }
    end)
  end

  defp estimate_island_frequency(island_gens, island_loads, gen_mw, load_mw) do
    cond do
      load_mw <= 0.0 ->
        60.0

      load_mw > gen_mw ->
        # Generation deficit -- frequency will drop
        lost_mw = load_mw - gen_mw
        try do
          trajectory = Frequency.simulate(island_gens, island_loads, lost_mw, 0.1, 10.0)
          Frequency.nadir(trajectory)
        rescue
          _ -> Protection.estimate_frequency(gen_mw, load_mw)
        end

      gen_mw > load_mw * 1.01 ->
        # Generation surplus (e.g. load shed overshoot) -- frequency rises
        # Use steady-state droop estimate: df/f0 = -dP/(D * P_load)
        # where D ~ 1.0, so surplus of 1% load -> +0.01 * 60 = 0.6 Hz
        surplus_frac = (gen_mw - load_mw) / load_mw
        min(60.0 + surplus_frac * 60.0 * 0.05, 61.0)

      true ->
        # Balanced within 1% -- frequency is nominal
        60.0
    end
  end

  defp pick_fastest_trip([]), do: {nil, 0.0}

  defp pick_fastest_trip(timed_overloads) do
    fastest =
      Enum.min_by(timed_overloads, fn t ->
        case t.trip_time_s do
          :infinity -> 1.0e30
          s -> s
        end
      end)

    case fastest.trip_time_s do
      :infinity -> {nil, 0.0}
      s -> {Map.delete(fastest, :trip_time_s), s}
    end
  end

  # Run a transient stability simulation after a trip to detect OOS generators.
  # Produces generator trip events that feed back into the cascade.
  defp check_transient_stability(state, recent_trips) do
    # Only check if there were line/transformer trips (generator trips handled by redispatch)
    has_network_trip = Enum.any?(recent_trips, fn t ->
      t.component_type in ["transmission_line", "transformer"]
    end)

    if not has_network_trip do
      state
    else
      active_gens = active_generators(state)
      active_lines = Enum.reject(state.lines, &MapSet.member?(state.tripped_lines, &1.id))
      active_xfmrs = Enum.reject(state.transformers, &MapSet.member?(state.tripped_transformers, &1.id))

      # Build a snapshot for transient simulation
      snapshot = %{
        buses: state.buses,
        lines: active_lines,
        transformers: active_xfmrs,
        generators: apply_dispatch(active_gens, state.dispatch),
        loads: state.loads
      }

      # Run transient stability check (short duration, just looking for OOS)
      try do
        case PowerModel.Transient.Runner.run(snapshot, {:network_disturbance}, [
               duration_s: 2.0,
               dt: 0.01,
               base_mva: state.base_mva,
               use_nif: true
             ]) do
          {:ok, %{events: oos_events}} when oos_events != [] ->
            # Convert OOS events to cascade trip events
            oos_trips = Enum.map(oos_events, fn e ->
              %{
                component_type: "generator",
                component_id: e.component_id,
                failure_cause: "out_of_step",
                details: Map.get(e, :details, %{})
              }
            end)

            Logger.info("[CASCADE] Transient stability: #{length(oos_trips)} generators OOS")
            apply_trips(state, oos_trips)

          _ ->
            state
        end
      rescue
        _ -> state
      catch
        _, _ -> state
      end
    end
  end

  @doc false
  # Apply SIL limits for long EHV lines.
  # For 345kV+ lines over 200km (or 500kV+ over 300km), cap the effective
  # rating at 2 * SIL where SIL = sqrt(b_pu/x_pu) * base_mva.
  defp apply_sil_limits(lines, base_mva) do
    Enum.map(lines, fn line ->
      voltage_kv = Map.get(line, :voltage_kv) || 0.0
      length_km = Map.get(line, :length_km) || 0.0
      x_pu = Map.get(line, :x_pu) || 0.0
      b_pu = Map.get(line, :b_pu) || 0.0
      rating_a = Map.get(line, :rating_a_mva) || 0.0

      sil_applicable =
        x_pu > 0.0 and b_pu > 0.0 and rating_a > 0.0 and
        ((voltage_kv >= 345.0 and length_km >= 200.0) or
         (voltage_kv >= 500.0 and length_km >= 300.0))

      if sil_applicable do
        sil_pu = :math.sqrt(b_pu / x_pu)
        sil_mva = sil_pu * base_mva * 2.0
        if sil_mva < rating_a do
          %{line | rating_a_mva: sil_mva}
        else
          line
        end
      else
        line
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # LODF fast path
  # ---------------------------------------------------------------------------

  # Use LODF to compute updated flows without a full DC re-solve.
  # Processes recently tripped lines through LODF.trip_line.
  defp try_lodf_solve(state, islands, active_lines, active_xfmrs, dispatched_gens) do
    # Find lines tripped since LODF was last updated
    new_trips = MapSet.difference(state.tripped_lines, state.lodf_state.cumulative_trips)

    if MapSet.size(new_trips) == 0 do
      # No new trips — just rebuild flows from current LODF state
      lodf_flows = lodf_flow_map(state.lodf_state)
      line_map = Map.new(active_lines, &{&1.id, &1})
      timed = compute_timed_overloads(lodf_flows, state.base_overloaded, line_map)
      freq = estimate_frequency_from_state(state)
      {[], [], state.loads, timed, freq, state}
    else
      # Apply each new trip through LODF
      {lodf, split} = Enum.reduce_while(new_trips, {state.lodf_state, false}, fn line_id, {lodf, _} ->
        case LODF.trip_line(lodf, {:line, line_id}) do
          {:ok, new_lodf, _flows} -> {:cont, {new_lodf, false}}
          {:island_split, new_lodf} -> {:halt, {new_lodf, true}}
          {:error, new_lodf} -> {:halt, {new_lodf, true}}
        end
      end)

      if split do
        # LODF detected island split — fall back to full solve
        state = %{state | lodf_state: nil}
        {trips, results, lds, overloads, freq} =
          solve_islands_timed(islands, state.buses, active_lines, active_xfmrs,
                              dispatched_gens, state.loads, state.base_mva,
                              state.base_overloaded, state.use_ac, state.last_solution)
        {trips, results, lds, overloads, freq, state}
      else
        # LODF succeeded — use updated flows
        lodf_flows = lodf_flow_map(lodf)
        line_map = Map.new(active_lines, &{&1.id, &1})
        timed = compute_timed_overloads(lodf_flows, state.base_overloaded, line_map)
        freq = estimate_frequency_from_state(state)
        state = %{state | lodf_state: lodf}
        {[], [], state.loads, timed, freq, state}
      end
    end
  end

  defp lodf_flow_map(lodf_state) do
    branch_map = Map.new(lodf_state.branches, fn b -> {b.key, b} end)

    Map.new(lodf_state.base_flows, fn {key, flow_mw} ->
      branch = Map.get(branch_map, key)
      rating = if branch, do: branch.rating, else: 0.0
      loading = if rating > 0.0, do: abs(flow_mw) / rating * 100.0, else: 0.0

      {key, %{
        p_flow_mw: flow_mw,
        loading_pct: loading,
        overloaded: rating > 0.0 and abs(flow_mw) > rating
      }}
    end)
  end

  defp estimate_frequency_from_state(state) do
    active_gens = active_generators(state)
    gen_mw = Enum.sum_by(active_gens, fn g -> Map.get(state.dispatch, g.id, 0.0) end)
    load_mw = Enum.sum_by(state.loads, & &1.p_mw)

    computed_freq = estimate_island_frequency(active_gens, state.loads, gen_mw, load_mw)

    # Don't snap back to 60.0 if the system was just depressed.
    # Use the worse of: the new computed frequency, or the previous
    # frequency recovering toward 60.0 (simple exponential recovery,
    # ~30s time constant approximated per cascade step).
    if state.frequency_hz < 59.95 and computed_freq >= 59.95 do
      # Frequency is recovering -- blend toward 60.0 but don't jump there
      recovery_rate = 0.3  # ~30% recovery per cascade step
      recovered = state.frequency_hz + (60.0 - state.frequency_hz) * recovery_rate
      min(recovered, computed_freq)
    else
      computed_freq
    end
  end

  # ---------------------------------------------------------------------------
  # Layer 2 Controls integration
  # ---------------------------------------------------------------------------

  # RAS: check triggers against recent events
  defp run_ras(%{ras_schemes: schemes} = state) when schemes == [] or is_nil(schemes), do: state
  defp run_ras(state) do
    {updated_ras, actions} = RAS.check(
      state.ras_schemes,
      state.events,
      frequency_hz: state.frequency_hz
    )

    state = %{state | ras_schemes: updated_ras}

    Enum.reduce(actions, state, fn action, st ->
      case Map.get(action, :type) do
        :trip_generator ->
          event = %{step: st.step, component_type: "generator",
                    component_id: action.target_id,
                    failure_cause: "ras_action", details: %{ras_name: Map.get(action, :ras_name)}}
          # Invalidate LODF: injection vector changes with generator trip
          %{st |
            tripped_generators: MapSet.put(st.tripped_generators, action.target_id),
            events: [event | st.events],
            lodf_state: nil}

        :trip_line ->
          event = %{step: st.step, component_type: "transmission_line",
                    component_id: action.target_id,
                    failure_cause: "ras_action", details: %{ras_name: Map.get(action, :ras_name)}}
          %{st |
            tripped_lines: MapSet.put(st.tripped_lines, action.target_id),
            events: [event | st.events]}

        :shed_load ->
          target_ids = Map.get(action, :target_ids, [])
          fraction = Map.get(action, :fraction, 0.1)
          updated_loads = Enum.map(st.loads, fn l ->
            if l.id in target_ids do
              %{l | p_mw: l.p_mw * (1.0 - fraction)}
            else
              l
            end
          end)
          # Invalidate LODF: load shedding changes the injection vector
          %{st | loads: updated_loads, lodf_state: nil}

        _ -> st
      end
    end)
  end

  # AGC: runs every 4 seconds of simulated time
  defp run_agc(%{agc_state: nil} = state), do: state
  defp run_agc(state) do
    dt_since_agc = state.simulated_time - (state.last_agc_time || 0.0)

    if dt_since_agc < 4.0 do
      state
    else
      active_gens = active_generators(state)
      total_gen = Enum.sum_by(active_gens, fn g -> Map.get(state.dispatch, g.id, 0.0) end)
      total_load = Enum.sum_by(state.loads, & &1.p_mw)

      {new_agc, adjustments} = AGC.step(
        state.agc_state, state.frequency_hz,
        total_gen, total_load, dt_since_agc
      )

      # Apply dispatch adjustments
      new_dispatch = Enum.reduce(adjustments, state.dispatch, fn {gen_id, delta_p}, d ->
        Map.update(d, gen_id, delta_p, &(&1 + delta_p))
      end)

      # Invalidate LODF if AGC actually changed any dispatch values,
      # since the injection vector no longer matches the LODF base case.
      lodf = if Enum.empty?(adjustments), do: state.lodf_state, else: nil

      %{state | agc_state: new_agc, dispatch: new_dispatch,
        last_agc_time: state.simulated_time, lodf_state: lodf}
    end
  end

  # HVDC: update power injections based on frequency
  defp run_hvdc_controllers(%{hvdc_states: hvdc} = state) when map_size(hvdc) == 0, do: state
  defp run_hvdc_controllers(state) do
    dt_s = max(state.simulated_time - max(state.simulated_time - 1.0, 0.0), 0.1)

    updated_hvdc = Map.new(state.hvdc_states, fn {id, hvdc_state} ->
      {new_state, _p_inject} = HVDCController.step(hvdc_state, state.frequency_hz, dt_s)
      {id, new_state}
    end)

    %{state | hvdc_states: updated_hvdc}
  end

  # OLTC: check secondary voltages and adjust taps
  defp run_oltc_controllers(%{oltc_states: oltc} = state, _solutions) when map_size(oltc) == 0, do: state
  defp run_oltc_controllers(state, island_results) do
    bus_voltages = Enum.reduce(island_results, %{}, fn sol, acc ->
      Enum.zip(sol.bus_ids, sol.vm_pu) |> Enum.into(acc)
    end)

    xfmr_map = Map.new(state.transformers, &{&1.id, &1})
    dt_s = 1.0

    {updated_oltc, changed_xfmrs} =
      Enum.reduce(state.oltc_states, {%{}, %{}}, fn {xfmr_id, oltc_state}, {oltc_acc, changes} ->
        xfmr = Map.get(xfmr_map, xfmr_id)

        if xfmr == nil do
          {Map.put(oltc_acc, xfmr_id, oltc_state), changes}
        else
          v_secondary = Map.get(bus_voltages, xfmr.to_bus_id, 1.0)
          {new_oltc, action} = OLTC.step(oltc_state, v_secondary, dt_s)

          changes = case action do
            {:tap_change, new_tap} -> Map.put(changes, xfmr_id, new_tap)
            :no_change -> changes
          end

          {Map.put(oltc_acc, xfmr_id, new_oltc), changes}
        end
      end)

    updated_xfmrs = if map_size(changed_xfmrs) == 0 do
      state.transformers
    else
      Enum.map(state.transformers, fn x ->
        case Map.get(changed_xfmrs, x.id) do
          nil -> x
          new_tap -> %{x | tap_ratio: new_tap}
        end
      end)
    end

    %{state | oltc_states: updated_oltc, transformers: updated_xfmrs}
  end

  # SVC: update reactive power injection from solved voltages
  defp run_svc_controllers(%{svc_states: svc} = state, _solutions) when map_size(svc) == 0, do: state
  defp run_svc_controllers(state, island_results) do
    bus_voltages = Enum.reduce(island_results, %{}, fn sol, acc ->
      Enum.zip(sol.bus_ids, sol.vm_pu) |> Enum.into(acc)
    end)

    updated_svc = Map.new(state.svc_states, fn {id, svc_state} ->
      device = Enum.find(state.svc_devices, fn s -> s.id == id end)
      bus_id = device && Map.get(device, :bus_id)
      v_bus = Map.get(bus_voltages, bus_id, 1.0)
      {new_state, _q_inject} = SVCController.step(svc_state, v_bus)
      {id, new_state}
    end)

    %{state | svc_states: updated_svc}
  end

  # Check if any FACTS device has changed a line's impedance from its base value
  defp facts_changed_impedances?(facts_states, facts_devices)
       when map_size(facts_states) == 0 or facts_devices == [], do: false
  defp facts_changed_impedances?(facts_states, facts_devices) do
    Enum.any?(facts_devices, fn device ->
      state = Map.get(facts_states, device.id)
      state != nil and Map.get(state, :x_set_pu) != nil and
        Map.get(state, :x_set_pu) != Map.get(device, :x_pu)
    end)
  end

  # FACTS: modify line impedances before power flow solve
  defp apply_facts_to_lines(facts_states, facts_devices, lines)
       when map_size(facts_states) == 0 or facts_devices == [] do
    lines
  end
  defp apply_facts_to_lines(facts_states, facts_devices, lines) do
    # Build a map from line_id to FACTS modifications
    facts_by_line = Enum.reduce(facts_devices, %{}, fn device, acc ->
      line_id = Map.get(device, :line_id)
      facts_state = Map.get(facts_states, device.id)

      if line_id && facts_state do
        Map.put(acc, line_id, facts_state)
      else
        acc
      end
    end)

    if map_size(facts_by_line) == 0 do
      lines
    else
      Enum.map(lines, fn line ->
        case Map.get(facts_by_line, line.id) do
          nil -> line
          facts_state ->
            x_set = Map.get(facts_state, :x_set_pu)
            if x_set && x_set != 0.0 do
              %{line | x_pu: x_set}
            else
              line
            end
        end
      end)
    end
  end

  # Returns generators that are both online (committed) and not tripped
  defp active_generators(state) do
    offline = state.offline_generators || MapSet.new()
    Enum.reject(state.generators, fn g ->
      MapSet.member?(state.tripped_generators, g.id) or MapSet.member?(offline, g.id)
    end)
  end

  defp apply_dispatch(generators, dispatch) do
    Enum.map(generators, fn g ->
      dispatched_mw = Map.get(dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))
      %{g | p_max_mw: dispatched_mw, capacity_factor: 1.0}
    end)
  end

  defp apply_trips(state, trips) do
    Enum.reduce(trips, state, fn trip, st ->
      event = Map.put(trip, :step, st.step)

      case trip.component_type do
        "transmission_line" ->
          %{st |
            tripped_lines: MapSet.put(st.tripped_lines, trip.component_id),
            events: [event | st.events]
          }
        "transformer" ->
          %{st |
            tripped_transformers: MapSet.put(st.tripped_transformers, trip.component_id),
            events: [event | st.events]
          }
        "generator" ->
          # Invalidate LODF: generator trip changes the injection vector,
          # which LODF cannot model (it only handles topology/line outages).
          %{st |
            tripped_generators: MapSet.put(st.tripped_generators, trip.component_id),
            events: [event | st.events],
            lodf_state: nil
          }
        _ ->
          %{st | events: [event | st.events]}
      end
    end)
  end

  defp trip_event(component_type, component_id, cause \\ "manual_trip") do
    %{step: 0, component_type: component_type, component_id: component_id,
      failure_cause: cause, details: %{}}
  end

  defp component_type_string(:line), do: "transmission_line"
  defp component_type_string(:transformer), do: "transformer"
  defp component_type_string(other), do: Atom.to_string(other)

  defp check_water_facility_impacts(water_facilities, already_affected, islands, active_gens, _buses) do
    if Enum.empty?(water_facilities) do
      {[], MapSet.new()}
    else
      gen_bus_ids = MapSet.new(active_gens, & &1.bus_id)

      dead_bus_ids = Enum.reduce(islands, MapSet.new(), fn island, acc ->
        has_gen = Enum.any?(island, &MapSet.member?(gen_bus_ids, &1))
        if has_gen do
          acc
        else
          MapSet.union(acc, island)
        end
      end)

      {trips, new_ids} =
        water_facilities
        |> Enum.filter(fn wf ->
          wf.bus_id != nil and
          MapSet.member?(dead_bus_ids, wf.bus_id) and
          not MapSet.member?(already_affected, wf.id)
        end)
        |> Enum.reduce({[], MapSet.new()}, fn wf, {t, ids} ->
          trip = %{
            component_type: "water_facility",
            component_id: wf.id,
            failure_cause: "power_loss",
            details: %{name: wf.name, facility_type: wf.facility_type,
                        power_mw: wf.power_consumption_mw}
          }
          {[trip | t], MapSet.put(ids, wf.id)}
        end)

      {trips, new_ids}
    end
  end

  defp check_critical_facility_impacts(critical_facilities, already_affected, islands, active_gens, _buses) do
    if Enum.empty?(critical_facilities) do
      {[], MapSet.new()}
    else
      gen_bus_ids = MapSet.new(active_gens, & &1.bus_id)

      dead_bus_ids = Enum.reduce(islands, MapSet.new(), fn island, acc ->
        has_gen = Enum.any?(island, &MapSet.member?(gen_bus_ids, &1))
        if has_gen do
          acc
        else
          MapSet.union(acc, island)
        end
      end)

      {trips, new_ids} =
        critical_facilities
        |> Enum.filter(fn cf ->
          cf.bus_id != nil and
          MapSet.member?(dead_bus_ids, cf.bus_id) and
          not MapSet.member?(already_affected, cf.id)
        end)
        |> Enum.reduce({[], MapSet.new()}, fn cf, {t, ids} ->
          trip = %{
            component_type: "critical_facility",
            component_id: cf.id,
            failure_cause: "power_loss",
            details: %{name: cf.name, category: cf.category,
                        power_mw: cf.estimated_power_mw}
          }
          {[trip | t], MapSet.put(ids, cf.id)}
        end)

      {trips, new_ids}
    end
  end

  # ---------------------------------------------------------------------------
  # Shared infrastructure for solver integrations
  # ---------------------------------------------------------------------------

  @doc false
  # Build a snapshot of the currently active topology for use by OPF, CPF,
  # SmallSignal, Harmonics. Excludes tripped/offline components.
  def build_active_snapshot(state) do
    offline = state.offline_generators || MapSet.new()

    active_gens = state.generators
    |> Enum.reject(fn g ->
      MapSet.member?(state.tripped_generators, g.id) or MapSet.member?(offline, g.id)
    end)
    |> Enum.map(fn g ->
      d = Map.get(state.dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))
      %{g | p_max_mw: d, capacity_factor: 1.0}
    end)

    %{
      buses: state.buses,
      lines: Enum.reject(state.lines, &MapSet.member?(state.tripped_lines, &1.id)),
      transformers: Enum.reject(state.transformers, &MapSet.member?(state.tripped_transformers, &1.id)),
      generators: active_gens,
      loads: state.loads
    }
  end

  # ---------------------------------------------------------------------------
  # Integration 3: Auto-enable transient stability
  # ---------------------------------------------------------------------------

  # Determines whether transient stability should be checked for this step.
  # Auto-enables when >500 MW generation lost OR >=3 lines tripped.
  # `use_transient: true` forces unconditional checking.
  defp should_check_transient?(state, recent_trips) do
    if state.use_transient do
      true
    else
      # Auto-enable for large disturbances
      gen_trips = Enum.filter(recent_trips, fn t ->
        t.component_type == "generator"
      end)
      lost_mw = Enum.sum_by(gen_trips, fn t ->
        Map.get(state.dispatch, t.component_id, 0.0)
      end)

      line_trips = Enum.count(recent_trips, fn t ->
        t.component_type in ["transmission_line", "transformer"]
      end)

      total_tripped_lines = MapSet.size(state.tripped_lines) + MapSet.size(state.tripped_transformers)

      lost_mw > 500.0 or line_trips >= 3 or total_tripped_lines >= 3
    end
  end

  # ---------------------------------------------------------------------------
  # Post-stabilization analyses (CPF, SmallSignal, Harmonics)
  # ---------------------------------------------------------------------------

  # Run all enabled post-stabilization analyses after the cascade reaches
  # a stable state. Each analysis is wrapped in try/rescue so a failure in
  # one does not prevent others from running.
  defp run_post_stabilization(state) do
    state
    |> maybe_run_cpf()
    |> maybe_run_small_signal()
    |> maybe_run_harmonics()
  end

  # Integration 5: CPF after cascade stabilizes
  defp maybe_run_cpf(%{run_cpf: true} = state) do
    try do
      snapshot = build_active_snapshot(state)
      solver = if state.use_ac, do: :ac, else: :dc
      result = CPF.trace(snapshot, base_mva: state.base_mva, solver: solver, max_steps: 50)

      %{state |
        cpf_result: result,
        voltage_margin_mw: result.margin_mw,
        critical_bus_id: result.critical_bus_id
      }
    rescue
      e ->
        Logger.warning("[CASCADE] CPF post-stabilization failed: #{inspect(e)}")
        state
    end
  end
  defp maybe_run_cpf(state), do: state

  # Integration 6: Small-signal after cascade stabilizes
  defp maybe_run_small_signal(%{run_small_signal: true} = state) do
    try do
      active_gens = active_generators(state)

      # Limit to 50 largest generators for performance
      top_gens = active_gens
      |> Enum.sort_by(fn g -> -(Map.get(state.dispatch, g.id, 0.0)) end)
      |> Enum.take(50)

      n = length(top_gens)
      if n < 2 do
        %{state | small_signal_stable: true, stability_modes: [], small_signal_result: nil}
      else
        # Build a simple reduced admittance matrix from generator buses
        # Use uniform internal voltages and angles as approximation
        base_angles = List.duplicate(0.0, n)
        e_prime = List.duplicate(1.0, n)

        # Build Y_red from generator buses (simplified — diagonal dominant)
        gen_bus_ids = Enum.map(top_gens, & &1.bus_id)
        bus_index = Map.new(Enum.with_index(gen_bus_ids))

        active_lines = Enum.reject(state.lines, &MapSet.member?(state.tripped_lines, &1.id))
        active_xfmrs = Enum.reject(state.transformers, &MapSet.member?(state.tripped_transformers, &1.id))

        {rows, cols, g_vals, b_vals} =
          build_y_red_coo(gen_bus_ids, bus_index, active_lines, active_xfmrs)

        result = SmallSignal.analyze(top_gens, {rows, cols, g_vals, b_vals},
                                     base_angles, e_prime, base_mva: state.base_mva)

        %{state |
          small_signal_result: result,
          small_signal_stable: result.stable,
          stability_modes: result.modes
        }
      end
    rescue
      e ->
        Logger.warning("[CASCADE] Small-signal post-stabilization failed: #{inspect(e)}")
        state
    end
  end
  defp maybe_run_small_signal(state), do: state

  # Build a simplified reduced admittance matrix in COO format for small-signal.
  # Only includes connections between generator buses.
  defp build_y_red_coo(gen_bus_ids, bus_index, lines, transformers) do
    gen_set = MapSet.new(gen_bus_ids)

    triplets =
      Enum.reduce(lines ++ transformers, %{}, fn branch, acc ->
        from = branch.from_bus_id
        to = branch.to_bus_id

        if MapSet.member?(gen_set, from) and MapSet.member?(gen_set, to) do
          i = Map.get(bus_index, from)
          j = Map.get(bus_index, to)
          x = Map.get(branch, :x_pu) || 0.001
          r = Map.get(branch, :r_pu) || 0.0
          z_sq = r * r + x * x
          g = r / max(z_sq, 1.0e-12)
          b = -x / max(z_sq, 1.0e-12)

          if i != nil and j != nil do
            acc
            |> Map.update({i, i}, {g, -b}, fn {g0, b0} -> {g0 + g, b0 - b} end)
            |> Map.update({j, j}, {g, -b}, fn {g0, b0} -> {g0 + g, b0 - b} end)
            |> Map.update({i, j}, {-g, b}, fn {g0, b0} -> {g0 - g, b0 + b} end)
            |> Map.update({j, i}, {-g, b}, fn {g0, b0} -> {g0 - g, b0 + b} end)
          else
            acc
          end
        else
          acc
        end
      end)

    {rows, cols, g_vals, b_vals} =
      Enum.reduce(triplets, {[], [], [], []}, fn {{r, c}, {g, b}}, {rs, cs, gs, bs} ->
        {[r | rs], [c | cs], [g | gs], [b | bs]}
      end)

    {rows, cols, g_vals, b_vals}
  end

  # Integration 8: Harmonics post-stabilization
  defp maybe_run_harmonics(%{run_harmonics: true} = state) do
    try do
      snapshot = build_active_snapshot(state)
      harmonic_scenario = HarmonicsScenario.create_scenario(snapshot,
        base_mva: state.base_mva, max_harmonic: 15)

      case HarmonicsScenario.run(harmonic_scenario, snapshot) do
        {:ok, result} ->
          {worst_bus_id, worst_thd} = result.worst_bus

          %{state |
            harmonics_result: result,
            harmonics_worst_thd: %{bus_id: worst_bus_id, thd_pct: worst_thd},
            harmonics_violations: result.total_violations
          }

        {:error, reason} ->
          Logger.warning("[CASCADE] Harmonics post-stabilization failed: #{inspect(reason)}")
          state
      end
    rescue
      e ->
        Logger.warning("[CASCADE] Harmonics post-stabilization failed: #{inspect(e)}")
        state
    end
  end
  defp maybe_run_harmonics(state), do: state
end
