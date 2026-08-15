defmodule PowerModel.Ingestion.HIFLD.GeoJSONTest do
  use ExUnit.Case, async: true

  alias PowerModel.Ingestion.HIFLD.GeoJSON

  @lines_fixture "test/fixtures/hifld/transmission_lines_mini.geojsonl"
  @substations_fixture "test/fixtures/hifld/substations_mini.geojson"

  describe "format detection" do
    test "the converted line snapshot reads as newline-delimited features" do
      refute GeoJSON.feature_collection?(@lines_fixture)
    end

    test "the substation mirror reads as one FeatureCollection" do
      assert GeoJSON.feature_collection?(@substations_fixture)
    end
  end

  describe "stream_features!/1 row counts (conversion contract)" do
    test "every line of the converted fixture is one Feature" do
      features = @lines_fixture |> GeoJSON.stream_features!() |> Enum.to_list()

      # scripts/convert_vendored_hifld.py --limit 25 wrote this file; the
      # count is the contract the full 94,619-feature conversion is checked
      # against by the script's own accounting.
      assert length(features) == 25
      assert Enum.all?(features, &(&1["type"] == "Feature"))
    end

    test "the fixture carries every field the ingester reads, INFERRED included" do
      features = @lines_fixture |> GeoJSON.stream_features!() |> Enum.to_list()

      for field <- ~w(source_ID TYPE STATUS VOLTAGE VOLT_CLASS INFERRED SUB_1 SUB_2) do
        assert Enum.all?(features, &Map.has_key?(&1["properties"], field)),
               "#{field} did not survive the parquet -> GeoJSON conversion"
      end
    end

    test "the FeatureCollection fixture yields its features" do
      features = @substations_fixture |> GeoJSON.stream_features!() |> Enum.to_list()

      assert length(features) == 51
      assert Enum.all?(features, &(&1["geometry"]["type"] == "Point"))
    end
  end

  describe "line_parts/1" do
    test "a LineString is one part" do
      feature = %{
        "geometry" => %{"type" => "LineString", "coordinates" => [[-90.0, 30.0], [-90.1, 30.1]]}
      }

      assert GeoJSON.line_parts(feature) == [[{-90.0, 30.0}, {-90.1, 30.1}]]
    end

    test "a MultiLineString keeps its parts apart (no phantom bridge, LIN-9)" do
      feature = %{
        "geometry" => %{
          "type" => "MultiLineString",
          "coordinates" => [
            [[-90.0, 30.0], [-90.1, 30.0]],
            [[-80.0, 30.0], [-80.1, 30.0]]
          ]
        }
      }

      assert [part_a, part_b] = GeoJSON.line_parts(feature)
      assert part_a == [{-90.0, 30.0}, {-90.1, 30.0}]
      assert part_b == [{-80.0, 30.0}, {-80.1, 30.0}]
    end

    test "Z ordinates are dropped and degenerate parts discarded" do
      feature = %{
        "geometry" => %{
          "type" => "MultiLineString",
          "coordinates" => [
            [[-90.0, 30.0, 120.0], [-90.1, 30.1, 130.0]],
            [[-80.0, 30.0]]
          ]
        }
      }

      assert GeoJSON.line_parts(feature) == [[{-90.0, 30.0}, {-90.1, 30.1}]]
    end

    test "missing or point geometry yields no parts" do
      assert GeoJSON.line_parts(%{}) == []

      assert GeoJSON.line_parts(%{"geometry" => %{"type" => "Point", "coordinates" => [1, 2]}}) ==
               []
    end
  end

  describe "point_coordinates/1" do
    test "reads lon/lat and ignores any further ordinates" do
      assert GeoJSON.point_coordinates(%{
               "geometry" => %{"type" => "Point", "coordinates" => [-90.5, 30.25, 10.0]}
             }) == {-90.5, 30.25}
    end

    test "nil for other or missing geometry" do
      assert GeoJSON.point_coordinates(%{"geometry" => nil}) == nil
      assert GeoJSON.point_coordinates(%{}) == nil
    end
  end
end
