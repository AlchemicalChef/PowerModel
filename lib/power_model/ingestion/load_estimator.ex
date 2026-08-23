defmodule PowerModel.Ingestion.LoadEstimator do
  @moduledoc """
  Creates a **synthetic spatial baseline** of loads — it does NOT use real
  demand data.

  Total load is set to 85% of in-service generation capacity and distributed
  across load-serving buses with power factor 0.95 lagging. The spatial
  weights are **population-based** when Census county data is present (`mix
  power_model.ingest population`): each county's population is spread over the
  buses inside and near it, and a bus's share of load is 80% its share of
  national population + 20% floor (so empty-county transmission buses keep a
  nonzero load). Both terms are weighted by the bus's load-serving capability.
  Without county data it falls back to the old gen-proximity heuristic (50%
  uniform, 50% proportional to bus-attached generation).

  These per-bus values serve as spatial weights: when EIA-930 demand data is
  ingested (`mix power_model.ingest demand`), `PowerModel.Demand.scale_loads/3`
  rescales them at snapshot time so each balancing authority's total matches
  its actual demand for the selected hour.

  Water facility MW (merged into `constant_power` rows by
  `Grid.map_water_facilities_to_grid/1`) is re-applied after re-estimation,
  since re-estimation rebuilds those rows from scratch.

  ## Where load may land (TOPO-2, TOPO-6, LIN13-B)

  Four rules decide the candidate set, and every one of them exists because
  the previous rule — nearest 25 PQ buses to the county centroid,
  inverse-distance weighted with a 1 km floor, no voltage and no topology —
  produced load a network cannot serve:

    * **60 kV and above.** Load is served from sub-transmission, not from the
      13.8 kV bus a HIFLD yard happens to also record. ERCOT carried 1.9 GW of
      scaled demand on buses under 30 kV.

    * **One bus per yard, the LOWEST qualifying level.** The old rule ranked
      buses by distance, and the levels of one substation sit at the same
      point, so every level of a yard drew nearly the same weight and the yard
      collected its county share once per level. SCE's GALE held 214.45 MW on
      *both* its 115 kV and its 33 kV bus, HARVARD 300.58 MW on both of its
      two — 1,030 MW of baseline where the county spread had placed 515.

    * **At most 0.8 x the bus's connected capability**, with the overflow
      redistributed to the rest of the county. A bus cannot draw more than its
      branches can deliver, and 19 buses were doing exactly that.

    * **At most what a substation of its VOLTAGE CLASS delivers**
      (`@class_ceiling_mw`), less whatever another placer has already committed
      there (datacenter rows and water facility MW — see
      `committed_load_by_bus/0`). Connected capability counts a yard's
      circuits, and a circuit in and a circuit out is transfer, not delivery:
      two 116 MVA 69 kV lines through Mesa's bus 76087 read as 186 MW of cap on
      a bus whose banks step down at 20-30 MVA a piece. 586 buses held more
      baseline MW than their class delivers, 513 of them at 69 kV.

    * **A known balancing authority**, whenever the database has any. These
      values are spatial WEIGHTS: `Demand.scale_loads/3` rescales each BA to
      its measured demand, and a bus outside every BA is never rescaled, so
      its weight becomes permanent synthetic load. Left unguarded, the 2,701
      substation buses a restoration pass added after the last `map_bas` run
      would have carried 34 GW of it.

  ### Anchoring the cap

  Capability counts line `rating_a_mva` as ingested, but takes the CLASS
  STANDARD rating for a transformer — `BusMapper.transformer_attrs/2` with no
  through-load — never the stored `rated_mva`. `BusMapper.resize_transformers_to_through_load/0`
  sizes banks *from* the load on them, so a cap read off stored ratings is a
  cap the current misplacement has already paid for: at HARVARD the 66 kV bank
  reads 800 MVA precisely because 300 MW sits behind it. The class standard is
  a function of voltage alone and breaks the loop. Once load has moved, re-run
  the resize and the two agree by construction: the cap is `0.8 x unit` and the
  resize buys `ceil(load / 0.8 / unit)` units.

  A bus reachable only through transformers is additionally capped by what
  reaches the far side of those banks, since a 100 MVA bank fed by a 55 MVA
  line delivers 55 MVA. One hop is enough for the two- and three-level yards
  this network is made of.

  ## The spread

  `spread_radii/1` gives each county a characteristic radius; population is
  spread over every candidate within 2.5 radii under a `1 / (1 + (d/r)^2)`
  kernel, which is flat across the county and decays outside it. There is no
  distance floor, so no bus can win a county by standing next to its interior
  point: Harris County's 5.0 M people used to reach RITTENHOUSE at 1.5 km and
  hand each of its two buses 1,530.83 MW.

  Within that kernel a bus's weight is its **load-serving capability**
  (`@serving_capability_mva`), not one vote per bus. Utilities build
  substations where demand is, so a yard's share of the local load follows its
  share of the local capability, and it is the same quantity the branch cap is
  set from — a bus binds exactly when its county's demand density passes 0.8 of
  local capability, wherever it stands. One vote per bus instead put 22-23% of
  Eastern's and Western's load on degree-1 buses, which hold 9% of the
  candidate capability between them.

  The class ceiling deliberately does NOT enter the weight. Weighting by
  `min(capability, class ceiling)` compresses a 100 MVA degree-1 spur and a
  500 MVA meshed yard from 100:400 into 50:150, which is most of the way back
  to one vote per bus: measured, it took the degree-1 share of served load to
  20.8% in Western and 18.2% in Eastern against a 15% gate. Only the cap moves.

  Overflow from a capped bus is redistributed **within the same county**, not
  nationally, so the reallocation stays local and bus->BA demand attribution
  (ENE-17, and through it `Demand.snapshot_load_shares/1`) moves as little as
  the physics allows. `mix grid.census load_placement` scores every rule above.
  """

  import Ecto.Query
  require Logger

  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, Generator, Load, TransmissionLine, Transformer}
  alias PowerModel.Ingestion.BusMapper
  alias PowerModel.Ingestion.Census.Population

  # The stored `q_mvar` is the LOAD's own reactive demand at this power factor,
  # not the reactive power the transmission bus ends up seeing: what reaches the
  # bus is whatever `Solver.LoadModel` makes of the row, and any distribution
  # compensation modelled there sits between the two.
  @power_factor 0.95
  # ~0.3287
  @q_ratio :math.tan(:math.acos(@power_factor))
  @population_weight 0.8

  # Load-serving voltage floor: below this a bus is a yard's distribution
  # record, not a point demand is delivered from.
  @min_load_kv 60.0

  # Share of a bus's connected capability its load may occupy.
  @cap_fraction 0.8

  # The most load one substation of a given class ordinarily DELIVERS, in MW at
  # the 0.95 pf above (so the banks behind it see ceiling / 0.95 MVA).
  #
  # A bus's branches are transfer capacity, not delivery capacity: two 116 MVA
  # 69 kV circuits through a yard are one circuit in and one out, and summing
  # them says a 69 kV bus may serve 186 MW. Load leaves the network through the
  # yard's step-down banks, so it is the banks that fix the ceiling. Standard
  # three-phase units come in the ANSI/IEEE C57.12.00 preferred series
  # (12/16/20, 20/26.7/33.3, 30/40/50, 50/66.7/83.3 MVA ONAN/ONAF/ONAF), and a
  # delivery yard carries two or three of them with the largest out for N-1:
  #
  #     < 46 kV    2 x 12/16 MVA           ->   25 MW
  #     46-99      2-3 x 20/26.7 MVA       ->   50 MW  (69 kV distribution)
  #     100-160    3 x 50/66.7 MVA         ->  150 MW  (115/138 kV)
  #     161-229    3 x 83.3 MVA            ->  250 MW
  #     230-344    2-3 x 150-200 MVA       ->  400 MW
  #     345-499    3 x 250 MVA             ->  750 MW
  #     >= 500     2 x 500-750 MVA         -> 1000 MW
  #
  # Only the 46-99 and 100-160 rows bind on the ingested network; the rest are
  # guard rails against a future spread putting a city on one 500 kV bus.
  #
  # This is NOT the transformer class table in `BusMapper`: that one rates a
  # yard's INTERTIE banks by high-side class (100 MVA below 138 kV), which is a
  # transmission figure and three to five times a 69 kV delivery bank.
  @class_ceiling_mw [
    {500.0, 1000.0},
    {345.0, 750.0},
    {230.0, 400.0},
    {161.0, 250.0},
    {100.0, 150.0},
    {46.0, 50.0},
    {0.0, 25.0}
  ]

  # Kernel cut-off, in county radii.
  @spread_radii 2.5

  # How much connected capability counts as LOAD-SERVING capability when
  # weighting a bus's share of its county. Substations are built where demand
  # is, so a yard's share of local load follows its share of local capability —
  # but only up to the size of a distribution system: past a couple of banks
  # and a few circuits, more capability is through-flow, not delivery, and
  # without the ceiling a 500 kV switching station with 6.4 GVA of lines would
  # draw sixteen times a 138 kV yard's load.
  @serving_capability_mva 400.0

  # Cap/overflow rounds. Each round refills the counties whose load was clipped;
  # in practice it settles in single digits.
  @max_overflow_rounds 24

  @doc """
  Create loads at each load-serving bus. Total load is set to ~85% of total
  generation capacity (typical reserve margin); distribution is
  population-weighted when Census county data is available.
  """
  def run do
    IO.puts("Estimating loads...")

    {deleted, _} = Repo.delete_all(from l in Load, where: l.load_type == "constant_power")
    if deleted > 0, do: IO.puts("  Cleared #{deleted} existing estimated loads.")

    total_gen =
      Repo.one(
        from g in Generator,
          where: g.status == "in_service" and not is_nil(g.bus_id),
          select: sum(g.p_max_mw)
      ) || 0.0

    # Target load = 85% of capacity (15% reserve margin)
    target_load = total_gen * 0.85

    IO.puts("  Total generation capacity: #{Float.round(total_gen, 0)} MW")
    IO.puts("  Target total load (85%): #{Float.round(target_load, 0)} MW")

    case allocate(target_load, total_gen: total_gen) do
      {:error, reason} ->
        {:error, reason}

      {:ok, allocation, stats} ->
        write_loads(allocation)
        report(stats, allocation)

        # Re-estimation rebuilt the constant_power rows, dropping the water
        # facility MW that map_water_facilities_to_grid had merged in.
        {updated, inserted} = PowerModel.Grid.reapply_water_facility_loads()

        if updated + inserted > 0 do
          IO.puts(
            "  Re-applied water facility MW (#{updated} loads updated, #{inserted} created)."
          )
        end

        {:ok, map_size(allocation)}
    end
  end

  @doc """
  Re-run the allocation over the **existing** baseline total instead of
  recomputing it from generation capacity.

  This is what the reallocation migration calls. Holding the total fixed makes
  the migration a purely spatial change: every acceptance number it is scored
  on — per-BA share drift, degree-1 load share, buses over their branch rating
  — moves only because load moved, not because the baseline grew or shrank.

  Water facility MW is subtracted from the pool before spreading and re-applied
  afterwards, exactly as `run/0` does, so a second run is a no-op rather than a
  bus gaining its treatment plant twice.

  Returns `{:ok, summary}`.
  """
  def reallocate do
    water_mw = water_facility_mw()
    before = load_by_bus()
    pool = before |> Map.values() |> Enum.sum() |> Kernel.-(water_mw) |> max(0.0)

    case allocate(pool) do
      {:error, reason} ->
        {:error, reason}

      {:ok, allocation, stats} ->
        write_loads(allocation)
        {_updated, _inserted} = PowerModel.Grid.reapply_water_facility_loads()

        {:ok,
         stats
         |> Map.merge(movement(before, allocation))
         |> Map.merge(%{
           pool_mw: pool,
           water_mw: water_mw,
           buses_before: map_size(before),
           buses_after: map_size(allocation)
         })}
    end
  end

  @doc """
  `%{bus_id => p_mw}` for a target total, under the current rule.

  Returns `{:ok, allocation, stats}`, or `{:error, :no_buses}` when nothing in
  the database can serve load.
  """
  def allocate(target_mw, opts \\ []) do
    candidates = candidates()

    cond do
      candidates == [] ->
        IO.puts("  No load-serving buses found. Run bus mapping first.")
        {:error, :no_buses}

      target_mw <= 0.0 ->
        {:ok, Map.new(candidates, &{&1.id, 0.0}),
         %{counties: 0, capped_buses: 0, residual_mw: 0.0}}

      true ->
        counties = Population.counties()
        allocate_over(candidates, counties, target_mw, opts)
    end
  end

  defp allocate_over(candidates, counties, target_mw, opts) do
    total_pop = counties |> Enum.map(& &1.population) |> Enum.sum()

    if total_pop > 0 do
      IO.puts("  Population weighting: #{length(counties)} counties, #{total_pop} people.")
      population_allocation(candidates, counties, target_mw)
    else
      IO.puts("  No county population data; falling back to gen-proximity weighting.")
      IO.puts("  (Run `mix power_model.ingest population data/` for population-based loads.)")
      gen_proximity_allocation(candidates, target_mw, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # The candidate set
  # ---------------------------------------------------------------------------

  @doc """
  The buses load may be placed on: PQ, geolocated, at or above
  `#{@min_load_kv}` kV, one per substation (the lowest qualifying level that
  has a branch), each with the MW cap its branches justify.

  `[%{id, lon, lat, cap_mw, capability_mva, base_kv, degree, line_degree}]`.
  """
  def candidates do
    network = network()
    caps = capability(network)
    occupied = committed_load_by_bus()

    # A weight on a bus with no balancing authority is not a weight: nothing
    # ever rescales it, so `Demand.scale_loads/3` ships it into every snapshot
    # at its raw synthetic value. Skipped only when SOME bus has a BA, so a
    # network ingested before `mix power_model.ingest map_bas` still gets a
    # baseline.
    ba_known? = Enum.any?(network.buses, &(not is_nil(&1.balancing_authority_id)))

    network.buses
    |> Enum.filter(fn bus ->
      bus.bus_type == 1 and is_number(bus.base_kv) and bus.base_kv >= @min_load_kv and
        not is_nil(bus.lon) and
        Map.has_key?(caps, bus.id) and headroom(caps[bus.id], occupied, bus.id) > 0.0 and
        (not ba_known? or not is_nil(bus.balancing_authority_id))
    end)
    |> Enum.group_by(&yard_key/1)
    # Levels of one yard sit at the same point: ranking them by distance gave
    # each of them the county's weight, so the yard collected its share once
    # per level. One candidate per yard, and the lowest level that can serve.
    |> Enum.map(fn {_yard, buses} ->
      bus = yard_candidate(buses, caps)
      cap = Map.fetch!(caps, bus.id)
      free = headroom(cap, occupied, bus.id)

      %{
        id: bus.id,
        lon: bus.lon,
        lat: bus.lat,
        base_kv: bus.base_kv,
        cap_mw: free,
        capability_mva: cap.capability_mva,
        serving_weight: min(cap.capability_mva, @serving_capability_mva),
        degree: cap.degree,
        line_degree: cap.line_degree
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  # What the estimator may still place here: the delivery cap less the MW some
  # other placer has already committed.
  defp headroom(cap, occupied, bus_id) do
    max(cap.delivery_cap_mw - Map.get(occupied, bus_id, 0.0), 0.0)
  end

  # MW on a bus that this allocation does not get to choose, and that lands
  # there whatever the spread decides. Both terms arrive AFTER the caps are
  # applied, so a cap that ignores them is a cap the bus exceeds by exactly
  # their size.
  #
  #   * Datacenter rows (`Grid.map_datacenters_to_grid/0`), which
  #     `Demand.scale_loads/3` holds FLAT — a 400 MW campus is 400 MW at every
  #     hour, so a bus carrying one has no room left for a share of its county.
  #
  #   * Water facility MW, which `reapply_water_facility_loads/0` merges INTO
  #     the constant_power row written here once the spread is done. Three
  #     69 kV buses sat at 51-54 MW against a 50 MW ceiling on exactly this:
  #     the cap held the spread and the treatment plant went on top of it.
  #
  # A database whose datacenters are not mapped yet has an empty map and the
  # ceiling stands alone.
  defp committed_load_by_bus do
    flat =
      from(l in Load,
        where: l.status == "in_service" and l.load_type != "constant_power",
        group_by: l.bus_id,
        select: {l.bus_id, sum(l.p_mw)}
      )
      |> Repo.all(timeout: :infinity)

    water =
      from(w in PowerModel.Grid.WaterFacility,
        where: w.status == "active" and not is_nil(w.bus_id) and w.power_consumption_mw > 0.0,
        group_by: w.bus_id,
        select: {w.bus_id, sum(w.power_consumption_mw)}
      )
      |> Repo.all(timeout: :infinity)

    Enum.reduce(flat ++ water, %{}, fn {bus_id, mw}, acc ->
      Map.update(acc, bus_id, (mw || 0.0) * 1.0, &(&1 + (mw || 0.0) * 1.0))
    end)
  end

  # The yard's lowest level that is part of the network — has a LINE of its
  # own — and only failing that its lowest level at all.
  #
  # A bus whose branches are all transformers is not somewhere the network
  # delivers to; it is the far side of a bank, and load put there is radial by
  # construction. Taking it anyway is how "lowest load-serving level" turns a
  # meshed 138 kV yard into a degree-1 69 kV one: consolidating every yard on
  # its lowest level took ERCOT's degree-1 share of served load from 31.5% to
  # 47.9%. HARVARD is the case that still falls through — no level of it at or
  # above 60 kV carries a line — and the capability cap holds it to what its
  # bank's far terminal can deliver.
  defp yard_candidate(buses, caps) do
    networked = Enum.filter(buses, &(Map.fetch!(caps, &1.id).line_degree > 0))
    Enum.min_by(if(networked == [], do: buses, else: networked), &{&1.base_kv, &1.id})
  end

  @doc """
  Which substation yard a bus belongs to.

  A bus carries no substation FK; the owning yard is read off the source_id
  `BusMapper` writes ("<substation id>_<kV>kV"). Buses without one — synthetic
  and international — stand alone.

  Public so every placer that has to consolidate a yard's levels shares one
  definition of what a yard is: placing per LEVEL instead of per yard is how a
  substation collects its share once for each voltage it happens to record.
  """
  def yard_key(%{source: "substation", source_id: source_id}) when is_binary(source_id) do
    case Integer.parse(source_id) do
      {id, "_" <> _} -> {:substation, id}
      _ -> {:source_id, source_id}
    end
  end

  def yard_key(%{id: id}), do: {:bus, id}

  @doc """
  The most load a substation of `base_kv` ordinarily delivers, in MW.

  A bus with no usable voltage gets the LOWEST ceiling, not the highest. That
  is not a stylistic choice: `base_kv >= kv` with a `nil` on the left is TRUE
  under Elixir term ordering, because atoms sort above numbers — so the guardless
  version answered `nil` with 1000.0 and made a voltage-less bus the single most
  attractive load and datacenter target in the network. Caught in review
  2026-08-23. `ParameterEstimator.cap_class_ceiling/1` already made the
  conservative choice for the same edge case; the two now agree.

  Non-positive MW gets the same treatment rather than a `MatchError`: this is
  public, documented API, and a census or a test may reasonably ask about a
  zero-MW bus.
  """
  def class_ceiling(base_kv) when is_number(base_kv) and base_kv > 0.0 do
    {_kv, mw} = Enum.find(@class_ceiling_mw, fn {kv, _mw} -> base_kv >= kv end)
    mw
  end

  def class_ceiling(_), do: @class_ceiling_mw |> Enum.map(&elem(&1, 1)) |> Enum.min()

  @doc """
  `%{bus_id => %{cap_mw, delivery_cap_mw, class_cap_mw, capability_mva, line_mva,
  bank_mva, degree, line_degree}}` for a network of `%{buses:, lines:, transformers:}`.

  Capability is the summed rating of the bus's branches, with **class-standard**
  transformer ratings rather than stored ones — see the module doc on anchoring
  — and `cap_mw` is `#{@cap_fraction}` of it. A bus with no line of its own is
  additionally held to what reaches the far terminals of its banks.

  `delivery_cap_mw` is what the allocator spends: the branch cap AND the class
  ceiling, whichever is smaller. `cap_mw` stays the branch cap alone so the
  census section named after it keeps measuring the same thing.
  """
  def capability(network) do
    {line_mva, line_degree} = incidence(network.lines, fn line -> line.rating_a_mva || 0.0 end)

    kv = Map.new(network.buses, &{&1.id, &1.base_kv})
    class = Map.new(network.transformers, &{&1.id, class_bank_mva(&1, kv)})

    {bank_mva, bank_degree} = incidence(network.transformers, &Map.fetch!(class, &1.id))

    # What a bank can actually deliver: the lines on its OTHER terminal. A
    # 100 MVA bank behind a 55 MVA line delivers 55 MVA, which is the whole of
    # HARVARD's story.
    bank_supply =
      Enum.reduce(network.transformers, %{}, fn xfmr, acc ->
        mva = Map.fetch!(class, xfmr.id)

        acc
        |> add(xfmr.from_bus_id, min(mva, Map.get(line_mva, xfmr.to_bus_id, 0.0)))
        |> add(xfmr.to_bus_id, min(mva, Map.get(line_mva, xfmr.from_bus_id, 0.0)))
      end)

    network.buses
    |> Enum.map(fn bus ->
      lines = Map.get(line_mva, bus.id, 0.0)
      bank = Map.get(bank_mva, bus.id, 0.0)

      capability =
        if lines > 0.0 do
          lines + bank
        else
          min(bank, Map.get(bank_supply, bus.id, 0.0))
        end

      class_cap = class_ceiling(bus.base_kv)

      {bus.id,
       %{
         cap_mw: @cap_fraction * capability,
         class_cap_mw: class_cap,
         delivery_cap_mw: min(@cap_fraction * capability, class_cap),
         capability_mva: capability,
         line_mva: lines,
         bank_mva: bank,
         degree: Map.get(line_degree, bus.id, 0) + Map.get(bank_degree, bus.id, 0),
         line_degree: Map.get(line_degree, bus.id, 0)
       }}
    end)
    |> Map.new()
  end

  defp add(map, nil, _value), do: map
  defp add(map, key, value), do: Map.update(map, key, value, &(&1 + value))

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

  # The rating BusMapper would give this bank knowing nothing about the load on
  # it: a function of the high-side class alone (see the module doc). Asking
  # BusMapper itself keeps one table of class ratings in the codebase.
  defp class_bank_mva(xfmr, kv) do
    high = Map.get(kv, xfmr.from_bus_id) || 0.0
    low = Map.get(kv, xfmr.to_bus_id) || 0.0

    %{rated_mva: mva} =
      BusMapper.transformer_attrs(
        %Bus{id: 1, base_kv: max(high, low)},
        %Bus{id: 2, base_kv: min(high, low)}
      )

    mva
  end

  @doc false
  def network do
    buses =
      from(b in Bus,
        select: %{
          id: b.id,
          bus_type: b.bus_type,
          base_kv: b.base_kv,
          source: b.source,
          source_id: b.source_id,
          balancing_authority_id: b.balancing_authority_id,
          lon: fragment("ST_X(?)", b.coordinates),
          lat: fragment("ST_Y(?)", b.coordinates)
        }
      )
      |> Repo.all(timeout: :infinity)

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

    %{buses: buses, lines: lines, transformers: transformers}
  end

  # ---------------------------------------------------------------------------
  # Population spread
  # ---------------------------------------------------------------------------

  @doc """
  `%{county_id => radius_m}` — how far from its interior point a county's
  population should be spread.

  The Census Gazetteer publishes an interior point per county and no boundary,
  and no tract-level file is vendored, so the extent is inferred from the
  spacing of neighbouring counties: they tile the country without gaps, so the
  distance to the nearest few interior points measures local county size. For a
  tiling at spacing `s` the equal-area radius is `0.50 s` (squares) to `0.53 s`
  (hexagons); this takes `0.55 x mean(3 nearest)`.

  Calibrated against the Gazetteer's own `ALAND` (equal-area radius
  `sqrt(ALAND/pi)`) over all 3,144 ingested counties: median 21.8 km vs
  22.5 km (ratio 0.96), 10th percentile 15.4 vs 15.4 km, 90th 36.9 vs 39.0 km,
  per-county correlation 0.64. That is the honest limit — it estimates the
  LOCAL county scale well and a single county's own area only roughly, the
  scatter coming from counties whose neighbours are much larger or smaller
  than they are. It is used as the width of a smooth kernel, where local scale
  is what matters and a few km of error moves load between substations of the
  same city.

  `ALAND` is not read directly because it is a column of the Gazetteer FILE and
  not of `county_population`: it would be NULL on every existing database, and
  a radius that silently changes meaning at the next re-ingest is worse than
  one always derived the same way.
  """
  @radius_from_spacing 0.55
  @radius_neighbours 3
  @min_radius_m 8_000.0
  @max_radius_m 120_000.0

  def spread_radii(counties) do
    index = build_index(counties)

    Map.new(counties, fn county ->
      spacing =
        index
        |> nearest(county, @radius_neighbours + 1)
        |> Enum.reject(&(elem(&1, 0) == county.id))
        |> Enum.take(@radius_neighbours)
        |> case do
          [] -> @max_radius_m / @radius_from_spacing
          found -> Enum.sum(Enum.map(found, &elem(&1, 1))) / length(found)
        end

      {county.id, clamp(@radius_from_spacing * spacing, @min_radius_m, @max_radius_m)}
    end)
  end

  defp population_allocation(candidates, counties, target_mw) do
    radii = spread_radii(counties)
    index = build_index(candidates)

    # 20% floor, spread over the candidate set rather than over every PQ bus (a
    # bus that cannot serve load should not hold a floor either) and in
    # proportion to serving capability, like everything else here.
    uniform_mw = (1.0 - @population_weight) * target_mw
    population_mw = @population_weight * target_mw

    total_pop = counties |> Enum.map(& &1.population) |> Enum.sum()

    caps = Map.new(candidates, &{&1.id, &1.cap_mw})

    # Water-filled, not one clipped pass. A single `min(share, cap)` drops the
    # clipped MW on the floor: the national floor is 3.1 MW a bus and no cap
    # comes near it, but a small candidate set makes it reachable and a
    # baseline that shrinks silently moves every BA share.
    {base, floor_residual} =
      fill_fixed(
        Enum.map(candidates, &{&1.id, &1.serving_weight}),
        uniform_mw,
        Map.new(candidates, &{&1.id, 0.0}),
        caps
      )

    demands =
      Enum.map(counties, fn county ->
        %{
          county: county,
          radius: Map.fetch!(radii, county.id),
          reach: @spread_radii * Map.fetch!(radii, county.id),
          demand: population_mw * county.population / total_pop
        }
      end)

    {allocation, residual} = fill(demands, base, caps, index, candidates)

    stats = %{
      counties: length(counties),
      candidates: length(candidates),
      capped_buses:
        Enum.count(allocation, fn {id, mw} -> mw >= Map.fetch!(caps, id) - 1.0e-6 end),
      residual_mw: residual + floor_residual,
      floor_mw: uniform_mw
    }

    {:ok, allocation, stats}
  end

  # Every candidate within `reach`, under a kernel that is flat across the
  # county and decays outside it. No distance floor: the old rule's
  # GREATEST(dist, 1000) is what let a bus 1.5 km from Harris County's interior
  # point take 1,530 MW off a 5 M-person county.
  defp county_weights(%{county: county, radius: radius, reach: reach}, index) do
    index
    |> within(county, reach)
    |> Enum.map(fn {candidate, d} ->
      ratio = d / radius
      {candidate.id, candidate.serving_weight / (1.0 + ratio * ratio)}
    end)
  end

  # Water-filling, county by county. A county's own demand is spread over its
  # own kernel; whatever the caps refuse comes back to THAT county and is
  # re-spread, widening its reach when everything within it is already full.
  # Overflow that went to a national pool instead would move Houston's surplus
  # to Idaho and rewrite bus->BA attribution wholesale.
  defp fill(demands, base, caps, index, candidates) do
    {allocation, pending} =
      Enum.reduce(1..@max_overflow_rounds, {base, demands}, fn _round, {allocation, pending} ->
        if pending == [] do
          {allocation, []}
        else
          fill_round(allocation, pending, caps, index, candidates)
        end
      end)

    {allocation, pending |> Enum.map(& &1.demand) |> Enum.sum() |> Kernel.*(1.0)}
  end

  defp fill_round(allocation, pending, caps, index, candidates) do
    Enum.reduce(pending, {allocation, []}, fn entry, {acc, still} ->
      open =
        entry
        |> county_weights(index)
        |> Enum.filter(fn {id, _w} -> Map.get(acc, id, 0.0) < caps[id] - 1.0e-9 end)

      total_w = open |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      cond do
        entry.demand <= 1.0e-6 ->
          {acc, still}

        # Everything this county can reach is full. Widen rather than drop the
        # load: a national total that shrinks silently moves every BA share.
        total_w <= 0.0 ->
          spill_outward(entry, acc, still, candidates, caps)

        true ->
          {acc, spilled} =
            Enum.reduce(open, {acc, 0.0}, fn {id, w}, {acc, spilled} ->
              want = Map.get(acc, id, 0.0) + entry.demand * w / total_w
              cap = caps[id]
              {Map.put(acc, id, min(want, cap)), spilled + max(want - cap, 0.0)}
            end)

          if spilled > 1.0e-6 do
            {acc, [%{entry | demand: spilled} | still]}
          else
            {acc, still}
          end
      end
    end)
  end

  # Double the reach while that is still a local move. Past @max_reach_m the
  # kernel has stopped meaning anything, so the remainder goes to the nearest
  # bus anywhere with headroom left; if there is none, the network genuinely
  # cannot carry this load and the entry stays pending to be reported as
  # residual.
  @max_reach_m 500_000.0

  defp spill_outward(entry, allocation, still, candidates, caps) do
    if entry.reach < @max_reach_m do
      {allocation, [%{entry | reach: entry.reach * 2.0} | still]}
    else
      open =
        Enum.filter(candidates, &(Map.get(allocation, &1.id, 0.0) < caps[&1.id] - 1.0e-9))

      case open do
        [] ->
          {allocation, [entry | still]}

        open ->
          nearest =
            Enum.min_by(open, &distance_m(entry.county.lon, entry.county.lat, &1.lon, &1.lat))

          held = Map.get(allocation, nearest.id, 0.0)
          placed = min(entry.demand, caps[nearest.id] - held)
          allocation = Map.put(allocation, nearest.id, held + placed)
          rest = entry.demand - placed

          if rest > 1.0e-6 do
            {allocation, [%{entry | demand: rest} | still]}
          else
            {allocation, still}
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Legacy heuristic (no census data)
  # ---------------------------------------------------------------------------

  # 50% uniform + 50% proportional to bus-attached generation, still subject to
  # the capability cap.
  defp gen_proximity_allocation(candidates, target_mw, opts) do
    total_gen =
      Keyword.get_lazy(opts, :total_gen, fn ->
        Repo.one(
          from g in Generator,
            where: g.status == "in_service" and not is_nil(g.bus_id),
            select: sum(g.p_max_mw)
        ) || 0.0
      end)

    gen_per_bus =
      Repo.all(
        from g in Generator,
          where: g.status == "in_service" and not is_nil(g.bus_id),
          group_by: g.bus_id,
          select: {g.bus_id, sum(g.p_max_mw)}
      )
      |> Map.new()

    n = length(candidates)

    weights =
      Enum.map(candidates, fn bus ->
        weight =
          if total_gen > 0.0 do
            0.5 / n + 0.5 * Map.get(gen_per_bus, bus.id, 0.0) / total_gen
          else
            1.0 / n
          end

        {bus.id, weight}
      end)

    caps = Map.new(candidates, &{&1.id, &1.cap_mw})
    base = Map.new(candidates, &{&1.id, 0.0})
    {allocation, residual} = fill_fixed(weights, target_mw, base, caps)

    {:ok, allocation,
     %{counties: 0, candidates: n, capped_buses: 0, residual_mw: residual, floor_mw: 0.0}}
  end

  # Water-filling over one fixed set of weights, with no geography to widen
  # into: the fallback has no county data to be local about.
  defp fill_fixed(weights, demand, allocation, caps) do
    Enum.reduce_while(1..@max_overflow_rounds, {allocation, demand}, fn _round,
                                                                        {allocation, demand} ->
      open =
        Enum.filter(weights, fn {id, _w} -> Map.get(allocation, id, 0.0) < caps[id] - 1.0e-9 end)

      total_w = open |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      if demand <= 1.0e-6 or total_w <= 0.0 do
        {:halt, {allocation, demand}}
      else
        {allocation, spilled} =
          Enum.reduce(open, {allocation, 0.0}, fn {id, w}, {acc, spilled} ->
            want = Map.get(acc, id, 0.0) + demand * w / total_w
            cap = caps[id]
            {Map.put(acc, id, min(want, cap)), spilled + max(want - cap, 0.0)}
          end)

        {:cont, {allocation, spilled}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  defp write_loads(allocation) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      Enum.map(allocation, fn {bus_id, p_mw} ->
        p_mw = Float.round(p_mw, 2)

        %{
          bus_id: bus_id,
          p_mw: p_mw,
          q_mvar: Float.round(p_mw * @q_ratio, 2),
          load_type: "constant_power",
          status: "in_service",
          inserted_at: now,
          updated_at: now
        }
      end)

    rows
    |> Enum.chunk_every(500)
    |> Enum.each(fn batch ->
      Repo.insert_all(Load, batch,
        on_conflict: {:replace, [:p_mw, :q_mvar, :updated_at]},
        conflict_target: [:bus_id, :load_type]
      )
    end)

    # Buses the rule no longer serves keep no row: a 0 MW load is a bus the
    # snapshot still ships to the solver and the censuses still count. Passed
    # as one array parameter, not an IN list — there are 71,665 of them and
    # Postgres takes 65,535 parameters.
    keep = Map.keys(allocation)

    {dropped, _} =
      Repo.delete_all(
        from l in Load,
          where: l.load_type == "constant_power" and fragment("? <> ALL(?)", l.bus_id, ^keep)
      )

    dropped
  end

  defp report(stats, allocation) do
    total = allocation |> Map.values() |> Enum.sum()

    IO.puts(
      "  Created #{map_size(allocation)} loads, total: #{Float.round(total, 0)} MW " <>
        "(#{stats.capped_buses} at their capability cap)"
    )

    if stats.residual_mw > 1.0 do
      Logger.warning(
        "Load allocation could not place #{Float.round(stats.residual_mw, 1)} MW " <>
          "within the capability caps of the counties that hold it"
      )
    end
  end

  defp load_by_bus do
    from(l in Load,
      where: l.load_type == "constant_power",
      select: {l.bus_id, l.p_mw}
    )
    |> Repo.all(timeout: :infinity)
    |> Map.new()
  end

  defp water_facility_mw do
    Repo.one(
      from w in PowerModel.Grid.WaterFacility,
        where: w.status == "active" and not is_nil(w.bus_id) and w.power_consumption_mw > 0.0,
        select: sum(w.power_consumption_mw)
    ) || 0.0
  end

  defp movement(before, allocation) do
    ids = MapSet.union(MapSet.new(Map.keys(before)), MapSet.new(Map.keys(allocation)))

    Enum.reduce(ids, %{moved_mw: 0.0, gained: 0, lost: 0, emptied: 0}, fn id, acc ->
      was = Map.get(before, id, 0.0)
      now = Map.get(allocation, id, 0.0)
      delta = now - was

      %{
        acc
        | moved_mw: acc.moved_mw + max(delta, 0.0),
          gained: acc.gained + if(delta > 0.01, do: 1, else: 0),
          lost: acc.lost + if(delta < -0.01, do: 1, else: 0),
          emptied:
            acc.emptied +
              if(was > 0.0 and now == 0.0 and not is_map_key(allocation, id), do: 1, else: 0)
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Geometry
  # ---------------------------------------------------------------------------

  # A flat grid keyed by whole cells of @cell_km on a side. Buses carry a GIST
  # index, but these queries run per county over a filtered candidate set the
  # planner cannot index, and there are only ~10^5 points either way.
  @cell_km 25.0
  @km_per_degree 111.32

  defp build_index(points) do
    Enum.group_by(points, &cell(&1.lon, &1.lat))
  end

  defp cell(lon, lat) do
    lat_deg = @cell_km / @km_per_degree
    {floor(lat / lat_deg), floor(lon / lon_degree(lat))}
  end

  # A degree of longitude shrinks away from the equator, so the cell has to
  # cover more degrees of it to stay @cell_km wide on the ground.
  defp lon_degree(lat) do
    @cell_km / @km_per_degree / max(:math.cos(lat * :math.pi() / 180.0), 0.2)
  end

  # Every indexed point within `radius_m`, with its distance. The ring count
  # covers the radius, and one extra ring absorbs the longitude cell growing
  # with latitude between the query point and its neighbours.
  defp within(index, %{lon: lon, lat: lat}, radius_m) do
    rings = ceil(radius_m / 1000.0 / @cell_km) + 1
    {row, col} = cell(lon, lat)

    for dr <- -rings..rings, dc <- -rings..rings, reduce: [] do
      acc ->
        Enum.reduce(Map.get(index, {row + dr, col + dc}, []), acc, fn point, acc ->
          d = distance_m(lon, lat, point.lon, point.lat)
          if d <= radius_m, do: [{point, d} | acc], else: acc
        end)
    end
  end

  # `[{id, distance_m}]` for the `count` nearest indexed points, widening the
  # search until it finds them (a county in the middle of Nevada has no
  # neighbour within one ring).
  defp nearest(index, point, count, radius_m \\ @cell_km * 1000.0) do
    found = within(index, point, radius_m)

    if length(found) >= count + 1 or radius_m >= @max_radius_m * 4 do
      found
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.take(count)
      |> Enum.map(fn {p, d} -> {p.id, d} end)
    else
      nearest(index, point, count, radius_m * 2.0)
    end
  end

  @earth_radius_m 6_371_000.0

  defp distance_m(lon1, lat1, lon2, lat2) do
    dlat = (lat2 - lat1) * :math.pi() / 180.0
    dlon = (lon2 - lon1) * :math.pi() / 180.0
    mean_lat = (lat1 + lat2) / 2.0 * :math.pi() / 180.0

    x = dlon * :math.cos(mean_lat)
    @earth_radius_m * :math.sqrt(x * x + dlat * dlat)
  end

  defp clamp(value, lo, hi), do: value |> max(lo) |> min(hi)
end
