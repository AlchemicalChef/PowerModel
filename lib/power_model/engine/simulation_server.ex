defmodule PowerModel.Engine.SimulationServer do
  @moduledoc """
  GenServer per active simulation session.
  Holds current topology, cached Y-bus, and cascade history.
  Orchestrates DC (fast) and AC (accurate) power flow solutions.

  Servers are `:temporary`: a crashed simulation is not silently restarted
  with an empty state (which would desync every subscribed client); the
  owning LiveView monitors the server and rebuilds on demand instead.
  Idle servers reap themselves after `@default_idle_timeout` without calls
  so abandoned browser sessions do not pin a full grid snapshot forever.
  """

  use GenServer, restart: :temporary

  require Logger

  alias PowerModel.Grid
  alias PowerModel.Solver.{DCPowerFlow, FDPF, Solution, Partition}
  alias PowerModel.Failure.Cascade

  defstruct [
    :sim_id,
    :interconnection_id,
    :snapshot,
    :cascade_state,
    :dc_solution,
    :ac_solution,
    :base_mva,
    :base_overloaded,
    :base_line_categories,
    :base_line_loading,
    :hour,
    :idle_timeout,
    :last_activity,
    epoch: 0
  ]

  # CAS-4: reap sim servers that have not received a call in this long.
  @default_idle_timeout 30 * 60 * 1000

  # Client API

  def start_link(opts) do
    sim_id = Keyword.fetch!(opts, :sim_id)
    GenServer.start_link(__MODULE__, opts, name: via(sim_id))
  end

  # Full-grid cascades re-solve three interconnection islands per step;
  # give the synchronous caller room (results stream via PubSub regardless).
  @trip_timeout 120_000

  def trip_branch(sim_id, line_id) do
    GenServer.call(via(sim_id), {:trip_branch, line_id}, @trip_timeout)
  end

  def trip_generator(sim_id, gen_id) do
    GenServer.call(via(sim_id), {:trip_generator, gen_id}, @trip_timeout)
  end

  def trip_transformer(sim_id, xfmr_id) do
    GenServer.call(via(sim_id), {:trip_transformer, xfmr_id}, @trip_timeout)
  end

  def get_state(sim_id) do
    GenServer.call(via(sim_id), :get_state, 30_000)
  end

  def reset(sim_id) do
    # Must queue behind (and survive) an in-flight trip call
    GenServer.call(via(sim_id), :reset, @trip_timeout)
  end

  # Server

  @impl true
  def init(opts) do
    sim_id = Keyword.fetch!(opts, :sim_id)
    interconnection_id = Keyword.get(opts, :interconnection_id)
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    idle_timeout = Keyword.get(opts, :idle_timeout, @default_idle_timeout)

    # ENE-1: when the caller does not choose an hour, default to the most
    # recent hour with real EIA-930 demand. An explicit `hour: nil` is an
    # explicit request for the synthetic baseline.
    hour =
      case Keyword.fetch(opts, :hour) do
        {:ok, h} -> h
        :error -> PowerModel.Demand.latest_demand_hour()
      end

    if is_nil(hour) do
      Logger.warning(
        "[sim #{sim_id}] no demand hour selected and/or no EIA-930 demand data " <>
          "loaded -- simulating on the synthetic BASELINE load (~2x real demand)"
      )
    end

    snapshot =
      if interconnection_id do
        Grid.get_grid_snapshot(interconnection_id, hour: hour)
      else
        Grid.get_full_grid_snapshot(hour: hour)
      end

    # The hour is what lets the cascade start from the measured EIA-930 unit
    # commitment instead of a proportional guess.
    cascade_state = Cascade.init(snapshot, base_mva, hour: hour)

    state = %__MODULE__{
      sim_id: sim_id,
      interconnection_id: interconnection_id,
      snapshot: snapshot,
      cascade_state: cascade_state,
      dc_solution: nil,
      ac_solution: nil,
      base_mva: base_mva,
      base_overloaded: cascade_state.base_overloaded,
      base_line_categories: cascade_state.base_line_categories,
      base_line_loading: cascade_state.base_line_loading,
      hour: hour,
      idle_timeout: idle_timeout,
      last_activity: System.monotonic_time(:millisecond)
    }

    # Run initial DC power flow
    if length(snapshot.buses) > 0 do
      send(self(), :initial_solve)
    end

    schedule_idle_check(idle_timeout)

    {:ok, state}
  end

  @impl true
  def handle_info(:initial_solve, state) do
    case solve_dc(state) do
      {:ok, solution} ->
        broadcast(state.sim_id, "dc_update", solution_payload(solution, state))
        {:noreply, %{state | dc_solution: solution}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:ac_result, epoch, solution}, state) do
    cond do
      epoch != state.epoch ->
        # Computed against a topology that no longer exists (the grid was
        # reset or re-tripped while the AC task ran). Stale -- discard, or it
        # would repaint pre-reset overloads onto a clean grid.
        Logger.info(
          "[sim #{state.sim_id}] discarding stale AC result (epoch #{epoch} != #{state.epoch})"
        )

        {:noreply, state}

      not solution.converged ->
        # A diverged AC solve carries fabricated flows; never paint it on the map.
        Logger.warning("[sim #{state.sim_id}] AC refinement did not converge; discarding")
        {:noreply, state}

      true ->
        # Epoch matched, so the AC ran against the CURRENT topology and the
        # active snapshot's load sum is the right expectation (SOL-2).
        audit_solution(solution, state.sim_id, snapshot_load_mw(active_snapshot(state)))
        broadcast(state.sim_id, "ac_update", solution_payload(solution, state))
        {:noreply, %{state | ac_solution: solution}}
    end
  end

  def handle_info(:idle_check, state) do
    idle_ms = System.monotonic_time(:millisecond) - state.last_activity

    if idle_ms >= state.idle_timeout do
      Logger.info(
        "[sim #{state.sim_id}] idle for #{div(idle_ms, 1000)}s (limit " <>
          "#{div(state.idle_timeout, 1000)}s); stopping"
      )

      {:stop, :normal, state}
    else
      schedule_idle_check(state.idle_timeout - idle_ms)
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:trip_branch, line_id}, _from, state) do
    state = touch(state)
    cascade = state.cascade_state

    cond do
      MapSet.member?(cascade.tripped_lines, line_id) ->
        # Re-tripping a dead component must be a no-op, not a fresh disturbance.
        {:reply, {:error, :already_tripped}, state}

      Enum.any?(cascade.lines, &(&1.id == line_id)) ->
        state = %{state | epoch: state.epoch + 1}
        broadcast_manual_trip(state, "transmission_line", line_id)
        {final_cascade, step_results} = Cascade.trip_line(cascade, line_id)
        run_and_broadcast_cascade(state, final_cascade, step_results)

      true ->
        # The clicked line is not part of the simulated component (e.g. a small
        # disconnected fragment). Tripping it would silently change nothing.
        Logger.warning(
          "[sim #{state.sim_id}] trip rejected: line #{line_id} not in simulated network"
        )

        {:reply, {:error, :not_in_network}, state}
    end
  end

  def handle_call({:trip_transformer, xfmr_id}, _from, state) do
    state = touch(state)
    cascade = state.cascade_state

    cond do
      MapSet.member?(cascade.tripped_transformers, xfmr_id) ->
        {:reply, {:error, :already_tripped}, state}

      Enum.any?(cascade.transformers, &(&1.id == xfmr_id)) ->
        state = %{state | epoch: state.epoch + 1}
        broadcast_manual_trip(state, "transformer", xfmr_id)
        {final_cascade, step_results} = Cascade.trip_transformer(cascade, xfmr_id)
        run_and_broadcast_cascade(state, final_cascade, step_results)

      true ->
        Logger.warning(
          "[sim #{state.sim_id}] trip rejected: transformer #{xfmr_id} not in simulated network"
        )

        {:reply, {:error, :not_in_network}, state}
    end
  end

  def handle_call({:trip_generator, gen_id}, _from, state) do
    state = touch(state)
    cascade = state.cascade_state

    cond do
      MapSet.member?(cascade.tripped_generators, gen_id) ->
        {:reply, {:error, :already_tripped}, state}

      Enum.any?(cascade.generators, &(&1.id == gen_id)) ->
        state = %{state | epoch: state.epoch + 1}
        broadcast_manual_trip(state, "generator", gen_id)
        {final_cascade, step_results} = Cascade.trip_generator(cascade, gen_id)
        run_and_broadcast_cascade(state, final_cascade, step_results)

      true ->
        Logger.warning(
          "[sim #{state.sim_id}] trip rejected: generator #{gen_id} not in simulated network"
        )

        {:reply, {:error, :not_in_network}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    state = touch(state)

    reply = %{
      sim_id: state.sim_id,
      interconnection_id: state.interconnection_id,
      cascade_step: state.cascade_state.step,
      stable: state.cascade_state.stable,
      tripped_lines: MapSet.to_list(state.cascade_state.tripped_lines),
      tripped_generators: MapSet.to_list(state.cascade_state.tripped_generators),
      events: state.cascade_state.events,
      has_dc_solution: state.dc_solution != nil,
      has_ac_solution: state.ac_solution != nil,
      hour: state.hour
    }

    {:reply, reply, state}
  end

  def handle_call(:reset, _from, state) do
    # CAS-13 / UI-C2: reply immediately -- the base-case rebuild (a full DC
    # solve) runs in a continue so the caller never blocks behind it. The
    # epoch bump lands NOW so any in-flight AC refinement from the pre-reset
    # topology is already stale by the time it reports.
    state = %{touch(state) | epoch: state.epoch + 1}
    {:reply, :ok, state, {:continue, :reset}}
  end

  @impl true
  def handle_continue(:reset, state) do
    cascade = Cascade.init(state.snapshot, state.base_mva, hour: state.hour)

    state = %{
      state
      | cascade_state: cascade,
        dc_solution: nil,
        ac_solution: nil,
        base_overloaded: cascade.base_overloaded,
        base_line_categories: cascade.base_line_categories,
        base_line_loading: cascade.base_line_loading
    }

    send(self(), :initial_solve)
    broadcast(state.sim_id, "reset", %{})
    {:noreply, state}
  end

  # Private

  # The user-injected failure itself must reach the map immediately: cascade
  # step payloads only carry trips DISCOVERED during the cascade, so without
  # this the clicked component would never be marked tripped.
  defp broadcast_manual_trip(state, component_type, component_id) do
    step = %{
      step: 0,
      simulated_time: 0.0,
      islands: 1,
      trips: [
        %{
          component_type: component_type,
          component_id: component_id,
          failure_cause: "manual_trip",
          details: %{}
        }
      ],
      water_facility_ids: [],
      datacenter_ids: [],
      solution: [],
      balance: nil
    }

    broadcast(state.sim_id, "cascade_step", cascade_step_payload(step, state))
  end

  defp run_and_broadcast_cascade(state, final_cascade, step_results) do
    Enum.each(step_results, fn step ->
      broadcast(state.sim_id, "cascade_step", cascade_step_payload(step, state))
    end)

    # Run DC on final state
    state = %{state | cascade_state: final_cascade}

    case solve_dc_from_cascade(state) do
      {:ok, solution} ->
        broadcast(state.sim_id, "dc_update", solution_payload(solution, state))
        state = %{state | dc_solution: solution}

        # Spawn AC refinement in background
        spawn_ac_refinement(state)

        broadcast(state.sim_id, "cascade_done", cascade_done_payload(step_results, final_cascade))

        {:reply, {:ok, step_results}, state}

      _ ->
        # Final repaint failed, but the cascade itself completed -- the UI
        # must still leave its "cascading" state.
        broadcast(state.sim_id, "cascade_done", cascade_done_payload(step_results, final_cascade))

        {:reply, {:ok, step_results}, state}
    end
  end

  @component_trip_types ~w(transmission_line transformer generator)

  defp cascade_done_payload(step_results, final_cascade) do
    %{
      steps: length(step_results),
      stable: final_cascade.stable,
      total_events: length(final_cascade.events),
      # CAS-8: the "Tripped" metric must count COMPONENT trips (lines,
      # transformers, generators), not every event -- a national cascade
      # emits one event per shed load, which is not "tripped equipment".
      tripped_count:
        Enum.count(final_cascade.events, &(&1.component_type in @component_trip_types)),
      balance: Cascade.balance(final_cascade)
    }
  end

  defp solve_dc(state) do
    try do
      snapshot = active_snapshot(state)
      solution = DCPowerFlow.solve_islands(snapshot, base_mva: state.base_mva)
      audit_solution(solution, state.sim_id, snapshot_load_mw(snapshot))
      {:ok, solution}
    rescue
      e ->
        Logger.warning("[sim #{state.sim_id}] DC solve raised: #{Exception.message(e)}")
        :error
    catch
      thrown ->
        Logger.warning("[sim #{state.sim_id}] DC solve threw: #{inspect(thrown)}")
        :error
    end
  end

  defp solve_dc_from_cascade(state) do
    try do
      snapshot = active_snapshot(state)
      solution = DCPowerFlow.solve_islands(snapshot, base_mva: state.base_mva)
      audit_solution(solution, state.sim_id, snapshot_load_mw(snapshot))
      {:ok, solution}
    rescue
      e ->
        Logger.warning(
          "[sim #{state.sim_id}] post-cascade DC solve raised: #{Exception.message(e)}"
        )

        :error
    catch
      thrown ->
        Logger.warning("[sim #{state.sim_id}] post-cascade DC solve threw: #{inspect(thrown)}")
        :error
    end
  end

  # Truthfulness checks on every solution: the energy balance must close
  # against the SNAPSHOT's demand (SOL-2 -- the solution-internal identity is
  # tautological: DC sets gen = load by construction, converged AC defines
  # gen = load + loss), and the slack bus must not be silently covering a
  # large scheduling gap (which produces artificial flows around the slack).
  # Served load plus dead-island load must account for every MW the snapshot
  # asked for; anything else means load silently vanished from the solve.
  @doc false
  def audit_solution(%Solution{} = solution, sim_id, expected_load_mw)
      when is_number(expected_load_mw) do
    tol_mw = max(1.0, 1.0e-4 * abs(expected_load_mw))
    result = Solution.energy_balance(solution, tol_mw, expected_load_mw)

    unless result.ok do
      Logger.warning(
        "[sim #{sim_id}] energy balance violated: gen - load - losses = " <>
          "#{Float.round(result.residual_mw * 1.0, 2)} MW; served + dead = " <>
          "#{Float.round(result.accounted_load_mw * 1.0, 1)} MW vs snapshot load " <>
          "#{Float.round(result.expected_load_mw * 1.0, 1)} MW (unaccounted " <>
          "#{Float.round(-result.load_residual_mw * 1.0, 1)} MW)"
      )
    end

    mismatch = solution.mismatch_abs_mw || abs(solution.mismatch_mw || 0.0)

    if is_number(mismatch) and
         mismatch > 0.05 * max(solution.total_load_mw || 0.0, 1.0) do
      Logger.warning(
        "[sim #{sim_id}] slack bus #{inspect(solution.slack_bus_id)} is covering " <>
          "#{Float.round(mismatch * 1.0, 1)} MW of unscheduled generation " <>
          "(scheduled #{Float.round((solution.scheduled_gen_mw || 0.0) * 1.0, 1)} MW, " <>
          "load #{Float.round((solution.total_load_mw || 0.0) * 1.0, 1)} MW) -- " <>
          "flows near the slack may be artificial"
      )
    end

    :ok
  end

  def audit_solution(_solution, _sim_id, _expected_load_mw), do: :ok

  defp snapshot_load_mw(snapshot) do
    Enum.reduce(snapshot.loads, 0.0, fn load, acc -> acc + (load.p_mw || 0.0) end)
  end

  # `FDPF.solve/2` picks its own path per island — dense Newton-Raphson below
  # its cutoff, fast-decoupled above — so this cap is no longer about which
  # solver runs. It is a budget: an AC attempt on the Eastern interconnection
  # is seconds of background CPU per step whether or not it converges, and this
  # covers all three interconnections with room to spare.
  @max_ac_island_buses 60_000

  defp spawn_ac_refinement(state) do
    server = self()
    epoch = state.epoch

    Task.start(fn ->
      snapshot = active_snapshot(state)
      # AC refinement is also per electrical island -- a Y-bus spanning
      # disconnected systems is singular.
      {subs, dead} = Partition.split(snapshot)

      {tractable, skipped} =
        Enum.split_with(subs, &(length(&1.buses) <= @max_ac_island_buses))

      solutions =
        tractable
        |> Enum.map(&solve_island_ac(&1, state))
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(& &1.converged)

      dead_buses = Enum.reduce(dead, MapSet.new(), &MapSet.union(&2, &1))

      dead_info = %{
        dead_load_mw:
          snapshot.loads
          |> Enum.filter(&MapSet.member?(dead_buses, &1.bus_id))
          |> Enum.reduce(0.0, fn load, acc -> acc + (load.p_mw || 0.0) end),
        dead_bus_count: MapSet.size(dead_buses)
      }

      skipped_sizes = Enum.map(skipped, &length(&1.buses))

      case merge_ac_solutions(solutions, length(subs), skipped_sizes, dead_info, state.base_mva) do
        {:ok, merged} ->
          send(server, {:ac_result, epoch, merged})

        {:partial, reason} ->
          Logger.info(
            "[sim #{state.sim_id}] AC refinement discarded: #{reason}; DC results stand"
          )
      end
    end)
  end

  # One island's AC solve. `FDPF.solve/2` chooses dense Newton-Raphson or
  # fast-decoupled by island size and falls back between them on its own; what
  # is handled here is the case it cannot solve at all, which throws (a system
  # that cannot be solved must never come back as quietly wrong numbers). A
  # nil result drops out of the merge, and CAS-1 then keeps the DC picture.
  defp solve_island_ac(sub, state) do
    case FDPF.solve(sub, base_mva: state.base_mva, warm_start: state.dc_solution) do
      {:ok, solution} -> solution
      _ -> nil
    end
  catch
    thrown ->
      Logger.info(
        "[sim #{state.sim_id}] AC solve of a #{length(sub.buses)}-bus island " <>
          "failed: #{inspect(thrown)}"
      )

      nil
  end

  @doc """
  CAS-1: an AC refinement may only replace the DC picture when it covers
  EVERY island the DC solve covered. A merge of a strict subset of islands
  used to be broadcast as whole-grid authoritative, erasing marks and
  collapsing metrics to the fragment's totals on every skipped island.

  Returns `{:ok, merged_solution}` only when no island was skipped for size
  and all `n_islands` solvable islands produced a converged AC solution;
  `{:partial, reason}` otherwise (honest degradation: the DC results stand).
  """
  def merge_ac_solutions(solutions, n_islands, skipped_sizes, dead_info, base_mva) do
    n_solved = length(solutions)

    cond do
      skipped_sizes != [] ->
        {:partial,
         "island(s) of #{inspect(skipped_sizes)} buses exceed #{@max_ac_island_buses}-bus AC cap"}

      n_solved < n_islands ->
        {:partial, "#{n_islands - n_solved} of #{n_islands} island(s) diverged or failed"}

      n_solved == 0 ->
        {:partial, "no solvable islands"}

      true ->
        merged = Partition.merge_solutions(solutions, base_mva)

        {:ok,
         %{
           merged
           | dead_load_mw: dead_info.dead_load_mw,
             dead_bus_count: dead_info.dead_bus_count
         }}
    end
  end

  # Active topology with the cascade's dispatch applied to generation.
  # Solving with raw nameplate capacities instead of the dispatch would
  # disagree with the pre-failure base case everywhere, painting phantom
  # "impact" onto regions the failure never touched.
  defp active_snapshot(state) do
    cascade = state.cascade_state

    %{
      buses: cascade.buses,
      lines: Enum.reject(cascade.lines, &MapSet.member?(cascade.tripped_lines, &1.id)),
      transformers:
        Enum.reject(cascade.transformers, &MapSet.member?(cascade.tripped_transformers, &1.id)),
      generators: Cascade.dispatched_generators(cascade),
      loads: cascade.loads
    }
  end

  @doc """
  Classify branch flows for the map, relative to the pre-failure base case.

  A branch is reported when its loading category worsened (3=overloaded >100%,
  2=stressed 75-100%, 1=rerouted 30-75%) OR when its loading rose by at least
  10 percentage points above its base value (and is at least 20%) — the latter
  is what makes flow redistribution ("load shifting") visible even when a
  branch stays within its base category.

  Lines and transformers are reported in SEPARATE id lists: they come from
  different tables with independently colliding numeric ids.

  Returns a map with `overloaded/stressed/rerouted_line_ids` and
  `overloaded/stressed/rerouted_transformer_ids`.
  """
  def classify_flows(flows, base_categories, base_loading) do
    base_cats = base_categories || %{}
    base_load = base_loading || %{}

    empty = %{
      overloaded_line_ids: [],
      stressed_line_ids: [],
      rerouted_line_ids: [],
      overloaded_transformer_ids: [],
      stressed_transformer_ids: [],
      rerouted_transformer_ids: []
    }

    Enum.reduce(flows, empty, fn {{type, id} = key, flow}, acc ->
      base_cat = Map.get(base_cats, key, 0)
      base_pct = Map.get(base_load, key, 0.0)
      delta = flow.loading_pct - base_pct

      new_cat =
        cond do
          flow.loading_pct > 100.0 -> 3
          flow.loading_pct >= 75.0 -> 2
          flow.loading_pct >= 30.0 -> 1
          true -> 0
        end

      worsened = new_cat > base_cat
      shifted = delta >= 10.0 and flow.loading_pct >= 20.0

      bucket =
        cond do
          new_cat == 3 and (worsened or shifted) -> :overloaded
          new_cat == 2 and (worsened or shifted) -> :stressed
          (new_cat == 1 and worsened) or (new_cat <= 1 and shifted) -> :rerouted
          true -> nil
        end

      case {bucket, type} do
        {nil, _} -> acc
        {b, :line} -> Map.update!(acc, :"#{b}_line_ids", &[id | &1])
        {b, :transformer} -> Map.update!(acc, :"#{b}_transformer_ids", &[id | &1])
        _ -> acc
      end
    end)
  end

  @doc "Line-only view of `classify_flows/3`: `{overloaded, stressed, rerouted}` ids."
  def categorize_line_flows(line_flows, base_categories, base_loading) do
    c = classify_flows(line_flows, base_categories, base_loading)
    {c.overloaded_line_ids, c.stressed_line_ids, c.rerouted_line_ids}
  end

  defp solution_payload(nil, _state), do: %{}

  defp solution_payload(solution, state) do
    classified =
      classify_flows(solution.line_flows, state.base_line_categories, state.base_line_loading)

    %{
      converged: solution.converged,
      iterations: solution.iterations,
      max_mismatch: solution.max_mismatch,
      overloaded_line_ids: classified.overloaded_line_ids,
      stressed_line_ids: classified.stressed_line_ids,
      rerouted_line_ids: classified.rerouted_line_ids,
      overloaded_transformer_ids: classified.overloaded_transformer_ids,
      stressed_transformer_ids: classified.stressed_transformer_ids,
      rerouted_transformer_ids: classified.rerouted_transformer_ids,
      overloaded_count: length(classified.overloaded_line_ids),
      total_gen_mw: solution.total_gen_mw,
      total_load_mw: solution.total_load_mw,
      total_loss_mw: solution.total_loss_mw,
      scheduled_gen_mw: solution.scheduled_gen_mw,
      slack_injection_mw: solution.slack_injection_mw,
      mismatch_mw: solution.mismatch_mw,
      # Absolute overload truth across ALL branches, independent of the
      # worsened-only filtering above (which only drives map coloring).
      overload_summary: Solution.overload_summary(solution),
      # UI-H2 / contract #3: per-line loading percent for the "Loading %"
      # view, only for lines >= 30% loaded (absent id = lowest band on the
      # client). ONLY `{:line, id}` keys -- transformer ids are a separate,
      # independently colliding id space and must never enter this map.
      line_loading: line_loading_payload(solution.line_flows)
    }
  end

  defp line_loading_payload(line_flows) do
    for {{:line, id}, flow} <- line_flows,
        is_number(Map.get(flow, :loading_pct)) and flow.loading_pct >= 30.0,
        into: %{} do
      {id, Float.round(flow.loading_pct * 1.0, 1)}
    end
  end

  @event_atoms %{
    "dc_update" => :simulation_dc_update,
    "ac_update" => :simulation_ac_update,
    "cascade_step" => :simulation_cascade_step,
    "cascade_done" => :simulation_cascade_done,
    "reset" => :simulation_reset
  }

  defp broadcast(sim_id, event, payload) do
    atom = Map.fetch!(@event_atoms, event)

    Phoenix.PubSub.broadcast(
      PowerModel.PubSub,
      "simulation:#{sim_id}",
      {atom, payload}
    )
  end

  defp cascade_step_payload(step, state) do
    trips = if is_list(step.trips), do: step.trips, else: []

    # Separate trips by component type. Transformer ids must NOT enter the
    # line id list -- separate tables, colliding numeric ids.
    tripped_line_ids =
      trips
      |> Enum.filter(&(&1.component_type == "transmission_line"))
      |> Enum.map(& &1.component_id)

    tripped_transformer_ids =
      trips
      |> Enum.filter(&(&1.component_type == "transformer"))
      |> Enum.map(& &1.component_id)

    tripped_generator_ids =
      trips
      |> Enum.filter(&(&1.component_type == "generator"))
      |> Enum.map(& &1.component_id)

    # Categorize trips by failure cause (load shedding affects buses).
    # LoadShedding emits "ufls_shed"; "ufls" kept for safety.
    shed_ids =
      trips
      |> Enum.filter(&(&1.failure_cause in ["ufls_shed", "ufls", "island_blackout"]))
      |> Enum.map(& &1.component_id)

    # Critical-infrastructure impacts (water facilities, datacenters)
    water_facility_trips = Enum.filter(trips, &(&1.component_type == "water_facility"))
    water_facility_ids = Map.get(step, :water_facility_ids, [])
    datacenter_trips = Enum.filter(trips, &(&1.component_type == "datacenter"))
    datacenter_ids = Map.get(step, :datacenter_ids, [])

    # Extract overloaded/stressed/rerouted from step solutions, lines and
    # transformers in separate channels. Base-case artifacts filtered out.
    solutions = if is_list(step.solution), do: step.solution, else: []

    merged =
      Enum.reduce(
        solutions,
        %{
          overloaded_line_ids: [],
          stressed_line_ids: [],
          rerouted_line_ids: [],
          overloaded_transformer_ids: [],
          stressed_transformer_ids: [],
          rerouted_transformer_ids: []
        },
        fn sol, acc ->
          c = classify_flows(sol.line_flows, state.base_line_categories, state.base_line_loading)
          Map.new(acc, fn {k, v} -> {k, v ++ Map.fetch!(c, k)} end)
        end
      )

    %{
      step: step.step,
      simulated_time: Map.get(step, :simulated_time, 0.0),
      islands: step.islands,
      trips: trips,
      tripped_line_ids: tripped_line_ids,
      tripped_transformer_ids: tripped_transformer_ids,
      tripped_generator_ids: tripped_generator_ids,
      trip_count: length(trips),
      overloaded_line_ids: merged.overloaded_line_ids,
      stressed_line_ids: merged.stressed_line_ids,
      rerouted_line_ids: merged.rerouted_line_ids,
      overloaded_transformer_ids: merged.overloaded_transformer_ids,
      stressed_transformer_ids: merged.stressed_transformer_ids,
      rerouted_transformer_ids: merged.rerouted_transformer_ids,
      shed_ids: shed_ids,
      water_facility_ids: water_facility_ids,
      water_facility_trips:
        Enum.map(water_facility_trips, fn t ->
          %{
            id: t.component_id,
            name: get_in(t, [:details, :name]),
            facility_type: get_in(t, [:details, :facility_type]),
            cause: t.failure_cause
          }
        end),
      datacenter_ids: datacenter_ids,
      datacenter_trips:
        Enum.map(datacenter_trips, fn t ->
          %{
            id: t.component_id,
            name: get_in(t, [:details, :name]),
            operator: get_in(t, [:details, :operator]),
            power_mw: get_in(t, [:details, :power_mw]),
            cause: t.failure_cause
          }
        end),
      balance: Map.get(step, :balance)
    }
  end

  defp via(sim_id) do
    {:via, Registry, {PowerModel.SimulationRegistry, sim_id}}
  end

  defp touch(state) do
    %{state | last_activity: System.monotonic_time(:millisecond)}
  end

  defp schedule_idle_check(delay_ms) do
    Process.send_after(self(), :idle_check, max(delay_ms, 10))
  end
end
