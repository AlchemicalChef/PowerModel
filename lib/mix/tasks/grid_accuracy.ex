defmodule Mix.Tasks.Grid.Accuracy do
  @moduledoc """
  Network accuracy scoreboard — ROADMAP Phase 0, item 2.

  Prints, per interconnection and pooled, how much of the real network the
  simulator actually runs and how healthy that network is at rest:

    * bus/branch counts, geolocated versus simulated
    * island count, largest-connected-component share, isolated buses
    * base-case overload rate and loading distribution (median, p95),
      overall and by voltage class
    * the kV-mismatch census: line endpoints disagreeing beyond ±10%, and
      the >5:1 "welds"
    * the size of the `base_overloaded` set — branches the cascade can never
      trip because they are already over their rating at rest

  The base case comes from `PowerModel.Failure.Cascade.init/3` over
  `Grid.get_grid_snapshot/2`, i.e. the exact path a simulation takes, so
  these numbers and a running simulation cannot disagree.

  ## Usage

      mix grid.accuracy
      mix grid.accuracy --interconnection ERCOT --interconnection Western
      mix grid.accuracy --format json > accuracy.json
      mix grid.accuracy --hour 2024-08-20T18:00:00Z

  ## A/B mode

  `--ab` applies parameter overrides to an in-memory *copy* of the snapshot
  and prints what moved. Nothing is written to the database.

      mix grid.accuracy --interconnection Western --ab scale_rating_above_kv=300:2

  Repeat `--ab` to stack overrides. Recognised keys:

      scale_rating=F                 every branch rating x F
      scale_rating_above_kv=KV:F     ratings at or above KV kV x F
      scale_rating_below_kv=KV:F     ratings below KV kV x F
      min_rating_mva=MVA             floor under every branch rating
      scale_reactance=F              every branch x_pu x F
      scale_reactance_above_kv=KV:F  x_pu at or above KV kV x F
      scale_load=F                   every load x F
      scale_generation=F             every generator p_max_mw x F

  ## Options

      --interconnection NAME|ID  restrict to one interconnection (repeatable)
      --hour ISO8601             scale loads to an EIA-930 hour
      --format text|json         default text; json keys are stable for CI diffs
      --base-mva F               solver base, default 100.0
      --max-solve-buses N        skip the base case above this island size
                                 (default 0 = no guard). Obsolete since sparse
                                 triplet assembly landed (ROADMAP 18): Eastern
                                 solves in ~1 s. Kept for CI time budgets.
      --solve-timeout MS         wall-clock cap per base-case solve
  """

  use Mix.Task

  alias PowerModel.Analysis.NetworkMetrics

  @shortdoc "Network accuracy scoreboard (coverage, islands, overloads, kV census)"

  @switches [
    interconnection: :keep,
    hour: :string,
    format: :string,
    base_mva: :float,
    max_solve_buses: :integer,
    solve_timeout: :integer,
    ab: :keep
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("unrecognised option(s): #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    format = Keyword.get(opts, :format, "text")

    unless format in ~w(text json) do
      Mix.raise("--format must be text or json, got #{inspect(format)}")
    end

    # Nothing but JSON may reach stdout in JSON mode, and both Mix ("Compiling
    # 3 files") and Ecto's query logger write there by default. The logger has
    # to be quieted *after* app.start, which loads the :debug level from config.
    if format == "json", do: Mix.shell(Mix.Shell.Quiet)
    Mix.Task.run("app.start")

    if format == "json" do
      Logger.configure(level: :warning)
      # Surviving warnings (demand scaling, Ecto) must not land inside the JSON
      # document — route the default handler to stderr, same pattern as
      # mix power_model.validate.
      :logger.update_handler_config(:default, :config, %{type: :standard_error})
    end

    report =
      NetworkMetrics.report(
        interconnections: Keyword.get_values(opts, :interconnection),
        hour: parse_hour(opts[:hour]),
        base_mva: Keyword.get(opts, :base_mva, 100.0),
        max_solve_buses: Keyword.get(opts, :max_solve_buses, 0),
        solve_timeout_ms: Keyword.get(opts, :solve_timeout, 120_000),
        overrides: Enum.map(Keyword.get_values(opts, :ab), &parse_override/1)
      )

    case format do
      "json" -> IO.puts(encode_json(report))
      "text" -> render_text(report)
    end
  end

  # ---------------------------------------------------------------------------
  # Argument parsing
  # ---------------------------------------------------------------------------

  defp parse_hour(nil), do: nil

  defp parse_hour(string) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _offset} -> dt
      {:error, reason} -> Mix.raise("--hour #{string} is not ISO8601: #{inspect(reason)}")
    end
  end

  @tuple_overrides ~w(scale_rating_above_kv scale_rating_below_kv scale_reactance_above_kv)
  @scalar_overrides ~w(scale_rating min_rating_mva scale_reactance scale_load scale_generation)

  defp parse_override(string) do
    case String.split(string, "=", parts: 2) do
      [key, value] when key in @tuple_overrides ->
        case String.split(value, ":", parts: 2) do
          [kv, factor] ->
            {String.to_atom(key), {to_float(kv, string), to_float(factor, string)}}

          _ ->
            Mix.raise("--ab #{string}: #{key} needs KV:FACTOR, e.g. #{key}=300:2")
        end

      [key, value] when key in @scalar_overrides ->
        {String.to_atom(key), to_float(value, string)}

      [key, _] ->
        Mix.raise(
          "--ab #{string}: unknown override #{key}. Known: " <>
            Enum.join(Enum.sort(@tuple_overrides ++ @scalar_overrides), ", ")
        )

      _ ->
        Mix.raise("--ab #{string}: expected KEY=VALUE")
    end
  end

  defp to_float(string, original) do
    case Float.parse(string) do
      {value, ""} -> value
      _ -> Mix.raise("--ab #{original}: #{inspect(string)} is not a number")
    end
  end

  # ---------------------------------------------------------------------------
  # JSON
  # ---------------------------------------------------------------------------

  @doc """
  Encode a report as JSON. Keys are stable across runs (no timestamps, no
  ordering surprises) so CI can diff two runs directly.
  """
  def encode_json(report) do
    report
    |> NetworkMetrics.presentable()
    |> stringify()
    |> Jason.encode!(pretty: true)
  end

  # Branch keys are `{:line, id}` tuples and diff paths are already strings;
  # everything else becomes a JSON-safe string key.
  defp stringify(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_key(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  # The sparse LU NIF is not bit-reproducible, so two runs over identical data
  # differ around the 12th digit. Rounding here keeps a CI diff to real
  # changes; 1e-6 of a loading percent is orders of magnitude below anything
  # the model can claim to resolve.
  defp stringify(value) when is_float(value), do: Float.round(value, 6)

  defp stringify(value), do: value

  defp to_key(key) when is_binary(key), do: key
  defp to_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_key(key), do: inspect(key)

  # ---------------------------------------------------------------------------
  # Text rendering
  # ---------------------------------------------------------------------------

  defp render_text(report) do
    header(report)
    Enum.each(report.scopes, &render_scope/1)
    Mix.shell().info("")
  end

  defp header(report) do
    Mix.shell().info("")
    Mix.shell().info("NETWORK ACCURACY SCOREBOARD (schema v#{report.schema_version})")

    Mix.shell().info(
      "hour: #{report.hour || "none (unscaled estimated loads)"}   base_mva: #{report.base_mva}"
    )

    if report.overrides != [] do
      Mix.shell().info("A/B overrides: #{Enum.join(report.overrides, "  ")}")
    end
  end

  defp render_scope(scope) do
    rule()
    Mix.shell().info(String.upcase(scope.scope))
    rule()

    render_topology(scope.topology)
    render_base_case(scope.base_case)
    render_census(scope.kv_census)

    if scope[:diff], do: render_diff(scope.diff)
  end

  defp render_topology(t) do
    Mix.shell().info("\n  COVERAGE                geolocated -> simulated")

    coverage("buses", t.geolocated_buses, t.simulated_buses, t.simulated_bus_share)
    coverage("lines", t.geolocated_lines, t.simulated_lines, nil)
    coverage("transformers", t.geolocated_transformers, t.simulated_transformers, nil)
    coverage("branches", t.geolocated_branches, t.simulated_branches, t.simulated_branch_share)

    Mix.shell().info("")

    row(
      "islands",
      "#{t.island_count} geolocated, #{t.simulated_island_count} simulated",
      ""
    )

    row("largest component", "#{t.largest_component_buses} buses", pct(t.largest_component_share))
    row("isolated buses", "#{t.isolated_buses} carry no branch", pct(t.isolated_bus_share))

    row(
      "connected buses",
      "#{t.geolocated_buses - t.isolated_buses} carry a branch (target >80%)",
      pct(t.connected_bus_share)
    )
  end

  defp coverage(label, geolocated, simulated, share) do
    row(label, "#{geolocated} -> #{simulated}", pct(share || ratio(simulated, geolocated)))
  end

  defp ratio(_numerator, 0), do: nil
  defp ratio(numerator, denominator), do: numerator / denominator

  defp render_base_case(b) do
    Mix.shell().info("\n  BASE CASE")

    if b.status != "ok" do
      Mix.shell().info("    #{String.upcase(b.status)}: #{b.reason}")
    else
      row("solved branches", "#{b.branches_solved} of #{b.branches}", "")
      row("rated branches", "#{b.branches_rated} (loading denominator)", "")
      row("load", "#{mw(b.load_mw)} MW", "")

      row(
        "dispatch",
        "#{mw(b.dispatched_gen_mw)} MW via #{b.dispatch_source}",
        "#{pct(b.dispatch_to_load)} of load"
      )

      unserved(b.dispatch_coverage)
      row("base_overloaded", "#{b.base_overloaded} branches, trip-immune", pct(b.overload_rate))
      row("loading median", "", num(b.median_loading_pct) <> "%")
      row("loading p95", "", num(b.p95_loading_pct) <> "%")

      render_class_table(b.by_voltage_class)
    end
  end

  defp unserved(nil), do: :ok

  defp unserved(coverage) do
    row(
      "dispatch coverage",
      "#{mw(coverage.dispatched_mw)} of #{mw(coverage.target_mw)} MW measured, " <>
        "#{coverage.online_units}/#{coverage.units} units",
      ""
    )
  end

  defp render_class_table(by_class) when map_size(by_class) == 0, do: :ok

  # Lines get their own columns because a transformer is classified by its
  # high side: pooling the step-downs into "345 kV" changes what the class
  # means. The lines-only column is the backbone number.
  defp render_class_table(by_class) do
    Mix.shell().info("")

    Mix.shell().info(
      "    " <>
        pad("class", 12) <>
        pad("rated", 7) <>
        pad("over", 6) <>
        pad("over%", 8) <>
        pad("median", 9) <> pad("p95", 10) <> pad("lines", 7) <> "ln.over%"
    )

    for label <- NetworkMetrics.voltage_class_labels(), stats = by_class[label], stats do
      Mix.shell().info(
        "    " <>
          pad(label, 12) <>
          pad(to_string(stats.branches_rated), 7) <>
          pad(to_string(stats.overloaded), 6) <>
          pad(pct(stats.overload_rate), 8) <>
          pad(num(stats.median_loading_pct) <> "%", 9) <>
          pad(num(stats.p95_loading_pct) <> "%", 10) <>
          pad(to_string(stats.lines.branches_rated), 7) <>
          pct(stats.lines.overload_rate)
      )
    end
  end

  defp render_census(census) do
    Mix.shell().info("\n  kV CENSUS (lines only; a transformer changes level by design)")

    Mix.shell().info(
      "    " <>
        pad("scope", 14) <>
        pad("lines", 8) <>
        pad("compared", 10) <>
        pad("off>10%", 9) <>
        pad("rate", 8) <> pad("weld>5:1", 10) <> pad("line/bus", 10) <> "worst"
    )

    Enum.each([:geolocated, :simulated], fn key ->
      c = census[key]

      Mix.shell().info(
        "    " <>
          pad(to_string(key), 14) <>
          pad(to_string(c.lines), 8) <>
          pad(to_string(c.comparable), 10) <>
          pad(to_string(c.mismatch_10pct), 9) <>
          pad(pct(c.mismatch_rate), 8) <>
          pad(to_string(c.weld_5to1), 10) <>
          pad(to_string(c.line_vs_bus_mismatch), 10) <> worst(c.worst_ratio)
      )
    end)
  end

  defp worst(nil), do: "n/a"
  defp worst(ratio), do: num(ratio) <> ":1"

  defp render_diff(diff) when map_size(diff) == 0 do
    Mix.shell().info("\n  A/B DIFF: no metric moved")
  end

  defp render_diff(diff) do
    Mix.shell().info("\n  A/B DIFF (variant - base)")

    diff
    |> Enum.sort_by(fn {path, _} -> path end)
    |> Enum.each(fn {path, %{base: b, variant: v, delta: d}} ->
      Mix.shell().info(
        "    " <>
          pad(path, 62) <>
          pad(metric(path, b), 11) <> pad("->", 3) <> pad(metric(path, v), 11) <> signed(path, d)
      )
    end)
  end

  # Rates and shares live in [0, 1]; two decimals would round most A/B moves
  # to nothing, so they are printed as percentages.
  defp metric(path, value) do
    if rate?(path), do: pct(value), else: num(value)
  end

  defp rate?(path), do: String.ends_with?(path, "_rate") or String.ends_with?(path, "_share")

  defp signed(_path, nil), do: ""
  defp signed(path, value) when value > 0, do: "+" <> metric(path, value)
  defp signed(path, value), do: metric(path, value)

  # ---------------------------------------------------------------------------
  # Formatting helpers
  # ---------------------------------------------------------------------------

  defp rule, do: Mix.shell().info(String.duplicate("=", 78))

  defp row(label, detail, right) do
    Mix.shell().info("    " <> pad(label, 20) <> pad(detail, 48) <> right)
  end

  defp pad(string, width) do
    string = to_string(string)
    if String.length(string) >= width, do: string <> " ", else: String.pad_trailing(string, width)
  end

  defp pct(nil), do: "n/a"
  defp pct(value), do: :erlang.float_to_binary(value * 100.0, decimals: 1) <> "%"

  defp num(nil), do: "n/a"
  defp num(value) when is_integer(value), do: Integer.to_string(value)
  defp num(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp mw(nil), do: "n/a"
  defp mw(value), do: :erlang.float_to_binary(value * 1.0, decimals: 0)
end
