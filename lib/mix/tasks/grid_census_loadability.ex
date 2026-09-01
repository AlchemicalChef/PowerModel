defmodule Mix.Tasks.Grid.Census.Loadability do
  @moduledoc """
  How much load each interconnection can actually CARRY, as opposed to how much
  the solver can find a root for.

      mix grid.census loadability
      mix grid.census loadability --interconnection ERCOT --format json
      mix grid.census loadability --controls --peak-multiplier 1.75

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

  ## `--controls`: the same census with the reactive plant switched on

  Measured 2026-08-23 (the table in REVIEW CAS-28), the uncontrolled network
  holds the normal band at NO load level on any interconnection. That is what a
  network with only fixed shunt plant does: it cannot absorb charging at light
  load and supply vars at heavy load with the same equipment. `--controls`
  runs every solve through `PowerModel.Solver.VoltageControl` — switched
  capacitor and reactor steps and LTC taps, derived by rule from the island —
  and reports the bands the CONTROLLED network holds.

  Each grid point is solved FRESH — devices at their stamped positions, flat
  start — so a banded row answers "is there a device configuration that holds
  this band at this load level", the planning question. (A continuation that
  carries positions upward from α 0.02 was measured on ERCOT 2026-08-31 to
  leave 1–2 buses outside the normal band at 0.15–0.25 where a fresh solve
  leaves none: hysteresis from an unphysically light start, not a property of
  the network.) The solvable-ceiling bisection is the exception: its probes
  sit above the highest converged grid point, where a cold solve diverges
  before any device can act, so they start from that point's positions and
  voltages and carry forward from each accepted probe. Device sizes are
  derived once from the UNSCALED island with `--peak-multiplier` (default
  #{"1.75"}, the ratio of national peak to the reference hour in the ingested
  EIA-930 record), so a bank does not change size with the α being solved.

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
  alias PowerModel.Solver.{FDPF, Partition, VoltageControl}

  @shortdoc "Load an interconnection can carry, against a voltage criterion"

  @base_mva 100.0
  @bisection_steps 7
  @solve_opts [base_mva: @base_mva, dense_nr_max_buses: 0, max_iterations: 400]

  @bands [
    {"solvable", nil, nil},
    {"emergency", 0.90, 1.10},
    {"normal", 0.95, 1.05}
  ]

  # Peak-to-reference-hour demand ratio used to size switched banks. The
  # reference hour sits at 0.35-0.51 of the stored allocation basis by BA, and
  # national demand across the ingested EIA-930 record spans 0.12x-1.73x it.
  @default_peak_multiplier 1.75

  @switches [
    interconnection: :keep,
    format: :string,
    hour: :string,
    controls: :boolean,
    peak_multiplier: :float
  ]

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

    controls = Keyword.get(opts, :controls, false)
    peak = Keyword.get(opts, :peak_multiplier, @default_peak_multiplier)

    %{
      census: "loadability",
      hour: hour && DateTime.to_iso8601(hour),
      controls: controls,
      peak_multiplier: if(controls, do: peak),
      bands: Enum.map(@bands, fn {n, lo, hi} -> %{name: n, min_pu: lo, max_pu: hi} end),
      interconnections: Enum.map(interconnections, &measure(&1, hour, controls, peak))
    }
  end

  defp measure(ic, hour, controls, peak) do
    island = island_for(ic, hour)
    island_mw = Enum.reduce(island.loads, 0.0, &(&2 + (&1.p_mw || 0.0)))

    # Devices are sized from the island as loaded, before any α scaling.
    ctrl = if controls, do: %{devices: VoltageControl.devices(island, peak_multiplier: peak)}

    # One pass over the grid serves both banded rows, and its highest
    # converged state seeds the bisection so the controlled ceiling is reached
    # by continuation rather than from a cold start at α = 1.
    {scan, carry} = scan(island, ctrl)

    bands =
      Map.new(@bands, fn
        {name, nil, nil} ->
          {alpha, sol} = bisect(island, nil, nil, ctrl, carry)
          {name, band_detail(sol, alpha, alpha, island_mw)}

        {name, lo, hi} ->
          {a_lo, a_hi, sol} = feasible_interval(scan, lo, hi)
          {name, band_detail(sol, a_lo, a_hi, island_mw)}
      end)

    %{
      name: ic.name,
      island_buses: length(island.buses),
      island_mw: Float.round(island_mw, 1),
      devices: ctrl && device_summary(ctrl.devices),
      bands: bands
    }
  end

  defp device_summary(devices) do
    shunts = Enum.filter(devices, &(&1.type == :switched_shunt))

    %{
      ltc: Enum.count(devices, &(&1.type == :ltc)),
      shunt_buses: length(shunts),
      cap_capacity_mvar:
        shunts |> Enum.map(&(&1.cap_step_mvar * &1.cap_steps)) |> Enum.sum() |> Float.round(1),
      reac_capacity_mvar:
        shunts |> Enum.map(&(&1.reac_step_mvar * &1.reac_steps)) |> Enum.sum() |> Float.round(1)
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

  # One solve at load scaling `a`. Uncontrolled: a flat-start FDPF solve, the
  # historical measurement, reproduced exactly. Controlled: the voltage-control
  # loop, from the stamped positions when `carry` is nil, else from `carry` —
  # the device positions and voltages of an accepted solve at a lower α.
  defp solve(island, a, nil, _carry) do
    case FDPF.solve(scale(island, a), @solve_opts) do
      {:ok, s} -> s
      _ -> nil
    end
  catch
    _, _ -> nil
  end

  defp solve(island, a, %{devices: devices}, carry) do
    opts =
      @solve_opts ++
        [devices: devices] ++
        case carry do
          %{state: state, warm: warm} -> [control_state: state, warm_start: warm]
          _ -> []
        end

    case VoltageControl.solve(scale(island, a), opts) do
      {:ok, s} -> s
      _ -> nil
    end
  catch
    _, _ -> nil
  end

  defp carry_from(nil, carry), do: carry
  defp carry_from(%{converged: false}, carry), do: carry

  defp carry_from(%{voltage_control: %{state: state}} = sol, _carry),
    do: %{state: state, warm: sol}

  defp carry_from(_sol, carry), do: carry

  defp acceptable?(nil, _lo, _hi), do: false

  defp acceptable?(sol, lo, hi) do
    sol.converged and
      (lo == nil or Enum.min(sol.vm_pu) >= lo) and
      (hi == nil or Enum.max(sol.vm_pu) <= hi)
  end

  # A coarse sweep, because a two-sided band is a window rather than a prefix
  # and bisection from zero cannot see it (see the moduledoc). Deliberately
  # coarse: the point is whether a feasible window EXISTS and roughly where,
  # not its edges to four decimals. Walked upward so the controlled rows can
  # carry state from one load level to the next.
  @scan_grid [0.02, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.75, 0.9, 1.0]

  # Every grid point solved once, FRESH (see the moduledoc). Returns the
  # `[{alpha, solution | nil}]` list and the carry from the highest converged
  # point, which seeds the bisection.
  defp scan(island, ctrl) do
    {pairs, carry} =
      Enum.reduce(@scan_grid, {[], nil}, fn a, {pairs, carry} ->
        sol = solve(island, a, ctrl, nil)
        {[{a, sol} | pairs], carry_from(sol, carry)}
      end)

    {Enum.reverse(pairs), carry}
  end

  defp feasible_interval(scan, lo, hi) do
    case Enum.filter(scan, fn {_a, sol} -> acceptable?(sol, lo, hi) end) do
      [] -> {nil, nil, nil}
      pairs -> {elem(hd(pairs), 0), elem(List.last(pairs), 0), elem(List.last(pairs), 1)}
    end
  end

  defp band_detail(_sol, nil, nil, _island_mw) do
    %{
      alpha_lo: nil,
      alpha_hi: nil,
      served_mw: nil,
      feasible: false,
      vm_min: nil,
      vm_max: nil,
      buses_under_0_90: nil,
      buses_over_1_10: nil,
      controls: nil
    }
  end

  defp band_detail(sol, a_lo, a_hi, island_mw) do
    %{
      alpha_lo: a_lo,
      alpha_hi: a_hi,
      served_mw: Float.round(a_hi * island_mw, 1),
      feasible: true,
      vm_min: sol && Float.round(Enum.min(sol.vm_pu), 4),
      vm_max: sol && Float.round(Enum.max(sol.vm_pu), 4),
      buses_under_0_90: sol && Enum.count(sol.vm_pu, &(&1 < 0.90)),
      buses_over_1_10: sol && Enum.count(sol.vm_pu, &(&1 > 1.10)),
      controls: sol && control_detail(sol.voltage_control)
    }
  end

  defp control_detail(nil), do: nil

  defp control_detail(vc) do
    %{
      rounds: vc.rounds,
      stopped: vc.stopped,
      ltc_moved: vc.ltc.moved,
      ltc_at_limit: vc.ltc.at_limit,
      cap_mvar_in: vc.shunt.cap_mvar_in,
      reac_mvar_in: vc.shunt.reac_mvar_in,
      latched: vc.ltc.latched + vc.shunt.latched
    }
  end

  # Returns {alpha, solution_at_alpha}. The controlled bisection carries the
  # state of the last ACCEPTED (lower) α into each probe, starting from the
  # scan's highest converged state.
  defp bisect(island, lo, hi, ctrl, seed) do
    top = solve(island, 1.0, ctrl, seed)

    if acceptable?(top, lo, hi) do
      {1.0, top}
    else
      {a_lo, _a_hi, sol, _carry} =
        Enum.reduce(1..@bisection_steps, {0.0, 1.0, nil, seed}, fn _, {a_lo, a_hi, best, carry} ->
          mid = (a_lo + a_hi) / 2
          sol = solve(island, mid, ctrl, carry)

          if acceptable?(sol, lo, hi),
            do: {mid, a_hi, sol, carry_from(sol, carry)},
            else: {a_lo, mid, best, carry}
        end)

      {Float.round(a_lo, 4), sol}
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
    controls =
      if report.controls,
        do: "controls ON (switched shunts + LTC, peak multiplier #{report.peak_multiplier})",
        else: "controls OFF (fixed plant only — the historical measurement)"

    IO.puts("""

    ══ loadability census ══
    hour #{report.hour}
    #{controls}
    Convergence is a property of the equations; operability is a property of the
    grid. `solvable` is the historical alpha and carries no voltage criterion.
    """)

    for s <- report.interconnections do
      IO.puts("── #{s.name} (#{s.island_buses} buses, #{s.island_mw} MW island) ──")

      if s.devices do
        d = s.devices

        IO.puts(
          "  devices: #{d.ltc} LTC, #{d.shunt_buses} shunt buses " <>
            "(#{round(d.cap_capacity_mvar)} MVAr capacitor, #{round(d.reac_capacity_mvar)} MVAr reactor capacity)"
        )
      end

      for {name, lo, hi} <- @bands do
        b = s.bands[name]
        band = if lo, do: "#{lo}-#{hi} pu", else: "no criterion"

        if b.feasible do
          window =
            if b.alpha_lo == b.alpha_hi,
              do: "alpha #{b.alpha_hi}",
              else: "alpha #{b.alpha_lo}..#{b.alpha_hi}"

          ctrl =
            case b.controls do
              nil ->
                ""

              c ->
                "  [#{c.rounds} rounds, #{c.stopped}; taps moved #{c.ltc_moved}, " <>
                  "caps in #{round(c.cap_mvar_in)} MVAr, reactors in #{round(c.reac_mvar_in)} MVAr]"
            end

          IO.puts(
            "  #{String.pad_trailing(name, 10)} #{String.pad_trailing(band, 14)} " <>
              "#{String.pad_trailing(window, 20)} " <>
              "#{String.pad_leading(to_string(round(b.served_mw)), 8)} MW  " <>
              "Vm #{b.vm_min}..#{b.vm_max}#{ctrl}"
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
