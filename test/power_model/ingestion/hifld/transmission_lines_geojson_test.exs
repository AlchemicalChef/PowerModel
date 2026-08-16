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

    test "a feature that carries its own voltage is marked as such" do
      attrs =
        feature(
          %{"source_ID" => "1", "VOLTAGE" => 230.0},
          line_string([[-90.0, 30.0], [-90.1, 30.0]])
        )
        |> TransmissionLines.parse_geojson_feature()

      assert attrs.voltage_kv == 230.0
      assert attrs.voltage_source == :hifld
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

  describe "parse_geojson_feature/2 restoring a circuit with no voltage (TOPO-1)" do
    # 8,814 of the snapshot's features carry the -999999 sentinel AND an
    # unparseable VOLT_CLASS. They used to be dropped; each rule below is one
    # of the four ways a voltage is now inferred for them.
    defp no_voltage_feature(sub_1, sub_2) do
      feature(
        %{
          "source_ID" => "1",
          "VOLTAGE" => -999_999.0,
          "VOLT_CLASS" => "NOT AVAILABLE",
          "SUB_1" => sub_1,
          "SUB_2" => sub_2
        },
        line_string([[-90.0, 30.0], [-90.1, 30.0]])
      )
    end

    defp restore(sub_1, sub_2, index) do
      TransmissionLines.parse_geojson_feature(no_voltage_feature(sub_1, sub_2), index)
    end

    test "takes the highest level both yards have" do
      attrs =
        restore("KEYSTONE", "MIDWAY", %{
          "KEYSTONE" => [{-90.0, 30.0, 345.0}, {-90.0, 30.0, 138.0}],
          "MIDWAY" => [{-90.1, 30.0, 345.0}, {-90.1, 30.0, 138.0}]
        })

      assert attrs.voltage_kv == 345.0
      assert attrs.voltage_source == :shared_level
    end

    test "115 kV and 120 kV count as the same shared level" do
      attrs =
        restore("KEYSTONE", "MIDWAY", %{
          "KEYSTONE" => [{-90.0, 30.0, 115.0}],
          "MIDWAY" => [{-90.1, 30.0, 120.0}]
        })

      assert attrs.voltage_kv == 115.0
      assert attrs.voltage_source == :shared_level
    end

    test "with only one yard known, takes that yard's LOWEST level" do
      attrs =
        restore("KEYSTONE", "TAP999", %{
          "KEYSTONE" => [{-90.0, 30.0, 345.0}, {-90.0, 30.0, 138.0}]
        })

      assert attrs.voltage_kv == 138.0
      assert attrs.voltage_source == :single_yard
    end

    test "two yards with no level in common straddle at the lower yard's top level" do
      attrs =
        restore("KEYSTONE", "MIDWAY", %{
          "KEYSTONE" => [{-90.0, 30.0, 345.0}],
          "MIDWAY" => [{-90.1, 30.0, 230.0}, {-90.1, 30.0, 69.0}]
        })

      assert attrs.voltage_kv == 230.0
      assert attrs.voltage_source == :straddle
    end

    test "neither yard known falls back to the 138 kV default BusMapper would use" do
      assert %{voltage_kv: 138.0, voltage_source: :default} = restore("KEYSTONE", "MIDWAY", %{})
    end

    test "a same-name yard beyond the name-match radius lends nothing" do
      # 0.5 degrees of latitude is ~55 km, twice EndpointMatcher's 25 km.
      attrs = restore("MIDWAY", "MIDWAY", %{"MIDWAY" => [{-90.0, 30.5, 500.0}]})

      assert attrs.voltage_kv == 138.0
      assert attrs.voltage_source == :default
    end

    test "a bare sentinel name is not a yard key, so it lends nothing" do
      attrs =
        restore("NOT AVAILABLE", "NOT AVAILABLE", %{
          "NOT AVAILABLE" => [{-90.0, 30.0, 500.0}]
        })

      assert attrs.voltage_source == :default
    end

    test "UNKNOWN<id>/TAP<id> ARE yard keys (Names) and do lend their level" do
      attrs =
        restore("UNKNOWN128553", "TAP139917", %{
          "UNKNOWN128553" => [{-90.0, 30.0, 161.0}],
          "TAP139917" => [{-90.1, 30.0, 161.0}]
        })

      assert attrs.voltage_kv == 161.0
      assert attrs.voltage_source == :shared_level
    end
  end

  describe "build_yard_voltage_index/1" do
    @tag :tmp_dir
    test "indexes both endpoints of a line that carries a voltage", %{tmp_dir: tmp_dir} do
      path = write_features(tmp_dir, [{"345.0", "AC; OVERHEAD", "ALPHA", "BETA"}])

      index = TransmissionLines.build_yard_voltage_index(path)

      assert %{"ALPHA" => [{-90.0, 30.0, 345.0}], "BETA" => [{-90.1, 30.0, 345.0}]} = index
    end

    @tag :tmp_dir
    test "an HVDC bipole never lends its pole-to-pole voltage (LIN-12)", %{tmp_dir: tmp_dir} do
      # HIFLD stores the Pacific DC Intertie at VOLTAGE 1000 for a +/-500 kV
      # link. A restored circuit at Celilo must not come out at 1000 kV.
      path = write_features(tmp_dir, [{"1000.0", "DC; OVERHEAD", "CELILO", "SYLMAR EAST"}])

      assert TransmissionLines.build_yard_voltage_index(path) == %{}
    end

    @tag :tmp_dir
    test "no AC line above 765 kV lends its voltage either", %{tmp_dir: tmp_dir} do
      path = write_features(tmp_dir, [{"1100.0", "AC; OVERHEAD", "ALPHA", "BETA"}])

      assert TransmissionLines.build_yard_voltage_index(path) == %{}
    end

    defp write_features(tmp_dir, specs) do
      path = Path.join(tmp_dir, "lines.geojsonl")

      body =
        specs
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {{voltage, type, sub_1, sub_2}, i} ->
          %{
            "source_ID" => to_string(i),
            "VOLTAGE" => String.to_float(voltage),
            "TYPE" => type,
            "SUB_1" => sub_1,
            "SUB_2" => sub_2
          }
          |> feature(line_string([[-90.0, 30.0], [-90.1, 30.0]]))
          |> Jason.encode!()
        end)

      File.write!(path, body)
      path
    end
  end

  describe "ingest_geojson/1" do
    test "ingests every feature of the converted fixture and is idempotent" do
      # 25 features: 21 with a HIFLD voltage, 4 restored (TOPO-1).
      assert {:ok, 25} = TransmissionLines.ingest_geojson(@lines_fixture)
      assert Repo.aggregate(TransmissionLine, :count) == 25

      TransmissionLines.ingest_geojson(@lines_fixture)
      assert Repo.aggregate(TransmissionLine, :count) == 25
    end

    test "SUB_1/SUB_2 are stored — they are the connectivity keys" do
      TransmissionLines.ingest_geojson(@lines_fixture)

      with_names =
        Repo.aggregate(
          from(l in TransmissionLine, where: not is_nil(l.sub_1) and not is_nil(l.sub_2)),
          :count
        )

      assert with_names == 25
    end

    test "every inserted line has a positive voltage and is left to the estimator" do
      TransmissionLines.ingest_geojson(@lines_fixture)

      lines = Repo.all(TransmissionLine)

      assert Enum.all?(lines, &(&1.voltage_kv > 0.0)),
             "a line with no voltage would have no class to estimate from"

      # Below ParameterEstimator.params_version/0, so the restored circuits get
      # an impedance and a rating like every other row.
      assert Enum.all?(lines, &(&1.params_version == 0))
      assert Enum.all?(lines, &is_nil(&1.x_pu))
    end

    test "the restored circuits are the ones HIFLD gave no voltage" do
      TransmissionLines.ingest_geojson(@lines_fixture)

      restored =
        Repo.all(
          from l in TransmissionLine,
            where: l.source_id in ["100000", "100003", "100012", "100018"],
            select: {l.source_id, l.voltage_kv}
        )

      assert length(restored) == 4
      assert Enum.all?(restored, fn {_id, kv} -> kv > 0.0 end)
    end
  end
end
