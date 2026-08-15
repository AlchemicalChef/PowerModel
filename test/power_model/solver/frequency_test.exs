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

  test "2HS floor is continuous across small fleet changes (ENE-4)" do
    loads = [%{p_mw: 15.0}]
    wind = fn mw -> %{p_max_mw: mw, capacity_factor: 1.0, fuel_type: "wind"} end
    gas = fn mw -> %{p_max_mw: mw, capacity_factor: 1.0, fuel_type: "gas"} end

    # h_sys straddles the old `h_sys < 0.01 -> 0.5` floor: 0.0098 vs 0.0105.
    # Flooring the H constant made these near-identical fleets differ ~47x in
    # first-step RoCoF; flooring the 2HS product keeps them within a few %.
    fleet_a = [gas.(2.8), wind.(997.2)]
    fleet_b = [gas.(3.0), wind.(997.0)]

    first_step_drop = fn fleet ->
      trajectory = Frequency.simulate(fleet, loads, 0.5)
      60.0 - Enum.at(trajectory, 1).frequency
    end

    drop_a = first_step_drop.(fleet_a)
    drop_b = first_step_drop.(fleet_b)

    assert drop_a > 0.0
    assert drop_b > 0.0
    assert max(drop_a, drop_b) / min(drop_a, drop_b) < 2.0
  end

  test "an unstable caller-supplied dt is shrunk to satisfy the Euler bound (ENE-5)" do
    # beta = dt*D*Pload/(2HS) = 5.0 * 1.0 * 900 / 900 = 5.0 > 2: the raw step
    # diverges into a 55/65 Hz square wave (Swing.lean beta_lt_two_iff).
    # simulate/5 must shrink dt so beta <= 1 and integrate stably.
    generators = [%{p_max_mw: 1000.0, capacity_factor: 0.9, fuel_type: "wind"}]
    loads = [%{p_mw: 900.0}]

    trajectory = Frequency.simulate(generators, loads, 3.0, 5.0, 30.0)

    # dt shrunk 5.0 -> 1.0 (beta 5 -> 1): 30 steps, first record at t=1.0
    assert Enum.at(trajectory, 1).time == 1.0
    assert length(trajectory) == 31

    # Stable decay to the ~59.8 Hz equilibrium: no oscillation, no UFLS
    assert Enum.all?(trajectory, &(&1.frequency >= 59.5))
    assert List.last(trajectory).load_shed_mw == 0.0
    refute Frequency.collapsed?(trajectory)
  end

  test "clamp-touching trajectories are flagged collapsed (ENE-5)" do
    loads = [%{p_mw: 100.0}]

    trajectory = Frequency.simulate([], loads, 100.0)

    assert Frequency.collapsed?(trajectory)
    assert Frequency.nadir(trajectory) == 55.0
    refute hd(trajectory).collapsed
    assert List.last(trajectory).collapsed
  end

  test "duration shorter than one time step returns only the initial record (ENE-11)" do
    generators = [%{p_max_mw: 100.0, capacity_factor: 0.5, fuel_type: "gas"}]
    loads = [%{p_mw: 50.0}]

    assert [record] = Frequency.simulate(generators, loads, 10.0, 0.1, 0.04)
    assert record.time == 0.0
    assert record.frequency == 60.0
    refute record.collapsed
  end

  test "UFLS stages shed a fraction of the currently-connected load (ENE-6)" do
    # Slow nuclear fleet with a deep deficit: stages trip sequentially, so
    # stage 2 must shed 7.5% of (900 - 67.5), not of the original 900.
    generators = [%{p_max_mw: 1000.0, capacity_factor: 0.9, fuel_type: "NUC"}]
    loads = [%{p_mw: 900.0}]

    trajectory = Frequency.simulate(generators, loads, 200.0)

    shed_values = trajectory |> Enum.map(& &1.load_shed_mw) |> Enum.uniq()

    assert [zero, first, second | _] = shed_values
    assert zero == 0.0
    assert_in_delta first, 0.075 * 900.0, 0.01
    assert_in_delta second - first, 0.075 * (900.0 - 67.5), 0.02
  end

  test "EIA fuel codes map to their fuel classes (PLT-3)" do
    h = fn code ->
      {h_sys, _s_sys} = Frequency.system_inertia([%{p_max_mw: 100.0, fuel_type: code}])
      h_sys
    end

    for code <- ["SUB", "LIG", "RC", "WC", "BIT"] do
      assert h.(code) == 4.0, "#{code} should carry coal inertia"
    end

    assert h.("NUC") == 6.0
    assert h.("NG") == 3.5
    assert h.("WAT") == 3.0
    assert h.("WND") == 0.0
    assert h.("SUN") == 0.0
    # battery storage: inverter-based, zero inertia
    assert h.("MWH") == 0.0
    # oil-fired steam units
    assert h.("DFO") == 4.0
    assert h.("RFO") == 4.0
    assert h.("GEO") == 3.5
  end

  test "MWH storage provides no governor response (PLT-3)" do
    generators = [%{p_max_mw: 100.0, capacity_factor: 0.5, fuel_type: "MWH"}]
    loads = [%{p_mw: 50.0}]

    trajectory = Frequency.simulate(generators, loads, 10.0)

    assert Enum.all?(trajectory, &(&1.gov_response_mw == 0.0))
  end

  test "GEO responds with a slow steam governor, not a fast gas turbine (PLT-3)" do
    loads = [%{p_mw: 50.0}]

    gov_at_step_2 = fn fuel ->
      [%{p_max_mw: 100.0, capacity_factor: 0.5, fuel_type: fuel}]
      |> Frequency.simulate(loads, 5.0)
      |> Enum.at(2)
      |> Map.get(:gov_response_mw)
    end

    geo = gov_at_step_2.("GEO")
    gas = gov_at_step_2.("NG")

    assert geo > 0.0
    assert gas > geo * 5.0
  end
end
