defmodule Mix.Tasks.Grid.Census.LoadPlacement do
  @moduledoc """
  Where the estimated load sits against what the network under it can deliver
  (TOPO-2, TOPO-6, LIN13-B load half).

      mix grid.census load_placement
      mix grid.census load_placement --graph db
      mix grid.census load_placement --hour 2025-01-01T04:00:00Z --format json

  Every section is a rule `PowerModel.Ingestion.LoadEstimator` applies when it
  places load, scored on the network as it stands. A section at zero means the
  rule holds; the reallocation migration is gated on exactly these numbers.

  ## Which graph

  Unlike the rest of the census family this defaults to `--graph main-island`,
  the graph `Grid.get_grid_snapshot/2` builds and every simulation runs on,
  with loads scaled to the hour. A load number only means what a dispatcher
  means by it once it has been scaled, and a bus in a 40-bus fragment island
  can carry any MW at all without a solver ever seeing it. `--graph db` gives
  the all-components view with loads at their unscaled baseline.

  Note that the main-island snapshot keeps every component of 200 buses or
  more, so it is not always literally one island (Eastern's is two).

  ## Sections

    * **unservable** — degree-0 buses carrying load. Nothing can deliver it.
    * **radial over 200 MW** — degree <= 1 buses above 200 MW. One branch, and
      the whole of it lost on any trip of that branch.
    * **over branch rating** — degree-1 buses whose load exceeds the rating of
      the single branch feeding them, so the base case has no solution.
    * **over capability cap** — buses above `#{0.8}` x their connected
      capability. Capability takes line ratings as ingested but CLASS-STANDARD
      transformer ratings, never stored ones: `BusMapper.resize_transformers_to_through_load/0`
      sizes banks from the load on them, so a cap read off stored ratings is
      one the misplacement has already paid for.
    * **transformer-fed above bank** — the same test for buses with no line of
      their own, against their banks alone (TOPO-6).
    * **below the load-serving floor** — load on buses under 60 kV.
    * **split across yard levels** — substations carrying load on more than one
      of their levels. The old rule ranked candidate buses by distance from a
      county centroid, and every level of a yard stands at the same point, so a
      yard drew its county share once per level: SCE's GALE held 214.45 MW on
      its 115 kV bus and 214.45 MW again on its 33 kV bus.
    * **degree-1 load share** — the share of served load behind a single
      branch, per interconnection. The wave gate is 15%.

  ## Options

      --interconnection NAME     restrict to one interconnection (repeatable)
      --graph main-island|db     which graph to measure, default main-island
      --hour ISO8601             demand hour (main-island graph only)
      --limit N                  rows printed per section, default 15
      --format text|json         default text; json keys are stable for CI
  """

  use Mix.Task

  import Ecto.Query

  alias PowerModel.{Demand, Grid, Repo}
  alias PowerModel.Grid.{Bus, Load, Substation, TransmissionLine, Transformer}
  alias PowerModel.Ingestion.LoadEstimator

  require Logger

  @shortdoc "Load MW against the branch capability of the bus it sits on"

  @switches [
    interconnection: :keep,
    graph: :string,
    hour: :string,
    limit: :integer,
    format: :string
  ]

  @default_limit 15
  @graphs ~w(main-island db)

  # The gates DR-5 is scored on.
  @radial_limit_mw 200.0
  @deg1_share_limit 0.15
  @min_load_kv 60.0

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
  Build the census without printing it, so tests, the migration gate and other
  tasks can assert on the numbers rather than on formatted output.
  """
  def report(opts \\ []) do
    graph = Keyword.get(opts, :graph, "main-island")

    unless graph in @graphs do
      Mix.raise("--graph must be one of #{Enum.join(@graphs, ", ")}, got #{inspect(graph)}")
    end

    hour = parse_hour(opts[:hour]) || Demand.latest_demand_hour()
    names = Map.new(Repo.all(from s in Substation, select: {s.id, s.name}))

    interconnections =
      case Keyword.get_values(opts, :interconnection) do
        [] -> Grid.list_interconnections()
        given -> Enum.map(given, &fetch_interconnection!/1)
      end

    sections =
      Enum.map(interconnections, fn interconnection ->
        interconnection
        |> load_network(graph, hour)
        |> summarize(names)
        |> Map.put(:name, interconnection.name)
      end)

    %{
      census: "load_placement",
      graph: graph,
      graph_description: graph_description(graph),
      hour: graph == "main-island" && hour && DateTime.to_iso8601(hour),
      radial_limit_mw: @radial_limit_mw,
      deg1_share_limit: @deg1_share_limit,
      min_load_kv: @min_load_kv,
      limit: Keyword.get(opts, :limit, @default_limit),
      interconnections: sections,
      total_unservable: count(sections, :unservable),
      total_radial_over_limit: count(sections, :radial_over_limit),
      total_radial_over_limit_flat_only: flat_only(sections, :radial_over_limit),
      total_over_branch_rating: count(sections, :over_branch_rating),
      total_over_branch_rating_flat_only: flat_only(sections, :over_branch_rating),
      total_over_capability: count(sections, :over_capability),
      total_over_capability_flat_only: flat_only(sections, :over_capability),
      total_transformer_fed: count(sections, :transformer_fed),
      total_below_load_floor_mw: round1(sum(sections, & &1.below_load_floor.mw)),
      total_split_yards: count(sections, :split_yards),
      worst_deg1_share: sections |> Enum.map(& &1.deg1_share) |> Enum.max(fn -> 0.0 end)
    }
  end

  # ---------------------------------------------------------------------------
  # Measurement
  # ---------------------------------------------------------------------------

  @doc false
  def summarize(network, names \\ %{}) do
    caps = LoadEstimator.capability(network)
    load = sum_by(network.loads, & &1.bus_id, &(&1.p_mw || 0.0))
    single = single_branch_rating(network)

    # Datacenters are placed by `Grid.map_datacenters_to_grid/0` and held FLAT
    # by `Demand.scale_loads/3`; the estimator never writes them and cannot
    # move them. Splitting them out is what makes a section attributable to the
    # allocation rather than to another placer.
    flat =
      network.loads
      |> Enum.reject(&(Map.get(&1, :load_type, "constant_power") == "constant_power"))
      |> sum_by(& &1.bus_id, &(&1.p_mw || 0.0))

    rows =
      network.buses
      |> Enum.filter(&Map.has_key?(load, &1.id))
      |> Enum.map(fn bus ->
        cap = Map.get(caps, bus.id, empty_capability())

        %{
          bus_id: bus.id,
          base_kv: bus.base_kv,
          source_id: bus.source_id,
          substation: Map.get(names, yard_id(bus)),
          load_mw: Map.fetch!(load, bus.id),
          flat_mw: Map.get(flat, bus.id, 0.0),
          capability_mva: cap.capability_mva,
          cap_mw: cap.cap_mw,
          bank_mva: cap.bank_mva,
          line_mva: cap.line_mva,
          single_branch_mva: Map.get(single, bus.id),
          degree: cap.degree,
          line_degree: cap.line_degree
        }
      end)

    served = rows |> Enum.map(& &1.load_mw) |> Enum.sum()
    deg1 = rows |> Enum.filter(&(&1.degree <= 1)) |> Enum.map(& &1.load_mw) |> Enum.sum()

    %{
      buses: length(rows),
      served_mw: round1(served),
      deg1_mw: round1(deg1),
      deg1_share: if(served > 0.0, do: Float.round(deg1 / served, 4), else: 0.0),
      unservable: section(rows, &(&1.degree == 0 and &1.load_mw > 0.0)),
      radial_over_limit: section(rows, &(&1.degree <= 1 and &1.load_mw > @radial_limit_mw)),
      over_branch_rating:
        section(
          rows,
          &(&1.degree == 1 and is_number(&1.single_branch_mva) and
              &1.load_mw > &1.single_branch_mva)
        ),
      over_capability: section(rows, &(&1.load_mw > &1.cap_mw + 1.0e-6)),
      transformer_fed:
        section(rows, &(&1.line_degree == 0 and &1.load_mw > 0.8 * &1.bank_mva + 1.0e-6)),
      below_load_floor: section(rows, &(&1.base_kv < @min_load_kv and &1.load_mw > 0.0)),
      split_yards: split_yards(rows, network, names)
    }
  end

  # A yard carrying load on more than one of its levels: the county share was
  # counted once per level. Reported per yard, with the MW that is duplicated.
  defp split_yards(rows, network, names) do
    yards = Map.new(network.buses, &{&1.id, yard_id(&1)})

    grouped =
      rows
      |> Enum.filter(&(&1.load_mw > 0.0))
      |> Enum.group_by(&Map.get(yards, &1.bus_id))
      |> Map.delete(nil)
      |> Enum.filter(fn {_yard, buses} -> length(buses) > 1 end)
      |> Enum.map(fn {yard, buses} ->
        sorted = Enum.sort_by(buses, &(-&1.load_mw))
        [keep | rest] = sorted

        %{
          yard_id: yard,
          substation: Map.get(names, yard),
          levels: length(buses),
          load_mw: round1(Enum.sum(Enum.map(buses, & &1.load_mw))),
          duplicate_mw: round1(Enum.sum(Enum.map(rest, & &1.load_mw))),
          flat_mw: round1(Enum.sum(Enum.map(buses, & &1.flat_mw))),
          kept_bus_id: keep.bus_id
        }
      end)
      |> Enum.sort_by(&(-&1.duplicate_mw))

    %{
      count: length(grouped),
      mw: round1(Enum.sum(Enum.map(grouped, & &1.duplicate_mw))),
      flat_mw: round1(Enum.sum(Enum.map(grouped, & &1.flat_mw))),
      flat_only: Enum.count(grouped, &(&1.flat_mw >= &1.duplicate_mw - 1.0e-6)),
      rows: grouped
    }
  end

  defp section(rows, predicate) do
    matched = rows |> Enum.filter(predicate) |> Enum.sort_by(&(-&1.load_mw))

    %{
      count: length(matched),
      mw: round1(Enum.sum(Enum.map(matched, & &1.load_mw))),
      flat_mw: round1(Enum.sum(Enum.map(matched, & &1.flat_mw))),
      # Buses whose whole excess is flat load some other placer put there.
      flat_only: Enum.count(matched, &(&1.load_mw - &1.flat_mw <= &1.cap_mw + 1.0e-6)),
      rows: matched
    }
  end

  defp empty_capability do
    %{capability_mva: 0.0, cap_mw: 0.0, bank_mva: 0.0, line_mva: 0.0, degree: 0, line_degree: 0}
  end

  # The rating of the ONE branch a degree-1 bus hangs off, as ingested. Buses
  # with any other degree are absent.
  defp single_branch_rating(network) do
    branches =
      Enum.map(network.lines, &{&1.from_bus_id, &1.to_bus_id, &1.rating_a_mva || 0.0}) ++
        Enum.map(network.transformers, &{&1.from_bus_id, &1.to_bus_id, &1.rated_mva || 0.0})

    branches
    |> Enum.reduce(%{}, fn {from, to, mva}, acc ->
      acc
      |> Map.update(from, [mva], &[mva | &1])
      |> Map.update(to, [mva], &[mva | &1])
    end)
    |> Enum.flat_map(fn
      {bus_id, [mva]} -> [{bus_id, mva}]
      {_bus_id, _many} -> []
    end)
    |> Map.new()
  end

  defp yard_id(%{source: "substation", source_id: source_id}) when is_binary(source_id) do
    case Integer.parse(source_id) do
      {id, "_" <> _} -> id
      _ -> nil
    end
  end

  defp yard_id(_bus), do: nil

  defp sum_by(rows, key_fun, value_fun) do
    Enum.reduce(rows, %{}, fn row, acc ->
      case key_fun.(row) do
        nil -> acc
        key -> Map.update(acc, key, value_fun.(row), &(&1 + value_fun.(row)))
      end
    end)
  end

  defp count(sections, key), do: Enum.sum(Enum.map(sections, &Map.fetch!(&1, key).count))

  # How many of the counted buses are over only because of load the estimator
  # does not place: the rest are the allocation's own.
  defp flat_only(sections, key),
    do: Enum.sum(Enum.map(sections, &Map.fetch!(&1, key).flat_only))

  defp sum(sections, fun), do: sections |> Enum.map(fun) |> Enum.sum() |> Kernel.*(1.0)
  defp round1(value), do: Float.round(value * 1.0, 1)

  # --- the two graphs --------------------------------------------------------

  defp graph_description("main-island"),
    do: "Grid.get_grid_snapshot/2 — every component >= 200 buses, loads scaled to the hour"

  defp graph_description("db"),
    do: "every bus and in-service branch in the database, all components; loads unscaled"

  defp load_network(interconnection, "main-island", hour) do
    snapshot = Grid.get_grid_snapshot(interconnection.id, hour: hour)
    Map.take(snapshot, [:buses, :lines, :transformers, :loads])
  end

  defp load_network(interconnection, "db", _hour) do
    id = interconnection.id

    buses =
      from(b in Bus,
        where: b.interconnection_id == ^id,
        select: %{id: b.id, base_kv: b.base_kv, source: b.source, source_id: b.source_id}
      )
      |> Repo.all(timeout: :infinity)

    bus_ids = MapSet.new(buses, & &1.id)

    lines =
      from(l in TransmissionLine,
        where: l.status == "in_service" and not is_nil(l.from_bus_id) and not is_nil(l.to_bus_id),
        select: %{
          id: l.id,
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
        select: %{
          id: t.id,
          from_bus_id: t.from_bus_id,
          to_bus_id: t.to_bus_id,
          rated_mva: t.rated_mva
        }
      )
      |> Repo.all(timeout: :infinity)
      |> Enum.filter(&touches?(&1, bus_ids))

    loads =
      from(l in Load,
        join: b in Bus,
        on: l.bus_id == b.id,
        where: l.status == "in_service" and b.interconnection_id == ^id,
        select: %{bus_id: l.bus_id, p_mw: l.p_mw, load_type: l.load_type}
      )
      |> Repo.all(timeout: :infinity)

    %{buses: buses, lines: lines, transformers: transformers, loads: loads}
  end

  defp touches?(branch, bus_ids),
    do: MapSet.member?(bus_ids, branch.from_bus_id) or MapSet.member?(bus_ids, branch.to_bus_id)

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  @doc "Print a report built by `report/1`."
  def render_text(report) do
    limit = Map.get(report, :limit, @default_limit)

    IO.puts("""

    ══ load placement census ══
    graph: #{report.graph} — #{report.graph_description}
    #{if report.hour, do: "hour #{report.hour}", else: "loads at their unscaled baseline"}
    """)

    for section <- report.interconnections do
      IO.puts(
        "── #{section.name} (#{section.buses} buses carrying load, #{num(section.served_mw)} MW) ──"
      )

      render_section("unservable (degree 0)", section.unservable, limit)

      render_section(
        "radial above #{trunc(report.radial_limit_mw)} MW",
        section.radial_over_limit,
        limit
      )

      render_section("over their single branch's rating", section.over_branch_rating, limit)
      render_section("over 0.8 x connected capability", section.over_capability, limit)
      render_section("transformer-fed above 0.8 x bank", section.transformer_fed, limit)

      render_section(
        "below the #{trunc(report.min_load_kv)} kV load-serving floor",
        section.below_load_floor,
        limit
      )

      render_yards(section.split_yards, limit)

      IO.puts(
        "  degree-1 load share: #{pct(section.deg1_share)} " <>
          "(#{num(section.deg1_mw)} of #{num(section.served_mw)} MW, limit #{pct(report.deg1_share_limit)})"
      )

      IO.puts("")
    end

    IO.puts("TOTAL unservable buses: #{report.total_unservable}")

    IO.puts(
      "TOTAL radial buses above #{trunc(report.radial_limit_mw)} MW: " <>
        "#{report.total_radial_over_limit} (#{report.total_radial_over_limit_flat_only} flat-only)"
    )

    IO.puts(
      "TOTAL buses over their single branch's rating: #{report.total_over_branch_rating} " <>
        "(#{report.total_over_branch_rating_flat_only} flat-only)"
    )

    IO.puts(
      "TOTAL buses over 0.8 x capability: #{report.total_over_capability} " <>
        "(#{report.total_over_capability_flat_only} flat-only)"
    )

    IO.puts("TOTAL transformer-fed above 0.8 x bank: #{report.total_transformer_fed}")

    IO.puts(
      "TOTAL load below the load-serving floor: #{num(report.total_below_load_floor_mw)} MW"
    )

    IO.puts("TOTAL yards split across levels: #{report.total_split_yards}")
    IO.puts("WORST degree-1 load share: #{pct(report.worst_deg1_share)}")
  end

  defp render_section(label, section, limit) do
    %{count: count, flat_mw: flat_mw, flat_only: flat_only, rows: rows} = section

    IO.puts(
      "  #{label}: #{count} buses, #{num(section.mw)} MW" <>
        if(flat_mw > 0.0,
          do: " (#{num(flat_mw)} MW flat, #{flat_only} buses flat-only)",
          else: ""
        )
    )

    for row <- Enum.take(rows, limit) do
      IO.puts(
        "    bus #{row.bus_id} kv=#{num(row.base_kv)} load=#{num(row.load_mw)}MW " <>
          "(flat #{num(row.flat_mw)}) " <>
          "cap=#{num(row.cap_mw)}MW capability=#{num(row.capability_mva)}MVA " <>
          "(line #{num(row.line_mva)} + bank #{num(row.bank_mva)}) " <>
          "deg=#{row.degree} #{row.substation || row.source_id}"
      )
    end

    if count > limit, do: IO.puts("    ... #{count - limit} more")
  end

  defp render_yards(%{count: count, flat_mw: flat_mw, rows: rows} = section, limit) do
    IO.puts(
      "  yards split across levels: #{count} yards, #{num(section.mw)} MW counted twice or more" <>
        if(flat_mw > 0.0, do: " (#{num(flat_mw)} MW flat)", else: "")
    )

    for row <- Enum.take(rows, limit) do
      IO.puts(
        "    yard #{row.yard_id} #{row.substation || "-"} levels=#{row.levels} " <>
          "load=#{num(row.load_mw)}MW duplicate=#{num(row.duplicate_mw)}MW"
      )
    end

    if count > limit, do: IO.puts("    ... #{count - limit} more")
  end

  defp pct(share), do: "#{num(share * 100.0)}%"

  # Elixir renders 1400.0 as "1.4e3", which reads as a different number in a
  # column of MW.
  defp num(nil), do: "-"
  defp num(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

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
