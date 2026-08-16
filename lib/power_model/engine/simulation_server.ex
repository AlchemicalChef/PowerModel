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

  ## The broadcast contract (REVIEW UIW-3/4/5)

  Five PubSub messages leave this server: `dc_update`, `ac_update`,
  `cascade_step`, `cascade_done` and `reset`. Two rules govern their payloads.

  **Absence means "no information", never zero.** Every key this module adds
  beyond the original set is present only when it carries something. A step
  that ran no voltage layer has no `:voltage_layer` key; a step with no bus
  outside the overlay band has no `:bus_voltage` key. A consumer that reads a
  missing key as `0` would report "no undervoltage" for a cascade whose
  voltage layer never ran, which is the honest-degradation failure CAS-1
  exists to prevent.

  **There is one voltage authority, and it is structurally partial.** The
  cascade's own QSS-AC is the only thing that solves AC now; the post-cascade
  whole-grid FDPF refinement is gone (it re-solved the same island the cascade
  had just failed to solve, and CAS-1's all-or-nothing merge discarded the
  result at real demand — see `merge_ac_solutions/5`). What the cascade DID
  converge is forwarded on `ac_update` under the `:ac_overlay` key, covering
  those islands and saying nothing whatever about the rest. Nothing inside
  `:ac_overlay` may be merged into a whole-grid metric.
  """

  use GenServer, restart: :temporary

  require Logger

  alias PowerModel.Grid
  alias PowerModel.Solver.{DCPowerFlow, Solution, Partition}
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

  @doc """
  The session's live topology and base solve, for N-1 screening (UIW-2).

  Returns the ACTIVE snapshot (tripped components removed, generation set to
  the cascade's dispatch) plus the dispatch map and the DC solution already
  computed for it, so a screening sweep neither re-queries the database (4.6 s
  on Eastern) nor re-solves a base case the session has in hand.

  `:dc_solution` is `nil` before the first solve completes, and comes from
  `DCPowerFlow.solve_islands/2` — a MERGE of per-island solutions. A caller
  passing it to `ContingencyScreening.run/3` is asserting that the network is
  one island; on a split network, let `run/2` solve its own base case.
  """
  def screening_snapshot(sim_id) do
    GenServer.call(via(sim_id), :screening_snapshot, @trip_timeout)
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

  def handle_call(:screening_snapshot, _from, state) do
    state = touch(state)

    reply = %{
      snapshot: active_snapshot(state),
      dc_solution: state.dc_solution,
      dispatch: state.cascade_state.dispatch,
      base_mva: state.base_mva,
      interconnection_id: state.interconnection_id,
      hour: state.hour,
      # The epoch a sweep was started against: a result computed here is
      # stale the moment another trip lands, exactly as for AC refinements.
      epoch: state.epoch
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

  # Every cause under which a load loses demand. Frequency-driven shedding
  # ("ufls_shed", plus "ufls" kept for safety), the voltage-driven stage
  # ("uvls_shed" -- absent here before UIW-6), and an island going dark.
  @shed_causes ~w(ufls_shed ufls uvls_shed island_blackout)

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

        # UIW-4: the voltage picture comes from the cascade's own per-island
        # AC solves, not from a second whole-grid FDPF. Sent BEFORE
        # cascade_done so the terminal status the UI settles on is the
        # cascade's, not "AC solved".
        broadcast_voltage_overlay(state, step_results)

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

  # UIW-3. Four additive keys beyond the original five:
  #
  #   :reason              why the cascade stopped, from `Cascade.termination/1`
  #                        on the FINAL STATE. Never derived from the step
  #                        stream: the budget clause fires instead of a step,
  #                        so `:budget_exhausted` is stamped onto the returned
  #                        list and the callback stream never carries it.
  #                        `stable` alone cannot separate a truncated run from
  #                        a collapse -- both leave it false, and reading a
  #                        truncated run as a collapse is the false-10x hazard.
  #   :voltage_layer       AC coverage counters for the whole cascade.
  #   :btm_trip_breakdown  rooftop MW lost, split frequency vs voltage. The
  #                        wire balance's `btm_tripped_mw` is the total; this
  #                        says which mechanism took it.
  #   :agc                 the final per-island secondary-control summaries,
  #                        read off the last step result so this module does
  #                        not re-derive what the cascade already published.
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
      balance: Cascade.balance(final_cascade),
      reason: Cascade.termination(final_cascade),
      voltage_layer: final_cascade.voltage_layer,
      btm_trip_breakdown: final_cascade.btm_trip_breakdown,
      agc: final_step_agc(step_results)
    }
  end

  defp final_step_agc([]), do: []

  defp final_step_agc(step_results) do
    step_results |> List.last() |> Map.get(:agc) |> List.wrap()
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

  # The size above which an island is not attempted at all. This module no
  # longer runs any AC solve of its own (UIW-4 removed the post-cascade
  # refinement: it re-attempted the same island the cascade had just failed to
  # solve, and the merge below then discarded the result), so the cap survives
  # only as the coverage guard's threshold and as the number the `{:partial,
  # reason}` message quotes.
  @max_ac_island_buses 60_000

  # UIW-4. The cascade's converged per-island voltages, forwarded once per
  # cascade on the `ac_update` message (the name is kept so the client's
  # existing AC branch needs no change).
  #
  # The DC classification lists ride along unchanged from the `dc_update` that
  # fired immediately before: the client's AC branch delegates to its DC
  # painter, which CLEARS every flow state before applying the lists it is
  # given, so an overlay without them would blank the map that was just
  # painted. Sending the same lists makes that repaint idempotent.
  #
  # Every AC-derived number stays inside `:ac_overlay`. CAS-1's rule is that a
  # solve covering a subset of islands may never speak for the grid, and this
  # channel covers whatever subset the cascade reached -- typically none of the
  # main island at real demand.
  defp broadcast_voltage_overlay(state, step_results) do
    case voltage_overlay_payload(step_results) do
      nil ->
        :ok

      overlay ->
        payload =
          state.dc_solution
          |> solution_payload(state)
          |> Map.put(:partial_ac, true)
          |> Map.put(:ac_overlay, overlay)

        broadcast(state.sim_id, "ac_update", payload)
    end
  end

  @doc """
  The `:ac_overlay` value for a finished cascade, or `nil` when no island
  reached an AC solution (the ordinary case at real demand).

  Built from the LAST step that converged something: earlier steps' overlays
  describe topologies the cascade has since torn up.
  """
  def voltage_overlay_payload(step_results) do
    step_results
    |> Enum.reverse()
    |> Enum.find_value(fn step ->
      case Map.get(step, :voltage_overlay) do
        %{islands: [_ | _]} = overlay -> overlay_payload(overlay)
        _ -> nil
      end
    end)
  end

  defp overlay_payload(overlay) do
    %{
      # Structural, not a status: this covers the islands AC reached and is
      # silent about the rest. Never average or total it with DC results.
      partial: true,
      island_count: length(overlay.islands),
      covered_bus_count: overlay.covered_bus_count,
      undervoltage_bus_ids: overlay.undervoltage_bus_ids,
      overvoltage_bus_ids: overlay.overvoltage_bus_ids,
      islands:
        Enum.map(overlay.islands, fn island ->
          %{
            island_id: island.island_id,
            at_s: island.at_s,
            bus_count: island.bus_count,
            undervoltage_bus_ids: island.undervoltage_bus_ids,
            overvoltage_bus_ids: island.overvoltage_bus_ids,
            # The FULL magnitude map, deliberately: a per-cell minimum over an
            # H3 hexbin needs every bus in the cell, not only the ones already
            # outside the band. Rounded to 1e-4 pu, which is two orders of
            # magnitude finer than any band edge and roughly halves the bytes.
            vm_by_bus: round_vm(island.vm_by_bus)
          }
        end)
    }
  end

  defp round_vm(vm_by_bus) do
    Map.new(vm_by_bus, fn {bus_id, vm} -> {bus_id, Float.round(vm * 1.0, 4)} end)
  end

  @doc """
  CAS-1: an AC solution may only replace the DC picture when it covers EVERY
  island the DC solve covered. A merge of a strict subset of islands used to
  be broadcast as whole-grid authoritative, erasing marks and collapsing
  metrics to the fragment's totals on every skipped island.

  Returns `{:ok, merged_solution}` only when no island was skipped for size
  and all `n_islands` solvable islands produced a converged AC solution;
  `{:partial, reason}` otherwise (honest degradation: the DC results stand).

  UIW-4 removed this module's only caller — the post-cascade refinement that
  re-solved, per trip, the same island the cascade had just failed to solve.
  The rule it encodes did not go away with it: it is why the cascade's own
  per-island voltages travel as `:ac_overlay` rather than as a solution.
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
    # UIW-6: "uvls_shed" (LoadShedding's voltage-driven stage) was missing
    # here, so a purely voltage-driven collapse produced an empty shed channel.
    shed_ids =
      trips
      |> Enum.filter(&(&1.failure_cause in @shed_causes))
      |> Enum.map(& &1.component_id)

    bus_by_load = bus_by_load(state)

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

    {panel_trips, trips_omitted} = panel_trips(trips, bus_by_load)

    %{
      step: step.step,
      simulated_time: Map.get(step, :simulated_time, 0.0),
      islands: step.islands,
      trips: panel_trips,
      tripped_line_ids: tripped_line_ids,
      tripped_transformer_ids: tripped_transformer_ids,
      tripped_generator_ids: tripped_generator_ids,
      # The TRUE event count for this step, not `length(trips)`: `trips` is the
      # itemized-plus-aggregated view built for the panel. This is the number
      # that reconciles with the balance's shed MW.
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
    |> put_present(:trips_omitted, if(trips_omitted > 0, do: trips_omitted))
    |> put_present(:shed_bus_ids, shed_bus_ids(trips, bus_by_load))
    |> put_present(:voltage_layer, Map.get(step, :voltage_layer))
    |> put_present(:frequency, Map.get(step, :frequency))
    |> put_present(:agc, Map.get(step, :agc))
    |> put_present(:bus_voltage, violating_bus_voltage(Map.get(step, :voltage_overlay)))
  end

  # A key is added only when it carries information (UIW-3). `false` and `0.0`
  # are information; `nil`, `[]` and `%{}` are not, and shipping them would let
  # a consumer read "the voltage layer found no violation" off a cascade whose
  # voltage layer never ran.
  defp put_present(payload, _key, nil), do: payload
  defp put_present(payload, _key, []), do: payload
  defp put_present(payload, _key, empty) when empty == %{}, do: payload
  defp put_present(payload, key, value), do: Map.put(payload, key, value)

  @doc """
  Per-bus magnitudes for the buses a step left OUTSIDE the overlay band.

  The full magnitude map is far larger and travels once per cascade on
  `ac_update`, not once per step; what a step needs is the alarm set. Returns
  `%{}` when the voltage layer produced nothing, and the caller then omits the
  key rather than shipping an empty map that reads as "no violations".

  The band is the cascade's overlay band (0.9/1.1 pu), applied by
  `Cascade`, and it is deliberately TIGHTER than the 0.85/1.15 alarm band the
  protection layer trips on. They answer different questions; do not reconcile
  them.
  """
  def violating_bus_voltage(%{islands: islands}) when is_list(islands) do
    Enum.reduce(islands, %{}, fn island, acc ->
      island.undervoltage_bus_ids
      |> Enum.concat(island.overvoltage_bus_ids)
      |> Enum.reduce(acc, fn bus_id, acc ->
        case Map.fetch(island.vm_by_bus, bus_id) do
          {:ok, vm} -> Map.put(acc, bus_id, Float.round(vm * 1.0, 4))
          :error -> acc
        end
      end)
    end)
  end

  def violating_bus_voltage(_overlay), do: %{}

  @max_itemized_trips 200

  @doc """
  The panel view of one step's trips: `{events, omitted_count}`.

  UIW-5. A collapse emits one event per shed load -- 11,304 of them in the
  ERCOT reference cascade, 2.2 MB of JSON in a single frame. The map paints
  none of them (it reads the typed id lists) and the panel can show fifty
  rows, so per-load shedding travels as ONE synthetic event per cause per step
  and the itemized remainder is capped at #{@max_itemized_trips}.

  `bus_by_load` maps load id to bus id, which is what lets an aggregate name
  the island it came from.

  This is a VIEW, not the truth: the step payload's `trip_count` stays the
  true event total, so anything reconciling counts against the balance's shed
  MW is unaffected by either the aggregation or the cap.
  """
  def panel_trips(trips, bus_by_load) do
    {shed, itemized} =
      Enum.split_with(trips, &(&1.component_type == "load" and &1.failure_cause in @shed_causes))

    kept = cap_itemized(itemized)
    {kept ++ shed_aggregates(shed, bus_by_load), length(itemized) - length(kept)}
  end

  # The cap reserves a slot for the FIRST event of every cause before filling
  # the rest chronologically. A step where one relay type fires 199 times must
  # not hide the single distance-zone or voltage event that fired after it --
  # those rarer causes are usually the ones worth reading.
  defp cap_itemized(itemized) when length(itemized) <= @max_itemized_trips, do: itemized

  defp cap_itemized(itemized) do
    indexed = Enum.with_index(itemized)

    reserved =
      indexed
      |> Enum.uniq_by(fn {trip, _i} -> trip.failure_cause end)
      |> Enum.take(@max_itemized_trips)
      |> MapSet.new(fn {_trip, i} -> i end)

    filler =
      indexed
      |> Enum.reject(fn {_trip, i} -> MapSet.member?(reserved, i) end)
      |> Enum.take(@max_itemized_trips - MapSet.size(reserved))
      |> MapSet.new(fn {_trip, i} -> i end)

    keep = MapSet.union(reserved, filler)

    for {trip, i} <- indexed, MapSet.member?(keep, i), do: trip
  end

  # One synthetic event per shed cause per step.
  #
  # `component_id` is the lowest BUS id among the aggregated loads, which is
  # the identifier convention island-level events already use (`btm_trip`,
  # `island_blackout`). It names the island exactly when a single island shed
  # in this step -- the ordinary case, since shedding is applied per island --
  # and the lowest of them otherwise.
  #
  # `details.frequency_nadir` is the MINIMUM over the group, not the mean:
  # the UI's frequency metric is a running minimum over shed events, so the
  # aggregate has to preserve the deepest dip or the reported nadir rises.
  defp shed_aggregates([], _bus_by_load), do: []

  defp shed_aggregates(shed, bus_by_load) do
    shed
    |> Enum.group_by(& &1.failure_cause)
    |> Enum.map(fn {cause, events} ->
      nadirs =
        events
        |> Enum.map(&get_in(&1, [:details, :frequency_nadir]))
        |> Enum.filter(&is_number/1)

      %{
        component_type: "island",
        component_id: aggregate_id(events, bus_by_load),
        failure_cause: cause,
        details:
          %{
            aggregated: true,
            count: length(events),
            shed_mw: Enum.reduce(events, 0.0, &(&2 + shed_event_mw(&1)))
          }
          |> put_present(:frequency_nadir, Enum.min(nadirs, fn -> nil end))
      }
    end)
    |> Enum.sort_by(& &1.failure_cause)
  end

  defp aggregate_id(events, bus_by_load) do
    events
    |> Enum.map(&Map.get(bus_by_load, &1.component_id, &1.component_id))
    |> Enum.min(fn -> nil end)
  end

  defp bus_by_load(state) do
    Map.new(state.cascade_state.loads, &{&1.id, &1.bus_id})
  end

  @doc """
  The BUSES that lost demand this step, deduplicated.

  The map paints buses, not loads, and `:shed_ids` carries LOAD ids and is
  dropped before the client sees it — so without this the shed marks had no
  producer at all. One bus commonly carries several loads, so this is
  materially smaller than the load-id channel it replaces on the wire.

  Resolved only from `component_type: "load"` events, deliberately: load,
  generator and line ids are separate id spaces with colliding integers, so a
  non-load event whose `component_id` happened to match a load id would
  otherwise mark that load's bus. `:shed_ids` keeps its looser filter for
  compatibility — it has no consumers and is dropped at the client seam.
  """
  def shed_bus_ids(trips, bus_by_load) do
    trips
    |> Enum.filter(&(&1.component_type == "load" and &1.failure_cause in @shed_causes))
    |> Enum.map(&Map.get(bus_by_load, &1.component_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # UFLS/UVLS report what they took as `shed_mw`; an island blackout reports it
  # as `lost_mw`. Both are MW of demand removed at this step.
  defp shed_event_mw(%{details: %{} = details}) do
    (Map.get(details, :shed_mw) || Map.get(details, :lost_mw) || 0.0) * 1.0
  end

  defp shed_event_mw(_event), do: 0.0

  @doc """
  The `cascade_step` payload with the channels no browser reads removed.

  `:shed_bus_ids` is NOT dropped: it is the map's shed channel and replaces the
  load-id channel below. Adding a key here that the map paints from would blank
  the shed marks.

  `:trips`, `:water_facility_trips`, `:datacenter_trips` and `:shed_ids` exist
  for the LiveView, which builds the Affected panel and the frequency metric
  from them server-side. Nothing in `assets/js` reads any of the four (UIW-4),
  and on the reference cascade they are essentially the entire frame. Push the
  result of this function to the client; keep the PubSub payload for the
  LiveView's own assigns.
  """
  @client_dropped_keys [:trips, :water_facility_trips, :datacenter_trips, :shed_ids]

  def client_step_payload(payload) when is_map(payload) do
    Map.drop(payload, @client_dropped_keys)
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
