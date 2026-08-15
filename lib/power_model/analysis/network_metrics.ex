defmodule PowerModel.Analysis.NetworkMetrics do
  @moduledoc """
  Network accuracy scoreboard (ROADMAP Phase 0, item 2).

  Answers one question with numbers instead of adjectives: *how much of the
  real network do we actually simulate, and how healthy is it at rest?*

  Four families of metric, per interconnection and pooled:

    * **Coverage / topology** — geolocated bus and branch counts versus the
      snapshot the simulator really runs, island count, largest-component
      share, isolated-bus count.
    * **Base case** — overload rate and loading distribution (median, p95),
      overall and by voltage class, from the *same* solve the cascade does.
    * **kV census** — branches whose endpoints disagree on `base_kv` beyond
      ±10%, and the >5:1 "welds" that item 11 of the roadmap exists to kill.
    * **Trip immunity** — the size of the `base_overloaded` set that
      `Cascade.init/3` builds; every branch in it is excluded from cascade
      trip consideration forever, so its size is a direct measure of how much
      of the network protection cannot see.

  ## Where the numbers come from

  The base case is not re-derived here. `measure/3` calls `Cascade.init/3`,
  which is what a real simulation calls, so `base_overloaded` and the
  per-branch loadings are the same objects a cascade would start from — a
  divergence between the scoreboard and a simulation is impossible by
  construction. Nothing in this module writes: DB access is read-only
  (`Grid.get_grid_snapshot/2` plus lean census queries) and A/B variants are
  built by mapping over an in-memory snapshot, never by touching a row.

  ## Definitions (fixed, so numbers stay comparable across runs)

  *Geolocated* is the population a perfect ingest would simulate: every bus
  of the interconnection carrying coordinates, and every in-service branch
  whose two endpoints are geolocated buses in that same interconnection.
  These predicates mirror `Grid.in_service_lines/1` /
  `Grid.in_service_transformers/1` exactly (self-loops out, HVDC out per
  LIN-6, cross-interconnection out).

  *Simulated* is what `Grid.get_grid_snapshot/2` returns: the components of
  that population large enough to clear the connectivity threshold. The gap
  between the two is the coverage number the roadmap tracks (Eastern 27%,
  Western 16.6%, ERCOT 30.6% when this was written).

  ## A/B mode

  `apply_overrides/2` returns a modified copy of an in-memory snapshot;
  feeding it back through `measure/3` and comparing with `diff/2` prices a
  parameter change before anyone migrates data:

      geo = NetworkMetrics.geolocated_population(ic_id)
      snap = PowerModel.Grid.get_grid_snapshot(ic_id)
      base = NetworkMetrics.measure("Western", geo, snap)
      variant_snap = NetworkMetrics.apply_overrides(snap, scale_rating_above_kv: {300.0, 2.0})
      variant = NetworkMetrics.measure("Western", geo, variant_snap)
      NetworkMetrics.diff(base, variant)
  """

  import Ecto.Query

  alias PowerModel.Failure.Cascade
  alias PowerModel.Grid.{Bus, Interconnection, Transformer, TransmissionLine}
  alias PowerModel.Repo
  alias PowerModel.Simulation.Cascading.IslandDetector

  @schema_version 1

  # Endpoints closer than this in kV are the same electrical level as far as
  # the census is concerned; anything wider is a modeling error on a line
  # (a transformer is *supposed* to change level, so lines are censused
  # separately from transformers).
  @kv_tolerance 0.10

  # A line whose endpoints differ by more than this ratio is a "weld": EHV
  # spliced straight onto distribution because the substation was collapsed
  # to a single bus. ROADMAP item 11.
  @weld_ratio 5.0

  # Dense B' assembly is O(n^2) in an Elixir list (ROADMAP item 18), so a
  # large island does not merely run slowly, it never returns. Islands above
  # this size are reported as skipped rather than attempted.
  @default_max_solve_buses 8_000

  # Wall-clock backstop for the base-case solve, in milliseconds.
  @default_solve_timeout_ms 120_000

  @voltage_classes [
    {"765kV+", 600.0, nil},
    {"500kV", 400.0, 600.0},
    {"345kV", 300.0, 400.0},
    {"230kV", 200.0, 300.0},
    {"100-199kV", 100.0, 200.0},
    {"<100kV", 0.0, 100.0}
  ]

  @unknown_class "unknown"

  @doc "Ordered voltage-class labels, high to low, plus `unknown`."
  def voltage_class_labels do
    Enum.map(@voltage_classes, fn {label, _, _} -> label end) ++ [@unknown_class]
  end

  @doc "Report schema version. Bump when JSON keys change meaning."
  def schema_version, do: @schema_version

  # ---------------------------------------------------------------------------
  # Top level: full DB-backed report
  # ---------------------------------------------------------------------------

  @doc """
  Measure every interconnection (or the subset named in `:interconnections`)
  and append a pooled `TOTAL` row.

  Options:

    * `:interconnections` — list of ids and/or names; defaults to all
    * `:hour` — `DateTime`; scales loads to that EIA-930 hour
    * `:base_mva` — solver base, default 100.0
    * `:overrides` — A/B overrides (see `apply_overrides/2`); when present
      each scope carries a `:variant` measurement and a `:diff`
    * `:max_solve_buses` — skip the base case above this island size
      (default #{@default_max_solve_buses}; `0` disables the guard)
    * `:solve_timeout_ms` — wall-clock cap on one base-case solve
  """
  def report(opts \\ []) do
    ics = select_interconnections(opts[:interconnections])
    overrides = Keyword.get(opts, :overrides, [])

    scopes =
      Enum.map(ics, fn ic ->
        geo = geolocated_population(ic.id)
        snapshot = PowerModel.Grid.get_grid_snapshot(ic.id, hour: opts[:hour])

        base = measure(ic.name, geo, snapshot, opts)
        base = Map.put(base, :interconnection_id, ic.id)

        if overrides == [] do
          base
        else
          variant =
            ic.name
            |> measure(geo, apply_overrides(snapshot, overrides), opts)
            |> Map.put(:interconnection_id, ic.id)

          Map.merge(base, %{variant: variant, diff: diff(base, variant)})
        end
      end)

    # A TOTAL row over a single scope is that scope printed twice.
    scopes = if length(scopes) > 1, do: scopes ++ [aggregate("TOTAL", scopes)], else: scopes

    %{
      schema_version: @schema_version,
      hour: opts[:hour] && DateTime.to_iso8601(opts[:hour]),
      base_mva: Keyword.get(opts, :base_mva, 100.0),
      overrides: describe_overrides(overrides),
      scopes: scopes
    }
  end

  @doc """
  Interconnections to measure. Accepts ids, names, or nil for all.
  """
  def select_interconnections(nil), do: Repo.all(from(i in Interconnection, order_by: i.id))

  def select_interconnections([]), do: select_interconnections(nil)

  def select_interconnections(selectors) do
    all = select_interconnections(nil)

    Enum.flat_map(selectors, fn sel ->
      Enum.filter(all, fn ic ->
        to_string(ic.id) == to_string(sel) or
          String.downcase(ic.name) == String.downcase(to_string(sel))
      end)
    end)
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  The geolocated population of one interconnection: the network a perfect
  ingest would hand the solver.

  Lean projections only — bus geometry and line geometry are never decoded,
  which is the difference between a second and a minute on Eastern. The
  predicates mirror `Grid.in_service_lines/1` and
  `Grid.in_service_transformers/1`.
  """
  def geolocated_population(interconnection_id) do
    buses =
      from(b in Bus,
        where: b.interconnection_id == ^interconnection_id and not is_nil(b.coordinates),
        select: %{id: b.id, base_kv: b.base_kv}
      )
      |> Repo.all()

    lines =
      from(tl in TransmissionLine,
        join: fb in Bus,
        on: tl.from_bus_id == fb.id,
        join: tb in Bus,
        on: tl.to_bus_id == tb.id,
        where:
          tl.status == "in_service" and fb.interconnection_id == ^interconnection_id and
            tl.from_bus_id != tl.to_bus_id and
            (is_nil(tl.line_type) or tl.line_type != "dc") and
            not is_nil(fb.coordinates) and not is_nil(tb.coordinates) and
            not is_nil(fb.interconnection_id) and
            fb.interconnection_id == tb.interconnection_id,
        select: %{
          id: tl.id,
          from_bus_id: tl.from_bus_id,
          to_bus_id: tl.to_bus_id,
          voltage_kv: tl.voltage_kv,
          rating_a_mva: tl.rating_a_mva
        }
      )
      |> Repo.all()

    transformers =
      from(t in Transformer,
        join: fb in Bus,
        on: t.from_bus_id == fb.id,
        join: tb in Bus,
        on: t.to_bus_id == tb.id,
        where:
          t.status == "in_service" and fb.interconnection_id == ^interconnection_id and
            t.from_bus_id != t.to_bus_id and
            not is_nil(fb.coordinates) and not is_nil(tb.coordinates) and
            not is_nil(fb.interconnection_id) and
            fb.interconnection_id == tb.interconnection_id,
        select: %{
          id: t.id,
          from_bus_id: t.from_bus_id,
          to_bus_id: t.to_bus_id,
          rated_mva: t.rated_mva
        }
      )
      |> Repo.all()

    %{buses: buses, lines: lines, transformers: transformers}
  end

  # ---------------------------------------------------------------------------
  # Pure measurement
  # ---------------------------------------------------------------------------

  @doc """
  Measure one scope. Pure: `geo` and `snapshot` are plain maps, and no
  database call happens here.

  `geo` is `%{buses: [%{id:, base_kv:}], lines: [...], transformers: [...]}`
  (see `geolocated_population/1`); `snapshot` is a solver snapshot. Passing
  the snapshot as both measures a network against itself, which is what the
  in-memory tests do.
  """
  def measure(scope, geo, snapshot, opts \\ []) do
    geo = normalize_population(geo)
    snapshot = normalize_snapshot(snapshot)

    # One BFS over the snapshot, shared: the coverage section reports how many
    # islands it found and the base case needs the largest one's size to decide
    # whether a solve is even attemptable.
    sim_islands = island_sizes(snapshot)

    %{
      scope: scope,
      topology: topology_metrics(geo, snapshot, sim_islands),
      base_case: base_case_metrics(snapshot, sim_islands, opts),
      kv_census: %{
        geolocated: kv_census(geo.lines, geo.buses),
        simulated: kv_census(snapshot.lines, snapshot.buses)
      }
    }
  end

  defp island_sizes(%{buses: buses, lines: lines, transformers: transformers}) do
    buses
    |> Enum.map(& &1.id)
    |> IslandDetector.detect(lines, transformers)
    |> Enum.map(&MapSet.size/1)
  end

  defp normalize_population(geo) do
    %{
      buses: Map.get(geo, :buses, []),
      lines: Map.get(geo, :lines, []),
      transformers: Map.get(geo, :transformers, [])
    }
  end

  defp normalize_snapshot(snapshot) do
    %{
      buses: Map.get(snapshot, :buses, []),
      lines: Map.get(snapshot, :lines, []),
      transformers: Map.get(snapshot, :transformers, []),
      generators: Map.get(snapshot, :generators, []),
      loads: Map.get(snapshot, :loads, []),
      water_facilities: Map.get(snapshot, :water_facilities, []),
      datacenters: Map.get(snapshot, :datacenters, [])
    }
  end

  # --- topology --------------------------------------------------------------

  defp topology_metrics(geo, snapshot, sim_islands) do
    geo_bus_ids = Enum.map(geo.buses, & &1.id)
    geo_buses = length(geo_bus_ids)

    sizes =
      geo_bus_ids
      |> IslandDetector.detect(geo.lines, geo.transformers)
      |> Enum.map(&MapSet.size/1)

    largest = Enum.max(sizes, fn -> 0 end)
    isolated = Enum.count(sizes, &(&1 == 1))

    geo_branches = length(geo.lines) + length(geo.transformers)
    sim_buses = length(snapshot.buses)
    sim_branches = length(snapshot.lines) + length(snapshot.transformers)

    %{
      geolocated_buses: geo_buses,
      geolocated_lines: length(geo.lines),
      geolocated_transformers: length(geo.transformers),
      geolocated_branches: geo_branches,
      simulated_buses: sim_buses,
      simulated_lines: length(snapshot.lines),
      simulated_transformers: length(snapshot.transformers),
      simulated_branches: sim_branches,
      simulated_bus_share: share(sim_buses, geo_buses),
      simulated_branch_share: share(sim_branches, geo_branches),
      island_count: length(sizes),
      simulated_island_count: length(sim_islands),
      largest_component_buses: largest,
      largest_component_share: share(largest, geo_buses),
      isolated_buses: isolated,
      isolated_bus_share: share(isolated, geo_buses),
      connected_bus_share: share(geo_buses - isolated, geo_buses)
    }
  end

  # --- base case -------------------------------------------------------------

  defp base_case_metrics(snapshot, sim_islands, opts) do
    branches = length(snapshot.lines) + length(snapshot.transformers)
    empty = empty_base_case(branches)
    max_buses = Keyword.get(opts, :max_solve_buses, @default_max_solve_buses)
    largest = Enum.max(sim_islands, fn -> 0 end)

    cond do
      snapshot.buses == [] ->
        %{empty | status: "skipped", reason: "empty snapshot"}

      max_buses > 0 and largest > max_buses ->
        %{empty | status: "skipped", reason: oversize_reason(largest, max_buses)}

      true ->
        case run_cascade_init(snapshot, opts) do
          {:ok, state} -> summarize_base_case(snapshot, state)
          {:error, reason} -> %{empty | status: "failed", reason: reason}
        end
    end
  end

  defp empty_base_case(branches) do
    %{
      status: "ok",
      reason: nil,
      branches: branches,
      branches_solved: 0,
      branches_rated: 0,
      base_overloaded: 0,
      overload_rate: nil,
      median_loading_pct: nil,
      p95_loading_pct: nil,
      load_mw: 0.0,
      dispatched_gen_mw: 0.0,
      dispatch_to_load: nil,
      dispatch_source: nil,
      dispatch_coverage: nil,
      by_voltage_class: %{},
      loading_samples: %{}
    }
  end

  defp oversize_reason(largest, max_buses) do
    "largest island has #{largest} buses, above the #{max_buses}-bus solve " <>
      "cap; dense B' assembly is O(n^2) (ROADMAP item 18). Raise with " <>
      "--max-solve-buses (0 disables)."
  end

  # `Cascade.init/3` rescues solver exceptions but nothing rescues a runaway
  # assembly, so the solve runs in an unlinked process under a wall clock.
  #
  # The hour goes through to the cascade as well as to the snapshot: scaling
  # load to a measured hour while leaving generation on the proportional rule
  # would score an operating point no dispatcher ever ran.
  defp run_cascade_init(snapshot, opts) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    timeout = Keyword.get(opts, :solve_timeout_ms, @default_solve_timeout_ms)
    init_opts = [hour: opts[:hour]]
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn -> send(parent, {ref, Cascade.init(snapshot, base_mva, init_opts)}) end)

    receive do
      {^ref, state} ->
        Process.demonitor(monitor, [:flush])
        {:ok, state}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, "base-case solve died: #{inspect(reason)}"}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, "base-case solve exceeded #{timeout} ms"}
    end
  end

  defp summarize_base_case(snapshot, state) do
    branches = branch_list(snapshot)
    loading = state.base_line_loading
    balance = Cascade.balance(state)

    # A branch counts toward the loading distribution only if it was solved
    # (present in the flow map) AND carries a rating: DCPowerFlow reports
    # loading 0.0 for an unrated branch, which would otherwise drag every
    # percentile toward zero and understate the overload rate.
    rated =
      for {key, branch, kv} <- branches,
          rating = branch_rating(branch),
          is_number(rating) and rating > 0,
          pct = Map.get(loading, key),
          is_number(pct) do
        {kind(key), voltage_class(kv), pct}
      end

    samples = group_samples(rated)
    all = pooled(samples)

    %{
      status: "ok",
      reason: nil,
      branches: length(branches),
      branches_solved: map_size(loading),
      branches_rated: length(all),
      base_overloaded: MapSet.size(state.base_overloaded),
      overload_rate: share(count_over(all), length(all)),
      median_loading_pct: percentile(all, 0.5),
      p95_loading_pct: percentile(all, 0.95),
      load_mw: balance.original_load_mw,
      dispatched_gen_mw: balance.dispatched_gen_mw,
      dispatch_to_load: safe_ratio(balance.dispatched_gen_mw, balance.original_load_mw),
      dispatch_source: to_string(Map.get(state, :dispatch_source) || "unknown"),
      dispatch_coverage: dispatch_summary(Map.get(state, :dispatch_coverage)),
      by_voltage_class: class_breakdown(samples),
      loading_samples: samples
    }
  end

  # Which rule produced the operating point the overloads were measured at:
  # `eia_fuel` (measured per-fuel dispatch) or `proportional` (capacity
  # pro-rata). An overload rate means something different under each, so the
  # scoreboard carries the provenance next to the number.
  #
  # Only the scalar headline of the coverage report is kept — the full map
  # holds per-BA/per-fuel breakdowns and a DateTime, none of which belongs in
  # an artifact CI diffs.
  @coverage_keys [:target_mw, :dispatched_mw, :unserved_mw, :units, :online_units, :bas]

  defp dispatch_summary(coverage) when is_map(coverage), do: Map.take(coverage, @coverage_keys)
  defp dispatch_summary(_), do: nil

  # Loadings are kept split by branch kind because a transformer is
  # classified by its high side while a line is classified by its own
  # voltage: pooling them turns "the 345 kV backbone" into something else
  # (ERCOT, 2026-08: 27.6% of 345 kV *lines* are overloaded at rest, 23.3%
  # once the step-downs hanging off them are mixed in).
  defp group_samples(rated) do
    rated
    |> Enum.group_by(fn {_kind, class, _pct} -> class end)
    |> Map.new(fn {class, entries} ->
      {class,
       %{
         lines: kind_samples(entries, :lines),
         transformers: kind_samples(entries, :transformers)
       }}
    end)
  end

  defp kind_samples(entries, wanted) do
    for {kind, _class, pct} <- entries, kind == wanted, do: pct
  end

  defp pooled(samples) do
    samples
    |> Enum.flat_map(fn {_class, %{lines: l, transformers: t}} -> l ++ t end)
    |> Enum.sort()
  end

  defp class_breakdown(samples) do
    Map.new(samples, fn {class, %{lines: lines, transformers: xfmrs}} ->
      {class,
       lines
       |> Kernel.++(xfmrs)
       |> loading_stats()
       |> Map.merge(%{lines: loading_stats(lines), transformers: loading_stats(xfmrs)})}
    end)
  end

  defp loading_stats(loadings) do
    sorted = Enum.sort(loadings)
    over = count_over(sorted)

    %{
      branches_rated: length(sorted),
      overloaded: over,
      overload_rate: share(over, length(sorted)),
      median_loading_pct: percentile(sorted, 0.5),
      p95_loading_pct: percentile(sorted, 0.95)
    }
  end

  defp count_over(sorted), do: Enum.count(sorted, &(&1 > 100.0))

  defp kind({:line, _id}), do: :lines
  defp kind({:transformer, _id}), do: :transformers

  # --- kV census -------------------------------------------------------------

  @doc """
  Census of endpoint voltage disagreement across a line collection.

  Transformers are excluded on purpose: changing level is their job. What is
  counted here is a *line* whose two ends claim different base voltages,
  which is either a bad bus assignment or a substation collapsed to one bus.
  `line_vs_bus_mismatch` catches the same defect from the other side — a
  500 kV line landing on a 13.8 kV bus.
  """
  def kv_census(lines, buses) do
    bus_kv = bus_kv_map(buses)

    init = %{
      lines: length(lines),
      comparable: 0,
      mismatch_10pct: 0,
      weld_5to1: 0,
      line_vs_bus_mismatch: 0,
      worst_ratio: nil
    }

    census =
      Enum.reduce(lines, init, fn line, acc ->
        from_kv = Map.get(bus_kv, line.from_bus_id)
        to_kv = Map.get(bus_kv, line.to_bus_id)
        line_kv = positive(Map.get(line, :voltage_kv))

        acc
        |> tally_endpoints(from_kv, to_kv)
        |> tally_line_vs_bus(line_kv, from_kv, to_kv)
      end)

    Map.put(census, :mismatch_rate, share(census.mismatch_10pct, census.comparable))
  end

  defp tally_endpoints(acc, from_kv, to_kv) when is_number(from_kv) and is_number(to_kv) do
    ratio = max(from_kv, to_kv) / min(from_kv, to_kv)

    %{
      acc
      | comparable: acc.comparable + 1,
        mismatch_10pct: acc.mismatch_10pct + bool_to_int(ratio > 1.0 + @kv_tolerance),
        weld_5to1: acc.weld_5to1 + bool_to_int(ratio > @weld_ratio),
        worst_ratio: max(acc.worst_ratio || 1.0, ratio)
    }
  end

  defp tally_endpoints(acc, _from_kv, _to_kv), do: acc

  defp tally_line_vs_bus(acc, line_kv, from_kv, to_kv) when is_number(line_kv) do
    off? =
      Enum.any?([from_kv, to_kv], fn kv ->
        is_number(kv) and kv > 0 and max(kv, line_kv) / min(kv, line_kv) > 1.0 + @kv_tolerance
      end)

    %{acc | line_vs_bus_mismatch: acc.line_vs_bus_mismatch + bool_to_int(off?)}
  end

  defp tally_line_vs_bus(acc, _line_kv, _from_kv, _to_kv), do: acc

  # ---------------------------------------------------------------------------
  # A/B overrides
  # ---------------------------------------------------------------------------

  @doc """
  Return a modified copy of an in-memory snapshot. Nothing is persisted; the
  original snapshot is untouched (Elixir terms are immutable, so the "copy"
  is structural sharing plus the changed fields).

  Supported overrides, applied left to right:

    * `{:scale_rating, factor}` — every branch rating
    * `{:scale_rating_above_kv, {kv, factor}}` — branches at or above `kv`
    * `{:scale_rating_below_kv, {kv, factor}}` — branches below `kv`
    * `{:min_rating_mva, mva}` — floor on every branch rating
    * `{:scale_reactance, factor}` / `{:scale_reactance_above_kv, {kv, factor}}`
    * `{:scale_load, factor}` — load p/q
    * `{:scale_generation, factor}` — generator `p_max_mw`

  A branch's kV is its own `voltage_kv` when it has one, otherwise the higher
  of its two endpoint `base_kv` values (a transformer is classified by its
  high side).
  """
  def apply_overrides(snapshot, []), do: snapshot

  def apply_overrides(snapshot, overrides) do
    bus_kv = bus_kv_map(Map.get(snapshot, :buses, []))
    Enum.reduce(overrides, snapshot, &apply_override(&1, &2, bus_kv))
  end

  defp apply_override({:scale_rating, factor}, snapshot, bus_kv) do
    scale_ratings(snapshot, bus_kv, fn _kv -> factor end)
  end

  defp apply_override({:scale_rating_above_kv, {kv, factor}}, snapshot, bus_kv) do
    scale_ratings(snapshot, bus_kv, fn branch_kv ->
      if is_number(branch_kv) and branch_kv >= kv, do: factor, else: 1.0
    end)
  end

  defp apply_override({:scale_rating_below_kv, {kv, factor}}, snapshot, bus_kv) do
    scale_ratings(snapshot, bus_kv, fn branch_kv ->
      if is_number(branch_kv) and branch_kv < kv, do: factor, else: 1.0
    end)
  end

  defp apply_override({:min_rating_mva, floor_mva}, snapshot, _bus_kv) do
    snapshot
    |> Map.update!(:lines, fn lines ->
      Enum.map(
        lines,
        &put_rating(&1, :rating_a_mva, max(rating_or(&1, :rating_a_mva, 0.0), floor_mva))
      )
    end)
    |> Map.update!(:transformers, fn xfs ->
      Enum.map(xfs, &put_rating(&1, :rated_mva, max(rating_or(&1, :rated_mva, 0.0), floor_mva)))
    end)
  end

  defp apply_override({:scale_reactance, factor}, snapshot, bus_kv) do
    scale_reactance(snapshot, fn _kv -> factor end, bus_kv)
  end

  defp apply_override({:scale_reactance_above_kv, {kv, factor}}, snapshot, bus_kv) do
    scale_reactance(
      snapshot,
      fn branch_kv -> if is_number(branch_kv) and branch_kv >= kv, do: factor, else: 1.0 end,
      bus_kv
    )
  end

  defp apply_override({:scale_load, factor}, snapshot, _bus_kv) do
    Map.update!(snapshot, :loads, fn loads ->
      Enum.map(loads, fn load ->
        load
        |> Map.put(:p_mw, (load.p_mw || 0.0) * factor)
        |> Map.put(:q_mvar, (Map.get(load, :q_mvar) || 0.0) * factor)
      end)
    end)
  end

  defp apply_override({:scale_generation, factor}, snapshot, _bus_kv) do
    Map.update!(snapshot, :generators, fn gens ->
      Enum.map(gens, &Map.put(&1, :p_max_mw, (&1.p_max_mw || 0.0) * factor))
    end)
  end

  defp apply_override(other, _snapshot, _bus_kv) do
    raise ArgumentError, "unknown network-metrics override: #{inspect(other)}"
  end

  defp scale_ratings(snapshot, bus_kv, factor_fun) do
    snapshot
    |> Map.update!(:lines, fn lines ->
      Enum.map(lines, fn line ->
        f = factor_fun.(line_kv(line, bus_kv))
        put_rating(line, :rating_a_mva, scaled(Map.get(line, :rating_a_mva), f))
      end)
    end)
    |> Map.update!(:transformers, fn xfs ->
      Enum.map(xfs, fn xf ->
        f = factor_fun.(branch_kv_from_buses(xf, bus_kv))
        put_rating(xf, :rated_mva, scaled(Map.get(xf, :rated_mva), f))
      end)
    end)
  end

  defp scale_reactance(snapshot, factor_fun, bus_kv) do
    snapshot
    |> Map.update!(:lines, fn lines ->
      Enum.map(lines, fn line ->
        scale_x(line, factor_fun.(line_kv(line, bus_kv)))
      end)
    end)
    |> Map.update!(:transformers, fn xfs ->
      Enum.map(xfs, fn xf ->
        scale_x(xf, factor_fun.(branch_kv_from_buses(xf, bus_kv)))
      end)
    end)
  end

  defp scale_x(branch, 1.0), do: branch
  defp scale_x(branch, factor), do: Map.put(branch, :x_pu, (branch.x_pu || 0.0) * factor)

  defp scaled(nil, _factor), do: nil
  defp scaled(value, factor), do: value * factor

  defp put_rating(branch, _key, nil), do: branch
  defp put_rating(branch, key, value), do: Map.put(branch, key, value)

  defp rating_or(branch, key, default), do: Map.get(branch, key) || default

  @doc """
  Human-readable echo of the override list, for the report header.
  """
  def describe_overrides([]), do: []

  def describe_overrides(overrides) do
    Enum.map(overrides, fn
      {key, {kv, factor}} -> "#{key}=#{fmt(kv)}:#{fmt(factor)}"
      {key, value} -> "#{key}=#{fmt(value)}"
    end)
  end

  # ---------------------------------------------------------------------------
  # Aggregation and diffing
  # ---------------------------------------------------------------------------

  @doc """
  Pool per-scope measurements into one. Counts sum; shares are recomputed
  from the sums; percentiles are recomputed over the pooled loading samples,
  never averaged (an average of medians is not a median).

  A scope whose base case was skipped contributes its topology and census but
  not its loadings, and the pooled `status` records how many did solve.
  """
  def aggregate(scope, scopes) do
    %{
      scope: scope,
      topology: aggregate_topology(Enum.map(scopes, & &1.topology)),
      base_case: aggregate_base_case(Enum.map(scopes, & &1.base_case)),
      kv_census: %{
        geolocated: aggregate_census(Enum.map(scopes, & &1.kv_census.geolocated)),
        simulated: aggregate_census(Enum.map(scopes, & &1.kv_census.simulated))
      }
    }
  end

  defp aggregate_topology(topos) do
    sums =
      Map.new(
        ~w(geolocated_buses geolocated_lines geolocated_transformers geolocated_branches
           simulated_buses simulated_lines simulated_transformers simulated_branches
           island_count simulated_island_count isolated_buses)a,
        fn key -> {key, sum_key(topos, key)} end
      )

    largest = topos |> Enum.map(& &1.largest_component_buses) |> Enum.max(fn -> 0 end)

    Map.merge(sums, %{
      largest_component_buses: largest,
      largest_component_share: share(largest, sums.geolocated_buses),
      simulated_bus_share: share(sums.simulated_buses, sums.geolocated_buses),
      simulated_branch_share: share(sums.simulated_branches, sums.geolocated_branches),
      isolated_bus_share: share(sums.isolated_buses, sums.geolocated_buses),
      connected_bus_share:
        share(sums.geolocated_buses - sums.isolated_buses, sums.geolocated_buses)
    })
  end

  defp aggregate_base_case(cases) do
    solved = Enum.filter(cases, &(&1.status == "ok"))

    samples =
      solved
      |> Enum.flat_map(&Map.to_list(&1.loading_samples))
      |> Enum.group_by(fn {class, _} -> class end, fn {_, kinds} -> kinds end)
      |> Map.new(fn {class, kind_maps} ->
        {class,
         %{
           lines: Enum.flat_map(kind_maps, & &1.lines),
           transformers: Enum.flat_map(kind_maps, & &1.transformers)
         }}
      end)

    all = pooled(samples)

    %{
      status: if(solved == [], do: "skipped", else: "ok"),
      reason: "#{length(solved)}/#{length(cases)} scopes solved",
      branches: sum_key(cases, :branches),
      branches_solved: sum_key(solved, :branches_solved),
      branches_rated: length(all),
      base_overloaded: sum_key(solved, :base_overloaded),
      overload_rate: share(count_over(all), length(all)),
      median_loading_pct: percentile(all, 0.5),
      p95_loading_pct: percentile(all, 0.95),
      load_mw: sum_key(solved, :load_mw),
      dispatched_gen_mw: sum_key(solved, :dispatched_gen_mw),
      dispatch_to_load:
        safe_ratio(sum_key(solved, :dispatched_gen_mw), sum_key(solved, :load_mw)),
      dispatch_source: merge_sources(solved),
      dispatch_coverage: merge_coverage(solved),
      by_voltage_class: class_breakdown(samples),
      loading_samples: samples
    }
  end

  # Scopes can land on different dispatch rules (one BA has EIA-930 coverage
  # for the hour, another does not), and averaging that away would hide it.
  defp merge_sources(solved) do
    case solved |> Enum.map(& &1.dispatch_source) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> nil
      sources -> sources |> Enum.sort() |> Enum.join("+")
    end
  end

  defp merge_coverage(solved) do
    case Enum.filter(solved, &is_map(&1.dispatch_coverage)) do
      [] ->
        nil

      covered ->
        Map.new(
          @coverage_keys,
          &{&1, sum_key(Enum.map(covered, fn s -> s.dispatch_coverage end), &1)}
        )
    end
  end

  defp aggregate_census(censuses) do
    sums =
      Map.new(~w(lines comparable mismatch_10pct weld_5to1 line_vs_bus_mismatch)a, fn key ->
        {key, sum_key(censuses, key)}
      end)

    worst = censuses |> Enum.map(&(&1.worst_ratio || 0.0)) |> Enum.max(fn -> 0.0 end)

    Map.merge(sums, %{
      mismatch_rate: share(sums.mismatch_10pct, sums.comparable),
      worst_ratio: if(worst > 0.0, do: worst, else: nil)
    })
  end

  @doc """
  Flat diff of two measurements: every numeric leaf that moved, keyed by its
  dotted path, as `%{base:, variant:, delta:}`. Unchanged leaves are omitted
  — a diff that lists everything hides the thing that changed.
  """
  def diff(base, variant) do
    base_flat = flatten(base)
    variant_flat = flatten(variant)

    base_flat
    |> Map.keys()
    |> Enum.concat(Map.keys(variant_flat))
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn path, acc ->
      b = Map.get(base_flat, path)
      v = Map.get(variant_flat, path)

      cond do
        b == v -> acc
        is_number(b) and is_number(v) -> Map.put(acc, path, %{base: b, variant: v, delta: v - b})
        true -> Map.put(acc, path, %{base: b, variant: v, delta: nil})
      end
    end)
  end

  # `loading_samples` is raw material for aggregation, not a metric; it would
  # otherwise flood the diff with thousands of per-branch paths.
  defp flatten(map, prefix \\ "") do
    Enum.reduce(map, %{}, fn
      {:loading_samples, _}, acc ->
        acc

      {key, value}, acc when is_map(value) and not is_struct(value) ->
        Map.merge(acc, flatten(value, path_join(prefix, key)))

      {key, value}, acc when is_number(value) ->
        Map.put(acc, path_join(prefix, key), value)

      _, acc ->
        acc
    end)
  end

  defp path_join("", key), do: to_string(key)
  defp path_join(prefix, key), do: prefix <> "." <> to_string(key)

  @doc """
  Strip internal sample lists so a report can be rendered or encoded.
  """
  def presentable(value) when is_map(value) and not is_struct(value) do
    value
    |> Map.drop([:loading_samples])
    |> Map.new(fn {k, v} -> {k, presentable(v)} end)
  end

  def presentable(value) when is_list(value), do: Enum.map(value, &presentable/1)
  def presentable(value), do: value

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  @doc """
  Voltage class label for a kV value. `nil`/non-positive is `"unknown"`.
  """
  def voltage_class(kv) when is_number(kv) and kv > 0 do
    Enum.find_value(@voltage_classes, @unknown_class, fn {label, low, high} ->
      if kv >= low and (is_nil(high) or kv < high), do: label
    end)
  end

  def voltage_class(_), do: @unknown_class

  @doc """
  Linear-interpolated percentile of an already-sorted list. `nil` for empty.
  """
  def percentile([], _p), do: nil
  def percentile([single], _p), do: single

  def percentile(sorted, p) do
    n = length(sorted)
    pos = p * (n - 1)
    low = trunc(pos)
    high = min(low + 1, n - 1)
    frac = pos - low
    Enum.at(sorted, low) * (1.0 - frac) + Enum.at(sorted, high) * frac
  end

  defp bus_kv_map(buses), do: Map.new(buses, &{&1.id, positive(Map.get(&1, :base_kv))})

  # `{type, id}` keys match DCPowerFlow's flow map exactly.
  defp branch_list(snapshot) do
    bus_kv = bus_kv_map(snapshot.buses)

    lines =
      Enum.map(snapshot.lines, fn line -> {{:line, line.id}, line, line_kv(line, bus_kv)} end)

    xfs =
      Enum.map(snapshot.transformers, fn xf ->
        {{:transformer, xf.id}, xf, branch_kv_from_buses(xf, bus_kv)}
      end)

    lines ++ xfs
  end

  defp branch_rating(%{rating_a_mva: rating}), do: rating
  defp branch_rating(%{rated_mva: rating}), do: rating
  defp branch_rating(_), do: nil

  defp line_kv(line, bus_kv) do
    positive(Map.get(line, :voltage_kv)) || branch_kv_from_buses(line, bus_kv)
  end

  defp branch_kv_from_buses(branch, bus_kv) do
    [Map.get(bus_kv, branch.from_bus_id), Map.get(bus_kv, branch.to_bus_id)]
    |> Enum.filter(&is_number/1)
    |> Enum.max(fn -> nil end)
  end

  defp positive(value) when is_number(value) and value > 0, do: value
  defp positive(_), do: nil

  defp share(_numerator, 0), do: nil
  defp share(numerator, denominator), do: numerator / denominator

  # Unlike share/2 the denominator here is a float that can legitimately be
  # 0.0 (a snapshot with no load at all).
  defp safe_ratio(_numerator, denominator) when denominator in [0, 0.0], do: nil
  defp safe_ratio(numerator, denominator), do: numerator / denominator

  defp sum_key(maps, key), do: Enum.reduce(maps, 0, fn m, acc -> acc + (Map.get(m, key) || 0) end)

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  defp fmt(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 4])

  defp fmt(value), do: to_string(value)
end
