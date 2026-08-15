defmodule PowerModel.Ingestion.LineLoadabilityTest do
  @moduledoc """
  ROADMAP item 10: EHV ratings are capped by St. Clair loadability, EHV
  resistance is physical, and the ambient derate lives on the rating rather
  than on a resistance the DC solver never reads.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Ingestion.ParameterEstimator, as: PE

  # The published curve is drawn against miles.
  @km_per_mile 1.609344
  defp mi(miles), do: miles * @km_per_mile

  describe "st_clair_loadability/1 at the published breakpoints" do
    test "matches Dunlop/Gutman/Marchenko Fig. 4 at every breakpoint" do
      for {miles, expected} <- [
            {50, 3.00},
            {100, 2.00},
            {150, 1.60},
            {200, 1.35},
            {250, 1.20},
            {300, 1.05},
            {350, 0.95},
            {400, 0.85},
            {500, 0.72},
            {600, 0.62}
          ] do
        assert_in_delta PE.st_clair_loadability(mi(miles)),
                        expected,
                        1.0e-9,
                        "breakpoint at #{miles} mi"
      end
    end

    test "interpolates linearly between breakpoints" do
      # Halfway between 100 mi (2.00) and 150 mi (1.60).
      assert_in_delta PE.st_clair_loadability(mi(125)), 1.80, 1.0e-9
    end

    test "clamps below the first and above the last breakpoint" do
      # Short lines are thermally limited; the clamp keeps the stability cap
      # generous so `min/2` against the thermal ceiling is what binds.
      assert PE.st_clair_loadability(mi(10)) == 3.00
      assert PE.st_clair_loadability(0.0) == 3.00

      assert PE.st_clair_loadability(mi(900)) == 0.62
    end

    test "decreases monotonically with length" do
      values = Enum.map([10, 60, 120, 220, 380, 550, 800], &PE.st_clair_loadability(mi(&1)))

      assert values == Enum.sort(values, :desc)
    end
  end

  describe "sil_mw/1" do
    test "returns the standard SIL for each EHV class" do
      assert PE.sil_mw(345.0) == 420.0
      assert PE.sil_mw(500.0) == 1000.0
      assert PE.sil_mw(765.0) == 2280.0
    end

    test "is nil at and below 300 kV, where the length cap is not applied" do
      # MEASURED: making sub-300 kV ratings length-aware makes the overload
      # census worse, so those classes stay flat.
      assert PE.sil_mw(230.0) == nil
      assert PE.sil_mw(138.0) == nil
      assert PE.sil_mw(300.0) == nil
    end
  end

  describe "rating_a_mva/3 discriminates short from long EHV lines" do
    test "a short 500 kV line is thermally bound" do
      # 50 km: 3 x SIL = 3,000 MW of stability headroom, well above the
      # conductors' 1,800 MVA ceiling, so the thermal limit is what binds.
      short = PE.rating_a_mva(500.0, 50.0, 35.0)

      assert_in_delta short, 1800.0 * PE.ambient_rating_derate(35.0), 1.0e-6
    end

    test "a long 500 kV line is stability bound, and rated well below thermal" do
      # 500 km ~ 311 mi: about 1.03 x SIL, i.e. ~1,030 MW against an 1,800 MVA
      # thermal ceiling.
      long = PE.rating_a_mva(500.0, 500.0, 35.0)

      assert long < 1800.0 * PE.ambient_rating_derate(35.0)
      assert_in_delta long, 1000.0 * PE.st_clair_loadability(500.0), 1.0e-6
      assert_in_delta long, 1030.0, 15.0
    end

    test "the long line is rated below the short one at the same voltage" do
      assert PE.rating_a_mva(500.0, 500.0) < PE.rating_a_mva(500.0, 50.0)
    end

    test "sub-300 kV ratings are flat: length changes nothing" do
      short = PE.rating_a_mva(230.0, 20.0)
      long = PE.rating_a_mva(230.0, 400.0)

      assert short == long
      assert_in_delta short, 450.0 * PE.ambient_rating_derate(35.0), 1.0e-6
    end
  end

  describe "ambient_rating_derate/1 — the derate now lives on the rating" do
    test "is 1.0 at the 25 C reference the class table is quoted at" do
      assert_in_delta PE.ambient_rating_derate(25.0), 1.0, 1.0e-12
    end

    test "derates about 10.6% at the 35 C summer default" do
      # sqrt((75-35)/(75-25)) = sqrt(0.8)
      assert_in_delta PE.ambient_rating_derate(35.0), :math.sqrt(0.8), 1.0e-12
      assert_in_delta PE.ambient_rating_derate(35.0), 0.8944, 1.0e-4
    end

    test "a cooler ambient rates the line up, a hotter one down" do
      assert PE.ambient_rating_derate(10.0) > 1.0
      assert PE.ambient_rating_derate(45.0) < PE.ambient_rating_derate(35.0)
    end

    test "clamps rather than returning nonsense for absurd temperatures" do
      assert PE.ambient_rating_derate(200.0) == 0.25
      assert PE.ambient_rating_derate(-100.0) == 1.25
    end

    test "flows through to the rating a relay compares against" do
      hot = PE.rating_a_mva(230.0, 100.0, 40.0)
      mild = PE.rating_a_mva(230.0, 100.0, 20.0)

      assert hot < mild
    end
  end

  describe "EHV resistance is physical" do
    test "X/R sits in the 12-20 band real overhead EHV lines achieve" do
      for kv <- [345.0, 500.0, 765.0] do
        {r, x, _b, _rating, _circuits} = PE.lookup_line_params(kv)
        x_over_r = x / r

        assert x_over_r >= 12.0 and x_over_r <= 20.0,
               "#{trunc(kv)} kV X/R is #{Float.round(x_over_r, 1)}, outside 12-20"
      end
    end

    test "resistance rises with voltage class only as the bundle count grows" do
      {r_345, _, _, _, _} = PE.lookup_line_params(345.0)
      {r_500, _, _, _, _} = PE.lookup_line_params(500.0)
      {r_765, _, _, _, _} = PE.lookup_line_params(765.0)

      assert r_345 > r_500 and r_500 > r_765
    end
  end

  describe "line_params/2 composes the whole recipe" do
    test "writes all three rating tiers and stamps the version" do
      params = PE.line_params(%{voltage_kv: 500.0, length_km: 50.0}, 35.0)

      assert params.params_version == PE.params_version()
      assert_in_delta params.rating_b_mva / params.rating_a_mva, 1.15, 1.0e-9
      assert_in_delta params.rating_c_mva / params.rating_a_mva, 1.35, 1.0e-9
    end

    test "a long EHV line gets the loadability-capped rating, not the class rating" do
      long = PE.line_params(%{voltage_kv: 500.0, length_km: 500.0}, 35.0)

      assert long.rating_a_mva < 1800.0
      assert_in_delta long.rating_a_mva, PE.rating_a_mva(500.0, 500.0, 35.0), 1.0e-9
    end

    test "impedance still scales with length" do
      short = PE.line_params(%{voltage_kv: 500.0, length_km: 50.0})
      long = PE.line_params(%{voltage_kv: 500.0, length_km: 500.0})

      assert_in_delta long.x_pu / short.x_pu, 10.0, 1.0e-6
    end
  end
end
