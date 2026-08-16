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

  ## Undervoltage load shedding (ROADMAP item 20)

  `apply_uvls_with_state/4` is the voltage-driven sibling of the UFLS pair
  above, and deliberately the same shape: a staged program in a module
  attribute, a `{loads, events, state}` return, and persistent stage state so
  successive cascade segments compound instead of rearming.

  Two things differ, and both follow from the physics:

    * **UVLS is LOCAL.** Frequency is an island-wide scalar; voltage is not.
      Each load bus has its own relay, its own measurement and its own timer,
      so the state is keyed by bus and a depressed pocket sheds while the rest
      of the island does not. That pocket is what a voltage collapse looks
      like, and an island-average voltage would erase it.
    * **UVLS is TIMED, not nadir-driven.** A UFLS stage is decided by the
      frequency nadir. A UVLS stage must see its voltage held below threshold
      for the stage's full delay; if voltage recovers, the timer drops out and
      resets. That is why `apply_uvls_with_state/4` takes a `dt_s` — it is
      integrating a timer, not reading an extremum.
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

  # ===========================================================================
  # Undervoltage load shedding (ROADMAP item 20)
  # ===========================================================================

  # UVLS stages: `{threshold_pu, shed_fraction, delay_s}`, shallowest first.
  #
  # Shaped after the utility UVLS programs NERC PRC-010-2 requires entities to
  # document and validate, and the WECC-region schemes described in NERC's
  # "Undervoltage Load Shedding" reliability guideline: a first block in the
  # low 0.9s with a long enough delay to let generator excitation, switched
  # shunts and tap changers act first, then faster and larger blocks as the
  # voltage keeps falling. The programs are utility-specific and none of them
  # is canonical; these are the documented defaults this model uses, and they
  # live only here.
  #
  # Note the inversion against UFLS: deeper voltage means a SHORTER delay,
  # because a bus that has not recovered by 0.86 pu is on the unstable side of
  # the P-V nose and waiting costs more than shedding.
  @uvls_stages [
    {0.92, 0.05, 8.0},
    {0.89, 0.05, 5.0},
    {0.86, 0.10, 3.0}
  ]

  @doc """
  The canonical UVLS program: `{threshold_pu, shed_fraction, delay_s}` per
  stage, shed fractions incremental, shallowest stage first. Single source of
  truth — 20% cumulative with every stage in.
  """
  def uvls_stages, do: @uvls_stages

  @doc """
  Static, delay-ignoring view of the UVLS program at a given voltage: every
  stage whose threshold `vm_pu` is below, with their CUMULATIVE fraction.

  The exact counterpart of `PowerModel.Failure.Protection.ufls_schedule/1`,
  and useful for the same reason — "what would this bus eventually shed if it
  sat here" — but it is NOT what `apply_uvls_with_state/4` does. Stages only
  fire once their delay has elapsed; this function ignores delays entirely.

  Returns `[]` above the first stage, else `[stage: n, shed_fraction: cum]`.
  """
  def uvls_schedule(vm_pu, stages \\ @uvls_stages) do
    tripped = Enum.filter(stages, fn {threshold_pu, _frac, _delay} -> vm_pu < threshold_pu end)

    case tripped do
      [] ->
        []

      fired ->
        cumulative = fired |> Enum.map(fn {_t, frac, _d} -> frac end) |> Enum.sum()
        [stage: length(fired), shed_fraction: cumulative]
    end
  end

  @doc """
  A fresh UVLS state: no bus has armed a timer and nothing has shed.

  Shape:

      %{
        buses: %{bus_id => [%{armed_s: float(), tripped: boolean()}]},
        cumulative_shed_mw: float(),
        elapsed_s: float()
      }

  One stage entry per stage in `uvls_stages/0`, in the same order. Persist one
  state per island (or per cascade) and hand it back on the next segment.
  """
  def fresh_uvls_state do
    %{buses: %{}, cumulative_shed_mw: 0.0, elapsed_s: 0.0}
  end

  @doc """
  Apply undervoltage load shedding over a `dt_s` segment.

  Returns `{updated_loads, shed_events, uvls_state}`.

  ## Parameters

    * `loads` — load maps with `id`, `bus_id`, `p_mw`, `q_mvar`
    * `voltages` — either a `%{bus_id => vm_pu}` map or a single float applied
      to every load bus (island-wide form, for callers with no AC solution
      yet). A bus MISSING from the map has no measurement: its timers are
      left exactly as they were rather than being reset, because a missing
      reading is not a recovered voltage.
    * `dt_s` — simulated seconds this segment advanced. Timers integrate it.

  ## Options

    * `:uvls_state` — the state from a previous call, or `nil`
    * `:stages` — override the program (tests, sensitivity studies)

  ## Timer semantics

  Every stage whose threshold the bus voltage is below arms INDEPENDENTLY and
  counts up; a stage fires when its own delay has elapsed while continuously
  below. Voltage at or above the threshold drops the timer back to zero. A
  stage that has fired stays fired — the breakers are open, and re-firing it
  would shed the same feeders twice.

  ## Shed accounting

  A firing stage sheds its fraction of the load's CURRENT `p_mw`, the same
  convention `apply_proportional_shedding/5` uses for UFLS. Stages firing in
  the same segment are summed and applied once; stages firing in different
  segments therefore compound (0.05 then 0.05 leaves 0.9025, not 0.90). Q
  scales with P. A load already at zero MW emits no event.
  """
  @spec apply_uvls_with_state(list(map()), map() | number(), number(), keyword()) ::
          {list(map()), list(map()), map()}
  def apply_uvls_with_state(loads, voltages, dt_s, opts \\ []) do
    stages = Keyword.get(opts, :stages, @uvls_stages)
    state = Keyword.get(opts, :uvls_state) || fresh_uvls_state()
    dt = max(dt_s * 1.0, 0.0)

    bus_ids = loads |> Enum.map(&Map.get(&1, :bus_id)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    # Advance every measured bus's timers first, then shed. Doing it in this
    # order means one pass decides the whole segment: a bus cannot arm on a
    # voltage its own shedding has already invalidated.
    {bus_states, fired} =
      Enum.reduce(bus_ids, {state.buses, %{}}, fn bus_id, {acc_states, acc_fired} ->
        case bus_voltage(voltages, bus_id) do
          nil ->
            {acc_states, acc_fired}

          vm_pu ->
            prior = Map.get(acc_states, bus_id) || fresh_stage_states(stages)
            {advanced, fraction, stage_numbers} = advance_bus_stages(prior, stages, vm_pu, dt)

            acc_fired =
              if fraction > 0.0 do
                Map.put(acc_fired, bus_id, {fraction, stage_numbers, vm_pu})
              else
                acc_fired
              end

            {Map.put(acc_states, bus_id, advanced), acc_fired}
        end
      end)

    {updated_loads, events} = shed_uvls_blocks(loads, fired)

    shed_mw = events |> Enum.map(& &1.details.shed_mw) |> Enum.sum()

    new_state = %{
      state
      | buses: bus_states,
        cumulative_shed_mw: state.cumulative_shed_mw + shed_mw,
        elapsed_s: state.elapsed_s + dt
    }

    {updated_loads, events, new_state}
  end

  @doc """
  Stateless UVLS: `apply_uvls_with_state/4` with no incoming state and the
  outgoing state discarded, returning `{loads, events}`.

  Only the stages whose delay fits inside this single `dt_s` can fire, so a
  caller that wants a staged program to progress must use the stateful form.
  """
  def apply_uvls(loads, voltages, dt_s, opts \\ []) do
    {shed_loads, events, _state} = apply_uvls_with_state(loads, voltages, dt_s, opts)
    {shed_loads, events}
  end

  @doc """
  Restrict a UVLS state to a set of bus ids — the SPLIT half of island-state
  threading, and the exact counterpart of
  `PowerModel.Failure.Protection.split_voltage_state/2` and
  `PowerModel.Grid.BtmSolar.split_voltage_state/2`.

  UVLS stage timers are keyed by BUS and are INTENSIVE: "this bus has been
  below 0.89 pu for 3.2 s" is a property of the bus, not a quantity to share
  out. So unlike the frequency state's cumulative megawatts (which
  `PowerModel.Failure.Cascade` apportions by load share when an island splits),
  these need no scaling — partitioning by key is the whole operation and every
  timer is conserved exactly.

  `cumulative_shed_mw` IS extensive, and it is apportioned by the surviving
  buses' share of the state's own tally rather than carried whole into both
  halves. It is a report, not a control input — nothing in
  `apply_uvls_with_state/4` reads it back — so the apportionment only has to
  keep the two halves summing to the parent.

  Accepts a list, `MapSet` or map of bus ids.
  """
  @spec split_uvls_state(map() | nil, Enumerable.t()) :: map()
  def split_uvls_state(nil, _bus_ids), do: fresh_uvls_state()

  def split_uvls_state(state, bus_ids) do
    keep = MapSet.new(bus_ids)
    buses = Map.filter(state.buses, fn {id, _} -> MapSet.member?(keep, id) end)

    share =
      case map_size(state.buses) do
        0 -> 0.0
        n -> map_size(buses) / n
      end

    %{
      state
      | buses: buses,
        cumulative_shed_mw: Map.get(state, :cumulative_shed_mw, 0.0) * share
    }
  end

  defp bus_voltage(voltages, _bus_id) when is_number(voltages), do: voltages * 1.0
  defp bus_voltage(voltages, bus_id) when is_map(voltages), do: Map.get(voltages, bus_id)
  defp bus_voltage(_voltages, _bus_id), do: nil

  defp fresh_stage_states(stages),
    do: Enum.map(stages, fn _ -> %{armed_s: 0.0, tripped: false} end)

  # One bus's stage timers over one segment. Returns the advanced states, the
  # total fraction firing NOW, and which stage numbers fired (1-based, matching
  # the table order).
  defp advance_bus_stages(prior, stages, vm_pu, dt) do
    prior = pad_stage_states(prior, stages)

    {advanced, fraction, numbers} =
      stages
      |> Enum.zip(prior)
      |> Enum.with_index(1)
      |> Enum.reduce({[], 0.0, []}, fn {{{threshold_pu, frac, delay_s}, stage}, number},
                                       {acc, total, nums} ->
        cond do
          stage.tripped ->
            {[stage | acc], total, nums}

          vm_pu >= threshold_pu ->
            # Dropped out: the relay resets, it does not remember.
            {[%{stage | armed_s: 0.0} | acc], total, nums}

          true ->
            armed = stage.armed_s + dt

            if armed >= delay_s do
              {[%{armed_s: armed, tripped: true} | acc], total + frac, [number | nums]}
            else
              {[%{stage | armed_s: armed} | acc], total, nums}
            end
        end
      end)

    {Enum.reverse(advanced), min(fraction, 1.0), Enum.reverse(numbers)}
  end

  # A state carried over from a run with a shorter stage table must not
  # silently drop the stages off the end of it.
  defp pad_stage_states(prior, stages) when length(prior) >= length(stages), do: prior

  defp pad_stage_states(prior, stages) do
    missing = length(stages) - length(prior)
    prior ++ Enum.map(1..missing, fn _ -> %{armed_s: 0.0, tripped: false} end)
  end

  defp shed_uvls_blocks(loads, fired) when map_size(fired) == 0, do: {loads, []}

  defp shed_uvls_blocks(loads, fired) do
    {updated, events} =
      Enum.map_reduce(loads, [], fn load, acc ->
        case Map.get(fired, Map.get(load, :bus_id)) do
          nil ->
            {load, acc}

          {fraction, stage_numbers, vm_pu} ->
            shed_mw = load.p_mw * fraction

            if shed_mw <= 0.0 do
              {load, acc}
            else
              updated = %{
                load
                | p_mw: load.p_mw - shed_mw,
                  q_mvar: (load.q_mvar || 0.0) * (1.0 - fraction)
              }

              event = %{
                component_type: "load",
                component_id: load.id,
                failure_cause: "uvls_shed",
                details: %{
                  shed_mw: shed_mw,
                  shed_fraction: fraction,
                  remaining_mw: updated.p_mw,
                  stages: stage_numbers,
                  vm_pu: vm_pu
                }
              }

              {updated, [event | acc]}
            end
        end
      end)

    {updated, Enum.reverse(events)}
  end
end
