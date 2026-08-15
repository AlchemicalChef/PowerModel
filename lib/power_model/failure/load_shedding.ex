defmodule PowerModel.Failure.LoadShedding do
  @moduledoc """
  Implements load shedding strategies for generation-load imbalance.

  Integrates with the swing-equation frequency simulator
  (`PowerModel.Solver.Frequency`) to determine shedding amounts based on
  the actual frequency trajectory rather than a static calculation.

  ## Persistent frequency state (ROADMAP item 15)

  `apply_ufls_with_state/5` is the state-threading form: it takes the
  island's previous frequency state and returns the new one alongside the
  shed loads and events, so a cascade can persist one state PER ISLAND and
  have successive trips compound instead of each restarting at 60.0 Hz with
  every UFLS stage rearmed.

  `apply_ufls/4` is the stateless form and is unchanged — same arguments,
  same `{loads, events}` return. It is `apply_ufls_with_state/5` with no
  incoming state and the outgoing state discarded, which is exactly the old
  behaviour. Callers that want compounding must move to the 5-arity form;
  the cascade's move is wave 2's (it owns `cascade.ex`).
  """

  alias PowerModel.Failure.Protection
  alias PowerModel.Solver.Frequency

  @doc """
  Apply UFLS load shedding to an island with generation deficit.

  When generator structs are available, uses the full frequency simulation
  to determine the frequency nadir and shed accordingly.  Falls back to
  the static `estimate_frequency` when only MW totals are provided.

  Returns `{updated_loads, shed_events}`. See `apply_ufls_with_state/5` for
  the form that carries frequency state across disturbances.
  """
  def apply_ufls(loads, generators, gen_mw, load_mw)
      when is_list(generators) do
    {shed_loads, events, _state} =
      apply_ufls_with_state(loads, generators, gen_mw, load_mw)

    {shed_loads, events}
  end

  @doc """
  Apply UFLS to an island, threading `PowerModel.Solver.Frequency` state in
  and out.

  Returns `{updated_loads, shed_events, frequency_state}`. The state is the
  simulator's (see `PowerModel.Solver.Frequency`'s moduledoc for its shape);
  persist it per island and hand it back on the next disturbance in that
  island.

  Two things compound when the state is threaded, and both matter:

  * the second disturbance starts from the DEPRESSED frequency and from the
    governor output already deployed, so it reaches a strictly worse nadir
    than the same disturbance would from 60.0 Hz; and
  * UFLS stages already spent stay spent. A stage that shed 7.5% at the first
    trip cannot shed another 7.5% at the second — the breakers are already
    open. Only stages still armed can fire, so the second event sheds less
    from the program even as the frequency goes lower.

  ## Options

    * `:frequency_state` — the state returned by a previous call, or `nil`
    * `:duration_seconds` — how long to integrate this disturbance
      (default 30.0, the simulator's own default)

  ## Notes on the numbers

  `lost_mw` handed to the simulator is `load_mw - gen_mw`, the NEW imbalance
  this call is answering; the state carries what was already lost. The MW the
  simulation sheds is read INCREMENTALLY (the state's cumulative shed before
  and after), because the trajectory's `load_shed_mw` is cumulative across
  every segment the state has seen and re-applying it would shed the same
  megawatts twice.
  """
  @spec apply_ufls_with_state(list(map()), list(map()), float(), float(), keyword()) ::
          {list(map()), list(map()), map() | nil}
  def apply_ufls_with_state(loads, generators, gen_mw, load_mw, opts \\ [])
      when is_list(generators) do
    prior = Keyword.get(opts, :frequency_state)

    if load_mw <= gen_mw do
      {loads, [], prior}
    else
      lost_mw = load_mw - gen_mw
      shed_before = if prior, do: Map.get(prior, :cumulative_shed_mw, 0.0), else: 0.0

      sim_opts =
        [initial_state: prior]
        |> then(fn o ->
          case Keyword.fetch(opts, :duration_seconds) do
            {:ok, d} -> Keyword.put(o, :duration_seconds, d)
            :error -> o
          end
        end)

      {trajectory, state} =
        Frequency.simulate_with_state(generators, loads, lost_mw, sim_opts)

      nadir = Frequency.nadir(trajectory)

      # Only the stages this disturbance can still fire count toward the
      # static floor: a stage the island already spent is not available again.
      schedule = remaining_schedule(nadir, prior)

      # The simulation's shed, read incrementally (see the moduledoc note).
      sim_shed_mw = max(Map.get(state, :cumulative_shed_mw, 0.0) - shed_before, 0.0)

      case schedule do
        [] ->
          {loads, [], state}

        config ->
          # Use the larger of: UFLS schedule fraction or simulation-determined shed
          shed_fraction = config[:shed_fraction]
          total_load = Enum.sum(Enum.map(loads, & &1.p_mw))
          sim_fraction = if total_load > 0, do: sim_shed_mw / total_load, else: 0.0
          effective_fraction = max(shed_fraction, sim_fraction)

          {shed_loads, events} =
            apply_proportional_shedding(loads, effective_fraction, gen_mw, load_mw,
              frequency_nadir: nadir,
              gov_response_mw: trajectory |> List.last() |> Map.get(:gov_response_mw, 0.0)
            )

          {shed_loads, events, state}
      end
    end
  end

  # The cumulative UFLS fraction still AVAILABLE at this nadir: every stage
  # the frequency fell below that the island has not already spent. With no
  # prior state this is exactly `Protection.ufls_schedule/1`.
  defp remaining_schedule(nadir, nil), do: Protection.ufls_schedule(nadir)

  defp remaining_schedule(nadir, prior) do
    spent = Map.get(prior, :ufls_state, [])

    available =
      Frequency.ufls_stages()
      |> Enum.with_index()
      |> Enum.filter(fn {{threshold_hz, _frac, _delay}, index} ->
        nadir < threshold_hz and not stage_tripped?(spent, index)
      end)

    case available do
      [] ->
        []

      stages ->
        cumulative = stages |> Enum.map(fn {{_t, frac, _d}, _i} -> frac end) |> Enum.sum()
        [stage: length(stages), shed_fraction: cumulative]
    end
  end

  defp stage_tripped?(ufls_state, index) do
    case Enum.at(ufls_state, index) do
      %{tripped: true} -> true
      _ -> false
    end
  end

  # Backward-compatible 3-arity: uses static frequency estimate
  def apply_ufls(loads, gen_mw, load_mw) do
    freq = Protection.estimate_frequency(gen_mw, load_mw)
    schedule = Protection.ufls_schedule(freq)

    case schedule do
      [] ->
        {loads, []}

      config ->
        shed_fraction = config[:shed_fraction]
        apply_proportional_shedding(loads, shed_fraction, gen_mw, load_mw)
    end
  end

  @doc """
  Proportional load shedding: reduce all loads by a fraction
  until generation-load balance is restored.

  Accepts optional keyword metadata (e.g., frequency_nadir, gov_response_mw)
  that will be included in the shed event details.

  Loads with zero remaining demand (e.g. already blacked out) are left
  untouched and emit NO shed event; an empty or all-zero load list returns
  `{loads, []}` (no divide-by-zero on the shed fraction).
  """
  def apply_proportional_shedding(loads, shed_fraction, gen_mw, load_mw, opts \\ []) do
    deficit = load_mw - gen_mw
    total_load = Enum.sum(Enum.map(loads, & &1.p_mw))

    if deficit <= 0 or total_load <= 0 do
      {loads, []}
    else
      actual_shed_fraction = min(shed_fraction, deficit / total_load)

      extra_details =
        opts
        |> Keyword.take([:frequency_nadir, :gov_response_mw])
        |> Map.new()

      {updated_loads, shed_events} =
        Enum.map_reduce(loads, [], fn load, events ->
          shed_mw = load.p_mw * actual_shed_fraction

          if shed_mw <= 0.0 do
            # Zero-MW shed on an already-dark (or zero-demand) load: emitting
            # an event per such load floods national-scale cascades with tens
            # of thousands of meaningless events.
            {load, events}
          else
            updated = %{
              load
              | p_mw: load.p_mw - shed_mw,
                q_mvar: (load.q_mvar || 0.0) * (1.0 - actual_shed_fraction)
            }

            event = %{
              component_type: "load",
              component_id: load.id,
              failure_cause: "ufls_shed",
              details:
                Map.merge(extra_details, %{
                  shed_mw: shed_mw,
                  shed_fraction: actual_shed_fraction,
                  remaining_mw: updated.p_mw
                })
            }

            {updated, [event | events]}
          end
        end)

      {updated_loads, Enum.reverse(shed_events)}
    end
  end
end
