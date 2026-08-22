defmodule PowerModel.Ingestion.OSM.LineVoltagesTest do
  use ExUnit.Case, async: true

  alias PowerModel.Ingestion.OSM.LineVoltages

  describe "distance_to_way_m/3" do
    test "perpendicular distance to a passing segment" do
      # way runs east-west 0.001 deg (~110.5 m) north of the point
      geometry = [{40.001, -83.01}, {40.001, -82.99}]
      d = LineVoltages.distance_to_way_m(40.0, -83.0, geometry)
      assert_in_delta d, 110.5, 2.0
    end

    test "distance to the nearest endpoint when the projection falls outside" do
      geometry = [{40.0, -82.99}, {40.0, -82.98}]
      d = LineVoltages.distance_to_way_m(40.0, -83.0, geometry)
      # ~0.01 deg longitude at lat 40 is ~852 m
      assert_in_delta d, 852.0, 10.0
    end
  end

  describe "infer/2" do
    defp yard(id, lat, lon) do
      %{
        id: id,
        name: "UNKNOWN#{id}",
        hifld_id: "#{id}",
        levels: [],
        class: :blind,
        lat: lat,
        lon: lon
      }
    end

    test "a way passing within the radius lends its levels; a distant one does not" do
      ways = [
        %{
          id: 1,
          raw_voltage: "69000",
          levels_kv: [69.0],
          geometry: [{40.0008, -83.01}, {40.0008, -82.99}]
        },
        %{
          id: 2,
          raw_voltage: "345000",
          levels_kv: [345.0],
          geometry: [{40.01, -83.01}, {40.01, -82.99}]
        }
      ]

      assert [%{yard: %{id: 7}, levels: [69.0], ways: [{%{id: 1}, d}]}] =
               LineVoltages.infer([yard(7, 40.0, -83.0)], ways)

      assert d < 120.0
    end

    test "levels from several crossing ways merge with the 5% clustering" do
      ways = [
        %{
          id: 1,
          raw_voltage: "69000",
          levels_kv: [69.0],
          geometry: [{40.0004, -83.01}, {40.0004, -82.99}]
        },
        %{
          id: 2,
          raw_voltage: "138000",
          levels_kv: [138.0],
          geometry: [{39.9996, -83.01}, {39.9996, -82.99}]
        }
      ]

      assert [%{levels: [138.0, 69.0]}] = LineVoltages.infer([yard(7, 40.0, -83.0)], ways)
    end

    test "a yard with no way in range gets nothing" do
      ways = [
        %{
          id: 2,
          raw_voltage: "345000",
          levels_kv: [345.0],
          geometry: [{40.01, -83.01}, {40.01, -82.99}]
        }
      ]

      assert LineVoltages.infer([yard(7, 40.0, -83.0)], ways) == []
    end
  end

  describe "load_snapshot!/1" do
    @fixture Path.expand("../../../fixtures/osm/line_voltages_mini.json", __DIR__)

    test "keeps voltage-tagged grid ways, drops traction and short geometry" do
      ways = LineVoltages.load_snapshot!(@fixture)

      assert [%{id: 501, levels_kv: [138.0], geometry: [{_, _} | _]}] = ways
    end
  end
end
