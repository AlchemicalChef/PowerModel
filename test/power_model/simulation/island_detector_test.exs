defmodule PowerModel.Simulation.Cascading.IslandDetectorTest do
  use ExUnit.Case, async: true

  alias PowerModel.Simulation.Cascading.IslandDetector

  # ---------------------------------------------------------------------------
  # Helpers – plain-map builders
  # ---------------------------------------------------------------------------

  defp bus(id, opts \\ []) do
    %{
      id: id,
      bus_type: Keyword.get(opts, :bus_type, 1),
      base_kv: Keyword.get(opts, :base_kv, 138.0),
      vm_pu: 1.0,
      va_rad: 0.0
    }
  end

  defp line(id, from, to, opts \\ []) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      voltage_kv: Keyword.get(opts, :voltage_kv, 138.0),
      r_pu: Keyword.get(opts, :r_pu, 0.01),
      x_pu: Keyword.get(opts, :x_pu, 0.1),
      b_pu: Keyword.get(opts, :b_pu, 0.02),
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 100.0)
    }
  end

  defp transformer(id, from, to, opts \\ []) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      r_pu: Keyword.get(opts, :r_pu, 0.005),
      x_pu: Keyword.get(opts, :x_pu, 0.05),
      rated_mva: Keyword.get(opts, :rated_mva, 200.0),
      tap_ratio: Keyword.get(opts, :tap_ratio, 1.0)
    }
  end

  defp generator(id, bus_id, opts) do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      capacity_factor: Keyword.get(opts, :capacity_factor, 1.0),
      q_max_mvar: Keyword.get(opts, :q_max_mvar, 50.0),
      q_min_mvar: Keyword.get(opts, :q_min_mvar, -50.0)
    }
  end

  defp load(id, bus_id, opts) do
    %{
      id: id,
      bus_id: bus_id,
      p_mw: Keyword.get(opts, :p_mw, 50.0),
      q_mvar: Keyword.get(opts, :q_mvar, 20.0)
    }
  end

  # ===========================================================================
  # detect/3
  # ===========================================================================

  describe "detect/3" do
    test "simple connected graph (3 buses, 2 lines) -> 1 island" do
      buses = [bus(1), bus(2), bus(3)]
      lines = [line(1, 1, 2), line(2, 2, 3)]

      islands = IslandDetector.detect(Enum.map(buses, & &1.id), lines, [])

      assert length(islands) == 1
      [island] = islands
      assert MapSet.equal?(island, MapSet.new([1, 2, 3]))
    end

    test "disconnection: removing a bridge line -> 2 islands" do
      # Topology: 1 -- 2 -- 3.  Remove line 2-3 => island {1,2} and {3}.
      buses = [bus(1), bus(2), bus(3)]
      _all_lines = [line(1, 1, 2), line(2, 2, 3)]

      # Keep only line 1 (1-2); line 2 (2-3) is tripped
      active_lines = [line(1, 1, 2)]

      islands = IslandDetector.detect(Enum.map(buses, & &1.id), active_lines, [])

      assert length(islands) == 2
      island_sets = Enum.map(islands, &MapSet.to_list(&1) |> Enum.sort())
      assert [1, 2] in island_sets
      assert [3] in island_sets
    end

    test "fully disconnected buses -> each bus is its own island" do
      buses = [bus(1), bus(2), bus(3), bus(4)]
      # No lines, no transformers
      islands = IslandDetector.detect(Enum.map(buses, & &1.id), [], [])

      assert length(islands) == 4

      for island <- islands do
        assert MapSet.size(island) == 1
      end

      all_bus_ids = islands |> Enum.flat_map(&MapSet.to_list/1) |> Enum.sort()
      assert all_bus_ids == [1, 2, 3, 4]
    end

    test "ring topology stays connected when one line is removed" do
      # Ring: 1-2, 2-3, 3-1.  Remove line 3-1 => still one island.
      buses = [bus(1), bus(2), bus(3)]
      _ring_lines = [line(1, 1, 2), line(2, 2, 3), line(3, 3, 1)]

      # Remove line 3 (3-1); alternative path 1-2-3 keeps all connected
      active_lines = [line(1, 1, 2), line(2, 2, 3)]

      islands = IslandDetector.detect(Enum.map(buses, & &1.id), active_lines, [])

      assert length(islands) == 1
      [island] = islands
      assert MapSet.equal?(island, MapSet.new([1, 2, 3]))
    end

    test "transformer connects buses across voltage levels" do
      # Bus 1 (138kV) connected to bus 2 (345kV) only via transformer
      _buses = [bus(1, base_kv: 138.0), bus(2, base_kv: 345.0)]
      xfmrs = [transformer(1, 1, 2)]

      islands = IslandDetector.detect([1, 2], [], xfmrs)

      assert length(islands) == 1
      [island] = islands
      assert MapSet.equal?(island, MapSet.new([1, 2]))
    end

    test "mixed lines and transformers form correct topology" do
      # 1 --line-- 2 --xfmr-- 3 --line-- 4
      _buses = [bus(1), bus(2), bus(3), bus(4)]
      lines = [line(1, 1, 2), line(2, 3, 4)]
      xfmrs = [transformer(1, 2, 3)]

      islands = IslandDetector.detect([1, 2, 3, 4], lines, xfmrs)

      assert length(islands) == 1
      [island] = islands
      assert MapSet.equal?(island, MapSet.new([1, 2, 3, 4]))
    end

    test "removing transformer creates two islands" do
      # 1 --line-- 2    3 --line-- 4  (transformer 2-3 removed)
      _buses = [bus(1), bus(2), bus(3), bus(4)]
      lines = [line(1, 1, 2), line(2, 3, 4)]
      xfmrs = []  # transformer removed

      islands = IslandDetector.detect([1, 2, 3, 4], lines, xfmrs)

      assert length(islands) == 2
      island_sets = Enum.map(islands, &MapSet.to_list(&1) |> Enum.sort())
      assert [1, 2] in island_sets
      assert [3, 4] in island_sets
    end
  end

  # ===========================================================================
  # island_balance/3
  # ===========================================================================

  describe "island_balance/3" do
    test "generation surplus returns {:ok, surplus_mw}" do
      island = MapSet.new([1, 2])
      gens = [generator(1, 1, p_max_mw: 200.0, capacity_factor: 1.0)]
      loads = [load(1, 2, p_mw: 80.0)]

      assert {:ok, surplus} = IslandDetector.island_balance(island, gens, loads)
      assert_in_delta surplus, 120.0, 0.01
    end

    test "generation deficit returns {:deficit, deficit_mw}" do
      island = MapSet.new([1, 2])
      gens = [generator(1, 1, p_max_mw: 50.0, capacity_factor: 1.0)]
      loads = [load(1, 2, p_mw: 120.0)]

      assert {:deficit, deficit} = IslandDetector.island_balance(island, gens, loads)
      assert_in_delta deficit, 70.0, 0.01
    end

    test "exact balance returns {:ok, 0.0}" do
      island = MapSet.new([1])
      gens = [generator(1, 1, p_max_mw: 100.0, capacity_factor: 1.0)]
      loads = [load(1, 1, p_mw: 100.0)]

      assert {:ok, surplus} = IslandDetector.island_balance(island, gens, loads)
      assert_in_delta surplus, 0.0, 0.01
    end

    test "capacity_factor reduces effective generation" do
      island = MapSet.new([1])
      gens = [generator(1, 1, p_max_mw: 200.0, capacity_factor: 0.5)]
      loads = [load(1, 1, p_mw: 120.0)]

      # Effective gen = 200 * 0.5 = 100 MW, load = 120 MW => deficit 20 MW
      assert {:deficit, deficit} = IslandDetector.island_balance(island, gens, loads)
      assert_in_delta deficit, 20.0, 0.01
    end

    test "generators and loads outside the island are ignored" do
      island = MapSet.new([1])
      gens = [
        generator(1, 1, p_max_mw: 100.0),
        generator(2, 99, p_max_mw: 500.0)  # bus 99 not in island
      ]
      loads = [
        load(1, 1, p_mw: 60.0),
        load(2, 99, p_mw: 300.0)  # bus 99 not in island
      ]

      assert {:ok, surplus} = IslandDetector.island_balance(island, gens, loads)
      assert_in_delta surplus, 40.0, 0.01
    end

    test "island with no generation has full deficit" do
      island = MapSet.new([1])
      gens = []
      loads = [load(1, 1, p_mw: 50.0)]

      assert {:deficit, deficit} = IslandDetector.island_balance(island, gens, loads)
      assert_in_delta deficit, 50.0, 0.01
    end

    test "island with no load has full surplus" do
      island = MapSet.new([1])
      gens = [generator(1, 1, p_max_mw: 100.0)]
      loads = []

      assert {:ok, surplus} = IslandDetector.island_balance(island, gens, loads)
      assert_in_delta surplus, 100.0, 0.01
    end

    test "accepts a plain list as island argument" do
      # The function should handle both MapSet and list input
      island = [1, 2]
      gens = [generator(1, 1, p_max_mw: 100.0)]
      loads = [load(1, 2, p_mw: 40.0)]

      assert {:ok, surplus} = IslandDetector.island_balance(island, gens, loads)
      assert_in_delta surplus, 60.0, 0.01
    end
  end

  # ===========================================================================
  # assign_slack_buses/2
  # ===========================================================================

  describe "assign_slack_buses/2" do
    test "assigns bus with largest generation as slack per island" do
      islands = [
        MapSet.new([1, 2]),
        MapSet.new([3, 4])
      ]

      generators = [
        generator(1, 1, p_max_mw: 50.0),
        generator(2, 2, p_max_mw: 200.0),  # largest in island 0
        generator(3, 3, p_max_mw: 300.0),  # largest in island 1
        generator(4, 4, p_max_mw: 100.0)
      ]

      slack_map = IslandDetector.assign_slack_buses(islands, generators)

      assert slack_map[0] == 2
      assert slack_map[1] == 3
    end
  end
end
