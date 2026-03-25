defmodule PowerModel.Transient.Runner do
  @moduledoc """
  Orchestrator for transient stability simulation.

  Coordinates initialization from a power flow solution, event scheduling,
  time-domain integration via the classical machine model (Elixir fallback
  or Rust NIF), and post-simulation analysis (OOS detection, relay events).
  """

  require Logger

  alias PowerModel.Transient.{State, NetworkInterface, OutOfStep}
  alias PowerModel.Transient.Machine.Classical
  alias PowerModel.Solver.Sparse

  @doc """
  Run a transient stability simulation.

  ## Parameters
    * `snapshot` - grid snapshot (buses, lines, transformers, generators, loads)
    * `event` - the initiating event: `{:trip_generator, gen_id}` or `{:trip_line, line_id}`
    * `opts` - simulation options

  ## Options
    * `:duration_s` - simulation duration in seconds (default 5.0)
    * `:dt` - timestep in seconds (default 0.005)
    * `:base_mva` - system MVA base (default 100.0)
    * `:output_every` - output decimation factor (default 10)
    * `:use_nif` - use Rust NIF for simulation (default true, falls back to Elixir)

  ## Returns
    `{:ok, %{trajectory: [...], events: [...], stable: bool}}`
  """
  def run(snapshot, event, opts \\ []) do
    duration_s = Keyword.get(opts, :duration_s, 5.0)
    dt = Keyword.get(opts, :dt, 0.005)
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    output_every = Keyword.get(opts, :output_every, 10)
    use_nif = Keyword.get(opts, :use_nif, true)

    # Need a power flow solution for initialization
    solution = Keyword.get(opts, :solution) || solve_base_case(snapshot, base_mva)

    # Filter to synchronous generators only
    sync_gens = Enum.filter(snapshot.generators, fn g ->
      (Map.get(g, :inertia_h) || 0.0) > 0.0
    end) |> Enum.sort_by(& &1.id)

    if length(sync_gens) < 2 do
      {:error, :insufficient_generators}
    else
      # Initialize state
      state = State.init(sync_gens, solution, base_mva, dt: dt)

      # Build reduced admittance matrix
      state = build_y_reduced(state, snapshot, sync_gens, base_mva)

      # Schedule the event
      state = schedule_event(state, event, sync_gens)

      # Run simulation
      n_steps = round(duration_s / dt)

      trajectory = if use_nif do
        run_nif(state, n_steps, output_every)
      else
        nil
      end

      trajectory = trajectory || Classical.simulate(state, n_steps, output_every)

      # Analyze results
      events = analyze_trajectory(trajectory, state)

      stable = Enum.empty?(events)

      {:ok, %{
        trajectory: trajectory,
        events: events,
        stable: stable,
        n_gen: state.n_gen,
        gen_ids: state.gen_ids,
        duration_s: duration_s,
        dt: dt
      }}
    end
  end

  defp solve_base_case(snapshot, base_mva) do
    alias PowerModel.Solver.DCPowerFlow
    DCPowerFlow.solve(snapshot, base_mva: base_mva)
  end

  defp build_y_reduced(state, snapshot, sync_gens, base_mva) do
    result = if length(snapshot.buses) > 500 do
      # Try NIF Kron reduction for large systems
      try do
        NetworkInterface.build_y_reduced(
          snapshot.buses, snapshot.lines,
          Map.get(snapshot, :transformers, []),
          sync_gens, base_mva
        )
      rescue
        _ -> nil
      end
    else
      nil
    end

    case result do
      {:ok, rows, cols, g, b} ->
        %{state | y_red_rows: rows, y_red_cols: cols, y_red_g: g, y_red_b: b}

      _ ->
        # Fallback to Elixir Kron reduction
        {:ok, rows, cols, g, b} =
          NetworkInterface.build_y_reduced_elixir(
            snapshot.buses, snapshot.lines,
            Map.get(snapshot, :transformers, []),
            sync_gens, base_mva)

        %{state | y_red_rows: rows, y_red_cols: cols, y_red_g: g, y_red_b: b}
    end
  end

  defp schedule_event(state, {:trip_generator, gen_id}, _sync_gens) do
    # Trip = set P_mech to 0 at t=0.001 (just after initialization)
    State.add_event(state, 0.001, gen_id, 0.0)
  end

  defp schedule_event(state, {:fault, gen_id, clear_time_s}, _sync_gens) do
    # Three-phase fault near generator: P_elec drops to ~0 during fault,
    # modeled as setting P_mech to 2x (simulates acceleration)
    # then restoring at clear time
    case State.gen_index(state, gen_id) do
      nil -> state
      idx ->
        original_p = Enum.at(state.p_mech, idx)
        state
        |> State.add_event(0.001, gen_id, original_p * 2.0)  # fault on: P_elec ≈ 0
        |> State.add_event(clear_time_s, gen_id, original_p)  # fault cleared
    end
  end

  defp schedule_event(state, {:network_disturbance}, _sync_gens) do
    # No explicit event — just simulate from current state to check stability
    # The topology change is already reflected in the snapshot
    state
  end

  defp schedule_event(state, {:trip_line, _line_id}, _sync_gens) do
    # Line trip is reflected in the snapshot topology; just run from current state
    state
  end

  defp schedule_event(state, _event, _sync_gens), do: state

  defp run_nif(state, n_steps, output_every) do
    # Sort events for NIF
    sorted_events = Enum.sort_by(state.events, & &1.time)
    event_times = Enum.map(sorted_events, & &1.time)
    event_indices = Enum.map(sorted_events, & &1.gen_index)
    event_p_mechs = Enum.map(sorted_events, & &1.p_mech_new)

    try do
      case Sparse.transient_classical_simulate(
             state.n_gen,
             state.delta, state.omega, state.p_mech, state.e_prime,
             state.h, state.d,
             state.y_red_rows, state.y_red_cols,
             state.y_red_g, state.y_red_b,
             state.dt, n_steps,
             event_times, event_indices, event_p_mechs,
             output_every) do
        {:ok, raw_trajectory} ->
          # Convert raw trajectory to maps
          Enum.map(raw_trajectory, fn row ->
            [t | rest] = row
            {deltas, omegas} = Enum.split(rest, state.n_gen)
            %{
              t: t,
              delta: deltas,
              omega: omegas,
              frequency_hz: Enum.map(omegas, &(&1 * 60.0))
            }
          end)

        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  defp analyze_trajectory(trajectory, state) do
    # Check each trajectory point for OOS
    trajectory
    |> Enum.flat_map(fn point ->
      oos_indices = OutOfStep.detect(point.delta, state.h, state.n_gen)

      Enum.map(oos_indices, fn idx ->
        %{
          time: point.t,
          component_type: "generator",
          component_id: Enum.at(state.gen_ids, idx),
          failure_cause: "out_of_step",
          details: %{
            delta_rad: Enum.at(point.delta, idx),
            omega_pu: Enum.at(point.omega, idx),
            delta_coi: OutOfStep.center_of_inertia(point.delta, state.h, state.n_gen)
          }
        }
      end)
    end)
    |> Enum.uniq_by(& &1.component_id)  # Only report first OOS per generator
  end
end
