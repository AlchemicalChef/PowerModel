defmodule Mix.Tasks.Grid.Census.Stranding do
  @moduledoc """
  Plant and load MW against the branch capacity of the bus they sit on
  (LIN13-B), per interconnection.

      mix grid.census stranding
      mix grid.census stranding --graph main-island --hour 2025-01-01T04:00:00Z
      mix grid.census.stranding --format json

  A bus is *stranded* when the generation attached to it exceeds
  #{1.2} x the sum of its connected branch ratings: whatever the dispatcher
  asks of that plant, the network at its terminals cannot carry it, so the DC
  solution answers with an angle no AC solution can reproduce. The same test
  run against load is the mirror image, and is the metric DR-5's capacity cap
  is scored on.

  ## Which graph (this is not a detail)

  The same census over two different graphs gives two different numbers, and a
  threshold set on one of them passes vacuously on the other. Both are
  available and every report names the one it used:

    * `--graph db` (default) — every bus and every in-service branch in the
      database, all components. This is the graph the LIN13-B census was
      measured on, so before/after numbers are comparable to it.
    * `--graph main-island` — `Grid.get_grid_snapshot/2`, i.e. the graph every
      simulation actually runs, with loads scaled to `--hour`, and the only
      one where a load number means what a dispatcher would mean by it. Note
      the snapshot keeps every component of 200 buses or more, so this is not
      always literally one island (Eastern's is two).

  ## Sections

    * **generation** — buses whose attached nameplate exceeds the headroom.
      The TOTAL nameplate is the wave's `< 100 GW` gate.
    * **radial generation** — DR-1's rule for separating a genuine stranding
      from a dispatch artifact: degree exactly 1 AND nameplate above the
      single branch's rating. A bus like this cannot be fixed by rebalancing
      dispatch, only by moving the plant.
    * **load** — the same test against load, reported for DR-5.
    * **transformer-fed load** — buses whose ONLY branches are transformers
      and whose load exceeds #{0.8} x their nameplate: TOPO-6's population,
      which `BusMapper.resize_transformers_to_through_load/0` drives to zero.

  ## Options

      --interconnection NAME     restrict to one interconnection (repeatable)
      --graph db|main-island     which graph to measure, default db
      --hour ISO8601             demand hour (main-island graph only)
      --headroom F               stranding ratio, default 1.2
      --limit N                  rows printed per section, default 20
      --format text|json         default text; json keys are stable for CI
  """

  use Mix.Task

  import Ecto.Query

  alias PowerModel.{Demand, Grid, Repo}
  alias PowerModel.Grid.{Bus, Generator, Load, Substation, TransmissionLine, Transformer}

  require Logger

  @shortdoc "Generation/load MW against the connected branch capacity of their bus"

  @switches [
    interconnection: :keep,
    graph: :string,
    hour: :string,
    headroom: :float,
    limit: :integer,
    format: :string
  ]

  @default_headroom 1.2
  @default_limit 20

  # TOPO-6: a bank whose low side draws more than this share of its nameplate
  # is undersized for the substation it stands in.
  @bank_load_headroom 0.8

  @graphs ~w(db main-island)

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

    if format == "json", do: Mix.shell(Mix.Shell.Quiet)
    Mix.Task.run("app.start")
    Logger.configure(level: if(format == "json", do: :warning, else: :info))

    if format == "json" do
      :logger.update_handler_config(:default, :config, %{type: :standard_error})
    end

    report = report(opts)

    case format do
      "json" -> IO.puts(Jason.encode!(report, pretty: true))
      "text" -> render_text(report)
    end
  end

  @doc """
  Build the census without printing it, so tests and other tasks can assert on
  the numbers rather than on formatted output.
  """
  def report(opts \\ []) do
    graph = Keyword.get(opts, :graph, "db")

    unless graph in @graphs do
      Mix.raise("--graph must be one of #{Enum.join(@graphs, ", ")}, got #{inspect(graph)}")
    end

    headroom = Keyword.get(opts, :headroom, @default_headroom)
    hour = parse_hour(opts[:hour]) || Demand.latest_demand_hour()

    interconnections =
      case Keyword.get_values(opts, :interconnection) do
        [] -> Grid.list_interconnections()
        names -> Enum.map(names, &fetch_interconnection!/1)
      end

    names = Map.new(substation_names(), fn {id, name} -> {id, name} end)

    sections =
      Enum.map(interconnections, &census_one(&1, graph, hour, headroom, names))

    %{
      census: "stranding",
      graph: graph,
      graph_description: graph_description(graph),
      hour: graph == "main-island" && hour && DateTime.to_iso8601(hour),
      headroom: headroom,
      limit: Keyword.get(opts, :limit, @default_limit),
      bank_load_headroom: @bank_load_headroom,
      interconnections: sections,
      total_stranded_buses: Enum.sum(Enum.map(sections, & &1.generation.count)),
      total_stranded_nameplate_gw: Float.round(total(sections, & &1.generation.nameplate_gw), 1),
      total_radial_generation: Enum.sum(Enum.map(sections, & &1.radial_generation.count)),
      total_stranded_load_mw: Float.round(total(sections, & &1.load.mw), 1),
      total_undersized_banks: Enum.sum(Enum.map(sections, & &1.transformer_fed_load.count))
    }
  end

  defp graph_description("db"),
    do: "every bus and in-service branch in the database, all components; loads unscaled"

  defp graph_description("main-island"),
    do: "Grid.get_grid_snapshot/2 — every component >= 200 buses, loads scaled to the hour"

  # ---------------------------------------------------------------------------
  # Measurement
  # ---------------------------------------------------------------------------

  defp census_one(interconnection, graph, hour, headroom, names) do
    network = load_network(interconnection, graph, hour)

    network
    |> summarize(headroom: headroom, names: names)
    |> Map.merge(%{name: interconnection.name})
  end

  @doc """
  The four stranding sections for an already-loaded network
  (`%{buses:, lines:, transformers:, generators:, loads:}`).

  Exposed so `mix grid.accuracy` can report stranding off the same main-island
  snapshot it measures bridges on, rather than loading Eastern twice.
  """
  def summarize(network, opts \\ []) do
    headroom = Keyword.get(opts, :headroom, @default_headroom)
    names = Keyword.get(opts, :names, %{})
    rows = census_rows(network, names)

    stranded_generation =
      rows
      |> Enum.filter(&(&1.gen_mw > headroom * &1.branch_mva))
      |> Enum.sort_by(& &1.gen_mw, :desc)

    radial_generation =
      rows
      |> Enum.filter(&(&1.degree == 1 and &1.gen_mw > &1.branch_mva))
      |> Enum.sort_by(& &1.gen_mw, :desc)

    stranded_load =
      rows
      |> Enum.filter(&(&1.load_mw > headroom * &1.branch_mva))
      |> Enum.sort_by(& &1.load_mw, :desc)

    transformer_fed =
      rows
      |> Enum.filter(
        &(&1.line_degree == 0 and &1.transformer_mva > 0.0 and
            &1.load_mw > @bank_load_headroom * &1.transformer_mva)
      )
      |> Enum.sort_by(& &1.load_mw, :desc)

    %{
      buses: length(rows),
      generation: summarize_generation(stranded_generation),
      radial_generation: summarize_generation(radial_generation),
      load: summarize_load(stranded_load),
      transformer_fed_load: summarize_load(transformer_fed)
    }
  end

  defp summarize_generation(rows) do
    %{
      count: length(rows),
      nameplate_gw: Float.round(total(rows, & &1.gen_mw) / 1000.0, 2),
      rows: rows
    }
  end

  defp summarize_load(rows) do
    %{count: length(rows), mw: Float.round(total(rows, & &1.load_mw), 1), rows: rows}
  end

  # Enum.sum/1 of an empty list is the INTEGER zero, which Float.round/2
  # refuses.
  defp total(rows, fun), do: rows |> Enum.map(fun) |> Enum.sum() |> Kernel.*(1.0)

  # One row per bus that carries generation or load. Buses with neither cannot
  # be stranded and would only dilute the printed lists.
  defp census_rows(network, names) do
    gen = sum_by(network.generators, & &1.bus_id, &(&1.p_max_mw || 0.0))
    load = sum_by(network.loads, & &1.bus_id, &(&1.p_mw || 0.0))

    {line_mva, line_degree} = incidence(network.lines, &(&1.rating_a_mva || 0.0))
    {xfmr_mva, xfmr_degree} = incidence(network.transformers, &(&1.rated_mva || 0.0))

    network.buses
    |> Enum.filter(&(Map.has_key?(gen, &1.id) or Map.has_key?(load, &1.id)))
    |> Enum.map(fn bus ->
      %{
        bus_id: bus.id,
        base_kv: bus.base_kv,
        source_id: bus.source_id,
        substation: substation_name(names, bus),
        gen_mw: Map.get(gen, bus.id, 0.0),
        load_mw: Map.get(load, bus.id, 0.0),
        line_mva: Map.get(line_mva, bus.id, 0.0),
        transformer_mva: Map.get(xfmr_mva, bus.id, 0.0),
        branch_mva: Map.get(line_mva, bus.id, 0.0) + Map.get(xfmr_mva, bus.id, 0.0),
        line_degree: Map.get(line_degree, bus.id, 0),
        degree: Map.get(line_degree, bus.id, 0) + Map.get(xfmr_degree, bus.id, 0)
      }
    end)
  end

  defp sum_by(rows, key_fun, value_fun) do
    Enum.reduce(rows, %{}, fn row, acc ->
      case key_fun.(row) do
        nil -> acc
        key -> Map.update(acc, key, value_fun.(row), &(&1 + value_fun.(row)))
      end
    end)
  end

  # A branch contributes its rating and one degree to BOTH of its terminals.
  defp incidence(branches, rating_fun) do
    Enum.reduce(branches, {%{}, %{}}, fn branch, {mva, degree} ->
      rating = rating_fun.(branch)

      [branch.from_bus_id, branch.to_bus_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce({mva, degree}, fn bus_id, {m, d} ->
        {Map.update(m, bus_id, rating, &(&1 + rating)), Map.update(d, bus_id, 1, &(&1 + 1))}
      end)
    end)
  end

  # --- the two graphs --------------------------------------------------------

  defp load_network(interconnection, "main-island", hour) do
    snapshot = Grid.get_grid_snapshot(interconnection.id, hour: hour)

    %{
      buses: snapshot.buses,
      lines: snapshot.lines,
      transformers: snapshot.transformers,
      generators: snapshot.generators,
      loads: snapshot.loads
    }
  end

  defp load_network(interconnection, "db", _hour) do
    id = interconnection.id

    buses =
      from(b in Bus,
        where: b.interconnection_id == ^id,
        select: %{id: b.id, base_kv: b.base_kv, source_id: b.source_id, source: b.source}
      )
      |> Repo.all(timeout: :infinity)

    bus_ids = MapSet.new(buses, & &1.id)

    lines =
      from(l in TransmissionLine,
        where: l.status == "in_service" and not is_nil(l.from_bus_id) and not is_nil(l.to_bus_id),
        select: %{
          from_bus_id: l.from_bus_id,
          to_bus_id: l.to_bus_id,
          rating_a_mva: l.rating_a_mva
        }
      )
      |> Repo.all(timeout: :infinity)
      |> Enum.filter(&touches?(&1, bus_ids))

    transformers =
      from(t in Transformer,
        where: t.status == "in_service" and not is_nil(t.from_bus_id) and not is_nil(t.to_bus_id),
        select: %{from_bus_id: t.from_bus_id, to_bus_id: t.to_bus_id, rated_mva: t.rated_mva}
      )
      |> Repo.all(timeout: :infinity)
      |> Enum.filter(&touches?(&1, bus_ids))

    generators =
      from(g in Generator,
        join: b in Bus,
        on: g.bus_id == b.id,
        where: g.status == "in_service" and b.interconnection_id == ^id,
        select: %{bus_id: g.bus_id, p_max_mw: g.p_max_mw}
      )
      |> Repo.all(timeout: :infinity)

    loads =
      from(l in Load,
        join: b in Bus,
        on: l.bus_id == b.id,
        where: l.status == "in_service" and b.interconnection_id == ^id,
        select: %{bus_id: l.bus_id, p_mw: l.p_mw}
      )
      |> Repo.all(timeout: :infinity)

    %{
      buses: buses,
      lines: lines,
      transformers: transformers,
      generators: generators,
      loads: loads
    }
  end

  defp touches?(branch, bus_ids),
    do: MapSet.member?(bus_ids, branch.from_bus_id) or MapSet.member?(bus_ids, branch.to_bus_id)

  defp substation_names do
    from(s in Substation, select: {s.id, s.name}) |> Repo.all()
  end

  # Buses carry no substation FK; the owning substation is read off the
  # source_id the way BusMapper writes it.
  defp substation_name(names, %{source_id: source_id}) when is_binary(source_id) do
    case Integer.parse(source_id) do
      {id, "_" <> _} -> Map.get(names, id)
      _ -> nil
    end
  end

  defp substation_name(_names, _bus), do: nil

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  @doc "Print a report built by `report/1`."
  def render_text(report) do
    limit = Map.get(report, :limit, @default_limit)

    IO.puts("""

    ══ stranding census ══
    graph: #{report.graph} — #{report.graph_description}
    #{if report.hour, do: "hour #{report.hour}", else: "loads at their unscaled baseline"}
    stranded when MW > #{report.headroom} x the sum of connected branch ratings
    """)

    for section <- report.interconnections do
      IO.puts("── #{section.name} (#{section.buses} buses carrying generation or load) ──")

      render_section("generation stranded", section.generation, limit, :gen_mw)

      render_section(
        "  of which degree-1 (dispatch-invariant)",
        section.radial_generation,
        limit,
        :gen_mw
      )

      render_section("load stranded", section.load, limit, :load_mw)

      render_section(
        "transformer-fed load above #{report.bank_load_headroom} x bank",
        section.transformer_fed_load,
        limit,
        :load_mw
      )

      IO.puts("")
    end

    IO.puts("TOTAL stranded buses: #{report.total_stranded_buses}")
    IO.puts("TOTAL stranded nameplate: #{report.total_stranded_nameplate_gw} GW")
    IO.puts("TOTAL degree-1 stranded buses: #{report.total_radial_generation}")
    IO.puts("TOTAL stranded load: #{report.total_stranded_load_mw} MW")
    IO.puts("TOTAL undersized transformer-fed buses: #{report.total_undersized_banks}")
  end

  defp render_section(label, %{count: count, rows: rows} = section, limit, field) do
    magnitude =
      case section do
        %{nameplate_gw: gw} -> "#{gw} GW"
        %{mw: mw} -> "#{mw} MW"
      end

    IO.puts("  #{label}: #{count} buses, #{magnitude}")

    for row <- Enum.take(rows, limit) do
      IO.puts("    " <> format_row(row, field))
    end

    if count > limit, do: IO.puts("    ... #{count - limit} more")
  end

  defp format_row(row, field) do
    "bus #{row.bus_id} kv=#{fmt(row.base_kv, 1)} #{field}=#{fmt(Map.fetch!(row, field), 1)}MW " <>
      "branch=#{fmt(row.branch_mva, 1)}MVA (line #{fmt(row.line_mva, 1)} + xfmr #{fmt(row.transformer_mva, 1)}) " <>
      "deg=#{row.degree} #{row.substation || row.source_id}"
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
