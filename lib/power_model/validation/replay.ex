defmodule PowerModel.Validation.Replay do
  @moduledoc """
  EIA-930 replay harness — ROADMAP Phase 0, item 1.

  Replays historical hours through the model's own dispatch path and scores
  the result against what the grid actually did that hour, so every later
  accuracy change is a number instead of a claim.

  ## What is scored

  For each replayed hour the harness builds the snapshot the simulator would
  run, scales its loads to that hour's EIA-930 demand, dispatches it exactly
  as `PowerModel.Failure.Cascade.init/3` does, and reports four families of
  error:

    * **Fuel-mix total-variation distance** per balancing authority:
      `0.5 * Σ|share_model − share_actual|` over the eight canonical
      `PowerModel.Demand.BAFuelHour` fuels. This is the ROADMAP baseline
      metric — 0.243 measured under the old proportional dispatch, i.e.
      "24.3% of all generation sits on the wrong fuel". A TV distance is the
      fraction of generation that would have to move between fuels to make
      the model's mix match the measurement, so it reads directly as that
      sentence.
    * **Net-interchange error** per BA: implied (`dispatch − served load`)
      against EIA's reported `total_interchange_mw`. Fuel-anchored dispatch
      uses measured MW as absolute values, so a BA's generation minus its
      load should reproduce its real interchange; the residual is how far
      from that the modeled fleet lands. It is NOT an independent signal —
      see the decomposition below.
    * **Served-load error** per BA: the snapshot's scaled load against EIA
      demand. `Demand.scale_loads/3` makes this zero BY CONSTRUCTION wherever
      it produced a factor — it rescales each BA's snapshot loads to that
      BA's whole demand however few of the BA's buses survived into the
      snapshot. A non-zero value therefore means the BA got NO factor and
      kept the ~2× synthetic baseline (REVIEW ENE-8/ENE-13), which is the
      failure worth catching. `load_scale_factor` (served ÷ baseline) is
      reported alongside so the metric carries the size of the correction
      rather than an uninformative zero.
    * **Generation-conservation residual**: `Σdispatch − Σload` per
      electrical island, plus the MW the dispatch could not place at all
      (`unserved`, from units too small or below minimum load, and
      `unmatched`, measured MW in a BA that owns no unit of that fuel).
      Broken out per fuel, this is the scoreboard for REVIEW ENE-15 — the
      23.3 GW of measured nuclear the geolocated fleet cannot hold — so
      Phase 2 plant-mapping progress shows up here as the nuclear line
      falling.

  ## Two coverage universes — read the balance numbers through this

  The generation side and the load side of every balance metric are measured
  over different populations, and will stay that way until ROADMAP item 12
  (connectivity repair) lands:

    * **Load**: `Demand.scale_loads/3` puts a BA's ENTIRE demand on whichever
      of its buses reached the simulated component — measured nationally at
      `bus_coverage` ≈ 0.28 of geolocated buses. Served load therefore equals
      EIA demand exactly, on roughly a quarter of the real network.
    * **Generation**: only measured MW that found a mapped in-service unit of
      the right fuel is placed — `generation_coverage`, measured ≈ 0.86.

  So a negative conservation residual is mostly this asymmetry, NOT a
  dispatch failure: the load side is complete by construction and the
  generation side is short by exactly the MW no unit could hold. Both ratios
  are reported per BA and in every summary (and in the CI summary line) so
  the residual is never read as the dispatcher losing power.

  The interchange error is likewise not independent. With served load equal
  to demand, it decomposes exactly:

      interchange_error = generation_error + eia_identity_residual
                          − served_load_error

  where `generation_error` is model minus measured generation (the placement
  gap) and `eia_identity_residual` is EIA's own `generation − demand −
  interchange`, which does not close on 4% of BA-hours and never closes for
  BPAT, MISO or CISO. All three terms are reported per BA. Note that
  `Dispatch`'s own coverage `implied_interchange_mw` offers no cleaner
  alternative — it is built from the same scaled loads (`dispatch.ex:492`)
  and carries the identical distortion.

  ## Legacy comparison

  `mode: :legacy` scores the pre-Phase-1 rule (uniform pro-rata of island
  capacity, capped at 95%) on the same hours and the same snapshot, which is
  what makes a single command print the before/after.

  ## Scoring conventions

    * A BA is **scored** when it both reports per-fuel generation for the
      hour and owns at least one bus in the snapshot. BAs that report but own
      no snapshot bus are listed in `unmodeled_bas` with their MW rather than
      silently dropped — an omitted BA would otherwise flatter every average.
    * Model generation on a fuel EIA-930 does not report as generation
      (import pseudo-generators, blank fuel codes) is counted in an
      `"unclassified"` category that the measurement always has zero of, so
      it is penalised rather than hidden.
    * Shares are taken over non-negative MW. Storage charging is published as
      negative net generation; clamping keeps a share a share, and the raw
      signed totals stay in `actual_generation_mw`.
    * Both mixes empty ⇒ TV is `nil` (unscored). Exactly one empty ⇒ `1.0`.

  ## Scope

  `run/1` scores one national model assembled from every selected
  interconnection's snapshot, with each interconnection's islands carried
  through. A simulation runs one interconnection at a time; the difference
  matters only for the nine BAs whose buses straddle an interconnection
  boundary (MISO and SWPP span three), where scoring the union allocates
  each BA's measured MW once instead of once per snapshot.

  Topology is read once and only the loads are rescaled per hour, which is
  what `Grid.get_grid_snapshot/2` does internally with `:hour` — the same
  numbers at one topology read instead of one per hour.
  """

  import Ecto.Query

  require Logger

  alias PowerModel.Analysis.NetworkMetrics
  alias PowerModel.Demand
  alias PowerModel.Demand.BAFuelHour
  alias PowerModel.Dispatch
  alias PowerModel.Grid
  alias PowerModel.Grid.{BalancingAuthority, Bus}
  alias PowerModel.Repo
  alias PowerModel.Simulation.Cascading.IslandDetector

  @schema_version 1

  # Model MW on a fuel EIA-930 has no generation column for. Never present in
  # the measurement, so every MW here is a full contribution to TV distance.
  @unclassified "unclassified"

  @doc "Report schema version. Bump when JSON keys change meaning."
  def schema_version, do: @schema_version

  @doc "The fuel categories a mix is scored over: the canonical eight plus `unclassified`."
  def fuels, do: BAFuelHour.fuels() ++ [@unclassified]

  # ---------------------------------------------------------------------------
  # Top level
  # ---------------------------------------------------------------------------

  @doc """
  Replay hours and score them.

  ## Options

    * `:hours` — replay the N most recent COMPLETE hours (default 24)
    * `:from` / `:to` — replay every hour with per-fuel data in the closed
      `DateTime` range instead
    * `:interconnections` — ids and/or names; defaults to all
    * `:legacy` — also score the pre-Phase-1 proportional dispatch (default
      false)
    * `:reporting_slack` — an hour counts as complete when the number of BAs
      reporting per-fuel generation is at least `modal - slack` (default 1).
      The last hour of a bulk EIA file is a boundary hour where a third of
      the country has not reported yet (REVIEW ENE-13); replaying it would
      score the model against a partial measurement.
    * `:context` — a prebuilt `build_context/1` result (tests, repeated runs)
  """
  def run(opts \\ []) do
    hours = hours(opts)
    context = Keyword.get_lazy(opts, :context, fn -> build_context(opts) end)

    modes = if Keyword.get(opts, :legacy, false), do: [:measured, :legacy], else: [:measured]

    scored =
      Enum.map(hours, fn meta ->
        input = hour_input(context, meta.hour)
        {meta, Map.new(modes, fn mode -> {mode, score_hour(input, mode: mode)} end)}
      end)

    mode_reports =
      Enum.map(modes, fn mode ->
        mode
        |> collect_mode(scored)
        |> Map.put(:mode, mode)
      end)

    %{
      schema_version: @schema_version,
      hours: Enum.map(hours, & &1.hour),
      hour_census: hours,
      window: window(hours),
      scope: scope(context),
      modes: mode_reports,
      comparison: comparison(mode_reports)
    }
  end

  @doc """
  Hours to replay, newest last, as `%{hour:, reporting_bas:, complete?:}`.

  Without `:from`/`:to` this is the most recent `:hours` COMPLETE hours;
  with them it is every hour in range that has per-fuel data, completeness
  flagged rather than filtered so a deliberately chosen window is replayed
  as asked.
  """
  def hours(opts \\ []) do
    census = fuel_hour_census(Keyword.get(opts, :reporting_slack, 1))

    cond do
      opts[:from] || opts[:to] ->
        census.hours
        |> Enum.filter(&in_range?(&1.hour, opts[:from], opts[:to]))

      true ->
        census.hours
        |> Enum.filter(& &1.complete?)
        |> Enum.take(-max(Keyword.get(opts, :hours, 24), 1))
    end
  end

  defp in_range?(hour, from, to) do
    (is_nil(from) or DateTime.compare(hour, from) != :lt) and
      (is_nil(to) or DateTime.compare(hour, to) != :gt)
  end

  @doc """
  Per-hour reporting census of `ba_fuel_hour`: the modal number of BAs
  reporting, the completeness threshold, and every hour with its count.
  """
  def fuel_hour_census(slack \\ 1) do
    hours =
      Repo.all(
        from f in BAFuelHour,
          group_by: f.timestamp_utc,
          order_by: f.timestamp_utc,
          select: {f.timestamp_utc, count(f.ba_code, :distinct)}
      )

    counts = Enum.map(hours, &elem(&1, 1))
    modal = modal_count(counts)
    threshold = if modal, do: max(modal - slack, 1)

    %{
      modal_reporting_bas: modal,
      complete_threshold: threshold,
      hours:
        Enum.map(hours, fn {ts, n} ->
          %{hour: ts, reporting_bas: n, complete?: threshold != nil and n >= threshold}
        end)
    }
  end

  defp modal_count([]), do: nil

  defp modal_count(counts) do
    counts
    |> Enum.frequencies()
    # Ties break toward the larger count: two plateaus mean a partly-ingested
    # file and the fuller plateau is the real fleet.
    |> Enum.max_by(fn {count, freq} -> {freq, count} end)
    |> elem(0)
  end

  # ---------------------------------------------------------------------------
  # Model context (hour-invariant)
  # ---------------------------------------------------------------------------

  @doc """
  Build the hour-invariant half of a replay: the snapshots, their islands,
  and the BA lookups. Loads are the unscaled baseline; `hour_input/2` scales
  them per hour.
  """
  def build_context(opts \\ []) do
    ics = NetworkMetrics.select_interconnections(opts[:interconnections])

    snapshots =
      Enum.map(ics, fn ic ->
        snapshot = Grid.get_grid_snapshot(ic.id)

        islands =
          IslandDetector.detect(
            Enum.map(snapshot.buses, & &1.id),
            snapshot.lines,
            Map.get(snapshot, :transformers, [])
          )

        {ic, snapshot, islands}
      end)

    buses = Enum.flat_map(snapshots, fn {_ic, s, _i} -> s.buses end)
    bus_ba = Map.new(buses, &{&1.id, Map.get(&1, :balancing_authority_id)})

    # The dispatch holds contingency reserve per INTERCONNECTION (REVIEW
    # ENE-19), so the harness has to name each bus's system or it would
    # measure an operating point no simulation actually runs.
    ic_names = Map.new(ics, &{&1.id, &1.name})

    bus_interconnection =
      Map.new(buses, &{&1.id, Map.get(ic_names, Map.get(&1, :interconnection_id))})

    %{
      interconnections: Enum.map(ics, & &1.name),
      buses: buses,
      generators: Enum.flat_map(snapshots, fn {_ic, s, _i} -> s.generators end),
      base_loads: Enum.flat_map(snapshots, fn {_ic, s, _i} -> s.loads end),
      islands: Enum.flat_map(snapshots, fn {_ic, _s, i} -> i end),
      bus_ba: bus_ba,
      bus_interconnection: bus_interconnection,
      ba_codes: ba_codes(),
      ba_interconnection: ba_interconnection(snapshots),
      ba_bus_coverage: ba_bus_coverage(bus_ba)
    }
  end

  # What share of each BA's geolocated buses the snapshot actually contains.
  # The denominator is every geolocated bus of the BA, not just those inside
  # the selected interconnections, because that is the universe the LOAD side
  # is scaled against: `Demand.scale_loads/3` puts the BA's whole demand on
  # whatever slice survived, so a BA at 0.3 coverage carries 100% of its
  # demand on 30% of its buses.
  defp ba_bus_coverage(bus_ba) do
    geolocated =
      from(b in Bus,
        where: not is_nil(b.coordinates) and not is_nil(b.balancing_authority_id),
        group_by: b.balancing_authority_id,
        select: {b.balancing_authority_id, count(b.id)}
      )
      |> Repo.all()
      |> Map.new()

    in_snapshot = bus_ba |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.frequencies()

    Map.new(geolocated, fn {ba_id, total} ->
      {ba_id,
       %{
         snapshot_buses: Map.get(in_snapshot, ba_id, 0),
         geolocated_buses: total,
         coverage: safe_div(Map.get(in_snapshot, ba_id, 0), total)
       }}
    end)
  end

  # Every BA, not just the modeled ones: the unmodeled BAs are reported by
  # code too, and there are only a few dozen rows.
  defp ba_codes do
    from(ba in BalancingAuthority, select: {ba.id, ba.code}) |> Repo.all() |> Map.new()
  end

  # A BA is labelled with the interconnection holding most of its snapshot
  # buses; the nine cross-boundary BAs get their majority side.
  defp ba_interconnection(snapshots) do
    snapshots
    |> Enum.flat_map(fn {ic, snapshot, _islands} ->
      snapshot.buses
      |> Enum.map(& &1.balancing_authority_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.map(fn {ba_id, count} -> {ba_id, {ic.name, count}} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {ba_id, entries} ->
      {name, _count} = Enum.max_by(entries, &elem(&1, 1))
      {ba_id, name}
    end)
  end

  @doc """
  The complete, database-free input for one replayed hour: the context's
  topology with loads scaled to that hour and the hour's measurements
  attached.
  """
  def hour_input(context, %DateTime{} = hour) do
    %{
      hour: hour,
      generators: context.generators,
      loads: Demand.scale_loads(context.base_loads, context.buses, hour),
      baseline_loads: context.base_loads,
      bus_ba: context.bus_ba,
      bus_interconnection: Map.get(context, :bus_interconnection, %{}),
      islands: context.islands,
      fuel_totals: Demand.fuel_generation_at(hour),
      demand: Demand.demand_at(hour),
      interchange: Demand.interchange_at(hour),
      ba_codes: context.ba_codes,
      ba_interconnection: Map.get(context, :ba_interconnection, %{}),
      ba_bus_coverage: Map.get(context, :ba_bus_coverage, %{})
    }
  end

  # ---------------------------------------------------------------------------
  # Scoring one hour (no database access)
  # ---------------------------------------------------------------------------

  @doc """
  Score one hour. `input` is a `hour_input/2` map; every key is data, so this
  runs against fixtures with no repository at all. Only `:hour`,
  `:generators`, `:loads`, `:bus_ba` and `:fuel_totals` are required — the
  measurement maps and lookups default to empty.

  Options: `:mode` — `:measured` (default) or `:legacy`.
  """
  def score_hour(input, opts \\ []) do
    input = normalize_input(input)
    mode = Keyword.get(opts, :mode, :measured)
    {dispatch, source, coverage} = dispatch_for(input, mode)

    by_ba = score_bas(input, dispatch)
    islands = score_islands(input, dispatch)
    gap = gap_by_fuel(coverage)

    %{
      hour: input.hour,
      mode: mode,
      dispatch_source: source,
      by_ba: by_ba,
      unmodeled_bas: unmodeled_bas(input),
      islands: islands,
      gap_by_fuel: gap,
      totals: totals(input, by_ba, dispatch, islands, coverage, gap)
    }
  end

  defp normalize_input(input) do
    defaults = %{
      loads: [],
      baseline_loads: Map.get(input, :loads, []),
      islands: nil,
      bus_interconnection: %{},
      fuel_totals: %{},
      demand: %{},
      interchange: %{},
      ba_codes: %{},
      ba_interconnection: %{},
      ba_bus_coverage: %{}
    }

    Map.merge(defaults, input)
  end

  @doc """
  The dispatch a simulation would run for this hour, as
  `{dispatch, source, coverage}`.

  `:measured` is the path `PowerModel.Failure.Cascade.init/3` takes,
  including its fallback: no per-fuel data for the hour means the
  proportional rule, said out loud. `:legacy` forces that fallback.
  """
  def dispatch_for(input, mode \\ :measured)

  def dispatch_for(input, :measured) do
    input = normalize_input(input)

    dispatch_opts = [
      bus_ba: input.bus_ba,
      bus_interconnection: input.bus_interconnection,
      islands: input.islands,
      loads: input.loads,
      fuel_totals: input.fuel_totals
    ]

    case Dispatch.for_hour(input.generators, input.hour, dispatch_opts) do
      {:ok, %{dispatch: dispatch, coverage: coverage}} ->
        {dispatch, :eia_fuel, coverage}

      {:error, reason} ->
        Logger.info(
          "Replay #{DateTime.to_iso8601(input.hour)}: measured dispatch declined " <>
            "(#{inspect(reason)}); scoring the proportional fallback, as a simulation would"
        )

        {legacy_dispatch(input.generators, input.loads, input.islands), :proportional, nil}
    end
  end

  def dispatch_for(input, :legacy) do
    input = normalize_input(input)
    {legacy_dispatch(input.generators, input.loads, input.islands), :proportional, nil}
  end

  @doc """
  The pre-Phase-1 dispatch rule: within each island every in-service unit
  runs at the same fraction of its nameplate, sized to island load and capped
  at 95% so the slack bus keeps headroom. Capacity factors are not consulted.

  Mirrors `PowerModel.Failure.Cascade`'s private `balance_dispatch_per_island`
  so a before/after runs on one command; `replay_test.exs` pins the two
  together against `Cascade.init/3`.
  """
  def legacy_dispatch(generators, loads, islands) do
    islands = islands || [:all]

    Enum.reduce(islands, %{}, fn island, dispatch ->
      island_gens = Enum.filter(generators, &in_island?(&1, island))
      island_loads = Enum.filter(loads, &in_island?(&1, island))

      Map.merge(dispatch, balance_dispatch(island_gens, island_loads))
    end)
  end

  defp balance_dispatch(generators, loads) do
    total_load = sum_by(loads, & &1.p_mw)
    total_capacity = sum_by(generators, & &1.p_max_mw)

    if total_capacity <= 0 or total_load <= 0 do
      Map.new(generators, &{&1.id, 0.0})
    else
      ratio = min(total_load / total_capacity, 0.95)
      Map.new(generators, &{&1.id, &1.p_max_mw * ratio})
    end
  end

  defp in_island?(_item, :all), do: true
  defp in_island?(item, island), do: MapSet.member?(island, Map.get(item, :bus_id))

  # --- per balancing authority ----------------------------------------------

  defp score_bas(input, dispatch) do
    model_fuel = model_fuel_mw(input, dispatch)
    model_load = sum_by_ba(input.loads, input.bus_ba, & &1.p_mw)

    baseline_load =
      sum_by_ba(Map.get(input, :baseline_loads) || input.loads, input.bus_ba, & &1.p_mw)

    modeled = modeled_ba_ids(input)

    input.fuel_totals
    |> Map.keys()
    |> Enum.filter(&MapSet.member?(modeled, &1))
    |> Enum.map(&score_ba(&1, input, model_fuel, model_load, baseline_load))
    |> Enum.sort_by(&(-&1.actual_generation_mw))
  end

  defp score_ba(ba_id, input, model_fuel, model_load, baseline_load) do
    model_mix = Map.get(model_fuel, ba_id, %{})
    actual_mix = Map.get(input.fuel_totals, ba_id, %{})

    model_gen = sum_values(model_mix)
    actual_gen = sum_values(actual_mix)
    load_mw = Map.get(model_load, ba_id, 0.0)
    baseline_mw = Map.get(baseline_load, ba_id, 0.0)
    demand_mw = Map.get(input.demand, ba_id)
    reported_ix = Map.get(input.interchange, ba_id)

    %{
      ba_id: ba_id,
      ba_code: Map.get(input.ba_codes, ba_id) || "BA #{ba_id}",
      interconnection: Map.get(input.ba_interconnection, ba_id),
      fuel_mix_tv: tv_distance(model_mix, actual_mix),
      model_generation_mw: model_gen,
      actual_generation_mw: actual_gen,
      generation_error_mw: model_gen - actual_gen,
      model_fuel_mw: fill_fuels(model_mix),
      actual_fuel_mw: fill_fuels(actual_mix),
      served_load_mw: load_mw,
      baseline_load_mw: baseline_mw,
      load_scale_factor: safe_div(load_mw, baseline_mw),
      eia_demand_mw: demand_mw,
      served_load_error_mw: demand_mw && load_mw - demand_mw,
      served_load_error_pct: relative_error(load_mw, demand_mw),
      implied_interchange_mw: model_gen - load_mw,
      reported_interchange_mw: reported_ix,
      interchange_error_mw: reported_ix && model_gen - load_mw - reported_ix,
      # EIA's own trio need not close (measured: 4% of BA-hours miss by more
      # than 1 GW, and BPAT/MISO/CISO miss on nearly every hour). Carrying it
      # here keeps the interchange decomposition exact instead of charging
      # EIA's inconsistency to the model.
      eia_identity_residual_mw: reported_ix && demand_mw && actual_gen - demand_mw - reported_ix,
      # The two coverage universes, side by side: `bus_coverage` is the share
      # of the BA's geolocated buses the snapshot holds (the LOAD side lands
      # 100% of demand on it regardless), `generation_coverage` is the share
      # of measured MW the mapped fleet could hold.
      bus_coverage: get_in(input.ba_bus_coverage, [ba_id, :coverage]),
      snapshot_buses: get_in(input.ba_bus_coverage, [ba_id, :snapshot_buses]),
      generation_coverage: safe_div(model_gen, actual_gen),
      dispatch_to_load: safe_div(model_gen, load_mw)
    }
  end

  defp relative_error(_actual, nil), do: nil
  defp relative_error(_actual, reference) when reference == 0.0, do: nil
  defp relative_error(actual, reference), do: (actual - reference) / reference

  # Every BA with a bus in the snapshot, whether or not any unit sits on it.
  defp modeled_ba_ids(input) do
    input.bus_ba |> Map.values() |> Enum.reject(&is_nil/1) |> MapSet.new()
  end

  # Reporting BAs the snapshot does not contain: their measurement is not
  # scored, so it is reported instead of vanishing.
  defp unmodeled_bas(input) do
    modeled = modeled_ba_ids(input)

    input.fuel_totals
    |> Enum.reject(fn {ba_id, _fuels} -> MapSet.member?(modeled, ba_id) end)
    |> Enum.map(fn {ba_id, fuels} ->
      %{
        ba_id: ba_id,
        ba_code: Map.get(input.ba_codes, ba_id) || "BA #{ba_id}",
        actual_generation_mw: sum_values(fuels),
        eia_demand_mw: Map.get(input.demand, ba_id)
      }
    end)
    |> Enum.sort_by(&(-&1.actual_generation_mw))
  end

  defp model_fuel_mw(input, dispatch) do
    Enum.reduce(input.generators, %{}, fn generator, acc ->
      case Map.get(input.bus_ba, Map.get(generator, :bus_id)) do
        nil ->
          acc

        ba_id ->
          fuel = scored_fuel(generator)
          mw = Map.get(dispatch, generator.id, 0.0)

          Map.update(acc, ba_id, %{fuel => mw}, fn mix ->
            Map.update(mix, fuel, mw, &(&1 + mw))
          end)
      end
    end)
  end

  defp scored_fuel(generator) do
    fuel = Dispatch.fuel_for(generator)
    if fuel in BAFuelHour.fuels(), do: fuel, else: @unclassified
  end

  @doc """
  Total-variation distance between two fuel mixes given as `%{fuel => mw}`:
  `0.5 * Σ|share_model − share_actual|`, in `[0, 1]`.

  Shares are taken over non-negative MW (storage charging publishes negative
  net generation). `nil` when both mixes are empty; `1.0` when exactly one
  is — a model producing nothing where the grid produced something has all
  of its generation on the wrong fuel.
  """
  def tv_distance(model_mw, actual_mw) do
    model = shares(model_mw)
    actual = shares(actual_mw)

    cond do
      is_nil(model) and is_nil(actual) -> nil
      is_nil(model) or is_nil(actual) -> 1.0
      true -> 0.5 * sum_by(fuel_keys(model, actual), &abs(share(model, &1) - share(actual, &1)))
    end
  end

  defp fuel_keys(model, actual) do
    model |> Map.keys() |> Kernel.++(Map.keys(actual)) |> Enum.uniq()
  end

  defp share(mix, fuel), do: Map.get(mix, fuel, 0.0)

  defp shares(mix) do
    positive = Map.new(mix, fn {fuel, mw} -> {fuel, max(mw, 0.0)} end)
    total = sum_values(positive)

    if total <= 0.0, do: nil, else: Map.new(positive, fn {fuel, mw} -> {fuel, mw / total} end)
  end

  defp fill_fuels(mix), do: Map.new(fuels(), &{&1, Map.get(mix, &1, 0.0)})

  # --- conservation ----------------------------------------------------------

  defp score_islands(input, dispatch) do
    islands = input.islands || [MapSet.new(Map.keys(input.bus_ba))]

    residuals =
      Enum.map(islands, fn island ->
        generation =
          sum_by(input.generators, fn g ->
            if in_island?(g, island), do: Map.get(dispatch, g.id, 0.0), else: 0.0
          end)

        load = sum_by(input.loads, fn l -> if in_island?(l, island), do: l.p_mw, else: 0.0 end)

        %{
          buses: island_size(island),
          generation_mw: generation,
          load_mw: load,
          residual_mw: generation - load
        }
      end)

    %{
      count: length(residuals),
      residual_mw: sum_by(residuals, & &1.residual_mw),
      abs_residual_mw: sum_by(residuals, &abs(&1.residual_mw)),
      worst: residuals |> Enum.sort_by(&(-abs(&1.residual_mw))) |> List.first()
    }
  end

  defp island_size(:all), do: nil
  defp island_size(island), do: MapSet.size(island)

  # Measured MW the fleet could not hold, split by fuel: `unserved` is MW
  # offered to a BA's units of that fuel that no unit could take (all at
  # capability, or the remainder below a minimum load), `unmatched` is MW in
  # a BA that owns no in-service unit of that fuel at all. Their sum per fuel
  # is REVIEW ENE-15's gap; the nuclear line is the one Phase 2 must close.
  defp gap_by_fuel(nil), do: nil

  defp gap_by_fuel(coverage) do
    unserved =
      coverage.by_ba
      |> Map.values()
      |> Enum.flat_map(&Map.to_list(&1.by_fuel))
      |> Enum.reduce(%{}, fn {fuel, stat}, acc ->
        Map.update(
          acc,
          fuel,
          stat.target_mw - stat.dispatched_mw,
          &(&1 + stat.target_mw - stat.dispatched_mw)
        )
      end)

    unmatched =
      Enum.reduce(coverage.unmatched, %{}, fn entry, acc ->
        Map.update(acc, entry.fuel, entry.mw, &(&1 + entry.mw))
      end)

    Map.new(BAFuelHour.fuels(), fn fuel ->
      unserved_mw = Map.get(unserved, fuel, 0.0)
      unmatched_mw = Map.get(unmatched, fuel, 0.0)

      {fuel,
       %{
         unserved_mw: unserved_mw,
         unmatched_mw: unmatched_mw,
         unplaced_mw: unserved_mw + unmatched_mw
       }}
    end)
  end

  # --- hour totals -----------------------------------------------------------

  defp totals(input, by_ba, dispatch, islands, coverage, gap) do
    scored = Enum.reject(by_ba, &is_nil(&1.fuel_mix_tv))
    tvs = Enum.map(scored, & &1.fuel_mix_tv)

    demand_weights = Enum.map(scored, &max(&1.eia_demand_mw || 0.0, 0.0))
    generation_weights = Enum.map(scored, &max(&1.actual_generation_mw, 0.0))

    # The interchange decomposition only adds up over ONE population, so
    # every one of its terms is summed over exactly the BAs that have a
    # reported interchange to compare against.
    ix_bas = Enum.filter(by_ba, &is_number(&1.interchange_error_mw))
    interchange_errors = Enum.map(ix_bas, & &1.interchange_error_mw)

    load_errors = by_ba |> Enum.map(& &1.served_load_error_mw) |> Enum.reject(&is_nil/1)
    load_error_pcts = by_ba |> Enum.map(& &1.served_load_error_pct) |> Enum.filter(&is_number/1)

    %{
      bas_scored: length(scored),
      bas_reporting: map_size(input.fuel_totals),
      tv_load_weighted: weighted_mean(tvs, demand_weights),
      tv_generation_weighted: weighted_mean(tvs, generation_weights),
      tv_mean: mean(tvs),
      tv_median: median(tvs),
      tv_worst: worst_ba(scored),
      interchange_mae_mw: mean(Enum.map(interchange_errors, &abs/1)),
      interchange_bias_mw: sum(interchange_errors),
      # bias == placement + eia_residual − load_error, exactly.
      interchange_from_placement_mw: sum_by(ix_bas, & &1.generation_error_mw),
      interchange_from_eia_residual_mw: sum_by(ix_bas, &(&1.eia_identity_residual_mw || 0.0)),
      interchange_from_load_error_mw: sum_by(ix_bas, &(&1.served_load_error_mw || 0.0)),
      interchange_bas: length(ix_bas),
      served_load_mae_mw: mean(Enum.map(load_errors, &abs/1)),
      served_load_bias_mw: sum(load_errors),
      served_load_mape: mean(Enum.map(load_error_pcts, &abs/1)),
      # A BA whose loads kept the synthetic baseline: the demand scaling
      # found no factor for it, so its "served load" is fiction.
      bas_load_unscaled: Enum.count(by_ba, &unscaled?/1),
      # A BA whose whole demand landed on a fraction of its buses. Scoping a
      # snapshot to one interconnection does this to every BA that straddles
      # the boundary: an ERCOT snapshot holds a handful of MISO-labelled
      # buses and `Demand.scale_loads/3` puts all 69 GW of MISO demand on
      # them. Counted against the same sane range Demand itself warns on.
      bas_scale_factor_outsized: Enum.count(by_ba, &outsized_scale?/1),
      outsized_scale_load_mw:
        by_ba |> Enum.filter(&outsized_scale?/1) |> sum_by(& &1.served_load_mw),
      # Median, not mean: a handful of BAs whose synthetic baseline is a
      # rounding error scale up by two orders of magnitude and would carry
      # any average with them.
      load_scale_factor_median: median(Enum.map(by_ba, & &1.load_scale_factor)),
      model_generation_mw: dispatch |> Map.values() |> Enum.sum(),
      model_load_mw: sum_by(input.loads, & &1.p_mw),
      actual_generation_mw: sum_by(scored, & &1.actual_generation_mw),
      eia_demand_mw: sum_by(scored, &(&1.eia_demand_mw || 0.0)),
      # The asymmetry the conservation residual is mostly made of: the load
      # side carries every scored BA's full demand, the generation side only
      # the measured MW that found a mapped unit, and the buses under both
      # are a fraction of the real network.
      generation_coverage:
        safe_div(
          sum_by(scored, & &1.model_generation_mw),
          sum_by(scored, & &1.actual_generation_mw)
        ),
      dispatch_to_load:
        safe_div(sum_by(scored, & &1.model_generation_mw), sum_by(scored, & &1.served_load_mw)),
      bus_coverage_load_weighted:
        weighted_mean(Enum.map(scored, & &1.bus_coverage), demand_weights),
      conservation_residual_mw: islands.residual_mw,
      island_abs_residual_mw: islands.abs_residual_mw,
      unserved_mw: coverage && coverage.unserved_mw,
      unmatched_mw: coverage && coverage.unmatched_mw,
      unplaced_mw: gap && sum_by(Map.values(gap), & &1.unplaced_mw),
      unplaced_nuclear_mw: gap && gap["nuclear"].unplaced_mw,
      online_units: coverage && coverage.online_units,
      units: coverage && coverage.units
    }
  end

  # Scaling reproduces EIA demand exactly; anything past rounding means this
  # BA never received a factor.
  defp unscaled?(%{served_load_error_pct: pct}) when is_number(pct), do: abs(pct) > 0.001
  defp unscaled?(_ba), do: false

  # PowerModel.Demand's own @sane_factor_range: outside it, the per-BA
  # scaling is warned about at snapshot-build time.
  defp outsized_scale?(%{load_scale_factor: factor}) when is_number(factor),
    do: factor < 0.05 or factor > 2.0

  defp outsized_scale?(_ba), do: false

  defp worst_ba([]), do: nil

  defp worst_ba(scored) do
    worst = Enum.max_by(scored, & &1.fuel_mix_tv)
    %{ba_code: worst.ba_code, fuel_mix_tv: worst.fuel_mix_tv}
  end

  # ---------------------------------------------------------------------------
  # Aggregation across hours
  # ---------------------------------------------------------------------------

  # Per-hour scores averaged into one row per mode, plus a per-BA table
  # averaged over the hours each BA was scored in.
  defp collect_mode(mode, scored) do
    hours =
      Enum.map(scored, fn {meta, by_mode} ->
        score = Map.fetch!(by_mode, mode)

        %{
          hour: meta.hour,
          reporting_bas: meta.reporting_bas,
          complete?: meta.complete?,
          dispatch_source: score.dispatch_source,
          totals: score.totals
        }
      end)

    scores = Enum.map(scored, fn {_meta, by_mode} -> Map.fetch!(by_mode, mode) end)

    %{
      hours: hours,
      summary: summarize(hours, scores),
      by_ba: aggregate_bas(scores),
      gap_by_fuel: aggregate_gap(scores),
      unmodeled_bas: aggregate_unmodeled(scores)
    }
  end

  @numeric_totals ~w(
    tv_load_weighted tv_generation_weighted tv_mean tv_median
    interchange_mae_mw interchange_bias_mw
    served_load_mae_mw served_load_bias_mw served_load_mape load_scale_factor_median
    outsized_scale_load_mw
    model_generation_mw model_load_mw actual_generation_mw eia_demand_mw
    generation_coverage dispatch_to_load bus_coverage_load_weighted
    conservation_residual_mw island_abs_residual_mw
    interchange_from_placement_mw interchange_from_eia_residual_mw
    interchange_from_load_error_mw
    unserved_mw unmatched_mw unplaced_mw unplaced_nuclear_mw
  )a

  defp summarize([], _scores), do: %{hours: 0}

  defp summarize(hours, scores) do
    totals = Enum.map(hours, & &1.totals)

    means =
      Map.new(@numeric_totals, fn key ->
        {key, mean(totals |> Enum.map(&Map.get(&1, key)) |> Enum.filter(&is_number/1))}
      end)

    means
    |> Map.merge(%{
      hours: length(hours),
      bas_scored: rounded_median(Enum.map(totals, & &1.bas_scored)),
      bas_reporting: rounded_median(Enum.map(totals, & &1.bas_reporting)),
      bas_load_unscaled: rounded_median(Enum.map(totals, & &1.bas_load_unscaled)),
      bas_scale_factor_outsized: rounded_median(Enum.map(totals, & &1.bas_scale_factor_outsized)),
      tv_load_weighted_worst_hour: worst_hour(hours),
      dispatch_sources: hours |> Enum.map(& &1.dispatch_source) |> Enum.frequencies(),
      incomplete_hours: Enum.count(hours, &(not &1.complete?)),
      demand_coverage:
        safe_div(
          sum_by(totals, &(&1.eia_demand_mw || 0.0)),
          sum_by(scores, fn s ->
            (s.totals.eia_demand_mw || 0.0) +
              sum_by(s.unmodeled_bas, &(&1.eia_demand_mw || 0.0))
          end)
        )
    })
  end

  defp worst_hour(hours) do
    scored = Enum.filter(hours, &is_number(&1.totals.tv_load_weighted))

    case scored do
      [] ->
        nil

      _ ->
        worst = Enum.max_by(scored, & &1.totals.tv_load_weighted)
        %{hour: worst.hour, tv_load_weighted: worst.totals.tv_load_weighted}
    end
  end

  @ba_numeric ~w(
    fuel_mix_tv model_generation_mw actual_generation_mw generation_error_mw
    served_load_mw baseline_load_mw load_scale_factor
    eia_demand_mw served_load_error_mw served_load_error_pct
    implied_interchange_mw reported_interchange_mw interchange_error_mw
    eia_identity_residual_mw bus_coverage generation_coverage dispatch_to_load
  )a

  defp aggregate_bas(scores) do
    scores
    |> Enum.flat_map(& &1.by_ba)
    |> Enum.group_by(& &1.ba_code)
    |> Enum.map(fn {code, rows} ->
      first = hd(rows)

      averaged =
        Map.new(@ba_numeric, fn key ->
          {key, mean(rows |> Enum.map(&Map.get(&1, key)) |> Enum.filter(&is_number/1))}
        end)

      Map.merge(averaged, %{
        ba_code: code,
        ba_id: first.ba_id,
        interconnection: first.interconnection,
        hours: length(rows),
        interchange_mae_mw:
          mean(
            rows
            |> Enum.map(& &1.interchange_error_mw)
            |> Enum.filter(&is_number/1)
            |> Enum.map(&abs/1)
          ),
        model_fuel_mw: mean_mix(rows, :model_fuel_mw),
        actual_fuel_mw: mean_mix(rows, :actual_fuel_mw)
      })
    end)
    |> Enum.sort_by(&(-(&1.actual_generation_mw || 0.0)))
  end

  defp mean_mix(rows, key) do
    Map.new(fuels(), fn fuel ->
      {fuel, mean(Enum.map(rows, &get_in(&1, [Access.key(key), fuel])))}
    end)
  end

  defp aggregate_gap(scores) do
    gaps = scores |> Enum.map(& &1.gap_by_fuel) |> Enum.reject(&is_nil/1)

    if gaps == [] do
      nil
    else
      Map.new(BAFuelHour.fuels(), fn fuel ->
        {fuel,
         %{
           unserved_mw: mean(Enum.map(gaps, &get_in(&1, [fuel, :unserved_mw]))),
           unmatched_mw: mean(Enum.map(gaps, &get_in(&1, [fuel, :unmatched_mw]))),
           unplaced_mw: mean(Enum.map(gaps, &get_in(&1, [fuel, :unplaced_mw])))
         }}
      end)
    end
  end

  defp aggregate_unmodeled(scores) do
    scores
    |> Enum.flat_map(& &1.unmodeled_bas)
    |> Enum.group_by(& &1.ba_code)
    |> Enum.map(fn {code, rows} ->
      %{
        ba_code: code,
        hours: length(rows),
        actual_generation_mw: mean(Enum.map(rows, & &1.actual_generation_mw)),
        eia_demand_mw: mean(rows |> Enum.map(& &1.eia_demand_mw) |> Enum.filter(&is_number/1))
      }
    end)
    |> Enum.sort_by(&(-(&1.actual_generation_mw || 0.0)))
  end

  # The point of the harness: measured minus legacy on identical hours.
  defp comparison(mode_reports) do
    with %{summary: measured} <- Enum.find(mode_reports, &(&1.mode == :measured)),
         %{summary: legacy} <- Enum.find(mode_reports, &(&1.mode == :legacy)) do
      Map.new(@numeric_totals, fn key ->
        {key,
         %{
           measured: Map.get(measured, key),
           legacy: Map.get(legacy, key),
           delta: delta(Map.get(measured, key), Map.get(legacy, key))
         }}
      end)
    else
      _ -> nil
    end
  end

  defp delta(a, b) when is_number(a) and is_number(b), do: a - b
  defp delta(_a, _b), do: nil

  # ---------------------------------------------------------------------------
  # Presentation
  # ---------------------------------------------------------------------------

  @doc """
  One `key=value` line per mode (plus a `delta` line when the legacy
  dispatch ran), designed to be pasted into a CI assertion.
  """
  def summary_lines(report) do
    lines =
      Enum.map(report.modes, fn mode_report ->
        "REPLAY schema=#{report.schema_version} mode=#{mode_report.mode} " <>
          metric_pairs(mode_report.summary)
      end)

    case report.comparison do
      nil ->
        lines

      comparison ->
        lines ++ ["REPLAY schema=#{report.schema_version} mode=delta " <> delta_pairs(comparison)]
    end
  end

  @summary_keys ~w(
    hours bas_scored tv_load_weighted tv_generation_weighted tv_mean
    interchange_mae_mw served_load_mape conservation_residual_mw
    unplaced_mw unplaced_nuclear_mw generation_coverage bus_coverage_load_weighted
  )a

  defp metric_pairs(summary) do
    Enum.map_join(@summary_keys, " ", fn key ->
      "#{key}=#{format_metric(Map.get(summary, key))}"
    end)
  end

  defp delta_pairs(comparison) do
    Enum.map_join(@summary_keys -- [:hours, :bas_scored], " ", fn key ->
      "#{key}=#{format_metric(get_in(comparison, [key, :delta]))}"
    end)
  end

  defp format_metric(nil), do: "n/a"
  defp format_metric(value) when is_integer(value), do: Integer.to_string(value)
  defp format_metric(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 4)
  defp format_metric(value), do: to_string(value)

  @doc """
  Convert a report to JSON-safe values: `DateTime`s become ISO-8601 strings,
  atoms become strings, floats are rounded so two runs over identical data
  produce an identical file.
  """
  def presentable(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def presentable(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, inner} -> {presentable_key(key), presentable(inner)} end)
  end

  def presentable(value) when is_list(value), do: Enum.map(value, &presentable/1)
  def presentable(value) when is_float(value), do: Float.round(value, 6)

  def presentable(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  def presentable(value), do: value

  defp presentable_key(key) when is_atom(key), do: Atom.to_string(key)
  defp presentable_key(key) when is_binary(key), do: key
  defp presentable_key(key), do: inspect(key)

  defp scope(context) do
    %{
      interconnections: context.interconnections,
      buses: length(context.buses),
      generators: length(context.generators),
      loads: length(context.base_loads),
      islands: length(context.islands),
      bas_modeled:
        context.bus_ba |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()
    }
  end

  defp window([]), do: nil

  defp window(hours) do
    %{from: List.first(hours).hour, to: List.last(hours).hour, hours: length(hours)}
  end

  # ---------------------------------------------------------------------------
  # Numeric helpers
  # ---------------------------------------------------------------------------

  defp sum_by(list, fun), do: list |> Enum.map(fun) |> Enum.sum()
  defp sum_values(map), do: map |> Map.values() |> Enum.sum()
  defp sum([]), do: nil
  defp sum(list), do: Enum.sum(list)

  defp sum_by_ba(items, bus_ba, fun) do
    Enum.reduce(items, %{}, fn item, acc ->
      case Map.get(bus_ba, Map.get(item, :bus_id)) do
        nil -> acc
        ba_id -> Map.update(acc, ba_id, fun.(item), &(&1 + fun.(item)))
      end
    end)
  end

  defp mean([]), do: nil

  defp mean(values) do
    numbers = Enum.filter(values, &is_number/1)
    if numbers == [], do: nil, else: Enum.sum(numbers) / length(numbers)
  end

  defp median([]), do: nil

  defp median(values) do
    numbers = values |> Enum.filter(&is_number/1) |> Enum.sort()
    count = length(numbers)

    case count do
      0 ->
        nil

      _ when rem(count, 2) == 1 ->
        Enum.at(numbers, div(count, 2))

      _ ->
        (Enum.at(numbers, div(count, 2) - 1) + Enum.at(numbers, div(count, 2))) / 2
    end
  end

  defp rounded_median(values) do
    case median(values) do
      nil -> nil
      value -> round(value)
    end
  end

  defp weighted_mean(values, weights) do
    pairs = Enum.zip(values, weights) |> Enum.filter(fn {v, w} -> is_number(v) and w > 0.0 end)
    total = sum_by(pairs, fn {_v, w} -> w end)

    if pairs == [] or total <= 0.0 do
      mean(values)
    else
      sum_by(pairs, fn {v, w} -> v * w end) / total
    end
  end

  defp safe_div(_numerator, denominator) when denominator in [0, 0.0], do: nil
  defp safe_div(numerator, denominator), do: numerator / denominator
end
