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

  ## Main-island census (TOPO-3)

  The `SIMULATED-GRAPH CENSUS` block reports bridges, degree-1 buses, the load
  behind them, un-welded co-located yards, and stranded generation — every one
  of them measured on the graph `Grid.get_grid_snapshot/2` hands the solver,
  which is every component of 200 buses or more with loads scaled to `--hour`
  (Eastern's is two islands, not one). The block says so on every run, and
  that is not decoration: the same census over ALL components gives materially
  different fractions (Eastern 31.9% bridges against 27.8% on the simulated
  graph), so a threshold set on one graph passes vacuously on the other.
  Anything comparing these numbers to a benchmark has to compare against a
  benchmark measured on the same graph.

  Loading the snapshot a second time is what the block costs; `--no-census`
  skips it.

  ## Options

      --interconnection NAME|ID  restrict to one interconnection (repeatable)
      --hour ISO8601             scale loads to an EIA-930 hour
      --format text|json         default text; json keys are stable for CI diffs
      --census / --no-census     main-island bridge/deg-1/stranding census,
                                 default on
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
    census: :boolean,
    ab: :keep
  ]

  # The graph every number in the census block is measured on, printed with
  # the block so a threshold can never be compared against a fraction from a
  # different graph (TOPO-3).
  #
  # "Simulated" and not "main island": `Grid.get_grid_snapshot/2` keeps every
  # component of 200 buses or more, not only the largest, so the graph a
  # simulation runs on can be several islands (Eastern's is two — 59,817 buses
  # and 287). The census reports `simulated islands` so the difference is
  # visible rather than assumed away.
  @census_graph "simulated (Grid.get_grid_snapshot/2: every component >= 200 buses), loads scaled to --hour"

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

    report = attach_census(report, opts)

    case format do
      "json" -> IO.puts(encode_json(report))
      "text" -> render_text(report)
    end
  end

  # ---------------------------------------------------------------------------
  # Main-island census (TOPO-3)
  # ---------------------------------------------------------------------------

  defp attach_census(report, opts) do
    if Keyword.get(opts, :census, true) do
      scopes =
        Enum.map(report.scopes, fn scope ->
          case scope[:interconnection_id] do
            nil -> scope
            id -> Map.put(scope, :main_island_census, main_island_census(id, opts[:hour]))
          end
        end)

      Map.put(%{report | scopes: scopes}, :census_graph, @census_graph)
    else
      report
    end
  end

  defp main_island_census(interconnection_id, hour) do
    snapshot = PowerModel.Grid.get_grid_snapshot(interconnection_id, hour: hour)

    branches =
      Enum.map(snapshot.lines, &{:line, &1}) ++
        Enum.map(snapshot.transformers, &{:transformer, &1})

    bus_ids = Enum.map(snapshot.buses, & &1.id)
    load_by_bus = load_by_bus(snapshot.loads)
    island_load = load_by_bus |> Map.values() |> Enum.sum()

    degree = degree_by_bus(branches)
    deg1 = Enum.filter(bus_ids, &(Map.get(degree, &1, 0) <= 1))
    deg1_load = Enum.sum(Enum.map(deg1, &Map.get(load_by_bus, &1, 0.0)))

    bridge_edges = bridges(bus_ids, branches)
    isolated_load = load_behind_bridges(bus_ids, branches, bridge_edges, load_by_bus)

    stranding = Mix.Tasks.Grid.Census.Stranding.summarize(snapshot)

    %{
      graph: @census_graph,
      buses: length(bus_ids),
      branches: length(branches),
      islands: islands(bus_ids, branches),
      island_load_mw: island_load,
      bridges: MapSet.size(bridge_edges),
      bridge_share: share(MapSet.size(bridge_edges), length(branches)),
      degree_1_buses: length(deg1),
      degree_1_share: share(length(deg1), length(bus_ids)),
      degree_1_load_mw: deg1_load,
      degree_1_load_share: share(deg1_load, island_load),
      load_behind_bridges_mw: isolated_load,
      load_behind_bridges_share: share(isolated_load, island_load),
      colocated_unwelded_pairs: colocated_unwelded_pairs(snapshot, branches),
      stranded_generation_buses: stranding.generation.count,
      stranded_generation_gw: stranding.generation.nameplate_gw,
      radial_generation_buses: stranding.radial_generation.count,
      undersized_bank_buses: stranding.transformer_fed_load.count
    }
  end

  defp share(_numerator, 0), do: nil
  defp share(_numerator, +0.0), do: nil
  defp share(numerator, denominator), do: numerator / denominator

  defp islands(bus_ids, branches) do
    parent =
      Enum.reduce(branches, Map.new(bus_ids, &{&1, &1}), fn {_kind, b}, acc ->
        union(acc, b.from_bus_id, b.to_bus_id)
      end)

    bus_ids |> Enum.map(&find(parent, &1)) |> Enum.uniq() |> length()
  end

  defp load_by_bus(loads) do
    Enum.reduce(loads, %{}, fn load, acc ->
      Map.update(acc, load.bus_id, load.p_mw || 0.0, &(&1 + (load.p_mw || 0.0)))
    end)
  end

  defp degree_by_bus(branches) do
    Enum.reduce(branches, %{}, fn {_kind, b}, acc ->
      acc
      |> Map.update(b.from_bus_id, 1, &(&1 + 1))
      |> Map.update(b.to_bus_id, 1, &(&1 + 1))
    end)
  end

  # Adjacency keyed by bus, each entry {neighbour, edge_key}. The edge key
  # distinguishes parallel circuits, which is what keeps a double circuit from
  # being reported as a bridge.
  defp adjacency(branches) do
    branches
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {{_kind, b}, index}, acc ->
      acc
      |> Map.update(b.from_bus_id, [{b.to_bus_id, index}], &[{b.to_bus_id, index} | &1])
      |> Map.update(b.to_bus_id, [{b.from_bus_id, index}], &[{b.from_bus_id, index} | &1])
    end)
  end

  # Iterative Tarjan. Recursion would blow the stack on a 60,000-bus island,
  # and the depth is exactly what a stringy bridge-heavy network maximises.
  defp bridges(bus_ids, branches) do
    adj = adjacency(branches)

    {_disc, _low, _timer, found} =
      Enum.reduce(bus_ids, {%{}, %{}, 0, MapSet.new()}, fn root, {disc, low, timer, found} ->
        if Map.has_key?(disc, root) do
          {disc, low, timer, found}
        else
          dfs(
            [{root, nil, Map.get(adj, root, [])}],
            adj,
            Map.put(disc, root, timer),
            Map.put(low, root, timer),
            timer + 1,
            found
          )
        end
      end)

    found
  end

  defp dfs([], _adj, disc, low, timer, found), do: {disc, low, timer, found}

  defp dfs([{u, parent_edge, [{v, edge} | rest]} | tail], adj, disc, low, timer, found) do
    cond do
      edge == parent_edge ->
        dfs([{u, parent_edge, rest} | tail], adj, disc, low, timer, found)

      Map.has_key?(disc, v) ->
        low = Map.update!(low, u, &min(&1, Map.fetch!(disc, v)))
        dfs([{u, parent_edge, rest} | tail], adj, disc, low, timer, found)

      true ->
        frame = {v, edge, Map.get(adj, v, [])}

        dfs(
          [frame, {u, parent_edge, rest} | tail],
          adj,
          Map.put(disc, v, timer),
          Map.put(low, v, timer),
          timer + 1,
          found
        )
    end
  end

  defp dfs([{u, parent_edge, []} | tail], adj, disc, low, timer, found) do
    case tail do
      [] ->
        dfs([], adj, disc, low, timer, found)

      [{p, _pe, _rest} | _] ->
        low_u = Map.fetch!(low, u)
        low = Map.update!(low, p, &min(&1, low_u))

        found =
          if low_u > Map.fetch!(disc, p), do: MapSet.put(found, parent_edge), else: found

        dfs(tail, adj, disc, low, timer, found)
    end
  end

  # Load that at least one bridge separates from the network core: union-find
  # over the NON-bridge branches, then everything outside the largest
  # 2-edge-connected component. Summing per bridge instead would count nested
  # bridges several times over.
  defp load_behind_bridges(bus_ids, branches, bridge_edges, load_by_bus) do
    parent =
      branches
      |> Enum.with_index()
      |> Enum.reject(fn {_branch, index} -> MapSet.member?(bridge_edges, index) end)
      |> Enum.reduce(Map.new(bus_ids, &{&1, &1}), fn {{_kind, b}, _index}, acc ->
        union(acc, b.from_bus_id, b.to_bus_id)
      end)

    groups = Enum.group_by(bus_ids, &find(parent, &1))

    case groups do
      empty when empty == %{} ->
        0.0

      groups ->
        core = groups |> Enum.max_by(fn {_root, members} -> length(members) end) |> elem(0)

        groups
        |> Enum.reject(fn {root, _members} -> root == core end)
        |> Enum.flat_map(fn {_root, members} -> members end)
        |> Enum.map(&Map.get(load_by_bus, &1, 0.0))
        |> Enum.sum()
    end
  end

  defp find(parent, id) do
    case Map.get(parent, id, id) do
      ^id -> id
      next -> find(parent, next)
    end
  end

  defp union(parent, a, b) do
    root_a = find(parent, a)
    root_b = find(parent, b)
    if root_a == root_b, do: parent, else: Map.put(parent, root_a, root_b)
  end

  # TOPO-4's metric, on the simulated graph: same-level bus pairs within 250 m
  # with no branch directly between them.
  defp colocated_unwelded_pairs(snapshot, branches) do
    direct =
      MapSet.new(branches, fn {_kind, b} ->
        {min(b.from_bus_id, b.to_bus_id), max(b.from_bus_id, b.to_bus_id)}
      end)

    located =
      snapshot.buses
      |> Enum.flat_map(fn bus ->
        case bus.coordinates do
          %Geo.Point{coordinates: {lon, lat}} when is_number(bus.base_kv) ->
            [{bus.id, round(bus.base_kv / 5.0), lon, lat}]

          _ ->
            []
        end
      end)

    cells =
      Enum.group_by(located, fn {_id, _lk, lon, lat} -> {floor(lon / 0.01), floor(lat / 0.01)} end)

    Enum.reduce(located, 0, fn {id, lk, lon, lat}, count ->
      {cx, cy} = {floor(lon / 0.01), floor(lat / 0.01)}

      neighbours =
        for dx <- -1..1,
            dy <- -1..1,
            other <- Map.get(cells, {cx + dx, cy + dy}, []),
            do: other

      count +
        Enum.count(neighbours, fn {other_id, other_lk, olon, olat} ->
          other_id > id and other_lk == lk and
            not MapSet.member?(direct, {id, other_id}) and
            PowerModel.Ingestion.HIFLD.EndpointMatcher.haversine_km(lat, lon, olat, olon) <= 0.25
        end)
    end)
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
    render_main_island_census(scope[:main_island_census])

    if scope[:diff], do: render_diff(scope.diff)
  end

  defp render_main_island_census(nil), do: :ok

  defp render_main_island_census(c) do
    Mix.shell().info("\n  SIMULATED-GRAPH CENSUS  graph: #{c.graph}")

    row("buses / branches", "#{c.buses} / #{c.branches}", "")
    row("simulated islands", "#{c.islands} component(s) of >= 200 buses", "")
    row("bridges", "#{c.bridges} branches whose loss splits the island", pct(c.bridge_share))
    row("degree <= 1 buses", "#{c.degree_1_buses}", pct(c.degree_1_share))

    row(
      "load on them",
      "#{mw(c.degree_1_load_mw)} MW of #{mw(c.island_load_mw)} MW",
      pct(c.degree_1_load_share)
    )

    row(
      "load behind a bridge",
      "#{mw(c.load_behind_bridges_mw)} MW outside the core",
      pct(c.load_behind_bridges_share)
    )

    row(
      "co-located unwelded",
      "#{c.colocated_unwelded_pairs} same-level pairs <= 250 m apart",
      ""
    )

    row(
      "stranded generation",
      "#{c.stranded_generation_buses} buses, #{c.stranded_generation_gw} GW " <>
        "(#{c.radial_generation_buses} of them degree-1)",
      ""
    )

    row("undersized banks", "#{c.undersized_bank_buses} transformer-fed buses over 0.8x", "")
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
