defmodule PowerModel.Ingestion.HIFLD.TransmissionLinesTest do
  use ExUnit.Case, async: true

  alias PowerModel.Ingestion.HIFLD.TransmissionLines

  # 0.1 deg of latitude ~= 11.12 km
  @part_len_km 11.12

  defp feature(attrs_overrides \\ %{}, paths) do
    attrs =
      Map.merge(
        %{
          "ID" => 12345,
          "VOLTAGE" => 345,
          "VOLT_CLASS" => "345",
          "STATUS" => "NOT AVAILABLE",
          "TYPE" => "AC; OVERHEAD",
          "OWNER" => "TEST CO",
          "SUB_1" => "ALPHA",
          "SUB_2" => "BETA",
          "NAICS_CODE" => "2211",
          "NAICS_DESC" => "POWER"
        },
        attrs_overrides
      )

    %{"attributes" => attrs, "geometry" => %{"paths" => paths}}
  end

  describe "parse_status/1 (LIN-2)" do
    test "NOT AVAILABLE and unknown codes map to in_service" do
      assert TransmissionLines.parse_status("NOT AVAILABLE") == "in_service"
      assert TransmissionLines.parse_status("SOME NEW CODE") == "in_service"
      assert TransmissionLines.parse_status(nil) == "in_service"
      assert TransmissionLines.parse_status("") == "in_service"
      assert TransmissionLines.parse_status("IN SERVICE") == "in_service"
    end

    test "only explicit outage codes map to out_of_service" do
      for status <- [
            "INACTIVE",
            "RETIRED",
            "UNDER CONSTRUCTION",
            "PROPOSED",
            "DECOMMISSIONED",
            " retired "
          ] do
        assert TransmissionLines.parse_status(status) == "out_of_service",
               "expected #{inspect(status)} to be out_of_service"
      end
    end

    test "parsed features keep NOT AVAILABLE lines in service" do
      parsed =
        feature(%{"STATUS" => "NOT AVAILABLE"}, [[[-119.0, 35.0], [-119.0, 35.1]]])
        |> TransmissionLines.parse_api_feature()

      assert parsed.status == "in_service"
    end
  end

  describe "line_type_from/2 (LIN-6)" do
    test "VOLT_CLASS DC yields the canonical dc marker" do
      assert TransmissionLines.line_type_from("DC", "DC; OVERHEAD") == "dc"
      assert TransmissionLines.line_type_from(" dc ", nil) == "dc"
    end

    test "DC-prefixed TYPE also yields dc when VOLT_CLASS is unhelpful" do
      assert TransmissionLines.line_type_from("NOT AVAILABLE", "DC; OVERHEAD") == "dc"
    end

    test "AC lines keep the raw TYPE" do
      assert TransmissionLines.line_type_from("345", "AC; OVERHEAD") == "AC; OVERHEAD"
      assert TransmissionLines.line_type_from(nil, nil) == nil
    end

    test "parsed HVDC feature is stored with line_type dc" do
      parsed =
        feature(%{"VOLTAGE" => 500, "VOLT_CLASS" => "DC", "TYPE" => "DC; OVERHEAD"}, [
          [[-121.0, 45.0], [-121.0, 45.1]]
        ])
        |> TransmissionLines.parse_api_feature()

      assert parsed.line_type == "dc"
    end
  end

  describe "parse_paths/1 (LIN-9)" do
    test "keeps parts separate and drops Z coordinates" do
      paths = [
        [[-119.0, 35.0, 812.5], [-119.0, 35.1, 820.0]],
        [[-117.0, 35.0], [-117.0, 35.1]]
      ]

      assert TransmissionLines.parse_paths(paths) == [
               [{-119.0, 35.0}, {-119.0, 35.1}],
               [{-117.0, 35.0}, {-117.0, 35.1}]
             ]
    end

    test "drops malformed points and degenerate parts" do
      paths = [
        [[-119.0, 35.0], ["x", "y"], [-119.0, 35.1]],
        [[-117.0, 35.0]],
        "not a part"
      ]

      assert TransmissionLines.parse_paths(paths) == [[{-119.0, 35.0}, {-119.0, 35.1}]]
    end

    test "non-list input yields no parts" do
      assert TransmissionLines.parse_paths(nil) == []
    end
  end

  describe "parts_length_km/1 (LIN-9)" do
    test "sums within parts only, never bridging between them" do
      parts = [
        [{-119.0, 35.0}, {-119.0, 35.1}],
        # ~180 km east of part 1: a flattened parser would add that bridge
        [{-117.0, 35.0}, {-117.0, 35.1}]
      ]

      assert_in_delta TransmissionLines.parts_length_km(parts), 2 * @part_len_km, 0.3
    end

    test "empty parts yield nil" do
      assert TransmissionLines.parts_length_km([]) == nil
    end
  end

  describe "parse_api_feature/1 multi-part geometry (LIN-9)" do
    test "no phantom bridge: length is the per-part sum" do
      parsed =
        feature([
          [[-119.0, 35.0], [-119.0, 35.1]],
          [[-117.0, 35.0], [-117.0, 35.1]]
        ])
        |> TransmissionLines.parse_api_feature()

      # Flattened parsing would report ~204 km (22 km of line + 182 km bridge)
      assert_in_delta parsed.length_km, 2 * @part_len_km, 0.3
      assert parsed.length_km < 100.0
    end

    test "line endpoints are first point of first part / last point of last part" do
      parsed =
        feature([
          [[-119.0, 35.0], [-119.0, 35.1]],
          [[-117.0, 35.0], [-117.0, 35.1]]
        ])
        |> TransmissionLines.parse_api_feature()

      assert %Geo.LineString{coordinates: coords} = parsed.geometry
      assert List.first(coords) == {-119.0, 35.0}
      assert List.last(coords) == {-117.0, 35.1}
      assert length(coords) == 4
    end

    test "Z coordinates do not scramble the parsed points" do
      # The old flatten/chunk_every(2) parser turned [lon, lat, z] triples
      # into nonsense pairs like {z, lon}.
      parsed =
        feature([[[-119.0, 35.0, 812.5], [-119.05, 35.05, 820.0], [-119.0, 35.1, 830.0]]])
        |> TransmissionLines.parse_api_feature()

      assert %Geo.LineString{coordinates: coords} = parsed.geometry
      assert coords == [{-119.0, 35.0}, {-119.05, 35.05}, {-119.0, 35.1}]
    end

    test "features without at least 2 valid points are rejected" do
      assert feature([[[-119.0, 35.0]]]) |> TransmissionLines.parse_api_feature() == nil
      assert feature([]) |> TransmissionLines.parse_api_feature() == nil
    end
  end
end
