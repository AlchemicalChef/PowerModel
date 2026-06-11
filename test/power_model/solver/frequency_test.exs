defmodule PowerModel.Solver.FrequencyTest do
  use ExUnit.Case, async: true

  alias PowerModel.Solver.Frequency

  describe "simulate/5" do
    test "UFLS and governor pickup recover frequency after a large generation loss" do
      generators = [
        %{
          p_max_mw: 1000.0,
          capacity_factor: 0.8,
          fuel_type: "gas"
        }
      ]

      loads = [%{p_mw: 800.0}]

      trajectory = Frequency.simulate(generators, loads, 200.0, 0.1, 20.0)

      nadir = Frequency.nadir(trajectory)
      settling = Frequency.settling_frequency(trajectory)
      final = List.last(trajectory)

      assert nadir < 60.0
      assert final.load_shed_mw > 0.0
      assert settling > nadir
      assert settling > 59.0
    end
  end

  describe "helper functions" do
    test "nadir/1 returns the minimum frequency in the trajectory" do
      trajectory = [
        %{time: 0.0, frequency: 60.0},
        %{time: 1.0, frequency: 59.2},
        %{time: 2.0, frequency: 59.5}
      ]

      assert Frequency.nadir(trajectory) == 59.2
    end

    test "settling_frequency/1 returns the last frequency value" do
      trajectory = [
        %{time: 0.0, frequency: 60.0},
        %{time: 1.0, frequency: 59.6},
        %{time: 2.0, frequency: 59.8}
      ]

      assert Frequency.settling_frequency(trajectory) == 59.8
    end
  end
end
