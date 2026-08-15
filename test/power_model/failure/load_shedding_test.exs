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
end
