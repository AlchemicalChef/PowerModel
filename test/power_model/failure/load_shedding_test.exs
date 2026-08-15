defmodule PowerModel.Failure.LoadSheddingTest do
  use ExUnit.Case, async: true

  alias PowerModel.Failure.LoadShedding

  defp grid_load(id, p_mw, q_mvar \\ 0.0) do
    %{id: id, bus_id: id, p_mw: p_mw, q_mvar: q_mvar}
  end

  describe "apply_proportional_shedding/5" do
    test "empty load list returns unchanged with no events (no divide-by-zero)" do
      assert {[], []} = LoadShedding.apply_proportional_shedding([], 0.1, 50.0, 100.0)
    end

    test "all-zero loads with a positive deficit return unchanged with no events" do
      loads = [grid_load(1, 0.0), grid_load(2, 0.0)]

      assert {^loads, []} = LoadShedding.apply_proportional_shedding(loads, 0.5, 0.0, 10.0)
    end

    test "zero-MW loads produce no shed events and are left untouched" do
      loads = [grid_load(1, 100.0, 30.0), grid_load(2, 0.0), grid_load(3, 50.0)]

      {updated, events} = LoadShedding.apply_proportional_shedding(loads, 0.1, 135.0, 150.0)

      # Only the two loads that actually shed MW emit events, in load order
      assert Enum.map(events, & &1.component_id) == [1, 3]
      refute Enum.any?(events, fn e -> e.details.shed_mw == 0.0 end)

      # The already-dark load is bit-identical
      assert Enum.find(updated, &(&1.id == 2)) == grid_load(2, 0.0)
    end

    test "sheds proportionally and event totals equal the shed amount" do
      loads = [grid_load(1, 100.0, 30.0), grid_load(2, 50.0, 10.0)]

      {updated, events} = LoadShedding.apply_proportional_shedding(loads, 0.1, 135.0, 150.0)

      total_after = Enum.sum(Enum.map(updated, & &1.p_mw))
      event_shed = Enum.sum(Enum.map(events, & &1.details.shed_mw))

      assert length(events) == 2
      assert_in_delta total_after, 135.0, 1.0e-9
      assert_in_delta event_shed, 15.0, 1.0e-9

      # Reactive power scales with the same fraction
      first = Enum.find(updated, &(&1.id == 1))
      assert_in_delta first.q_mvar, 27.0, 1.0e-9
    end

    test "no shedding when there is no deficit" do
      loads = [grid_load(1, 100.0)]

      assert {^loads, []} = LoadShedding.apply_proportional_shedding(loads, 0.1, 100.0, 100.0)
    end

    test "shed fraction is capped at the deficit" do
      loads = [grid_load(1, 100.0)]

      {updated, events} = LoadShedding.apply_proportional_shedding(loads, 0.9, 90.0, 100.0)

      assert [event] = events
      assert_in_delta event.details.shed_mw, 10.0, 1.0e-9
      assert_in_delta hd(updated).p_mw, 90.0, 1.0e-9
    end
  end

  describe "apply_ufls/4" do
    test "balanced island sheds nothing" do
      loads = [grid_load(1, 100.0)]
      gens = [%{id: 1, bus_id: 2, p_max_mw: 100.0, capacity_factor: 1.0}]

      assert {^loads, []} = LoadShedding.apply_ufls(loads, gens, 100.0, 100.0)
    end
  end

  # ===========================================================================
  # Persistent frequency state (ROADMAP item 15)
  # ===========================================================================

  describe "apply_ufls_with_state/5" do
    defp island_gens do
      [
        %{id: 1, bus_id: 1, p_max_mw: 1000.0, capacity_factor: 0.6, fuel_type: "NG"},
        %{id: 2, bus_id: 1, p_max_mw: 500.0, capacity_factor: 0.6, fuel_type: "BIT"}
      ]
    end

    test "apply_ufls/4 is apply_ufls_with_state/5 with the state dropped" do
      loads = [grid_load(1, 900.0)]

      {stateless_loads, stateless_events} =
        LoadShedding.apply_ufls(loads, island_gens(), 780.0, 900.0)

      {stateful_loads, stateful_events, state} =
        LoadShedding.apply_ufls_with_state(loads, island_gens(), 780.0, 900.0)

      assert stateless_loads == stateful_loads
      assert stateless_events == stateful_events
      assert is_map(state)
      assert state.lost_mw == 120.0
    end

    test "a balanced island returns the state it was handed, untouched" do
      loads = [grid_load(1, 100.0)]

      assert {^loads, [], nil} =
               LoadShedding.apply_ufls_with_state(loads, island_gens(), 100.0, 100.0)

      {_, _, state} = LoadShedding.apply_ufls_with_state(loads, island_gens(), 80.0, 100.0)

      assert {^loads, [], ^state} =
               LoadShedding.apply_ufls_with_state(loads, island_gens(), 100.0, 100.0,
                 frequency_state: state
               )
    end

    test "a second deficit on a depressed island settles lower than from 60 Hz" do
      loads = [grid_load(1, 900.0)]

      {after_first, first_events, state} =
        LoadShedding.apply_ufls_with_state(loads, island_gens(), 780.0, 900.0)

      assert nadir_of(first_events) < 60.0
      assert state.frequency < 60.0

      served = Enum.sum(Enum.map(after_first, & &1.p_mw))

      # Same island, a further 60 MW short. Once starting from the state the
      # first event left behind, once from a cold 60.0 Hz with fresh reserves.
      {_after_second, _second_events, compounded} =
        LoadShedding.apply_ufls_with_state(
          after_first,
          island_gens(),
          served - 60.0,
          served,
          frequency_state: state
        )

      {_cold_loads, _cold_events, cold} =
        LoadShedding.apply_ufls_with_state(after_first, island_gens(), served - 60.0, served)

      assert compounded.frequency < cold.frequency
      assert compounded.frequency < state.frequency
    end

    test "a stage already spent is not offered to the second disturbance" do
      loads = [grid_load(1, 900.0)]

      {after_first, _events, state} =
        LoadShedding.apply_ufls_with_state(loads, island_gens(), 700.0, 900.0)

      spent = Enum.count(state.ufls_state, & &1.tripped)
      assert spent >= 1

      served = Enum.sum(Enum.map(after_first, & &1.p_mw))

      {_loads, events, next} =
        LoadShedding.apply_ufls_with_state(
          after_first,
          island_gens(),
          served - 5.0,
          served,
          frequency_state: state
        )

      # The stages that already opened stay open — the second event can only
      # reach stages the first left armed.
      for {before_stage, after_stage} <- Enum.zip(state.ufls_state, next.ufls_state) do
        if before_stage.tripped, do: assert(after_stage.tripped)
      end

      # And whatever it sheds is bounded by the deficit it was handed, never
      # by re-running the whole cumulative program.
      shed = events |> Enum.map(& &1.details.shed_mw) |> Enum.sum()
      assert shed <= 5.0 + 1.0e-6
    end

    test "the simulation's shed is read incrementally, not cumulatively" do
      # The trajectory's load_shed_mw is cumulative across every segment the
      # state has seen. Reading it whole on the second call would shed the
      # first call's megawatts a second time.
      loads = [grid_load(1, 900.0)]

      {after_first, first_events, state} =
        LoadShedding.apply_ufls_with_state(loads, island_gens(), 700.0, 900.0)

      first_shed = first_events |> Enum.map(& &1.details.shed_mw) |> Enum.sum()
      assert first_shed > 0.0
      assert state.cumulative_shed_mw > 0.0

      served = Enum.sum(Enum.map(after_first, & &1.p_mw))

      {_loads, events, _next} =
        LoadShedding.apply_ufls_with_state(
          after_first,
          island_gens(),
          served - 1.0,
          served,
          frequency_state: state
        )

      shed = events |> Enum.map(& &1.details.shed_mw) |> Enum.sum()
      assert shed < first_shed
      assert shed <= 1.0 + 1.0e-6
    end
  end

  # ===========================================================================
  # Undervoltage load shedding (ROADMAP item 20)
  # ===========================================================================

  describe "uvls_stages/0 and uvls_schedule/1" do
    test "the program is three stages, 20% cumulative, deepest stage fastest" do
      stages = LoadShedding.uvls_stages()

      assert [{0.92, 0.05, 8.0}, {0.89, 0.05, 5.0}, {0.86, 0.10, 3.0}] = stages

      thresholds = Enum.map(stages, fn {t, _f, _d} -> t end)
      delays = Enum.map(stages, fn {_t, _f, d} -> d end)

      assert thresholds == Enum.sort(thresholds, :desc)
      # Deeper voltage means a SHORTER delay — the inversion against UFLS.
      assert delays == Enum.sort(delays, :desc)
      assert_in_delta Enum.sum(Enum.map(stages, fn {_t, f, _d} -> f end)), 0.20, 1.0e-9
    end

    test "the static schedule is cumulative over the stages a voltage passes" do
      assert LoadShedding.uvls_schedule(0.95) == []
      assert LoadShedding.uvls_schedule(0.92) == []
      assert LoadShedding.uvls_schedule(0.90) == [stage: 1, shed_fraction: 0.05]

      assert [stage: 2, shed_fraction: f2] = LoadShedding.uvls_schedule(0.87)
      assert_in_delta f2, 0.10, 1.0e-9

      assert [stage: 3, shed_fraction: f3] = LoadShedding.uvls_schedule(0.85)
      assert_in_delta f3, 0.20, 1.0e-9
    end
  end

  describe "apply_uvls_with_state/4" do
    defp depressed_bus_loads do
      [grid_load(1, 1000.0, 300.0)]
    end

    defp shed_total(events), do: events |> Enum.map(& &1.details.shed_mw) |> Enum.sum()

    test "nothing sheds before the stage delay has elapsed" do
      loads = depressed_bus_loads()

      # 0.85 pu arms all three stages, but the fastest needs 3 s.
      {unchanged, events, state} = LoadShedding.apply_uvls_with_state(loads, 0.85, 2.0)

      assert unchanged == loads
      assert events == []
      assert state.cumulative_shed_mw == 0.0
      assert state.elapsed_s == 2.0
      assert [%{armed_s: 2.0}, %{armed_s: 2.0}, %{armed_s: 2.0}] = state.buses[1]
    end

    test "stage state persists across calls and the program progresses" do
      loads = depressed_bus_loads()

      {loads, none, s1} = LoadShedding.apply_uvls_with_state(loads, 0.85, 2.0)
      assert none == []

      # 4 s in: stage 3 (0.86 pu / 3 s) fires with a 10% block.
      {loads, third, s2} =
        LoadShedding.apply_uvls_with_state(loads, 0.85, 2.0, uvls_state: s1)

      assert [event] = third
      assert event.failure_cause == "uvls_shed"
      assert event.details.stages == [3]
      assert_in_delta event.details.shed_fraction, 0.10, 1.0e-9
      assert_in_delta event.details.shed_mw, 100.0, 1.0e-9
      assert_in_delta event.details.remaining_mw, 900.0, 1.0e-9
      assert event.details.vm_pu == 0.85

      # 6 s in: stage 2 (0.89 pu / 5 s) fires with a 5% block of what remains.
      {loads, second, s3} =
        LoadShedding.apply_uvls_with_state(loads, 0.85, 2.0, uvls_state: s2)

      assert [%{details: %{stages: [2]}}] = second
      assert_in_delta shed_total(second), 45.0, 1.0e-9

      # 8 s in: stage 1 (0.92 pu / 8 s) fires last, being the shallowest.
      {loads, first, s4} =
        LoadShedding.apply_uvls_with_state(loads, 0.85, 2.0, uvls_state: s3)

      assert [%{details: %{stages: [1]}}] = first

      # 10 s in: the program is spent.
      {_loads, spent, s5} =
        LoadShedding.apply_uvls_with_state(loads, 0.85, 2.0, uvls_state: s4)

      assert spent == []
      assert Enum.all?(s5.buses[1], & &1.tripped)
    end

    test "several stages can fire in one long segment, and only once" do
      loads = depressed_bus_loads()

      {after_all, events, state} = LoadShedding.apply_uvls_with_state(loads, 0.85, 10.0)

      assert [event] = events
      assert event.details.stages == [1, 2, 3]
      assert_in_delta event.details.shed_fraction, 0.20, 1.0e-9
      assert_in_delta event.details.shed_mw, 200.0, 1.0e-9
      assert_in_delta hd(after_all).p_mw, 800.0, 1.0e-9
      # Q follows P through the same fraction.
      assert_in_delta hd(after_all).q_mvar, 240.0, 1.0e-9

      {_again, none, _} =
        LoadShedding.apply_uvls_with_state(after_all, 0.85, 10.0, uvls_state: state)

      assert none == []
    end

    test "blocks shed in different segments compound, as the docs say" do
      loads = depressed_bus_loads()

      # 0.90 pu only reaches stage 1 (5%), twice over is NOT 10%.
      {once, _, state} = LoadShedding.apply_uvls_with_state(loads, 0.90, 8.0)
      assert_in_delta hd(once).p_mw, 950.0, 1.0e-9

      # Stage 1 is spent; drop to 0.87 so stage 2 can fire on what is left.
      {twice, _, _} =
        LoadShedding.apply_uvls_with_state(once, 0.87, 5.0, uvls_state: state)

      assert_in_delta hd(twice).p_mw, 950.0 * 0.95, 1.0e-9
    end

    test "a recovering voltage drops the timer out, it does not remember" do
      loads = depressed_bus_loads()

      {loads, [], s1} = LoadShedding.apply_uvls_with_state(loads, 0.85, 2.0)
      # One second back at nominal resets every armed timer.
      {loads, [], s2} = LoadShedding.apply_uvls_with_state(loads, 1.0, 1.0, uvls_state: s1)
      assert Enum.all?(s2.buses[1], &(&1.armed_s == 0.0))

      # Two more seconds below is still short of the 3 s stage-3 delay.
      {unchanged, events, _s3} =
        LoadShedding.apply_uvls_with_state(loads, 0.85, 2.0, uvls_state: s2)

      assert unchanged == loads
      assert events == []
    end

    test "shedding is LOCAL: only the depressed pocket sheds" do
      loads = [grid_load(1, 400.0, 100.0), grid_load(2, 600.0, 150.0)]
      voltages = %{1 => 0.85, 2 => 1.0}

      {updated, events, state} = LoadShedding.apply_uvls_with_state(loads, voltages, 10.0)

      assert [event] = events
      assert event.component_id == 1
      assert_in_delta event.details.shed_mw, 80.0, 1.0e-9

      assert_in_delta Enum.find(updated, &(&1.id == 1)).p_mw, 320.0, 1.0e-9
      assert Enum.find(updated, &(&1.id == 2)) == grid_load(2, 600.0, 150.0)

      # The healthy bus has a relay, it just never armed.
      assert Enum.all?(state.buses[2], &(&1.armed_s == 0.0 and not &1.tripped))
    end

    test "MW bookkeeping is conserved across loads and state" do
      loads = [grid_load(1, 400.0), grid_load(2, 600.0), grid_load(3, 250.0)]
      before_mw = Enum.sum(Enum.map(loads, & &1.p_mw))

      {updated, events, state} = LoadShedding.apply_uvls_with_state(loads, 0.85, 6.0)

      after_mw = Enum.sum(Enum.map(updated, & &1.p_mw))

      assert length(events) == 3
      assert_in_delta shed_total(events), before_mw - after_mw, 1.0e-9
      assert_in_delta state.cumulative_shed_mw, before_mw - after_mw, 1.0e-9

      # ...and it accumulates across segments rather than restarting.
      {updated2, events2, state2} =
        LoadShedding.apply_uvls_with_state(updated, 0.85, 6.0, uvls_state: state)

      final_mw = Enum.sum(Enum.map(updated2, & &1.p_mw))

      assert_in_delta state2.cumulative_shed_mw,
                      shed_total(events) + shed_total(events2),
                      1.0e-9

      assert_in_delta state2.cumulative_shed_mw, before_mw - final_mw, 1.0e-9
    end

    test "a bus with no voltage reading is left alone, timers and all" do
      loads = [grid_load(1, 400.0), grid_load(2, 600.0)]

      {loads, [], s1} = LoadShedding.apply_uvls_with_state(loads, %{1 => 0.85, 2 => 0.85}, 2.0)
      assert s1.buses[2] |> Enum.all?(&(&1.armed_s == 2.0))

      # Bus 2 drops out of the solution: no measurement is not a recovery.
      {updated, events, s2} =
        LoadShedding.apply_uvls_with_state(loads, %{1 => 0.85}, 2.0, uvls_state: s1)

      assert [%{component_id: 1}] = events
      assert Enum.find(updated, &(&1.id == 2)) == grid_load(2, 600.0)
      assert s2.buses[2] == s1.buses[2]
    end

    test "an already-dark load emits no event" do
      loads = [grid_load(1, 0.0), grid_load(2, 500.0)]

      {updated, events, _state} = LoadShedding.apply_uvls_with_state(loads, 0.85, 10.0)

      assert Enum.map(events, & &1.component_id) == [2]
      assert Enum.find(updated, &(&1.id == 1)) == grid_load(1, 0.0)
    end

    test "loads without a bus, and an empty island, are handled" do
      assert {[], [], state} = LoadShedding.apply_uvls_with_state([], 0.80, 30.0)
      assert state.buses == %{}

      orphan = [%{id: 1, bus_id: nil, p_mw: 100.0, q_mvar: 0.0}]
      assert {^orphan, [], _} = LoadShedding.apply_uvls_with_state(orphan, 0.80, 30.0)
    end

    test "a healthy voltage never sheds, however long the segment" do
      loads = depressed_bus_loads()

      assert {^loads, [], state} = LoadShedding.apply_uvls_with_state(loads, 0.93, 600.0)
      assert state.cumulative_shed_mw == 0.0
    end

    test "the stage table is overridable" do
      loads = depressed_bus_loads()
      stages = [{0.95, 0.25, 1.0}]

      {updated, events, _} =
        LoadShedding.apply_uvls_with_state(loads, 0.90, 2.0, stages: stages)

      assert [%{details: %{stages: [1], shed_fraction: 0.25}}] = events
      assert_in_delta hd(updated).p_mw, 750.0, 1.0e-9
    end

    test "apply_uvls/4 is apply_uvls_with_state/4 with the state dropped" do
      loads = depressed_bus_loads()

      {stateful_loads, stateful_events, _} =
        LoadShedding.apply_uvls_with_state(loads, 0.85, 10.0)

      assert {^stateful_loads, ^stateful_events} = LoadShedding.apply_uvls(loads, 0.85, 10.0)
    end

    test "negative or zero dt advances nothing" do
      loads = depressed_bus_loads()

      assert {^loads, [], state} = LoadShedding.apply_uvls_with_state(loads, 0.80, -5.0)
      assert state.elapsed_s == 0.0
      assert Enum.all?(state.buses[1], &(&1.armed_s == 0.0))
    end
  end

  defp nadir_of(events) do
    events
    |> Enum.map(&Map.get(&1.details, :frequency_nadir))
    |> Enum.filter(&is_number/1)
    |> Enum.min(fn -> 60.0 end)
  end
end
