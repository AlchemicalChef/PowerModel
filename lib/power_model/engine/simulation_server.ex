defmodule PowerModel.Engine.SimulationServer do
  @moduledoc """
  GenServer per active simulation session.
  Holds current topology, cached Y-bus, and cascade history.
  Orchestrates DC (fast) and AC (accurate) power flow solutions.
  """

  use GenServer

  require Logger

  alias PowerModel.Grid
  alias PowerModel.Solver.{DCPowerFlow, NewtonRaphson, Solution, Partition}
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
    epoch: 0
  ]

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
    hour = Keyword.get(opts, :hour)

    snapshot = if interconnection_id do
      Grid.get_grid_snapshot(interconnection_id, hour: hour)
    else
      Grid.get_full_grid_snapshot(hour: hour)
    end

    cascade_state = Cascade.init(snapshot, base_mva)

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
      hour: hour
    }

    # Run initial DC power flow
    if length(snapshot.buses) > 0 do
      send(self(), :initial_solve)
    end

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
        Logger.info("[sim #{state.sim_id}] discarding stale AC result (epoch #{epoch} != #{state.epoch})")
        {:noreply, state}

      not solution.converged ->
        # A diverged AC solve carries fabricated flows; never paint it on the map.
        Logger.warning("[sim #{state.sim_id}] AC refinement did not converge; discarding")
        {:noreply, state}

      true ->
        audit_solution(solution, state.sim_id)
        broadcast(state.sim_id, "ac_update", solution_payload(solution, state))
        {:noreply, %{state | ac_solution: solution}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:trip_branch, line_id}, _from, state) do
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
        Logger.warning("[sim #{state.sim_id}] trip rejected: line #{line_id} not in simulated network")
        {:reply, {:error, :not_in_network}, state}
    end
  end

  def handle_call({:trip_generator, gen_id}, _from, state) do
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
        Logger.warning("[sim #{state.sim_id}] trip rejected: generator #{gen_id} not in simulated network")
        {:reply, {:error, :not_in_network}, state}
    end
  end

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

        broadcast(state.sim_id, "cascade_done", %{
          steps: length(step_results),
          stable: final_cascade.stable,
          total_events: length(final_cascade.events),
          balance: Cascade.balance(final_cascade)
        })

        {:reply, {:ok, step_results}, state}

      _ ->
        # Final repaint failed, but the cascade itself completed -- the UI
        # must still leave its "cascading" state.
        broadcast(state.sim_id, "cascade_done", %{
          steps: length(step_results),
          stable: final_cascade.stable,
          total_events: length(final_cascade.events),
          balance: Cascade.balance(final_cascade)
        })

        {:reply, {:ok, step_results}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    reply = %{
      sim_id: state.sim_id,
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
    cascade = Cascade.init(state.snapshot, state.base_mva)
    state = %{state |
      cascade_state: cascade,
      dc_solution: nil,
      ac_solution: nil,
      base_overloaded: cascade.base_overloaded,
      base_line_categories: cascade.base_line_categories,
      base_line_loading: cascade.base_line_loading,
      # Invalidate any in-flight AC refinement from the pre-reset topology
      epoch: state.epoch + 1
    }
    send(self(), :initial_solve)
    broadcast(state.sim_id, "reset", %{})
    {:reply, :ok, state}
  end

  # Private

  defp solve_dc(state) do
    try do
      snapshot = active_snapshot(state)
      solution = DCPowerFlow.solve_islands(snapshot, base_mva: state.base_mva)
      audit_solution(solution, state.sim_id)
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
      solution = DCPowerFlow.solve_islands(active_snapshot(state), base_mva: state.base_mva)
      audit_solution(solution, state.sim_id)
      {:ok, solution}
    rescue
      e ->
        Logger.warning("[sim #{state.sim_id}] post-cascade DC solve raised: #{Exception.message(e)}")
        :error
    catch
      thrown ->
        Logger.warning("[sim #{state.sim_id}] post-cascade DC solve threw: #{inspect(thrown)}")
        :error
    end
  end

  # Truthfulness checks on every solution: the energy balance must close and
  # the slack bus must not be silently covering a large scheduling gap (which
  # produces artificial flows around the slack).
  defp audit_solution(%Solution{} = solution, sim_id) do
    %{residual_mw: residual, ok: balanced?} = Solution.energy_balance(solution)

    unless balanced? do
      Logger.warning(
        "[sim #{sim_id}] energy balance violated: gen - load - losses = " <>
          "#{Float.round(residual * 1.0, 2)} MW"
      )
    end

    mismatch = solution.mismatch_mw

    if is_number(mismatch) and
         abs(mismatch) > 0.05 * max(solution.total_load_mw || 0.0, 1.0) do
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

  defp audit_solution(_solution, _sim_id), do: :ok

  # Dense Newton-Raphson is O(n^2) per iteration; beyond this it is not a
  # refinement, it is a space heater.
  @max_ac_island_buses 3_000

  defp spawn_ac_refinement(state) do
    server = self()
    epoch = state.epoch

    Task.start(fn ->
      snapshot = active_snapshot(state)
      # AC refinement is also per electrical island -- a Y-bus spanning
      # disconnected systems is singular.
      {subs, _dead} = Partition.split(snapshot)

      {tractable, skipped} =
        Enum.split_with(subs, &(length(&1.buses) <= @max_ac_island_buses))

      if skipped != [] do
        sizes = Enum.map(skipped, &length(&1.buses))

        Logger.info(
          "[sim #{state.sim_id}] AC refinement skipped for island(s) of " <>
            "#{inspect(sizes)} buses (> #{@max_ac_island_buses}); DC results stand"
        )
      end

      solutions =
        tractable
        |> Enum.map(fn sub ->
          case NewtonRaphson.solve(sub, base_mva: state.base_mva, warm_start: state.dc_solution) do
            {:ok, solution} -> solution
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        # One diverged island must not suppress the others' refinements
        |> Enum.filter(& &1.converged)

      if solutions != [] do
        send(server, {:ac_result, epoch, Partition.merge_solutions(solutions, state.base_mva)})
      end
    end)
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
      transformers: Enum.reject(cascade.transformers, &MapSet.member?(cascade.tripped_transformers, &1.id)),
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

  Returns `{overloaded_ids, stressed_ids, rerouted_ids}`.
  """
  def categorize_line_flows(line_flows, base_categories, base_loading) do
    base_cats = base_categories || %{}
    base_load = base_loading || %{}

    Enum.reduce(line_flows, {[], [], []}, fn {key, flow}, {ol, st, rt} ->
      base_cat = Map.get(base_cats, key, 0)
      base_pct = Map.get(base_load, key, 0.0)
      delta = flow.loading_pct - base_pct

      new_cat = cond do
        flow.loading_pct > 100.0 -> 3
        flow.loading_pct >= 75.0 -> 2
        flow.loading_pct >= 30.0 -> 1
        true -> 0
      end

      worsened = new_cat > base_cat
      shifted = delta >= 10.0 and flow.loading_pct >= 20.0

      case key do
        # Only transmission LINES feed the map's line-coloring id lists --
        # transformer ids live in a separate table and would collide with
        # unrelated line ids (the map has no transformer layer to paint).
        {:line, id} ->
          cond do
            new_cat == 3 and (worsened or shifted) -> {[id | ol], st, rt}
            new_cat == 2 and (worsened or shifted) -> {ol, [id | st], rt}
            (new_cat == 1 and worsened) or (new_cat <= 1 and shifted) -> {ol, st, [id | rt]}
            true -> {ol, st, rt}
          end

        _ ->
          {ol, st, rt}
      end
    end)
  end

  defp solution_payload(nil, _state), do: %{}
  defp solution_payload(solution, state) do
    {overloaded, stressed_lines, rerouted_lines} =
      categorize_line_flows(solution.line_flows, state.base_line_categories, state.base_line_loading)

    %{
      converged: solution.converged,
      iterations: solution.iterations,
      max_mismatch: solution.max_mismatch,
      overloaded_line_ids: overloaded,
      stressed_line_ids: stressed_lines,
      rerouted_line_ids: rerouted_lines,
      overloaded_count: length(overloaded),
      total_gen_mw: solution.total_gen_mw,
      total_load_mw: solution.total_load_mw,
      total_loss_mw: solution.total_loss_mw,
      scheduled_gen_mw: solution.scheduled_gen_mw,
      slack_injection_mw: solution.slack_injection_mw,
      mismatch_mw: solution.mismatch_mw,
      # Absolute overload truth across ALL branches, independent of the
      # worsened-only filtering above (which only drives map coloring).
      overload_summary: Solution.overload_summary(solution)
    }
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
    tripped_line_ids = trips
    |> Enum.filter(&(&1.component_type == "transmission_line"))
    |> Enum.map(& &1.component_id)

    tripped_generator_ids = trips
    |> Enum.filter(&(&1.component_type == "generator"))
    |> Enum.map(& &1.component_id)

    # Categorize trips by failure cause (load shedding affects buses).
    # LoadShedding emits "ufls_shed"; "ufls" kept for safety.
    shed_ids = trips
    |> Enum.filter(&(&1.failure_cause in ["ufls_shed", "ufls", "island_blackout"]))
    |> Enum.map(& &1.component_id)

    # Critical-infrastructure impacts (water facilities, datacenters)
    water_facility_trips = Enum.filter(trips, &(&1.component_type == "water_facility"))
    water_facility_ids = Map.get(step, :water_facility_ids, [])
    datacenter_trips = Enum.filter(trips, &(&1.component_type == "datacenter"))
    datacenter_ids = Map.get(step, :datacenter_ids, [])

    # Extract overloaded/stressed/rerouted from step solutions (these are LINE IDs only)
    # Filter out base-case overloads (model artifacts)
    solutions = if is_list(step.solution), do: step.solution, else: []

    {overloaded_line_ids, stressed_line_ids, rerouted_line_ids} =
      Enum.reduce(solutions, {[], [], []}, fn sol, {ol, st, rt} ->
        {sol_ol, sol_st, sol_rt} =
          categorize_line_flows(sol.line_flows, state.base_line_categories, state.base_line_loading)

        {ol ++ sol_ol, st ++ sol_st, rt ++ sol_rt}
      end)

    %{
      step: step.step,
      simulated_time: Map.get(step, :simulated_time, 0.0),
      islands: step.islands,
      trips: trips,
      tripped_line_ids: tripped_line_ids,
      tripped_generator_ids: tripped_generator_ids,
      trip_count: length(trips),
      overloaded_line_ids: overloaded_line_ids,
      stressed_line_ids: stressed_line_ids,
      rerouted_line_ids: rerouted_line_ids,
      shed_ids: shed_ids,
      water_facility_ids: water_facility_ids,
      water_facility_trips: Enum.map(water_facility_trips, fn t ->
        %{id: t.component_id, name: get_in(t, [:details, :name]),
          facility_type: get_in(t, [:details, :facility_type]),
          cause: t.failure_cause}
      end),
      datacenter_ids: datacenter_ids,
      datacenter_trips: Enum.map(datacenter_trips, fn t ->
        %{id: t.component_id, name: get_in(t, [:details, :name]),
          operator: get_in(t, [:details, :operator]),
          power_mw: get_in(t, [:details, :power_mw]),
          cause: t.failure_cause}
      end),
      balance: Map.get(step, :balance)
    }
  end

  defp via(sim_id) do
    {:via, Registry, {PowerModel.SimulationRegistry, sim_id}}
  end
end
