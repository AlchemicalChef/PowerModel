defmodule PowerModel.Solver.FrequencyTest do
  use ExUnit.Case, async: true

  alias PowerModel.Solver.Frequency

  test "under-frequency load shedding arrests the decline" do
    generators = [%{p_max_mw: 1000.0, capacity_factor: 0.9, fuel_type: "wind"}]
    loads = [%{p_mw: 900.0}]

    trajectory = Frequency.simulate(generators, loads, 50.0)
    final_record = List.last(trajectory)

    assert Frequency.nadir(trajectory) > 58.5
    assert final_record.load_shed_mw <= 0.075 * 900.0 + 0.01
  end

  test "governor response prevents UFLS for a supported generation loss" do
    generators = [%{p_max_mw: 1000.0, capacity_factor: 0.5, fuel_type: "gas"}]
    loads = [%{p_mw: 500.0}]

    trajectory = Frequency.simulate(generators, loads, 100.0)

    assert Frequency.nadir(trajectory) > 59.3
    assert Enum.all?(trajectory, &(&1.load_shed_mw == 0.0))
    assert Enum.any?(trajectory, &(&1.gov_response_mw > 0.0))
  end

  test "governors back down generation after load loss" do
    generators = [%{p_max_mw: 1000.0, capacity_factor: 0.5, fuel_type: "gas"}]
    loads = [%{p_mw: 500.0}]

    trajectory = Frequency.simulate(generators, loads, -200.0)
    settling_frequency = Frequency.settling_frequency(trajectory)

    assert Enum.max_by(trajectory, & &1.frequency).frequency < 65.0
    assert settling_frequency > 60.0
    assert settling_frequency < 65.0
    assert Enum.all?(trajectory, &(&1.gov_response_mw <= 0.0))
    assert Enum.any?(trajectory, &(&1.gov_response_mw < 0.0))
  end

  test "imports contribute no synchronous inertia" do
    {h_sys, s_sys} =
      Frequency.system_inertia([%{p_max_mw: 2000.0, fuel_type: "import"}])

    assert h_sys == 0.0
    assert s_sys == 2000.0
  end

  test "an empty de-energized system does not divide by zero" do
    trajectory = Frequency.simulate([], [], 100.0)

    assert length(trajectory) > 1
    assert Enum.all?(trajectory, &is_float(&1.frequency))
  end

  test "one crossed UFLS threshold sheds exactly one incremental stage" do
    generators = [%{p_max_mw: 1000.0, capacity_factor: 0.9, fuel_type: "wind"}]
    loads = [%{p_mw: 900.0}]

    trajectory = Frequency.simulate(generators, loads, 15.0)
    expected_stage_mw = 0.075 * 900.0

    assert Frequency.nadir(trajectory) < 59.3
    assert Frequency.nadir(trajectory) > 58.9
    assert List.last(trajectory).load_shed_mw == expected_stage_mw
    assert Enum.uniq(Enum.map(trajectory, & &1.load_shed_mw)) == [0.0, expected_stage_mw]
  end
end
