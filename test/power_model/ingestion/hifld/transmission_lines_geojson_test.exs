defmodule PowerModel.Ingestion.HIFLD.TransmissionLinesGeoJSONTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid.TransmissionLine
  alias PowerModel.Ingestion.HIFLD.TransmissionLines

  @lines_fixture "test/fixtures/hifld/transmission_lines_mini.geojsonl"

  defp feature(props, geometry) do
    %{"type" => "Feature", "geometry" => geometry, "properties" => props}
  end

  defp line_string(coords), do: %{"type" => "LineString", "coordinates" => coords}

  describe "parse_geojson_feature/1 (HIFLD Next schema)" do
    test "reads the snapshot's field names, source_ID included" do
      attrs =
        feature(
          %{
            "source_ID" => "100000",
            "VOLTAGE" => 138.0,
            "VOLT_CLASS" => "100-161",
            "TYPE" => "AC; OVERHEAD",
            "STATUS" => "IN SERVICE",
            "SUB_1" => "KEYSTONE",
            "SUB_2" => "MIDWAY",
            "OWNER" => "SOME UTILITY",
            "NAICS_CODE" => "221121"
          },
          line_string([[-90.0, 30.0], [-90.5, 30.0]])
        )
        |> TransmissionLines.parse_geojson_feature()

      assert attrs.source_id == "100000"
      assert attrs.source == "hifld"
      assert attrs.voltage_kv == 138.0
      assert attrs.sub_1 == "KEYSTONE"
      assert attrs.sub_2 == "MIDWAY"
      assert attrs.status == "in_service"
      assert attrs.line_type == "AC; OVERHEAD"
      assert_in_delta attrs.length_km, 48.2, 0.5
    end

    test "the -999999 VOLTAGE sentinel falls back to VOLT_CLASS" do
      attrs =
        feature(
          %{"source_ID" => "1", "VOLTAGE" => -999_999.0, "VOLT_CLASS" => "100-161"},
          line_string([[-90.0, 30.0], [-90.1, 30.0]])
        )
        |> TransmissionLines.parse_geojson_feature()

      assert attrs.voltage_kv == 130.5
    end

    test "a row with neither a usable VOLTAGE nor VOLT_CLASS is dropped" do
      assert TransmissionLines.parse_geojson_feature(
               feature(
                 %{"source_ID" => "1", "VOLTAGE" => -999_999.0, "VOLT_CLASS" => "NOT AVAILABLE"},
                 line_string([[-90.0, 30.0], [-90.1, 30.0]])
               )
             ) == nil
    end

    test "HVDC is marked from either TYPE or VOLT_CLASS (LIN-6)" do
      by_type =
        feature(
          %{"source_ID" => "1", "VOLTAGE" => 500.0, "TYPE" => "DC; OVERHEAD"},
          line_string([[-90.0, 30.0], [-90.1, 30.0]])
        )
        |> TransmissionLines.parse_geojson_feature()

      by_class =
        feature(
          %{"source_ID" => "2", "VOLTAGE" => 500.0, "VOLT_CLASS" => "DC"},
          line_string([[-90.0, 30.0], [-90.1, 30.0]])
        )
        |> TransmissionLines.parse_geojson_feature()

      assert by_type.line_type == "dc"
      assert by_class.line_type == "dc"
    end

    test "a MultiLineString's length is the per-part sum, never bridged (LIN-9)" do
      attrs =
        feature(
          %{"source_ID" => "1", "VOLTAGE" => 138.0},
          %{
            "type" => "MultiLineString",
            "coordinates" => [
              [[-90.0, 30.0], [-90.1, 30.0]],
              [[-80.0, 30.0], [-80.1, 30.0]]
            ]
          }
        )
        |> TransmissionLines.parse_geojson_feature()

      # Two ~9.6 km parts; the 960 km gap between them is not a segment.
      assert attrs.length_km < 25.0
      # Geometry keeps the true endpoints of the whole line.
      assert List.first(attrs.geometry.coordinates) == {-90.0, 30.0}
      assert List.last(attrs.geometry.coordinates) == {-80.1, 30.0}
    end

    test "NOT AVAILABLE status stays in service (LIN-2)" do
      attrs =
        feature(
          %{"source_ID" => "1", "VOLTAGE" => 138.0, "STATUS" => "NOT AVAILABLE"},
          line_string([[-90.0, 30.0], [-90.1, 30.0]])
        )
        |> TransmissionLines.parse_geojson_feature()

      assert attrs.status == "in_service"
    end
  end

  describe "ingest_geojson/1" do
    test "ingests the converted fixture and is idempotent" do
      assert {:ok, 21} = TransmissionLines.ingest_geojson(@lines_fixture)
      assert Repo.aggregate(TransmissionLine, :count) == 21

      TransmissionLines.ingest_geojson(@lines_fixture)
      assert Repo.aggregate(TransmissionLine, :count) == 21
    end

    test "SUB_1/SUB_2 are stored — they are the connectivity keys" do
      TransmissionLines.ingest_geojson(@lines_fixture)

      with_names =
        Repo.aggregate(
          from(l in TransmissionLine, where: not is_nil(l.sub_1) and not is_nil(l.sub_2)),
          :count
        )

      assert with_names == 21
    end
  end
end
