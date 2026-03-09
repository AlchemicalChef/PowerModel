defmodule PowerModel.Engine.SimulationServer do
  @moduledoc """
  GenServer per active simulation session.
  Holds current topology, cached Y-bus, and cascade history.
  Orchestrates DC (fast) and AC (accurate) power flow solutions.
  """

  use GenServer
  require Logger

  alias PowerModel.Grid
  alias PowerModel.Solver.{DCPowerFlow, NewtonRaphson}
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
    :base_line_loading
  ]

  def start_link(opts) do
    sim_id = Keyword.fetch!(opts, :sim_id)
    GenServer.start_link(__MODULE__, opts, name: via(sim_id))
  end

  def trip_branch(sim_id, line_id) do
    GenServer.call(via(sim_id), {:trip_branch, line_id}, 30_000)
  end

  def trip_generator(sim_id, gen_id) do
    GenServer.call(via(sim_id), {:trip_generator, gen_id}, 30_000)
  end

  def get_state(sim_id) do
    GenServer.call(via(sim_id), :get_state, 30_000)
  end

  def reset(sim_id) do
    GenServer.call(via(sim_id), :reset)
  end

  @impl true
  def init(opts) do
    sim_id = Keyword.fetch!(opts, :sim_id)
    interconnection_id = Keyword.get(opts, :interconnection_id)
    base_mva = Keyword.get(opts, :base_mva, 100.0)

    snapshot = if interconnection_id do
      Grid.get_grid_snapshot(interconnection_id)
    else
      Grid.get_full_grid_snapshot()
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
      base_line_loading: cascade_state.base_line_loading
    }

    if length(snapshot.buses) > 0 do
      send(self(), :initial_solve)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:initial_solve, state) do
    case solve_dc(state) do
      {:ok, solution} ->
        broadcast(state.sim_id, "dc_update", solution_payload(solution, state.base_line_loading, state.cascade_state.lines))
        {:noreply, %{state | dc_solution: solution}}
      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:ac_result, solution}, state) do
    broadcast(state.sim_id, "ac_update", solution_payload(solution, state.base_line_loading, state.cascade_state.lines))
    {:noreply, %{state | ac_solution: solution}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:trip_branch, line_id}, _from, state) do
    cascade = state.cascade_state

    {final_cascade, step_results} =
      Cascade.trip_line(cascade, line_id)

    Enum.each(step_results, fn step ->
      broadcast(state.sim_id, "cascade_step", cascade_step_payload(step, state.base_line_loading))
    end)

    state = %{state | cascade_state: final_cascade}
    state = case solve_dc_from_cascade(state) do
      {:ok, solution} ->
        broadcast(state.sim_id, "dc_update", solution_payload(solution, state.base_line_loading, state.cascade_state.lines))
        state = %{state | dc_solution: solution}
        spawn_ac_refinement(state)
        state
      _ ->
        state
    end

    broadcast(state.sim_id, "cascade_done", %{
      steps: length(step_results),
      stable: final_cascade.stable,
      total_events: length(final_cascade.events)
    })

    {:reply, {:ok, step_results}, state}
  end

  def handle_call({:trip_generator, gen_id}, _from, state) do
    cascade = state.cascade_state

    {final_cascade, step_results} =
      Cascade.trip_generator(cascade, gen_id)

    Enum.each(step_results, fn step ->
      payload = cascade_step_payload(step, state.base_line_loading)
      broadcast(state.sim_id, "cascade_step", payload)
    end)

    state = %{state | cascade_state: final_cascade}
    state = case solve_dc_from_cascade(state) do
      {:ok, solution} ->
        payload = solution_payload(solution, state.base_line_loading, state.cascade_state.lines)
        broadcast(state.sim_id, "dc_update", payload)
        state = %{state | dc_solution: solution}
        spawn_ac_refinement(state)
        state
      _ ->
        state
    end

    broadcast(state.sim_id, "cascade_done", %{
      steps: length(step_results),
      stable: final_cascade.stable,
      total_events: length(final_cascade.events)
    })

    {:reply, {:ok, step_results}, state}
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
      has_ac_solution: state.ac_solution != nil
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
      base_line_loading: cascade.base_line_loading
    }
    send(self(), :initial_solve)
    broadcast(state.sim_id, "reset", %{})
    {:reply, :ok, state}
  end

  defp solve_dc(state) do
    try do
      snapshot = dispatched_snapshot(state)
      solution = DCPowerFlow.solve(snapshot, base_mva: state.base_mva)
      {:ok, solution}
    catch
      kind, reason ->
        Logger.warning("DC solve failed: #{kind} #{inspect(reason)}")
        :error
    end
  end

  defp solve_dc_from_cascade(state) do
    cascade = state.cascade_state
    dispatch = cascade.dispatch

    active_gens = cascade.generators
    |> Enum.reject(&MapSet.member?(cascade.tripped_generators, &1.id))
    |> Enum.map(fn g ->
      d = Map.get(dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))
      %{g | p_max_mw: d, capacity_factor: 1.0}
    end)

    snapshot = %{
      buses: cascade.buses,
      lines: Enum.reject(cascade.lines, &MapSet.member?(cascade.tripped_lines, &1.id)),
      transformers: Enum.reject(cascade.transformers, &MapSet.member?(cascade.tripped_transformers, &1.id)),
      generators: active_gens,
      loads: cascade.loads
    }

    try do
      solution = DCPowerFlow.solve(snapshot, base_mva: state.base_mva)
      {:ok, solution}
    catch
      kind, reason ->
        Logger.warning("DC cascade solve failed: #{kind} #{inspect(reason)}")
        :error
    end
  end

  defp spawn_ac_refinement(state) do
    server = self()
    Task.Supervisor.start_child(PowerModel.TaskSupervisor, fn ->
      snapshot = dispatched_snapshot(state)
      case NewtonRaphson.solve(snapshot, base_mva: state.base_mva, warm_start: state.dc_solution) do
        {:ok, solution} -> send(server, {:ac_result, solution})
        {:error, reason} -> Logger.debug("AC refinement did not converge: #{inspect(reason)}")
      end
    end)
  end

  defp dispatched_snapshot(state) do
    cascade = state.cascade_state
    dispatch = cascade.dispatch

    active_gens = cascade.generators
    |> Enum.reject(&MapSet.member?(cascade.tripped_generators, &1.id))
    |> Enum.map(fn g ->
      d = Map.get(dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))
      %{g | p_max_mw: d, capacity_factor: 1.0}
    end)

    %{
      buses: cascade.buses,
      lines: Enum.reject(cascade.lines, &MapSet.member?(cascade.tripped_lines, &1.id)),
      transformers: Enum.reject(cascade.transformers, &MapSet.member?(cascade.tripped_transformers, &1.id)),
      generators: active_gens,
      loads: cascade.loads
    }
  end

  defp solution_payload(nil, _base_loading, _lines), do: %{}
  defp solution_payload(solution, base_line_loading, lines) do
    base = base_line_loading || %{}
    line_lookup = Map.new(lines, &{&1.id, &1})

    {overloaded, stressed_lines, rerouted_lines, compensating} =
      Enum.reduce(solution.line_flows, {[], [], [], []}, fn {key, flow}, {ol, st, rt, comp} ->
        base_pct = Map.get(base, key, 0.0)
        delta = flow.loading_pct - base_pct
        {_type, id} = key

        cond do
          flow.loading_pct > 100.0 and base_pct <= 100.0 ->
            detail = line_detail(line_lookup, id, flow.loading_pct, base_pct, delta, "overloaded")
            {[id | ol], st, rt, [detail | comp]}
          delta >= 15.0 and flow.loading_pct >= 50.0 ->
            detail = line_detail(line_lookup, id, flow.loading_pct, base_pct, delta, "stressed")
            {ol, [id | st], rt, [detail | comp]}
          delta >= 5.0 and flow.loading_pct >= 10.0 ->
            detail = line_detail(line_lookup, id, flow.loading_pct, base_pct, delta, "compensating")
            {ol, st, [id | rt], [detail | comp]}
          true ->
            {ol, st, rt, comp}
        end
      end)

    compensating = Enum.sort_by(compensating, fn c -> {-status_rank(c.status), -c.delta} end)

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
      compensating_lines: compensating
    }
  end

  defp line_detail(lookup, id, loading_pct, base_pct, delta, status) do
    line = Map.get(lookup, id)
    %{
      id: id,
      voltage_kv: line && line.voltage_kv,
      sub_1: line && line.sub_1,
      sub_2: line && line.sub_2,
      owner: line && line.owner,
      loading_pct: Float.round(loading_pct, 1),
      base_pct: Float.round(base_pct, 1),
      delta: Float.round(delta, 1),
      status: status
    }
  end

  defp status_rank("overloaded"), do: 3
  defp status_rank("stressed"), do: 2
  defp status_rank(_), do: 1

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

  defp cascade_step_payload(step, base_line_loading) do
    trips = if is_list(step.trips), do: step.trips, else: []
    base_load = base_line_loading || %{}

    tripped_line_ids = trips
    |> Enum.filter(&(&1.component_type in ["transmission_line", "transformer"]))
    |> Enum.map(& &1.component_id)

    tripped_generator_ids = trips
    |> Enum.filter(&(&1.component_type == "generator"))
    |> Enum.map(& &1.component_id)

    shed_ids = trips
    |> Enum.filter(&(&1.failure_cause in ["ufls", "island_blackout"]))
    |> Enum.map(& &1.component_id)

    water_facility_trips = Enum.filter(trips, &(&1.component_type == "water_facility"))
    water_facility_ids = Map.get(step, :water_facility_ids, [])

    solutions = if is_list(step.solution), do: step.solution, else: []

    {overloaded_line_ids, stressed_line_ids, rerouted_line_ids} =
      Enum.reduce(solutions, {[], [], []}, fn sol, {ol, st, rt} ->
        {sol_ol, sol_st, sol_rt} =
          Enum.reduce(sol.line_flows, {[], [], []}, fn {k, f}, {o2, s2, r2} ->
            base_pct = Map.get(base_load, k, 0.0)
            delta = f.loading_pct - base_pct
            {_type, id} = k

            cond do
              f.loading_pct > 100.0 and base_pct <= 100.0 ->
                {[id | o2], s2, r2}
              delta >= 15.0 and f.loading_pct >= 50.0 ->
                {o2, [id | s2], r2}
              delta >= 5.0 and f.loading_pct >= 10.0 ->
                {o2, s2, [id | r2]}
              true ->
                {o2, s2, r2}
            end
          end)

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
      end)
    }
  end

  defp via(sim_id) do
    {:via, Registry, {PowerModel.SimulationRegistry, sim_id}}
  end
end
