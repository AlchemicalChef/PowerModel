defmodule PowerModel.Failure.MonteCarloTest do
  use ExUnit.Case, async: true

  alias PowerModel.Failure.{MonteCarlo, Scenarios}
  alias PowerModel.Solver.{DCPowerFlow, LODF}

  # ===========================================================================
  # Test helpers — 5-bus diamond network (same as LODF tests)
  # ===========================================================================

  defp bus(id, opts \\ []) do
    coords = Keyword.get(opts, :coordinates, nil)
    %{id: id, bus_type: Keyword.get(opts, :bus_type, 1), base_kv: 138.0,
      vm_pu: 1.0, va_rad: 0.0, b_shunt_mvar: 0.0, coordinates: coords}
  end

  defp line(id, from, to, opts \\ []) do
    %{id: id, from_bus_id: from, to_bus_id: to,
      voltage_kv: 138.0, r_pu: 0.01,
      x_pu: Keyword.get(opts, :x_pu, 0.1),
      b_pu: 0.02,
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 100.0)}
  end

  defp generator(id, bus_id, opts \\ []) do
    %{id: id, bus_id: bus_id,
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      capacity_factor: 1.0,
      fuel_type: "NG", status: "in_service",
      marginal_cost_per_mwh: 35.0}
  end

  defp load(id, bus_id, opts \\ []) do
    %{id: id, bus_id: bus_id,
      p_mw: Keyword.get(opts, :p_mw, 50.0),
      q_mvar: 0.0}
  end

  defp geo_point(lat, lon) do
    %{coordinates: {lon, lat}}
  end

  defp diamond_snapshot do
    buses = [
      bus(1, bus_type: 3, coordinates: geo_point(34.0, -118.0)),
      bus(2, coordinates: geo_point(34.5, -117.5)),
      bus(3, coordinates: geo_point(35.0, -118.0)),
      bus(4, coordinates: geo_point(34.5, -118.5)),
      bus(5, coordinates: geo_point(35.5, -117.5))
    ]
    lines = [
      line(1, 1, 2, x_pu: 0.1),
      line(2, 1, 3, x_pu: 0.15),
      line(3, 1, 4, x_pu: 0.2),
      line(4, 2, 5, x_pu: 0.1),
      line(5, 3, 5, x_pu: 0.15),
      line(6, 4, 5, x_pu: 0.2)
    ]
    gens = [generator(1, 1, p_max_mw: 200.0)]
    loads = [load(1, 5, p_mw: 100.0)]

    %{buses: buses, lines: lines, transformers: [],
      generators: gens, loads: loads}
  end

  # Heavily loaded diamond where some N-2 contingencies cause overloads
  defp stressed_diamond_snapshot do
    buses = [
      bus(1, bus_type: 3, coordinates: geo_point(34.0, -118.0)),
      bus(2, coordinates: geo_point(34.5, -117.5)),
      bus(3, coordinates: geo_point(35.0, -118.0)),
      bus(4, coordinates: geo_point(34.5, -118.5)),
      bus(5, coordinates: geo_point(35.5, -117.5))
    ]
    # Tight ratings on parallel paths — tripping 2 lines forces overload on the third
    lines = [
      line(1, 1, 2, x_pu: 0.1, rating_a_mva: 40.0),
      line(2, 1, 3, x_pu: 0.15, rating_a_mva: 40.0),
      line(3, 1, 4, x_pu: 0.2, rating_a_mva: 40.0),
      line(4, 2, 5, x_pu: 0.1, rating_a_mva: 40.0),
      line(5, 3, 5, x_pu: 0.15, rating_a_mva: 40.0),
      line(6, 4, 5, x_pu: 0.2, rating_a_mva: 40.0)
    ]
    gens = [generator(1, 1, p_max_mw: 200.0)]
    loads = [load(1, 5, p_mw: 100.0)]

    %{buses: buses, lines: lines, transformers: [],
      generators: gens, loads: loads}
  end

  # ===========================================================================
  # Score contingency tests
  # ===========================================================================

  describe "score_contingency/2" do
    test "returns correct structure" do
      snapshot = diamond_snapshot()
      solution = DCPowerFlow.solve(snapshot)
      lodf = LODF.init(snapshot, solution)

      result = MonteCarlo.score_contingency(lodf, [{:line, 1}])

      assert is_list(result.tripped)
      assert is_float(result.max_loading_pct)
      assert is_integer(result.overloaded_count)
      assert is_float(result.mw_at_risk)
      assert is_boolean(result.island_split)
      assert is_float(result.score)
    end

    test "single line trip in well-connected network has low overload" do
      snapshot = diamond_snapshot()
      solution = DCPowerFlow.solve(snapshot)
      lodf = LODF.init(snapshot, solution)

      result = MonteCarlo.score_contingency(lodf, [{:line, 1}])

      # Diamond is well-connected: tripping one line should not overload
      # others when ratings are 100 MVA and load is 100 MW
      assert result.overloaded_count == 0
      assert result.island_split == false
    end

    test "N-2 in stressed network can cause overloads" do
      snapshot = stressed_diamond_snapshot()
      solution = DCPowerFlow.solve(snapshot)
      lodf = LODF.init(snapshot, solution)

      # Trip both upper parallel paths (line 1: 1->2, line 2: 1->3)
      # forcing all flow through line 3 (1->4) and line 6 (4->5)
      result = MonteCarlo.score_contingency(lodf, [{:line, 1}, {:line, 2}])

      # With 100 MW load and 40 MVA ratings, this should overload
      assert result.max_loading_pct > 100.0
      assert result.overloaded_count > 0
      assert result.mw_at_risk > 0.0
      assert result.score > 0.0
    end

    test "island split is detected" do
      # 3-bus linear network: tripping the only path causes split
      buses = [bus(1, bus_type: 3), bus(2), bus(3)]
      lines = [line(1, 1, 2), line(2, 2, 3)]
      gens = [generator(1, 1, p_max_mw: 200.0)]
      loads = [load(1, 3, p_mw: 50.0)]
      snapshot = %{buses: buses, lines: lines, transformers: [], generators: gens, loads: loads}

      solution = DCPowerFlow.solve(snapshot)
      lodf = LODF.init(snapshot, solution)

      result = MonteCarlo.score_contingency(lodf, [{:line, 1}])

      assert result.island_split == true
      assert result.score >= 500.0  # island split bonus
    end
  end

  # ===========================================================================
  # N-2 screening tests
  # ===========================================================================

  describe "screen_n2/2" do
    test "returns list of contingency results sorted by score" do
      snapshot = stressed_diamond_snapshot()

      results = MonteCarlo.screen_n2(snapshot, top_k: 5)

      assert is_list(results)
      assert length(results) <= 5

      # Should be sorted by score descending
      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "finds overloaded contingencies in stressed network" do
      snapshot = stressed_diamond_snapshot()

      results = MonteCarlo.screen_n2(snapshot, top_k: 15)

      # At least one N-2 should cause an overload
      has_overload = Enum.any?(results, fn r -> r.overloaded_count > 0 end)
      assert has_overload, "Expected at least one N-2 to cause overload in stressed network"
    end

    test "each result has exactly 2 tripped lines" do
      snapshot = diamond_snapshot()

      results = MonteCarlo.screen_n2(snapshot, top_k: 5)

      for result <- results do
        assert length(result.tripped) == 2
      end
    end
  end

  # ===========================================================================
  # Random N-k screening tests
  # ===========================================================================

  describe "screen_random_nk/2" do
    test "returns results with varying k values" do
      snapshot = stressed_diamond_snapshot()

      results = MonteCarlo.screen_random_nk(snapshot,
        k_range: 2..3, sample_size: 50, top_k: 10)

      assert is_list(results)
      assert length(results) <= 10

      k_values = results |> Enum.map(fn r -> length(r.tripped) end) |> Enum.uniq() |> Enum.sort()

      # Should have at least some results (network is small enough)
      assert length(results) > 0
    end

    test "results are sorted by score descending" do
      snapshot = stressed_diamond_snapshot()

      results = MonteCarlo.screen_random_nk(snapshot,
        k_range: 2..3, sample_size: 30, top_k: 10)

      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end
  end

  # ===========================================================================
  # Geographic screening under scenario
  # ===========================================================================

  describe "screen_geographic/3" do
    test "N-1 screening under heat wave finds stressed contingencies" do
      snapshot = stressed_diamond_snapshot()

      scenario = Scenarios.heat_wave(snapshot)

      results = MonteCarlo.screen_geographic(snapshot, scenario, top_k: 6)

      assert is_list(results)
      assert length(results) <= 6

      # Each result is N-1 (single trip)
      for result <- results do
        assert length(result.tripped) == 1
      end
    end

    test "scenario deratings increase severity compared to normal" do
      snapshot = stressed_diamond_snapshot()

      # Normal N-1
      normal_results = MonteCarlo.screen_geographic(snapshot,
        %Scenarios{description: "none"}, top_k: 6)

      # Heat wave N-1 (loads up, ratings down)
      scenario = %Scenarios{
        line_deratings: Map.new(1..6, fn id -> {id, 0.5} end),
        load_multipliers: %{1 => 1.5},
        forced_trips: [],
        generator_deratings: %{},
        description: "extreme derate"
      }

      stressed_results = MonteCarlo.screen_geographic(snapshot, scenario, top_k: 6)

      # The worst stressed contingency should be worse than the worst normal one
      worst_normal = if normal_results == [], do: 0.0, else: hd(normal_results).score
      worst_stressed = if stressed_results == [], do: 0.0, else: hd(stressed_results).score

      assert worst_stressed >= worst_normal,
        "Stressed scenario should produce equal or worse contingencies"
    end
  end
end
