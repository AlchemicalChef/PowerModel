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
    :datacenters,
    :base_mva,
    :tripped_lines,
    :tripped_generators,
    :tripped_transformers,
    :affected_water_facilities,
    :affected_datacenters,
    :base_overloaded,
    :base_line_categories,
    :base_line_loading,
    :events,
    :step,
    :stable,
    :solution,
    :simulated_time,
    :dispatch,
    :bus_ba,
    :original_load_mw,
    :shed_load_mw,
    :blackout_load_mw,
    relay_elapsed: %{}
  ]

  @doc """
  Initialize cascade state from a grid snapshot.

  The `dispatch` map is seeded from `p_max_mw * capacity_factor` for each
  generator, representing the initial operating point.
  """
  def init(snapshot, base_mva \\ 100.0) do
    # Dispatch is balanced PER ISLAND: snapshots may contain several
    # electrically separate systems (Eastern/Western/ERCOT), and generation
    # in one never serves load in another.
    islands =
      IslandDetector.detect(
        Enum.map(snapshot.buses, & &1.id),
        snapshot.lines,
        Map.get(snapshot, :transformers, [])
      )

    dispatch = balance_dispatch_per_island(islands, snapshot.generators, snapshot.loads)

    # Solve base case to identify lines already overloaded due to model limitations.
    # These are excluded from cascade trip consideration since they represent
    # impedance estimation errors, not actual overloads.
    {base_overloaded, base_line_categories, base_line_loading} =
      compute_base_overloads(snapshot, dispatch, base_mva)

    %__MODULE__{
      buses: snapshot.buses,
      lines: snapshot.lines,
      transformers: Map.get(snapshot, :transformers, []),
      generators: snapshot.generators,
      loads: snapshot.loads,
      water_facilities: Map.get(snapshot, :water_facilities, []),
      datacenters: Map.get(snapshot, :datacenters, []),
      base_mva: base_mva,
      tripped_lines: MapSet.new(),
      tripped_generators: MapSet.new(),
      tripped_transformers: MapSet.new(),
      affected_water_facilities: MapSet.new(),
      affected_datacenters: MapSet.new(),
      base_overloaded: base_overloaded,
      base_line_categories: base_line_categories,
      base_line_loading: base_line_loading,
      events: [],
      step: 0,
      stable: false,
      solution: nil,
      simulated_time: 0.0,
      relay_elapsed: %{},
      dispatch: dispatch,
      bus_ba: Map.new(snapshot.buses, &{&1.id, Map.get(&1, :balancing_authority_id)}),
      original_load_mw: Enum.sum(Enum.map(snapshot.loads, & &1.p_mw)),
      shed_load_mw: 0.0,
      blackout_load_mw: 0.0
    }
  end

  @doc """
  Consumption accounting for the current cascade state.

  Conservation invariant: served + shed + blackout == original (within
  rounding), so the UI can always present a balance that adds up.
  """
  def balance(%__MODULE__{} = state) do
    active_gens = Enum.reject(state.generators, &MapSet.member?(state.tripped_generators, &1.id))

    %{
      original_load_mw: state.original_load_mw,
      served_load_mw: Enum.sum(Enum.map(state.loads, & &1.p_mw)),
      shed_load_mw: state.shed_load_mw,
      blackout_load_mw: state.blackout_load_mw,
      dispatched_gen_mw: Enum.sum(Enum.map(active_gens, &Map.get(state.dispatch, &1.id, 0.0))),
      online_capacity_mw: Enum.sum(Enum.map(active_gens, & &1.p_max_mw))
    }
  end

  defp compute_base_overloads(snapshot, dispatch, base_mva) do
    dispatched_gens =
      Enum.map(snapshot.generators, fn g ->
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
      solution = DCPowerFlow.solve_islands(base_snapshot, base_mva: base_mva)

      # Overloaded set (>100%) for cascade trip filtering
      overloaded =
        solution.line_flows
        |> Enum.filter(fn {_key, flow} -> flow.loading_pct > 100.0 end)
        |> Enum.map(fn {{type, id}, _flow} -> {type, id} end)
        |> MapSet.new()

      # Category map for ALL lines with significant loading
      # Used to filter frontend payloads so only WORSENED lines are shown
      # 3=overloaded(>100%), 2=stressed(75-100%), 1=rerouted(30-75%)
      categories =
        solution.line_flows
        |> Enum.filter(fn {_key, flow} -> flow.loading_pct >= 30.0 end)
        |> Map.new(fn {key, flow} ->
          cat =
            cond do
              flow.loading_pct > 100.0 -> 3
              flow.loading_pct >= 75.0 -> 2
              true -> 1
            end

          {key, cat}
        end)

      # Per-branch base loading so post-failure payloads can surface flow
      # redistribution (delta vs base), not just category jumps.
      loading = Map.new(solution.line_flows, fn {key, flow} -> {key, flow.loading_pct} end)

      {overloaded, categories, loading}
    rescue
      e ->
        Logger.warning("base-case solve raised #{Exception.message(e)}; no base filtering")
        {MapSet.new(), %{}, %{}}
    catch
      thrown ->
        Logger.warning("base-case solve threw #{inspect(thrown)}; no base filtering")
        {MapSet.new(), %{}, %{}}
    end
  end

  # Balance dispatch independently within each electrical island and merge.
  defp balance_dispatch_per_island(islands, generators, loads) do
    Enum.reduce(islands, %{}, fn island, dispatch ->
      island_gens = Enum.filter(generators, &MapSet.member?(island, &1.bus_id))
      island_loads = Enum.filter(loads, &MapSet.member?(island, &1.bus_id))
      Map.merge(dispatch, balance_dispatch(island_gens, island_loads))
    end)
  end

  # Scale generator dispatch to match total load within p_max limits.
  # Capacity factor is used for ordering (baseload units dispatch first)
  # but all generators can run up to p_max if needed.
  defp balance_dispatch(generators, loads) do
    total_load = Enum.sum(Enum.map(loads, & &1.p_mw))
    total_capacity = Enum.sum(Enum.map(generators, & &1.p_max_mw))

    if total_capacity <= 0 or total_load <= 0 do
      Map.new(generators, fn g -> {g.id, 0.0} end)
    else
      # Dispatch ratio: what fraction of max capacity do we need?
      # Cap at 0.95 to leave some headroom for the slack bus
      ratio = min(total_load / total_capacity, 0.95)

      Map.new(generators, fn g ->
        # Each generator dispatches proportionally to its capacity
        {g.id, g.p_max_mw * ratio}
      end)
    end
  end

  @doc """
  Trip a transmission line and run cascade.
  Returns {final_state, all_step_results} for streaming.
  """
  def trip_line(%__MODULE__{} = state, line_id) do
    state = %{
      state
      | tripped_lines: MapSet.put(state.tripped_lines, line_id),
        events: [
          %{
            step: 0,
            component_type: "transmission_line",
            component_id: line_id,
            failure_cause: "manual_trip",
            details: %{}
          }
          | state.events
        ]
    }

    run_cascade(state)
  end

  @doc """
  Trip a transformer and run cascade.
  Returns {final_state, all_step_results} for streaming.
  """
  def trip_transformer(%__MODULE__{} = state, xfmr_id) do
    state = %{
      state
      | tripped_transformers: MapSet.put(state.tripped_transformers, xfmr_id),
        events: [
          %{
            step: 0,
            component_type: "transformer",
            component_id: xfmr_id,
            failure_cause: "manual_trip",
            details: %{}
          }
          | state.events
        ]
    }

    run_cascade(state)
  end

  @doc """
  Trip a generator and run cascade.
  Performs redispatch to cover the lost generation before running the cascade loop.
  """
  def trip_generator(%__MODULE__{} = state, gen_id) do
    # MW lost from this generator. Its dispatch entry is zeroed immediately so
    # a repeated trip (or any later read) cannot double-count the loss.
    lost_mw =
      if MapSet.member?(state.tripped_generators, gen_id) do
        0.0
      else
        Map.get(state.dispatch, gen_id, 0.0)
      end

    gen = Enum.find(state.generators, &(&1.id == gen_id))

    state = %{
      state
      | tripped_generators: MapSet.put(state.tripped_generators, gen_id),
        dispatch: Map.put(state.dispatch, gen_id, 0.0),
        events: [
          %{
            step: 0,
            component_type: "generator",
            component_id: gen_id,
            failure_cause: "manual_trip",
            details: %{}
          }
          | state.events
        ]
    }

    # Redispatch within the tripped generator's OWN island only -- and within
    # that island, the unit's own balancing authority responds first (its
    # contingency reserves), with the rest of the island as emergency backup.
    state =
      case gen && island_containing(state, gen.bus_id) do
        nil ->
          state

        island ->
          origin_ba = Map.get(state.bus_ba || %{}, gen.bus_id)
          redispatch(state, lost_mw, island, origin_ba)
      end

    run_cascade(state)
  end

  @doc """
  Run cascade loop until stable or max steps reached.
  Yields each step result for streaming via callback.
  """
  def run_cascade(state, callback \\ nil) do
    do_cascade(state, [], callback)
  end

  # ---------------------------------------------------------------------------
  # Redispatch
  # ---------------------------------------------------------------------------

  @doc """
  Redistribute `deficit_mw` (positive = need more generation) among online
  generators in `island_bus_set`, mirroring how reserves are actually
  activated:

  1. **Origin BA** -- when `origin_ba` is known, contingency reserves inside
     the balancing authority that lost the generation respond first (ACE
     restoration / secondary control).
  2. **Emergency assistance** -- any remaining deficit is covered by headroom
     across the rest of the SAME island. Never beyond it: an asynchronous
     neighbor interconnection cannot supply this power.
  3. **UFLS** -- a deficit the whole island cannot cover sheds load, also
     confined to the island (frequency is an island-wide quantity).

  Returns the updated cascade state with modified `dispatch` (and possibly
  modified `loads` / `events` when UFLS fires).
  """
  def redispatch(state, deficit_mw, island_bus_set, origin_ba \\ nil)

  def redispatch(%__MODULE__{} = state, deficit_mw, _island_bus_set, _origin_ba)
      when deficit_mw <= 0.0 do
    state
  end

  def redispatch(%__MODULE__{} = state, deficit_mw, island_bus_set, origin_ba) do
    # Tier 1: reserves within the origin balancing authority
    {state, remaining} =
      if origin_ba do
        ba_gens =
          state
          |> online_island_gens(island_bus_set)
          |> Enum.filter(fn g -> Map.get(state.bus_ba || %{}, g.bus_id) == origin_ba end)

        apply_headroom(state, deficit_mw, ba_gens)
      else
        {state, deficit_mw}
      end

    # Tier 2: emergency assistance from all remaining island headroom
    {state, remaining} =
      if remaining > 0.5 do
        apply_headroom(state, remaining, online_island_gens(state, island_bus_set))
      else
        {state, remaining}
      end

    # Tier 3: island-wide UFLS for anything still uncovered
    if remaining > 0.5 do
      trigger_ufls_for_deficit(state, remaining, island_bus_set)
    else
      state
    end
  end

  # Raise the given generators proportionally to their headroom to cover as
  # much of `deficit_mw` as possible. Returns `{state, remaining_deficit}`.
  defp apply_headroom(state, deficit_mw, gens) do
    headrooms =
      Enum.map(gens, fn g ->
        current = Map.get(state.dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))
        {g.id, max(g.p_max_mw - current, 0.0), current}
      end)

    total_headroom =
      headrooms
      |> Enum.map(fn {_id, h, _current} -> h end)
      |> Enum.sum()

    if total_headroom <= 0.0 do
      {state, deficit_mw}
    else
      dispatchable = min(deficit_mw, total_headroom)
      fraction = dispatchable / total_headroom

      new_dispatch =
        Enum.reduce(headrooms, state.dispatch, fn {gen_id, headroom, fallback_current}, d ->
          increase = headroom * fraction
          current = Map.get(d, gen_id, fallback_current)
          Map.put(d, gen_id, current + increase)
        end)

      {%{state | dispatch: new_dispatch}, deficit_mw - dispatchable}
    end
  end

  defp online_island_gens(state, island_bus_set) do
    state.generators
    |> Enum.reject(&MapSet.member?(state.tripped_generators, &1.id))
    |> Enum.filter(&MapSet.member?(island_bus_set, &1.bus_id))
  end

  # The active-topology island containing a bus (nil when the bus is unknown).
  defp island_containing(state, bus_id) do
    state
    |> active_topology_islands()
    |> Enum.find(&MapSet.member?(&1, bus_id))
  end

  defp active_topology_islands(state) do
    active_lines = Enum.reject(state.lines, &MapSet.member?(state.tripped_lines, &1.id))

    active_xfmrs =
      Enum.reject(state.transformers, &MapSet.member?(state.tripped_transformers, &1.id))

    IslandDetector.detect(Enum.map(state.buses, & &1.id), active_lines, active_xfmrs)
  end

  # Trigger UFLS to cover an unresolvable generation deficit within one island.
  defp trigger_ufls_for_deficit(state, deficit_mw, island_bus_set) do
    island_loads = Enum.filter(state.loads, &MapSet.member?(island_bus_set, &1.bus_id))
    online_gens = online_island_gens(state, island_bus_set)

    total_load = Enum.sum(Enum.map(island_loads, & &1.p_mw))

    total_gen =
      online_gens
      |> Enum.map(fn g -> Map.get(state.dispatch, g.id, 0.0) end)
      |> Enum.sum()

    {shed_loads, ufls_events} =
      LoadShedding.apply_ufls(
        island_loads,
        apply_dispatch(online_gens, state.dispatch),
        total_gen,
        total_load
      )

    # If UFLS didn't shed enough (e.g. frequency still above threshold),
    # force-shed ONLY the remaining gap against the post-UFLS loads. Both
    # rounds' events are kept so the conservation accounting stays exact.
    ufls_shed_mw =
      Enum.sum(Enum.map(ufls_events, fn e -> Map.get(e.details, :shed_mw, 0.0) end))

    remaining_mw = deficit_mw - ufls_shed_mw
    current_total = total_load - ufls_shed_mw

    {shed_loads, force_events} =
      if remaining_mw > 0.5 and current_total > 0 do
        fraction = min(remaining_mw / current_total, 1.0)

        # gen/load args express exactly the remaining gap so the internal cap
        # cannot re-shed what round 1 already removed
        LoadShedding.apply_proportional_shedding(
          shed_loads,
          fraction,
          current_total - remaining_mw,
          current_total
        )
      else
        {shed_loads, []}
      end

    shed_events = ufls_events ++ force_events

    shed_map = Map.new(shed_loads, &{&1.id, &1})
    updated_loads = Enum.map(state.loads, fn l -> Map.get(shed_map, l.id, l) end)

    events_with_step = Enum.map(shed_events, &Map.put(&1, :step, state.step))

    event_shed_mw =
      Enum.sum(Enum.map(shed_events, fn e -> Map.get(e.details, :shed_mw, 0.0) end))

    %{
      state
      | loads: updated_loads,
        events: events_with_step ++ state.events,
        shed_load_mw: state.shed_load_mw + event_shed_mw
    }
  end

  # ---------------------------------------------------------------------------
  # Timed cascade loop
  # ---------------------------------------------------------------------------

  defp do_cascade(%{step: step} = state, step_results, _callback) when step >= @max_steps do
    {%{state | stable: false}, Enum.reverse(step_results)}
  end

  defp do_cascade(state, step_results, callback) do
    state = %{state | step: state.step + 1}

    # Get active topology (exclude tripped components)
    active_lines = Enum.reject(state.lines, &MapSet.member?(state.tripped_lines, &1.id))

    active_xfmrs =
      Enum.reject(state.transformers, &MapSet.member?(state.tripped_transformers, &1.id))

    active_gens = Enum.reject(state.generators, &MapSet.member?(state.tripped_generators, &1.id))

    # Build dispatched generators -- override p_max_mw/capacity_factor to match dispatch
    dispatched_gens = apply_dispatch(active_gens, state.dispatch)

    # Detect islands
    bus_ids = Enum.map(state.buses, & &1.id)
    islands = IslandDetector.detect(bus_ids, active_lines, active_xfmrs)

    # Solve each island and collect ALL overloaded components with trip times
    {non_thermal_trips, island_results, updated_loads, timed_overloads, step_shed_mw,
     step_blackout_mw, dispatch_updates} =
      solve_islands_timed(
        islands,
        state.buses,
        active_lines,
        active_xfmrs,
        dispatched_gens,
        state.loads,
        state.base_mva,
        state.base_overloaded
      )

    state = %{state | dispatch: Map.merge(state.dispatch, dispatch_updates)}

    # Facilities on dead-island buses lose power (water + datacenters)
    dead_bus_ids = dead_island_buses(islands, active_gens)

    {water_trips, newly_affected} =
      check_facility_power_loss(
        state.water_facilities,
        state.affected_water_facilities,
        dead_bus_ids,
        "water_facility",
        &water_facility_details/1
      )

    {datacenter_trips, newly_affected_dcs} =
      check_facility_power_loss(
        state.datacenters,
        state.affected_datacenters,
        dead_bus_ids,
        "datacenter",
        &datacenter_details/1
      )

    facility_trips =
      Enum.map(water_trips ++ datacenter_trips, &Map.put(&1, :step, state.step))

    state = %{state | events: facility_trips ++ state.events}

    if Enum.empty?(non_thermal_trips) and Enum.empty?(timed_overloads) do
      # Stable -- no trips of any kind
      state = %{
        state
        | stable: true,
          loads: updated_loads,
          shed_load_mw: state.shed_load_mw + step_shed_mw,
          blackout_load_mw: state.blackout_load_mw + step_blackout_mw,
          relay_elapsed: %{},
          affected_water_facilities:
            MapSet.union(state.affected_water_facilities, newly_affected),
          affected_datacenters: MapSet.union(state.affected_datacenters, newly_affected_dcs)
      }

      step_result = %{
        step: state.step,
        simulated_time: state.simulated_time,
        islands: length(islands),
        trips: facility_trips,
        water_facility_ids: MapSet.to_list(state.affected_water_facilities),
        datacenter_ids: MapSet.to_list(state.affected_datacenters),
        solution: island_results,
        balance: balance(state)
      }

      if callback, do: callback.(step_result)

      {state, Enum.reverse([step_result | step_results])}
    else
      # Process non-thermal trips immediately (blackouts, UFLS)
      state = apply_trips(state, non_thermal_trips)

      state = %{
        state
        | loads: updated_loads,
          shed_load_mw: state.shed_load_mw + step_shed_mw,
          blackout_load_mw: state.blackout_load_mw + step_blackout_mw
      }

      # For thermal/zone3 overloads: trip ONLY the first relay to finish timing.
      # Every currently overloaded branch accrues the same wall-clock advance.
      {tripped_component, time_advance_s, relay_elapsed} =
        advance_relay_timers(timed_overloads, state.relay_elapsed)

      state = %{state | relay_elapsed: relay_elapsed}

      {thermal_trips, state} =
        if tripped_component do
          {[tripped_component], %{state | simulated_time: state.simulated_time + time_advance_s}}
        else
          {[], state}
        end

      all_trips_this_step = non_thermal_trips ++ thermal_trips ++ facility_trips

      state = %{
        state
        | affected_water_facilities:
            MapSet.union(state.affected_water_facilities, newly_affected),
          affected_datacenters: MapSet.union(state.affected_datacenters, newly_affected_dcs)
      }

      step_result = %{
        step: state.step,
        simulated_time: state.simulated_time,
        islands: length(islands),
        trips: all_trips_this_step,
        water_facility_ids: MapSet.to_list(state.affected_water_facilities),
        datacenter_ids: MapSet.to_list(state.affected_datacenters),
        solution: island_results,
        balance: balance(state)
      }

      if callback, do: callback.(step_result)
      step_results = [step_result | step_results]

      if Enum.empty?(thermal_trips) and Enum.empty?(non_thermal_trips) do
        {%{state | stable: true}, Enum.reverse(step_results)}
      else
        # Apply thermal trip
        state = apply_trips(state, thermal_trips)

        # Redispatch after trip (cover any generation/load imbalance)
        state = maybe_redispatch_after_trip(state)

        do_cascade(state, step_results, callback)
      end
    end
  end

  # After a line/component trips, recompute generation-load balance PER
  # ISLAND and rebalance within each: deficits raise reserves (or shed),
  # SURPLUSES curtail generation. An island split leaves the exporting half
  # over-dispatched -- without curtailment that surplus becomes a phantom
  # sink at the slack bus, creating fictitious flows that trip healthy lines.
  # Islands without online generation are skipped -- their loads are
  # accounted as blackouts by the island solver, not as UFLS shedding.
  defp maybe_redispatch_after_trip(state) do
    state
    |> active_topology_islands()
    |> Enum.reduce(state, fn island, st ->
      island_gens = online_island_gens(st, island)

      if island_gens == [] do
        st
      else
        island_dispatch =
          island_gens
          |> Enum.map(fn g -> Map.get(st.dispatch, g.id, 0.0) end)
          |> Enum.sum()

        island_load =
          st.loads
          |> Enum.filter(&MapSet.member?(island, &1.bus_id))
          |> Enum.map(& &1.p_mw)
          |> Enum.sum()

        deficit = island_load - island_dispatch

        cond do
          deficit > 0.5 -> redispatch(st, deficit, island)
          deficit < -0.5 -> curtail_island(st, island_gens, island_dispatch, island_load)
          true -> st
        end
      end
    end)
  end

  # Scale an island's generation down proportionally to match its load.
  defp curtail_island(state, island_gens, island_dispatch, island_load)
       when island_dispatch > 0.0 do
    factor = max(island_load, 0.0) / island_dispatch

    new_dispatch =
      Enum.reduce(island_gens, state.dispatch, fn g, d ->
        Map.update(d, g.id, 0.0, &(&1 * factor))
      end)

    %{state | dispatch: new_dispatch}
  end

  defp curtail_island(state, _gens, _dispatch, _load), do: state

  # ---------------------------------------------------------------------------
  # Island solving (timed variant)
  #
  # Instead of returning thermal trips directly, this collects all overloaded
  # components with their inverse-time trip times so the caller can pick the
  # single fastest-to-trip component.
  # ---------------------------------------------------------------------------

  defp solve_islands_timed(
         islands,
         buses,
         lines,
         transformers,
         generators,
         loads,
         base_mva,
         base_overloaded
       ) do
    Enum.reduce(islands, {[], [], loads, [], 0.0, 0.0, %{}}, fn island,
                                                                {trips, results, lds, overloads,
                                                                 shed_mw, blackout_mw,
                                                                 dispatch_updates} ->
      island_set = island
      island_buses = Enum.filter(buses, &MapSet.member?(island_set, &1.id))

      island_lines =
        Enum.filter(lines, fn l ->
          MapSet.member?(island_set, l.from_bus_id) and MapSet.member?(island_set, l.to_bus_id)
        end)

      island_xfmrs =
        Enum.filter(transformers, fn t ->
          MapSet.member?(island_set, t.from_bus_id) and MapSet.member?(island_set, t.to_bus_id)
        end)

      island_gens = Enum.filter(generators, &MapSet.member?(island_set, &1.bus_id))
      island_loads = Enum.filter(lds, &MapSet.member?(island_set, &1.bus_id))

      if island_dead?(island_buses, island_gens) do
        # Isolated bus or no generation -- all loads lost.
        # Only loads still carrying demand black out (already-zeroed loads were
        # accounted in an earlier step); their p_mw is zeroed so redispatch and
        # frequency simulation no longer see phantom demand.
        lost_loads = Enum.filter(island_loads, &(&1.p_mw > 0.0))

        new_trips =
          Enum.map(lost_loads, fn load ->
            %{
              component_type: "load",
              component_id: load.id,
              failure_cause: "island_blackout",
              details: %{lost_mw: load.p_mw}
            }
          end)

        lost_mw = Enum.sum(Enum.map(lost_loads, & &1.p_mw))
        lost_ids = MapSet.new(lost_loads, & &1.id)

        lds =
          Enum.map(lds, fn l ->
            if MapSet.member?(lost_ids, l.id), do: %{l | p_mw: 0.0, q_mvar: 0.0}, else: l
          end)

        {trips ++ new_trips, results, lds, overloads, shed_mw, blackout_mw + lost_mw,
         dispatch_updates}
      else
        # Check generation-load balance using dispatched values
        gen_mw =
          Enum.sum(
            Enum.map(island_gens, fn g ->
              g.p_max_mw * (g.capacity_factor || 1.0)
            end)
          )

        load_mw = Enum.sum(Enum.map(island_loads, & &1.p_mw))

        {island_gens, gen_mw, island_dispatch_updates} =
          if load_mw > gen_mw do
            raise_island_generation(island_gens, load_mw - gen_mw)
          else
            {island_gens, gen_mw, %{}}
          end

        dispatch_updates = Map.merge(dispatch_updates, island_dispatch_updates)

        # Available headroom is raised first. Apply UFLS only to any remaining
        # deficit, then ALWAYS power-flow solve the island with the raised
        # dispatch and post-shed loads. Skipping the solve would leave thermal /
        # voltage / zone-3 protection unevaluated in the deficient island.
        {lds, island_loads, shed_events, event_shed_mw} =
          if load_mw > gen_mw do
            {shed_loads, shed_events} =
              LoadShedding.apply_ufls(island_loads, island_gens, gen_mw, load_mw)

            shed_map = Map.new(shed_loads, &{&1.id, &1})
            lds = Enum.map(lds, fn l -> Map.get(shed_map, l.id, l) end)
            island_loads = Enum.map(island_loads, fn l -> Map.get(shed_map, l.id, l) end)

            event_shed_mw =
              Enum.sum(Enum.map(shed_events, fn e -> Map.get(e.details, :shed_mw, 0.0) end))

            {lds, island_loads, shed_events, event_shed_mw}
          else
            {lds, island_loads, [], 0.0}
          end

        # Run DC power flow
        snapshot = %{
          buses: island_buses,
          lines: island_lines,
          transformers: island_xfmrs,
          generators: island_gens,
          loads: island_loads
        }

        try do
          solution = DCPowerFlow.solve(snapshot, base_mva: base_mva)

          # Compute trip times for each overloaded branch (inverse-time curve)
          # Exclude lines already overloaded in the base case (model artifacts)
          timed = compute_timed_overloads(solution.line_flows, base_overloaded)

          voltage_trips =
            Protection.check_voltage_violations(
              solution.bus_ids,
              solution.vm_pu
            )

          # Zone 3 distance relay check (load encroachment)
          bus_index =
            solution.bus_ids
            |> Enum.with_index()
            |> Map.new()

          zone3_trips =
            Protection.check_zone3_encroachment(
              solution.line_flows,
              island_lines ++ island_xfmrs,
              island_buses,
              solution.vm_pu,
              solution.va_rad,
              bus_index
            )

          # Zone 3 trips are treated like fast thermal trips (trip time ~0.5s)
          zone3_timed =
            Enum.map(zone3_trips, fn t ->
              Map.put(t, :trip_time_s, 0.5)
            end)

          {trips ++ shed_events ++ voltage_trips, [solution | results], lds,
           overloads ++ timed ++ zone3_timed, shed_mw + event_shed_mw, blackout_mw,
           dispatch_updates}
        rescue
          e ->
            Logger.warning(
              "island solve raised #{Exception.message(e)}; island dropped from this step"
            )

            {trips ++ shed_events, results, lds, overloads, shed_mw + event_shed_mw, blackout_mw,
             dispatch_updates}
        catch
          thrown ->
            Logger.warning("island solve threw #{inspect(thrown)}; island dropped from this step")

            {trips ++ shed_events, results, lds, overloads, shed_mw + event_shed_mw, blackout_mw,
             dispatch_updates}
        end
      end
    end)
  end

  # Raise dispatched generation proportionally into physical nameplate headroom.
  # The returned generator shapes feed both UFLS/frequency and the DC solve,
  # while the update map is merged into the cascade state's persistent dispatch.
  defp raise_island_generation(generators, deficit_mw) do
    headrooms =
      Enum.map(generators, fn g ->
        current =
          Map.get(g, :p_dispatch_mw) ||
            g.p_max_mw * (Map.get(g, :capacity_factor) || 1.0)

        nameplate = Map.get(g, :p_nameplate_mw) || g.p_max_mw
        {g, current, nameplate, max(nameplate - current, 0.0)}
      end)

    total_headroom = Enum.sum(Enum.map(headrooms, fn {_g, _current, _nameplate, h} -> h end))

    if total_headroom <= 0.0 do
      {generators,
       Enum.sum(
         Enum.map(generators, fn g ->
           Map.get(g, :p_dispatch_mw) ||
             g.p_max_mw * (Map.get(g, :capacity_factor) || 1.0)
         end)
       ), %{}}
    else
      dispatchable = min(deficit_mw, total_headroom)
      fraction = dispatchable / total_headroom

      {raised_gens, dispatch_updates} =
        Enum.map_reduce(headrooms, %{}, fn {g, current, nameplate, headroom}, updates ->
          raised_dispatch = current + headroom * fraction

          raised_gen =
            %{g | p_max_mw: raised_dispatch, capacity_factor: 1.0}
            |> Map.put(:p_dispatch_mw, raised_dispatch)
            |> Map.put(:p_nameplate_mw, nameplate)

          {raised_gen, Map.put(updates, g.id, raised_dispatch)}
        end)

      raised_gen_mw =
        Enum.sum(Enum.map(raised_gens, &Map.fetch!(&1, :p_dispatch_mw)))

      {raised_gens, raised_gen_mw, dispatch_updates}
    end
  end

  # Compute trip time for each overloaded branch using Protection.overcurrent_trip_time/1.
  defp compute_timed_overloads(line_flows, base_overloaded) do
    line_flows
    |> Enum.filter(fn {{type, id}, flow} ->
      flow.loading_pct > 100.0 and not MapSet.member?(base_overloaded, {type, id})
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

  # Advance all concurrently overloaded relays by the remaining time of the
  # first relay to finish. A branch that is absent from `timed_overloads` has
  # fallen back to 100% loading or below and is dropped here: this model uses
  # an instantaneous thermal reset rather than retaining cooling memory.
  defp advance_relay_timers([], _relay_elapsed), do: {nil, 0.0, %{}}

  defp advance_relay_timers(timed_overloads, relay_elapsed) do
    overloads_with_remaining =
      Enum.map(timed_overloads, fn trip ->
        key = relay_key(trip)
        elapsed = Map.get(relay_elapsed, key, 0.0)
        {trip, remaining_trip_time(trip.trip_time_s, elapsed)}
      end)

    {fastest, remaining} =
      Enum.min_by(overloads_with_remaining, fn {_trip, remaining} ->
        trip_time_sort_value(remaining)
      end)

    case remaining do
      :infinity ->
        retained_elapsed =
          Map.new(overloads_with_remaining, fn {trip, _remaining} ->
            key = relay_key(trip)
            {key, Map.get(relay_elapsed, key, 0.0)}
          end)

        {nil, 0.0, retained_elapsed}

      time_advance_s ->
        advanced_elapsed =
          Map.new(overloads_with_remaining, fn {trip, _remaining} ->
            key = relay_key(trip)
            {key, Map.get(relay_elapsed, key, 0.0) + time_advance_s}
          end)

        {Map.delete(fastest, :trip_time_s), time_advance_s, advanced_elapsed}
    end
  end

  defp relay_key(trip), do: {trip.component_type, trip.component_id}

  defp remaining_trip_time(:infinity, _elapsed), do: :infinity
  defp remaining_trip_time(trip_time_s, elapsed), do: max(trip_time_s - elapsed, 0.0)

  defp trip_time_sort_value(:infinity), do: 1.0e30
  defp trip_time_sort_value(seconds), do: seconds

  # ---------------------------------------------------------------------------
  # Dispatch helpers
  # ---------------------------------------------------------------------------

  @doc """
  Active (non-tripped) generators with the current dispatch applied, shaped
  for the solvers (p_max_mw = dispatched MW, capacity_factor 1.0).

  Every solve of the cascade's network MUST use these: the pre-failure base
  case is computed from dispatched generation, so solving with raw nameplate
  capacities instead produces nationwide flow differences that masquerade as
  failure impact.
  """
  def dispatched_generators(%__MODULE__{} = state) do
    state.generators
    |> Enum.reject(&MapSet.member?(state.tripped_generators, &1.id))
    |> apply_dispatch(state.dispatch)
  end

  # Override generator maps so the DC solver sees the dispatched MW values.
  # We set capacity_factor to 1.0 and p_max_mw to the dispatched value so
  # the solver's P_inject = dispatch_mw / base_mva. The physical values ride
  # along as :p_dispatch_mw / :p_nameplate_mw so the frequency simulation
  # keeps real governor headroom and the machine-MVA inertia base (reading
  # the solver shape naively would zero both).
  defp apply_dispatch(generators, dispatch) do
    Enum.map(generators, fn g ->
      dispatched_mw = Map.get(dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))

      %{g | p_max_mw: dispatched_mw, capacity_factor: 1.0}
      |> Map.put(:p_dispatch_mw, dispatched_mw)
      |> Map.put(:p_nameplate_mw, g.p_max_mw)
    end)
  end

  # ---------------------------------------------------------------------------
  # Trip application
  # ---------------------------------------------------------------------------

  defp apply_trips(state, trips) do
    Enum.reduce(trips, state, fn trip, st ->
      event = Map.put(trip, :step, st.step)

      case trip.component_type do
        "transmission_line" ->
          %{
            st
            | tripped_lines: MapSet.put(st.tripped_lines, trip.component_id),
              events: [event | st.events]
          }

        "transformer" ->
          %{
            st
            | tripped_transformers: MapSet.put(st.tripped_transformers, trip.component_id),
              events: [event | st.events]
          }

        "generator" ->
          %{
            st
            | tripped_generators: MapSet.put(st.tripped_generators, trip.component_id),
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

  # ---------------------------------------------------------------------------
  # Facility power-loss detection (water facilities, datacenters)
  # ---------------------------------------------------------------------------

  # All bus IDs in islands the solver treats as dead — everything on these
  # buses is blacked out, including colocated facilities.
  defp dead_island_buses(islands, active_gens) do
    Enum.reduce(islands, MapSet.new(), fn island, acc ->
      island_gens = Enum.filter(active_gens, &MapSet.member?(island, &1.bus_id))

      if island_dead?(island, island_gens) do
        MapSet.union(acc, island)
      else
        acc
      end
    end)
  end

  defp island_dead?(island_buses_or_ids, island_gens) do
    Enum.count(island_buses_or_ids) < 2 or Enum.empty?(island_gens)
  end

  # Facilities on dead buses that aren't already marked lose power.
  # Returns {new_trip_events, newly_affected_ids_mapset}.
  defp check_facility_power_loss(
         facilities,
         already_affected,
         dead_bus_ids,
         component_type,
         details_fn
       ) do
    facilities
    |> Enum.filter(fn f ->
      f.bus_id != nil and
        MapSet.member?(dead_bus_ids, f.bus_id) and
        not MapSet.member?(already_affected, f.id)
    end)
    |> Enum.reduce({[], MapSet.new()}, fn f, {trips, ids} ->
      trip = %{
        component_type: component_type,
        component_id: f.id,
        failure_cause: "power_loss",
        details: details_fn.(f)
      }

      {[trip | trips], MapSet.put(ids, f.id)}
    end)
  end

  defp water_facility_details(wf) do
    %{name: wf.name, facility_type: wf.facility_type, power_mw: wf.power_consumption_mw}
  end

  defp datacenter_details(dc) do
    %{
      name: dc.name,
      facility_type: dc.facility_type,
      operator: dc.operator,
      power_mw: dc.power_mw
    }
  end
end
