defmodule PowerModel.Ingestion.OSM.MatcherTest do
  use ExUnit.Case, async: true

  alias PowerModel.Ingestion.OSM.Matcher

  # 0.001 deg latitude is ~111 m.
  @lat 40.0
  @lon -83.0

  defp yard(id, name, opts \\ []) do
    %{
      id: id,
      name: name,
      hifld_id: "#{id}",
      levels: Keyword.get(opts, :levels, []),
      class: Keyword.get(opts, :class, :blind),
      lat: Keyword.get(opts, :lat, @lat),
      lon: Keyword.get(opts, :lon, @lon)
    }
  end

  defp osm_sub(id, opts) do
    %{
      type: Keyword.get(opts, :type, "way"),
      id: id,
      name: Keyword.get(opts, :name),
      raw_voltage: Keyword.get(opts, :raw_voltage, "69000"),
      lat: Keyword.get(opts, :lat, @lat),
      lon: Keyword.get(opts, :lon, @lon),
      levels_kv: Keyword.get(opts, :levels_kv, [69.0])
    }
  end

  defp run(yards, subs, evidence \\ %{}) do
    %{decisions: decisions} =
      Matcher.match_with(%{eligible: yards, real_line_levels: evidence}, subs)

    decisions
  end

  test "a lone candidate within 250 m matches on distance alone, even for UNKNOWN keys" do
    [decision] = run([yard(1, "UNKNOWN123456")], [osm_sub(10, lat: @lat + 0.001)])

    assert {:applied, %{id: 1}, %{id: 10}, "distance", nil, dist, nil} = decision
    assert_in_delta dist, 111.0, 5.0
  end

  test "beyond 250 m is unmatched" do
    assert [{:unmatched, %{id: 1}}] =
             run([yard(1, "UNKNOWN123456")], [osm_sub(10, lat: @lat + 0.003)])
  end

  test "two candidates with the SAME levels are not ambiguous" do
    subs = [
      osm_sub(10, lat: @lat + 0.0005, levels_kv: [69.0]),
      osm_sub(11, lat: @lat - 0.001, levels_kv: [69.0])
    ]

    assert [{:applied, _, %{id: 10}, "distance", _, _, _}] = run([yard(1, "TAP99")], subs)
  end

  test "two candidates with DIFFERING levels and no name signal are held" do
    subs = [
      osm_sub(10, lat: @lat + 0.0005, levels_kv: [69.0]),
      osm_sub(11, lat: @lat - 0.001, levels_kv: [138.0])
    ]

    assert [{:held, _, _, _, _, _, "ambiguous:" <> _}] = run([yard(1, "TAP99")], subs)
  end

  test "a clear name win resolves differing-level ambiguity" do
    subs = [
      osm_sub(10, lat: @lat + 0.0005, levels_kv: [69.0], name: "Sammis Substation"),
      osm_sub(11, lat: @lat - 0.001, levels_kv: [138.0], name: "Elm Road Substation")
    ]

    assert [{:applied, _, %{id: 10}, "distance+name", sim, _, _}] =
             run([yard(1, "FIRSTENERGY W H SAMMIS")], subs)

    assert sim == 1.0
  end

  test "adjacent distinct yards are vetoed by name (Ross vs CLUTCH SWITCH, 3 m apart)" do
    subs = [osm_sub(10, lat: @lat + 0.00003, name: "Ross Substation", levels_kv: [765.0])]

    assert [{:held, _, _, _, _, _, "name_mismatch:" <> _}] = run([yard(1, "CLUTCH SWITCH")], subs)
  end

  test "incident real-line voltage outside 5% of every OSM level holds the match" do
    evidence = %{1 => [345.0]}

    assert [{:held, _, _, _, _, _, "line_voltage_conflict:" <> _}] =
             run([yard(1, "UNKNOWN123456")], [osm_sub(10, levels_kv: [69.0])], evidence)
  end

  test "incident real-line voltage within 5% of an OSM level passes" do
    evidence = %{1 => [345.0]}

    assert [{:applied, _, _, _, _, _, _}] =
             run(
               [yard(1, "UNKNOWN123456")],
               [osm_sub(10, levels_kv: [345.0, 69.0], raw_voltage: "345000;69000")],
               evidence
             )
  end
end
