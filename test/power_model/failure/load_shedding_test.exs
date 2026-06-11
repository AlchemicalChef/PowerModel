defmodule PowerModel.Failure.LoadSheddingTest do
  use ExUnit.Case, async: true

  alias PowerModel.Failure.LoadShedding

  describe "apply_proportional_shedding/5" do
    test "sheds low-priority load before critical load" do
      loads = [
        %{id: 1, bus_id: 1, p_mw: 50.0, q_mvar: 10.0, shed_priority: :low},
        %{id: 2, bus_id: 2, p_mw: 50.0, q_mvar: 10.0, critical: true}
      ]

      {updated, events} =
        LoadShedding.apply_proportional_shedding(loads, 0.5, 50.0, 100.0)

      low = Enum.find(updated, &(&1.id == 1))
      critical = Enum.find(updated, &(&1.id == 2))

      assert low.p_mw == 0.0
      assert critical.p_mw == 50.0
      assert length(events) == 1
      assert hd(events).component_id == 1
    end
  end

  describe "apply_ufls/3" do
    test "does not re-shed when an equal or lower UFLS stage was already applied" do
      loads = [
        %{
          id: 1,
          bus_id: 1,
          p_mw: 80.0,
          q_mvar: 20.0,
          ufls_stage: 2,
          ufls_cumulative_fraction: 0.20
        }
      ]

      {updated, events} = LoadShedding.apply_ufls(loads, 80.0, 100.0)

      assert updated == loads
      assert events == []
    end
  end

  describe "apply_uvls/2" do
    test "applies only incremental UVLS when stage escalates" do
      loads = [
        %{
          id: 1,
          bus_id: 1,
          p_mw: 100.0,
          q_mvar: 40.0,
          uvls_stage: 1,
          uvls_cumulative_fraction: 0.05
        }
      ]

      {updated, events} = LoadShedding.apply_uvls(loads, %{1 => 0.82})

      [load] = updated
      assert_in_delta load.p_mw, 95.0, 1.0e-6
      assert load.uvls_stage == 2
      assert_in_delta load.uvls_cumulative_fraction, 0.10, 1.0e-6
      assert length(events) == 1
      assert hd(events).failure_cause == "uvls"
      assert hd(events).details.stage == 2
    end
  end
end
