defmodule Mix.Tasks.PowerModel.Validate do
  @moduledoc """
  EIA-930 replay validation — ROADMAP Phase 0, item 1.

  Replays historical hours through the model's own dispatch path and scores
  the result against what the grid actually did: per-BA fuel-mix
  total-variation distance, net-interchange error, served-load error, and the
  generation-conservation residual. See `PowerModel.Validation.Replay` for
  the definitions.

  ## Usage

      mix power_model.validate                          # 24 most recent complete hours
      mix power_model.validate --hours 6
      mix power_model.validate --from 2024-08-20T12:00:00Z --to 2024-08-20T23:00:00Z
      mix power_model.validate --interconnection ERCOT --hours 24
      mix power_model.validate --hours 6 --legacy       # before/after in one command
      mix power_model.validate --hours 6 --format json > replay.json

  ## Options

      --hours N              replay the N most recent COMPLETE hours (default 24)
      --from ISO8601         replay a window instead (inclusive)
      --to ISO8601
      --interconnection X    name or id, repeatable; defaults to all
      --legacy               also score the pre-Phase-1 proportional dispatch
      --format text|json     default text; json keys are stable for CI diffs
      --top N                BA rows to print (default 20; 0 prints all)
      --reporting-slack N    an hour is complete at modal-N reporting BAs (default 1)

  The last line(s) of text output are `key=value` summaries meant to be
  pasted into a CI assertion, e.g.

      REPLAY schema=1 mode=measured hours=6 ... tv_load_weighted=0.0412 ...

  `--hours` selects only COMPLETE hours: the final hour of an EIA bulk file
  is a boundary hour where a third of the country has not reported yet
  (REVIEW ENE-13), and replaying it would score the model against a partial
  measurement. `--from`/`--to` replay the window as asked and flag any
  incomplete hour in it instead.
  """

  use Mix.Task

  alias PowerModel.Validation.Replay

  @shortdoc "Replay EIA-930 hours and score dispatch accuracy"

  @switches [
    hours: :integer,
    from: :string,
    to: :string,
    interconnection: :keep,
    legacy: :boolean,
    format: :string,
    top: :integer,
    reporting_slack: :integer
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

    if opts[:hours] && (opts[:from] || opts[:to]) do
      Mix.raise("--hours and --from/--to select hours differently; pass one or the other")
    end

    # Nothing but JSON may reach stdout in JSON mode, and Mix, Ecto's query
    # logger, and the demand-scaling warnings all write there by default.
    if format == "json", do: Mix.shell(Mix.Shell.Quiet)
    Mix.Task.run("app.start")
    if format == "json", do: logs_to_stderr()

    report =
      Replay.run(
        hours: Keyword.get(opts, :hours, 24),
        from: parse_hour(opts[:from], "--from"),
        to: parse_hour(opts[:to], "--to"),
        interconnections: Keyword.get_values(opts, :interconnection),
        legacy: Keyword.get(opts, :legacy, false),
        reporting_slack: Keyword.get(opts, :reporting_slack, 1)
      )

    case format do
      "json" -> IO.puts(encode_json(report))
      "text" -> render_text(report, Keyword.get(opts, :top, 20))
    end
  end

  # A replay logs freely — Ecto queries, every BA whose demand scaling looks
  # odd — and the default handler writes all of it to stdout, where it would
  # sit in the middle of the JSON document. Move the handler to stderr rather
  # than silencing it: `--format json > report.json` then leaves the warnings
  # on the terminal where someone can still read them. Ecto's :debug logs are
  # dropped outright; they are noise at this volume.
  defp logs_to_stderr do
    Logger.configure(level: :info)

    case :logger.update_handler_config(:default, :config, %{type: :standard_error}) do
      :ok ->
        :ok

      {:error, reason} ->
        # An unusual handler configuration: silence rather than corrupt.
        Logger.configure(level: :emergency)
        Mix.shell().error("could not redirect logs to stderr (#{inspect(reason)}); silenced")
    end
  end

  defp parse_hour(nil, _flag), do: nil

  defp parse_hour(string, flag) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _offset} -> dt
      {:error, reason} -> Mix.raise("#{flag} #{string} is not ISO8601: #{inspect(reason)}")
    end
  end

  @doc """
  Encode a report as JSON. Keys are stable across runs so CI can diff two
  runs directly.
  """
  def encode_json(report) do
    report
    |> Replay.presentable()
    |> Jason.encode!(pretty: true)
  end

  # ---------------------------------------------------------------------------
  # Text rendering
  # ---------------------------------------------------------------------------

  defp render_text(report, top) do
    header(report)

    if report.hours == [] do
      Mix.shell().info("\n  no hours to replay — is ba_fuel_hour ingested?\n")
    else
      Enum.each(report.modes, &render_mode(&1, top))
      render_comparison(report.comparison)
      Mix.shell().info("")
      Enum.each(Replay.summary_lines(report), fn line -> Mix.shell().info(line) end)
      Mix.shell().info("")
    end
  end

  defp header(report) do
    Mix.shell().info("")
    Mix.shell().info("EIA-930 REPLAY VALIDATION (schema v#{report.schema_version})")

    case report.window do
      nil ->
        Mix.shell().info("window: none")

      window ->
        Mix.shell().info(
          "window: #{iso(window.from)} .. #{iso(window.to)}  (#{window.hours} hours)"
        )
    end

    scope = report.scope

    Mix.shell().info(
      "scope:  #{Enum.join(scope.interconnections, ", ")} — #{scope.buses} buses / " <>
        "#{scope.generators} generators / #{scope.islands} islands / " <>
        "#{scope.bas_modeled} BAs modeled"
    )
  end

  defp render_mode(mode_report, top) do
    summary = mode_report.summary

    rule()
    Mix.shell().info(mode_title(mode_report.mode))
    rule()

    if summary.hours == 0 do
      Mix.shell().info("  no hours scored")
    else
      render_summary(summary)
      render_bas(mode_report.by_ba, top)
      render_gap(mode_report.gap_by_fuel)
      render_unmodeled(mode_report.unmodeled_bas)
    end
  end

  defp mode_title(:measured),
    do: "MEASURED DISPATCH — PowerModel.Dispatch, EIA-930 per-fuel MW (the simulator's path)"

  defp mode_title(:legacy),
    do: "LEGACY DISPATCH — uniform pro-rata of island capacity (pre-ROADMAP-Phase-1)"

  defp render_summary(s) do
    Mix.shell().info("\n  FUEL MIX (total-variation distance; 0.243 = the ROADMAP baseline)")
    row("load-weighted", tv(s.tv_load_weighted), "of generation on the wrong fuel")
    row("generation-weighted", tv(s.tv_generation_weighted), "")
    row("mean / median BA", "#{tv(s.tv_mean)} / #{tv(s.tv_median)}", "")

    if s.tv_load_weighted_worst_hour do
      row(
        "worst hour",
        tv(s.tv_load_weighted_worst_hour.tv_load_weighted),
        iso(s.tv_load_weighted_worst_hour.hour)
      )
    end

    render_coverage(s)

    Mix.shell().info("\n  BALANCE (mean over #{s.hours} hours)")
    row("interchange MAE", mw(s.interchange_mae_mw) <> " MW", "per BA, implied vs reported")
    row("interchange bias", mw(s.interchange_bias_mw) <> " MW", "signed, summed over BAs")

    row(
      "  = placement gap",
      mw(s.interchange_from_placement_mw) <> " MW",
      "model − measured generation"
    )

    row(
      "  + EIA residual",
      mw(s.interchange_from_eia_residual_mw) <> " MW",
      "measured gen − demand − interchange"
    )

    row(
      "  − served-load error",
      mw(s.interchange_from_load_error_mw) <> " MW",
      "the three terms sum to the bias exactly"
    )

    row("served-load MAE", mw(s.served_load_mae_mw) <> " MW", "per BA, snapshot vs EIA demand")

    row(
      "served-load MAPE",
      pct(s.served_load_mape),
      "#{s.bas_load_unscaled} BA(s) on synthetic baseline"
    )

    row("load scale factor", num(s.load_scale_factor_median), "median served ÷ baseline")

    if s.bas_scale_factor_outsized > 0 do
      row(
        "outsized scaling",
        "#{s.bas_scale_factor_outsized} BA(s), #{gw(s.outsized_scale_load_mw)} GW",
        "whole-BA demand on a slice of its buses"
      )
    end

    row("model generation", gw(s.model_generation_mw) <> " GW", "")
    row("model load", gw(s.model_load_mw) <> " GW", "")
    row("measured generation", gw(s.actual_generation_mw) <> " GW", "scored BAs only")
    row("EIA demand", gw(s.eia_demand_mw) <> " GW", "#{pct(s.demand_coverage)} of reporting BAs")

    Mix.shell().info("\n  CONSERVATION (mostly the coverage asymmetry above, not lost dispatch)")
    row("island residual", mw(s.conservation_residual_mw) <> " MW", "signed, Σgen − Σload")
    row("island |residual|", mw(s.island_abs_residual_mw) <> " MW", "summed over islands")
    row("unserved", mw(s.unserved_mw) <> " MW", "measured MW no unit could absorb")
    row("unmatched", mw(s.unmatched_mw) <> " MW", "measured MW with no unit at all")
    row("unplaced total", mw(s.unplaced_mw) <> " MW", "REVIEW ENE-15 gap")
    row("  of which nuclear", mw(s.unplaced_nuclear_mw) <> " MW", "Phase 2 scoreboard")

    row("BAs scored", "#{s.bas_scored} of #{s.bas_reporting} reporting", "")

    if s.incomplete_hours > 0 do
      row("incomplete hours", "#{s.incomplete_hours}", "scored against a partial measurement")
    end

    sources = Enum.map_join(s.dispatch_sources, ", ", fn {k, v} -> "#{k} x#{v}" end)
    row("dispatch source", sources, "")
  end

  # Since ENE-17 and ENE-20 both sides are measured over the SAME population:
  # the snapshot's share of each BA's load universe scales its demand and its
  # measured generation alike. Printing the share first says what fraction of
  # the country every balance number below it describes.
  defp render_coverage(s) do
    Mix.shell().info("\n  COVERAGE UNIVERSES (the two sides of every balance number)")

    row(
      "load side",
      "#{pct(s.load_share_weighted)} of BA load universe",
      "serves that share of BA demand"
    )

    row(
      "generation side",
      "#{pct(s.generation_coverage)} of the MW offered",
      "placed on mapped units"
    )

    row("dispatch ÷ load", pct(s.dispatch_to_load), "closes only when both reach 100%")
  end

  defp render_bas([], _top), do: :ok

  defp render_bas(by_ba, top) do
    shown = if top && top > 0, do: Enum.take(sort_by_tv(by_ba), top), else: sort_by_tv(by_ba)

    Mix.shell().info("\n  PER BA (mean over the replayed hours, worst fuel mix first)")

    Mix.shell().info(
      "    " <>
        pad("ba", 8) <>
        pad("ic", 9) <>
        pad("tv", 8) <>
        pad("gen GW", 9) <>
        pad("meas GW", 10) <>
        pad("share", 9) <>
        pad("gen cov", 9) <> pad("ix err", 10) <> "biggest fuel error"
    )

    Enum.each(shown, fn ba ->
      Mix.shell().info(
        "    " <>
          pad(ba.ba_code, 8) <>
          pad(ba.interconnection || "-", 9) <>
          pad(tv(ba.fuel_mix_tv), 8) <>
          pad(gw(ba.model_generation_mw), 9) <>
          pad(gw(ba.actual_generation_mw), 10) <>
          pad(pct(ba.load_share), 9) <>
          pad(pct(ba.generation_coverage), 9) <>
          pad(mw(ba.interchange_mae_mw), 10) <> biggest_fuel_error(ba)
      )
    end)

    if (top && top > 0) and length(by_ba) > top do
      Mix.shell().info("    ... #{length(by_ba) - top} more (--top 0 for all)")
    end
  end

  defp sort_by_tv(by_ba), do: Enum.sort_by(by_ba, &(-(&1.fuel_mix_tv || 0.0)))

  # The single fuel carrying the largest signed MW error, which is what a
  # reader wants next after "this BA's mix is wrong".
  defp biggest_fuel_error(ba) do
    Replay.fuels()
    |> Enum.map(fn fuel ->
      {fuel, (Map.get(ba.model_fuel_mw, fuel) || 0.0) - (Map.get(ba.actual_fuel_mw, fuel) || 0.0)}
    end)
    |> Enum.max_by(fn {_fuel, delta} -> abs(delta) end, fn -> nil end)
    |> case do
      nil -> ""
      {fuel, delta} -> "#{fuel} #{signed_mw(delta)} MW"
    end
  end

  defp render_gap(nil), do: :ok

  defp render_gap(gap) do
    Mix.shell().info("\n  MEASURED MW THE FLEET COULD NOT HOLD (mean MW; REVIEW ENE-15)")

    Mix.shell().info(
      "    " <> pad("fuel", 14) <> pad("unserved", 12) <> pad("unmatched", 12) <> "unplaced"
    )

    gap
    |> Enum.sort_by(fn {_fuel, stats} -> -stats.unplaced_mw end)
    |> Enum.each(fn {fuel, stats} ->
      Mix.shell().info(
        "    " <>
          pad(fuel, 14) <>
          pad(mw(stats.unserved_mw), 12) <>
          pad(mw(stats.unmatched_mw), 12) <> mw(stats.unplaced_mw)
      )
    end)
  end

  defp render_unmodeled([]), do: :ok

  defp render_unmodeled(unmodeled) do
    total = unmodeled |> Enum.map(&(&1.actual_generation_mw || 0.0)) |> Enum.sum()

    top =
      unmodeled
      |> Enum.take(6)
      |> Enum.map_join(", ", fn ba -> "#{ba.ba_code} #{mw(ba.actual_generation_mw)}" end)

    Mix.shell().info(
      "\n  NOT SCORED: #{length(unmodeled)} reporting BAs own no bus in the snapshot " <>
        "(#{gw(total)} GW measured) — #{top}"
    )
  end

  defp render_comparison(nil), do: :ok

  defp render_comparison(comparison) do
    rule()
    Mix.shell().info("MEASURED − LEGACY (same hours, same snapshot)")
    rule()

    Mix.shell().info(
      "    " <> pad("metric", 28) <> pad("measured", 14) <> pad("legacy", 14) <> "delta"
    )

    ~w(tv_load_weighted tv_generation_weighted tv_mean interchange_mae_mw
       served_load_mape conservation_residual_mw)a
    |> Enum.each(fn key ->
      entry = Map.get(comparison, key)

      Mix.shell().info(
        "    " <>
          pad(to_string(key), 28) <>
          pad(num(entry.measured), 14) <> pad(num(entry.legacy), 14) <> signed(entry.delta)
      )
    end)
  end

  # ---------------------------------------------------------------------------
  # Formatting helpers
  # ---------------------------------------------------------------------------

  defp rule, do: Mix.shell().info(String.duplicate("=", 92))

  defp row(label, detail, right) do
    Mix.shell().info("    " <> pad(label, 22) <> pad(detail, 26) <> right)
  end

  defp pad(string, width) do
    string = to_string(string)
    if String.length(string) >= width, do: string <> " ", else: String.pad_trailing(string, width)
  end

  defp iso(nil), do: "none"
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp tv(nil), do: "n/a"
  defp tv(value), do: :erlang.float_to_binary(value * 1.0, decimals: 4)

  defp pct(nil), do: "n/a"
  defp pct(value), do: :erlang.float_to_binary(value * 100.0, decimals: 2) <> "%"

  defp mw(nil), do: "n/a"
  defp mw(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  defp signed_mw(value) when value > 0, do: "+" <> mw(value)
  defp signed_mw(value), do: mw(value)

  defp gw(nil), do: "n/a"
  defp gw(value), do: :erlang.float_to_binary(value / 1000.0, decimals: 2)

  defp num(nil), do: "n/a"
  defp num(value) when is_integer(value), do: Integer.to_string(value)
  defp num(value), do: :erlang.float_to_binary(value * 1.0, decimals: 4)

  defp signed(nil), do: "n/a"
  defp signed(value) when value > 0, do: "+" <> num(value)
  defp signed(value), do: num(value)
end
