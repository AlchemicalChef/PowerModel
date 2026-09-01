defmodule Mix.Tasks.PowerModel.CascadeCcdf do
  @moduledoc """
  Blackout-size distribution from random initiating outages, against DOE
  OE-417 (ROADMAP item 27, REVIEW EXT-3).

      mix power_model.cascade_ccdf --interconnection ERCOT --samples 200 --out ccdf.csv
      mix power_model.cascade_ccdf --interconnection ERCOT --samples 200 --n2 --constrained

  Draws `--samples` initiating events — a single rated branch trip, or a
  simultaneous pair with `--n2` — uniformly over the main island's rated
  branches at the latest ingested hour, runs the cascade for each, and
  records the load lost (shed + blackout) and the outcome. Writes one row per
  sample and prints the complementary cumulative distribution of lost MW with
  a maximum-likelihood power-law exponent over the tail above `--xmin`
  (default 100 MW): the published OE-417 blackout-size CCDF has α ≈ 1.31
  (Carreras/Dobson); a bimodal distribution — everything either settles at
  zero or runs away — is CAS-26's binary regime, and this is how it is seen.

  `--constrained` starts each cascade from the transmission-constrained
  operating point (`Cascade.init(constrained_dispatch: true)`);
  `--voltage-control` turns the reactive layer on. `--seed` fixes the draw.
  """

  use Mix.Task

  require Logger

  alias PowerModel.{Demand, Grid, Repo}
  alias PowerModel.Failure.Cascade

  @shortdoc "Blackout-size CCDF from random initiating outages (OE-417 check)"

  @switches [
    interconnection: :string,
    samples: :integer,
    out: :string,
    hour: :string,
    n2: :boolean,
    constrained: :boolean,
    voltage_control: :boolean,
    seed: :integer,
    xmin: :float
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [], do: Mix.raise("unrecognised option(s): #{inspect(invalid)}")
    name = opts[:interconnection] || Mix.raise("--interconnection is required")
    samples = opts[:samples] || 100
    xmin = opts[:xmin] || 100.0

    Mix.Task.run("app.start")
    Logger.configure(level: :warning)
    :rand.seed(:exsss, {opts[:seed] || 1, 2, 3})

    hour = parse_hour(opts[:hour]) || Demand.latest_demand_hour()
    ic = Repo.get_by(Grid.Interconnection, name: name) || Mix.raise("no interconnection #{name}")
    snap = Grid.get_grid_snapshot(ic.id, hour: hour)

    init_opts =
      [hour: hour] ++
        if(opts[:constrained], do: [constrained_dispatch: true], else: []) ++
        if(opts[:voltage_control], do: [voltage_control: true], else: [])

    base = Cascade.init(snap, 100.0, init_opts)
    candidates = rated_branches(base)

    Mix.shell().info(
      "#{name} @ #{hour}: #{length(candidates)} rated branches; #{samples} #{if opts[:n2], do: "N-2", else: "N-1"} samples" <>
        if(opts[:constrained], do: " from the constrained operating point", else: "")
    )

    rows =
      for i <- 1..samples do
        picks =
          if opts[:n2], do: Enum.take_random(candidates, 2), else: Enum.take_random(candidates, 1)

        t0 = System.monotonic_time(:millisecond)
        {state, steps} = run_event(base, picks)
        b = Cascade.balance(state)
        lost = b.shed_load_mw + b.blackout_load_mw

        row = %{
          sample: i,
          initiating: Enum.map_join(picks, ";", fn {t, id} -> "#{t}:#{id}" end),
          lost_mw: Float.round(lost, 1),
          shed_mw: Float.round(b.shed_load_mw, 1),
          blackout_mw: Float.round(b.blackout_load_mw, 1),
          steps: length(steps),
          termination: Cascade.termination(state),
          outcome: Cascade.outcome(state),
          secs: (System.monotonic_time(:millisecond) - t0) / 1000
        }

        if rem(i, 10) == 0,
          do: Mix.shell().info("  #{i}/#{samples} lost #{row.lost_mw} MW (#{row.outcome})")

        row
      end

    if opts[:out], do: write_csv(opts[:out], rows)
    report(rows, xmin, base)
  end

  defp rated_branches(state) do
    lines =
      state.lines
      |> Enum.filter(&(is_number(&1.rating_a_mva) and &1.rating_a_mva > 0))
      |> Enum.map(&{:line, &1.id})

    xfmrs =
      state.transformers
      |> Enum.filter(&(is_number(&1.rated_mva) and &1.rated_mva > 0))
      |> Enum.map(&{:transformer, &1.id})

    lines ++ xfmrs
  end

  # Trip the first element through the public entry point (it runs the
  # cascade); a second element is tripped on the returned state.
  defp run_event(base, [first | rest]) do
    {state, steps} = trip(base, first)

    Enum.reduce(rest, {state, steps}, fn el, {st, acc} ->
      {st2, more} = trip(st, el)
      {st2, acc ++ more}
    end)
  end

  defp trip(state, {:line, id}), do: Cascade.trip_line(state, id)
  defp trip(state, {:transformer, id}), do: Cascade.trip_transformer(state, id)

  defp write_csv(path, rows) do
    header = "sample,initiating,lost_mw,shed_mw,blackout_mw,steps,termination,outcome,secs"

    body =
      Enum.map(rows, fn r ->
        "#{r.sample},#{r.initiating},#{r.lost_mw},#{r.shed_mw},#{r.blackout_mw},#{r.steps},#{r.termination},#{r.outcome},#{r.secs}"
      end)

    File.write!(path, Enum.join([header | body], "\n") <> "\n")
  end

  defp report(rows, xmin, base) do
    n = length(rows)
    lost = Enum.map(rows, & &1.lost_mw)
    zero = Enum.count(lost, &(&1 < 1.0))
    tail = lost |> Enum.filter(&(&1 >= xmin)) |> Enum.sort()
    total = base.original_load_mw

    IO.puts(
      "\n== blackout-size distribution: #{n} samples, #{zero} lost < 1 MW, #{length(tail)} ≥ #{xmin} MW"
    )

    for q <- [0.5, 0.9, 0.99] do
      v = Enum.at(Enum.sort(lost), min(round(q * n) - 1, n - 1) |> max(0))

      IO.puts(
        "   quantile #{q}: #{Float.round(v * 1.0, 1)} MW (#{Float.round(v / max(total, 1.0) * 100, 2)} % of #{round(total)} MW)"
      )
    end

    outcomes = Enum.frequencies_by(rows, & &1.outcome)
    terms = Enum.frequencies_by(rows, & &1.termination)
    IO.puts("   outcomes #{inspect(outcomes)}; terminations #{inspect(terms)}")

    if length(tail) >= 10 do
      # Discrete-free MLE for a continuous power law above xmin: alpha = 1 + n / sum(ln(x/xmin)).
      alpha =
        1.0 + length(tail) / Enum.reduce(tail, 0.0, fn x, acc -> acc + :math.log(x / xmin) end)

      IO.puts(
        "   CCDF tail exponent (MLE, x ≥ #{xmin} MW): alpha = #{Float.round(alpha, 2)} on #{length(tail)} events; OE-417 published ≈ 1.31 (pdf exponent ≈ 2.31)"
      )

      IO.puts("   CCDF points (MW: P[X ≥ MW]):")

      for x <- [100, 300, 1000, 3000, 10000] do
        p = Enum.count(lost, &(&1 >= x)) / n
        IO.puts("     #{String.pad_leading(to_string(x), 6)}: #{Float.round(p, 3)}")
      end
    else
      IO.puts(
        "   fewer than 10 events above #{xmin} MW — no tail to fit (a binary regime looks like this)"
      )
    end
  end

  defp parse_hour(nil), do: nil

  defp parse_hour(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> Mix.raise("--hour must be ISO8601")
    end
  end
end
