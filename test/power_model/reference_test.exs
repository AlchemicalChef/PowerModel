defmodule PowerModel.ReferenceTest do
  @moduledoc """
  The reference corpus and the POI floor derived from it.

  These tests pin two things the corpus must not lose: that absence is a
  supported state (a checkout without the artifact still runs every census,
  just unscored), and that the floor is read as the MOST PERMISSIVE reading —
  a bus failing it is one no reference case would produce.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Reference

  # Registered deliberately: the moduledoc example was previously unreachable,
  # so it documented behaviour nothing checked. The example is chosen to hold
  # whether or not the artifact is present, since absence is a supported state.
  doctest PowerModel.Reference

  describe "stats/0" do
    test "the shipped artifact parses and carries its sources" do
      stats = Reference.stats()
      assert is_map(stats), "priv/reference/structural_stats.json missing or unparseable"
      assert stats["schema_version"] == 1
      assert is_list(stats["sources"]) and stats["sources"] != []

      for source <- stats["sources"] do
        assert source["case"]
        assert source["buses"] > 0
        assert is_list(source["voltage_levels_kv"])
      end
    end

    test "cases/0 names every source" do
      assert "case_ACTIVSg2000" in Reference.cases()
      assert length(Reference.cases()) == length(Reference.stats()["sources"])
    end
  end

  describe "poi_floor_kv/1" do
    test "rises with plant size and never falls" do
      sizes = [30, 100, 250, 500, 1000, 2000]
      floors = Enum.map(sizes, &Reference.poi_floor_kv/1)

      refute Enum.any?(floors, &is_nil/1)
      assert floors == Enum.sort(floors), "floor must be monotonic in plant size: #{inspect(floors)}"
    end

    test "a plant smaller than the first band has no opinion" do
      assert Reference.poi_floor_kv(1) == nil
    end

    test "is the minimum observed, not the median" do
      # ACTIVSg2000 interconnects the MEDIAN 200-400 MW plant at 500 kV. If the
      # floor ever tracked the median it would flag most of a real network, so
      # this pins it to the permissive end.
      band = Reference.metric("poi_kv_by_plant_mw_band", "case_ACTIVSg2000")["200-400"]
      assert band["p50"] > band["min"]
      assert Reference.poi_floor_kv(300) <= band["min"]
    end

    test "a 525 MW plant escaping at 69 kV is below the floor" do
      # The measured ERCOT case (bus 58121): a 345 kV switchyard with no
      # 345 kV lines, exporting through a transformer to 69 kV.
      assert Reference.poi_floor_kv(525) > 69.0
    end
  end

  describe "metric/2" do
    test "reference places load in a narrow band and none on EHV" do
      shares = Reference.metric("load_mw_share_by_bus_kv", "case_ACTIVSg2000")
      levels = shares |> Map.keys() |> Enum.map(&String.to_float/1)

      assert Enum.min(levels) >= 115.0,
             "reference model places load below 115 kV, which invalidates the band observation"

      assert Enum.max(levels) < 230.0,
             "reference model places load on EHV, which invalidates the band observation"
    end

    test "unknown names and cases return nil rather than raising" do
      assert Reference.metric("no_such_metric", "case_ACTIVSg2000") == nil
      assert Reference.metric("load_mw_share_by_bus_kv", "no_such_case") == nil
    end
  end
end
