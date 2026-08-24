defmodule Mix.Tasks.Grid.Census do
  @moduledoc """
  Targeted network censuses — the ones a repair round has to drive to zero.

  ## subtransmission

      mix grid.census subtransmission

  Every branch below #{100} kV whose base-case DC flow exceeds #{1.25} x its
  rate A, plus every branch (any voltage) whose DC angle difference exceeds 90
  degrees, at the as-dispatched operating point.

  These two lists are the same defect seen from two sides. A sub-100 kV line
  carrying 579 MW is either mislabeled voltage in HIFLD or the only path left
  after a mapping failure stranded the real one; either way the fix is the
  endpoint remap, never an edit to `x_pu` (ROADMAP item 8 re-scope — the
  extreme stored reactances are the estimator's recipe working correctly on a
  small voltage base). The >90 degree list is the AC-feasibility half of the
  same story: no AC solution exists near nominal voltage across a branch that
  DC says needs more than 90 degrees, since P = V_i V_j sin(dTheta) / x cannot
  reach it.

  The threshold is 1.25x, not 2x, deliberately: at 2x, real offenders hide.
  Line 85182 sits at 1.60x and line 73688 at 0.80x of a rating that is itself
  overstated, and both are genuine defects.

  Both sections print a TOTAL line, which is the number the repair rounds are
  gated on: it should reach 0.

  ## stranding

      mix grid.census stranding

  Generation and load MW against the connected branch capacity of the bus they
  sit on — the placement half of the same story. Documented in
  `Mix.Tasks.Grid.Census.Stranding`, which this task delegates to; its
  `--graph`, `--headroom` and `--limit` options are parsed here.

  ## load_placement

      mix grid.census load_placement

  Every rule `PowerModel.Ingestion.LoadEstimator` applies when it places load,
  scored on the network as it stands: unservable buses, radials above 200 MW,
  load over a branch's rating or over a bus's capability, load below the
  60 kV load-serving floor, and yards holding their county's share once per
  voltage level. Documented in `Mix.Tasks.Grid.Census.LoadPlacement`, which
  this task delegates to. Note it defaults to `--graph main-island`, not `db`.

  ## generator_interconnection

      mix grid.census generator_interconnection

  The generation-side mirror of `load_placement`: whether a plant's output can
  physically leave the bus it sits on, scored against the reference cases in
  `PowerModel.Reference`. Documented in
  `Mix.Tasks.Grid.Census.GeneratorInterconnection`, which this task delegates
  to. Reports `UNSCORED` rather than passing when the corpus is absent.

  ### Options

      --interconnection NAME     restrict to one interconnection (repeatable)
      --hour ISO8601             demand hour (default: latest ingested)
      --threshold F              overload ratio cut, default 1.25
      --max-kv KV                voltage ceiling for the census, default 100
      --limit N                  rows printed per section, default 40
      --balanced                 scale dispatch to match load exactly, instead
                                 of using the as-dispatched operating point
      --format text|json         default text; json keys are stable for CI
      --base-mva F               solver base, default 100.0
  """

  use Mix.Task

  alias PowerModel.{Demand, Grid}
  alias PowerModel.Failure.Cascade
  alias PowerModel.Grid.Ratings
  alias PowerModel.Solver.DCPowerFlow

  require Logger

  @shortdoc "Sub-transmission overload and >90-degree branch census"

  @switches [
    interconnection: :keep,
    hour: :string,
    threshold: :float,
    max_kv: :float,
    limit: :integer,
    balanced: :boolean,
    format: :string,
    base_mva: :float,
    # stranding only
    graph: :string,
    headroom: :float
  ]

  # `stranding` lives in Mix.Tasks.Grid.Census.Stranding (LIN13-B, DR-4) and
  # `load_placement` in Mix.Tasks.Grid.Census.LoadPlacement (TOPO-2, DR-5);
  # this task is the front door for all of them so the CLI reads as one census
  # family.
  @censuses ~w(subtransmission stranding load_placement generator_interconnection loadability)

  @default_threshold 1.25
  @default_max_kv 100.0
  @default_limit 40

  # A DC angle difference above this has no AC solution near nominal voltage.
  @angle_limit_deg 90.0

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("unrecognised option(s): #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    census =
      case rest do
        [name] when name in @censuses ->
          name

        [] ->
          Mix.raise("which census? one of: #{Enum.join(@censuses, ", ")}")

        other ->
          Mix.raise("unknown census #{inspect(other)}; one of: #{Enum.join(@censuses, ", ")}")
      end

    format = Keyword.get(opts, :format, "text")

    unless format in ~w(text json) do
      Mix.raise("--format must be text or json, got #{inspect(format)}")
    end

    # Nothing but JSON may reach stdout in JSON mode; Mix and the Ecto logger
    # both write there by default, and the logger level only settles after
    # app.start loads config (same pattern as mix grid.accuracy).
    if format == "json", do: Mix.shell(Mix.Shell.Quiet)
    Mix.Task.run("app.start")

    # The Ecto query logger runs at :debug in dev and would bury the census
    # under one SQL statement per snapshot table. The level can only be set
    # after app.start, which loads it from config.
    Logger.configure(level: if(format == "json", do: :warning, else: :info))

    if format == "json" do
      # Surviving warnings must not land inside the JSON document.
      :logger.update_handler_config(:default, :config, %{type: :standard_error})
    end

    report = report(census, opts)

    case format do
      "json" -> IO.puts(Jason.encode!(report, pretty: true))
      "text" -> render_text(report)
    end
  end

  @doc """
  Build the census report without printing it. Exposed so tests and other
  tasks can assert on the numbers rather than on formatted output.
  """
  def report("stranding", opts), do: Mix.Tasks.Grid.Census.Stranding.report(opts)
  def report("load_placement", opts), do: Mix.Tasks.Grid.Census.LoadPlacement.report(opts)

  def report("generator_interconnection", opts),
    do: Mix.Tasks.Grid.Census.GeneratorInterconnection.report(opts)

  def report("loadability", opts), do: Mix.Tasks.Grid.Census.Loadability.report(opts)

  def report("subtransmission", opts) do
    hour = parse_hour(opts[:hour]) || Demand.latest_demand_hour()
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    max_kv = Keyword.get(opts, :max_kv, @default_max_kv)
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    balanced? = Keyword.get(opts, :balanced, false)

    interconnections =
      case Keyword.get_values(opts, :interconnection) do
        [] -> Grid.list_interconnections()
        names -> Enum.map(names, &fetch_interconnection!/1)
      end

    sections =
      Enum.map(interconnections, &census_one(&1, hour, threshold, max_kv, base_mva, balanced?))

    %{
      census: "subtransmission",
      hour: hour && DateTime.to_iso8601(hour),
      threshold: threshold,
      max_kv: max_kv,
      operating_point: if(balanced?, do: "balanced", else: "as_dispatched"),
      angle_limit_deg: @angle_limit_deg,
      interconnections: sections,
      total_overloads: Enum.sum(Enum.map(sections, & &1.overload_count)),
      total_over_angle: Enum.sum(Enum.map(sections, & &1.over_angle_count))
    }
  end

  # ---------------------------------------------------------------------------
  # Measurement
  # ---------------------------------------------------------------------------

  defp census_one(interconnection, hour, threshold, max_kv, base_mva, balanced?) do
    snapshot = Grid.get_grid_snapshot(interconnection.id, hour: hour)
    state = Cascade.init(snapshot, base_mva, hour: hour)
    generators = operating_point(state, snapshot, balanced?)

    solution = DCPowerFlow.solve_islands(%{snapshot | generators: generators}, base_mva: base_mva)

    angles = angle_map(solution)

    branches =
      Enum.map(snapshot.lines, &{:line, &1}) ++
        Enum.map(snapshot.transformers, &{:transformer, &1})

    rows = Enum.map(branches, &row(&1, solution, angles))

    overloads =
      rows
      |> Enum.filter(fn r ->
        is_number(r.voltage_kv) and r.voltage_kv < max_kv and r.loading > threshold
      end)
      |> Enum.sort_by(& &1.loading, :desc)

    over_angle =
      rows
      |> Enum.filter(&(&1.angle_deg > @angle_limit_deg))
      |> Enum.sort_by(& &1.angle_deg, :desc)

    %{
      name: interconnection.name,
      buses: length(snapshot.buses),
      overload_count: length(overloads),
      over_angle_count: length(over_angle),
      overloads: overloads,
      over_angle: over_angle
    }
  end

  # The as-dispatched point is the one every other census and the simulation
  # itself run at. `--balanced` additionally removes the interconnection's
  # residual dispatch imbalance, which is a control for telling a real
  # topology defect from an imbalance artifact.
  defp operating_point(state, _snapshot, false), do: Cascade.dispatched_generators(state)

  defp operating_point(state, snapshot, true) do
    generators = Cascade.dispatched_generators(state)
    load = snapshot.loads |> Enum.map(& &1.p_mw) |> Enum.sum()
    gen = generators |> Enum.map(& &1.p_max_mw) |> Enum.sum()
    scale = if gen > 0.0, do: load / gen, else: 1.0

    Enum.map(generators, &%{&1 | p_max_mw: &1.p_max_mw * scale})
  end

  defp angle_map(solution) do
    solution.bus_ids
    |> Enum.zip(solution.va_rad)
    |> Map.new()
  end

  defp row({kind, branch}, solution, angles) do
    key = {kind, branch.id}
    flow = Map.get(solution.line_flows, key)
    {rate_a, _b, _c} = Ratings.branch_ratings(branch)

    flow_mw = if flow, do: flow.p_flow_mw, else: 0.0

    angle_deg =
      case {Map.get(angles, branch.from_bus_id), Map.get(angles, branch.to_bus_id)} do
        {a, b} when is_number(a) and is_number(b) -> abs(a - b) * 180.0 / :math.pi()
        _ -> 0.0
      end

    %{
      kind: Atom.to_string(kind),
      id: branch.id,
      voltage_kv: Map.get(branch, :voltage_kv),
      x_pu: Map.get(branch, :x_pu),
      length_km: Map.get(branch, :length_km),
      source: Map.get(branch, :source),
      from_bus_id: branch.from_bus_id,
      to_bus_id: branch.to_bus_id,
      flow_mw: flow_mw,
      rating_mva: rate_a,
      loading: if(is_number(rate_a) and rate_a > 0.0, do: abs(flow_mw) / rate_a, else: 0.0),
      angle_deg: angle_deg
    }
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  defp render_text(%{census: "stranding"} = report),
    do: Mix.Tasks.Grid.Census.Stranding.render_text(report)

  defp render_text(%{census: "load_placement"} = report),
    do: Mix.Tasks.Grid.Census.LoadPlacement.render_text(report)

  defp render_text(%{census: "generator_interconnection"} = report),
    do: Mix.Tasks.Grid.Census.GeneratorInterconnection.render_text(report)

  defp render_text(%{census: "loadability"} = report),
    do: Mix.Tasks.Grid.Census.Loadability.render_text(report)

  defp render_text(report) do
    limit = @default_limit

    IO.puts("""

    ══ subtransmission census ══
    hour #{report.hour}   operating point #{report.operating_point}
    below #{trunc(report.max_kv)} kV at more than #{report.threshold}x rate A, and any branch over #{trunc(report.angle_limit_deg)} degrees
    """)

    for section <- report.interconnections do
      IO.puts("── #{section.name} (#{section.buses} buses) ──")
      IO.puts("  sub-#{trunc(report.max_kv)} kV overloads: #{section.overload_count}")

      for r <- Enum.take(section.overloads, limit), do: IO.puts("    " <> format_row(r))

      if section.overload_count > limit do
        IO.puts("    ... #{section.overload_count - limit} more")
      end

      IO.puts(
        "  branches over #{trunc(report.angle_limit_deg)} degrees: #{section.over_angle_count}"
      )

      for r <- Enum.take(section.over_angle, limit), do: IO.puts("    " <> format_row(r))

      if section.over_angle_count > limit do
        IO.puts("    ... #{section.over_angle_count - limit} more")
      end

      IO.puts("")
    end

    IO.puts("TOTAL sub-#{trunc(report.max_kv)} kV overloads: #{report.total_overloads}")

    IO.puts(
      "TOTAL branches over #{trunc(report.angle_limit_deg)} degrees: #{report.total_over_angle}"
    )
  end

  defp format_row(r) do
    "#{r.kind} #{r.id} " <>
      "kv=#{fmt(r.voltage_kv, 1)} " <>
      "flow=#{fmt(r.flow_mw, 1)}MW " <>
      "rate=#{fmt(r.rating_mva, 1)} " <>
      "loading=#{fmt(r.loading * 100.0, 0)}% " <>
      "angle=#{fmt(r.angle_deg, 1)}deg " <>
      "x=#{fmt(r.x_pu, 5)} " <>
      "len=#{fmt(r.length_km, 1)}km " <>
      "buses #{r.from_bus_id}->#{r.to_bus_id}"
  end

  defp fmt(nil, _), do: "-"
  defp fmt(value, places) when is_float(value), do: Float.round(value, places)
  defp fmt(value, _), do: value

  defp parse_hour(nil), do: nil

  defp parse_hour(string) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _offset} -> dt
      {:error, reason} -> Mix.raise("--hour #{string} is not ISO8601: #{inspect(reason)}")
    end
  end

  defp fetch_interconnection!(name) do
    Grid.get_interconnection_by_name(name) ||
      Mix.raise("no interconnection named #{inspect(name)}")
  end
end
