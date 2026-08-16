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
      a bus, and per-interconnection connectivity (share of geolocated buses
      carrying a branch, and largest-component share). The first run writes
      the baseline; later runs fail on regression beyond the configured
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

  alias PowerModel.Demand.{BADemandHour, BAFuelHour}
  alias PowerModel.Dispatch

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
    generators_without_bus: :down
  }

  @interconnection_metric_directions %{
    geolocated_bus_count: :up,
    connected_bus_count: :up,
    connected_fraction: :up,
    component_count: :down,
    largest_component_bus_count: :up,
    largest_component_fraction: :up
  }

  @fraction_metrics ~w(connected_fraction largest_component_fraction)

  @doc """
  Run every gate. Returns `{:ok, summary}` when no check failed,
  `{:error, summary}` otherwise. Warnings never fail the run.
  """
  def run(opts \\ []) do
    checks = [
      hour_completeness(opts),
      egrid_vintage(opts),
      topology_census(opts),
      capacity_and_balance(opts)
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
    |> Map.put(:interconnections, interconnection_connectivity())
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
          "the change together with the ingest change that caused it.",
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

  ## Balance at screened hours

  On each BA-hour the identity is `generation - demand = total_interchange`.
  Rows are SCREENED on EIA's own numbers first (`|net_generation -
  (demand + interchange)| <= tolerance`), because EIA's published trio does
  not close on every row — measured 4.0% of rows off by more than 1 GW — and
  scoring our ingest against an hour EIA itself cannot balance measures
  nothing. On the rows that survive, `Σ ba_fuel_hour - demand -
  total_interchange` must stay inside the same tolerance; a systematic
  residual means the per-fuel columns are being read wrong (the ENE-16 class
  of bug), not that the grid failed to balance. Measured 2026-08-15: 94.5% of
  rows screened in, 4.0% of those out of tolerance (mean residual 53.5 MW,
  concentrated in PJM).

  WHICH BAs fail EIA's own identity is a measurement, not a list. The ENE-16
  re-ingest changed the answer: at a 5% tolerance MISO now closes 4,389 of
  4,389 hours and CISO 2,090 of 2,473 (84.5%), while **BPAT still closes 0 of
  4,417** (mean residual -4,317 MW, sd 725 — a systematic bias, not noise) and
  is the one BA about which almost nothing can be validated. The next-worst is
  IID at 60.9%. `PowerModel.Demand.broken_identity_bas/0` re-runs that screen
  per call, and is what `PowerModel.Dispatch` anchors a broken BA's generation
  budget on `demand + interchange` from (REVIEW ENE-20). Re-measured
  2026-08-15 after ENE-16.

  ## Options

  Merged over the defaults below, from `:capacity_and_balance` in the opts or
  in `config :power_model, PowerModel.Ingestion.Validation`:

      #{inspect(%{capacity_slack: 0.05, capacity_min_mw: 100.0, capacity_fail_ratio: 2.0, capacity_fail_share: 0.35, balance_tolerance_mw: 50.0, balance_tolerance_rel: 0.01, screen_tolerance_mw: 50.0, screen_tolerance_rel: 0.01, balance_fail_share: 0.1}, pretty: true)}
  """
  def capacity_and_balance(opts \\ []) do
    settings = fuel_gate_settings(opts)

    if Repo.exists?(from(f in BAFuelHour)) do
      capacity = capacity_feasibility(settings)
      balance = balance_at_screened_hours(settings)

      report(:capacity_and_balance, %{capacity: capacity, balance: balance, settings: settings},
        warnings: capacity_warnings(capacity, settings) ++ balance_warnings(balance, settings),
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
    balance_tolerance_mw: 50.0,
    balance_tolerance_rel: 0.01,
    screen_tolerance_mw: 50.0,
    screen_tolerance_rel: 0.01,
    # Share of screened rows out of tolerance that fails (measured 0.039).
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

  # --- balance at screened hours --------------------------------------------

  # One pass in SQL: 1.2M per-fuel rows summed per BA-hour and joined to the
  # demand row, aggregated per BA so only a few dozen rows come back.
  @balance_sql """
  WITH fuel AS (
    SELECT ba_code, timestamp_utc, sum(net_generation_mw) AS gen_mw
    FROM ba_fuel_hour GROUP BY 1, 2
  ),
  joined AS (
    SELECT ba.code AS code, d.timestamp_utc AS hour, d.demand_mw, d.net_generation_mw AS ng,
           d.total_interchange_mw AS ti, fuel.gen_mw,
           abs(d.net_generation_mw - (d.demand_mw + d.total_interchange_mw)) AS eia_residual,
           abs(fuel.gen_mw - d.demand_mw - d.total_interchange_mw) AS residual,
           greatest($1, $2 * abs(d.net_generation_mw)) AS tolerance,
           greatest($3, $4 * abs(d.demand_mw)) AS screen
    FROM ba_demand_hourly d
    JOIN balancing_authorities ba ON ba.id = d.balancing_authority_id
    JOIN fuel ON fuel.ba_code = ba.code AND fuel.timestamp_utc = d.timestamp_utc
    WHERE d.net_generation_mw IS NOT NULL AND d.total_interchange_mw IS NOT NULL
      AND d.demand_mw IS NOT NULL
  )
  SELECT code,
         count(*),
         count(*) FILTER (WHERE eia_residual <= screen),
         count(*) FILTER (WHERE eia_residual <= screen AND residual > tolerance),
         coalesce(sum(residual) FILTER (WHERE eia_residual <= screen), 0),
         coalesce(max(residual) FILTER (WHERE eia_residual <= screen), 0)
  FROM joined GROUP BY code ORDER BY code
  """

  defp balance_at_screened_hours(settings) do
    {:ok, %{rows: rows}} =
      Repo.query(@balance_sql, [
        settings.balance_tolerance_mw,
        settings.balance_tolerance_rel,
        settings.screen_tolerance_mw,
        settings.screen_tolerance_rel
      ])

    by_ba =
      Enum.map(rows, fn [code, rows_n, screened, out, residual_sum, residual_max] ->
        %{
          ba_code: code,
          rows: rows_n,
          screened: screened,
          out_of_tolerance: out,
          mean_residual_mw: safe_fraction(to_float(residual_sum), screened),
          max_residual_mw: to_float(residual_max)
        }
      end)

    rows_total = sum_by(by_ba, & &1.rows)
    screened = sum_by(by_ba, & &1.screened)
    out = sum_by(by_ba, & &1.out_of_tolerance)

    %{
      bas: length(by_ba),
      bas_without_fuel_rows: bas_without_fuel_rows(),
      rows: rows_total,
      screened_rows: screened,
      screened_share: safe_fraction(screened, rows_total),
      out_of_tolerance: out,
      out_of_tolerance_share: safe_fraction(out, screened),
      mean_residual_mw:
        safe_fraction(sum_by(by_ba, &((&1.mean_residual_mw || 0.0) * &1.screened)), screened),
      # BAs whose own EIA trio rarely closes: nothing downstream can be
      # validated against them, so the screen throws most of their hours away.
      barely_screened:
        by_ba
        |> Enum.filter(&(&1.rows > 100 and safe_fraction(&1.screened, &1.rows) < 0.5))
        |> Enum.sort_by(&safe_fraction(&1.screened, &1.rows))
        |> Enum.map(&Map.put(&1, :screened_share, safe_fraction(&1.screened, &1.rows))),
      worst:
        by_ba
        |> Enum.filter(&(&1.out_of_tolerance > 0))
        |> Enum.sort_by(&(-(&1.mean_residual_mw || 0.0)))
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

  defp balance_warnings(balance, settings) do
    []
    |> maybe_warn(
      balance.bas_without_fuel_rows != [],
      "#{length(balance.bas_without_fuel_rows)} BA(s) report demand but no per-fuel " <>
        "generation: #{Enum.join(Enum.take(balance.bas_without_fuel_rows, 10), ", ")}. " <>
        "Their generation cannot be anchored to a fuel and falls to the island fallback."
    )
    |> maybe_warn(
      is_number(balance.screened_share) and balance.screened_share < 0.8,
      "Only #{percent(balance.screened_share)} of BA-hours pass the EIA identity screen " <>
        "(|net_generation - demand - interchange| <= " <>
        "max(#{settings.screen_tolerance_mw} MW, #{percent(settings.screen_tolerance_rel)})). " <>
        "EIA's own trio is that inconsistent, or the demand ingest is misaligned."
    )
    |> maybe_warn(
      balance.barely_screened != [],
      "#{length(balance.barely_screened)} BA(s) fail EIA's OWN generation identity on more " <>
        "than half their hours, so most of their data cannot be validated at all: " <>
        Enum.map_join(Enum.take(balance.barely_screened, 6), ", ", fn b ->
          "#{b.ba_code} #{b.screened}/#{b.rows} (#{percent(b.screened_share)})"
        end)
    )
    |> maybe_warn(
      balance.out_of_tolerance > 0,
      "#{balance.out_of_tolerance} of #{balance.screened_rows} screened BA-hours " <>
        "(#{percent(balance.out_of_tolerance_share)}) do not balance: summed per-fuel " <>
        "generation minus demand minus interchange exceeds tolerance, mean residual " <>
        "#{round1(balance.mean_residual_mw || 0.0)} MW. Worst: " <>
        describe_balance(balance.worst)
    )
    |> Enum.reverse()
  end

  defp balance_failures(balance, settings) do
    if is_number(balance.out_of_tolerance_share) and
         balance.out_of_tolerance_share > settings.balance_fail_share do
      [
        "Per-BA balance: #{percent(balance.out_of_tolerance_share)} of screened BA-hours do " <>
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
      "#{b.ba_code} #{b.out_of_tolerance}/#{b.screened} rows, mean " <>
        "#{round1(b.mean_residual_mw || 0.0)} MW"
    end)
  end

  defp sum_by(list, fun), do: list |> Enum.map(fun) |> Enum.sum()

  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(value), do: value

  defp fmt_gw(mw), do: Float.round(mw / 1000.0, 1)

  # ---------------------------------------------------------------------------
  # Report plumbing / rendering
  # ---------------------------------------------------------------------------

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
      "#{percent(m.balance.out_of_tolerance_share)} of #{m.balance.screened_rows} " <>
      "screened BA-hours unbalanced"
  end

  defp headline(%{check: check}), do: to_string(check)

  defp percent(nil), do: "n/a"
  defp percent(fraction), do: "#{Float.round(fraction * 100, 1)}%"

  defp round1(value), do: Float.round(value * 1.0, 1)
end
