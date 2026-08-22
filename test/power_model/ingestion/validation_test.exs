defmodule PowerModel.Ingestion.ValidationTest do
  use PowerModel.DataCase, async: false

  @moduletag :db
  # Every gate logs its warnings; keep them out of the suite output unless a
  # test fails. The tests that assert on the logging capture it explicitly.
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias PowerModel.Demand.{BADemandHour, BAFuelHour}

  alias PowerModel.Grid.{
    BalancingAuthority,
    Bus,
    Generator,
    Interconnection,
    Load,
    TransmissionLine
  }

  alias PowerModel.Ingestion.Validation

  setup do
    tmp = Path.join(System.tmp_dir!(), "validation_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp, baseline: Path.join(tmp, "topology_baseline.json")}
  end

  # --- fixtures --------------------------------------------------------------

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  # June-September is EIA's summer capability season, everything else winter.
  @summer_hour ~U[2024-07-15 18:00:00Z]
  @winter_hour ~U[2024-01-15 18:00:00Z]

  defp insert_ba(code), do: Repo.insert!(%BalancingAuthority{code: code, name: code})

  defp insert_generator(bus, fuel_type, p_max_mw, opts \\ []) do
    Repo.insert!(%Generator{
      bus_id: bus.id,
      fuel_type: fuel_type,
      prime_mover: "ST",
      p_max_mw: p_max_mw,
      p_min_mw: 0.0,
      summer_capacity_mw: opts[:summer_capacity_mw],
      winter_capacity_mw: opts[:winter_capacity_mw],
      capacity_factor: 0.5,
      status: Keyword.get(opts, :status, "in_service")
    })
  end

  # A BA with enough of one fuel to produce whatever the fixture measures, so
  # a balance test is not also a capacity test.
  defp insert_fleet(ba, fuel_type, p_max_mw) do
    insert_generator(insert_bus(nil, ba: ba), fuel_type, p_max_mw)
  end

  defp insert_fuel(code, hour, fuel, mw) do
    Repo.insert!(%BAFuelHour{
      ba_code: code,
      timestamp_utc: hour,
      fuel: fuel,
      net_generation_mw: mw
    })
  end

  defp insert_demand(ba, hour, opts) do
    Repo.insert!(%BADemandHour{
      balancing_authority_id: ba.id,
      timestamp_utc: hour,
      demand_mw: Keyword.fetch!(opts, :demand),
      net_generation_mw: opts[:net_generation],
      total_interchange_mw: opts[:interchange]
    })
  end

  defp insert_bus(ic, opts \\ []) do
    Repo.insert!(%Bus{
      bus_type: 1,
      base_kv: 345.0,
      coordinates: Keyword.get(opts, :coordinates, point(-96.0, 32.0)),
      interconnection_id: ic && ic.id,
      balancing_authority_id: opts[:ba] && opts[:ba].id,
      source: "substation",
      source_id: "bus-#{System.unique_integer([:positive])}"
    })
  end

  defp insert_line(from, to, opts \\ []) do
    Repo.insert!(%TransmissionLine{
      voltage_kv: 345.0,
      x_pu: 0.01,
      status: Keyword.get(opts, :status, "in_service"),
      line_type: opts[:line_type],
      rating_a_mva: opts[:rating_a_mva],
      from_bus_id: from && from.id,
      to_bus_id: to && to.id,
      source: "hifld",
      source_id: "line-#{System.unique_integer([:positive])}"
    })
  end

  # Hours are written as a plateau of `modal` BAs with explicit exceptions,
  # mirroring the shape of a real EIA-930 bulk file: full hours in the middle,
  # partial hours where the file starts and ends.
  defp seed_hours(hour_counts) do
    bas = for i <- 1..53, do: insert_ba("BA#{i}")
    base = ~U[2024-07-01 00:00:00Z]

    for {offset, reporting} <- hour_counts,
        ba <- Enum.take(bas, reporting) do
      Repo.insert!(%BADemandHour{
        balancing_authority_id: ba.id,
        timestamp_utc: DateTime.add(base, offset * 3600, :second),
        demand_mw: 1000.0
      })
    end

    base
  end

  # --- hour completeness -----------------------------------------------------

  describe "hour_completeness/1" do
    test "reports the modal count, incomplete hours, and the latest complete hour" do
      # 6 full hours, one 52-BA hour (inside slack), a 17-BA boundary hour last.
      seed_hours([{0, 53}, {1, 53}, {2, 52}, {3, 53}, {4, 53}, {5, 53}, {6, 17}])

      assert {:ok, report} = Validation.hour_completeness()
      m = report.metrics

      assert m.hours_total == 7
      assert m.modal_reporting_bas == 53
      assert m.complete_threshold == 52
      assert m.complete_hours == 6
      assert m.incomplete_hours == 1
      assert m.latest_complete_hour == ~U[2024-07-01 05:00:00Z]
      assert m.latest_hour == ~U[2024-07-01 06:00:00Z]
      assert m.latest_hour_reporting_bas == 17
      assert m.boundary_incomplete_hours == [%{hour: ~U[2024-07-01 06:00:00Z], reporting_bas: 17}]
      assert m.interior_incomplete_hours == []
    end

    test "warns loudly (ENE-13) when the latest hour is incomplete" do
      seed_hours([{0, 53}, {1, 53}, {2, 17}])

      log =
        capture_log(fn ->
          assert {:ok, report} = Validation.hour_completeness()
          assert report.status == :warn
          assert Enum.any?(report.warnings, &(&1 =~ "ENE-13/DAT-15"))
          assert Enum.any?(report.warnings, &(&1 =~ "17/53 BAs reporting"))
          assert Enum.any?(report.warnings, &(&1 =~ "incomplete boundary hour"))
        end)

      assert log =~ "[validate hour_completeness]"
      assert log =~ "latest ingested hour"
    end

    test "separates incomplete hours inside the window from file-boundary hours" do
      seed_hours([{0, 53}, {1, 20}, {2, 53}])

      assert {:ok, report} = Validation.hour_completeness()

      assert report.metrics.boundary_incomplete_hours == []

      assert report.metrics.interior_incomplete_hours == [
               %{hour: ~U[2024-07-01 01:00:00Z], reporting_bas: 20}
             ]

      assert Enum.any?(report.warnings, &(&1 =~ "INSIDE the ingested window"))
    end

    test "a fully reported window passes with no warnings" do
      seed_hours([{0, 53}, {1, 53}, {2, 53}])

      assert {:ok, report} = Validation.hour_completeness()
      assert report.status == :ok
      assert report.warnings == []
    end

    test "the completeness threshold is configurable" do
      seed_hours([{0, 53}, {1, 50}, {2, 53}])

      assert {:ok, strict} = Validation.hour_completeness()
      assert strict.metrics.incomplete_hours == 1

      assert {:ok, loose} = Validation.hour_completeness(reporting_slack: 5)
      assert loose.metrics.complete_threshold == 48
      assert loose.metrics.incomplete_hours == 0
    end

    test "an empty demand table is a failure, not a warning" do
      assert {:error, report} = Validation.hour_completeness()
      assert report.status == :error
      assert [failure] = report.failures
      assert failure =~ "ba_demand_hourly is empty"
    end
  end

  # --- eGRID vintage ---------------------------------------------------------

  describe "egrid_vintage/1" do
    test "warns when the eGRID vintage trails the EIA-860 fleet", %{tmp: tmp} do
      File.write!(Path.join(tmp, "egrid2022.xlsx"), "")
      File.write!(Path.join(tmp, "3_1_Generator_Y2024.csv"), "")

      log =
        capture_log(fn ->
          assert {:ok, report} = Validation.egrid_vintage(data_dir: tmp)
          assert report.status == :warn
          assert report.metrics.egrid_year == 2022
          assert report.metrics.eia860_year == 2024
          assert report.metrics.vintage_gap_years == 2
          assert [warning] = report.warnings
          assert warning =~ "eGRID vintage mismatch"
        end)

      assert log =~ "eGRID vintage mismatch"
    end

    test "matching vintages pass", %{tmp: tmp} do
      File.write!(Path.join(tmp, "egrid2024.xlsx"), "")
      File.write!(Path.join(tmp, "3_1_Generator_Y2024.csv"), "")

      assert {:ok, report} = Validation.egrid_vintage(data_dir: tmp)
      assert report.status == :ok
      assert report.warnings == []
      assert report.metrics.vintage_gap_years == 0
    end

    test "falls back to the downloaded archive when no CSV has been exported", %{tmp: tmp} do
      File.write!(Path.join(tmp, "egrid2022.xlsx"), "")
      File.write!(Path.join(tmp, "eia860_2024.zip"), "")

      assert {:ok, report} = Validation.egrid_vintage(data_dir: tmp)
      assert report.metrics.eia860_year == 2024
      assert report.metrics.eia860_file =~ "eia860_2024.zip"
    end

    test "missing inputs warn instead of failing", %{tmp: tmp} do
      assert {:ok, report} = Validation.egrid_vintage(data_dir: tmp)
      assert report.status == :warn
      assert [warning] = report.warnings
      assert warning =~ "No egrid*.xlsx"

      File.write!(Path.join(tmp, "egrid2022.xlsx"), "")
      assert {:ok, report} = Validation.egrid_vintage(data_dir: tmp)
      assert [warning] = report.warnings
      assert warning =~ "cannot verify the fleet vintage"
    end
  end

  # --- topology census -------------------------------------------------------

  describe "census_metrics/0" do
    test "counts unmapped endpoints, self-loops, and generators off-bus" do
      ic = Repo.insert!(%Interconnection{name: "Eastern"})
      ba = insert_ba("PJM")
      a = insert_bus(ic, ba: ba)
      b = insert_bus(ic, ba: ba)
      # no BA, no coordinates: the MATPOWER-shaped rows that never simulate
      orphan = insert_bus(ic, coordinates: nil)

      insert_line(a, b)
      insert_line(a, a)
      insert_line(a, nil)
      insert_line(orphan, b, status: "out_of_service")

      Repo.insert!(%Generator{p_max_mw: 100.0, bus_id: a.id})
      Repo.insert!(%Generator{p_max_mw: 50.0})

      m = Validation.census_metrics()

      assert m.bus_count == 3
      assert m.geolocated_bus_count == 2
      assert m.buses_without_ba == 1
      assert m.geolocated_buses_without_ba == 0
      assert m.line_count == 4
      assert m.lines_in_service == 3
      assert m.lines_unmapped_endpoints == 1
      assert m.self_loop_lines == 1
      assert m.generator_count == 2
      assert m.generators_without_bus == 1
    end

    test "connectivity is per interconnection over the simulated branch set" do
      east = Repo.insert!(%Interconnection{name: "Eastern"})
      west = Repo.insert!(%Interconnection{name: "Western"})

      # Eastern: a 3-bus chain, a 2-bus pair, one isolated bus -> 2 components,
      # largest 3 of 6 geolocated buses.
      [e1, e2, e3, e4, e5, _e6] = for _ <- 1..6, do: insert_bus(east)
      insert_line(e1, e2)
      insert_line(e2, e3)
      insert_line(e4, e5)

      # A DC tie and an out-of-service line must not join anything.
      insert_line(e3, e4, line_type: "dc")
      insert_line(e5, e1, status: "out_of_service")

      [w1, w2] = for _ <- 1..2, do: insert_bus(west)
      insert_line(w1, w2)

      %{"Eastern" => eastern, "Western" => western} =
        Validation.census_metrics().interconnections

      assert eastern.geolocated_bus_count == 6
      assert eastern.connected_bus_count == 5
      assert eastern.component_count == 2
      assert eastern.largest_component_bus_count == 3
      assert eastern.largest_component_fraction == 0.5
      assert eastern.connected_fraction == 0.8333

      assert western.largest_component_fraction == 1.0
      assert western.component_count == 1
    end

    # REVIEW DAT-28: the census recorded what the network CONTAINS and nothing
    # about whether it can carry it, so DAT-26 — placement falling back to the
    # pre-DR-4 rule because rating_a_mva was still NULL when map_buses ran —
    # went past the pipeline's final gate clean. These are the three metrics
    # that move when placement degrades.
    test "stranded nameplate counts plants their bus cannot evacuate" do
      ic = Repo.insert!(%Interconnection{name: "Western"})
      strong = insert_bus(ic)
      weak = insert_bus(ic)
      far = insert_bus(ic)

      # 2,000 MVA of branch behind `strong`, 100 MVA behind `weak`.
      insert_line(strong, far, rating_a_mva: 1000.0)
      insert_line(far, strong, rating_a_mva: 1000.0)
      insert_line(weak, far, rating_a_mva: 100.0)

      insert_generator(strong, "NG", 800.0)
      insert_generator(weak, "WAT", 600.0)

      m = Validation.census_metrics()

      # 800 MW against 2,000 MVA clears 1.2x; 600 MW against 100 MVA does not.
      assert m.stranded_nameplate_mw == 600
      assert m.zero_capability_generator_buses == 0
    end

    test "a generator bus with no branch at all is counted separately" do
      ic = Repo.insert!(%Interconnection{name: "Western"})
      orphan = insert_bus(ic)
      insert_generator(orphan, "NG", 250.0)

      m = Validation.census_metrics()

      # A ratio test never divides here, which is why this is its own metric.
      assert m.zero_capability_generator_buses == 1
      assert m.stranded_nameplate_mw == 250
    end

    test "radial load share is reported per interconnection" do
      east = Repo.insert!(%Interconnection{name: "Eastern"})
      [a, b, spur] = for _ <- 1..3, do: insert_bus(east)

      insert_line(a, b)
      insert_line(b, spur)

      Repo.insert!(%Load{bus_id: a.id, p_mw: 300.0, status: "in_service"})
      Repo.insert!(%Load{bus_id: spur.id, p_mw: 100.0, status: "in_service"})

      %{"Eastern" => eastern} = Validation.census_metrics().interconnections

      # `spur` carries one branch; `a` carries one too (only the a-b line), so
      # both are radial — 400 of 400 MW is behind a single branch.
      assert eastern.degree_1_load_mw == 400
      assert eastern.degree_1_load_share == 1.0
    end
  end

  describe "topology_census/1 golden file" do
    setup %{baseline: baseline} do
      ic = Repo.insert!(%Interconnection{name: "Eastern"})
      ba = insert_ba("PJM")
      buses = for _ <- 1..4, do: insert_bus(ic, ba: ba)
      [a, b, c, d] = buses
      insert_line(a, b)
      insert_line(b, c)
      insert_line(c, d)

      {:ok, ic: ic, ba: ba, buses: buses, baseline: baseline}
    end

    test "the first run writes the baseline and reports it", %{baseline: path} do
      refute File.exists?(path)

      assert {:ok, report} = Validation.topology_census(baseline_path: path)
      assert report.status == :baseline_written
      assert [warning] = report.warnings
      assert warning =~ "wrote this run as the baseline"

      written = path |> File.read!() |> Jason.decode!()
      assert written["version"] == 1
      assert written["metrics"]["bus_count"] == 4

      assert written["metrics"]["interconnections"]["Eastern"]["largest_component_fraction"] ==
               1.0

      assert written["generated_at"] =~ "T"
    end

    test "an unchanged network compares clean", %{baseline: path} do
      assert {:ok, _} = Validation.topology_census(baseline_path: path)
      assert {:ok, report} = Validation.topology_census(baseline_path: path)

      assert report.status == :ok
      assert report.warnings == []
      assert report.metrics.regressions == []
      assert report.metrics.baseline_path == path
    end

    test "a regression beyond tolerance fails", %{baseline: path, ic: ic} do
      assert {:ok, _} = Validation.topology_census(baseline_path: path)

      # Lose half the buses and gain a self-loop: both move the wrong way.
      Repo.delete_all(from(tl in TransmissionLine))
      Repo.delete_all(from b in Bus, where: b.interconnection_id == ^ic.id)
      new_bus = insert_bus(ic)
      insert_line(new_bus, new_bus)

      log =
        capture_log(fn ->
          assert {:error, report} =
                   Validation.topology_census(
                     baseline_path: path,
                     tolerances: %{count_absolute: 0}
                   )

          assert report.status == :error
          assert Enum.any?(report.failures, &(&1 =~ "bus_count: 4 -> 1"))
          assert Enum.any?(report.failures, &(&1 =~ "self_loop_lines: 0 -> 1"))

          metrics = Enum.map(report.metrics.regressions, & &1.metric)
          assert "bus_count" in metrics
          assert "Eastern.connected_fraction" in metrics
          assert Enum.all?(report.metrics.regressions, &(&1.direction == :regression))
        end)

      assert log =~ "[validate topology_census]"
    end

    test "movement inside tolerance passes", %{baseline: path, ic: ic} do
      assert {:ok, _} = Validation.topology_census(baseline_path: path)

      insert_bus(ic)

      assert {:ok, report} =
               Validation.topology_census(
                 baseline_path: path,
                 tolerances: %{count_absolute: 5, fraction_absolute: 1.0}
               )

      assert report.status == :ok
    end

    test "an improvement warns and suggests refreshing the baseline", %{
      baseline: path,
      ic: ic,
      ba: ba,
      buses: buses
    } do
      assert {:ok, _} = Validation.topology_census(baseline_path: path)

      # Extend the existing chain, so connectivity improves along with the counts.
      e = insert_bus(ic, ba: ba)
      f = insert_bus(ic, ba: ba)
      insert_line(List.last(buses), e)
      insert_line(e, f)

      assert {:ok, report} =
               Validation.topology_census(baseline_path: path, tolerances: %{count_absolute: 0})

      assert report.status == :warn
      assert report.metrics.regressions == []
      assert Enum.any?(report.warnings, &(&1 =~ "--update-baseline"))
      assert Enum.any?(report.metrics.improvements, &(&1.metric == "bus_count"))
    end

    test "--update-baseline rewrites the golden file", %{baseline: path, ic: ic} do
      assert {:ok, _} = Validation.topology_census(baseline_path: path)
      insert_bus(ic)

      assert {:ok, report} =
               Validation.topology_census(baseline_path: path, update_baseline: true)

      assert report.status == :baseline_written
      assert path |> File.read!() |> Jason.decode!() |> get_in(["metrics", "bus_count"]) == 5

      assert {:ok, report} =
               Validation.topology_census(baseline_path: path, tolerances: %{count_absolute: 0})

      assert report.status == :ok
    end

    test "an interconnection that disappears is a regression", %{baseline: path} do
      assert {:ok, _} = Validation.topology_census(baseline_path: path)

      Repo.delete_all(from(tl in TransmissionLine))
      Repo.delete_all(from(b in Bus))
      Repo.delete_all(from(i in Interconnection))

      assert {:error, report} = Validation.topology_census(baseline_path: path)
      assert Enum.any?(report.metrics.regressions, &(&1.metric == "Eastern.present"))
    end
  end

  # --- aggregate run + rendering ---------------------------------------------

  describe "run/1" do
    test "aggregates the gates, and warnings alone do not fail the run", %{
      tmp: tmp,
      baseline: baseline
    } do
      seed_hours([{0, 53}, {1, 53}, {2, 17}])
      File.write!(Path.join(tmp, "egrid2022.xlsx"), "")
      File.write!(Path.join(tmp, "3_1_Generator_Y2024.csv"), "")

      capture_log(fn ->
        assert {:ok, summary} = Validation.run(data_dir: tmp, baseline_path: baseline)

        assert summary.status == :warn
        assert summary.failures == []

        assert Enum.map(summary.checks, & &1.check) == [
                 :hour_completeness,
                 :egrid_vintage,
                 :topology_census,
                 :capacity_and_balance,
             :reactive_study
               ]

        table = Validation.summary_table(summary)
        assert table =~ "Ingest validation — WARN"
        assert table =~ "hour_completeness"
        assert table =~ "WARNINGS:"
        refute table =~ "FAILURES:"
      end)
    end

    test "a failing gate fails the run and shows up in the table", %{
      tmp: tmp,
      baseline: baseline
    } do
      # No demand rows at all -> hour completeness fails.
      capture_log(fn ->
        assert {:error, summary} = Validation.run(data_dir: tmp, baseline_path: baseline)

        assert summary.status == :error
        assert [failure] = summary.failures
        assert failure =~ "ba_demand_hourly is empty"

        table = Validation.summary_table(summary)
        assert table =~ "Ingest validation — ERROR"
        assert table =~ "[FAIL]"
        assert table =~ "FAILURES:"
      end)
    end

    test "the capacity/balance gate reports as skipped without ba_fuel_hour" do
      assert {:ok, report} = Validation.capacity_and_balance()
      assert report.status == :skipped
      assert report.failures == []
      assert report.metrics.reason =~ "ba_fuel_hour is empty"
    end
  end

  # --- capacity feasibility + per-BA balance ---------------------------------

  describe "capacity_and_balance/1 capacity feasibility" do
    test "a fleet that can produce what was measured raises nothing" do
      ba = insert_ba("AAA")
      bus = insert_bus(nil, ba: ba)
      insert_generator(bus, "BIT", 100.0)

      insert_fuel("AAA", @summer_hour, "coal", 90.0)

      capture_log(fn ->
        assert {:ok, report} = Validation.capacity_and_balance()

        assert report.metrics.capacity.short == 0
        assert report.metrics.capacity.shortfall_mw == 0.0
        assert report.failures == []
      end)
    end

    test "measured generation the mapped fleet cannot produce is reported per group" do
      ba = insert_ba("AAA")
      bus = insert_bus(nil, ba: ba)
      insert_generator(bus, "BIT", 100.0)

      insert_fuel("AAA", @summer_hour, "coal", 500.0)

      capture_log(fn ->
        # The failure threshold is exercised by the next test; here only the
        # per-group reporting is under test.
        assert {:ok, report} =
                 Validation.capacity_and_balance(
                   capacity_and_balance: %{capacity_fail_share: 1.0}
                 )

        capacity = report.metrics.capacity
        assert capacity.short == 1
        assert capacity.shortfall_mw == 400.0
        assert capacity.short_beyond_fail_ratio == 1

        assert [%{ba_code: "AAA", fuel: "coal", season: :summer, peak_mw: 500.0}] = capacity.worst
        assert Enum.any?(report.warnings, &(&1 =~ "AAA/coal"))
      end)
    end

    test "the aggregate shortfall share fails the gate past its threshold" do
      ba = insert_ba("AAA")
      bus = insert_bus(nil, ba: ba)
      insert_generator(bus, "BIT", 100.0)

      insert_fuel("AAA", @summer_hour, "coal", 500.0)

      capture_log(fn ->
        assert {:error, report} =
                 Validation.capacity_and_balance(
                   capacity_and_balance: %{capacity_fail_share: 0.5}
                 )

        assert report.status == :error
        assert [failure] = report.failures
        assert failure =~ "Capacity feasibility"
        assert failure =~ "80.0%"
      end)
    end

    test "seasonal capability is compared against the matching season's peak" do
      ba = insert_ba("AAA")
      bus = insert_bus(nil, ba: ba)
      # Winter-rated 200 MW, summer-derated to 60 MW.
      insert_generator(bus, "NG", 200.0, summer_capacity_mw: 60.0, winter_capacity_mw: 200.0)

      insert_fuel("AAA", @summer_hour, "natural_gas", 180.0)
      insert_fuel("AAA", @winter_hour, "natural_gas", 180.0)

      capture_log(fn ->
        assert {:ok, report} = Validation.capacity_and_balance()

        assert report.metrics.capacity.ba_fuels == 2
        assert [%{season: :summer, shortfall_mw: 120.0}] = report.metrics.capacity.worst
        assert report.metrics.capacity.seasonal_capability_units == 1
      end)
    end

    test "groups below the minimum MW are noise, not findings" do
      ba = insert_ba("AAA")
      insert_bus(nil, ba: ba)

      # 10 MW measured against a BA that owns no unit at all.
      insert_fuel("AAA", @summer_hour, "solar", 10.0)

      capture_log(fn ->
        assert {:ok, report} = Validation.capacity_and_balance()
        assert report.metrics.capacity.short == 0
      end)
    end
  end

  describe "capacity_and_balance/1 balance at screened hours" do
    test "a BA-hour that closes on both sides passes" do
      ba = insert_ba("AAA")
      insert_fleet(ba, "BIT", 1200.0)
      insert_demand(ba, @summer_hour, demand: 1000.0, net_generation: 1100.0, interchange: 100.0)
      insert_fuel("AAA", @summer_hour, "coal", 1100.0)

      capture_log(fn ->
        assert {:ok, report} = Validation.capacity_and_balance()

        balance = report.metrics.balance
        assert balance.rows == 1
        assert balance.screened_rows == 1
        assert balance.out_of_tolerance == 0
      end)
    end

    test "an hour EIA's own column closes but the fuel sum misses is still a finding" do
      ba = insert_ba("AAA")
      insert_fleet(ba, "BIT", 600.0)
      # EIA's own trio is 400 MW from closing AND the fuel columns account for
      # only 500 of the 1,100 MW the demand/interchange pair implies. REVIEW
      # ENE-23: the old screen threw this hour away on the first fact, which is
      # how WALC over-dispatched a fifth of its demand for 69% of its hours
      # without the report saying a word. Dispatch places the fuel columns, so
      # the fuel columns are what has to reconcile.
      insert_demand(ba, @summer_hour, demand: 1000.0, net_generation: 1500.0, interchange: 100.0)
      insert_fuel("AAA", @summer_hour, "coal", 500.0)

      capture_log(fn ->
        assert {:ok, report} =
                 Validation.capacity_and_balance(capacity_and_balance: %{balance_fail_share: 1.0})

        balance = report.metrics.balance
        assert balance.rows == 1
        assert balance.screened_rows == 0
        assert balance.screened_share == 0.0
        assert balance.out_of_tolerance == 1
        assert balance.mean_residual_mw == 600.0

        # EIA's own column is reported alongside, so the two can be told apart.
        assert balance.eia_screened_rows == 0
      end)
    end

    test "the fuel sum missing the identity is a finding even where EIA's column closes" do
      ba = insert_ba("AAA")
      insert_fleet(ba, "BIT", 1000.0)
      insert_demand(ba, @summer_hour, demand: 1000.0, net_generation: 1100.0, interchange: 100.0)
      # The per-fuel columns only account for 900 of the 1100 MW. This is the
      # WALC shape in miniature: EIA's own trio closes exactly.
      insert_fuel("AAA", @summer_hour, "coal", 900.0)

      capture_log(fn ->
        # Every row in this fixture is unbalanced, which the next test uses to
        # trip the gate; here only the measurement is under test.
        assert {:ok, report} =
                 Validation.capacity_and_balance(capacity_and_balance: %{balance_fail_share: 1.0})

        balance = report.metrics.balance
        assert balance.rows == 1
        assert balance.eia_screened_rows == 1
        assert balance.screened_rows == 0
        assert balance.out_of_tolerance == 1
        assert balance.out_of_tolerance_share == 1.0
        assert balance.mean_residual_mw == 200.0
        assert Enum.any?(report.warnings, &(&1 =~ "do not balance"))
        assert Enum.any?(report.warnings, &(&1 =~ "per-fuel SUM closes on only"))
      end)
    end

    test "too many unbalanced screened hours fail the gate" do
      ba = insert_ba("AAA")
      insert_fleet(ba, "BIT", 1000.0)
      insert_demand(ba, @summer_hour, demand: 1000.0, net_generation: 1100.0, interchange: 100.0)
      insert_fuel("AAA", @summer_hour, "coal", 900.0)

      capture_log(fn ->
        assert {:error, report} = Validation.capacity_and_balance()

        assert [failure] = report.failures
        assert failure =~ "Per-BA balance"
        assert failure =~ "ENE-16"
      end)
    end

    test "a residual inside tolerance is not a finding" do
      ba = insert_ba("AAA")
      insert_fleet(ba, "BIT", 1200.0)
      insert_demand(ba, @summer_hour, demand: 1000.0, net_generation: 1100.0, interchange: 100.0)
      # 20 MW off, inside Demand.identity_tolerance/0 = max(50 MW, 5% of demand).
      insert_fuel("AAA", @summer_hour, "coal", 1080.0)

      capture_log(fn ->
        assert {:ok, report} = Validation.capacity_and_balance()
        assert report.metrics.balance.out_of_tolerance == 0
      end)
    end

    test "BAs reporting demand but no per-fuel generation are named" do
      ba = insert_ba("AAA")
      insert_fleet(ba, "BIT", 1200.0)
      silent = insert_ba("BBB")
      insert_demand(ba, @summer_hour, demand: 1000.0, net_generation: 1100.0, interchange: 100.0)
      insert_demand(silent, @summer_hour, demand: 500.0, net_generation: 500.0, interchange: 0.0)
      insert_fuel("AAA", @summer_hour, "coal", 1100.0)

      capture_log(fn ->
        assert {:ok, report} = Validation.capacity_and_balance()

        assert report.metrics.balance.bas_without_fuel_rows == ["BBB"]
        assert Enum.any?(report.warnings, &(&1 =~ "report demand but no per-fuel"))
      end)
    end

    test "BAs that never satisfy EIA's own identity are called out separately" do
      ba = insert_ba("AAA")
      insert_fleet(ba, "BIT", 1600.0)

      for offset <- 0..150 do
        hour = DateTime.add(@summer_hour, offset * 3600, :second)
        insert_demand(ba, hour, demand: 1000.0, net_generation: 1500.0, interchange: 100.0)
        insert_fuel("AAA", hour, "coal", 1500.0)
      end

      capture_log(fn ->
        # Every hour in the fixture fails, which is 100% of rows and past the
        # gate — the naming is what is under test, so the gate is opened.
        assert {:ok, report} =
                 Validation.capacity_and_balance(capacity_and_balance: %{balance_fail_share: 1.0})

        assert [%{ba_code: "AAA", screened: 0}] = report.metrics.balance.barely_screened
        assert Enum.any?(report.warnings, &(&1 =~ "fail the generation identity"))

        # The screened set is exactly what dispatch anchor-corrects, taken from
        # the one identity implementation rather than a threshold of its own.
        assert Map.keys(PowerModel.Demand.broken_identity_bas()) == [ba.id]
      end)
    end
  end
end
