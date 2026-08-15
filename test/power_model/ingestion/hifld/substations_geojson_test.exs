defmodule PowerModel.Ingestion.HIFLD.SubstationsGeoJSONTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid.{Substation, TransmissionLine}
  alias PowerModel.Ingestion.HIFLD.Substations

  @substations_fixture "test/fixtures/hifld/substations_mini.geojson"
  @lines_fixture "test/fixtures/hifld/transmission_lines_mini.geojsonl"

  describe "parse_geojson_substation/1" do
    test "a normal yard keeps both reported levels" do
      entry =
        Substations.parse_geojson_substation(%{
          "geometry" => %{"type" => "Point", "coordinates" => [-90.0, 30.0]},
          "properties" => %{
            "ID" => "107655",
            "NAME" => "HOLCOMBE",
            "MAX_VOLT" => 161,
            "MIN_VOLT" => 69,
            "STATUS" => "IN SERVICE"
          }
        })

      assert entry.name == "HOLCOMBE"
      assert entry.hifld_id == "107655"
      assert entry.voltage_levels == [161.0, 69.0]
      assert entry.max_voltage_kv == 161.0
      assert entry.min_voltage_kv == 69.0
      assert entry.status == "in_service"
      assert %Geo.Point{coordinates: {-90.0, 30.0}} = entry.coordinates
    end

    test "-999999 sentinels become nil, never a million-volt yard" do
      entry =
        Substations.parse_geojson_substation(%{
          "geometry" => %{"type" => "Point", "coordinates" => [-90.0, 30.0]},
          "properties" => %{"ID" => "1", "NAME" => "A", "MAX_VOLT" => 115, "MIN_VOLT" => -999_999}
        })

      assert entry.voltage_levels == [115.0]
      assert entry.max_voltage_kv == 115.0
      assert entry.min_voltage_kv == nil
    end

    test "a yard with both voltages sentinel still ingests, with no levels" do
      entry =
        Substations.parse_geojson_substation(%{
          "geometry" => %{"type" => "Point", "coordinates" => [-90.0, 30.0]},
          "properties" => %{
            "ID" => "2",
            "NAME" => "B",
            "MAX_VOLT" => -999_999,
            "MIN_VOLT" => -999_999
          }
        })

      assert entry.voltage_levels == []
      assert entry.max_voltage_kv == nil
      assert entry.min_voltage_kv == nil
    end

    test "equal max and min collapse to a single level" do
      entry =
        Substations.parse_geojson_substation(%{
          "geometry" => %{"type" => "Point", "coordinates" => [-90.0, 30.0]},
          "properties" => %{"ID" => "3", "NAME" => "C", "MAX_VOLT" => 115, "MIN_VOLT" => 115}
        })

      assert entry.voltage_levels == [115.0]
      assert entry.min_voltage_kv == nil
    end

    test "explicit outage codes are honored, unknown ones are not (LIN-2)" do
      out =
        Substations.parse_geojson_substation(%{
          "geometry" => %{"type" => "Point", "coordinates" => [-90.0, 30.0]},
          "properties" => %{"ID" => "4", "NAME" => "D", "STATUS" => "UNDER CONSTRUCTION"}
        })

      unknown =
        Substations.parse_geojson_substation(%{
          "geometry" => %{"type" => "Point", "coordinates" => [-90.0, 30.0]},
          "properties" => %{"ID" => "5", "NAME" => "E", "STATUS" => "NOT AVAILABLE"}
        })

      assert out.status == "out_of_service"
      assert unknown.status == "in_service"
    end

    test "a nameless row is named after its own id rather than dropped" do
      entry =
        Substations.parse_geojson_substation(%{
          "geometry" => %{"type" => "Point", "coordinates" => [-90.0, 30.0]},
          "properties" => %{"ID" => "9911", "NAME" => nil}
        })

      assert entry.name == "UNKNOWN9911"
    end

    test "features with no point geometry or no id are skipped" do
      assert Substations.parse_geojson_substation(%{
               "geometry" => nil,
               "properties" => %{"ID" => "1", "NAME" => "A"}
             }) == nil

      assert Substations.parse_geojson_substation(%{
               "geometry" => %{"type" => "Point", "coordinates" => [-90.0, 30.0]},
               "properties" => %{"NAME" => "A"}
             }) == nil
    end
  end

  describe "sanitize_voltage/1" do
    test "the HIFLD null sentinel and non-positive values are nil" do
      assert Substations.sanitize_voltage(-999_999) == nil
      assert Substations.sanitize_voltage(0) == nil
      assert Substations.sanitize_voltage(-1) == nil
      assert Substations.sanitize_voltage(nil) == nil
      assert Substations.sanitize_voltage("not a number") == nil
    end

    test "real voltages come back as floats, strings included" do
      assert Substations.sanitize_voltage(345) == 345.0
      assert Substations.sanitize_voltage("230.0") == 230.0
    end
  end

  describe "ingest_geojson/1 (native layer)" do
    test "ingests the mirror's features and is idempotent on re-run" do
      assert {:ok, 51} = Substations.ingest_geojson(@substations_fixture)
      assert Repo.aggregate(Substation, :count) == 51

      # Upserts on hifld_id: a second pass adds nothing.
      Substations.ingest_geojson(@substations_fixture)
      assert Repo.aggregate(Substation, :count) == 51

      assert Repo.aggregate(Substation, :count, :hifld_id) == 51
    end

    test "real names survive — this is what endpoints key to" do
      Substations.ingest_geojson(@substations_fixture)

      named =
        Repo.all(from s in Substation, where: not like(s.name, "UNKNOWN%"), select: s.name)

      assert "LOUIS DOC BONIN" in named
    end
  end

  describe "augment_voltage_levels_from_lines/0 (LIN-5 through the data)" do
    setup do
      Substations.ingest_geojson(@substations_fixture)
      PowerModel.Ingestion.HIFLD.TransmissionLines.ingest_geojson(@lines_fixture)
      :ok
    end

    test "a level a line terminates at gains a place in the substation's list" do
      # LOUIS DOC BONIN reports MAX_VOLT 230 and a MIN_VOLT sentinel, so the
      # 138 kV circuits terminating there had no level to land on.
      sub = Repo.get_by!(Substation, name: "LOUIS DOC BONIN")
      before_levels = sub.voltage_levels

      line_voltages =
        Repo.all(
          from l in TransmissionLine,
            where: l.sub_1 == ^sub.name or l.sub_2 == ^sub.name,
            select: l.voltage_kv
        )

      assert line_voltages != []

      Substations.augment_voltage_levels_from_lines()

      after_levels = Repo.get!(Substation, sub.id).voltage_levels

      assert length(after_levels) >= length(before_levels)

      for kv <- line_voltages do
        assert Enum.any?(after_levels, &(abs(&1 - kv) <= kv * 0.05)),
               "no level within 5% of a terminating #{kv} kV line: #{inspect(after_levels)}"
      end
    end

    test "levels stay sorted descending and max/min stay the ends of the list" do
      Substations.augment_voltage_levels_from_lines()

      for sub <- Repo.all(from s in Substation, where: not is_nil(s.voltage_levels)),
          sub.voltage_levels != [] do
        assert sub.voltage_levels == Enum.sort(sub.voltage_levels, :desc)
        assert sub.max_voltage_kv == List.first(sub.voltage_levels)

        if length(sub.voltage_levels) > 1 do
          assert sub.min_voltage_kv == List.last(sub.voltage_levels)
        else
          assert sub.min_voltage_kv == nil
        end
      end
    end

    test "running it twice changes nothing the second time" do
      first = Substations.augment_voltage_levels_from_lines()
      assert first.substations_updated > 0

      second = Substations.augment_voltage_levels_from_lines()
      assert second.substations_updated == 0
      assert second.levels_added == 0
    end
  end
end
