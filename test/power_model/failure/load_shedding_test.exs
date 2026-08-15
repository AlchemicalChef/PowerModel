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

  defp nadir_of(events) do
    events
    |> Enum.map(&Map.get(&1.details, :frequency_nadir))
    |> Enum.filter(&is_number/1)
    |> Enum.min(fn -> 60.0 end)
  end
end
