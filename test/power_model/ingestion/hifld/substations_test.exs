defmodule PowerModel.Ingestion.HIFLD.SubstationsTest do
  use ExUnit.Case, async: true

  alias PowerModel.Ingestion.HIFLD.Substations

  # ~4 km in degrees of latitude (1 deg lat ~= 111.2 km)
  @four_km_lat 0.036

  describe "parse_status/1 (LIN-2 mirror)" do
    test "explicit outage codes map to out_of_service" do
      for status <- [
            "INACTIVE",
            "RETIRED",
            "UNDER CONSTRUCTION",
            "PROPOSED",
            "DECOMMISSIONED",
            " inactive "
          ] do
        assert Substations.parse_status(status) == "out_of_service",
               "expected #{inspect(status)} to be out_of_service"
      end
    end

    test "NOT AVAILABLE / unknown / missing statuses are in_service" do
      assert Substations.parse_status("NOT AVAILABLE") == "in_service"
      assert Substations.parse_status("SOME NEW CODE") == "in_service"
      assert Substations.parse_status("IN SERVICE") == "in_service"
      assert Substations.parse_status(nil) == "in_service"
      assert Substations.parse_status("") == "in_service"
    end
  end

  describe "sentinel_name?/1 (LIN-1)" do
    test "sentinel names are detected" do
      assert Substations.sentinel_name?("NOT AVAILABLE")
      assert Substations.sentinel_name?("NONE")
      assert Substations.sentinel_name?("DEADHEAD")
      assert Substations.sentinel_name?("UNKNOWN123")
      assert Substations.sentinel_name?("TAP 45")
      assert Substations.sentinel_name?(" not available ")
    end

    test "real names are not sentinels" do
      refute Substations.sentinel_name?("MIDWAY")
      refute Substations.sentinel_name?("KEYSTONE")
      # TAP must be a prefix, contained is fine
      refute Substations.sentinel_name?("WESTAP")
    end
  end

  describe "cluster_endpoints/2 (LIN-1)" do
    test "endpoints far apart form separate clusters" do
      endpoints = [{-119.0, 35.0, 230.0}, {-73.0, 42.0, 230.0}]

      clusters = Substations.cluster_endpoints(endpoints, 5.0)
      assert length(clusters) == 2
    end

    test "endpoints within 5 km form one cluster" do
      # ~0.91 km apart
      endpoints = [{-119.0, 35.0, 230.0}, {-119.01, 35.0, 115.0}]

      assert [cluster] = Substations.cluster_endpoints(endpoints, 5.0)
      assert length(cluster) == 2
    end

    test "clustering is transitive (chain within threshold merges)" do
      # A-B ~4 km, B-C ~4 km, A-C ~8 km: still one cluster via B
      endpoints = [
        {-119.0, 35.0, nil},
        {-119.0, 35.0 + @four_km_lat, nil},
        {-119.0, 35.0 + 2 * @four_km_lat, nil}
      ]

      assert [cluster] = Substations.cluster_endpoints(endpoints, 5.0)
      assert length(cluster) == 3
    end
  end

  describe "cluster_voltage_levels/1 (LIN-10)" do
    test "levels within 5% merge into one, keeping the highest" do
      assert Substations.cluster_voltage_levels([115.0, 120.0]) == [120.0]
      assert Substations.cluster_voltage_levels([138.0, 138.4]) == [138.4]
    end

    test "distinct levels are preserved, sorted descending" do
      assert Substations.cluster_voltage_levels([115.0, 500.0, 120.0]) == [500.0, 120.0]
      assert Substations.cluster_voltage_levels([230.0]) == [230.0]
      assert Substations.cluster_voltage_levels([]) == []
    end
  end

  describe "build_entries/1 (LIN-1 identity)" do
    test "same-name endpoints thousands of km apart become distinct substations" do
      endpoints = [
        {"MIDWAY", -119.0, 35.0, 230.0},
        {"MIDWAY", -73.0, 42.0, 345.0}
      ]

      entries = Substations.build_entries(endpoints)

      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.name == "MIDWAY"))

      ids = entries |> Enum.map(& &1.hifld_id) |> Enum.sort()
      assert length(Enum.uniq(ids)) == 2
      assert Enum.all?(ids, &String.starts_with?(&1, "MIDWAY@"))
    end

    test "same-name endpoints within 5 km merge into one substation at the centroid" do
      endpoints = [
        {"KEYSTONE", -119.0, 35.0, 500.0},
        {"KEYSTONE", -119.01, 35.0, 230.0}
      ]

      assert [entry] = Substations.build_entries(endpoints)
      assert entry.name == "KEYSTONE"
      assert %Geo.Point{coordinates: {lon, lat}} = entry.coordinates
      assert_in_delta lon, -119.005, 1.0e-9
      assert_in_delta lat, 35.0, 1.0e-9
      assert entry.hifld_id =~ ~r/^KEYSTONE@35\.00,-119\.0[01]$/
      assert entry.max_voltage_kv == 500.0
      assert entry.min_voltage_kv == 230.0
    end

    test "sentinel names are never merged: one substation per endpoint location" do
      endpoints = [
        {"NOT AVAILABLE", -119.0, 35.0, 115.0},
        {"NOT AVAILABLE", -73.0, 42.0, 115.0},
        {"DEADHEAD", -100.0, 40.0, nil}
      ]

      entries = Substations.build_entries(endpoints)

      assert length(entries) == 3
      not_avail = Enum.filter(entries, &(&1.name == "NOT AVAILABLE"))
      assert length(not_avail) == 2
      assert length(Enum.uniq(Enum.map(not_avail, & &1.hifld_id))) == 2
    end

    test "UNKNOWN*/TAP* endpoints get per-endpoint entries instead of being dropped" do
      endpoints = [
        {"UNKNOWN123", -119.0, 35.0, 115.0},
        {"TAP 7", -119.5, 35.5, 69.0}
      ]

      entries = Substations.build_entries(endpoints)

      assert length(entries) == 2
      assert Enum.any?(entries, &(&1.name == "UNKNOWN123"))
      assert Enum.any?(entries, &(&1.name == "TAP 7"))
    end

    test "voltage levels within 5% collapse to one level (single-level -> nil min)" do
      endpoints = [
        {"ALPHA", -119.0, 35.0, 115.0},
        {"ALPHA", -119.001, 35.0, 120.0}
      ]

      assert [entry] = Substations.build_entries(endpoints)
      assert entry.max_voltage_kv == 120.0
      assert entry.min_voltage_kv == nil
    end

    test "entries carry required insert fields" do
      assert [entry] = Substations.build_entries([{"BETA", -119.0, 35.0, 230.0}])
      assert entry.status == "in_service"
      assert %NaiveDateTime{} = entry.inserted_at
      assert %NaiveDateTime{} = entry.updated_at
      assert entry.hifld_id == "BETA@35.00,-119.00"
    end
  end
end
