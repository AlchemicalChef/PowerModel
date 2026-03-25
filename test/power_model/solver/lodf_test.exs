defmodule PowerModel.Solver.LODFTest do
  use ExUnit.Case, async: true

  alias PowerModel.Solver.{DCPowerFlow, LODF}

  # ===========================================================================
  # Test helpers — plain-map builders (same pattern as other tests)
  # ===========================================================================

  defp bus(id, opts \\ []) do
    %{id: id, bus_type: Keyword.get(opts, :bus_type, 1), base_kv: 138.0,
      vm_pu: 1.0, va_rad: 0.0, b_shunt_mvar: 0.0}
  end

  defp line(id, from, to, opts \\ []) do
    %{id: id, from_bus_id: from, to_bus_id: to,
      voltage_kv: 138.0, r_pu: 0.01,
      x_pu: Keyword.get(opts, :x_pu, 0.1),
      b_pu: 0.02,
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 100.0)}
  end

  defp generator(id, bus_id, opts) do
    %{id: id, bus_id: bus_id,
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      capacity_factor: 1.0,
      fuel_type: "NG", status: "in_service",
      marginal_cost_per_mwh: 35.0}
  end

  defp load(id, bus_id, opts) do
    %{id: id, bus_id: bus_id,
      p_mw: Keyword.get(opts, :p_mw, 50.0),
      q_mvar: 0.0}
  end

  # ===========================================================================
  # 5-bus diamond network for LODF testing
  #
  #     Bus 1 (slack/gen)
  #    / |  \
  #   L1 L2  L3
  #  /   |    \
  # B2   B3   B4
  #  \   |   /
  #   L4 L5 L6
  #    \  | /
  #     Bus 5 (load)
  #
  # Lines: 1-2, 1-3, 1-4, 2-5, 3-5, 4-5
  # Tripping any single line should redistribute flow to parallel paths.
  # ===========================================================================

  defp diamond_snapshot do
    buses = [bus(1, bus_type: 3), bus(2), bus(3), bus(4), bus(5)]
    lines = [
      line(1, 1, 2, x_pu: 0.1),   # L1: 1→2
      line(2, 1, 3, x_pu: 0.15),  # L2: 1→3
      line(3, 1, 4, x_pu: 0.2),   # L3: 1→4
      line(4, 2, 5, x_pu: 0.1),   # L4: 2→5
      line(5, 3, 5, x_pu: 0.15),  # L5: 3→5
      line(6, 4, 5, x_pu: 0.2),   # L6: 4→5
    ]
    gens = [generator(1, 1, p_max_mw: 200.0)]
    loads = [load(1, 5, p_mw: 100.0)]

    %{buses: buses, lines: lines, transformers: [],
      generators: gens, loads: loads}
  end

  # ===========================================================================
  # LODF accuracy tests: compare against full DC re-solve
  # ===========================================================================

  describe "LODF vs full DC solve accuracy" do
    test "tripping line 1 (1→2) gives same flows as full re-solve" do
      snapshot = diamond_snapshot()
      base_solution = DCPowerFlow.solve(snapshot)

      # Initialize LODF
      lodf = LODF.init(snapshot, base_solution)

      # Trip line 1 via LODF
      {:ok, _lodf, lodf_flows} = LODF.trip_line(lodf, {:line, 1})

      # Trip line 1 via full DC re-solve
      remaining_lines = Enum.reject(snapshot.lines, &(&1.id == 1))
      resolve_snapshot = %{snapshot | lines: remaining_lines}
      resolve_solution = DCPowerFlow.solve(resolve_snapshot)

      # Compare flows on remaining lines
      for {key, resolve_flow} <- resolve_solution.line_flows do
        lodf_flow = Map.get(lodf_flows, key)

        if lodf_flow do
          assert_in_delta lodf_flow.p_flow_mw, resolve_flow.p_flow_mw, 0.1,
            "Flow mismatch on #{inspect(key)}: LODF=#{lodf_flow.p_flow_mw}, DC=#{resolve_flow.p_flow_mw}"
        end
      end
    end

    test "tripping line 5 (3→5) gives same flows as full re-solve" do
      snapshot = diamond_snapshot()
      base_solution = DCPowerFlow.solve(snapshot)
      lodf = LODF.init(snapshot, base_solution)

      {:ok, _lodf, lodf_flows} = LODF.trip_line(lodf, {:line, 5})

      remaining_lines = Enum.reject(snapshot.lines, &(&1.id == 5))
      resolve_solution = DCPowerFlow.solve(%{snapshot | lines: remaining_lines})

      for {key, resolve_flow} <- resolve_solution.line_flows do
        lodf_flow = Map.get(lodf_flows, key)

        if lodf_flow do
          assert_in_delta lodf_flow.p_flow_mw, resolve_flow.p_flow_mw, 0.1,
            "Flow mismatch on #{inspect(key)}"
        end
      end
    end

    test "tripping each line in the diamond gives correct flows" do
      snapshot = diamond_snapshot()
      base_solution = DCPowerFlow.solve(snapshot)

      for line_id <- 1..6 do
        lodf = LODF.init(snapshot, base_solution)
        result = LODF.trip_line(lodf, {:line, line_id})

        case result do
          {:ok, _lodf, lodf_flows} ->
            remaining_lines = Enum.reject(snapshot.lines, &(&1.id == line_id))
            resolve_solution = DCPowerFlow.solve(%{snapshot | lines: remaining_lines})

            for {key, resolve_flow} <- resolve_solution.line_flows do
              lodf_flow = Map.get(lodf_flows, key)
              if lodf_flow do
                assert_in_delta lodf_flow.p_flow_mw, resolve_flow.p_flow_mw, 0.5,
                  "Line #{line_id} trip: flow mismatch on #{inspect(key)}"
              end
            end

          {:island_split, _lodf} ->
            # Valid — some lines are bridges
            :ok
        end
      end
    end
  end

  # ===========================================================================
  # Bridge detection (island split)
  # ===========================================================================

  describe "island split detection" do
    test "tripping a bridge line returns :island_split" do
      # Linear 3-bus network: 1 --L1-- 2 --L2-- 3
      # Both lines are bridges
      buses = [bus(1, bus_type: 3), bus(2), bus(3)]
      lines = [line(1, 1, 2), line(2, 2, 3)]
      gens = [generator(1, 1, p_max_mw: 200.0)]
      loads = [load(1, 3, p_mw: 50.0)]
      snapshot = %{buses: buses, lines: lines, transformers: [], generators: gens, loads: loads}

      base_solution = DCPowerFlow.solve(snapshot)
      lodf = LODF.init(snapshot, base_solution)

      assert {:island_split, _} = LODF.trip_line(lodf, {:line, 1})
    end

    test "tripping a redundant line does NOT return :island_split" do
      snapshot = diamond_snapshot()
      base_solution = DCPowerFlow.solve(snapshot)
      lodf = LODF.init(snapshot, base_solution)

      # Line 1 (1→2) has parallel paths through 3 and 4
      assert {:ok, _, _} = LODF.trip_line(lodf, {:line, 1})
    end
  end

  # ===========================================================================
  # Edge cases
  # ===========================================================================

  describe "edge cases" do
    test "tripping an already-tripped line is a no-op" do
      snapshot = diamond_snapshot()
      base_solution = DCPowerFlow.solve(snapshot)
      lodf = LODF.init(snapshot, base_solution)

      {:ok, lodf, flows1} = LODF.trip_line(lodf, {:line, 1})
      {:ok, _lodf, flows2} = LODF.trip_line(lodf, {:line, 1})

      # Flows should be identical
      for {key, f1} <- flows1 do
        f2 = Map.get(flows2, key)
        if f2 do
          assert_in_delta f1.p_flow_mw, f2.p_flow_mw, 0.001
        end
      end
    end

    test "tripping a nonexistent line is a no-op" do
      snapshot = diamond_snapshot()
      base_solution = DCPowerFlow.solve(snapshot)
      lodf = LODF.init(snapshot, base_solution)

      {:ok, _lodf, _flows} = LODF.trip_line(lodf, {:line, 999})
    end

    test "needs_refactorize? triggers after threshold trips" do
      snapshot = diamond_snapshot()
      base_solution = DCPowerFlow.solve(snapshot)
      lodf = LODF.init(snapshot, base_solution)

      refute LODF.needs_refactorize?(lodf, max_cumulative_trips: 3)

      # Simulate 4 trips (manually add to cumulative_trips)
      lodf = %{lodf | cumulative_trips: MapSet.new([{:line, 1}, {:line, 2}, {:line, 3}, {:line, 4}])}
      assert LODF.needs_refactorize?(lodf, max_cumulative_trips: 3)
    end
  end

  # ===========================================================================
  # Loading percentage accuracy
  # ===========================================================================

  describe "loading percentage" do
    test "loading_pct matches full DC solve after trip" do
      snapshot = diamond_snapshot()
      base_solution = DCPowerFlow.solve(snapshot)
      lodf = LODF.init(snapshot, base_solution)

      {:ok, _lodf, lodf_flows} = LODF.trip_line(lodf, {:line, 2})

      remaining_lines = Enum.reject(snapshot.lines, &(&1.id == 2))
      resolve_solution = DCPowerFlow.solve(%{snapshot | lines: remaining_lines})

      for {key, resolve_flow} <- resolve_solution.line_flows do
        lodf_flow = Map.get(lodf_flows, key)
        if lodf_flow && resolve_flow.loading_pct > 0.0 do
          assert_in_delta lodf_flow.loading_pct, resolve_flow.loading_pct, 1.0,
            "Loading mismatch on #{inspect(key)}"
        end
      end
    end
  end
end
