defmodule PowerModel.Dispatch do
  @moduledoc """
  Unit dispatch from measured EIA-930 per-fuel generation.

  EIA-930 publishes, for every balancing authority and hour, how many MW each
  fuel actually produced (`PowerModel.Demand.BAFuelHour`). This module places
  those MW on individual units: within one (BA, fuel, hour) the measured MW are
  filled into that BA's in-service units of that fuel in merit order —
  capacity factor descending — each unit capped at its seasonal capability.

  ## Absolute MW, never rescaled

  The measured MW are used as absolute targets. Nothing is normalized to the
  snapshot's load, so a BA's generation minus its load reproduces its real
  interchange by construction instead of the fictitious self-sufficiency a
  load-balanced dispatch imposes (ROADMAP item 6). Coverage therefore reports
  `implied_interchange_mw` alongside the interchange EIA reported, and the two
  should agree wherever the network's BA mapping is complete.

  ## Minimum load and OFFLINE units

  A unit whose remaining allocation would fall below its `p_min_mw` is left
  OFFLINE rather than part-loaded below a level it cannot physically hold; the
  allocation moves on to the next unit in merit order, which may be small
  enough to take it. Every generator appears in the returned map — offline
  ones with an explicit `0.0`.

  That explicit zero is load-bearing. `Cascade.apply_dispatch/2` defaults a
  generator MISSING from the dispatch map to `p_max_mw * capacity_factor`, and
  it hands the solver shape `p_max_mw = dispatched MW, capacity_factor = 1.0`
  (physical values ride along as `:p_dispatch_mw` / `:p_nameplate_mw`).
  `PowerModel.Solver.Frequency.simulate/5` keeps only generators with
  `capacity_factor > 0` and `p_max_mw > 0` as online, so a unit dispatched at
  0.0 contributes zero inertia and zero governor response — but a unit merely
  ABSENT from the map would silently come back online at its capacity factor.

  ## Fallback

  Generators whose bus carries no BA, or whose fuel the BA did not report for
  that hour (including import pseudo-generators, which EIA-930 has no fuel
  column for), are dispatched proportionally within their electrical island
  against whatever load the measured fuels left unserved. When the island's
  measured generation already covers its load the residual is zero and those
  units stay offline; when the island is a net importer the residual is the
  import, which is exactly what an import pseudo-generator should carry.

  ## Return shape

      {:ok, %{
        dispatch: %{generator_id => mw},          # every generator, 0.0 when offline
        coverage: %{
          hour: DateTime.t(),
          season: :summer | :winter,
          target_mw: float,          # measured MW offered to units
          dispatched_mw: float,      # MW actually placed (fuel + fallback)
          unserved_mw: float,        # measured MW no unit could absorb
          fallback_mw: float,        # MW placed by the island fallback
          fallback_capacity_mw: float,
          units: integer,
          online_units: integer,
          offline_units: integer,
          bas: integer,
          by_ba: %{ba_id => %{
            code: String.t() | nil,
            target_mw: float, dispatched_mw: float, unserved_mw: float,
            load_mw: float | nil,
            implied_interchange_mw: float | nil,
            reported_interchange_mw: float | nil,
            by_fuel: %{fuel => %{target_mw: float, dispatched_mw: float,
                                 units: integer, online_units: integer}}
          }},
          missing: [%{ba_id: integer | nil, fuel: String.t(), capacity_mw: float,
                      units: integer}],       # units with no measurement
          unmatched: [%{ba_id: integer, fuel: String.t(), mw: float}],
          unmatched_mw: float                 # measured MW with no unit
        }
      }}

  `{:error, :no_fuel_data}` is returned when no BA reported any fuel for the
  hour — the caller is expected to fall back to its own dispatch rule.

  ## Options

    * `:bus_ba` — `%{bus_id => ba_id}`; queried from the database when omitted
    * `:islands` — list of `MapSet` of bus ids; one island when omitted
    * `:loads` — snapshot loads, used for the island fallback residual and for
      the interchange identity in coverage
    * `:fuel_totals` — `%{ba_id => %{fuel => mw}}`. Supplying it declares the
      caller as the source of truth for the hour and suppresses EVERY database
      read (BA codes and reported interchange included), so the module runs
      against fixtures with no repo at all.
  """

  require Logger

  import Ecto.Query

  alias PowerModel.Demand
  alias PowerModel.Grid.{BalancingAuthority, Bus}
  alias PowerModel.Repo

  # EIA energy-source code -> the EIA-930 fuel column that reports it.
  # Codes EIA-930 folds into "Other Fuel Sources" / "Other Energy Storage"
  # (biomass, waste, geothermal, batteries, manufactured gases) map to "other";
  # anything unrecognized stays out of the canonical set on purpose so it goes
  # to the island fallback instead of competing for another fuel's MW.
  @fuel_codes %{
    "NUC" => "nuclear",
    "ANT" => "coal",
    "BIT" => "coal",
    "LIG" => "coal",
    "SUB" => "coal",
    "RC" => "coal",
    "WC" => "coal",
    "SC" => "coal",
    "SGC" => "coal",
    "NG" => "natural_gas",
    "DFO" => "petroleum",
    "JF" => "petroleum",
    "KER" => "petroleum",
    "PC" => "petroleum",
    "RFO" => "petroleum",
    "WO" => "petroleum",
    "WAT" => "hydro",
    "WND" => "wind",
    "SUN" => "solar",
    "GEO" => "other",
    "MWH" => "other",
    "BFG" => "other",
    "OG" => "other",
    "PG" => "other",
    "SGP" => "other",
    "LFG" => "other",
    "OBG" => "other",
    "OBL" => "other",
    "OBS" => "other",
    "AB" => "other",
    "BLQ" => "other",
    "MSW" => "other",
    "SLW" => "other",
    "TDF" => "other",
    "WDL" => "other",
    "WDS" => "other",
    "PUR" => "other",
    "WH" => "other",
    "OTH" => "other"
  }

  # Prime movers that make a WAT unit pumped storage, which EIA-930 reports
  # outside the hydro column (and this schema folds into "other").
  @pumped_storage_prime_movers ~w(PS)

  @doc """
  Dispatch `generators` for `hour` from measured EIA-930 per-fuel generation.

  See the module documentation for the return shape and options.
  """
  def for_hour(generators, hour, opts \\ [])

  def for_hour(generators, %DateTime{} = hour, opts) do
    hour = truncate_to_hour(hour)
    supplied = Keyword.get(opts, :fuel_totals)
    fuel_totals = supplied || Demand.fuel_generation_at(hour)

    if map_size(fuel_totals) == 0 do
      {:error, :no_fuel_data}
    else
      allocate_hour(generators, hour, fuel_totals, Keyword.put(opts, :db?, is_nil(supplied)))
    end
  end

  defp allocate_hour(generators, hour, fuel_totals, opts) do
    season = season_for(hour)

    bus_ba =
      Keyword.get_lazy(opts, :bus_ba, fn ->
        if opts[:db?], do: bus_ba_map(generators), else: %{}
      end)

    loads = Keyword.get(opts, :loads, [])
    islands = Keyword.get(opts, :islands)

    units = Enum.map(generators, &unit(&1, bus_ba, season))
    {dispatchable, unavailable} = Enum.split_with(units, & &1.in_service?)

    # Grouped by the (BA, fuel) key the measurement is published at.
    by_group = Enum.group_by(dispatchable, &{&1.ba_id, &1.fuel})

    {fuel_alloc, group_stats, missing} = allocate_groups(by_group, fuel_totals)

    # A unit inside a measured group that lost the merit order stays offline —
    # the measurement placed every MW it had. Only units whose group was never
    # measured at all are left for the fallback.
    measured_keys = MapSet.new(Map.keys(group_stats))
    leftover = Enum.reject(dispatchable, &MapSet.member?(measured_keys, {&1.ba_id, &1.fuel}))

    {fallback_alloc, fallback_mw} =
      fallback_dispatch(leftover, fuel_alloc, dispatchable, loads, islands)

    dispatch =
      units
      |> Map.new(&{&1.id, 0.0})
      |> Map.merge(fuel_alloc)
      |> Map.merge(fallback_alloc)

    coverage =
      build_coverage(
        hour,
        season,
        units,
        dispatch,
        group_stats,
        missing,
        unmatched(fuel_totals, by_group, dispatchable),
        fallback_mw,
        leftover,
        loads,
        bus_ba,
        opts
      )

    log_summary(coverage, unavailable)

    {:ok, %{dispatch: dispatch, coverage: coverage}}
  end

  # ---------------------------------------------------------------------------
  # Unit view
  # ---------------------------------------------------------------------------

  defp unit(generator, bus_ba, season) do
    capability = capability_mw(generator, season)
    bus_id = Map.get(generator, :bus_id)

    %{
      id: generator.id,
      bus_id: bus_id,
      ba_id: Map.get(bus_ba, bus_id),
      fuel: fuel_for(generator),
      capability_mw: capability,
      # A minimum above the seasonal capability would make the unit
      # undispatchable at any MW; clamp so it can still run at capability.
      p_min_mw: min(Map.get(generator, :p_min_mw) || 0.0, capability),
      capacity_factor: Map.get(generator, :capacity_factor) || 0.0,
      in_service?: (Map.get(generator, :status) || "in_service") == "in_service"
    }
  end

  @doc """
  The EIA-930 fuel column a generator's output is reported in.

  Returns one of the canonical `PowerModel.Demand.BAFuelHour` fuels, or a
  non-canonical string (`"import"`, `"unknown"`) for units EIA-930 does not
  report as generation — those are left to the island fallback.
  """
  def fuel_for(generator) do
    code = generator |> Map.get(:fuel_type) |> to_string() |> String.trim() |> String.upcase()
    prime_mover = generator |> Map.get(:prime_mover) |> to_string() |> String.trim()

    cond do
      code == "WAT" and String.upcase(prime_mover) in @pumped_storage_prime_movers -> "other"
      Map.has_key?(@fuel_codes, code) -> Map.fetch!(@fuel_codes, code)
      code == "" -> "unknown"
      true -> heuristic_fuel(code)
    end
  end

  # Free-text fuel descriptions (MATPOWER imports, hand-built fixtures).
  defp heuristic_fuel(code) do
    f = String.downcase(code)

    cond do
      String.contains?(f, "import") -> "import"
      String.contains?(f, "nuclear") -> "nuclear"
      String.contains?(f, "coal") -> "coal"
      String.contains?(f, "gas") -> "natural_gas"
      String.contains?(f, "oil") or String.contains?(f, "petrol") -> "petroleum"
      String.contains?(f, "hydro") -> "hydro"
      String.contains?(f, "wind") -> "wind"
      String.contains?(f, "solar") -> "solar"
      String.contains?(f, "nuc") -> "nuclear"
      true -> "unknown"
    end
  end

  # Seasonal capability, read defensively: the summer/winter capability columns
  # are being added in parallel, so a struct without them (or a plain map from
  # a fixture) falls back to summer capability and then to nameplate.
  defp capability_mw(generator, season) do
    seasonal =
      case season do
        :winter ->
          Map.get(generator, :winter_capacity_mw) || Map.get(generator, :summer_capacity_mw)

        :summer ->
          Map.get(generator, :summer_capacity_mw)
      end

    seasonal || generator.p_max_mw || 0.0
  end

  # EIA's summer capability season (June-September); everything else is rated
  # on winter capability.
  defp season_for(%DateTime{month: month}) when month in 6..9, do: :summer
  defp season_for(%DateTime{}), do: :winter

  # ---------------------------------------------------------------------------
  # Measured allocation
  # ---------------------------------------------------------------------------

  defp allocate_groups(by_group, fuel_totals) do
    Enum.reduce(by_group, {%{}, %{}, []}, fn {{ba_id, fuel}, group_units},
                                             {alloc, stats, missing} ->
      case measured_mw(fuel_totals, ba_id, fuel) do
        nil ->
          {alloc, stats,
           [
             %{
               ba_id: ba_id,
               fuel: fuel,
               units: length(group_units),
               capacity_mw: sum_by(group_units, & &1.capability_mw)
             }
             | missing
           ]}

        target_mw ->
          {group_alloc, remaining} = fill(group_units, max(target_mw, 0.0))

          dispatched = target_mw |> max(0.0) |> Kernel.-(remaining)

          stat = %{
            target_mw: target_mw,
            dispatched_mw: dispatched,
            units: length(group_units),
            online_units: Enum.count(group_alloc, fn {_id, mw} -> mw > 0.0 end)
          }

          {Map.merge(alloc, group_alloc), Map.put(stats, {ba_id, fuel}, stat), missing}
      end
    end)
  end

  # Measured MW the network cannot place at all: the BA is in this snapshot but
  # owns no in-service unit of that fuel, so the generation is simply missing
  # from the model. The other half of the coverage gap from `missing`.
  defp unmatched(fuel_totals, by_group, dispatchable) do
    snapshot_bas = dispatchable |> Enum.map(& &1.ba_id) |> Enum.reject(&is_nil/1) |> MapSet.new()

    for {ba_id, fuels} <- fuel_totals,
        MapSet.member?(snapshot_bas, ba_id),
        {fuel, mw} <- fuels,
        not Map.has_key?(by_group, {ba_id, fuel}),
        mw != 0.0 do
      %{ba_id: ba_id, fuel: fuel, mw: mw}
    end
    |> Enum.sort_by(&(-abs(&1.mw)))
  end

  # A group is measured only when the BA reported that exact fuel. Storage
  # charging shows up as negative net generation; it is floored at zero here
  # (charging as load is ROADMAP item 17) but the negative target is kept in
  # coverage so the discrepancy stays visible.
  defp measured_mw(_fuel_totals, nil, _fuel), do: nil

  defp measured_mw(fuel_totals, ba_id, fuel) do
    fuel_totals |> Map.get(ba_id, %{}) |> Map.get(fuel)
  end

  # Merit order fill: highest capacity factor first, then largest unit, then id
  # so the order is stable across runs.
  defp fill(units, target_mw) do
    units
    |> Enum.sort_by(&{-&1.capacity_factor, -&1.capability_mw, &1.id})
    |> Enum.reduce({%{}, target_mw}, fn unit, {alloc, remaining} ->
      take = min(unit.capability_mw, remaining)

      if take <= 0.0 or take < unit.p_min_mw do
        # Below its minimum load this unit cannot run at all; leave it offline
        # and offer the remaining MW to the next unit in merit order.
        {Map.put(alloc, unit.id, 0.0), remaining}
      else
        {Map.put(alloc, unit.id, take), remaining - take}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Island fallback
  # ---------------------------------------------------------------------------

  # Units the measurement cannot place: no BA, or a fuel the BA did not report.
  # They share whatever load the measured MW left unserved inside their island.
  defp fallback_dispatch([], _fuel_alloc, _all_units, _loads, _islands), do: {%{}, 0.0}

  defp fallback_dispatch(leftover, fuel_alloc, all_units, loads, islands) do
    islands = islands || [:all]

    Enum.reduce(islands, {%{}, 0.0}, fn island, {alloc, total} ->
      island_units = Enum.filter(leftover, &in_island?(&1, island))

      if island_units == [] do
        {alloc, total}
      else
        island_load = loads |> Enum.filter(&in_island?(&1, island)) |> sum_by(& &1.p_mw)

        placed_mw =
          all_units
          |> Enum.filter(&in_island?(&1, island))
          |> sum_by(&Map.get(fuel_alloc, &1.id, 0.0))

        {island_alloc, island_mw} = spread(island_units, island_load, placed_mw, loads == [])

        {Map.merge(alloc, island_alloc), total + island_mw}
      end
    end)
  end

  defp in_island?(_item, :all), do: true
  defp in_island?(item, island), do: MapSet.member?(island, Map.get(item, :bus_id))

  # Without loads there is no residual to spread, so uncovered units keep the
  # capacity-factor operating point they would have had before this module
  # existed. With loads, they share the island's unserved MW in proportion to
  # their expected output.
  defp spread(units, island_load, placed_mw, no_loads?) do
    expected = sum_by(units, &(&1.capability_mw * &1.capacity_factor))
    residual = island_load - placed_mw

    factor =
      cond do
        no_loads? -> 1.0
        expected <= 0.0 -> 0.0
        residual <= 0.0 -> 0.0
        true -> min(residual / expected, 1.0)
      end

    Enum.reduce(units, {%{}, 0.0}, fn unit, {alloc, total} ->
      mw = min(unit.capability_mw * unit.capacity_factor * factor, unit.capability_mw)

      if mw <= 0.0 or mw < unit.p_min_mw do
        {Map.put(alloc, unit.id, 0.0), total}
      else
        {Map.put(alloc, unit.id, mw), total + mw}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Coverage
  # ---------------------------------------------------------------------------

  defp build_coverage(
         hour,
         season,
         units,
         dispatch,
         group_stats,
         missing,
         unmatched,
         fallback_mw,
         leftover,
         loads,
         bus_ba,
         opts
       ) do
    by_ba_fuel = Enum.group_by(group_stats, fn {{ba_id, _fuel}, _stat} -> ba_id end)
    load_by_ba = load_by_ba(loads, bus_ba)

    reported = if opts[:db?], do: Demand.interchange_at(hour), else: %{}

    dispatch_by_ba = dispatch_by_ba(units, dispatch)

    by_ba =
      Map.new(by_ba_fuel, fn {ba_id, entries} ->
        fuels =
          Map.new(entries, fn {{_ba, fuel}, stat} ->
            {fuel, Map.take(stat, [:target_mw, :dispatched_mw, :units, :online_units])}
          end)

        target = fuels |> Map.values() |> sum_by(& &1.target_mw)
        ba_dispatch = Map.get(dispatch_by_ba, ba_id, 0.0)
        load_mw = Map.get(load_by_ba, ba_id)

        {ba_id,
         %{
           code: nil,
           target_mw: target,
           dispatched_mw: ba_dispatch,
           unserved_mw: max(target - (fuels |> Map.values() |> sum_by(& &1.dispatched_mw)), 0.0),
           load_mw: load_mw,
           implied_interchange_mw: load_mw && ba_dispatch - load_mw,
           reported_interchange_mw: Map.get(reported, ba_id),
           by_fuel: fuels
         }}
      end)

    by_ba = if opts[:db?], do: attach_codes(by_ba), else: by_ba
    target_mw = by_ba |> Map.values() |> sum_by(& &1.target_mw)
    dispatched_mw = dispatch |> Map.values() |> Enum.sum()
    online = Enum.count(dispatch, fn {_id, mw} -> mw > 0.0 end)

    %{
      hour: hour,
      season: season,
      target_mw: target_mw,
      dispatched_mw: dispatched_mw,
      unserved_mw: by_ba |> Map.values() |> sum_by(& &1.unserved_mw),
      fallback_mw: fallback_mw,
      fallback_capacity_mw: sum_by(leftover, & &1.capability_mw),
      units: length(units),
      online_units: online,
      offline_units: length(units) - online,
      bas: map_size(by_ba),
      by_ba: by_ba,
      missing: Enum.sort_by(missing, &(-&1.capacity_mw)),
      unmatched: unmatched,
      unmatched_mw: sum_by(unmatched, & &1.mw)
    }
  end

  defp dispatch_by_ba(units, dispatch) do
    Enum.reduce(units, %{}, fn unit, acc ->
      mw = Map.get(dispatch, unit.id, 0.0)

      if unit.ba_id, do: Map.update(acc, unit.ba_id, mw, &(&1 + mw)), else: acc
    end)
  end

  defp load_by_ba([], _bus_ba), do: %{}

  defp load_by_ba(loads, bus_ba) do
    Enum.reduce(loads, %{}, fn load, acc ->
      case Map.get(bus_ba, load.bus_id) do
        nil -> acc
        ba_id -> Map.update(acc, ba_id, load.p_mw, &(&1 + load.p_mw))
      end
    end)
  end

  defp attach_codes(by_ba) when map_size(by_ba) == 0, do: by_ba

  defp attach_codes(by_ba) do
    codes =
      from(ba in BalancingAuthority, where: ba.id in ^Map.keys(by_ba), select: {ba.id, ba.code})
      |> Repo.all()
      |> Map.new()

    Map.new(by_ba, fn {ba_id, entry} -> {ba_id, %{entry | code: Map.get(codes, ba_id)}} end)
  end

  defp log_summary(coverage, unavailable) do
    Logger.info(
      "Dispatch #{DateTime.to_iso8601(coverage.hour)} (#{coverage.season}): " <>
        "#{gw(coverage.dispatched_mw)} GW on #{coverage.online_units}/#{coverage.units} units " <>
        "across #{coverage.bas} BAs " <>
        "(measured #{gw(coverage.target_mw)} GW, unserved #{gw(coverage.unserved_mw)} GW, " <>
        "island fallback #{gw(coverage.fallback_mw)} GW of " <>
        "#{gw(coverage.fallback_capacity_mw)} GW capacity, " <>
        "#{length(unavailable)} units out of service)"
    )

    if coverage.missing != [] do
      top =
        coverage.missing
        |> Enum.take(5)
        |> Enum.map_join(", ", fn m ->
          "#{m.fuel}@BA #{inspect(m.ba_id)} #{gw(m.capacity_mw)} GW"
        end)

      Logger.info(
        "Dispatch: #{length(coverage.missing)} (BA, fuel) groups had no EIA-930 measurement " <>
          "and fell back to island-proportional dispatch -- largest: #{top}"
      )
    end
  end

  defp gw(mw), do: Float.round(mw / 1000.0, 1)

  defp sum_by(list, fun), do: list |> Enum.map(fun) |> Enum.sum()

  defp bus_ba_map(generators) do
    bus_ids =
      generators |> Enum.map(&Map.get(&1, :bus_id)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if bus_ids == [] do
      %{}
    else
      from(b in Bus, where: b.id in ^bus_ids, select: {b.id, b.balancing_authority_id})
      |> Repo.all()
      |> Map.new()
    end
  end

  defp truncate_to_hour(%DateTime{} = ts) do
    ts = DateTime.shift_zone!(ts, "Etc/UTC")

    %{ts | minute: 0, second: 0, microsecond: {0, 0}} |> DateTime.truncate(:second)
  end
end
