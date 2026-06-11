defmodule PowerModel.Engine.SimulationServer do
  @moduledoc """
  GenServer per active simulation session.
  Holds current topology, cached Y-bus, and cascade history.
  Orchestrates DC (fast) and AC (accurate) power flow solutions.
  """

  use GenServer
  require Logger
  import Ecto.Query, only: [from: 2]

  alias PowerModel.Grid
  alias PowerModel.Solver.{DCPowerFlow, NewtonRaphson}
  alias PowerModel.Failure.{Cascade, MonteCarlo}

  defstruct [
    :sim_id,
    :interconnection_id,
    :snapshot,
    :cascade_state,
    :dc_solution,
    :ac_solution,
    :base_mva,
    :base_overloaded,
    :base_line_loading,
    :cascade_opts
  ]

  def start_link(opts) do
    sim_id = Keyword.fetch!(opts, :sim_id)
    GenServer.start_link(__MODULE__, opts, name: via(sim_id))
  end

  def trip_branch(sim_id, line_id) do
    GenServer.call(via(sim_id), {:trip_branch, line_id}, 120_000)
  end

  def trip_generator(sim_id, gen_id) do
    GenServer.call(via(sim_id), {:trip_generator, gen_id}, 120_000)
  end

  def get_state(sim_id) do
    GenServer.call(via(sim_id), :get_state, 120_000)
  end

  def reset(sim_id) do
    GenServer.call(via(sim_id), :reset)
  end

  @doc """
  Integration 4: Run Monte Carlo N-k contingency screening.
  Broadcasts results via `:simulation_nk_screening_done`.
  """
  def screen_nk(sim_id, opts \\ []) do
    GenServer.call(via(sim_id), {:screen_nk, opts}, 300_000)
  end

  @impl true
  def init(opts) do
    sim_id = Keyword.fetch!(opts, :sim_id)
    interconnection_id = Keyword.get(opts, :interconnection_id)
    base_mva = Keyword.get(opts, :base_mva, 100.0)

    snapshot =
      if interconnection_id do
        Grid.get_grid_snapshot(interconnection_id)
      else
        Grid.get_full_grid_snapshot()
      end

    # Integration 7: Hourly load profile scaling
    hour = Keyword.get(opts, :hour, nil)

    snapshot =
      if hour do
        snapshot
        |> scale_loads_for_hour(hour)
        |> scale_generators_for_hour(hour)
      else
        snapshot
      end

    # Forward all new opts to Cascade.init
    use_transient = Keyword.get(opts, :use_transient, false)
    use_ac = Keyword.get(opts, :use_ac, false)
    scenario = Keyword.get(opts, :scenario, nil)
    use_opf = Keyword.get(opts, :use_opf, false)
    run_cpf = Keyword.get(opts, :run_cpf, false)
    run_small_signal = Keyword.get(opts, :run_small_signal, false)
    run_harmonics = Keyword.get(opts, :run_harmonics, false)

    cascade_opts = [
      use_ac: use_ac,
      use_transient: use_transient,
      scenario: scenario,
      use_opf: use_opf,
      run_cpf: run_cpf,
      run_small_signal: run_small_signal,
      run_harmonics: run_harmonics,
      ras_schemes: Keyword.get(opts, :ras_schemes, [])
    ]

    cascade_state = Cascade.init(snapshot, base_mva, cascade_opts)

    state = %__MODULE__{
      sim_id: sim_id,
      interconnection_id: interconnection_id,
      snapshot: snapshot,
      cascade_state: cascade_state,
      dc_solution: nil,
      ac_solution: nil,
      base_mva: base_mva,
      base_overloaded: cascade_state.base_overloaded,
      base_line_loading: cascade_state.base_line_loading,
      cascade_opts: cascade_opts
    }

    # Use the base solution from cascade init if available (avoids redundant 3rd DC solve)
    state =
      if cascade_state.solution do
        dc_solution = cascade_state.solution

        broadcast(
          sim_id,
          "dc_update",
          solution_payload(dc_solution, cascade_state.base_line_loading, cascade_state.lines)
        )

        %{state | dc_solution: dc_solution}
      else
        if snapshot.buses != [] do
          send(self(), :initial_solve)
        end

        state
      end

    {:ok, state}
  end

  @impl true
  def handle_info(:initial_solve, state) do
    case solve_dc(state) do
      {:ok, solution} ->
        broadcast(
          state.sim_id,
          "dc_update",
          solution_payload(solution, state.base_line_loading, state.cascade_state.lines)
        )

        {:noreply, %{state | dc_solution: solution}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ac_result, solution}, state) do
    broadcast(
      state.sim_id,
      "ac_update",
      solution_payload(solution, state.base_line_loading, state.cascade_state.lines)
    )

    {:noreply, %{state | ac_solution: solution}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:trip_branch, line_id}, _from, state) do
    {final_cascade, step_results} = Cascade.trip_line(state.cascade_state, line_id)
    {state, step_results} = finalize_trip(state, final_cascade, step_results)
    {:reply, {:ok, step_results}, state}
  end

  @impl true
  def handle_call({:trip_generator, gen_id}, _from, state) do
    {final_cascade, step_results} = Cascade.trip_generator(state.cascade_state, gen_id)
    {state, step_results} = finalize_trip(state, final_cascade, step_results)
    {:reply, {:ok, step_results}, state}
  end

  @impl true
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

  @impl true
  def handle_call(:reset, _from, state) do
    # Use saved cascade_opts to preserve all forwarded options on reset
    cascade_opts =
      state.cascade_opts ||
        [
          use_ac: state.cascade_state.use_ac || false,
          use_transient: state.cascade_state.use_transient || false
        ]

    cascade = Cascade.init(state.snapshot, state.base_mva, cascade_opts)

    state = %{
      state
      | cascade_state: cascade,
        dc_solution: nil,
        ac_solution: nil,
        base_overloaded: cascade.base_overloaded,
        base_line_loading: cascade.base_line_loading
    }

    send(self(), :initial_solve)
    broadcast(state.sim_id, "reset", %{})
    {:reply, :ok, state}
  end

  # Integration 4: Monte Carlo N-k screening
  @impl true
  def handle_call({:screen_nk, opts}, _from, state) do
    snapshot = dispatched_snapshot(state)

    result =
      try do
        MonteCarlo.screen_random_nk(
          snapshot,
          Keyword.merge([base_mva: state.base_mva], opts)
        )
      rescue
        e ->
          Logger.warning("[SIM] Monte Carlo screening failed: #{inspect(e)}")
          []
      catch
        :throw, reason ->
          Logger.warning("[SIM] Monte Carlo screening error: #{inspect(reason)}")
          []
      end

    broadcast(state.sim_id, "nk_screening_done", %{
      results: result,
      count: length(result)
    })

    {:reply, {:ok, result}, state}
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
    snapshot = dispatched_snapshot(state)

    try do
      solution = DCPowerFlow.solve(snapshot, base_mva: state.base_mva)
      {:ok, solution}
    catch
      kind, reason ->
        Logger.warning("DC cascade solve failed: #{kind} #{inspect(reason)}")
        :error
    end
  end

  defp finalize_trip(state, final_cascade, step_results) do
    Enum.each(step_results, fn step ->
      broadcast(state.sim_id, "cascade_step", cascade_step_payload(step, state.base_line_loading))
    end)

    state = %{state | cascade_state: final_cascade}

    state =
      case solve_dc_from_cascade(state) do
        {:ok, solution} ->
          broadcast(
            state.sim_id,
            "dc_update",
            solution_payload(solution, state.base_line_loading, state.cascade_state.lines)
          )

          state = %{state | dc_solution: solution}
          spawn_ac_refinement(state)
          state

        _ ->
          state
      end

    broadcast(state.sim_id, "cascade_done", cascade_done_payload(final_cascade, step_results))

    {state, step_results}
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
    offline = cascade.offline_generators || MapSet.new()

    active_gens =
      cascade.generators
      |> Enum.reject(fn g ->
        MapSet.member?(cascade.tripped_generators, g.id) or MapSet.member?(offline, g.id)
      end)
      |> Enum.map(fn g ->
        d = Map.get(dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))
        %{g | p_max_mw: d, capacity_factor: 1.0}
      end)

    %{
      buses: cascade.buses,
      lines: Enum.reject(cascade.lines, &MapSet.member?(cascade.tripped_lines, &1.id)),
      transformers:
        Enum.reject(cascade.transformers, &MapSet.member?(cascade.tripped_transformers, &1.id)),
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

        case classify_flow(flow.loading_pct, base_pct, delta) do
          :overloaded ->
            detail = line_detail(line_lookup, id, flow.loading_pct, base_pct, delta, "overloaded")
            {[id | ol], st, rt, [detail | comp]}

          :stressed ->
            detail = line_detail(line_lookup, id, flow.loading_pct, base_pct, delta, "stressed")
            {ol, [id | st], rt, [detail | comp]}

          :rerouted ->
            detail =
              line_detail(line_lookup, id, flow.loading_pct, base_pct, delta, "compensating")

            {ol, st, [id | rt], [detail | comp]}

          :normal ->
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

  defp classify_flow(loading_pct, base_pct, delta) do
    cond do
      loading_pct > 100.0 and base_pct <= 100.0 -> :overloaded
      delta >= 15.0 and loading_pct >= 50.0 -> :stressed
      delta >= 5.0 and loading_pct >= 10.0 -> :rerouted
      true -> :normal
    end
  end

  defp status_rank("overloaded"), do: 3
  defp status_rank("stressed"), do: 2
  defp status_rank(_), do: 1

  @event_atoms %{
    "dc_update" => :simulation_dc_update,
    "ac_update" => :simulation_ac_update,
    "cascade_step" => :simulation_cascade_step,
    "cascade_done" => :simulation_cascade_done,
    "reset" => :simulation_reset,
    "nk_screening_done" => :simulation_nk_screening_done
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

    tripped_line_ids =
      trips
      |> Enum.filter(&(&1.component_type in ["transmission_line", "transformer"]))
      |> Enum.map(& &1.component_id)

    tripped_generator_ids =
      trips
      |> Enum.filter(&(&1.component_type == "generator"))
      |> Enum.map(& &1.component_id)

    shed_ids =
      trips
      |> Enum.filter(&(&1.failure_cause in ["ufls", "island_blackout"]))
      |> Enum.map(& &1.component_id)

    water_facility_trips = Enum.filter(trips, &(&1.component_type == "water_facility"))
    water_facility_ids = Map.get(step, :water_facility_ids, [])

    critical_facility_trips = Enum.filter(trips, &(&1.component_type == "critical_facility"))
    critical_facility_ids = Map.get(step, :critical_facility_ids, [])

    solutions = if is_list(step.solution), do: step.solution, else: []

    classified =
      for sol <- solutions,
          {k, f} <- sol.line_flows,
          base_pct = Map.get(base_load, k, 0.0),
          delta = f.loading_pct - base_pct,
          class = classify_flow(f.loading_pct, base_pct, delta),
          class != :normal,
          {_type, id} = k,
          do: {class, id}

    grouped = Enum.group_by(classified, &elem(&1, 0), &elem(&1, 1))

    overloaded_line_ids = Map.get(grouped, :overloaded, [])
    stressed_line_ids = Map.get(grouped, :stressed, [])
    rerouted_line_ids = Map.get(grouped, :rerouted, [])

    %{
      step: step.step,
      simulated_time: Map.get(step, :simulated_time, 0.0),
      frequency_hz: Map.get(step, :frequency_hz, 60.0),
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
      water_facility_trips:
        Enum.map(water_facility_trips, fn t ->
          %{
            id: t.component_id,
            name: get_in(t, [:details, :name]),
            facility_type: get_in(t, [:details, :facility_type]),
            cause: t.failure_cause
          }
        end),
      critical_facility_ids: critical_facility_ids,
      critical_facility_trips:
        Enum.map(critical_facility_trips, fn t ->
          %{
            id: t.component_id,
            name: get_in(t, [:details, :name]),
            category: get_in(t, [:details, :category]),
            cause: t.failure_cause
          }
        end)
    }
  end

  # Build the cascade_done broadcast payload with post-stabilization data
  defp cascade_done_payload(final_cascade, step_results) do
    base = %{
      steps: length(step_results),
      stable: final_cascade.stable,
      total_events: length(final_cascade.events)
    }

    # Add OPF results if available
    base =
      if final_cascade.opf_result do
        Map.merge(base, %{
          opf_converged: final_cascade.opf_result.converged,
          opf_total_cost: final_cascade.opf_result.total_cost,
          lmps: final_cascade.lmps,
          congested_lines: final_cascade.congested_lines
        })
      else
        base
      end

    # Add CPF results if available
    base =
      if final_cascade.cpf_result do
        Map.merge(base, %{
          voltage_margin_mw: final_cascade.voltage_margin_mw,
          critical_bus_id: final_cascade.critical_bus_id,
          cpf_converged: final_cascade.cpf_result.converged
        })
      else
        base
      end

    # Add small-signal results if available
    base =
      if final_cascade.small_signal_result do
        Map.merge(base, %{
          small_signal_stable: final_cascade.small_signal_stable,
          stability_modes: Enum.take(final_cascade.stability_modes || [], 10)
        })
      else
        base
      end

    # Add transient-screening summary if checks were performed
    base =
      if (final_cascade.transient_checks_run || 0) > 0 do
        Map.merge(base, %{
          transient_checks_run: final_cascade.transient_checks_run,
          transient_unstable_checks: final_cascade.transient_unstable_checks || 0,
          transient_failed_checks: final_cascade.transient_failed_checks || 0,
          transient_last_stable: final_cascade.transient_last_stable,
          transient_last_oos_count: final_cascade.transient_last_oos_count || 0,
          transient_last_min_frequency_hz: final_cascade.transient_last_min_frequency_hz,
          transient_last_max_delta_deg: final_cascade.transient_last_max_delta_deg,
          transient_last_duration_s: final_cascade.transient_last_duration_s
        })
      else
        base
      end

    # Add harmonics results if available
    base =
      if final_cascade.harmonics_result do
        Map.merge(base, %{
          harmonics_worst_thd: final_cascade.harmonics_worst_thd,
          harmonics_violations: final_cascade.harmonics_violations
        })
      else
        base
      end

    # Add scenario description if present
    if final_cascade.scenario do
      Map.put(base, :scenario_description, final_cascade.scenario.description)
    else
      base
    end
  end

  # Integration 7: Scale loads based on hourly load profiles.
  # Queries hourly_load_profiles for the given hour and scales loads by
  # the BA-level demand ratio (hourly demand / average demand).
  defp scale_loads_for_hour(snapshot, hour) when is_integer(hour) and hour >= 0 and hour <= 23 do
    try do
      # Query average demand per BA and demand at the specified hour
      ba_avg_query =
        from(h in PowerModel.Grid.HourlyLoadProfile,
          group_by: h.ba_code,
          select: {h.ba_code, avg(h.demand_mw)}
        )

      ba_hour_query =
        from(h in PowerModel.Grid.HourlyLoadProfile,
          where: fragment("extract(hour from ?)", h.period) == ^hour,
          group_by: h.ba_code,
          select: {h.ba_code, avg(h.demand_mw)}
        )

      ba_avg = Map.new(PowerModel.Repo.all(ba_avg_query))
      ba_hour = Map.new(PowerModel.Repo.all(ba_hour_query))

      if map_size(ba_avg) == 0 or map_size(ba_hour) == 0 do
        Logger.debug("[SIM] No hourly load profiles found, skipping load scaling")
        snapshot
      else
        # Build BA lookup for loads (via generator BA membership or load BA field)
        # For simplicity, compute a system-wide scale factor from all BAs
        total_avg = ba_avg |> Map.values() |> Enum.sum()
        total_hour = ba_hour |> Map.values() |> Enum.sum()

        scale = if total_avg > 0.0, do: total_hour / total_avg, else: 1.0

        scaled_loads =
          Enum.map(snapshot.loads, fn load ->
            q = Map.get(load, :q_mvar) || 0.0
            %{load | p_mw: load.p_mw * scale, q_mvar: q * scale}
          end)

        Logger.info("[SIM] Scaled loads for hour #{hour}: factor=#{Float.round(scale, 3)}")
        %{snapshot | loads: scaled_loads}
      end
    rescue
      e ->
        Logger.warning("[SIM] Hourly load scaling failed: #{inspect(e)}")
        snapshot
    end
  end

  defp scale_loads_for_hour(snapshot, _hour), do: snapshot

  # Integration 8: Scale generator capacity factors based on hourly generation mix.
  # Uses fleet-level fuel mix ratios (hourly MW / average MW) from hourly_generation_mix.
  defp scale_generators_for_hour(snapshot, hour)
       when is_integer(hour) and hour >= 0 and hour <= 23 do
    try do
      fuel_avg_query =
        from(h in PowerModel.Grid.HourlyGenerationMix,
          group_by: h.fuel_type,
          select: {h.fuel_type, avg(h.generation_mw)}
        )

      fuel_hour_query =
        from(h in PowerModel.Grid.HourlyGenerationMix,
          where: fragment("extract(hour from ?)", h.period) == ^hour,
          group_by: h.fuel_type,
          select: {h.fuel_type, avg(h.generation_mw)}
        )

      fuel_avg = Map.new(PowerModel.Repo.all(fuel_avg_query))
      fuel_hour = Map.new(PowerModel.Repo.all(fuel_hour_query))

      if map_size(fuel_avg) == 0 or map_size(fuel_hour) == 0 do
        Logger.debug("[SIM] No hourly generation mix found, skipping generator scaling")
        snapshot
      else
        mix_ratios = compute_generation_mix_ratios(fuel_avg, fuel_hour)
        scaled_snapshot = scale_generators_by_mix(snapshot, mix_ratios)

        Logger.info(
          "[SIM] Scaled generator fuel mix for hour #{hour} (#{map_size(mix_ratios)} fuels)"
        )

        scaled_snapshot
      end
    rescue
      e ->
        Logger.warning("[SIM] Hourly generation mix scaling failed: #{inspect(e)}")
        snapshot
    end
  end

  defp scale_generators_for_hour(snapshot, _hour), do: snapshot

  @doc false
  def compute_generation_mix_ratios(avg_mix, hour_mix)
      when is_map(avg_mix) and is_map(hour_mix) do
    avg = aggregate_generation_mix(avg_mix)
    hour = aggregate_generation_mix(hour_mix)

    keys =
      avg
      |> Map.keys()
      |> Kernel.++(Map.keys(hour))
      |> Enum.uniq()

    Enum.reduce(keys, %{}, fn fuel_group, acc ->
      avg_mw = Map.get(avg, fuel_group, 0.0)

      ratio =
        cond do
          avg_mw <= 0.0 ->
            1.0

          Map.has_key?(hour, fuel_group) ->
            clamp(Map.get(hour, fuel_group, avg_mw) / avg_mw, 0.0, 3.0)

          true ->
            1.0
        end

      Map.put(acc, fuel_group, ratio)
    end)
  end

  @doc false
  def scale_generators_by_mix(snapshot, mix_ratios)
      when is_map(snapshot) and is_map(mix_ratios) do
    generators = Map.get(snapshot, :generators, [])

    scaled_generators =
      Enum.map(generators, fn gen ->
        fuel_group = normalize_generation_mix_fuel(Map.get(gen, :fuel_type))
        ratio = Map.get(mix_ratios, fuel_group, 1.0)
        base_cf = (Map.get(gen, :capacity_factor) || 1.0) * 1.0
        scaled_cf = clamp(base_cf * ratio, 0.0, 1.0)
        Map.put(gen, :capacity_factor, scaled_cf)
      end)

    Map.put(snapshot, :generators, scaled_generators)
  end

  @doc false
  def normalize_generation_mix_fuel(nil), do: :other

  def normalize_generation_mix_fuel(fuel) when is_atom(fuel) do
    fuel
    |> Atom.to_string()
    |> normalize_generation_mix_fuel()
  end

  def normalize_generation_mix_fuel(fuel) when is_binary(fuel) do
    normalized =
      fuel
      |> String.trim()
      |> String.downcase()

    cond do
      normalized in ["ng", "gas", "natgas", "natural gas", "og"] or
          String.contains?(normalized, "gas") ->
        :gas

      normalized in ["col", "coal", "bit", "sub", "lig"] or
          String.contains?(normalized, "coal") ->
        :coal

      normalized in ["nuc", "nuclear"] or String.contains?(normalized, "nuclear") ->
        :nuclear

      normalized in ["wat", "wh", "hydro"] or String.contains?(normalized, "hydro") ->
        :hydro

      normalized in ["wnd", "wind"] or String.contains?(normalized, "wind") ->
        :wind

      normalized in ["sun", "solar", "pv"] or String.contains?(normalized, "solar") ->
        :solar

      normalized in ["oil", "dfo", "rfo", "pet"] or String.contains?(normalized, "oil") ->
        :oil

      normalized in ["bio", "biomass", "wds", "ab"] or
        String.contains?(normalized, "bio") or
          String.contains?(normalized, "waste") ->
        :biomass

      normalized in ["geo", "geothermal"] or String.contains?(normalized, "geo") ->
        :geothermal

      true ->
        :other
    end
  end

  defp aggregate_generation_mix(mix) when is_map(mix) do
    Enum.reduce(mix, %{}, fn {fuel, mw}, acc ->
      if is_number(mw) and mw >= 0.0 do
        fuel_group = normalize_generation_mix_fuel(fuel)
        Map.update(acc, fuel_group, mw * 1.0, &(&1 + mw * 1.0))
      else
        acc
      end
    end)
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp via(sim_id) do
    {:via, Registry, {PowerModel.SimulationRegistry, sim_id}}
  end
end
