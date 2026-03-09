defmodule PowerModel.Failure.Cascade do
  @moduledoc """
  Cascading failure simulation engine.

  Implements two realism improvements over a naive simultaneous-trip model:

  1. **Timed cascade** -- Uses inverse-time overcurrent curves to determine
     which overloaded component trips first.  Only that single component is
     removed per step; the power flow is re-solved and remaining overloads
     are re-evaluated (the redistribution may relieve them).

  2. **Generator redispatch** -- After a generator or line trips, the lost
     power is redistributed proportionally among remaining online generators
     based on their available headroom (`p_max_mw - current_dispatch`).
     Only the residual numerical mismatch is left for the DC slack bus.
     When total headroom is insufficient the deficit triggers UFLS.
  """

  require Logger

  alias PowerModel.Solver.DCPowerFlow
  alias PowerModel.Solver.EconomicDispatch
  alias PowerModel.Failure.{Protection, LoadShedding}
  alias PowerModel.Simulation.Cascading.IslandDetector

  @max_steps 50

  defstruct [
    :buses,
    :lines,
    :transformers,
    :generators,
    :loads,
    :water_facilities,
    :base_mva,
    :tripped_lines,
    :tripped_generators,
    :tripped_transformers,
    :affected_water_facilities,
    :base_overloaded,
    :base_line_loading,
    :events,
    :step,
    :stable,
    :solution,
    :simulated_time,
    :dispatch
  ]

  @doc """
  Initialize cascade state from a grid snapshot.

  The `dispatch` map is seeded from `p_max_mw * capacity_factor` for each
  generator, representing the initial operating point.
  """
  def init(snapshot, base_mva \\ 100.0) do
    total_load = Enum.sum(Enum.map(snapshot.loads, & &1.p_mw))
    dispatch = EconomicDispatch.dispatch(snapshot.generators, total_load)

    {_overloaded, raw_loading} = compute_base_overloads(snapshot, dispatch, base_mva)

    calibrated_lines = calibrate_ratings(snapshot.lines, raw_loading)

    calibrated_snapshot = %{snapshot | lines: calibrated_lines}
    {base_overloaded, base_loading} = compute_base_overloads(calibrated_snapshot, dispatch, base_mva)

    %__MODULE__{
      buses: snapshot.buses,
      lines: calibrated_lines,
      transformers: snapshot.transformers,
      generators: snapshot.generators,
      loads: snapshot.loads,
      water_facilities: Map.get(snapshot, :water_facilities, []),
      base_mva: base_mva,
      tripped_lines: MapSet.new(),
      tripped_generators: MapSet.new(),
      tripped_transformers: MapSet.new(),
      affected_water_facilities: MapSet.new(),
      base_overloaded: base_overloaded,
      base_line_loading: base_loading,
      events: [],
      step: 0,
      stable: false,
      solution: nil,
      simulated_time: 0.0,
      dispatch: dispatch
    }
  end

  defp compute_base_overloads(snapshot, dispatch, base_mva) do
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

      overloaded_set =
        solution.line_flows
        |> Enum.filter(fn {_key, flow} -> flow.loading_pct > 100.0 end)
        |> Enum.map(fn {key, _flow} -> key end)
        |> MapSet.new()

      {overloaded_set, base_loading}
    catch
      :throw, {:error, reason} ->
        Logger.warning("[CASCADE INIT] base solve failed: #{inspect(reason)}")
        {MapSet.new(), %{}}
      kind, reason ->
        Logger.error("[CASCADE INIT] base solve unexpected failure: #{kind} #{inspect(reason)}")
        {MapSet.new(), %{}}
    end
  end

  @doc """
  Calibrate line ratings so the base case has no overloads.
  Lines whose base-case flow exceeds their generic rating get their rating
  bumped so the base flow sits at 80% loading. This leaves 20% headroom
  for real failures to push them past 100%.
  """
  def calibrate_ratings(lines, base_loading) do
    Enum.map(lines, fn line ->
      key = {:line, line.id}
      base_pct = Map.get(base_loading, key, 0.0)

      if base_pct > 80.0 and line.rating_a_mva != nil and line.rating_a_mva > 0 do
        new_rating = line.rating_a_mva * base_pct / 80.0
        %{line | rating_a_mva: new_rating}
      else
        line
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
      events: [%{step: 0, component_type: "transmission_line", component_id: line_id,
                  failure_cause: "manual_trip", details: %{}} | state.events]
    }
    run_cascade(state)
  end

  @doc """
  Trip a generator and run cascade.
  Performs redispatch to cover the lost generation before running the cascade loop.
  """
  def trip_generator(%__MODULE__{} = state, gen_id) do
    lost_mw = Map.get(state.dispatch, gen_id, 0.0)

    state = %{state |
      tripped_generators: MapSet.put(state.tripped_generators, gen_id),
      events: [%{step: 0, component_type: "generator", component_id: gen_id,
                  failure_cause: "manual_trip", details: %{}} | state.events]
    }

    state = redispatch(state, lost_mw, state.generators, state.loads)

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
  def redispatch(%__MODULE__{} = state, deficit_mw, _generators, _loads)
      when deficit_mw <= 0.0 do
    state
  end

  def redispatch(%__MODULE__{} = state, deficit_mw, _generators, _loads) do
    {new_dispatch, remaining} =
      EconomicDispatch.redispatch(
        state.dispatch,
        state.generators,
        state.tripped_generators,
        deficit_mw
      )

    state = %{state | dispatch: new_dispatch}

    if remaining > 0.5 do
      trigger_ufls_for_deficit(state, remaining)
    else
      state
    end
  end

  defp trigger_ufls_for_deficit(state, deficit_mw) do
    total_load = Enum.sum(Enum.map(state.loads, & &1.p_mw))
    total_gen =
      state.generators
      |> Enum.reject(&MapSet.member?(state.tripped_generators, &1.id))
      |> Enum.map(fn g -> Map.get(state.dispatch, g.id, 0.0) end)
      |> Enum.sum()

    online_gens =
      state.generators
      |> Enum.reject(&MapSet.member?(state.tripped_generators, &1.id))

    {shed_loads, shed_events} =
      LoadShedding.apply_ufls(state.loads, online_gens, total_gen, total_load)

    {shed_loads, shed_events} =
      if deficit_mw > 0 do
        shed_so_far =
          Enum.sum(Enum.map(shed_events, fn e -> Map.get(e.details, :shed_mw, 0.0) end))

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

    %{state |
      loads: updated_loads,
      events: events_with_step ++ state.events
    }
  end

  defp do_cascade(%{step: step} = state, step_results, _callback) when step >= @max_steps do
    {%{state | stable: false}, Enum.reverse(step_results)}
  end

  defp do_cascade(state, step_results, callback) do
    state = %{state | step: state.step + 1}

    active_lines = Enum.reject(state.lines, &MapSet.member?(state.tripped_lines, &1.id))
    active_xfmrs = Enum.reject(state.transformers, &MapSet.member?(state.tripped_transformers, &1.id))
    active_gens = Enum.reject(state.generators, &MapSet.member?(state.tripped_generators, &1.id))

    dispatched_gens = apply_dispatch(active_gens, state.dispatch)

    bus_ids = Enum.map(state.buses, & &1.id)
    islands = IslandDetector.detect(bus_ids, active_lines, active_xfmrs)

    {non_thermal_trips, island_results, updated_loads, timed_overloads} =
      solve_islands_timed(islands, state.buses, active_lines, active_xfmrs,
                          dispatched_gens, state.loads, state.base_mva,
                          state.base_overloaded)

    {water_trips, newly_affected} = check_water_facility_impacts(
      state.water_facilities, state.affected_water_facilities, islands,
      active_gens, state.buses
    )

    if Enum.empty?(non_thermal_trips) and Enum.empty?(timed_overloads) do
      step_result = %{
        step: state.step,
        simulated_time: state.simulated_time,
        islands: length(islands),
        trips: water_trips,
        water_facility_ids: MapSet.to_list(MapSet.union(state.affected_water_facilities, newly_affected)),
        solution: island_results
      }
      if callback, do: callback.(step_result)

      {%{state | stable: true, loads: updated_loads,
         affected_water_facilities: MapSet.union(state.affected_water_facilities, newly_affected)},
       Enum.reverse([step_result | step_results])}
    else
      state = apply_trips(state, non_thermal_trips)
      state = %{state | loads: updated_loads}

      {tripped_component, trip_time_s} = pick_fastest_trip(timed_overloads)

      {thermal_trips, state} =
        if tripped_component do
          {[tripped_component],
           %{state | simulated_time: state.simulated_time + trip_time_s}}
        else
          {[], state}
        end

      all_trips_this_step = non_thermal_trips ++ thermal_trips ++ water_trips
      state = %{state | affected_water_facilities: MapSet.union(state.affected_water_facilities, newly_affected)}

      step_result = %{
        step: state.step,
        simulated_time: state.simulated_time,
        islands: length(islands),
        trips: all_trips_this_step,
        water_facility_ids: MapSet.to_list(state.affected_water_facilities),
        solution: island_results
      }

      if callback, do: callback.(step_result)
      step_results = [step_result | step_results]

      if Enum.empty?(thermal_trips) and Enum.empty?(non_thermal_trips) do
        {%{state | stable: true}, Enum.reverse(step_results)}
      else
        state = apply_trips(state, thermal_trips)

        state = maybe_redispatch_after_trip(state)

        do_cascade(state, step_results, callback)
      end
    end
  end

  defp maybe_redispatch_after_trip(state) do
    active_gens = Enum.reject(state.generators, &MapSet.member?(state.tripped_generators, &1.id))

    total_dispatch =
      active_gens
      |> Enum.map(fn g -> Map.get(state.dispatch, g.id, 0.0) end)
      |> Enum.sum()

    total_load = Enum.sum(Enum.map(state.loads, & &1.p_mw))
    deficit = total_load - total_dispatch

    if deficit > 0.5 do
      redispatch(state, deficit, state.generators, state.loads)
    else
      state
    end
  end

  defp solve_islands_timed(islands, buses, lines, transformers, generators, loads, base_mva, base_overloaded) do
    Enum.reduce(islands, {[], [], loads, []}, fn island, {trips, results, lds, overloads} ->
      island_set = island
      island_buses = Enum.filter(buses, &MapSet.member?(island_set, &1.id))
      island_lines = Enum.filter(lines, fn l ->
        MapSet.member?(island_set, l.from_bus_id) and MapSet.member?(island_set, l.to_bus_id)
      end)
      island_xfmrs = Enum.filter(transformers, fn t ->
        MapSet.member?(island_set, t.from_bus_id) and MapSet.member?(island_set, t.to_bus_id)
      end)
      island_gens = Enum.filter(generators, &MapSet.member?(island_set, &1.bus_id))
      island_loads = Enum.filter(lds, &MapSet.member?(island_set, &1.bus_id))

      if length(island_buses) < 2 or Enum.empty?(island_gens) do
        new_trips = Enum.map(island_loads, fn load ->
          %{component_type: "load", component_id: load.id,
            failure_cause: "island_blackout", details: %{}}
        end)
        {trips ++ new_trips, results, lds, overloads}
      else
        gen_mw = Enum.sum(Enum.map(island_gens, fn g ->
          g.p_max_mw * (g.capacity_factor || 1.0)
        end))
        load_mw = Enum.sum(Enum.map(island_loads, & &1.p_mw))

        if load_mw > gen_mw do
          {shed_loads, shed_events} =
            LoadShedding.apply_ufls(island_loads, island_gens, gen_mw, load_mw)

          shed_map = Map.new(shed_loads, &{&1.id, &1})
          lds = Enum.map(lds, fn l -> Map.get(shed_map, l.id, l) end)

          {trips ++ shed_events, results, lds, overloads}
        else
          snapshot = %{
            buses: island_buses, lines: island_lines,
            transformers: island_xfmrs, generators: island_gens,
            loads: island_loads
          }

          try do
            solution = DCPowerFlow.solve(snapshot, base_mva: base_mva)

            timed = compute_timed_overloads(solution.line_flows, base_overloaded)

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

            {trips ++ voltage_trips, [solution | results], lds,
             overloads ++ timed ++ zone3_timed}
          catch
            kind, reason ->
              Logger.warning("island solve failed: #{kind} #{inspect(reason)}")
              {trips, results, lds, overloads}
          end
        end
      end
    end)
  end

  defp compute_timed_overloads(line_flows, _base_overloaded \\ MapSet.new()) do
    line_flows
    |> Enum.filter(fn {{_type, _id}, flow} ->
      flow.loading_pct > 100.0
    end)
    |> Enum.map(fn {{type, id}, flow} ->
      trip_time = Protection.overcurrent_trip_time(flow.loading_pct)
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
          %{st |
            tripped_generators: MapSet.put(st.tripped_generators, trip.component_id),
            events: [event | st.events]
          }
        _ ->
          %{st | events: [event | st.events]}
      end
    end)
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
end
