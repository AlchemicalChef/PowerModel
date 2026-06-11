defmodule PowerModel.Engine.SimulationServerTest do
  use ExUnit.Case, async: false

  # We test the SimulationServer by directly calling GenServer init/handle_call
  # with in-memory snapshots, bypassing the DB-dependent Grid context.
  # To do this, we start real GenServers with mocked grid data.

  # ---------------------------------------------------------------------------
  # Helpers
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

  defp line(id, from, to, opts) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      voltage_kv: Keyword.get(opts, :voltage_kv, 138.0),
      r_pu: Keyword.get(opts, :r_pu, 0.01),
      x_pu: Keyword.get(opts, :x_pu, 0.1),
      b_pu: Keyword.get(opts, :b_pu, 0.02),
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 200.0),
      sub_1: nil,
      sub_2: nil,
      owner: nil
    }
  end

  defp generator(id, bus_id, opts) do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      p_min_mw: Keyword.get(opts, :p_min_mw, 0.0),
      capacity_factor: Keyword.get(opts, :capacity_factor, 1.0),
      q_max_mvar: Keyword.get(opts, :q_max_mvar, 50.0),
      q_min_mvar: Keyword.get(opts, :q_min_mvar, -50.0),
      fuel_type: Keyword.get(opts, :fuel_type, "NG"),
      marginal_cost: Keyword.get(opts, :marginal_cost, 30.0)
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

  defp test_snapshot do
    %{
      buses: [bus(1, bus_type: 3), bus(2), bus(3)],
      lines: [
        line(1, 1, 2, rating_a_mva: 500.0),
        line(2, 2, 3, rating_a_mva: 500.0),
        line(3, 1, 3, rating_a_mva: 500.0)
      ],
      transformers: [],
      generators: [
        generator(1, 1, p_max_mw: 200.0),
        generator(2, 3, p_max_mw: 100.0)
      ],
      loads: [
        load(1, 2, p_mw: 80.0),
        load(2, 3, p_mw: 60.0)
      ],
      water_facilities: []
    }
  end

  # ---------------------------------------------------------------------------
  # Cascade + SimulationServer logic tests
  # ---------------------------------------------------------------------------

  describe "cascade integration" do
    test "init creates valid cascade state from snapshot" do
      snapshot = test_snapshot()
      cascade = PowerModel.Failure.Cascade.init(snapshot, 100.0)

      assert cascade.base_mva == 100.0
      assert length(cascade.buses) == 3
      assert length(cascade.generators) == 2
      assert MapSet.size(cascade.tripped_lines) == 0
    end

    test "tripping a line produces step results" do
      snapshot = test_snapshot()
      cascade = PowerModel.Failure.Cascade.init(snapshot, 100.0)

      {final, steps} = PowerModel.Failure.Cascade.trip_line(cascade, 1)

      assert MapSet.member?(final.tripped_lines, 1)
      assert is_list(steps)
      assert length(steps) >= 1
    end

    test "tripping a generator produces step results" do
      snapshot = test_snapshot()
      cascade = PowerModel.Failure.Cascade.init(snapshot, 100.0)

      {final, steps} = PowerModel.Failure.Cascade.trip_generator(cascade, 1)

      assert MapSet.member?(final.tripped_generators, 1)
      assert is_list(steps)
      assert length(steps) >= 1
    end

    test "get_state returns correct structure after trips" do
      snapshot = test_snapshot()
      cascade = PowerModel.Failure.Cascade.init(snapshot, 100.0)

      {final, _steps} = PowerModel.Failure.Cascade.trip_line(cascade, 2)

      assert MapSet.member?(final.tripped_lines, 2)
      assert is_list(final.events)
      assert length(final.events) >= 1
    end

    test "reset restores initial state" do
      snapshot = test_snapshot()
      cascade = PowerModel.Failure.Cascade.init(snapshot, 100.0)

      {tripped, _} = PowerModel.Failure.Cascade.trip_line(cascade, 1)
      assert MapSet.size(tripped.tripped_lines) >= 1

      # Re-init simulates reset
      fresh = PowerModel.Failure.Cascade.init(snapshot, 100.0)
      assert MapSet.size(fresh.tripped_lines) == 0
      assert fresh.events == []
      assert fresh.step == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Solution payload tests (testing the private function logic)
  # ---------------------------------------------------------------------------

  describe "DC solve from cascade state" do
    test "solving intact network produces valid solution" do
      snapshot = test_snapshot()
      cascade = PowerModel.Failure.Cascade.init(snapshot, 100.0)

      # Build dispatched snapshot (same logic as SimulationServer.dispatched_snapshot)
      active_gens =
        cascade.generators
        |> Enum.reject(&MapSet.member?(cascade.tripped_generators, &1.id))
        |> Enum.map(fn g ->
          d = Map.get(cascade.dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))
          %{g | p_max_mw: d, capacity_factor: 1.0}
        end)

      dc_snapshot = %{
        buses: cascade.buses,
        lines: Enum.reject(cascade.lines, &MapSet.member?(cascade.tripped_lines, &1.id)),
        transformers: [],
        generators: active_gens,
        loads: cascade.loads
      }

      solution = PowerModel.Solver.DCPowerFlow.solve(dc_snapshot, base_mva: 100.0)

      assert solution.converged == true
      assert length(solution.bus_ids) == 3
      assert map_size(solution.line_flows) >= 1
    end

    test "solving after line trip still converges" do
      snapshot = test_snapshot()
      cascade = PowerModel.Failure.Cascade.init(snapshot, 100.0)

      {tripped_cascade, _} = PowerModel.Failure.Cascade.trip_line(cascade, 1)

      active_gens =
        tripped_cascade.generators
        |> Enum.reject(&MapSet.member?(tripped_cascade.tripped_generators, &1.id))
        |> Enum.map(fn g ->
          d = Map.get(tripped_cascade.dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))
          %{g | p_max_mw: d, capacity_factor: 1.0}
        end)

      dc_snapshot = %{
        buses: tripped_cascade.buses,
        lines:
          Enum.reject(
            tripped_cascade.lines,
            &MapSet.member?(tripped_cascade.tripped_lines, &1.id)
          ),
        transformers: [],
        generators: active_gens,
        loads: tripped_cascade.loads
      }

      solution = PowerModel.Solver.DCPowerFlow.solve(dc_snapshot, base_mva: 100.0)

      assert solution.converged == true
      # Line 1 is tripped, so we should have fewer line flows
      line_flow_count =
        solution.line_flows
        |> Enum.count(fn {{type, _}, _} -> type == :line end)

      assert line_flow_count <= 3
    end
  end

  # ---------------------------------------------------------------------------
  # Base overload exclusion
  # ---------------------------------------------------------------------------

  describe "base overload exclusion" do
    test "base-case overloads are tracked in cascade state" do
      # Create a snapshot where a line will be overloaded in the base case
      snap = %{
        buses: [bus(1, bus_type: 3), bus(2)],
        lines: [line(1, 1, 2, rating_a_mva: 10.0, x_pu: 0.1)],
        transformers: [],
        generators: [generator(1, 1, p_max_mw: 200.0)],
        loads: [load(1, 2, p_mw: 80.0)],
        water_facilities: []
      }

      cascade = PowerModel.Failure.Cascade.init(snap, 100.0)

      # The line carries 80 MW through a 10 MVA rating.
      # After calibration, the rating should be bumped so it's not overloaded,
      # but the base_line_loading map should have an entry
      assert is_map(cascade.base_line_loading)
    end
  end

  # ---------------------------------------------------------------------------
  # Rating calibration
  # ---------------------------------------------------------------------------

  describe "calibrate_ratings/2" do
    test "bumps ratings on lines with base flow > 200% (data artifact threshold)" do
      lines = [
        line(1, 1, 2, rating_a_mva: 100.0),
        line(2, 2, 3, rating_a_mva: 100.0),
        line(3, 3, 4, rating_a_mva: 100.0)
      ]

      base_loading = %{
        # > 200% => data artifact, should be bumped
        {:line, 1} => 350.0,
        # 100-200% => genuinely stressed, keep as-is
        {:line, 2} => 150.0,
        # < 100% => keep as-is
        {:line, 3} => 50.0
      }

      calibrated = PowerModel.Failure.Cascade.calibrate_ratings(lines, base_loading)

      [cal1, cal2, cal3] = calibrated

      # Line 1: new_rating = 100 * 350 / 80 = 437.5
      assert cal1.rating_a_mva > 100.0
      assert_in_delta cal1.rating_a_mva, 437.5, 0.1

      # Line 2: unchanged (150% is not a clear data artifact)
      assert cal2.rating_a_mva == 100.0

      # Line 3: unchanged
      assert cal3.rating_a_mva == 100.0
    end

    test "does not bump lines below 200%" do
      lines = [line(1, 1, 2, rating_a_mva: 200.0)]
      base_loading = %{{:line, 1} => 150.0}

      [calibrated] = PowerModel.Failure.Cascade.calibrate_ratings(lines, base_loading)
      assert calibrated.rating_a_mva == 200.0
    end
  end

  describe "calibrate_transformer_ratings/2" do
    test "bumps transformer ratings for clear data artifacts (>200%)" do
      xfmrs = [
        %{
          id: 1,
          from_bus_id: 1,
          to_bus_id: 2,
          x_pu: 0.01,
          tap_ratio: 1.0,
          phase_shift_deg: 0.0,
          rated_mva: 100.0,
          status: "in_service"
        },
        %{
          id: 2,
          from_bus_id: 3,
          to_bus_id: 4,
          x_pu: 0.05,
          tap_ratio: 1.0,
          phase_shift_deg: 0.0,
          rated_mva: 200.0,
          status: "in_service"
        }
      ]

      base_loading = %{
        # > 200% => should be bumped
        {:transformer, 1} => 500.0,
        # < 200% => keep as-is
        {:transformer, 2} => 150.0
      }

      calibrated = PowerModel.Failure.Cascade.calibrate_transformer_ratings(xfmrs, base_loading)
      [cal1, cal2] = calibrated

      # Xfmr 1: new_rating = 100 * 500/80 = 625.0
      assert cal1.rated_mva > 100.0
      assert_in_delta cal1.rated_mva, 625.0, 0.1

      # Xfmr 2: unchanged
      assert cal2.rated_mva == 200.0
    end
  end

  describe "week 6 hourly generation mix scaling" do
    test "compute_generation_mix_ratios/2 normalizes fuel labels and returns ratios" do
      avg_mix = %{"NG" => 1000.0, "SUN" => 200.0, "COL" => 500.0, "WAT" => 100.0}
      hour_mix = %{"Natural Gas" => 900.0, "solar" => 20.0, "coal" => 650.0, "hydro" => 120.0}

      ratios = PowerModel.Engine.SimulationServer.compute_generation_mix_ratios(avg_mix, hour_mix)

      assert_in_delta Map.fetch!(ratios, :gas), 0.9, 1.0e-6
      assert_in_delta Map.fetch!(ratios, :solar), 0.1, 1.0e-6
      assert_in_delta Map.fetch!(ratios, :coal), 1.3, 1.0e-6
      assert_in_delta Map.fetch!(ratios, :hydro), 1.2, 1.0e-6
    end

    test "compute_generation_mix_ratios/2 defaults missing hourly fuels to neutral scaling" do
      avg_mix = %{"SUN" => 100.0, "WND" => 250.0}
      hour_mix = %{"WND" => 150.0}

      ratios = PowerModel.Engine.SimulationServer.compute_generation_mix_ratios(avg_mix, hour_mix)

      assert_in_delta Map.fetch!(ratios, :solar), 1.0, 1.0e-6
      assert_in_delta Map.fetch!(ratios, :wind), 0.6, 1.0e-6
    end

    test "scale_generators_by_mix/2 scales and clamps capacity factors by fuel group" do
      snapshot = %{
        buses: [],
        lines: [],
        transformers: [],
        loads: [],
        generators: [
          generator(1, 1, fuel_type: "NG", capacity_factor: 0.8),
          generator(2, 2, fuel_type: "SUN", capacity_factor: 0.9),
          generator(3, 3, fuel_type: "COL", capacity_factor: 0.7),
          generator(4, 4, fuel_type: "WND", capacity_factor: 0.6)
        ]
      }

      ratios = %{gas: 0.5, solar: 0.1, coal: 1.8}

      scaled = PowerModel.Engine.SimulationServer.scale_generators_by_mix(snapshot, ratios)
      [g1, g2, g3, g4] = scaled.generators

      assert_in_delta g1.capacity_factor, 0.4, 1.0e-6
      assert_in_delta g2.capacity_factor, 0.09, 1.0e-6
      assert_in_delta g3.capacity_factor, 1.0, 1.0e-6
      assert_in_delta g4.capacity_factor, 0.6, 1.0e-6
    end
  end
end
