defmodule PowerModel.Ingestion.Validation do
  @moduledoc """
  Ingest-time validation gates (ROADMAP Phase 0, item 3).

  Runs as the final stage of `mix power_model.ingest full_pipeline` and
  standalone via `mix power_model.ingest validate`. The gates answer one
  question: did the ingest that just finished produce data the simulator can
  trust, or did it produce something that *looks* complete?

  ## Checks in this wave

    * `hour_completeness/1` — per-hour reporting-BA census over
      `ba_demand_hourly`. Reports the modal reporting-BA count, how many hours
      fall below `modal - 1`, and the latest COMPLETE hour. This is the
      data-side view of REVIEW DAT-15/ENE-13: `Demand.latest_demand_hour/0`
      returns the file's boundary hour, where only a fraction of BAs report,
      so most of the country silently falls back to the baseline. The consumer
      fix lives in `PowerModel.Demand`; this check makes the condition visible
      and loud at ingest time.

    * `egrid_vintage/1` — compares the eGRID workbook vintage in `data/`
      against the EIA-860 vintage the generator ingest would use. eGRID
      capacity factors are joined onto an EIA-860 fleet; a vintage gap means
      units commissioned after the eGRID data year can never receive a
      measured CF and silently keep fuel-typical defaults. Warns (never
      fails) on mismatch.

    * `topology_census/1` — golden-file regression gate over the network:
      bus/line/generator/transformer counts, buses without a balancing
      authority, lines with unmapped endpoints, self-loops, generators without
      a bus, per-interconnection connectivity (share of geolocated buses
      carrying a branch, and largest-component share), and — REVIEW DAT-28 —
      whether the network can CARRY what is on it: stranded nameplate, buses
      with generation and no branch rating, and radial load per
      interconnection (`placement_census/0`). The first run writes the
      baseline; later runs fail on regression beyond the configured
      tolerances.

    * `capacity_and_balance/1` — the two `ba_fuel_hour` gates: can the mapped
      fleet physically produce the generation EIA says it produced, and does
      our per-fuel ingest reproduce EIA's own generation identity. Reports
      `:skipped` when `ba_fuel_hour` is empty.

  ## Return shape

  Every check returns `{:ok, report}` or `{:error, report}`. The report is a
  map with:

      %{
        check: :hour_completeness,       # check name
        status: :ok | :warn | :error | :skipped | :baseline_written,
        metrics: %{...},                 # structured measurements
        warnings: [String.t()],          # loud but non-fatal
        failures: [String.t()]           # non-empty exactly when {:error, _}
      }

  The error tuple carries the same map (rather than the bare failure list) so
  callers can still print metrics for a failed check; `report.failures` is the
  failure list and, for `topology_census/1`, `report.metrics.regressions`
  holds the structured diffs that tripped the gate.

  `run/1` aggregates the checks into `%{status:, checks:, warnings:,
  failures:}` and returns `{:ok, summary}` when no check failed.
  `summary_table/1` renders that summary for the mix task.

  ## Options

    * `:data_dir` — where the source files live (default `"data"`)
    * `:baseline_path` — topology golden file (default
      `priv/topology_baseline.json`)
    * `:update_baseline` — rewrite the golden file from this run (default false)
    * `:reporting_slack` — an hour is COMPLETE when its reporting-BA count is
      at least `modal - reporting_slack` (default 1)
    * `:tolerances` — map merged over `#{inspect(%{count_relative: 0.05, count_absolute: 25, fraction_absolute: 0.02})}`;
      also configurable as
      `config :power_model, PowerModel.Ingestion.Validation, tolerances: %{...}`
    * `:capacity_and_balance` — thresholds for the fuel gates, see
      `capacity_and_balance/1`
  """

  import Ecto.Query
  require Logger

  alias PowerModel.Demand
  alias PowerModel.Demand.{BADemandHour, BAFuelHour}
  alias PowerModel.Dispatch
  alias PowerModel.Grid
  alias PowerModel.Failure.Cascade
  alias PowerModel.Ingestion.{BusMapper, CapacityInference}
  alias PowerModel.Solver.Partition

  alias PowerModel.Grid.{
    BalancingAuthority,
    Bus,
    Generator,
    Interconnection,
    Transformer,
    TransmissionLine
  }

  alias PowerModel.Repo

  @baseline_version 1
  @default_baseline_relpath "topology_baseline.json"

  # A count metric may drift by max(count_absolute, count_relative * baseline)
  # in the bad direction before it counts as a regression; fractions use a
  # flat absolute tolerance.
  @default_tolerances %{count_relative: 0.05, count_absolute: 25, fraction_absolute: 0.02}

  # Direction of each scalar topology metric: :up means larger is healthier
  # (losing buses is data loss), :down means smaller is healthier (unmapped
  # endpoints, self-loops).
  @scalar_metric_directions %{
    bus_count: :up,
    geolocated_bus_count: :up,
    buses_without_ba: :down,
    geolocated_buses_without_ba: :down,
    geolocated_buses_without_interconnection: :down,
    line_count: :up,
    lines_in_service: :up,
    lines_unmapped_endpoints: :down,
    self_loop_lines: :down,
    transformer_count: :up,
    transformers_unmapped_endpoints: :down,
    self_loop_transformers: :down,
    generator_count: :up,
    generators_without_bus: :down,
    # REVIEW DAT-28: what the network can CARRY, not just what it contains.
    stranded_nameplate_mw: :down,
    zero_capability_generator_buses: :down
  }

  @interconnection_metric_directions %{
    geolocated_bus_count: :up,
    connected_bus_count: :up,
    connected_fraction: :up,
    component_count: :down,
    largest_component_bus_count: :up,
    largest_component_fraction: :up,
    degree_1_load_mw: :down,
    degree_1_load_share: :down
  }

  @fraction_metrics ~w(connected_fraction largest_component_fraction degree_1_load_share)

  @doc """
  Run every gate. Returns `{:ok, summary}` when no check failed,
  `{:error, summary}` otherwise. Warnings never fail the run.
  """
  # Fraction of rated branches over 100 % at rest above which the gate fails.
  @at_rest_fail_fraction 0.005

  def run(opts \\ []) do
    checks = [
      hour_completeness(opts),
      egrid_vintage(opts),
      topology_census(opts),
      capacity_and_balance(opts),
      reactive_study_freshness(opts),
      at_rest_loading(opts)
    ]

    reports = Enum.map(checks, fn {_tag, report} -> report end)
    failures = Enum.flat_map(reports, & &1.failures)
    warnings = Enum.flat_map(reports, & &1.warnings)

    summary = %{
      status: overall_status(reports),
      checks: reports,
      warnings: warnings,
      failures: failures
    }

    if failures == [], do: {:ok, summary}, else: {:error, summary}
  end

  defp overall_status(reports) do
    cond do
      Enum.any?(reports, &(&1.failures != [])) -> :error
      Enum.any?(reports, &(&1.warnings != [])) -> :warn
      true -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # 1. Hour completeness (DAT-15 / ENE-13)
  # ---------------------------------------------------------------------------

  @doc """
  Census of EIA-930 hour completeness: how many balancing authorities report
  in each hour of `ba_demand_hourly`.

  An hour is COMPLETE when its reporting-BA count is at least
  `modal - reporting_slack` (default slack 1, absorbing the routine
  single-BA gap). Incomplete hours at either end of the ingested window are
  reported as *boundary* hours — those are the partial hours a bulk file
  starts and ends on, and the reason `Demand.latest_demand_hour/0` lands on an
  hour where two-thirds of the country is missing. Incomplete hours in the
  middle of the window are reported separately: those are lost data, not a
  file boundary.

  Fails only when there is no demand data at all.
  """
  def hour_completeness(opts \\ []) do
    slack = Keyword.get(opts, :reporting_slack, 1)

    hours =
      Repo.all(
        from d in BADemandHour,
          group_by: d.timestamp_utc,
          order_by: d.timestamp_utc,
          select: {d.timestamp_utc, count(d.balancing_authority_id, :distinct)}
      )

    if hours == [] do
      report(:hour_completeness, %{hours_total: 0},
        failures: [
          "ba_demand_hourly is empty — no EIA-930 demand was ingested. " <>
            "Every simulation will run the ~2x nameplate baseline instead of measured demand."
        ]
      )
    else
      analyze_hours(hours, slack)
    end
  end

  defp analyze_hours(hours, slack) do
    counts = Enum.map(hours, &elem(&1, 1))
    modal = modal_count(counts)
    threshold = max(modal - slack, 1)

    complete = Enum.filter(hours, fn {_ts, n} -> n >= threshold end)
    incomplete = Enum.filter(hours, fn {_ts, n} -> n < threshold end)

    first_complete = complete |> List.first() |> then(&(&1 && elem(&1, 0)))
    latest_complete = complete |> List.last() |> then(&(&1 && elem(&1, 0)))

    {boundary, interior} =
      Enum.split_with(incomplete, fn {ts, _n} ->
        first_complete == nil or
          DateTime.compare(ts, first_complete) == :lt or
          DateTime.compare(ts, latest_complete) == :gt
      end)

    {latest_ts, latest_n} = List.last(hours)

    metrics = %{
      hours_total: length(hours),
      max_reporting_bas: Enum.max(counts),
      modal_reporting_bas: modal,
      complete_threshold: threshold,
      complete_hours: length(complete),
      incomplete_hours: length(incomplete),
      boundary_incomplete_hours: Enum.map(boundary, &format_hour/1),
      interior_incomplete_hours: Enum.map(interior, &format_hour/1),
      earliest_complete_hour: first_complete,
      latest_complete_hour: latest_complete,
      latest_hour: latest_ts,
      latest_hour_reporting_bas: latest_n
    }

    warnings =
      []
      |> maybe_warn(
        latest_complete != nil and DateTime.compare(latest_ts, latest_complete) == :gt,
        "ENE-13/DAT-15: the latest ingested hour #{format_ts(latest_ts)} has only " <>
          "#{latest_n}/#{modal} BAs reporting. `Demand.latest_demand_hour/0` returns THIS hour, " <>
          "so every BA missing from it silently falls back to the ~2x nameplate baseline. " <>
          "Latest COMPLETE hour: #{format_ts(latest_complete)}."
      )
      |> maybe_warn(
        boundary != [],
        "#{length(boundary)} incomplete boundary hour(s) (below #{threshold} reporting BAs): " <>
          summarize_hours(boundary)
      )
      |> maybe_warn(
        interior != [],
        "#{length(interior)} incomplete hour(s) INSIDE the ingested window — missing data, " <>
          "not a file boundary: " <> summarize_hours(interior)
      )
      |> maybe_warn(
        complete == [],
        "No hour reaches #{threshold} reporting BAs; the 930 ingest looks partial."
      )

    report(:hour_completeness, metrics, warnings: Enum.reverse(warnings))
  end

  defp modal_count(counts) do
    counts
    |> Enum.frequencies()
    # ties break toward the larger reporting count: a tie means the file is
    # split between two plateaus and the fuller one is the real fleet.
    |> Enum.max_by(fn {count, freq} -> {freq, count} end)
    |> elem(0)
  end

  defp format_hour({ts, n}), do: %{hour: ts, reporting_bas: n}

  defp summarize_hours(hours, limit \\ 8) do
    shown =
      hours
      |> Enum.take(limit)
      |> Enum.map_join(", ", fn {ts, n} -> "#{format_ts(ts)} (#{n} BAs)" end)

    extra = length(hours) - limit
    if extra > 0, do: shown <> " and #{extra} more", else: shown
  end

  defp format_ts(nil), do: "none"
  defp format_ts(%DateTime{} = ts), do: Calendar.strftime(ts, "%Y-%m-%d %H:%MZ")

  # ---------------------------------------------------------------------------
  # 2. eGRID vintage vs EIA-860 vintage
  # ---------------------------------------------------------------------------

  # Mirrors the generator-file precedence in PowerModel.Ingestion.EIA.Form860
  # (newest extracted Schedule 3.1 CSV first), then the downloaded archives
  # that such a CSV is exported from.
  @eia860_patterns ~w(3_1_Generator_Y*.csv eia860*.zip eia860*/ f860*.zip)

  @doc """
  Compare the eGRID workbook vintage in `data/` with the EIA-860 vintage the
  generator ingest would read.

  eGRID CFACT values are joined onto the EIA-860 fleet by plant ID. When the
  eGRID data year trails the 860 vintage, every unit commissioned in between
  keeps a fuel-typical default capacity factor with no measured value behind
  it — invisible unless something says so. Warns; never fails.
  """
  def egrid_vintage(opts \\ []) do
    dir = Keyword.get(opts, :data_dir, "data")

    egrid_file = first_match(dir, ["egrid*.xlsx"])
    eia860_file = first_match(dir, @eia860_patterns)

    egrid_year = year_in(egrid_file)
    eia860_year = year_in(eia860_file)

    metrics = %{
      data_dir: dir,
      egrid_file: egrid_file,
      egrid_year: egrid_year,
      eia860_file: eia860_file,
      eia860_year: eia860_year,
      vintage_gap_years: egrid_year && eia860_year && eia860_year - egrid_year
    }

    warnings =
      cond do
        egrid_file == nil ->
          ["No egrid*.xlsx in #{dir}/ — capacity factors fall back to fuel-typical defaults."]

        eia860_file == nil ->
          ["No EIA-860 generator file or archive in #{dir}/ — cannot verify the fleet vintage."]

        egrid_year == nil or eia860_year == nil ->
          [
            "Could not read a vintage year from #{Path.basename(egrid_file)} / " <>
              "#{Path.basename(eia860_file)} — vintage check skipped."
          ]

        egrid_year != eia860_year ->
          [
            "eGRID vintage mismatch: #{Path.basename(egrid_file)} (data year #{egrid_year}) " <>
              "against an EIA-860 #{eia860_year} fleet (#{Path.basename(eia860_file)}). " <>
              "Units added after #{egrid_year} can never receive a measured capacity factor " <>
              "and keep fuel-typical defaults."
          ]

        true ->
          []
      end

    report(:egrid_vintage, metrics, warnings: warnings)
  end

  defp first_match(dir, patterns) do
    Enum.find_value(patterns, fn pattern ->
      dir
      |> Path.join(pattern)
      |> Path.wildcard()
      |> Enum.sort(:desc)
      |> List.first()
    end)
  end

  defp year_in(nil), do: nil

  defp year_in(path) do
    case Regex.run(~r/(19|20)\d{2}/, Path.basename(path)) do
      [year | _] -> String.to_integer(year)
      nil -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Topology census vs golden file
  # ---------------------------------------------------------------------------

  @doc """
  Census the ingested network and compare it against the golden baseline.

  The first run (or `update_baseline: true`) writes
  `priv/topology_baseline.json` and returns `status: :baseline_written`.
  Later runs diff against it and return `{:error, report}` when any metric
  moved beyond tolerance in the unhealthy direction — buses or lines lost,
  unmapped endpoints or self-loops gained, connectivity dropped. Movement in
  the healthy direction is reported as a warning suggesting
  `--update-baseline`, so an improvement is recorded rather than silently
  becoming the new floor.

  Connectivity uses the same branch predicate the simulator does (see
  `PowerModel.Grid.get_full_grid_snapshot/1`): in-service, non-DC, no
  self-loops, both endpoints geolocated and in the same interconnection.
  """
  def topology_census(opts \\ []) do
    metrics = census_metrics()
    path = baseline_path(opts)

    cond do
      Keyword.get(opts, :update_baseline, false) ->
        write_baseline!(path, metrics)

        report(:topology_census, Map.put(metrics, :baseline_path, path),
          status: :baseline_written,
          warnings: ["Topology baseline rewritten from this run: #{path}"]
        )

      not File.exists?(path) ->
        write_baseline!(path, metrics)

        report(:topology_census, Map.put(metrics, :baseline_path, path),
          status: :baseline_written,
          warnings: [
            "No topology baseline at #{path} — wrote this run as the baseline. " <>
              "Commit it; later ingests fail on regression against it."
          ]
        )

      true ->
        compare_to_baseline(metrics, path, opts)
    end
  end

  defp compare_to_baseline(metrics, path, opts) do
    baseline = read_baseline!(path)
    diffs = diff_metrics(metrics, baseline["metrics"] || %{}, tolerances(opts))

    {regressions, improvements} = Enum.split_with(diffs, &(&1.direction == :regression))

    metrics =
      metrics
      |> Map.put(:baseline_path, path)
      |> Map.put(:baseline_generated_at, baseline["generated_at"])
      |> Map.put(:regressions, regressions)
      |> Map.put(:improvements, improvements)

    warnings =
      if improvements == [] do
        []
      else
        [
          "#{length(improvements)} topology metric(s) improved beyond tolerance; " <>
            "re-run with --update-baseline to record them: " <>
            Enum.map_join(Enum.take(improvements, 6), "; ", &describe_diff/1)
        ]
      end

    failures = Enum.map(regressions, &describe_diff/1)

    report(:topology_census, metrics, warnings: warnings, failures: failures)
  end

  defp describe_diff(diff) do
    "#{diff.metric}: #{fmt_num(diff.baseline)} -> #{fmt_num(diff.current)} " <>
      "(tolerance #{fmt_num(diff.tolerance)})"
  end

  defp fmt_num(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt_num(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 4)
  defp fmt_num(nil), do: "absent"
  defp fmt_num(other), do: inspect(other)

  @doc """
  Raw topology metrics for the current database, without any baseline
  comparison. Exposed for the accuracy scoreboard and for tests.
  """
  def census_metrics do
    bus =
      Repo.one(
        from b in Bus,
          select: %{
            bus_count: fragment("count(*)"),
            geolocated_bus_count: fragment("count(*) filter (where coordinates is not null)"),
            buses_without_ba: fragment("count(*) filter (where balancing_authority_id is null)"),
            geolocated_buses_without_ba:
              fragment(
                "count(*) filter (where coordinates is not null and balancing_authority_id is null)"
              ),
            geolocated_buses_without_interconnection:
              fragment(
                "count(*) filter (where coordinates is not null and interconnection_id is null)"
              )
          }
      )

    line =
      Repo.one(
        from tl in TransmissionLine,
          select: %{
            line_count: fragment("count(*)"),
            lines_in_service: fragment("count(*) filter (where status = 'in_service')"),
            lines_unmapped_endpoints:
              fragment("count(*) filter (where from_bus_id is null or to_bus_id is null)"),
            self_loop_lines: fragment("count(*) filter (where from_bus_id = to_bus_id)")
          }
      )

    transformer =
      Repo.one(
        from t in Transformer,
          select: %{
            transformer_count: fragment("count(*)"),
            transformers_unmapped_endpoints:
              fragment("count(*) filter (where from_bus_id is null or to_bus_id is null)"),
            self_loop_transformers: fragment("count(*) filter (where from_bus_id = to_bus_id)")
          }
      )

    generator =
      Repo.one(
        from g in Generator,
          select: %{
            generator_count: fragment("count(*)"),
            generators_without_bus: fragment("count(*) filter (where bus_id is null)")
          }
      )

    bus
    |> Map.merge(line)
    |> Map.merge(transformer)
    |> Map.merge(generator)
    |> Map.merge(placement_census())
    |> Map.put(:interconnections, interconnection_metrics())
  end

  # Connectivity and radial-load exposure land in one per-interconnection map
  # so the baseline diff walks them together.
  defp interconnection_metrics do
    deg1 = degree_1_load()
    empty = %{degree_1_load_mw: 0, degree_1_load_share: 0.0}

    Map.new(interconnection_connectivity(), fn {name, stats} ->
      {name, Map.merge(stats, Map.get(deg1, name, empty))}
    end)
  end

  @doc """
  Whether the network can CARRY what has been placed on it, as three numbers
  over the DB graph (every bus and every in-service branch, all components —
  the graph DR-4's stranding census was measured on, not the main-island
  snapshot):

    * `stranded_nameplate_mw` — in-service nameplate sitting on buses whose
      summed connected branch rating cannot carry
      `PowerModel.Ingestion.BusMapper.stranding_headroom/0` times it. Grand
      Coulee's 6,809 MW on a 115 kV bus with 537 MVA of branch is the shape of
      it: the DC solution answers with an angle no AC solution reproduces.
    * `zero_capability_generator_buses` — buses carrying in-service generation
      with NO branch rating at all. Distinct from the above because a bus with
      zero capability is invisible to a ratio test that never divides.
    * `degree_1_load_mw` / `degree_1_load_share` — load behind a single branch,
      per interconnection. A radial load is a load one trip disconnects.

  REVIEW DAT-28: the census recorded counts and connectivity only, so DAT-26's
  degradation — placement falling back to the pre-DR-4 rule because
  `rating_a_mva` was still NULL when `map_buses` ran — moved 87.8% of the
  capability at generator buses to zero and passed the pipeline's final gate
  clean. These three are the metrics that would have caught it.
  """
  def placement_census do
    %{rows: [[stranded_mw, zero_cap_buses]]} =
      Repo.query!(
        """
        WITH cap AS (
          SELECT bus_id, SUM(mva) AS mva FROM (
            SELECT from_bus_id AS bus_id, COALESCE(rating_a_mva, 0.0) AS mva
              FROM transmission_lines WHERE status = 'in_service'
            UNION ALL
            SELECT to_bus_id, COALESCE(rating_a_mva, 0.0)
              FROM transmission_lines WHERE status = 'in_service'
            UNION ALL
            SELECT from_bus_id, COALESCE(rated_mva, 0.0)
              FROM transformers WHERE status = 'in_service'
            UNION ALL
            SELECT to_bus_id, COALESCE(rated_mva, 0.0)
              FROM transformers WHERE status = 'in_service'
          ) branch WHERE bus_id IS NOT NULL GROUP BY bus_id
        ),
        gen AS (
          SELECT bus_id, SUM(COALESCE(p_max_mw, 0.0)) AS mw
            FROM generators WHERE status = 'in_service' AND bus_id IS NOT NULL
            GROUP BY bus_id
        )
        SELECT
          COALESCE(SUM(gen.mw) FILTER (WHERE gen.mw > $1 * COALESCE(cap.mva, 0.0)), 0.0),
          COUNT(*) FILTER (WHERE COALESCE(cap.mva, 0.0) = 0.0)
        FROM gen LEFT JOIN cap ON cap.bus_id = gen.bus_id
        """,
        [BusMapper.stranding_headroom()],
        timeout: :infinity
      )

    %{
      stranded_nameplate_mw: round(stranded_mw),
      zero_capability_generator_buses: zero_cap_buses
    }
  end

  # Load on buses carrying at most one in-service branch, per interconnection.
  # Degree is counted over the same branch set `interconnection_connectivity/0`
  # uses, so "degree 1" means the same thing in both.
  defp degree_1_load do
    %{rows: rows} =
      Repo.query!(
        """
        WITH branch AS (
          SELECT from_bus_id AS a, to_bus_id AS b FROM transmission_lines
            WHERE status = 'in_service' AND from_bus_id IS NOT NULL
              AND to_bus_id IS NOT NULL AND from_bus_id <> to_bus_id
          UNION ALL
          SELECT from_bus_id, to_bus_id FROM transformers
            WHERE status = 'in_service' AND from_bus_id IS NOT NULL
              AND to_bus_id IS NOT NULL AND from_bus_id <> to_bus_id
        ),
        degree AS (
          SELECT bus_id, count(*) AS deg FROM (
            SELECT a AS bus_id FROM branch UNION ALL SELECT b FROM branch
          ) e GROUP BY bus_id
        ),
        bus_load AS (
          SELECT bus_id, SUM(COALESCE(p_mw, 0.0)) AS mw FROM loads
            WHERE status = 'in_service' AND bus_id IS NOT NULL GROUP BY bus_id
        )
        SELECT i.name,
               COALESCE(SUM(bus_load.mw), 0.0),
               COALESCE(SUM(bus_load.mw) FILTER (WHERE COALESCE(degree.deg, 0) <= 1), 0.0)
        FROM bus_load
        JOIN buses b ON b.id = bus_load.bus_id
        JOIN interconnections i ON i.id = b.interconnection_id
        LEFT JOIN degree ON degree.bus_id = bus_load.bus_id
        GROUP BY i.name
        """,
        [],
        timeout: :infinity
      )

    Map.new(rows, fn [name, total_mw, deg1_mw] ->
      {name,
       %{degree_1_load_mw: round(deg1_mw), degree_1_load_share: safe_fraction(deg1_mw, total_mw)}}
    end)
  end

  @doc """
  Per-interconnection connectivity over the simulated branch set: how many
  geolocated buses carry a branch at all, how many connected components those
  buses form, and how large the biggest one is.
  """
  def interconnection_connectivity do
    names =
      Repo.all(from i in Interconnection, select: {i.id, i.name})
      |> Map.new()

    bus_ic =
      Repo.all(
        from b in Bus,
          where: not is_nil(b.coordinates) and not is_nil(b.interconnection_id),
          select: {b.id, b.interconnection_id}
      )

    roots = component_roots(simulated_branches())

    bus_ic
    |> Enum.group_by(fn {_bus_id, ic_id} -> ic_id end, fn {bus_id, _ic_id} -> bus_id end)
    |> Enum.map(fn {ic_id, bus_ids} ->
      {Map.get(names, ic_id, "interconnection_#{ic_id}"), connectivity_stats(bus_ids, roots)}
    end)
    |> Map.new()
  end

  defp connectivity_stats(bus_ids, roots) do
    sizes =
      bus_ids
      |> Enum.reduce(%{}, fn bus_id, acc ->
        case Map.fetch(roots, bus_id) do
          {:ok, root} -> Map.update(acc, root, 1, &(&1 + 1))
          :error -> acc
        end
      end)

    total = length(bus_ids)
    connected = sizes |> Map.values() |> Enum.sum()
    largest = if sizes == %{}, do: 0, else: sizes |> Map.values() |> Enum.max()

    %{
      geolocated_bus_count: total,
      connected_bus_count: connected,
      connected_fraction: safe_fraction(connected, total),
      component_count: map_size(sizes),
      largest_component_bus_count: largest,
      largest_component_fraction: safe_fraction(largest, total)
    }
  end

  defp safe_fraction(_num, 0), do: 0.0
  defp safe_fraction(_num, +0.0), do: 0.0
  defp safe_fraction(num, den), do: Float.round(num / den, 4)

  # The branch set the solver actually sees: in-service, not a self-loop, not
  # a DC tie, both endpoints geolocated and inside the same interconnection.
  defp simulated_branches do
    lines =
      Repo.all(
        from tl in TransmissionLine,
          join: fb in Bus,
          on: tl.from_bus_id == fb.id,
          join: tb in Bus,
          on: tl.to_bus_id == tb.id,
          where:
            tl.status == "in_service" and tl.from_bus_id != tl.to_bus_id and
              (is_nil(tl.line_type) or tl.line_type != "dc") and
              not is_nil(fb.coordinates) and not is_nil(tb.coordinates) and
              not is_nil(fb.interconnection_id) and
              fb.interconnection_id == tb.interconnection_id,
          select: {tl.from_bus_id, tl.to_bus_id}
      )

    transformers =
      Repo.all(
        from t in Transformer,
          join: fb in Bus,
          on: t.from_bus_id == fb.id,
          join: tb in Bus,
          on: t.to_bus_id == tb.id,
          where:
            t.status == "in_service" and t.from_bus_id != t.to_bus_id and
              not is_nil(fb.coordinates) and not is_nil(tb.coordinates) and
              not is_nil(fb.interconnection_id) and
              fb.interconnection_id == tb.interconnection_id,
          select: {t.from_bus_id, t.to_bus_id}
      )

    lines ++ transformers
  end

  # Union-find over the branch list; returns %{bus_id => component_root} for
  # every bus that carries at least one branch. Buses with no branch are
  # absent (they are isolated by definition and counted as such).
  defp component_roots(edges) do
    parent =
      Enum.reduce(edges, %{}, fn {a, b}, parent ->
        {ra, parent} = find_root(parent, a)
        {rb, parent} = find_root(parent, b)
        if ra == rb, do: parent, else: Map.put(parent, ra, rb)
      end)

    parent
    |> Map.keys()
    |> Enum.reduce({%{}, parent}, fn node, {roots, parent} ->
      {root, parent} = find_root(parent, node)
      {Map.put(roots, node, root), parent}
    end)
    |> elem(0)
  end

  defp find_root(parent, node) do
    case Map.get(parent, node, node) do
      ^node ->
        {node, Map.put_new(parent, node, node)}

      up ->
        {root, parent} = find_root(parent, up)
        {root, Map.put(parent, node, root)}
    end
  end

  # --- baseline file -------------------------------------------------------

  @doc """
  Path of the topology golden file. Defaults to `priv/topology_baseline.json`
  inside the application (a symlink to the repo's `priv/` in dev and test, so
  a first run writes a file that can be committed).
  """
  def baseline_path(opts \\ []) do
    Keyword.get_lazy(opts, :baseline_path, fn ->
      Application.app_dir(:power_model, Path.join("priv", @default_baseline_relpath))
    end)
  end

  defp write_baseline!(path, metrics) do
    payload = %{
      "version" => @baseline_version,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "note" =>
        "Topology census baseline written by PowerModel.Ingestion.Validation. " <>
          "Regenerate with `mix power_model.ingest validate --update-baseline` and commit " <>
          "the change together with the ingest change that caused it. " <>
          "buses_without_ba is a KNOWN-OPEN number, not a target: REVIEW DAT-23 owns it, " <>
          "and its fix will move this figure down and need this file regenerated in the " <>
          "same change. stranded_nameplate_mw / zero_capability_generator_buses / " <>
          "<ic>.degree_1_load_* are DAT-28's placement gate — they move when generator " <>
          "placement or load allocation degrades, which counts alone cannot see.",
      "metrics" => jsonable(metrics)
    }

    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(payload, pretty: true) <> "\n")
    Logger.info("Topology baseline written to #{path}")
    :ok
  end

  defp read_baseline!(path) do
    path |> File.read!() |> Jason.decode!()
  end

  defp jsonable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp jsonable(%_{} = struct), do: struct

  defp jsonable(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)
  end

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(other), do: other

  # --- diffing -------------------------------------------------------------

  defp tolerances(opts) do
    configured =
      :power_model
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:tolerances, %{})

    @default_tolerances
    |> Map.merge(configured)
    |> Map.merge(Keyword.get(opts || [], :tolerances, %{}))
  end

  defp diff_metrics(current, baseline, tol) do
    scalar_diffs =
      Enum.flat_map(@scalar_metric_directions, fn {key, direction} ->
        compare(
          Atom.to_string(key),
          baseline[Atom.to_string(key)],
          Map.get(current, key),
          direction,
          tol
        )
      end)

    scalar_diffs ++ interconnection_diffs(current, baseline, tol)
  end

  defp interconnection_diffs(current, baseline, tol) do
    base_ics = Map.get(baseline, "interconnections", %{})
    cur_ics = Map.get(current, :interconnections, %{})

    Enum.flat_map(base_ics, fn {ic_name, base_stats} ->
      case Map.get(cur_ics, ic_name) do
        nil ->
          [
            %{
              metric: "#{ic_name}.present",
              baseline: 1,
              current: 0,
              tolerance: 0,
              direction: :regression
            }
          ]

        stats ->
          Enum.flat_map(@interconnection_metric_directions, fn {key, direction} ->
            compare(
              "#{ic_name}.#{key}",
              base_stats[Atom.to_string(key)],
              Map.get(stats, key),
              direction,
              tol
            )
          end)
      end
    end)
  end

  defp compare(_metric, nil, _current, _direction, _tol), do: []
  defp compare(_metric, _baseline, nil, _direction, _tol), do: []

  defp compare(metric, baseline, current, direction, tol) do
    allowed = allowed_delta(metric, baseline, tol)
    delta = current - baseline

    healthy_move = if direction == :up, do: delta > 0, else: delta < 0

    cond do
      abs(delta) <= allowed ->
        []

      healthy_move ->
        [
          %{
            metric: metric,
            baseline: baseline,
            current: current,
            tolerance: allowed,
            direction: :improvement
          }
        ]

      true ->
        [
          %{
            metric: metric,
            baseline: baseline,
            current: current,
            tolerance: allowed,
            direction: :regression
          }
        ]
    end
  end

  defp allowed_delta(metric, baseline, tol) do
    if fraction_metric?(metric) do
      tol.fraction_absolute
    else
      max(tol.count_absolute, abs(baseline) * tol.count_relative)
    end
  end

  defp fraction_metric?(metric) do
    metric |> String.split(".") |> List.last() |> then(&(&1 in @fraction_metrics))
  end

  # ---------------------------------------------------------------------------
  # 4. Wave-2 stub: per-BA balance + capacity feasibility
  # ---------------------------------------------------------------------------

  @doc """
  Per-BA-fuel capacity feasibility and per-BA balance at screened hours.

  Two gates over `ba_fuel_hour` (ROADMAP Phase 1 item 5), both asking whether
  the ingested per-fuel series is consistent with the rest of the data.

  ## Capacity feasibility

  For each (BA, fuel) the seasonal peak of the measured net generation is
  compared against the summed capability of that BA's in-service units of
  that fuel — summer capability against the June–September peak, winter
  capability against the rest, falling back to `p_max_mw` on units where the
  seasonal columns are still NULL. Units are bucketed by the same
  `PowerModel.Dispatch.fuel_for/1` mapping the dispatcher uses, so a group
  the gate calls feasible is a group the dispatcher can actually fill.

  A shortfall means the modeled fleet cannot produce what the measurement
  says the real fleet produced, and the missing MW go nowhere at dispatch
  time (REVIEW ENE-15). Today that is dominated by fleet mapping rather than
  by a bad ingest, so the gate FAILS only when the aggregate shortfall share
  crosses `:capacity_fail_share` — a ratchet against a re-ingest that loses
  BA mapping — and warns on the individual groups. Measured 2026-08-15:
  0.168 shortfall share (311.8 GW), 202 of 565 (BA, fuel, season) groups
  short, 95 of them beyond 2x. No unit yet carries a seasonal capability, so
  today's bound is nameplate and the real shortfall is larger.

  ## Balance

  On each BA-hour the identity is `generation - demand = total_interchange`,
  and the generation term is the SUM of the per-fuel columns — the series
  `PowerModel.Dispatch` places. A BA-hour CLOSES when
  `|Σ ba_fuel_hour − (demand + interchange)|` lands inside
  `PowerModel.Demand.identity_tolerance/0`; everything else is a finding,
  because those are the MW dispatch will place against an obligation they do
  not match.

  This module no longer carries a screen of its own. REVIEW ENE-22 recorded
  the two disagreeing at runtime and suspected a sign or column divergence; it
  was neither — the formula was the same and the TOLERANCE was not (1% here,
  5% in `Demand`), which is why the same rows produced MISO 5/4,389 in one
  report and 4,389/4,389 in the other. Both now read
  `PowerModel.Demand.identity_closure_by_ba/0`.

  REVIEW ENE-23 is why the identity is stated on the fuel sum rather than on
  EIA's `net_generation` column: screening on `net_generation` threw away the
  hours where the two disagree, which is exactly where the defect lives. WALC
  closes `net_generation` on 99.5% of its 4,368 hours and its fuel sum on
  31.3%, running +202 MW long on average — invisible to a net-generation
  screen, and a fifth of its own demand at dispatch time. EIA's own column is
  still reported per BA as `eia_closure_rate`, so the two can be told apart.

  Measured 2026-08-16 nationally over 231,838 BA-hours: 95.1% close on the
  fuel sum, 97.1% on `net_generation`. `broken_identity_bas/0` screens in BPAT
  (0 of 4,417, mean residual −4,315 MW) and WALC; next-worst IID at 60.8%.
  `PowerModel.Dispatch` anchors a screened BA's generation budget on
  `demand + interchange` (REVIEW ENE-20).

  ## Options

  Merged over the defaults below, from `:capacity_and_balance` in the opts or
  in `config :power_model, PowerModel.Ingestion.Validation`:

      #{inspect(%{capacity_slack: 0.05, capacity_min_mw: 100.0, capacity_fail_ratio: 2.0, capacity_fail_share: 0.35, balance_fail_share: 0.1}, pretty: true)}

  The balance tolerance is NOT among them: it belongs to the one identity
  implementation in `PowerModel.Demand`, and a second knob here is how the two
  drifted apart in the first place.
  """
  def capacity_and_balance(opts \\ []) do
    settings = fuel_gate_settings(opts)

    if Repo.exists?(from(f in BAFuelHour)) do
      capacity = capacity_feasibility(settings)
      balance = balance_by_ba()

      report(:capacity_and_balance, %{capacity: capacity, balance: balance, settings: settings},
        warnings: capacity_warnings(capacity, settings) ++ balance_warnings(balance),
        failures: capacity_failures(capacity, settings) ++ balance_failures(balance, settings)
      )
    else
      report(
        :capacity_and_balance,
        %{
          reason:
            "ba_fuel_hour is empty — run `mix power_model.ingest demand` to load the " <>
              "per-fuel columns of the EIA-930 balance files"
        },
        status: :skipped
      )
    end
  end

  @default_fuel_gates %{
    # A shortfall inside this fraction of capability is seasonal-derate noise.
    capacity_slack: 0.05,
    # Below this peak a BA-fuel is a rounding error, not a fleet.
    capacity_min_mw: 100.0,
    # Peak beyond this multiple of capability is called out individually.
    capacity_fail_ratio: 2.0,
    # Aggregate shortfall share that fails the gate (measured 0.200).
    capacity_fail_share: 0.35,
    # Share of BA-hours whose fuel-sum identity does not close that fails the
    # gate (measured 0.049 nationally on 2026-08-16). The tolerance itself is
    # `PowerModel.Demand.identity_tolerance/0` — see the moduledoc for why
    # there is no second copy of it here.
    balance_fail_share: 0.10
  }

  defp fuel_gate_settings(opts) do
    configured =
      :power_model
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:capacity_and_balance, %{})

    @default_fuel_gates
    |> Map.merge(configured)
    |> Map.merge(Keyword.get(opts || [], :capacity_and_balance, %{}))
  end

  # --- capacity feasibility -------------------------------------------------

  defp capacity_feasibility(settings) do
    capability = ba_fuel_capability()
    groups = Enum.map(seasonal_peaks(), &feasibility_row(&1, capability, settings))

    short = Enum.filter(groups, & &1.short?)

    # Only flagged groups count toward the aggregate: a shortfall inside the
    # seasonal slack, or on a group too small to be a fleet, is noise the
    # gate has already decided to ignore, and it must not creep into the
    # share that fails the run.
    shortfall_mw = sum_by(short, & &1.shortfall_mw)
    peak_sum_mw = sum_by(groups, &max(&1.peak_mw, 0.0))

    %{
      ba_fuels: length(groups),
      seasonal_capability_units: seasonal_capability_units(),
      short: length(short),
      short_beyond_fail_ratio:
        Enum.count(short, &(&1.ratio == nil or &1.ratio > settings.capacity_fail_ratio)),
      shortfall_mw: shortfall_mw,
      peak_sum_mw: peak_sum_mw,
      shortfall_share: safe_fraction(shortfall_mw, peak_sum_mw),
      worst: short |> Enum.sort_by(&(-&1.shortfall_mw)) |> Enum.take(15)
    }
  end

  defp feasibility_row({ba_code, fuel, season, peak_mw}, capability, settings) do
    capability_mw = get_in(capability, [{ba_code, fuel}, season]) || 0.0
    allowed = capability_mw * (1.0 + settings.capacity_slack)

    %{
      ba_code: ba_code,
      fuel: fuel,
      season: season,
      peak_mw: peak_mw,
      capability_mw: capability_mw,
      units: get_in(capability, [{ba_code, fuel}, :units]) || 0,
      ratio: if(capability_mw > 0.0, do: peak_mw / capability_mw),
      shortfall_mw: max(peak_mw - capability_mw, 0.0),
      short?: peak_mw > allowed and peak_mw > settings.capacity_min_mw
    }
  end

  # Seasonal peak of measured net generation per (BA, fuel). EIA's summer
  # capability season is June-September; everything else is rated on winter
  # capability, matching PowerModel.Dispatch.
  defp seasonal_peaks do
    Repo.all(
      from f in BAFuelHour,
        group_by: [
          f.ba_code,
          f.fuel,
          fragment("extract(month from ?) between 6 and 9", f.timestamp_utc)
        ],
        select:
          {f.ba_code, f.fuel, fragment("extract(month from ?) between 6 and 9", f.timestamp_utc),
           max(f.net_generation_mw)}
    )
    |> Enum.map(fn {ba_code, fuel, summer?, peak} ->
      {ba_code, fuel, if(summer?, do: :summer, else: :winter), peak || 0.0}
    end)
  end

  # In-service capability per (BA code, EIA-930 fuel column), bucketed by the
  # dispatcher's own fuel mapping so the two agree on what a group contains.
  defp ba_fuel_capability do
    from(g in Generator,
      join: b in Bus,
      on: b.id == g.bus_id,
      join: ba in BalancingAuthority,
      on: ba.id == b.balancing_authority_id,
      where: g.status == "in_service",
      select: %{
        ba_code: ba.code,
        fuel_type: g.fuel_type,
        prime_mover: g.prime_mover,
        p_max_mw: g.p_max_mw,
        summer_capacity_mw: g.summer_capacity_mw,
        winter_capacity_mw: g.winter_capacity_mw
      }
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn generator, acc ->
      key = {generator.ba_code, Dispatch.fuel_for(generator)}
      summer = generator.summer_capacity_mw || generator.p_max_mw || 0.0
      winter = generator.winter_capacity_mw || summer

      Map.update(
        acc,
        key,
        %{summer: summer, winter: winter, units: 1},
        &%{&1 | summer: &1.summer + summer, winter: &1.winter + winter, units: &1.units + 1}
      )
    end)
  end

  defp seasonal_capability_units do
    Repo.one(
      from g in Generator,
        where: g.status == "in_service" and not is_nil(g.summer_capacity_mw),
        select: count(g.id)
    )
  end

  defp capacity_warnings(capacity, settings) do
    []
    |> maybe_warn(
      capacity.seasonal_capability_units == 0,
      "No in-service generator carries a summer capability; feasibility is bounded by " <>
        "nameplate, which EIA-860 puts about 83 GW above real national summer capability."
    )
    |> maybe_warn(
      capacity.short > 0,
      "#{capacity.short} of #{capacity.ba_fuels} (BA, fuel) groups peak above the mapped " <>
        "fleet's capability (#{fmt_gw(capacity.shortfall_mw)} GW total, " <>
        "#{percent(capacity.shortfall_share)} of summed peaks; " <>
        "#{capacity.short_beyond_fail_ratio} beyond #{settings.capacity_fail_ratio}x). " <>
        "Those MW have no unit to sit on at dispatch time — REVIEW ENE-15. Worst: " <>
        describe_groups(capacity.worst)
    )
    |> Enum.reverse()
  end

  defp capacity_failures(capacity, settings) do
    if is_number(capacity.shortfall_share) and
         capacity.shortfall_share > settings.capacity_fail_share do
      [
        "Capacity feasibility: #{percent(capacity.shortfall_share)} of summed BA-fuel peaks " <>
          "cannot be produced by the mapped fleet, past the " <>
          "#{percent(settings.capacity_fail_share)} gate. Either BA mapping regressed or the " <>
          "fleet ingest is short — check `mix power_model.ingest map_bas` and generators."
      ]
    else
      []
    end
  end

  defp describe_groups(groups) do
    Enum.map_join(Enum.take(groups, 6), ", ", fn g ->
      "#{g.ba_code}/#{g.fuel} #{fmt_gw(g.peak_mw)} GW #{g.season} peak vs " <>
        "#{fmt_gw(g.capability_mw)} GW on #{g.units} units"
    end)
  end

  # --- balance ---------------------------------------------------------------

  # Everything here is a projection of the ONE identity measurement in
  # `PowerModel.Demand` (ENE-22/ENE-23). `screened_rows` are the BA-hours whose
  # fuel-sum identity closes, `out_of_tolerance` the ones that do not; there is
  # no second tier, because with one identity a hour is either reproduced or
  # it is a finding.
  defp balance_by_ba do
    closure = Demand.identity_closure_by_ba()
    screened_ids = closure |> Demand.broken_identity_bas() |> Map.keys() |> MapSet.new()

    by_ba =
      closure
      |> Enum.map(fn {ba_id, s} ->
        %{
          ba_id: ba_id,
          ba_code: s.ba_code,
          rows: s.hours,
          screened: s.closed,
          screened_share: s.closure_rate,
          out_of_tolerance: s.hours - s.closed,
          mean_residual_mw: s.mean_abs_residual_mw,
          max_residual_mw: s.max_residual_mw,
          mean_error_mw: s.mean_error_mw,
          eia_screened: s.eia_closed,
          eia_screened_share: s.eia_closure_rate
        }
      end)
      |> Enum.sort_by(& &1.ba_code)

    rows_total = sum_by(by_ba, & &1.rows)
    screened = sum_by(by_ba, & &1.screened)
    out = sum_by(by_ba, & &1.out_of_tolerance)

    %{
      bas: length(by_ba),
      bas_without_fuel_rows: bas_without_fuel_rows(),
      rows: rows_total,
      screened_rows: screened,
      screened_share: safe_fraction(screened, rows_total),
      eia_screened_rows: sum_by(by_ba, & &1.eia_screened),
      eia_screened_share: safe_fraction(sum_by(by_ba, & &1.eia_screened), rows_total),
      out_of_tolerance: out,
      out_of_tolerance_share: safe_fraction(out, rows_total),
      mean_residual_mw:
        safe_fraction(sum_by(by_ba, &(&1.mean_residual_mw * &1.out_of_tolerance)), out),
      # Exactly the set `PowerModel.Dispatch` anchor-corrects: the identity
      # screen's own output, not a second threshold that happens to resemble it.
      barely_screened:
        by_ba
        |> Enum.filter(&MapSet.member?(screened_ids, &1.ba_id))
        |> Enum.sort_by(& &1.screened_share),
      worst:
        by_ba
        |> Enum.filter(&(&1.out_of_tolerance > 0))
        |> Enum.sort_by(&(-&1.mean_residual_mw))
        |> Enum.take(10)
    }
  end

  # BAs with demand rows but no per-fuel series at all: EIA does not publish
  # a fuel breakdown for every BA, so this is context, not a defect.
  defp bas_without_fuel_rows do
    Repo.all(
      from ba in BalancingAuthority,
        join: d in BADemandHour,
        on: d.balancing_authority_id == ba.id,
        left_join: f in BAFuelHour,
        on: f.ba_code == ba.code,
        where: is_nil(f.id),
        distinct: true,
        select: ba.code
    )
  end

  defp balance_warnings(balance) do
    []
    |> maybe_warn(
      balance.bas_without_fuel_rows != [],
      "#{length(balance.bas_without_fuel_rows)} BA(s) report demand but no per-fuel " <>
        "generation: #{Enum.join(Enum.take(balance.bas_without_fuel_rows, 10), ", ")}. " <>
        "Their generation cannot be anchored to a fuel and falls to the island fallback."
    )
    |> maybe_warn(
      is_number(balance.eia_screened_share) and
        balance.eia_screened_share - balance.screened_share > 0.01,
      "EIA's own net_generation column closes on #{percent(balance.eia_screened_share)} of " <>
        "BA-hours but the per-fuel SUM closes on only #{percent(balance.screened_share)}. " <>
        "The gap is the part of the data a net_generation screen cannot see, and the " <>
        "per-fuel columns are the ones dispatch places (REVIEW ENE-23)."
    )
    |> maybe_warn(
      balance.barely_screened != [],
      "#{length(balance.barely_screened)} BA(s) fail the generation identity on more than " <>
        "half their hours, so most of their data cannot be validated at all and dispatch " <>
        "anchors them on demand + interchange instead (REVIEW ENE-20): " <>
        Enum.map_join(Enum.take(balance.barely_screened, 6), ", ", fn b ->
          "#{b.ba_code} #{b.screened}/#{b.rows} (#{percent(b.screened_share)}, EIA's own " <>
            "column #{percent(b.eia_screened_share)})"
        end)
    )
    |> maybe_warn(
      balance.out_of_tolerance > 0,
      "#{balance.out_of_tolerance} of #{balance.rows} BA-hours " <>
        "(#{percent(balance.out_of_tolerance_share)}) do not balance: summed per-fuel " <>
        "generation minus demand minus interchange exceeds " <>
        "max(#{tolerance_mw()} MW, #{percent(tolerance_rel())}), mean residual " <>
        "#{round1(balance.mean_residual_mw || 0.0)} MW. Worst: " <>
        describe_balance(balance.worst)
    )
    |> Enum.reverse()
  end

  defp tolerance_mw, do: Demand.identity_tolerance() |> elem(0)
  defp tolerance_rel, do: Demand.identity_tolerance() |> elem(1)

  defp balance_failures(balance, settings) do
    if is_number(balance.out_of_tolerance_share) and
         balance.out_of_tolerance_share > settings.balance_fail_share do
      [
        "Per-BA balance: #{percent(balance.out_of_tolerance_share)} of BA-hours do " <>
          "not close, past the #{percent(settings.balance_fail_share)} gate. The per-fuel " <>
          "columns of EIA-930 are being read wrong (see REVIEW ENE-16 for the last time " <>
          "this happened) — re-check the Form 930 field resolver."
      ]
    else
      []
    end
  end

  defp describe_balance(worst) do
    Enum.map_join(Enum.take(worst, 6), ", ", fn b ->
      "#{b.ba_code} #{b.out_of_tolerance}/#{b.rows} rows, mean " <>
        "#{round1(b.mean_residual_mw || 0.0)} MW"
    end)
  end

  defp sum_by(list, fun), do: list |> Enum.map(fun) |> Enum.sum()

  defp fmt_gw(mw), do: Float.round(mw / 1000.0, 1)

  # ---------------------------------------------------------------------------
  # Report plumbing / rendering
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # 5. Reactive study freshness (DAT-30 / DAT-31)
  # ---------------------------------------------------------------------------

  @doc """
  Whether `priv/reactive_planning/reactive_support_banks.json` still describes
  the network it is about to be applied to.

  The study is a MEASURED result: which generator buses run out of vars is a
  property of a solved power flow, so it is only valid for the network it was
  solved on. On 2026-08-19 it was applied to a network the OSM voltage
  backfill had restamped underneath it, and the pipeline did not notice — the
  drift surfaced only because 60 bank keys stopped resolving, a symptom that
  is loud by luck and would have been silent had the ids survived while an
  impedance moved.

  This is the HARD gate for that. `ParameterEstimator` only warns, because a
  hard stop inside the ingest pipeline would be worse than slightly-stale
  banks; failing belongs here, where CI reads it and nothing is half-written.

  Absent study: warn, not fail — a checkout without the artifact still
  ingests, and the estimator falls back to no banks. Unstamped study: warn,
  because "unknown" is not "stale". Drifted study: FAIL, with
  `mix power_model.reactive_study` named as the fix.
  """
  def reactive_study_freshness(opts \\ []) do
    path =
      Keyword.get_lazy(opts, :study_path, fn ->
        PowerModel.Ingestion.ParameterEstimator.generator_support_study_path()
      end)

    case read_study(path) do
      {:error, reason} ->
        report(:reactive_study, %{path: path, present: false, drift: nil},
          warnings: [
            "No reactive support study at #{path} (#{reason}). Generator support banks " <>
              "will not be placed; derive one with `mix power_model.reactive_study`."
          ]
        )

      {:ok, study} ->
        check_study(study, path)
    end
  end

  # ---------------------------------------------------------------------------
  # 6. At-rest loading (CAS-26 / CAS-30)
  # ---------------------------------------------------------------------------

  @doc """
  How much of each interconnection's main island is over its rating with
  nothing out of service, at the measured dispatch of `:hour` (default: the
  latest ingested hour).

  A branch at several times its rating at rest is not an overload — the real
  grid carries this load — it is capacity the model lacks along that corridor
  (REVIEW CAS-30), and it is why no AC solution existed at real demand and why
  contingency response was binary (CAS-26). `CapacityInference.run/1` infers
  the missing circuits; this check is what says whether it has been run and
  whether the network has drifted since. Warns on any rated branch over 100 %;
  fails when more than #{"0.5"} % of rated branches are.
  """
  def at_rest_loading(opts \\ []) do
    if Grid.bus_count() == 0 do
      report(:at_rest_loading, %{interconnections: %{}, hour: nil}, status: :skipped)
    else
      hour = Keyword.get_lazy(opts, :hour, &Demand.latest_demand_hour/0)

      per =
        Map.new(Repo.all(from(i in Interconnection, order_by: i.name)), fn ic ->
          snap = Grid.get_grid_snapshot(ic.id, hour: hour)

          if snap.buses == [] do
            {ic.name, nil}
          else
            state = Cascade.init(snap, 100.0, hour: hour)

            {subs, _dead} =
              Partition.split(%{
                buses: state.buses,
                lines: state.lines,
                transformers: state.transformers,
                generators: Cascade.dispatched_generators(state),
                loads: state.loads
              })

            case subs do
              [] ->
                {ic.name, nil}

              _ ->
                island = Enum.max_by(subs, &length(&1.buses))
                r = CapacityInference.at_rest_loading(island, limit: 5)

                {ic.name,
                 %{
                   rated: r.rated,
                   over_100: r.over[100],
                   over_200: r.over[200],
                   overload_mw: Float.round(r.overload_mw, 1),
                   worst: r.worst
                 }}
            end
          end
        end)

      {warnings, failures} =
        Enum.reduce(per, {[], []}, fn
          {_name, nil}, acc ->
            acc

          {name, %{rated: rated, over_100: over, overload_mw: mw}}, {w, f} ->
            frac = if rated > 0, do: over / rated, else: 0.0

            cond do
              frac > @at_rest_fail_fraction ->
                {w,
                 [
                   "#{name}: #{over} of #{rated} rated branches over their rating at rest " <>
                     "(#{Float.round(frac * 100, 2)} %, #{round(mw)} MW of overload) — run " <>
                     "`CapacityInference.run/1` (REVIEW CAS-30)"
                   | f
                 ]}

              over > 0 ->
                {[
                   "#{name}: #{over} rated branch(es) over their rating at rest " <>
                     "(#{round(mw)} MW); the network has drifted since capacity was inferred"
                   | w
                 ], f}

              true ->
                {w, f}
            end
        end)

      report(:at_rest_loading, %{interconnections: per, hour: hour && DateTime.to_iso8601(hour)},
        warnings: Enum.reverse(warnings),
        failures: Enum.reverse(failures)
      )
    end
  end

  # A study can only be stale RELATIVE TO a network. On a database with no
  # buses there is nothing to apply it to, so the honest answer is `:skipped`,
  # not `:error`.
  #
  # This is not a test convenience. Without it the gate fails on every fresh
  # checkout, every CI run against an un-ingested database, and every
  # colleague's machine — and a gate that fires when nothing is wrong is one
  # people learn to route around, which is the exact failure the digest choice
  # was made to avoid.
  defp check_study(study, path) do
    # `bus_count/0`, not `network_signature/0`: the full signature hashes five
    # whole tables, and `evaluate_study/2` computes it again a line later.
    if Grid.bus_count() == 0 do
      report(
        :reactive_study,
        %{
          path: path,
          present: true,
          measured_on: study["measured_on"],
          drift: nil,
          skipped: true
        },
        status: :skipped
      )
    else
      evaluate_study(study, path)
    end
  end

  defp evaluate_study(study, path) do
    drift = Grid.network_signature_drift(study["inputs"])

    metrics = %{
      path: path,
      present: true,
      measured_on: study["measured_on"],
      banks: length(study["banks"] || []),
      drift: if(drift == [:unstamped], do: ["unstamped"], else: drift)
    }

    cond do
      drift == [] ->
        report(:reactive_study, metrics, [])

      drift == [:unstamped] ->
        report(:reactive_study, metrics,
          warnings: [
            "Reactive support study (#{study["measured_on"] || "undated"}) carries no " <>
              "`inputs` signature, so whether it matches this network cannot be checked. " <>
              "Re-derive with `mix power_model.reactive_study` to stamp it."
          ]
        )

      true ->
        report(:reactive_study, metrics,
          failures: [
            "Reactive support study (#{study["measured_on"] || "undated"}) was measured " <>
              "against a DIFFERENT network than the one it is applied to, so its " <>
              "shortfalls are not this network's. Re-derive with " <>
              "`mix power_model.reactive_study`. Drift: " <>
              Enum.join(Enum.take(drift, 5), "; ")
          ]
        )
    end
  end

  defp read_study(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"banks" => _} = study} <- Jason.decode(body) do
      {:ok, study}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "not valid JSON"}
      {:ok, _} -> {:error, "no `banks` key"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp report(check, metrics, opts) do
    warnings = Keyword.get(opts, :warnings, [])
    failures = Keyword.get(opts, :failures, [])

    status =
      Keyword.get_lazy(opts, :status, fn ->
        cond do
          failures != [] -> :error
          warnings != [] -> :warn
          true -> :ok
        end
      end)

    status = if failures != [], do: :error, else: status

    Enum.each(failures, &Logger.error("[validate #{check}] #{&1}"))
    Enum.each(warnings, &Logger.warning("[validate #{check}] #{&1}"))

    report = %{
      check: check,
      status: status,
      metrics: metrics,
      warnings: warnings,
      failures: failures
    }

    {if(failures == [], do: :ok, else: :error), report}
  end

  defp maybe_warn(warnings, false, _message), do: warnings
  defp maybe_warn(warnings, true, message), do: [message | warnings]

  @doc """
  Render a `run/1` summary as a printable table plus the warning and failure
  detail beneath it.
  """
  def summary_table(%{checks: checks} = summary) do
    rows = Enum.map(checks, &{status_marker(&1.status), &1.check, headline(&1)})

    check_width =
      rows |> Enum.map(fn {_m, c, _h} -> String.length(to_string(c)) end) |> Enum.max()

    body =
      Enum.map_join(rows, "\n", fn {marker, check, headline} ->
        "  #{marker} #{String.pad_trailing(to_string(check), check_width)}  #{headline}"
      end)

    detail =
      [
        detail_block("FAILURES", summary.failures),
        detail_block("WARNINGS", summary.warnings)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    header = "Ingest validation — #{String.upcase(to_string(summary.status))}\n"

    String.trim_trailing(header <> body <> "\n" <> detail)
  end

  defp detail_block(_label, []), do: ""

  defp detail_block(label, messages) do
    "\n#{label}:\n" <> Enum.map_join(messages, "\n", &("  - " <> &1))
  end

  defp status_marker(:ok), do: "[ ok ]"
  defp status_marker(:warn), do: "[warn]"
  defp status_marker(:error), do: "[FAIL]"
  defp status_marker(:skipped), do: "[skip]"
  defp status_marker(:baseline_written), do: "[base]"

  defp headline(%{check: :hour_completeness, metrics: m}) do
    case m do
      %{hours_total: 0} ->
        "no demand rows"

      %{} ->
        "#{m.hours_total} hours, modal #{m.modal_reporting_bas} BAs, " <>
          "#{m.incomplete_hours} incomplete, latest complete #{format_ts(m.latest_complete_hour)}"
    end
  end

  defp headline(%{check: :egrid_vintage, metrics: m}) do
    "eGRID #{m.egrid_year || "?"} vs EIA-860 #{m.eia860_year || "?"}"
  end

  defp headline(%{check: :topology_census, metrics: m}) do
    ics =
      m
      |> Map.get(:interconnections, %{})
      |> Enum.sort_by(fn {_name, s} -> -s.geolocated_bus_count end)
      |> Enum.map_join(", ", fn {name, s} ->
        "#{name} #{percent(s.largest_component_fraction)} largest"
      end)

    "#{m.bus_count} buses / #{m.line_count} lines / #{m.generator_count} gens; " <> ics
  end

  defp headline(%{check: :capacity_and_balance, metrics: %{reason: reason}}), do: reason

  defp headline(%{check: :capacity_and_balance, metrics: m}) do
    "#{m.capacity.short}/#{m.capacity.ba_fuels} BA-fuels short " <>
      "(#{percent(m.capacity.shortfall_share)} of peaks); " <>
      "#{percent(m.balance.out_of_tolerance_share)} of #{m.balance.rows} " <>
      "BA-hours unbalanced on the fuel sum"
  end

  defp headline(%{check: :reactive_study, metrics: %{present: false}}), do: "no study file"

  defp headline(%{check: :reactive_study, metrics: %{skipped: true}}),
    do: "no network ingested — nothing to apply the study to"

  defp headline(%{check: :reactive_study, metrics: m}) do
    state =
      case m.drift do
        [] -> "matches this network"
        ["unstamped"] -> "unstamped, cannot be checked"
        drift -> "STALE (#{length(drift)} difference(s))"
      end

    "#{m.banks} banks measured #{m.measured_on || "?"}; #{state}"
  end

  defp headline(%{check: check}), do: to_string(check)

  defp percent(nil), do: "n/a"
  defp percent(fraction), do: "#{Float.round(fraction * 100, 1)}%"

  defp round1(value), do: Float.round(value * 1.0, 1)
end
