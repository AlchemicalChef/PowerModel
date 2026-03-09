defmodule PowerModel.Solver.DCPowerFlowTest do
  use ExUnit.Case, async: true

  alias PowerModel.Solver.DCPowerFlow

  # ---------------------------------------------------------------------------
  # Helpers — plain-map builders matching what Grid.get_grid_snapshot returns
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
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 200.0)
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

  defp generator(id, bus_id, opts \\ []) do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      capacity_factor: Keyword.get(opts, :capacity_factor, 1.0),
      q_max_mvar: Keyword.get(opts, :q_max_mvar, 50.0),
      q_min_mvar: Keyword.get(opts, :q_min_mvar, -50.0)
    }
  end

  defp load(id, bus_id, opts \\ []) do
    %{
      id: id,
      bus_id: bus_id,
      p_mw: Keyword.get(opts, :p_mw, 50.0),
      q_mvar: Keyword.get(opts, :q_mvar, 20.0)
    }
  end

  defp snapshot(buses, lines, transformers, generators, loads) do
    %{
      buses: buses,
      lines: lines,
      transformers: transformers,
      generators: generators,
      loads: loads
    }
  end

  # ---------------------------------------------------------------------------
  # Basic solve tests
  # ---------------------------------------------------------------------------

  describe "solve/2 basic" do
    test "2-bus system: single gen, single load" do
      # Bus 1 (gen 100MW) --line--> Bus 2 (load 80MW)
      snap = snapshot(
        [bus(1, bus_type: 3), bus(2)],
        [line(1, 1, 2, x_pu: 0.1)],
        [],
        [generator(1, 1, p_max_mw: 100.0)],
        [load(1, 2, p_mw: 80.0)]
      )

      solution = DCPowerFlow.solve(snap)

      assert solution.converged == true
      # DC: all voltages are 1.0 pu
      assert Enum.all?(solution.vm_pu, &(&1 == 1.0))
      # Slack bus angle is 0
      assert Enum.at(solution.va_rad, 0) == 0.0
      # Non-slack bus should have a non-zero angle
      refute Enum.at(solution.va_rad, 1) == 0.0
      # Line flow should be ~20 MW (gen 100 - load 80 = 20 MW net at slack, flow = 80 MW to load bus)
      {_key, flow} = Enum.find(solution.line_flows, fn {{type, _id}, _f} -> type == :line end)
      assert abs(flow.p_flow_mw) > 0.0
    end

    test "balanced system: gen equals load, no flow" do
      # Gen 50MW on bus 1, Load 50MW on bus 1 => net injection = 0 at every bus
      snap = snapshot(
        [bus(1, bus_type: 3), bus(2)],
        [line(1, 1, 2, x_pu: 0.1)],
        [],
        [generator(1, 1, p_max_mw: 50.0)],
        [load(1, 1, p_mw: 50.0)]
      )

      solution = DCPowerFlow.solve(snap)

      assert solution.converged == true
      # Net injection at both buses is ~0 => angle difference ~0 => flow ~0
      {{:line, 1}, flow} = Enum.find(solution.line_flows, fn {{_, id}, _} -> id == 1 end)
      assert abs(flow.p_flow_mw) < 0.01
    end

    test "3-bus system with transformer" do
      snap = snapshot(
        [bus(1, bus_type: 3), bus(2), bus(3)],
        [line(1, 1, 2, x_pu: 0.1)],
        [transformer(1, 2, 3, x_pu: 0.05)],
        [generator(1, 1, p_max_mw: 200.0)],
        [load(1, 3, p_mw: 100.0)]
      )

      solution = DCPowerFlow.solve(snap)

      assert solution.converged == true
      assert map_size(solution.line_flows) == 2
      # Both the line and transformer should have flow
      assert solution.line_flows[{:line, 1}].p_flow_mw != 0.0
      assert solution.line_flows[{:transformer, 1}].p_flow_mw != 0.0
    end

    test "single bus system returns trivial solution" do
      snap = snapshot(
        [bus(1, bus_type: 3)],
        [],
        [],
        [generator(1, 1, p_max_mw: 100.0)],
        [load(1, 1, p_mw: 50.0)]
      )

      solution = DCPowerFlow.solve(snap)

      assert solution.converged == true
      assert length(solution.vm_pu) == 1
      assert length(solution.va_rad) == 1
      assert solution.line_flows == %{}
    end

    test "empty grid throws error" do
      snap = snapshot([], [], [], [], [])

      assert catch_throw(DCPowerFlow.solve(snap)) == {:error, :empty_grid}
    end
  end

  # ---------------------------------------------------------------------------
  # Line flow and loading tests
  # ---------------------------------------------------------------------------

  describe "line flows" do
    test "flow direction follows power injection" do
      # Gen on bus 1, load on bus 2 => flow goes 1->2 (positive)
      snap = snapshot(
        [bus(1, bus_type: 3), bus(2)],
        [line(1, 1, 2, x_pu: 0.1)],
        [],
        [generator(1, 1, p_max_mw: 100.0)],
        [load(1, 2, p_mw: 80.0)]
      )

      solution = DCPowerFlow.solve(snap)
      {{:line, 1}, flow} = Enum.find(solution.line_flows, fn {{_, id}, _} -> id == 1 end)

      # Flow from gen bus to load bus should be positive
      assert flow.p_flow_mw > 0.0
    end

    test "loading_pct computed correctly" do
      # Line rated at 100 MVA, flow should be ~80 MW => loading ~80%
      snap = snapshot(
        [bus(1, bus_type: 3), bus(2)],
        [line(1, 1, 2, x_pu: 0.1, rating_a_mva: 100.0)],
        [],
        [generator(1, 1, p_max_mw: 100.0)],
        [load(1, 2, p_mw: 80.0)]
      )

      solution = DCPowerFlow.solve(snap)
      {{:line, 1}, flow} = Enum.find(solution.line_flows, fn {{_, id}, _} -> id == 1 end)

      # Loading should be around 80% (80 MW / 100 MVA * 100)
      assert flow.loading_pct > 70.0
      assert flow.loading_pct < 90.0
    end

    test "overloaded flag set when flow exceeds rating" do
      # Line rated 50 MVA, flow ~80 MW => overloaded
      snap = snapshot(
        [bus(1, bus_type: 3), bus(2)],
        [line(1, 1, 2, x_pu: 0.1, rating_a_mva: 50.0)],
        [],
        [generator(1, 1, p_max_mw: 100.0)],
        [load(1, 2, p_mw: 80.0)]
      )

      solution = DCPowerFlow.solve(snap)
      {{:line, 1}, flow} = Enum.find(solution.line_flows, fn {{_, id}, _} -> id == 1 end)

      assert flow.overloaded == true
      assert flow.loading_pct > 100.0
    end

    test "parallel lines split flow" do
      # Two identical parallel lines: each should carry ~half the flow
      snap = snapshot(
        [bus(1, bus_type: 3), bus(2)],
        [
          line(1, 1, 2, x_pu: 0.1, rating_a_mva: 200.0),
          line(2, 1, 2, x_pu: 0.1, rating_a_mva: 200.0)
        ],
        [],
        [generator(1, 1, p_max_mw: 100.0)],
        [load(1, 2, p_mw: 80.0)]
      )

      solution = DCPowerFlow.solve(snap)

      flow1 = solution.line_flows[{:line, 1}].p_flow_mw
      flow2 = solution.line_flows[{:line, 2}].p_flow_mw

      # Each line should carry approximately half
      assert abs(flow1 - flow2) < 1.0
      assert abs(flow1 - 40.0) < 5.0
    end

    test "flow splits inversely with reactance" do
      # Two parallel lines with different reactances: lower X gets more flow
      snap = snapshot(
        [bus(1, bus_type: 3), bus(2)],
        [
          line(1, 1, 2, x_pu: 0.05, rating_a_mva: 200.0),
          line(2, 1, 2, x_pu: 0.15, rating_a_mva: 200.0)
        ],
        [],
        [generator(1, 1, p_max_mw: 100.0)],
        [load(1, 2, p_mw: 80.0)]
      )

      solution = DCPowerFlow.solve(snap)

      flow1 = abs(solution.line_flows[{:line, 1}].p_flow_mw)
      flow2 = abs(solution.line_flows[{:line, 2}].p_flow_mw)

      # Line 1 (x=0.05) should carry 3x the flow of line 2 (x=0.15)
      assert flow1 > flow2
      ratio = flow1 / flow2
      assert_in_delta ratio, 3.0, 0.1
    end
  end

  # ---------------------------------------------------------------------------
  # Slack bus selection
  # ---------------------------------------------------------------------------

  describe "slack bus" do
    test "explicit slack bus (type 3) is used" do
      snap = snapshot(
        [bus(1), bus(2, bus_type: 3), bus(3)],
        [line(1, 1, 2, x_pu: 0.1), line(2, 2, 3, x_pu: 0.1)],
        [],
        [generator(1, 1, p_max_mw: 50.0), generator(2, 2, p_max_mw: 100.0)],
        [load(1, 3, p_mw: 80.0)]
      )

      solution = DCPowerFlow.solve(snap)

      # Bus 2 is the slack => its angle should be 0
      # Bus order is [1, 2, 3], so index 1 = bus 2
      assert Enum.at(solution.va_rad, 1) == 0.0
    end

    test "without explicit slack, largest generator bus becomes slack" do
      snap = snapshot(
        [bus(1), bus(2), bus(3)],
        [line(1, 1, 2, x_pu: 0.1), line(2, 2, 3, x_pu: 0.1)],
        [],
        [generator(1, 1, p_max_mw: 50.0), generator(2, 3, p_max_mw: 200.0)],
        [load(1, 2, p_mw: 80.0)]
      )

      solution = DCPowerFlow.solve(snap)

      # Bus 3 has the largest gen (200 MW) => slack => angle = 0
      assert Enum.at(solution.va_rad, 2) == 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # Solution struct properties
  # ---------------------------------------------------------------------------

  describe "solution properties" do
    test "solution has correct bus count" do
      snap = snapshot(
        [bus(1, bus_type: 3), bus(2), bus(3)],
        [line(1, 1, 2, x_pu: 0.1), line(2, 2, 3, x_pu: 0.1)],
        [],
        [generator(1, 1, p_max_mw: 200.0)],
        [load(1, 2, p_mw: 50.0), load(2, 3, p_mw: 30.0)]
      )

      solution = DCPowerFlow.solve(snap)

      assert length(solution.bus_ids) == 3
      assert length(solution.vm_pu) == 3
      assert length(solution.va_rad) == 3
    end

    test "solution struct has expected fields" do
      snap = snapshot(
        [bus(1, bus_type: 3), bus(2)],
        [line(1, 1, 2, x_pu: 0.1)],
        [],
        [generator(1, 1, p_max_mw: 150.0, capacity_factor: 0.8)],
        [load(1, 2, p_mw: 100.0)]
      )

      solution = DCPowerFlow.solve(snap)

      assert solution.converged == true
      assert solution.iterations == 1
      assert is_number(solution.max_mismatch)
      assert is_number(solution.base_mva)
    end

    test "custom base_mva" do
      snap = snapshot(
        [bus(1, bus_type: 3), bus(2)],
        [line(1, 1, 2, x_pu: 0.1)],
        [],
        [generator(1, 1, p_max_mw: 100.0)],
        [load(1, 2, p_mw: 80.0)]
      )

      solution = DCPowerFlow.solve(snap, base_mva: 200.0)

      assert solution.converged == true
      # Flows should be the same in MW regardless of base_mva
      {{:line, 1}, flow} = Enum.find(solution.line_flows, fn {{_, id}, _} -> id == 1 end)
      assert abs(flow.p_flow_mw) > 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # Larger networks
  # ---------------------------------------------------------------------------

  describe "larger networks" do
    test "5-bus ring network" do
      # Ring: 1-2-3-4-5-1
      buses = for i <- 1..5, do: bus(i, bus_type: if(i == 1, do: 3, else: 1))
      lines = [
        line(1, 1, 2, x_pu: 0.1),
        line(2, 2, 3, x_pu: 0.1),
        line(3, 3, 4, x_pu: 0.1),
        line(4, 4, 5, x_pu: 0.1),
        line(5, 5, 1, x_pu: 0.1)
      ]
      gens = [generator(1, 1, p_max_mw: 200.0)]
      loads = [
        load(1, 2, p_mw: 30.0),
        load(2, 3, p_mw: 40.0),
        load(3, 4, p_mw: 20.0),
        load(4, 5, p_mw: 10.0)
      ]

      snap = snapshot(buses, lines, [], gens, loads)
      solution = DCPowerFlow.solve(snap)

      assert solution.converged == true
      assert map_size(solution.line_flows) == 5
      # All flows should be non-zero in a ring with asymmetric loads
      Enum.each(solution.line_flows, fn {_key, flow} ->
        assert is_number(flow.p_flow_mw)
      end)
    end

    test "10-bus linear chain" do
      buses = for i <- 1..10, do: bus(i, bus_type: if(i == 1, do: 3, else: 1))
      lines = for i <- 1..9, do: line(i, i, i + 1, x_pu: 0.05, rating_a_mva: 500.0)
      gens = [generator(1, 1, p_max_mw: 500.0)]
      loads = for i <- 2..10, do: load(i, i, p_mw: 20.0)

      snap = snapshot(buses, lines, [], gens, loads)
      solution = DCPowerFlow.solve(snap)

      assert solution.converged == true
      assert length(solution.bus_ids) == 10
      assert map_size(solution.line_flows) == 9

      # Flow should decrease along the chain (most flow near slack)
      flow1 = abs(solution.line_flows[{:line, 1}].p_flow_mw)
      flow9 = abs(solution.line_flows[{:line, 9}].p_flow_mw)
      assert flow1 > flow9
    end
  end
end
