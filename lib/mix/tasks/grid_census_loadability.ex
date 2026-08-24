defmodule Mix.Tasks.Grid.Census.Loadability do
  @moduledoc """
  How much load each interconnection can actually CARRY, as opposed to how much
  the solver can find a root for.

      mix grid.census loadability
      mix grid.census loadability --interconnection ERCOT --format json

  ## Why this exists

  Every α figure in REVIEW and ROADMAP answers "the highest uniform load scaling
  at which FDPF converges". Measured 2026-08-23, those converged points are
  operating states no system would run: Eastern converges with `Vm` down to
  0.6163 and 17 buses under 0.90 pu, ERCOT with 0.7448 and NINETY. This repo's
  own UVLS arms at 0.92/0.89/0.86 pu, so `Failure.LoadShedding` would shed load
  to escape the very state the ceiling is measured at.

  Convergence is a property of the equations; operability is a property of the
  grid. This census reports both, so the gap is visible instead of implied.

  ## The bands are TWO-SIDED, and that matters

  A first version of this measurement checked only the lower bound and made
  Western look far better than it is — Western carries buses at 1.1268 pu, well
  over any upper limit, from the line charging that `LIN-13` has tracked since
  the beginning. An undervoltage-only criterion silently passes a network that
  is failing in the other direction, so each band here is a range:

    * **solvable** — converged, no voltage criterion. The historical number.
    * **emergency** — every bus within #{"0.90"}-#{"1.10"} pu.
    * **normal** — every bus within #{"0.95"}-#{"1.05"} pu.

  ## A two-sided band is an INTERVAL, not a ceiling — and bisection cannot find it

  The first version of this census bisected each band from zero and reported
  α = 0.0 for `normal` on all three interconnections. That was an artifact of
  the method, not a result. Bisection from zero assumes monotonicity — if α
  works, everything below works — and an upper voltage bound breaks it: at LIGHT
  load the network OVERVOLTS on line charging with nothing to absorb it
  (Western reaches Vm 1.5 with 167 buses over 1.10 pu at α → 0). So the feasible
  set is a window with a floor and a ceiling, and a bisection starting below the
  floor finds nothing and calls it zero.

  The banded rows are therefore SCANNED on a coarse α grid and reported as the
  feasible interval `[lo, hi]`, or `none` when no sampled α satisfies the band.
  `solvable` keeps its bisection, because convergence has no upper bound.

  ## Reading it

  `none` on a band does not mean the network can serve no load. It means no
  sampled α holds every bus inside that band — the grid is failing at BOTH ends,
  overvoltage at light load and undervoltage at heavy. That is a real property
  of this model (LIN-13 recorded it for Western from the beginning) and the
  reason the historical single-sided α reads as high as it does.
  """

  use Mix.Task

  require Logger

  import Ecto.Query

  alias PowerModel.{Demand, Grid, Repo}
  alias PowerModel.Failure.Cascade
  alias PowerModel.Solver.{FDPF, Partition}

  @shortdoc "Load an interconnection can carry, against a voltage criterion"

  @base_mva 100.0
  @bisection_steps 7
  @solve_opts [base_mva: @base_mva, dense_nr_max_buses: 0, max_iterations: 400]

  @bands [
    {"solvable", nil, nil},
    {"emergency", 0.90, 1.10},
    {"normal", 0.95, 1.05}
  ]

  @switches [interconnection: :keep, format: :string, hour: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [],
      do: Mix.raise("unrecognised option(s): #{inspect(Enum.map(invalid, &elem(&1, 0)))}")

    format = Keyword.get(opts, :format, "text")
    unless format in ~w(text json), do: Mix.raise("--format must be text or json")

    if format == "json", do: Mix.shell(Mix.Shell.Quiet)
    Mix.Task.run("app.start")
    Logger.configure(level: if(format == "json", do: :warning, else: :info))

    if format == "json",
      do: :logger.update_handler_config(:default, :config, %{type: :standard_error})

    report = report(opts)

    case format do
      "json" -> IO.puts(Jason.encode!(report, pretty: true))
      "text" -> render_text(report)
    end
  end

  @doc "Build the report without printing it."
  def report(opts \\ []) do
    hour = parse_hour(opts[:hour]) || Demand.latest_demand_hour()

    interconnections =
      case Keyword.get_values(opts, :interconnection) do
        [] -> Repo.all(from(i in Grid.Interconnection, order_by: i.name))
        names -> Enum.map(names, &fetch!/1)
      end

    %{
      census: "loadability",
      hour: hour && DateTime.to_iso8601(hour),
      bands: Enum.map(@bands, fn {n, lo, hi} -> %{name: n, min_pu: lo, max_pu: hi} end),
      interconnections: Enum.map(interconnections, &measure(&1, hour))
    }
  end

  defp measure(ic, hour) do
    island = island_for(ic, hour)
    island_mw = Enum.reduce(island.loads, 0.0, &(&2 + (&1.p_mw || 0.0)))

    bands =
      Map.new(@bands, fn
        {name, nil, nil} ->
          alpha = bisect(island, nil, nil)
          {name, band_detail(island, alpha, alpha, island_mw)}

        {name, lo, hi} ->
          {a_lo, a_hi} = feasible_interval(island, lo, hi)
          {name, band_detail(island, a_lo, a_hi, island_mw)}
      end)

    %{
      name: ic.name,
      island_buses: length(island.buses),
      island_mw: Float.round(island_mw, 1),
      bands: bands
    }
  end

  defp island_for(ic, hour) do
    snap = Grid.get_grid_snapshot(ic.id, hour: hour)
    state = Cascade.init(snap, @base_mva, hour: hour)

    {subs, _dead} =
      Partition.split(%{
        buses: state.buses,
        lines: state.lines,
        transformers: state.transformers,
        generators: Cascade.dispatched_generators(state),
        loads: state.loads
      })

    Enum.max_by(subs, &length(&1.buses))
  end

  defp scale(island, a) do
    %{
      island
      | loads:
          Enum.map(
            island.loads,
            &%{&1 | p_mw: (&1.p_mw || 0.0) * a, q_mvar: (&1.q_mvar || 0.0) * a}
          ),
        generators: Enum.map(island.generators, &%{&1 | p_max_mw: &1.p_max_mw * a})
    }
  end

  defp solve(island, a) do
    case FDPF.solve(scale(island, a), @solve_opts) do
      {:ok, s} -> s
      _ -> nil
    end
  catch
    _, _ -> nil
  end

  defp acceptable?(nil, _lo, _hi), do: false

  defp acceptable?(sol, lo, hi) do
    sol.converged and
      (lo == nil or Enum.min(sol.vm_pu) >= lo) and
      (hi == nil or Enum.max(sol.vm_pu) <= hi)
  end

  # A coarse sweep, because a two-sided band is a window rather than a prefix
  # and bisection from zero cannot see it (see the moduledoc). Deliberately
  # coarse: the point is whether a feasible window EXISTS and roughly where,
  # not its edges to four decimals, and Eastern costs ~45 s per solve.
  @scan_grid [0.02, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.75, 0.9, 1.0]

  defp feasible_interval(island, lo, hi) do
    feasible =
      Enum.filter(@scan_grid, fn a -> island |> solve(a) |> acceptable?(lo, hi) end)

    case feasible do
      [] -> {nil, nil}
      as -> {Enum.min(as), Enum.max(as)}
    end
  end

  defp band_detail(_island, nil, nil, _island_mw) do
    %{
      alpha_lo: nil,
      alpha_hi: nil,
      served_mw: nil,
      feasible: false,
      vm_min: nil,
      vm_max: nil,
      buses_under_0_90: nil,
      buses_over_1_10: nil
    }
  end

  defp band_detail(island, a_lo, a_hi, island_mw) do
    sol = solve(island, a_hi)

    %{
      alpha_lo: a_lo,
      alpha_hi: a_hi,
      served_mw: Float.round(a_hi * island_mw, 1),
      feasible: true,
      vm_min: sol && Float.round(Enum.min(sol.vm_pu), 4),
      vm_max: sol && Float.round(Enum.max(sol.vm_pu), 4),
      buses_under_0_90: sol && Enum.count(sol.vm_pu, &(&1 < 0.90)),
      buses_over_1_10: sol && Enum.count(sol.vm_pu, &(&1 > 1.10))
    }
  end

  defp bisect(island, lo, hi) do
    ok? = fn a -> island |> solve(a) |> acceptable?(lo, hi) end

    if ok?.(1.0) do
      1.0
    else
      1..@bisection_steps
      |> Enum.reduce({0.0, 1.0}, fn _, {a_lo, a_hi} ->
        mid = (a_lo + a_hi) / 2
        if ok?.(mid), do: {mid, a_hi}, else: {a_lo, mid}
      end)
      |> elem(0)
      |> Float.round(4)
    end
  end

  defp parse_hour(nil), do: nil

  defp parse_hour(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      {:error, r} -> Mix.raise("--hour #{s} is not ISO8601: #{inspect(r)}")
    end
  end

  defp fetch!(name) do
    Repo.get_by(Grid.Interconnection, name: name) ||
      Mix.raise("no interconnection named #{inspect(name)}")
  end

  @doc false
  def render_text(report) do
    IO.puts("""

    ══ loadability census ══
    hour #{report.hour}
    Convergence is a property of the equations; operability is a property of the
    grid. `solvable` is the historical alpha and carries no voltage criterion.
    """)

    for s <- report.interconnections do
      IO.puts("── #{s.name} (#{s.island_buses} buses, #{s.island_mw} MW island) ──")

      for {name, lo, hi} <- @bands do
        b = s.bands[name]
        band = if lo, do: "#{lo}-#{hi} pu", else: "no criterion"

        if b.feasible do
          window =
            if b.alpha_lo == b.alpha_hi,
              do: "alpha #{b.alpha_hi}",
              else: "alpha #{b.alpha_lo}..#{b.alpha_hi}"

          IO.puts(
            "  #{String.pad_trailing(name, 10)} #{String.pad_trailing(band, 14)} " <>
              "#{String.pad_trailing(window, 20)} " <>
              "#{String.pad_leading(to_string(round(b.served_mw)), 8)} MW  " <>
              "Vm #{b.vm_min}..#{b.vm_max}"
          )
        else
          IO.puts(
            "  #{String.pad_trailing(name, 10)} #{String.pad_trailing(band, 14)} " <>
              "NO FEASIBLE ALPHA — fails at both ends (overvoltage light, undervoltage heavy)"
          )
        end
      end

      solvable = s.bands["solvable"].served_mw
      normal = s.bands["normal"]

      if normal.feasible do
        IO.puts(
          "  => #{round(solvable - normal.served_mw)} MW of the solvable ceiling is NOT " <>
            "operable (#{Float.round((solvable - normal.served_mw) / max(solvable, 1.0) * 100, 1)}%)\n"
        )
      else
        IO.puts(
          "  => the whole #{round(solvable)} MW solvable ceiling is outside the normal " <>
            "band; there is no alpha at which every bus sits within it\n"
        )
      end
    end
  end
end
