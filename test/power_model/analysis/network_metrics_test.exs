defmodule PowerModel.Analysis.NetworkMetricsTest do
  @moduledoc """
  The scoreboard is only useful if its numbers are trustworthy, so these
  tests pin the definitions themselves: what counts as a simulated bus, what
  counts as an island, which branches enter the loading distribution, and
  what a kV "weld" is. Every case is a hand-built in-memory network whose
  answers can be worked out on paper.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Grid.Accuracy
  alias PowerModel.Analysis.NetworkMetrics

  # ---------------------------------------------------------------------------
  # Fixture builders — same map shapes the cascade and solver tests use
  # ---------------------------------------------------------------------------

  defp bus(id, opts \\ []) do
    %{
      id: id,
      bus_type: Keyword.get(opts, :bus_type, 1),
      base_kv: Keyword.get(opts, :base_kv, 138.0),
      vm_pu: 1.0,
      va_rad: 0.0
    }
  end

  defp line(id, from, to, opts \\ []) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      voltage_kv: Keyword.get(opts, :voltage_kv, 138.0),
      r_pu: Keyword.get(opts, :r_pu, 0.01),
      x_pu: Keyword.get(opts, :x_pu, 0.1),
      b_pu: 0.02,
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 100.0)
    }
  end

  defp transformer(id, from, to, opts \\ []) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      r_pu: 0.005,
      x_pu: Keyword.get(opts, :x_pu, 0.05),
      rated_mva: Keyword.get(opts, :rated_mva, 200.0),
      tap_ratio: 1.0
    }
  end

  defp generator(id, bus_id, p_max) do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: p_max,
      capacity_factor: 1.0,
      q_max_mvar: 50.0,
      q_min_mvar: -50.0
    }
  end

  defp load(id, bus_id, p_mw), do: %{id: id, bus_id: bus_id, p_mw: p_mw, q_mvar: 0.0}

  defp snapshot(buses, lines, transformers, generators, loads) do
    %{
      buses: buses,
      lines: lines,
      transformers: transformers,
      generators: generators,
      loads: loads
    }
  end

  defp population(snapshot) do
    %{
      buses: Enum.map(snapshot.buses, &Map.take(&1, [:id, :base_kv])),
      lines: snapshot.lines,
      transformers: snapshot.transformers
    }
  end

  # A 3-bus radial line at 345 kV. Bus 1 generates, buses 2 and 3 consume, so
  # line 1 carries everything (300 MW over a 100 MVA rating = 300% loading)
  # while line 2 carries only bus 3's share (150%).
  defp overloaded_snapshot do
    snapshot(
      [bus(1, bus_type: 3, base_kv: 345.0), bus(2, base_kv: 345.0), bus(3, base_kv: 345.0)],
      [
        line(1, 1, 2, voltage_kv: 345.0, rating_a_mva: 100.0),
        line(2, 2, 3, voltage_kv: 345.0, rating_a_mva: 100.0)
      ],
      [],
      [generator(1, 1, 300.0)],
      [load(1, 2, 150.0), load(2, 3, 150.0)]
    )
  end

  describe "topology metrics" do
    test "coverage is simulated over geolocated, island count includes lone buses" do
      # Geolocated: a 3-bus chain, a separate 2-bus pair, and one bus with no
      # branch at all. Only the chain is simulated.
      geo = %{
        buses: Enum.map([1, 2, 3, 4, 5, 6], &%{id: &1, base_kv: 138.0}),
        lines: [line(1, 1, 2), line(2, 2, 3), line(3, 4, 5)],
        transformers: []
      }

      sim = snapshot([bus(1), bus(2), bus(3)], [line(1, 1, 2), line(2, 2, 3)], [], [], [])

      t = NetworkMetrics.measure("test", geo, sim, max_solve_buses: 1).topology

      assert t.geolocated_buses == 6
      assert t.simulated_buses == 3
      assert t.simulated_bus_share == 0.5
      assert t.geolocated_branches == 3
      assert t.simulated_branches == 2

      # Three components: the chain, the pair, and bus 6 alone.
      assert t.island_count == 3
      # The simulated snapshot is only the chain, so it is one island.
      assert t.simulated_island_count == 1
      assert t.largest_component_buses == 3
      assert t.largest_component_share == 0.5
      assert t.isolated_buses == 1
      assert t.connected_bus_share == 5 / 6
    end

    test "transformers count as branches for connectivity" do
      geo = %{
        buses: Enum.map([1, 2], &%{id: &1, base_kv: 138.0}),
        lines: [],
        transformers: [transformer(1, 1, 2)]
      }

      t = NetworkMetrics.measure("test", geo, geo, max_solve_buses: 1).topology

      assert t.island_count == 1
      assert t.isolated_buses == 0
      assert t.geolocated_transformers == 1
    end
  end

  describe "base case" do
    test "counts the branches a cascade would refuse to trip" do
      sim = overloaded_snapshot()
      b = NetworkMetrics.measure("test", population(sim), sim).base_case

      assert b.status == "ok"
      assert b.branches == 2
      assert b.branches_solved == 2
      assert b.branches_rated == 2

      # Both lines sit over their rating at rest, so both are trip-immune.
      assert b.base_overloaded == 2
      assert b.overload_rate == 1.0
      assert_in_delta b.median_loading_pct, 225.0, 0.5
      assert_in_delta b.load_mw, 300.0, 0.001

      # With no hour, the cascade falls back to capacity pro-rata; the
      # scoreboard records which rule produced the operating point, because an
      # overload rate means something different under each.
      assert b.dispatch_source == "proportional"
      assert b.dispatch_coverage == nil

      # `Cascade.init/3` closes the base operating point's own gap before
      # anything is an event (ROADMAP item 16), so the commitment the base
      # case is measured at covers its load exactly. The ratio still reports
      # a fuel-anchored dispatch that OVER-generates, which is the case where
      # a BA's measured MW encode a real export.
      assert_in_delta b.dispatch_to_load, 1.0, 0.001
    end

    test "an unrated branch is excluded from the loading distribution" do
      # DCPowerFlow reports 0.0% loading for a branch with no rating; counting
      # it would drag the median down and understate the overload rate.
      sim = overloaded_snapshot()
      unrated = %{line(3, 1, 3, voltage_kv: 345.0) | rating_a_mva: nil}
      sim = %{sim | lines: sim.lines ++ [unrated]}

      b = NetworkMetrics.measure("test", population(sim), sim).base_case

      assert b.branches == 3
      assert b.branches_solved == 3
      assert b.branches_rated == 2
    end

    test "breaks loading out by voltage class using the branch's own kV" do
      sim = overloaded_snapshot()
      b = NetworkMetrics.measure("test", population(sim), sim).base_case

      assert Map.keys(b.by_voltage_class) == ["345kV"]
      stats = b.by_voltage_class["345kV"]
      assert stats.branches_rated == 2
      assert stats.overloaded == 2
      assert stats.overload_rate == 1.0

      # Lines are broken out separately: a transformer is classified by its
      # high side, so pooling it changes what "the 345 kV backbone" means.
      assert stats.lines.branches_rated == 2
      assert stats.transformers.branches_rated == 0
      assert stats.transformers.overload_rate == nil
    end

    test "a class keeps lines and transformers apart" do
      # 500 kV line overloaded, 500/138 transformer comfortable. Pooled the
      # class reads 50% overloaded; the lines-only view reads 100%.
      sim =
        snapshot(
          [bus(1, bus_type: 3, base_kv: 500.0), bus(2, base_kv: 500.0), bus(3, base_kv: 138.0)],
          [line(1, 1, 2, voltage_kv: 500.0, rating_a_mva: 50.0)],
          [transformer(1, 2, 3, rated_mva: 5000.0)],
          [generator(1, 1, 200.0)],
          [load(1, 3, 200.0)]
        )

      stats = NetworkMetrics.measure("test", population(sim), sim).base_case.by_voltage_class

      assert %{"500kV" => class} = stats
      assert class.branches_rated == 2
      assert class.overload_rate == 0.5
      assert class.lines.overload_rate == 1.0
      assert class.transformers.overload_rate == 0.0
    end

    test "a transformer is classified by its high side" do
      sim =
        snapshot(
          [bus(1, bus_type: 3, base_kv: 500.0), bus(2, base_kv: 138.0)],
          [],
          [transformer(1, 1, 2, rated_mva: 100.0)],
          [generator(1, 1, 60.0)],
          [load(1, 2, 60.0)]
        )

      b = NetworkMetrics.measure("test", population(sim), sim).base_case
      assert Map.keys(b.by_voltage_class) == ["500kV"]
    end

    test "skips rather than attempts a solve above the bus cap" do
      sim = overloaded_snapshot()
      b = NetworkMetrics.measure("test", population(sim), sim, max_solve_buses: 2).base_case

      assert b.status == "skipped"
      assert b.reason =~ "3 buses"
      assert b.base_overloaded == 0
    end

    test "an empty snapshot is skipped, not crashed" do
      b = NetworkMetrics.measure("test", %{}, %{}).base_case

      assert b.status == "skipped"
      assert b.reason == "empty snapshot"
    end
  end

  describe "kV census" do
    test "counts endpoint disagreement, welds, and line-vs-bus mismatch" do
      buses = [
        bus(1, base_kv: 345.0),
        bus(2, base_kv: 345.0),
        bus(3, base_kv: 138.0),
        bus(4, base_kv: 13.8)
      ]

      lines = [
        # matched endpoints, line kV agrees
        line(1, 1, 2, voltage_kv: 345.0),
        # 345 vs 138: mismatch, ratio 2.5, not a weld
        line(2, 2, 3, voltage_kv: 345.0),
        # 345 vs 13.8: mismatch AND a 25:1 weld
        line(3, 1, 4, voltage_kv: 345.0)
      ]

      c = NetworkMetrics.kv_census(lines, buses)

      assert c.lines == 3
      assert c.comparable == 3
      assert c.mismatch_10pct == 2
      assert c.weld_5to1 == 1
      assert_in_delta c.worst_ratio, 25.0, 0.001
      assert_in_delta c.mismatch_rate, 2 / 3, 0.001

      # Lines 2 and 3 each land one end on a bus far from their own voltage.
      assert c.line_vs_bus_mismatch == 2
    end

    test "a branch with an unknown endpoint voltage is not comparable" do
      buses = [bus(1, base_kv: 345.0), %{id: 2, base_kv: nil}]
      c = NetworkMetrics.kv_census([line(1, 1, 2, voltage_kv: 345.0)], buses)

      assert c.lines == 1
      assert c.comparable == 0
      assert c.mismatch_rate == nil
      assert c.worst_ratio == nil
    end
  end

  describe "voltage_class/1 and percentile/2" do
    test "classes are half-open bands, high bound exclusive" do
      assert NetworkMetrics.voltage_class(765.0) == "765kV+"
      assert NetworkMetrics.voltage_class(600.0) == "765kV+"
      assert NetworkMetrics.voltage_class(500.0) == "500kV"
      assert NetworkMetrics.voltage_class(400.0) == "500kV"
      assert NetworkMetrics.voltage_class(345.0) == "345kV"
      assert NetworkMetrics.voltage_class(230.0) == "230kV"
      assert NetworkMetrics.voltage_class(138.0) == "100-199kV"
      assert NetworkMetrics.voltage_class(69.0) == "<100kV"
      assert NetworkMetrics.voltage_class(nil) == "unknown"
      assert NetworkMetrics.voltage_class(0.0) == "unknown"
    end

    test "percentiles interpolate and survive degenerate input" do
      assert NetworkMetrics.percentile([], 0.5) == nil
      assert NetworkMetrics.percentile([7.0], 0.95) == 7.0
      assert NetworkMetrics.percentile([1.0, 2.0, 3.0, 4.0], 0.5) == 2.5
      assert NetworkMetrics.percentile([1.0, 2.0, 3.0], 0.5) == 2.0
      assert_in_delta NetworkMetrics.percentile(Enum.map(1..100, &(&1 * 1.0)), 0.95), 95.05, 0.01
    end
  end

  describe "A/B overrides" do
    test "doubling EHV ratings clears the overloads and leaves the original alone" do
      base_snapshot = overloaded_snapshot()

      variant_snapshot =
        NetworkMetrics.apply_overrides(base_snapshot, scale_rating_above_kv: {300.0, 4.0})

      # Purity: the caller's snapshot is untouched, and nothing was persisted.
      assert Enum.map(base_snapshot.lines, & &1.rating_a_mva) == [100.0, 100.0]
      assert Enum.map(variant_snapshot.lines, & &1.rating_a_mva) == [400.0, 400.0]

      base = NetworkMetrics.measure("test", population(base_snapshot), base_snapshot)

      variant =
        NetworkMetrics.measure("test", population(variant_snapshot), variant_snapshot)

      assert base.base_case.base_overloaded == 2
      assert variant.base_case.base_overloaded == 0

      diff = NetworkMetrics.diff(base, variant)

      assert %{base: 2, variant: 0, delta: -2} = diff["base_case.base_overloaded"]
      assert %{delta: -1.0} = diff["base_case.overload_rate"]

      # Topology cannot move when only ratings change.
      refute Map.has_key?(diff, "topology.simulated_buses")
    end

    test "a kV threshold only touches branches at or above it" do
      sim =
        snapshot(
          [bus(1, base_kv: 345.0), bus(2, base_kv: 345.0), bus(3, base_kv: 138.0)],
          [
            line(1, 1, 2, voltage_kv: 345.0, rating_a_mva: 100.0),
            line(2, 2, 3, voltage_kv: 138.0, rating_a_mva: 100.0)
          ],
          [transformer(1, 2, 3, rated_mva: 200.0)],
          [],
          []
        )

      variant = NetworkMetrics.apply_overrides(sim, scale_rating_above_kv: {300.0, 2.0})

      assert Enum.map(variant.lines, & &1.rating_a_mva) == [200.0, 100.0]
      # The transformer's high side is 345 kV, so it scales too.
      assert Enum.map(variant.transformers, & &1.rated_mva) == [400.0]
    end

    test "load, generation, reactance and rating floors all apply" do
      sim = overloaded_snapshot()

      variant =
        NetworkMetrics.apply_overrides(sim,
          scale_load: 2.0,
          scale_generation: 0.5,
          scale_reactance: 3.0,
          min_rating_mva: 500.0
        )

      assert Enum.map(variant.loads, & &1.p_mw) == [300.0, 300.0]
      assert Enum.map(variant.generators, & &1.p_max_mw) == [150.0]
      assert Enum.map(variant.lines, & &1.rating_a_mva) == [500.0, 500.0]
      for l <- variant.lines, do: assert_in_delta(l.x_pu, 0.3, 1.0e-9)
    end

    test "an unknown override is rejected loudly" do
      assert_raise ArgumentError, ~r/unknown network-metrics override/, fn ->
        NetworkMetrics.apply_overrides(overloaded_snapshot(), nonsense: 1.0)
      end
    end

    test "diff omits what did not move" do
      m = NetworkMetrics.measure("test", %{}, overloaded_snapshot())
      assert NetworkMetrics.diff(m, m) == %{}
    end
  end

  describe "aggregation" do
    test "counts sum and percentiles are recomputed over pooled samples" do
      a = NetworkMetrics.measure("a", %{}, overloaded_snapshot())

      quiet =
        snapshot(
          [bus(1, bus_type: 3, base_kv: 345.0), bus(2, base_kv: 345.0)],
          [line(1, 1, 2, voltage_kv: 345.0, rating_a_mva: 1000.0)],
          [],
          [generator(1, 1, 100.0)],
          [load(1, 2, 100.0)]
        )

      b = NetworkMetrics.measure("b", %{}, quiet)
      total = NetworkMetrics.aggregate("TOTAL", [a, b])

      assert total.scope == "TOTAL"
      assert total.base_case.branches == 3
      assert total.base_case.branches_rated == 3
      assert total.base_case.base_overloaded == 2
      assert_in_delta total.base_case.overload_rate, 2 / 3, 0.001

      # Pooled loadings are {10%, 150%, 300%}: the median is the middle
      # sample, not the mean of the two scope medians.
      assert_in_delta total.base_case.median_loading_pct, 150.0, 0.5
      assert_in_delta total.base_case.load_mw, 400.0, 0.001
    end

    test "a skipped scope contributes topology but not loadings" do
      sim = overloaded_snapshot()
      solved = NetworkMetrics.measure("a", population(sim), sim)
      skipped = NetworkMetrics.measure("b", population(sim), sim, max_solve_buses: 1)

      total = NetworkMetrics.aggregate("TOTAL", [solved, skipped])

      assert total.base_case.reason == "1/2 scopes solved"
      assert total.base_case.branches == 4
      assert total.base_case.branches_rated == 2
      assert total.topology.geolocated_buses == 6
    end

    test "aggregating nothing yields zeros rather than crashing" do
      total = NetworkMetrics.aggregate("TOTAL", [])

      assert total.topology.geolocated_buses == 0
      assert total.topology.simulated_bus_share == nil
      assert total.base_case.status == "skipped"
      assert total.kv_census.geolocated.lines == 0
    end
  end

  describe "JSON output" do
    setup do
      sim = overloaded_snapshot()
      base = NetworkMetrics.measure("ERCOT", population(sim), sim)

      report = %{
        schema_version: NetworkMetrics.schema_version(),
        hour: nil,
        base_mva: 100.0,
        overrides: [],
        scopes: [base]
      }

      %{report: report, snapshot: sim}
    end

    test "keys are stable across identical runs", %{report: report} do
      assert Accuracy.encode_json(report) == Accuracy.encode_json(report)
    end

    test "floats are rounded so a non-reproducible solve does not churn the diff" do
      report = %{
        schema_version: 1,
        hour: nil,
        base_mva: 100.0,
        overrides: [],
        scopes: [%{scope: "x", metric: 17.784877394562105}]
      }

      decoded = Jason.decode!(Accuracy.encode_json(report))
      assert [%{"metric" => 17.784877}] = decoded["scopes"]
    end

    test "carries every metric family and no internal sample lists", %{report: report} do
      decoded = Jason.decode!(Accuracy.encode_json(report))

      assert decoded["schema_version"] == NetworkMetrics.schema_version()
      assert [scope] = decoded["scopes"]
      assert scope["scope"] == "ERCOT"

      assert scope["topology"]["simulated_buses"] == 3
      assert scope["base_case"]["base_overloaded"] == 2
      assert scope["base_case"]["by_voltage_class"]["345kV"]["overloaded"] == 2
      assert scope["kv_census"]["simulated"]["lines"] == 2

      refute Map.has_key?(scope["base_case"], "loading_samples")
    end

    test "a diff survives the round trip with its dotted paths intact", %{snapshot: sim} do
      base = NetworkMetrics.measure("ERCOT", population(sim), sim)

      variant_snapshot = NetworkMetrics.apply_overrides(sim, scale_rating: 10.0)
      variant = NetworkMetrics.measure("ERCOT", population(variant_snapshot), variant_snapshot)

      report = %{
        schema_version: NetworkMetrics.schema_version(),
        hour: nil,
        base_mva: 100.0,
        overrides: NetworkMetrics.describe_overrides(scale_rating: 10.0),
        scopes: [Map.merge(base, %{variant: variant, diff: NetworkMetrics.diff(base, variant)})]
      }

      decoded = Jason.decode!(Accuracy.encode_json(report))
      [scope] = decoded["scopes"]

      assert decoded["overrides"] == ["scale_rating=10.0"]

      assert scope["diff"]["base_case.base_overloaded"] == %{
               "base" => 2,
               "variant" => 0,
               "delta" => -2
             }

      assert scope["variant"]["base_case"]["base_overloaded"] == 0
    end
  end

  describe "live database" do
    @tag :db
    test "report/1 returns a well-formed scoreboard for whatever the DB holds" do
      # The rest of this file is pure, so the sandbox is checked out here
      # rather than pulling every test into DataCase.
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(PowerModel.Repo)

      # Shape only — the dev database is a moving target. The bus cap keeps
      # this a metadata query rather than a full solve.
      report = NetworkMetrics.report(max_solve_buses: 1)

      assert report.schema_version == NetworkMetrics.schema_version()
      assert is_list(report.scopes)

      for scope <- report.scopes do
        assert is_binary(scope.scope)

        assert is_integer(scope.topology.geolocated_buses)
        assert is_integer(scope.topology.simulated_buses)
        assert is_integer(scope.topology.island_count)
        assert scope.topology.simulated_buses <= scope.topology.geolocated_buses

        assert is_nil(scope.topology.simulated_bus_share) or
                 is_float(scope.topology.simulated_bus_share)

        assert scope.base_case.status in ~w(ok skipped failed)
        assert is_integer(scope.base_case.branches)

        for key <- [:geolocated, :simulated] do
          census = scope.kv_census[key]
          assert is_integer(census.lines)
          assert census.comparable <= census.lines
          assert census.weld_5to1 <= census.mismatch_10pct
        end
      end

      # And it encodes.
      assert is_binary(Accuracy.encode_json(report))
    end
  end
end
