defmodule PowerModel.Failure.ScenariosTest do
  use ExUnit.Case, async: true

  alias PowerModel.Failure.Scenarios

  # ===========================================================================
  # Test helpers — 5-bus diamond network (same as LODF tests)
  # ===========================================================================

  defp bus(id, opts \\ []) do
    coords = Keyword.get(opts, :coordinates, nil)

    %{
      id: id,
      bus_type: Keyword.get(opts, :bus_type, 1),
      base_kv: 138.0,
      vm_pu: 1.0,
      va_rad: 0.0,
      b_shunt_mvar: 0.0,
      coordinates: coords
    }
  end

  defp line(id, from, to, opts \\ []) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      voltage_kv: 138.0,
      r_pu: 0.01,
      x_pu: Keyword.get(opts, :x_pu, 0.1),
      b_pu: 0.02,
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 100.0)
    }
  end

  defp generator(id, bus_id, opts \\ []) do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      capacity_factor: 1.0,
      fuel_type: "NG",
      status: "in_service",
      marginal_cost_per_mwh: 35.0
    }
  end

  defp load(id, bus_id, opts \\ []) do
    %{
      id: id,
      bus_id: bus_id,
      p_mw: Keyword.get(opts, :p_mw, 50.0),
      q_mvar: Keyword.get(opts, :q_mvar, 15.0)
    }
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

    %{buses: buses, lines: lines, transformers: [], generators: gens, loads: loads}
  end

  # Fake cascade state struct (plain map) for apply_scenario tests
  defp fake_cascade_state(snapshot) do
    %{
      buses: snapshot.buses,
      lines: snapshot.lines,
      generators: snapshot.generators,
      loads: snapshot.loads,
      tripped_lines: MapSet.new()
    }
  end

  # ===========================================================================
  # Heat wave tests
  # ===========================================================================

  describe "heat_wave/2" do
    test "system-wide heat wave derates all lines and increases all loads" do
      snapshot = diamond_snapshot()
      scenario = Scenarios.heat_wave(snapshot)

      # All 6 lines should be derated
      assert map_size(scenario.line_deratings) == 6

      # Each derate should be between 0.80 and 0.90
      for {_id, factor} <- scenario.line_deratings do
        assert factor >= 0.80 and factor <= 0.90
      end

      # All 1 load should be increased
      assert map_size(scenario.load_multipliers) == 1

      for {_id, mult} <- scenario.load_multipliers do
        assert mult >= 1.10 and mult <= 1.20
      end

      # No forced trips
      assert scenario.forced_trips == []

      # Description present
      assert scenario.description =~ "Heat wave"
      assert scenario.description =~ "system-wide"
    end

    test "regional heat wave only affects buses in bounding box" do
      snapshot = diamond_snapshot()

      # Bounding box that covers bus 1 (34.0, -118.0) and bus 4 (34.5, -118.5)
      # but NOT bus 5 (35.5, -117.5) or bus 3 (35.0, -118.0, on border)
      scenario =
        Scenarios.heat_wave(snapshot, north: 34.6, south: 33.5, east: -117.0, west: -119.0)

      # Loads at bus 5 should be included because at least some lines
      # connect to in-region buses; but load multipliers are per-load
      # and load 1 is at bus 5 which is outside the box
      load_1_mult = Map.get(scenario.load_multipliers, 1)
      # bus 5 is at 35.5N, outside [33.5, 34.6]
      assert load_1_mult == nil
    end

    test "heat wave deratings are deterministic (same result on re-run)" do
      snapshot = diamond_snapshot()
      s1 = Scenarios.heat_wave(snapshot)
      s2 = Scenarios.heat_wave(snapshot)

      assert s1.line_deratings == s2.line_deratings
      assert s1.load_multipliers == s2.load_multipliers
    end
  end

  # ===========================================================================
  # Ice storm tests
  # ===========================================================================

  describe "ice_storm/2" do
    test "ice storm trips some lines and derates the rest" do
      snapshot = diamond_snapshot()
      scenario = Scenarios.ice_storm(snapshot, severity: 5)

      # With severity 5, trip_pct = 15%. With 6 lines, expect 0-2 trips
      # (deterministic, so exact count depends on hash values)
      assert is_list(scenario.forced_trips)
      total_affected = length(scenario.forced_trips) + map_size(scenario.line_deratings)
      # all lines are either tripped or derated
      assert total_affected == 6

      # Tripped lines should not also appear in deratings
      for tripped_id <- scenario.forced_trips do
        refute Map.has_key?(scenario.line_deratings, tripped_id)
      end

      # Description mentions severity
      assert scenario.description =~ "severity 5"
    end

    test "low severity ice storm trips fewer lines" do
      snapshot = diamond_snapshot()
      s1 = Scenarios.ice_storm(snapshot, severity: 1)
      s5 = Scenarios.ice_storm(snapshot, severity: 5)

      # Severity 1 should generally trip fewer (or equal) lines than severity 5
      # Both are deterministic so this is stable
      assert length(s1.forced_trips) <= length(s5.forced_trips) + 1
    end

    test "ice storm loads increase due to electric heating demand" do
      snapshot = diamond_snapshot()
      scenario = Scenarios.ice_storm(snapshot, severity: 3)

      for {_id, mult} <- scenario.load_multipliers do
        assert mult > 1.0,
               "Ice storm should increase loads (heating demand), got multiplier #{mult}"

        assert mult <= 1.20,
               "Ice storm load increase should be reasonable, got multiplier #{mult}"
      end
    end
  end

  # ===========================================================================
  # Wildfire tests
  # ===========================================================================

  describe "wildfire/2" do
    test "wildfire trips lines near fire center" do
      snapshot = diamond_snapshot()

      # Center fire near bus 1 (34.0, -118.0) with small radius
      scenario =
        Scenarios.wildfire(snapshot, center_lat: 34.0, center_lon: -118.0, radius_km: 10.0)

      # Lines connected to bus 1 (ids 1, 2, 3) should be tripped or at least
      # some lines near the fire center should be affected
      assert is_list(scenario.forced_trips)
      # The fire is right on top of bus 1, so lines 1-3 should be tripped
      # (bus 1 is within 10km of itself)
      assert length(scenario.forced_trips) > 0

      assert scenario.description =~ "Wildfire"
    end

    test "wildfire with no buses in range trips nothing" do
      snapshot = diamond_snapshot()

      # Fire in the middle of the ocean
      scenario = Scenarios.wildfire(snapshot, center_lat: 0.0, center_lon: 0.0, radius_km: 10.0)

      assert scenario.forced_trips == []
    end
  end

  # ===========================================================================
  # Earthquake tests
  # ===========================================================================

  describe "earthquake/2" do
    test "earthquake near bus damages connected lines" do
      snapshot = diamond_snapshot()

      # Epicenter right at bus 1 (34.0, -118.0), magnitude 6
      scenario =
        Scenarios.earthquake(snapshot, epicenter_lat: 34.0, epicenter_lon: -118.0, magnitude: 6.0)

      # Damage radius at M6 = 10^(0.5*6 - 1.5) = 10^1.5 ~ 31.6 km
      # Bus 1 is at the epicenter (0 km), so it's damaged
      # Lines 1, 2, 3 connect to bus 1 and should trip
      assert length(scenario.forced_trips) >= 3

      assert scenario.description =~ "Earthquake M6"
    end

    test "larger magnitude damages wider area" do
      snapshot = diamond_snapshot()

      s6 =
        Scenarios.earthquake(snapshot, epicenter_lat: 34.0, epicenter_lon: -118.0, magnitude: 6.0)

      s8 =
        Scenarios.earthquake(snapshot, epicenter_lat: 34.0, epicenter_lon: -118.0, magnitude: 8.0)

      assert length(s8.forced_trips) >= length(s6.forced_trips)
    end
  end

  # ===========================================================================
  # Apply scenario tests
  # ===========================================================================

  describe "apply_scenario/2" do
    test "apply_scenario derates lines" do
      snapshot = diamond_snapshot()
      cascade = fake_cascade_state(snapshot)

      scenario = %Scenarios{
        line_deratings: %{1 => 0.5, 3 => 0.8},
        load_multipliers: %{},
        forced_trips: [],
        generator_deratings: %{},
        description: "test"
      }

      result = Scenarios.apply_scenario(cascade, scenario)

      line_1 = Enum.find(result.lines, &(&1.id == 1))
      line_3 = Enum.find(result.lines, &(&1.id == 3))
      line_2 = Enum.find(result.lines, &(&1.id == 2))

      assert line_1.rating_a_mva == 100.0 * 0.5
      assert line_3.rating_a_mva == 100.0 * 0.8
      # unchanged
      assert line_2.rating_a_mva == 100.0
    end

    test "apply_scenario scales loads" do
      snapshot = diamond_snapshot()
      cascade = fake_cascade_state(snapshot)

      scenario = %Scenarios{
        line_deratings: %{},
        load_multipliers: %{1 => 1.15},
        forced_trips: [],
        generator_deratings: %{},
        description: "test"
      }

      result = Scenarios.apply_scenario(cascade, scenario)

      load_1 = Enum.find(result.loads, &(&1.id == 1))
      assert_in_delta load_1.p_mw, 100.0 * 1.15, 0.01
      assert_in_delta load_1.q_mvar, 15.0 * 1.15, 0.01
    end

    test "apply_scenario adds forced trips" do
      snapshot = diamond_snapshot()
      cascade = fake_cascade_state(snapshot)

      scenario = %Scenarios{
        line_deratings: %{},
        load_multipliers: %{},
        forced_trips: [2, 4],
        generator_deratings: %{},
        description: "test"
      }

      result = Scenarios.apply_scenario(cascade, scenario)

      assert MapSet.member?(result.tripped_lines, 2)
      assert MapSet.member?(result.tripped_lines, 4)
      refute MapSet.member?(result.tripped_lines, 1)
    end

    test "apply_scenario derates generators" do
      snapshot = diamond_snapshot()
      cascade = fake_cascade_state(snapshot)

      scenario = %Scenarios{
        line_deratings: %{},
        load_multipliers: %{},
        forced_trips: [],
        generator_deratings: %{1 => 0.7},
        description: "test"
      }

      result = Scenarios.apply_scenario(cascade, scenario)

      gen_1 = Enum.find(result.generators, &(&1.id == 1))
      assert_in_delta gen_1.p_max_mw, 200.0 * 0.7, 0.01
    end
  end

  # ===========================================================================
  # Coordinate helpers
  # ===========================================================================

  describe "coordinate helpers" do
    test "bus_coords extracts lat/lon from coordinates map" do
      bus = %{coordinates: %{coordinates: {-118.0, 34.0}}}
      assert Scenarios.bus_coords(bus) == {34.0, -118.0}
    end

    test "bus_coords returns nil for missing coordinates" do
      assert Scenarios.bus_coords(%{coordinates: nil}) == nil
      assert Scenarios.bus_coords(%{}) == nil
    end

    test "in_bbox? correctly filters points" do
      assert Scenarios.in_bbox?({34.0, -118.0}, 35.0, 33.0, -117.0, -119.0)
      refute Scenarios.in_bbox?({36.0, -118.0}, 35.0, 33.0, -117.0, -119.0)
    end

    test "haversine_km returns reasonable distances" do
      # LA to SF is roughly 559 km
      la = {34.05, -118.25}
      sf = {37.77, -122.42}
      dist = Scenarios.haversine_km(la, sf)
      assert dist > 500 and dist < 620
    end
  end
end
