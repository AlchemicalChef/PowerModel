defmodule PowerModel.Ingestion.OSM.SubstationsTest do
  use ExUnit.Case, async: true

  alias PowerModel.Ingestion.OSM.Substations

  doctest PowerModel.Ingestion.OSM.Substations

  describe "parse_voltage_levels/1" do
    test "volts become kV, descending" do
      assert Substations.parse_voltage_levels("765000;500000") == [765.0, 500.0]
      assert Substations.parse_voltage_levels("69000") == [69.0]
    end

    test "duplicated values collapse to one level" do
      assert Substations.parse_voltage_levels("138000;138000") == [138.0]
    end

    test "5% near-duplicates collapse like the HIFLD side" do
      assert Substations.parse_voltage_levels("115000;120000") == [120.0]
    end

    test "distribution levels below 20 kV are dropped from yard classing" do
      assert Substations.parse_voltage_levels("138000;12470") == [138.0]
      assert Substations.parse_voltage_levels("14400") == []
      assert Substations.parse_voltage_levels("12470;7200") == []
    end

    test "rail traction and junk do not survive" do
      assert Substations.parse_voltage_levels("750") == []
      assert Substations.parse_voltage_levels("HV") == []
      assert Substations.parse_voltage_levels("138000;abc") == [138.0]
      assert Substations.parse_voltage_levels(nil) == []
    end
  end

  describe "name_similarity/2" do
    test "operator prefixes and Substation suffixes do not hide agreement" do
      assert Substations.name_similarity("FIRSTENERGY W H SAMMIS", "Sammis Substation") == 1.0
    end

    test "distinct adjacent yards score low (the Ross/CLUTCH SWITCH case)" do
      sim = Substations.name_similarity("CLUTCH SWITCH", "Ross Substation")
      assert sim < 0.35
    end

    test "no usable tokens on either side is no signal, not zero" do
      assert Substations.name_similarity("Substation", "Port Union Substation") == nil
      assert Substations.name_similarity(nil, "Port Union Substation") == nil
    end

    test "minor spelling drift still matches fuzzily" do
      assert Substations.name_similarity("PORT UNION", "Port Union Substation") == 1.0
    end
  end

  describe "load_snapshot!/1" do
    @fixture Path.expand("../../../fixtures/osm/substations_mini.json", __DIR__)

    test "parses nodes and way centers, drops unusable elements" do
      subs = Substations.load_snapshot!(@fixture)

      assert [
               %{type: "way", id: 23_025_800, levels_kv: [345.0, 138.0], lat: lat},
               %{type: "way", id: 44_100_200, name: "Sammis Substation", levels_kv: [138.0]},
               %{type: "node", id: 3_492_005_001, levels_kv: [69.0]}
             ] = Enum.sort_by(subs, & &1.id)

      assert_in_delta lat, 39.4, 0.01
      # the traction-only ("750") and centerless elements are gone
      refute Enum.any?(subs, &(&1.id == 99_999_999))
      refute Enum.any?(subs, &(&1.id == 88_888_888))
    end
  end
end
