defmodule PowerModel.Ingestion.BusMapper do
  @moduledoc """
  Maps generators, transmission lines to buses via substations.

  Strategy:
  0. Merge terminating-line voltages into each substation's level list
     (`Substations.augment_voltage_levels_from_lines/0`) so a level a line
     actually terminates at always has a bus to land on
  1. One bus per substation per voltage level — EVERY level in
     `substations.voltage_levels`, not just the max and min (LIN-5)
  2. Map transmission line endpoints by HIFLD SUB_1/SUB_2 NAME first, with a
     tiered geometric snap as the fallback (see
     `map_transmission_line_buses/0`)
  3. Chain transformers across ADJACENT voltage levels at each substation
  4. Map generators to a bus that can evacuate them (10 km radius, wider for
     units the local sub-transmission cannot carry — see
     `map_generators_to_buses/0`)

  Generators are placed LAST because the rule that places them reads the
  connected branch capacity of each candidate bus, and a bus has no branches
  until the line endpoints and the level chains exist. Nothing in the line or
  transformer passes reads a generator, so the reorder is free.

  `repair_connectivity/0` is a separate pass, run after cleanup: it joins
  components that the endpoint mapping left apart even though they are the
  same yard (ROADMAP item 12).

  ## Fill mode vs re-map mode

  `run/0` fills: it creates buses and transformers that do not exist yet and
  never revisits a row it wrote before, so a corrected parameter recipe can
  never reach the existing rows.

  `remap/0` runs the same passes and then revisits transformers stamped below
  `params_version/0` (ROADMAP item 8): parameters are recomputed from the
  current recipe, the row is oriented high side first, and a bank that now
  spans NON-adjacent levels — because the substation gained the level between
  its terminals — is taken out of service in favour of the chain that replaces
  it. Buses are never rewritten or deleted in either mode; a substation whose
  voltage list grew gains buses and keeps the ones it had, along with
  everything pointing at them (DAT-9).
  """

  import Ecto.Query
  require Logger
  alias PowerModel.Repo

  alias PowerModel.Grid.{
    Bus,
    BalancingAuthority,
    Generator,
    Load,
    TransmissionLine,
    Substation,
    Transformer
  }

  alias PowerModel.Ingestion.HIFLD.{EndpointMatcher, Names, Substations}

  @gen_match_radius_m 10_000

  # LIN13-B. A plant is placed on a bus whose voltage class can plausibly
  # evacuate it: 115 kV for anything above #{100.0} MW, 230 kV above
  # #{500.0} MW. This is a DELIBERATE REVERSAL of LIN-8's lowest-level
  # tie-break for large units, and the reason is the same physics LIN-8 cites.
  # LIN-8 places a generator on the bottom level of its yard because the GSU
  # is not modeled; for a 6.8 GW plant that argument inverts — the un-modeled
  # GSU is precisely the element that carries the output, so landing the plant
  # on the yard's 115 kV bus asks sub-transmission to evacuate a flow that in
  # reality never touches it (Grand Coulee: 6,809 MW on a 115 kV bus with
  # 537 MVA of connected branch, 0.37 km from a 500 kV yard, producing a DC
  # angle of 180 degrees on the 115 kV corridor out of it). Below the
  # threshold LIN-8 is untouched: no floor applies and the lowest level still
  # wins.
  @gen_hv_plant_mw 100.0
  @gen_hv_floor_kv 115.0
  @gen_ehv_plant_mw 500.0
  @gen_ehv_floor_kv 230.0

  # When nothing inside #{div(@gen_match_radius_m, 1000)} km clears the floor,
  # the search widens for the floor-qualified candidates only. A GW-scale
  # plant is always tied to the EHV network within a few tens of km, and the
  # gen-tie that reaches it is exactly the element this rule stands in for.
  @gen_hv_search_radius_m 25_000

  # Candidates within this distance of each other are "the same site" as far
  # as the placement ranking is concerned; see `nearest_plant_bus/6`.
  @same_site_km 1.0

  # A bus "can evacuate" a plant when its connected branch rating covers the
  # nameplate with this much headroom — the same ratio the stranding census
  # (`mix grid.census stranding`) is measured at, so the placement rule and
  # the metric it is gated on cannot drift apart.
  @stranding_headroom 1.2

  # Tiered geometric snap radii for endpoints whose name resolves nothing
  # (ROADMAP item 12). Tier 1 is a confident snap; tier 2 is accepted but
  # counted, because at 10 km the endpoint could belong to a neighbouring
  # yard; anything further is left for `Cleanup.remap_unmapped_lines/0`, whose
  # 50 km search is flagged as a last resort.
  @snap_tier_1_km 2.0
  @snap_tier_2_km 10.0

  # A bus level this far from the line's voltage is a different voltage class,
  # not the same one measured differently.
  @level_tolerance 0.10

  # Cell size of the in-memory bus index, in degrees (~11 km of latitude).
  # 189,238 endpoints x a PostGIS round trip each is hours of round trips; the
  # same search over a grid hash is seconds.
  @grid_cell_deg 0.1

  # repair_connectivity/0 thresholds. Both are deliberately tight: a joint is
  # an assertion that two records describe one electrical point.
  @repair_name_radius_km 5.0
  @repair_proximity_km 2.0

  # TOPO-4. The weld phase runs AFTER the two component-joining phases and
  # joins co-located same-level buses that are already in one component —
  # which the joining phases structurally cannot do, because they discard any
  # pair whose union-find roots already match. Tighter than the 2 km
  # proximity rule on purpose: at 250 m the claim "these two rows are one
  # yard" survives without fusing two genuinely adjacent urban yards.
  @weld_radius_km 0.25

  # TOPO-5. Both endpoints of a circuit resolving to one bus is only a stub
  # when the endpoints really are one point. Measured on the STRAIGHT-LINE
  # separation of the two endpoints, never on `length_km`: a circuit that
  # loops back into the yard it left has kilometres of conductor and zero
  # endpoint separation, and inventing a second bus for it would be fiction.
  @same_bus_split_km 1.0

  # TOPO-6. A bank is sized so its low side's load sits at or below this
  # fraction of the rating, in whole multiples of the voltage class's standard
  # unit.
  @bank_load_headroom 0.8

  # Bumped whenever the transformer parameter recipe below changes; `remap/0`
  # recomputes every transformer stamped lower. 1 = adjacent-level chaining,
  # rating from the genuine high side, LIN-3 impedance rebase.
  @params_version 1

  # A substation with no usable voltage at all still needs a bus.
  @default_bus_kv 138.0

  # The unordered-pair unique index (20260815152510) is an expression index,
  # so the upsert has to name the expression rather than the columns.
  @transformer_pair_conflict {:unsafe_fragment,
                              "(LEAST(from_bus_id, to_bus_id), GREATEST(from_bus_id, to_bus_id))"}

  # Balancing authorities in the Western Interconnection. A bus whose BA is in
  # this set belongs to Western no matter where its geographic fallback box
  # placed it. ERCO is the sole ERCOT balancing authority; every other BA is
  # Eastern (SPP, MISO, PJM, SERC, ...). Consumed by
  # reconcile_interconnections_from_ba/0.
  @wecc_ba_codes ~w(
    AVA AZPS BANC BPAT CHPD CISO DEAA DOPD EPE GCPD GRID GRIF GWA HGMA IID
    IPCO LDWP NEVP NWMT PACE PACW PGE PNM PSCO PSEI SCL SRP TEPC TIDC TPWR
    WACM WALC WAUW WWA
  )

  def run do
    Substations.augment_voltage_levels_from_lines()
    create_substation_buses()
    map_transmission_line_buses()
    create_substation_transformers()
    map_generators_to_buses()
  end

  @doc """
  Fill pass plus the re-map passes `run/0` deliberately skips.

  Adds the buses for levels a substation has gained, chains the transformers
  those new levels make possible, then brings every transformer stamped below
  `params_version/0` up to the current recipe. Returns a summary map.
  """
  def remap do
    Substations.augment_voltage_levels_from_lines()
    buses = create_substation_buses()
    map_transmission_line_buses()
    created = create_substation_transformers()
    map_generators_to_buses()
    %{recomputed: recomputed, retired: retired} = remap_stale_transformers()

    Logger.info(
      "BusMapper.remap: #{buses} buses created, #{created} transformers created, " <>
        "#{recomputed} recomputed, #{retired} retired as non-adjacent"
    )

    %{
      buses_created: buses,
      transformers_created: created,
      transformers_recomputed: recomputed,
      transformers_retired: retired
    }
  end

  @doc "Current transformer parameter recipe version. See `remap/0`."
  def params_version, do: @params_version

  @doc """
  Create one bus per substation voltage level. Returns the number created.

  Additive and idempotent. A bus is keyed by `{"substation", "<sub id>_<kv>kV"}`,
  so re-running after a substation's voltage list grew creates only the buses
  for the new levels: the buses already there — and the lines, generators, and
  loads pointing at them — are left alone. That is what makes the level
  expansion safe on a live database (DAT-9); a 500/115 substation that
  re-ingests as 500/345/138/115 gains two buses rather than orphaning two.
  """
  def create_substation_buses do
    existing =
      from(b in Bus, where: b.source == "substation", select: b.source_id)
      |> Repo.all()
      |> MapSet.new()

    pending =
      Substation
      |> Repo.all()
      |> Enum.flat_map(fn sub ->
        ic_name = interconnection_name(sub.coordinates)

        for kv <- voltage_levels(sub),
            source_id = bus_source_id(sub, kv),
            not MapSet.member?(existing, source_id),
            do: {sub, kv, source_id, ic_name}
      end)
      |> Enum.uniq_by(fn {_sub, _kv, source_id, _ic} -> source_id end)

    # Resolved once for the interconnections actually used, rather than once
    # per bus: at national scale that was one round trip per row.
    interconnection_ids =
      pending
      |> Enum.map(fn {_sub, _kv, _sid, ic_name} -> ic_name end)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1, get_or_create_interconnection(&1)})

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      Enum.map(pending, fn {sub, kv, source_id, ic_name} ->
        %{
          bus_type: 1,
          base_kv: kv,
          vm_pu: 1.0,
          va_rad: 0.0,
          coordinates: sub.coordinates,
          source: "substation",
          source_id: source_id,
          interconnection_id: Map.get(interconnection_ids, ic_name),
          inserted_at: now,
          updated_at: now
        }
      end)

    entries
    |> Enum.chunk_every(1000)
    |> Enum.each(
      &Repo.insert_all(Bus, &1, on_conflict: :nothing, conflict_target: [:source, :source_id])
    )

    length(entries)
  end

  @doc """
  The voltage levels that get a bus at `sub`, descending.

  Prefers the stored `voltage_levels` list; falls back to max/min for rows
  ingested before the column existed, and to #{@default_bus_kv} kV for a
  substation with no usable voltage at all. Levels that would format to the
  same one-decimal `source_id` are collapsed so a substation can never try to
  claim one bus key twice.
  """
  def voltage_levels(%Substation{} = sub) do
    stored =
      case sub.voltage_levels do
        [_ | _] = levels -> levels
        _ -> [sub.max_voltage_kv, sub.min_voltage_kv]
      end

    levels =
      stored
      |> Enum.reject(&(is_nil(&1) or &1 <= 0))
      |> Enum.map(&(&1 * 1.0))
      |> Enum.sort(:desc)
      |> Enum.uniq_by(&format_kv/1)

    case levels do
      [] -> [@default_bus_kv]
      l -> l
    end
  end

  # LIN-10: one-decimal kv keeps distinct near-integer levels (138.0 vs 138.4)
  # from colliding into one source_id the way round/1 did.
  defp bus_source_id(%Substation{id: id}, kv), do: "#{id}_#{format_kv(kv)}kV"

  # Inverse of bus_source_id/2: buses carry no substation FK, so the owning
  # substation is read back off the source_id.
  defp substation_id_from_source_id(source_id) when is_binary(source_id) do
    case Integer.parse(source_id) do
      {id, "_" <> _} -> id
      _ -> nil
    end
  end

  defp substation_id_from_source_id(_), do: nil

  @doc """
  Attach every unmapped generator to a bus within
  #{div(@gen_match_radius_m, 1000)} km that can plausibly evacuate its PLANT,
  or to a synthetic bus at the plant.

  Placement is per PLANT, not per unit (LIN13-B): Grand Coulee is 33 rows of
  ~206 MW, and a per-row size test would see 33 small machines instead of one
  6.8 GW station. Units sharing an `eia_plant_id` are sized together and land
  on one bus; a unit without a plant id is its own plant.

  The candidate filter, for a plant above #{@gen_hv_plant_mw} MW, is
  `base_kv >= #{@gen_hv_floor_kv}` (above #{@gen_ehv_plant_mw} MW:
  `>= #{@gen_ehv_floor_kv}`) — see the `@gen_hv_plant_mw` note on why this
  deliberately reverses LIN-8's lowest-level tie-break for large units.
  Qualifying candidates are ranked by

    1. distance bucketed to #{@same_site_km} km, so a bus in the plant's own
       yard can never lose to a fatter one twenty kilometres away,
    2. whether the bus's connected branch rating covers
       #{@stranding_headroom} x the plant (the stranding-census criterion),
    3. the LOWEST qualifying level — LIN-8's preference, applied above the
       floor rather than below it,
    4. exact distance, then bus id, so the result never depends on map
       ordering.

  "Same-yard higher level beats a nearer low-voltage yard" falls out of the
  filter rather than needing a special case: a nearer yard whose every level
  sits under the floor is not a candidate at all.

  Plants that find no qualifying bus inside the normal radius get one more
  search at #{div(@gen_hv_search_radius_m, 1000)} km before the rule gives up
  and the LIN-8 any-level placement applies; that fallback is counted
  (`:floor_unreachable`) rather than silent. At that range an asynchronous
  seam is reachable, so the widened search is confined to the interconnection
  of the plant's own neighbourhood — the nearest bus at any level, which is
  where LIN-8 would have put it.

  The search runs against the same in-memory grid the line mapping uses. The
  equivalent PostGIS query cannot use the GiST index on `buses.coordinates`,
  because it casts to `geography` and the index is on the geometry — measured
  at 41 ms per generator, which is ~18 minutes of round trips for the national
  fleet.
  """
  def map_generators_to_buses do
    generators =
      from(g in Generator,
        where: is_nil(g.bus_id) and not is_nil(g.coordinates),
        select: %{
          id: g.id,
          eia_plant_id: g.eia_plant_id,
          p_max_mw: g.p_max_mw,
          coordinates: g.coordinates,
          lon: fragment("ST_X(?::geometry)", g.coordinates),
          lat: fragment("ST_Y(?::geometry)", g.coordinates)
        }
      )
      |> Repo.all()

    context = placement_context()
    plant_mw = plant_capacity_index()

    {assignments, synthetic, stats} =
      generators
      |> Enum.group_by(&plant_key/1)
      # Sorted so a re-run places the plants in the same order it did before.
      |> Enum.sort_by(fn {key, _units} -> key end)
      |> Enum.reduce({[], [], %{}}, fn {key, units}, {assigned, unassigned, stats} ->
        anchor = Enum.min_by(units, & &1.id)
        mw = Map.get(plant_mw, key) || plant_group_mw(units)

        case place_plant(context, anchor, mw) do
          {bus_id, rule} ->
            {Enum.map(units, &{&1.id, bus_id}) ++ assigned, unassigned, bump(stats, rule)}

          nil ->
            {assigned, units ++ unassigned, bump(stats, :synthetic)}
        end
      end)

    apply_generator_bus_updates(assignments)
    create_synthetic_generator_buses(synthetic)

    Logger.info(
      "BusMapper: #{length(assignments)} generators mapped to substation buses, " <>
        "#{length(synthetic)} on synthetic buses; plant placement " <>
        "#{inspect(Enum.sort(Map.to_list(stats)))}"
    )

    Map.merge(stats, %{mapped: length(assignments), synthetic: length(synthetic)})
  end

  @doc """
  Re-place plants whose CURRENT bus fails the placement rule (LIN13-B), and
  return `%{plants: n, generators: n, moved_mw: mw, examined: n}`.

  `map_generators_to_buses/0` is a fill: it never revisits a generator that
  already has a bus, so the rule it enforces can only reach rows written after
  it. This is the re-map half, and it is deliberately conservative — a plant
  moves only when the bus it sits on fails the rule AND the bus the rule
  chooses is a strict improvement (it clears a floor the current bus does not,
  or it can carry the plant where the current bus cannot). A plant already on
  the best bus available is left alone, so re-running is a no-op.

  Loads are never touched, so bus->BA demand attribution cannot move.
  """
  def remap_stranded_generators(opts \\ []) do
    context = placement_context()
    capacity = context.capacity
    plant_mw = plant_capacity_index()
    bus_kv = bus_voltage_index()

    generators =
      from(g in Generator,
        where: not is_nil(g.bus_id) and not is_nil(g.coordinates) and g.status == "in_service",
        select: %{
          id: g.id,
          eia_plant_id: g.eia_plant_id,
          p_max_mw: g.p_max_mw,
          bus_id: g.bus_id,
          lon: fragment("ST_X(?::geometry)", g.coordinates),
          lat: fragment("ST_Y(?::geometry)", g.coordinates)
        }
      )
      |> Repo.all()

    plants =
      generators
      |> Enum.group_by(&plant_key/1)
      |> Enum.sort_by(fn {key, _units} -> key end)

    {moves, moved_plants, moved_mw} =
      Enum.reduce(plants, {[], 0, 0.0}, fn {key, units}, {moves, count, mw_total} ->
        mw = Map.get(plant_mw, key) || plant_group_mw(units)
        anchor = Enum.min_by(units, & &1.id)
        current = Enum.map(units, & &1.bus_id) |> Enum.uniq()

        with true <- Enum.any?(current, &stranded_placement?(&1, mw, capacity, bus_kv)),
             {bus_id, _rule} <- place_plant(context, anchor, mw, anchors(context.index, current)),
             false <- current == [bus_id],
             true <- improvement?(bus_id, current, mw, capacity, bus_kv) do
          {Enum.map(units, &{&1.id, bus_id}) ++ moves, count + 1, mw_total + mw}
        else
          _ -> {moves, count, mw_total}
        end
      end)

    unless Keyword.get(opts, :dry_run, false), do: apply_generator_bus_updates(moves)

    Logger.info(
      "BusMapper: remapped #{moved_plants} stranded plants " <>
        "(#{length(moves)} generators, #{Float.round(moved_mw / 1000.0, 1)} GW)"
    )

    %{
      examined: length(plants),
      plants: moved_plants,
      generators: length(moves),
      moved_mw: moved_mw
    }
  end

  # The bus this plant sits on cannot represent it: its class is under the
  # floor, or its branches cannot carry the nameplate.
  #
  # The floor half is not redundant with the capacity half, and the ERCOT
  # 69 kV corridor is why. Bus 66388 carries 180 MW of wind against 316 MVA of
  # connected branch and passes the capacity test comfortably — but the
  # 316 MVA is one 116 MVA line plus one 200 MVA bank, and the 485 MW the
  # corridor's two wind farms inject has nowhere to go except along 48 km of
  # 69 kV conductor, at 95 degrees. Both plants have a 138 kV bus in their own
  # yard, 0 m away, on the far side of the bank they are wrongly under.
  defp stranded_placement?(bus_id, plant_mw, capacity, bus_kv) do
    case plant_voltage_floor(plant_mw) do
      nil ->
        false

      floor_kv ->
        Map.get(bus_kv, bus_id, 0.0) < floor_kv or
          Map.get(capacity, bus_id, 0.0) < @stranding_headroom * plant_mw
    end
  end

  # Only a strict gain justifies moving a plant: the new bus clears a floor
  # none of the current ones do, or it can carry the plant where none of them
  # can. Anything else is churn.
  defp improvement?(bus_id, current, plant_mw, capacity, bus_kv) do
    floor_kv = plant_voltage_floor(plant_mw) || 0.0
    needed = @stranding_headroom * plant_mw

    clears_floor? = Map.get(bus_kv, bus_id, 0.0) >= floor_kv
    carries? = Map.get(capacity, bus_id, 0.0) >= needed

    current_clears? = Enum.any?(current, &(Map.get(bus_kv, &1, 0.0) >= floor_kv))
    current_carries? = Enum.any?(current, &(Map.get(capacity, &1, 0.0) >= needed))

    (clears_floor? and not current_clears?) or (carries? and not current_carries?)
  end

  defp bus_voltage_index do
    from(b in Bus, select: {b.id, b.base_kv}) |> Repo.all() |> Map.new()
  end

  @doc """
  Weld co-located same-level buses (TOPO-4) without running the
  component-joining phases, and return `%{welded: n, components_before: n,
  components_after: n}`.

  The migration entry point for the weld rule documented in
  `repair_connectivity/1`.
  """
  def weld_colocated_buses(opts \\ []) do
    weld_km = Keyword.get(opts, :weld_km, @weld_radius_km)

    buses = repair_bus_rows()
    uf = components(buses)
    before = count_roots(uf, buses)

    {uf, joints} = weld_colocated(buses, uf, weld_km, [])
    insert_repair_lines(joints)

    after_count = count_roots(uf, buses)

    %{welded: length(joints), components_before: before, components_after: after_count}
  end

  @doc """
  The voltage floor a plant of `p_mw` must be placed at or above, or nil when
  no floor applies. See `map_generators_to_buses/0`.
  """
  def plant_voltage_floor(p_mw) when is_number(p_mw) do
    cond do
      p_mw > @gen_ehv_plant_mw -> @gen_ehv_floor_kv
      p_mw > @gen_hv_plant_mw -> @gen_hv_floor_kv
      true -> nil
    end
  end

  def plant_voltage_floor(_), do: nil

  @doc "Branch-rating headroom a bus needs to count as able to evacuate a plant."
  def stranding_headroom, do: @stranding_headroom

  # Units of one EIA plant are one machine set on one switchyard; a unit with
  # no plant id can only be judged on its own.
  defp plant_key(%{eia_plant_id: id}) when is_binary(id) and id != "", do: {:plant, id}
  defp plant_key(%{id: id}), do: {:unit, id}

  defp plant_group_mw(units), do: Enum.sum(Enum.map(units, &(&1.p_max_mw || 0.0)))

  # Whole-plant nameplate, including units this pass is not placing (already
  # mapped ones): the size test asks how much steel is behind the switchyard,
  # not how much of it happens to be unmapped right now.
  defp plant_capacity_index do
    from(g in Generator,
      where: g.status == "in_service" and not is_nil(g.eia_plant_id) and g.eia_plant_id != "",
      group_by: g.eia_plant_id,
      select: {g.eia_plant_id, sum(g.p_max_mw)}
    )
    |> Repo.all()
    |> Map.new(fn {plant, mw} -> {{:plant, plant}, (mw || 0.0) * 1.0} end)
  end

  @doc """
  Total in-service branch rating (line rate A plus transformer nameplate)
  incident on each bus, as `%{bus_id => mva}`.

  This is the denominator of the stranding census and the capacity term in the
  generator placement rule.
  """
  def connected_branch_capacity do
    Repo.query!(
      """
      SELECT bus_id, SUM(mva) FROM (
        SELECT from_bus_id AS bus_id, COALESCE(rating_a_mva, 0.0) AS mva
          FROM transmission_lines WHERE status = 'in_service'
        UNION ALL
        SELECT to_bus_id, COALESCE(rating_a_mva, 0.0)
          FROM transmission_lines WHERE status = 'in_service'
        UNION ALL
        SELECT from_bus_id, COALESCE(rated_mva, 0.0)
          FROM transformers WHERE status = 'in_service'
        UNION ALL
        SELECT to_bus_id, COALESCE(rated_mva, 0.0)
          FROM transformers WHERE status = 'in_service'
      ) branch
      WHERE bus_id IS NOT NULL
      GROUP BY bus_id
      """,
      [],
      timeout: :infinity
    ).rows
    |> Map.new(fn [bus_id, mva] -> {bus_id, (mva || 0.0) * 1.0} end)
  end

  # Everything the placement rule reads: the bus grid, the connected branch
  # capacity it ranks on, and the interconnection of each bus, which bounds
  # the widened search.
  defp placement_context do
    index = load_bus_index()

    %{
      index: index,
      grid: build_grid(index.all),
      capacity: connected_branch_capacity(),
      interconnection: Map.new(index.by_id, fn {id, {_kv, _lon, _lat, ic}} -> {id, ic} end)
    }
  end

  # Coordinates of the buses a plant is already attached to. A remap searches
  # from these as well as from the plant's own coordinate, because in this
  # data the two disagree by up to 15 km — plant 58771's generator row sits
  # 15.0 km from the bus the network attaches it to, and only one of those two
  # points has a 115 kV bus within reach. Either is a legitimate record of
  # where the plant meets the grid, so both are searched.
  defp anchors(index, bus_ids) do
    for id <- bus_ids,
        row = Map.get(index.by_id, id),
        row != nil do
      {_kv, lon, lat, _ic} = row
      %{lon: lon, lat: lat}
    end
  end

  # {bus_id, rule} or nil. `rule` names which arm placed the plant so the
  # census in the log can separate a clean placement from a fallback.
  defp place_plant(context, anchor, plant_mw, extra_anchors \\ []) do
    radius_km = @gen_match_radius_m / 1000.0
    lin8 = nearest_in_grid(context.grid, anchor.lon, anchor.lat, radius_km, nil)

    case plant_voltage_floor(plant_mw) do
      nil ->
        # LIN-8 untouched: any level, lowest one at the nearest yard.
        with {bus_id, _key} <- lin8, do: {bus_id, :small_unit}

      floor_kv ->
        needed = @stranding_headroom * plant_mw
        wide_km = @gen_hv_search_radius_m / 1000.0
        points = Enum.uniq([anchor | extra_anchors])

        # Whichever system the plant's own neighbourhood belongs to. nil only
        # when nothing at all is within reach, in which case the widened
        # search has nothing to cross to either.
        home =
          with {bus_id, _key} <- lin8, do: Map.get(context.interconnection, bus_id)

        # The plant's own coordinate at the normal radius first, then every
        # anchor at the normal radius, then the wide one — so a nearby answer
        # always beats a distant one whichever anchor found it.
        attempts =
          [{anchor, radius_km, :above_floor}] ++
            for(point <- points, do: {point, radius_km, :above_floor}) ++
            for(point <- points, do: {point, wide_km, :above_floor_extended})

        attempts
        |> Enum.find_value(fn {point, km, rule} ->
          with {bus_id, _key} <-
                 nearest_plant_bus(context, point, km, floor_kv, needed, home),
               do: {bus_id, rule}
        end)
        |> case do
          nil -> with({bus_id, _key} <- lin8, do: {bus_id, :floor_unreachable})
          hit -> hit
        end
    end
  end

  # Nearest grid member at or above `min_kv` inside `home`, ranked capacity
  # first. See `map_generators_to_buses/0` for why that order.
  defp nearest_plant_bus(context, anchor, radius_km, min_kv, needed_mva, home) do
    %{lon: lon, lat: lat} = anchor

    context.grid
    |> grid_cells(lon, lat, radius_km)
    |> Enum.reduce(nil, fn members, best ->
      Enum.reduce(members, best, fn {id, base_kv, blon, blat}, acc ->
        distance = EndpointMatcher.haversine_km(lat, lon, blat, blon)

        if base_kv >= min_kv and distance <= radius_km and
             same_system?(context, id, home) do
          short = if Map.get(context.capacity, id, 0.0) >= needed_mva, do: 0, else: 1

          # Distance is bucketed to the kilometre before capacity gets a vote,
          # so a bus in the plant's OWN yard can never lose to a fatter one
          # twenty kilometres away; inside a bucket the bus that can carry the
          # plant wins, and then the lowest adequate level.
          key = {trunc(distance / @same_site_km), short, base_kv, distance, id}

          if acc == nil or key < elem(acc, 1), do: {id, key}, else: acc
        else
          acc
        end
      end)
    end)
  end

  # An unknown home cannot constrain anything; a known one is binding, and a
  # candidate with no interconnection at all cannot prove it is on this side of
  # the seam.
  defp same_system?(_context, _bus_id, nil), do: true

  defp same_system?(context, bus_id, home),
    do: Map.get(context.interconnection, bus_id) == home

  defp apply_generator_bus_updates([]), do: :ok

  defp apply_generator_bus_updates(assignments) do
    assignments
    |> Enum.chunk_every(2000)
    |> Enum.each(fn chunk ->
      Repo.query!(
        """
        UPDATE generators g
        SET bus_id = v.bus_id, updated_at = NOW()
        FROM (SELECT unnest($1::bigint[]) AS id, unnest($2::bigint[]) AS bus_id) v
        WHERE g.id = v.id
        """,
        [Enum.map(chunk, &elem(&1, 0)), Enum.map(chunk, &elem(&1, 1))]
      )
    end)
  end

  defp create_synthetic_generator_buses([]), do: :ok

  defp create_synthetic_generator_buses(generators) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      Enum.map(generators, fn gen ->
        %{
          bus_type: 2,
          base_kv: 13.8,
          vm_pu: 1.0,
          va_rad: 0.0,
          coordinates: gen.coordinates,
          source: "synthetic",
          source_id: "gen_#{gen.id}",
          inserted_at: now,
          updated_at: now
        }
      end)

    entries
    |> Enum.chunk_every(1000)
    |> Enum.each(
      &Repo.insert_all(Bus, &1, on_conflict: :nothing, conflict_target: [:source, :source_id])
    )

    # Read the ids back rather than trusting insert_all's returning across an
    # on_conflict: a re-run must reuse the bus it made last time.
    source_ids = Enum.map(generators, &"gen_#{&1.id}")

    bus_ids =
      from(b in Bus, where: b.source == "synthetic" and b.source_id in ^source_ids)
      |> Repo.all()
      |> Map.new(&{&1.source_id, &1.id})

    generators
    |> Enum.flat_map(fn gen ->
      case Map.get(bus_ids, "gen_#{gen.id}") do
        nil -> []
        bus_id -> [{gen.id, bus_id}]
      end
    end)
    |> apply_generator_bus_updates()
  end

  @doc """
  Resolve every unmapped transmission-line endpoint to a bus.

  HIFLD's `SUB_1`/`SUB_2` are the PRIMARY key (ROADMAP item 12): they name the
  substation the circuit terminates at, which is a far stronger claim than
  "some bus happened to be nearby at a similar voltage". Order of attempts per
  endpoint:

    1. **Name.** `EndpointMatcher` resolves the name to a substation (nearest
       one when several share the name), then the endpoint lands on that
       substation's bus whose level is closest to the line's own voltage.
       Endpoints named by a bare sentinel ("NOT AVAILABLE" on 17,559 of them,
       "DEAD HEAD", …) carry no identity and skip straight to step 2.
    2. **Tiered geometric snap** over every bus within #{trunc(@level_tolerance * 100)}%
       of the line's voltage: #{@snap_tier_1_km} km first, then
       #{@snap_tier_2_km} km (counted separately — at that range the endpoint
       may belong to a neighbour).
    3. Nothing. The endpoint stays NULL for `Cleanup.remap_unmapped_lines/0`,
       whose 50 km search is the flagged last resort.

  ## Both endpoints on one bus (TOPO-5)

  A circuit whose two endpoints resolve to the same bus used to be dropped
  whole — 3,442 endpoints that had resolved perfectly well were thrown away
  with it. What separates the two cases is the STRAIGHT-LINE separation of the
  endpoints, not the conductor length:

    * separation <= #{@same_bus_split_km} km — the endpoints really are one
      point (a jumper or a loop back into the yard it left). Still skipped;
      an intra-yard stub carries no topology and a second bus for it would be
      an invention.
    * separation > #{@same_bus_split_km} km — the far end is a second yard
      HIFLD failed to name. The endpoint nearer the resolved bus keeps it and
      the far endpoint is re-resolved with that bus excluded; if the geometric
      tiers still find nothing, a synthetic bus is created at the far
      coordinate, which `repair_connectivity/1` then welds into the network if
      a real bus sits within its radius.

  Both the substation index and the bus index are built once in memory: at
  94,619 lines the previous per-endpoint PostGIS query was 189,238 round trips.

  Returns a stats map and prints the per-tier census, which is the measurement
  ROADMAP item 12 is scored on.
  """
  def map_transmission_line_buses do
    name_index = EndpointMatcher.build_index()
    buses = load_bus_index()
    bus_grid = build_grid(buses.all)

    lines =
      from(tl in TransmissionLine,
        where:
          (is_nil(tl.from_bus_id) or is_nil(tl.to_bus_id)) and not is_nil(tl.geometry) and
            not is_nil(tl.voltage_kv),
        select: %{
          id: tl.id,
          voltage_kv: tl.voltage_kv,
          sub_1: tl.sub_1,
          sub_2: tl.sub_2,
          from_bus_id: tl.from_bus_id,
          to_bus_id: tl.to_bus_id,
          from_lon: fragment("ST_X(ST_StartPoint(?))", tl.geometry),
          from_lat: fragment("ST_Y(ST_StartPoint(?))", tl.geometry),
          to_lon: fragment("ST_X(ST_EndPoint(?))", tl.geometry),
          to_lat: fragment("ST_Y(ST_EndPoint(?))", tl.geometry)
        }
      )
      |> Repo.all()

    IO.puts("Mapping #{length(lines)} transmission line endpoints (name-first)...")

    context = %{name_index: name_index, buses: buses, grid: bus_grid}

    {updates, pending, stats} =
      Enum.reduce(lines, {[], [], %{}}, fn line, {updates, pending, stats} ->
        from_pt = point(line.from_lon, line.from_lat)
        to_pt = point(line.to_lon, line.to_lat)

        {from_bus, stats} = resolve_endpoint(context, line.sub_1, from_pt, line.voltage_kv, stats)
        {to_bus, stats} = resolve_endpoint(context, line.sub_2, to_pt, line.voltage_kv, stats)

        resolved_from = from_bus || line.from_bus_id
        resolved_to = to_bus || line.to_bus_id

        cond do
          not is_nil(resolved_from) and resolved_from == resolved_to ->
            split_same_bus(context, line, resolved_from, from_pt, to_pt, updates, pending, stats)

          is_nil(from_bus) and is_nil(to_bus) ->
            {updates, pending, stats}

          true ->
            {[{line.id, from_bus, to_bus} | updates], pending, stats}
        end
      end)

    synthetic_updates = create_endpoint_buses(pending)

    apply_line_bus_updates(updates ++ synthetic_updates)
    report_endpoint_stats(stats, 2 * length(lines))

    Map.put(stats, :lines_updated, length(updates) + length(synthetic_updates))
  end

  # TOPO-5: a circuit whose endpoints resolved to one bus. See the
  # "Both endpoints on one bus" section of `map_transmission_line_buses/0`.
  defp split_same_bus(context, line, bus_id, from_pt, to_pt, updates, pending, stats)

  defp split_same_bus(_context, _line, _bus_id, nil, _to_pt, updates, pending, stats),
    do: {updates, pending, bump(stats, :self_loop_skipped)}

  defp split_same_bus(_context, _line, _bus_id, _from_pt, nil, updates, pending, stats),
    do: {updates, pending, bump(stats, :self_loop_skipped)}

  defp split_same_bus(context, line, bus_id, from_pt, to_pt, updates, pending, stats) do
    {from_lon, from_lat} = from_pt
    {to_lon, to_lat} = to_pt
    separation = EndpointMatcher.haversine_km(from_lat, from_lon, to_lat, to_lon)

    if separation <= @same_bus_split_km do
      {updates, pending, bump(stats, :self_loop_skipped)}
    else
      # The endpoint that keeps the resolved bus is the one actually next to
      # it; the other end is the yard HIFLD did not name.
      {bus_kv, bus_lon, bus_lat, interconnection_id} = bus_row(context.buses, bus_id)
      from_km = EndpointMatcher.haversine_km(bus_lat, bus_lon, from_lat, from_lon)
      to_km = EndpointMatcher.haversine_km(bus_lat, bus_lon, to_lat, to_lon)

      {side, far_pt} = if from_km <= to_km, do: {:to, to_pt}, else: {:from, from_pt}
      voltage_kv = line.voltage_kv || bus_kv

      case snap_excluding(context, far_pt, voltage_kv, bus_id) do
        {:ok, other_id} ->
          {[endpoint_update(line.id, side, bus_id, other_id) | updates], pending,
           bump(stats, :same_bus_split)}

        :none ->
          entry = %{
            line_id: line.id,
            side: side,
            near_bus_id: bus_id,
            point: far_pt,
            voltage_kv: voltage_kv,
            interconnection_id: interconnection_id
          }

          {updates, [entry | pending], bump(stats, :same_bus_synthetic)}
      end
    end
  end

  defp endpoint_update(line_id, :to, near_bus_id, far_bus_id),
    do: {line_id, near_bus_id, far_bus_id}

  defp endpoint_update(line_id, :from, near_bus_id, far_bus_id),
    do: {line_id, far_bus_id, near_bus_id}

  # The geometric tiers again, with the bus the near endpoint already claimed
  # taken out of the running.
  defp snap_excluding(context, {lon, lat}, voltage_kv, exclude) do
    with nil <- nearest_in_grid(context.grid, lon, lat, @snap_tier_1_km, voltage_kv, exclude),
         nil <- nearest_in_grid(context.grid, lon, lat, @snap_tier_2_km, voltage_kv, exclude) do
      :none
    else
      {bus_id, _key} -> {:ok, bus_id}
    end
  end

  # A bus at the far endpoint of a circuit whose second yard is missing from
  # HIFLD. Keyed by line so a re-run reuses the bus it made last time, and
  # given the near end's interconnection so `repair_connectivity/1` is allowed
  # to weld it (a bus with no interconnection can never prove it is not across
  # an asynchronous seam).
  defp create_endpoint_buses([]), do: []

  defp create_endpoint_buses(pending) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      Enum.map(pending, fn entry ->
        {lon, lat} = entry.point

        %{
          bus_type: 1,
          base_kv: entry.voltage_kv,
          vm_pu: 1.0,
          va_rad: 0.0,
          coordinates: %Geo.Point{coordinates: {lon, lat}, srid: 4326},
          source: "synthetic",
          source_id: endpoint_bus_source_id(entry),
          interconnection_id: entry.interconnection_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    entries
    |> Enum.chunk_every(1000)
    |> Enum.each(
      &Repo.insert_all(Bus, &1, on_conflict: :nothing, conflict_target: [:source, :source_id])
    )

    source_ids = Enum.map(entries, & &1.source_id)

    bus_ids =
      from(b in Bus, where: b.source == "synthetic" and b.source_id in ^source_ids)
      |> Repo.all()
      |> Map.new(&{&1.source_id, &1.id})

    Enum.flat_map(pending, fn entry ->
      case Map.get(bus_ids, endpoint_bus_source_id(entry)) do
        nil -> []
        far_id -> [endpoint_update(entry.line_id, entry.side, entry.near_bus_id, far_id)]
      end
    end)
  end

  defp endpoint_bus_source_id(%{line_id: line_id, side: side}), do: "line_#{line_id}_#{side}"

  # Name first, then the geometric tiers. Returns {bus_id_or_nil, stats}.
  defp resolve_endpoint(_context, _name, nil, _voltage_kv, stats),
    do: {nil, bump(stats, :no_endpoint_geometry)}

  defp resolve_endpoint(context, name, {_lon, _lat} = pt, voltage_kv, stats) do
    case EndpointMatcher.resolve(
           context.name_index,
           name,
           pt,
           EndpointMatcher.name_match_radius_km()
         ) do
      {:ok, sub_id, _distance} ->
        case bus_at_substation(context.buses, sub_id, voltage_kv) do
          nil -> snap(context, pt, voltage_kv, bump(stats, :name_matched_no_level))
          bus_id -> {bus_id, bump(stats, :name_matched)}
        end

      {:too_far, _sub_id, _distance} ->
        snap(context, pt, voltage_kv, bump(stats, :name_too_far))

      :no_match ->
        snap(context, pt, voltage_kv, bump(stats, :name_not_in_layer))

      :no_name ->
        snap(context, pt, voltage_kv, bump(stats, :name_sentinel))
    end
  end

  # Tier 1 then tier 2, both voltage-filtered.
  defp snap(context, {lon, lat}, voltage_kv, stats) do
    case nearest_in_grid(context.grid, lon, lat, @snap_tier_1_km, voltage_kv) do
      {bus_id, _} ->
        {bus_id, bump(stats, :snapped_tier_1)}

      nil ->
        case nearest_in_grid(context.grid, lon, lat, @snap_tier_2_km, voltage_kv) do
          {bus_id, _} -> {bus_id, bump(stats, :snapped_tier_2)}
          nil -> {nil, bump(stats, :unresolved)}
        end
    end
  end

  # The bus at `sub_id` whose level is closest to the line voltage, provided it
  # is within tolerance: a name match says WHICH yard, never that a 500 kV
  # circuit terminates on its 13.8 kV bus.
  defp bus_at_substation(buses, sub_id, voltage_kv) do
    buses.by_substation
    |> Map.get(sub_id, [])
    |> Enum.filter(fn {_id, base_kv, _lon, _lat} ->
      abs(base_kv - voltage_kv) <= voltage_kv * @level_tolerance
    end)
    |> case do
      [] ->
        nil

      candidates ->
        candidates |> Enum.min_by(fn {_id, kv, _, _} -> abs(kv - voltage_kv) end) |> elem(0)
    end
  end

  defp point(lon, lat) when is_number(lon) and is_number(lat), do: {lon, lat}
  defp point(_, _), do: nil

  defp bump(stats, key), do: Map.update(stats, key, 1, &(&1 + 1))

  defp report_endpoint_stats(stats, endpoints) do
    share = fn n -> if endpoints > 0, do: Float.round(100.0 * n / endpoints, 1), else: 0.0 end

    named = Map.get(stats, :name_matched, 0)
    tier1 = Map.get(stats, :snapped_tier_1, 0)
    tier2 = Map.get(stats, :snapped_tier_2, 0)
    unresolved = Map.get(stats, :unresolved, 0)

    IO.puts("""
      Endpoints: #{endpoints}
        by SUB_1/SUB_2 name:      #{named} (#{share.(named)}%)
        snapped <= #{@snap_tier_1_km} km:        #{tier1} (#{share.(tier1)}%)
        snapped <= #{@snap_tier_2_km} km:       #{tier2} (#{share.(tier2)}%)
        unresolved (-> cleanup):  #{unresolved} (#{share.(unresolved)}%)
        name fell through: sentinel #{Map.get(stats, :name_sentinel, 0)}, \
    not in layer #{Map.get(stats, :name_not_in_layer, 0)}, \
    beyond #{trunc(EndpointMatcher.name_match_radius_km())} km #{Map.get(stats, :name_too_far, 0)}, \
    no matching level #{Map.get(stats, :name_matched_no_level, 0)}
        one-bus circuits: split #{Map.get(stats, :same_bus_split, 0)}, \
    far bus created #{Map.get(stats, :same_bus_synthetic, 0)}, \
    intra-yard stubs skipped #{Map.get(stats, :self_loop_skipped, 0)}\
    """)
  end

  # One UPDATE ... FROM unnest() per chunk instead of one round trip per line.
  # NULLs in the arrays leave the existing value alone, so an endpoint this
  # pass could not resolve is never cleared.
  defp apply_line_bus_updates([]), do: :ok

  defp apply_line_bus_updates(updates) do
    updates
    |> Enum.chunk_every(2000)
    |> Enum.each(fn chunk ->
      ids = Enum.map(chunk, &elem(&1, 0))
      froms = Enum.map(chunk, &elem(&1, 1))
      tos = Enum.map(chunk, &elem(&1, 2))

      Repo.query!(
        """
        UPDATE transmission_lines tl
        SET from_bus_id = COALESCE(v.from_bus_id, tl.from_bus_id),
            to_bus_id = COALESCE(v.to_bus_id, tl.to_bus_id),
            updated_at = NOW()
        FROM (
          SELECT unnest($1::bigint[]) AS id,
                 unnest($2::bigint[]) AS from_bus_id,
                 unnest($3::bigint[]) AS to_bus_id
        ) v
        WHERE tl.id = v.id
        """,
        [ids, froms, tos]
      )
    end)
  end

  # Every bus with coordinates, as {id, base_kv, lon, lat}, plus the grouping
  # by owning substation the name path needs and a by-id lookup for the
  # endpoint split (TOPO-5).
  defp load_bus_index do
    rows =
      from(b in Bus,
        where: not is_nil(b.coordinates),
        select: %{
          id: b.id,
          base_kv: b.base_kv,
          source: b.source,
          source_id: b.source_id,
          interconnection_id: b.interconnection_id,
          lon: fragment("ST_X(?::geometry)", b.coordinates),
          lat: fragment("ST_Y(?::geometry)", b.coordinates)
        }
      )
      |> Repo.all()

    by_substation =
      rows
      |> Enum.filter(&(&1.source == "substation"))
      |> Enum.group_by(
        &substation_id_from_source_id(&1.source_id),
        &{&1.id, &1.base_kv, &1.lon, &1.lat}
      )
      |> Map.delete(nil)

    %{
      all: Enum.map(rows, &{&1.id, &1.base_kv, &1.lon, &1.lat}),
      by_id: Map.new(rows, &{&1.id, {&1.base_kv, &1.lon, &1.lat, &1.interconnection_id}}),
      by_substation: by_substation
    }
  end

  # A bus already in the index. Unknown ids cannot occur — the caller only
  # passes ids the index itself produced — but a nil-safe shape keeps a
  # partially-mapped line (an endpoint filled by an earlier run against a bus
  # that has since lost its coordinates) from crashing the pass.
  defp bus_row(buses, bus_id), do: Map.get(buses.by_id, bus_id, {nil, 0.0, 0.0, nil})

  # Grid hash over {id, base_kv, lon, lat} tuples, keyed by #{@grid_cell_deg}-degree cell.
  defp build_grid(items) do
    Enum.group_by(items, fn {_id, _kv, lon, lat} -> cell(lon, lat) end)
  end

  defp cell(lon, lat), do: {floor(lon / @grid_cell_deg), floor(lat / @grid_cell_deg)}

  # The member lists of every cell a circle of radius_km around (lon, lat) can
  # touch. Shared by the three searches over the grid so the span arithmetic
  # exists once.
  defp grid_cells(grid, lon, lat, radius_km) do
    lat_span = ceil(radius_km / (111.32 * @grid_cell_deg))
    lon_km_per_deg = max(111.32 * :math.cos(lat * :math.pi() / 180.0), 1.0e-6)
    lon_span = ceil(radius_km / (lon_km_per_deg * @grid_cell_deg))
    {cx, cy} = cell(lon, lat)

    for dx <- -lon_span..lon_span, dy <- -lat_span..lat_span do
      Map.get(grid, {cx + dx, cy + dy}, [])
    end
  end

  # Nearest grid member within radius_km whose level is within tolerance of
  # voltage_kv (nil voltage_kv means any level). Ties break on the closer
  # level, then id, so the result never depends on map ordering. `exclude` is
  # a bus the caller has already claimed (TOPO-5's far endpoint).
  defp nearest_in_grid(grid, lon, lat, radius_km, voltage_kv, exclude \\ nil) do
    grid
    |> grid_cells(lon, lat, radius_km)
    |> Enum.reduce(nil, fn members, best ->
      Enum.reduce(members, best, fn {id, base_kv, blon, blat}, acc ->
        if id != exclude and level_matches?(base_kv, voltage_kv) do
          distance = EndpointMatcher.haversine_km(lat, lon, blat, blon)

          # Every level of a substation shares one coordinate, so distance
          # alone cannot separate them: rank the closest voltage match
          # first (LIN-5), then the lowest level, then the id, so the
          # result never depends on map ordering.
          key =
            {distance, if(voltage_kv, do: abs(base_kv - voltage_kv), else: 0.0), base_kv, id}

          cond do
            distance > radius_km -> acc
            acc == nil -> {id, key}
            key < elem(acc, 1) -> {id, key}
            true -> acc
          end
        else
          acc
        end
      end)
    end)
  end

  defp level_matches?(_base_kv, nil), do: true

  defp level_matches?(base_kv, voltage_kv),
    do: abs(base_kv - voltage_kv) <= voltage_kv * @level_tolerance

  @doc """
  Chain transformers across ADJACENT voltage levels at each substation.
  Returns the number inserted.

  A 500/345/138 yard gets 500-345 and 345-138 — never 500-138. Welding
  non-adjacent levels is what produced the >5:1 ratio banks and handed EHV
  flow a fictitious one-hop path down to distribution voltage, and it was
  unavoidable while only the extreme levels had buses (LIN-5).
  """
  def create_substation_transformers do
    through = through_load_by_bus()

    substation_buses()
    |> Enum.flat_map(fn {_sub_id, buses} -> adjacent_bus_pairs(buses) end)
    |> Enum.reduce(0, fn {high, low}, inserted ->
      case Repo.insert(
             Transformer.changeset(%Transformer{}, transformer_attrs(high, low, through)),
             # LIN-4/DAT-1: real conflict target so map_buses re-runs cannot
             # duplicate a bank between the same two buses, in either terminal
             # order (unordered-pair unique index).
             on_conflict: :nothing,
             conflict_target: @transformer_pair_conflict
           ) do
        {:ok, %Transformer{id: id}} when not is_nil(id) -> inserted + 1
        _ -> inserted
      end
    end)
  end

  @doc """
  Re-rate substation banks whose low side carries more load than the bank can
  pass (TOPO-6). Returns `%{resized: n, added_mva: mva}`.

  `create_substation_transformers/0` runs during `map_buses`, long before
  `LoadEstimator` exists to say what the low side will carry, so the sizing
  rule has to be re-applied once the loads are there — which is why
  `Cleanup.run/0` calls this. Only banks joining two SUBSTATION buses are
  touched; MATPOWER banks carry real nameplates.

  A real distribution substation serving 400 MW has several banks, and the
  unordered-pair unique index means the model cannot hold two rows between one
  pair of buses. One row with `rated_mva = n x` the class's standard unit IS
  the n-parallel-bank model: the LIN-3 rebase gives it `x_pu = 0.1 x 100/(n x
  unit)`, exactly the reactance of n standard banks in parallel.

  The rating is SET, not raised: a bank whose low-side load has since moved
  away falls back to its class's standard unit. That matters because sizing a
  bank to its load and capping load at a fraction of the bank's rating (the
  load-side half of TOPO-6) are circular — a bank inflated for load that a
  later reallocation moves elsewhere would keep the cap from ever biting
  again.
  """
  def resize_transformers_to_through_load do
    through = through_load_by_bus()

    from(t in Transformer,
      join: fb in Bus,
      on: t.from_bus_id == fb.id,
      join: tb in Bus,
      on: t.to_bus_id == tb.id,
      where:
        t.status == "in_service" and fb.source == "substation" and tb.source == "substation" and
          t.from_bus_id != t.to_bus_id,
      preload: [:from_bus, :to_bus]
    )
    |> Repo.all()
    |> Enum.reduce(%{resized: 0, added_mva: 0.0}, fn xfmr, acc ->
      attrs = transformer_attrs(xfmr.from_bus, xfmr.to_bus, through)
      current = xfmr.rated_mva || 0.0

      if abs(attrs.rated_mva - current) > 1.0e-6 do
        xfmr
        |> Ecto.Changeset.change(Map.take(attrs, [:rated_mva, :r_pu, :x_pu]))
        |> Repo.update!()

        %{acc | resized: acc.resized + 1, added_mva: acc.added_mva + attrs.rated_mva - current}
      else
        acc
      end
    end)
  end

  # Load a bank has to pass, per bus: that bus's own load plus the load on
  # every level BELOW it at the same yard, which reaches it through the chain
  # this module builds. Deliberately local — a full downstream traversal would
  # also count load the bus reaches over its LINES, which those lines feed and
  # this bank does not.
  #
  # Returned alongside is the set of buses that carry no line at all. Those can
  # only be fed through a transformer, so their load counts against the bank
  # whichever TERMINAL they are: 450 MW sits on the 138 kV side of a 138/100
  # bank at UNKNOWN120325 with no other branch, and sizing on the low side
  # alone would leave that bank at its 200 MVA class default.
  defp through_load_by_bus do
    load_by_bus =
      from(l in Load, group_by: l.bus_id, select: {l.bus_id, sum(l.p_mw)})
      |> Repo.all()
      |> Map.new(fn {bus_id, mw} -> {bus_id, (mw || 0.0) * 1.0} end)

    if map_size(load_by_bus) == 0 do
      %{cumulative: %{}, line_fed: MapSet.new()}
    else
      cumulative =
        substation_buses()
        |> Enum.flat_map(fn {_sub_id, buses} ->
          # buses are sorted by descending base_kv, so the running sum from the
          # bottom up is "this level plus everything under it".
          buses
          |> Enum.reverse()
          |> Enum.map_reduce(0.0, fn bus, below ->
            total = below + Map.get(load_by_bus, bus.id, 0.0)
            {{bus.id, total}, total}
          end)
          |> elem(0)
        end)
        |> Map.new()

      %{cumulative: cumulative, line_fed: buses_with_lines()}
    end
  end

  defp buses_with_lines do
    from(l in TransmissionLine,
      where: l.status == "in_service" and not is_nil(l.from_bus_id) and not is_nil(l.to_bus_id),
      select: {l.from_bus_id, l.to_bus_id}
    )
    |> Repo.all()
    |> Enum.reduce(MapSet.new(), fn {a, b}, acc -> acc |> MapSet.put(a) |> MapSet.put(b) end)
  end

  @doc """
  Bring transformers stamped below `params_version/0` up to the current recipe.

  Two corrections, both of which the fill-only path could never make:

    * parameters are recomputed from the pair's GENUINE high side and the row
      is reoriented high side first, repairing banks rated off their low
      terminal because an earlier writer trusted row order;
    * a bank spanning non-adjacent levels at a substation that now has the
      level in between is taken out of service — `create_substation_transformers/0`
      has already built the chain that replaces it, so the connection survives
      at the right ratio instead of as a weld.

  Only rows whose substation topology actually changed are retired, and only
  stale rows are rewritten, so a correct mapping is never churned. Both passes
  are scoped to banks joining two SUBSTATION buses: MATPOWER-imported
  transformers carry per-unit impedances from their case file and are outside
  this module's authority.
  """
  def remap_stale_transformers do
    retired = retire_non_adjacent_transformers()
    recomputed = recompute_stale_transformer_params()
    %{recomputed: recomputed, retired: retired}
  end

  defp retire_non_adjacent_transformers do
    wanted =
      substation_buses()
      |> Enum.flat_map(fn {_sub_id, buses} -> adjacent_bus_pairs(buses) end)
      |> MapSet.new(fn {high, low} -> bus_pair_key(high.id, low.id) end)

    # Only intra-substation banks are ours to judge: a pair whose terminals sit
    # at different substations is a tie, not a level chain.
    stale =
      from(t in Transformer,
        join: fb in Bus,
        on: t.from_bus_id == fb.id,
        join: tb in Bus,
        on: t.to_bus_id == tb.id,
        where:
          t.params_version < @params_version and t.status == "in_service" and
            fb.source == "substation" and tb.source == "substation",
        select: {t, fb.source_id, tb.source_id}
      )
      |> Repo.all()

    ids =
      for {t, from_sid, to_sid} <- stale,
          sub_id = substation_id_from_source_id(from_sid),
          not is_nil(sub_id),
          sub_id == substation_id_from_source_id(to_sid),
          not MapSet.member?(wanted, bus_pair_key(t.from_bus_id, t.to_bus_id)),
          do: t.id

    case ids do
      [] ->
        0

      ids ->
        {n, _} =
          from(t in Transformer, where: t.id in ^ids)
          |> Repo.update_all(
            set: [
              status: "out_of_service",
              params_version: @params_version,
              updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
            ]
          )

        n
    end
  end

  defp recompute_stale_transformer_params do
    # Scoped to banks BOTH of whose terminals are substation buses — the ones
    # this module creates. MATPOWER-imported transformers carry real per-unit
    # impedances from their case file and are not ours to overwrite with the
    # generic 10%/0.3% recipe.
    from(t in Transformer,
      join: fb in Bus,
      on: t.from_bus_id == fb.id,
      join: tb in Bus,
      on: t.to_bus_id == tb.id,
      where:
        t.params_version < @params_version and fb.source == "substation" and
          tb.source == "substation",
      preload: [:from_bus, :to_bus]
    )
    |> Repo.all()
    |> Enum.reduce(0, fn xfmr, updated ->
      case {xfmr.from_bus, xfmr.to_bus} do
        {%Bus{} = a, %Bus{} = b} when a.id != b.id ->
          xfmr
          |> Ecto.Changeset.change(transformer_attrs(a, b))
          |> Repo.update!()

          updated + 1

        _ ->
          # Self-loop: no high side to rate it from. Stamp it so the pass does
          # not reconsider it every run.
          xfmr
          |> Ecto.Changeset.change(%{params_version: @params_version})
          |> Repo.update!()

          updated
      end
    end)
  end

  @doc """
  Transformer attributes for a pair of buses given in either terminal order.

  The high side is `max(base_kv)` of the pair, never "whichever argument came
  first": reading the rating off the listed from-terminal is what rated banks
  off their low side and put a 138 kV rating on a 500/138 autotransformer.
  `from_bus_id` is always the high side, so tap ratio, export positioning, and
  re-runs all mean the same thing.

  LIN-3: a typical bank has ~10% reactance / 0.3% resistance on its OWN MVA
  base. Stored impedances are on the 100 MVA system base, so rebase by
  100/rated_mva — otherwise a 1000 MVA bank is 10x too impedant and sits at its
  steady-state stability limit at nameplate.

  TOPO-6: the optional `through` map (`%{bus_id => MW the low side must pass}`)
  raises the rating to whole multiples of the class's standard unit until the
  load sits at or below #{@bank_load_headroom} of it. See
  `resize_transformers_to_through_load/0` for why one row stands in for n
  parallel banks.
  """
  def transformer_attrs(bus_a, bus_b, through \\ %{cumulative: %{}, line_fed: nil})

  def transformer_attrs(%Bus{} = bus_a, %Bus{} = bus_b, through) do
    {high, low} = order_by_voltage(bus_a, bus_b)
    unit_mva = estimate_transformer_rating(high.base_kv)
    rated_mva = bank_rating(unit_mva, through_load(through, high, low))

    %{
      from_bus_id: high.id,
      to_bus_id: low.id,
      rated_mva: rated_mva,
      r_pu: 0.003 * (100.0 / rated_mva),
      x_pu: 0.1 * (100.0 / rated_mva),
      tap_ratio: 1.0,
      params_version: @params_version
    }
  end

  # The low side's cumulative load always counts; the high side's counts too
  # when the high bus has no line of its own, because then the bank is the only
  # way that load can be served.
  defp through_load(%{cumulative: cumulative} = through, high, low) do
    line_fed = Map.get(through, :line_fed)

    high_side =
      if is_nil(line_fed) or MapSet.member?(line_fed, high.id),
        do: 0.0,
        else: Map.get(cumulative, high.id, 0.0)

    max(Map.get(cumulative, low.id, 0.0), high_side)
  end

  # Whole multiples of the class's standard bank, never a fractional custom
  # unit: utilities add banks, they do not order a 317 MVA transformer.
  defp bank_rating(unit_mva, through_mw) when through_mw > 0.0 do
    needed = through_mw / @bank_load_headroom
    banks = max(1, ceil(needed / unit_mva))
    banks * unit_mva
  end

  defp bank_rating(unit_mva, _through_mw), do: unit_mva

  defp order_by_voltage(%Bus{} = a, %Bus{} = b) do
    cond do
      a.base_kv > b.base_kv -> {a, b}
      b.base_kv > a.base_kv -> {b, a}
      # Equal base kV (a bus tie, or two levels that collapsed to one): pick a
      # stable order so re-runs never flip the row's terminals.
      a.id <= b.id -> {a, b}
      true -> {b, a}
    end
  end

  # Substation buses grouped by owning substation, each group sorted by
  # descending base_kv.
  defp substation_buses do
    from(b in Bus, where: b.source == "substation")
    |> Repo.all()
    |> Enum.group_by(&substation_id_from_source_id(&1.source_id))
    |> Map.delete(nil)
    |> Map.new(fn {sub_id, buses} ->
      {sub_id, Enum.sort_by(buses, &{-&1.base_kv, &1.id})}
    end)
  end

  # Adjacent pairs down the level chain: [500, 345, 138] -> {500,345}, {345,138}.
  defp adjacent_bus_pairs(buses) do
    buses
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [high, low] -> {high, low} end)
  end

  defp bus_pair_key(a, b), do: {min(a, b), max(a, b)}

  @doc """
  Join network components that the endpoint mapping left apart even though
  they are the same electrical point (ROADMAP item 12, the post-mapping pass).

  HIFLD records one physical yard as several rows — a `SUBSTATION` and the
  `TAP`s and `RISER`s around it, or the same name surveyed twice — and splits
  the circuits between them. The result is a network of tens of thousands of
  tiny islands whose boundary buses sit on top of each other. Two rules, both
  requiring the SAME voltage level and the SAME interconnection, and neither
  ever crossing an asynchronous seam:

    * **Shared name** — buses at substations with the same identifying name
      (`HIFLD.Names`, so no "DEAD HEAD" fusion) within
      #{@repair_name_radius_km} km of each other. The radius is what stops
      LIN-1's MIDWAY, which names 15 yards over 4,258 km, from welding the
      country into one component.
    * **Proximity** — buses within #{@repair_proximity_km} km regardless of
      name.

  A joint is a `connectivity_repair` line of the real (very short) distance
  with normal parameters for its voltage class, not a zero-impedance weld.
  Candidates are considered nearest-first and only when the two buses are
  genuinely in different components, so the pass adds the minimum number of
  branches that merges them and is idempotent on a second run.

  ## The weld phase (TOPO-4)

  Both rules above discard any pair whose union-find roots already match, so
  they structurally cannot touch a split yard whose halves ARE reachable from
  each other — the long way round, through the wider network. Those 3,604
  co-located same-level pairs are the same defect with a false detour instead
  of an island, and they inflate every path length and bridge count between
  them.

  A third phase therefore runs LAST, after both joining rules, over pairs
  within #{@weld_radius_km} km at the same level and interconnection that
  carry no direct branch between them, whether or not they are already in one
  component. The radius is an order of magnitude tighter than the proximity
  rule because that guarantee is weaker: at 250 m the claim "these are two
  records of one yard" holds without fusing two genuinely adjacent urban
  yards. Every such pair is welded rather than a spanning tree over each
  cluster — a tree is electrically sufficient, but the census the phase is
  measured on counts PAIRS, and a 5-bus cluster spanned by 4 ties still
  reports 6 unwelded pairs it does not have.

  Returns `%{joined_name: n, joined_proximity: n, welded: n,
  components_before: n, components_after: n}`.
  """
  def repair_connectivity(opts \\ []) do
    name_radius_km = Keyword.get(opts, :name_radius_km, @repair_name_radius_km)
    proximity_km = Keyword.get(opts, :proximity_km, @repair_proximity_km)
    weld_km = Keyword.get(opts, :weld_km, @weld_radius_km)

    buses = repair_bus_rows()
    uf = components(buses)
    before = count_roots(uf, buses)

    IO.puts("Connectivity repair: #{length(buses)} buses in #{before} components")

    {uf, name_joints} = join_by_shared_name(buses, uf, name_radius_km)
    {uf, proximity_joints} = join_by_proximity(buses, uf, proximity_km)

    joined = name_joints ++ proximity_joints
    {uf, weld_joints} = weld_colocated(buses, uf, weld_km, joined)

    joints = joined ++ weld_joints
    insert_repair_lines(joints)

    after_count = count_roots(uf, buses)

    IO.puts("  Welds: #{length(weld_joints)} co-located pairs (<= #{weld_km} km, same level)")

    IO.puts(
      "  Joints: #{length(name_joints)} by shared name, #{length(proximity_joints)} by proximity " <>
        "(<= #{proximity_km} km, same level, same interconnection)"
    )

    IO.puts("  Components: #{before} -> #{after_count}")

    %{
      joined_name: length(name_joints),
      joined_proximity: length(proximity_joints),
      welded: length(weld_joints),
      components_before: before,
      components_after: after_count
    }
  end

  defp repair_bus_rows do
    substation_names =
      from(s in Substation, select: {s.id, s.name})
      |> Repo.all()
      |> Map.new()

    from(b in Bus,
      where: not is_nil(b.coordinates) and not is_nil(b.base_kv),
      select: %{
        id: b.id,
        base_kv: b.base_kv,
        source: b.source,
        source_id: b.source_id,
        interconnection_id: b.interconnection_id,
        lon: fragment("ST_X(?::geometry)", b.coordinates),
        lat: fragment("ST_Y(?::geometry)", b.coordinates)
      }
    )
    |> Repo.all()
    |> Enum.map(fn bus ->
      name =
        with "substation" <- bus.source,
             sub_id when not is_nil(sub_id) <- substation_id_from_source_id(bus.source_id),
             raw when not is_nil(raw) <- Map.get(substation_names, sub_id),
             normalized when not is_nil(normalized) <- Names.normalize(raw) do
          if Names.identifying?(normalized), do: normalized
        else
          _ -> nil
        end

      Map.put(bus, :substation_name, name)
    end)
  end

  # Union-find over in-service AC branches. DC lines are excluded because the
  # AC snapshot queries exclude them (LIN-6): a component reachable only over
  # an HVDC tie is still a separate island everywhere it matters.
  defp components(buses) do
    uf = uf_new(Enum.map(buses, & &1.id))

    line_pairs =
      from(l in TransmissionLine,
        where:
          not is_nil(l.from_bus_id) and not is_nil(l.to_bus_id) and l.status == "in_service" and
            (is_nil(l.line_type) or l.line_type != "dc"),
        select: {l.from_bus_id, l.to_bus_id}
      )
      |> Repo.all()

    transformer_pairs =
      from(t in Transformer,
        where: not is_nil(t.from_bus_id) and not is_nil(t.to_bus_id) and t.status == "in_service",
        select: {t.from_bus_id, t.to_bus_id}
      )
      |> Repo.all()

    Enum.reduce(line_pairs ++ transformer_pairs, uf, fn {a, b}, acc ->
      if uf_member?(acc, a) and uf_member?(acc, b), do: uf_union(acc, a, b), else: acc
    end)
  end

  defp count_roots(uf, buses) do
    buses |> Enum.map(&uf_find(uf, &1.id)) |> Enum.uniq() |> length()
  end

  # Union-find with union-by-size. Without it, unioning a long chain of buses
  # (which a transmission corridor is) grows the find path linearly and the
  # component pass goes quadratic at national scale; by size the depth stays
  # under log2(n) ~ 17.
  defp uf_new(ids), do: {Map.new(ids, &{&1, &1}), %{}}

  defp uf_member?({parents, _sizes}, id), do: Map.has_key?(parents, id)

  defp uf_find({parents, _sizes} = uf, id) do
    case Map.fetch!(parents, id) do
      ^id -> id
      parent -> uf_find(uf, parent)
    end
  end

  defp uf_union({parents, sizes} = uf, a, b) do
    root_a = uf_find(uf, a)
    root_b = uf_find(uf, b)

    if root_a == root_b do
      uf
    else
      size_a = Map.get(sizes, root_a, 1)
      size_b = Map.get(sizes, root_b, 1)
      {child, root} = if size_a < size_b, do: {root_a, root_b}, else: {root_b, root_a}

      {Map.put(parents, child, root), Map.put(sizes, root, size_a + size_b)}
    end
  end

  defp join_by_shared_name(buses, uf, radius_km) do
    buses
    |> Enum.filter(& &1.substation_name)
    |> Enum.group_by(&{&1.substation_name, level_key(&1.base_kv)})
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> Enum.sort_by(fn {key, _group} -> key end)
    |> Enum.flat_map(fn {_key, group} -> candidate_pairs(group, radius_km) end)
    |> apply_joints(uf, :name)
  end

  defp join_by_proximity(buses, uf, radius_km) do
    grid = build_grid(Enum.map(buses, &{&1.id, &1.base_kv, &1.lon, &1.lat}))
    by_id = Map.new(buses, &{&1.id, &1})

    buses
    |> Enum.sort_by(& &1.id)
    |> Enum.flat_map(fn bus ->
      grid
      |> neighbours_within(bus.lon, bus.lat, radius_km)
      # Each unordered pair is generated once, from its lower-id member.
      |> Enum.filter(fn {id, base_kv, _lon, _lat} ->
        id > bus.id and level_key(base_kv) == level_key(bus.base_kv)
      end)
      |> Enum.flat_map(fn {id, _kv, _lon, _lat} ->
        candidate_pair(bus, Map.fetch!(by_id, id), radius_km)
      end)
    end)
    |> apply_joints(uf, :proximity)
  end

  # TOPO-4. Same shape as join_by_proximity, with two differences that are the
  # whole point: a pair already in one component is kept, and a pair that
  # already carries a direct branch is dropped (the joining rules get that
  # second guarantee for free, since a branch would have merged the
  # components).
  defp weld_colocated(buses, uf, radius_km, joined) do
    existing =
      joined
      |> MapSet.new(fn {a, b, _distance, _rule} -> bus_pair_key(a.id, b.id) end)
      |> MapSet.union(direct_branch_pairs())

    grid = build_grid(Enum.map(buses, &{&1.id, &1.base_kv, &1.lon, &1.lat}))
    by_id = Map.new(buses, &{&1.id, &1})

    buses
    |> Enum.sort_by(& &1.id)
    |> Enum.flat_map(fn bus ->
      grid
      |> neighbours_within(bus.lon, bus.lat, radius_km)
      # Each unordered pair is generated once, from its lower-id member.
      |> Enum.filter(fn {id, base_kv, _lon, _lat} ->
        id > bus.id and level_key(base_kv) == level_key(bus.base_kv) and
          not MapSet.member?(existing, bus_pair_key(bus.id, id))
      end)
      |> Enum.flat_map(fn {id, _kv, _lon, _lat} ->
        candidate_pair(bus, Map.fetch!(by_id, id), radius_km)
      end)
    end)
    |> Enum.sort_by(fn {distance, a, b} -> {distance, a.id, b.id} end)
    |> Enum.reduce({uf, []}, fn {distance, a, b}, {acc_uf, acc_joints} ->
      {uf_union(acc_uf, a.id, b.id), [{a, b, distance, :weld} | acc_joints]}
    end)
  end

  # Unordered bus pairs that already carry an in-service branch, in either
  # terminal order. DC lines count here even though `components/1` excludes
  # them: a weld's job is to remove a duplicate record, and two buses joined by
  # an HVDC tie are not duplicates.
  defp direct_branch_pairs do
    lines =
      from(l in TransmissionLine,
        where: not is_nil(l.from_bus_id) and not is_nil(l.to_bus_id) and l.status == "in_service",
        select: {l.from_bus_id, l.to_bus_id}
      )
      |> Repo.all()

    transformers =
      from(t in Transformer,
        where: not is_nil(t.from_bus_id) and not is_nil(t.to_bus_id) and t.status == "in_service",
        select: {t.from_bus_id, t.to_bus_id}
      )
      |> Repo.all()

    MapSet.new(lines ++ transformers, fn {a, b} -> bus_pair_key(a, b) end)
  end

  # Every in-radius, same-interconnection pair in a group, unordered.
  defp candidate_pairs(group, radius_km) do
    for a <- group, b <- group, a.id < b.id, pair <- candidate_pair(a, b, radius_km), do: pair
  end

  defp candidate_pair(a, b, radius_km) do
    # A joint must never bridge two asynchronous systems, and a bus with no
    # interconnection at all (an unmapped synthetic) cannot prove it does not.
    if is_nil(a.interconnection_id) or a.interconnection_id != b.interconnection_id do
      []
    else
      distance = EndpointMatcher.haversine_km(a.lat, a.lon, b.lat, b.lon)
      if distance <= radius_km, do: [{distance, a, b}], else: []
    end
  end

  # Nearest first, skipping pairs already in one component, so the pass adds
  # the fewest branches that merges them.
  defp apply_joints(pairs, uf, rule) do
    pairs
    |> Enum.sort_by(fn {distance, a, b} -> {distance, a.id, b.id} end)
    |> Enum.reduce({uf, []}, fn {distance, a, b}, {acc_uf, acc_joints} ->
      if uf_find(acc_uf, a.id) == uf_find(acc_uf, b.id) do
        {acc_uf, acc_joints}
      else
        {uf_union(acc_uf, a.id, b.id), [{a, b, distance, rule} | acc_joints]}
      end
    end)
  end

  defp neighbours_within(grid, lon, lat, radius_km) do
    for members <- grid_cells(grid, lon, lat, radius_km),
        member <- members,
        EndpointMatcher.haversine_km(lat, lon, elem(member, 3), elem(member, 2)) <= radius_km,
        do: member
  end

  # Levels within 5% are the same level (115 kV and 120 kV records of one
  # yard), matching Substations.cluster_voltage_levels/1.
  defp level_key(base_kv), do: round(base_kv / 5.0)

  defp insert_repair_lines([]), do: :ok

  defp insert_repair_lines(joints) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      Enum.map(joints, fn {a, b, distance_km, rule} ->
        {low, high} = {min(a.id, b.id), max(a.id, b.id)}
        voltage_kv = max(a.base_kv, b.base_kv)
        length_km = max(distance_km, 0.1)
        {r_pu, x_pu, rating} = repair_line_params(voltage_kv, length_km)

        %{
          from_bus_id: a.id,
          to_bus_id: b.id,
          voltage_kv: voltage_kv,
          r_pu: r_pu,
          x_pu: x_pu,
          b_pu: 0.0,
          rating_a_mva: rating,
          length_km: length_km,
          source: "connectivity_repair",
          source_id: "repair_#{rule}_#{low}_#{high}",
          status: "in_service",
          inserted_at: now,
          updated_at: now
        }
      end)

    # Log a bounded sample rather than every joint: a burst this size is
    # silently truncated by the logger (REVIEW DAT-20), and the counts in the
    # returned summary are the authoritative record.
    entries
    |> Enum.take(25)
    |> Enum.each(fn entry ->
      Logger.info(
        "Connectivity repair: joined bus #{entry.from_bus_id} to #{entry.to_bus_id} " <>
          "at #{entry.voltage_kv} kV over #{entry.length_km} km (#{entry.source_id})"
      )
    end)

    entries
    |> Enum.chunk_every(1000)
    |> Enum.each(
      &Repo.insert_all(TransmissionLine, &1,
        on_conflict: :nothing,
        conflict_target: [:source, :source_id]
      )
    )
  end

  # Impedance and rating for a joint, by voltage class.
  #
  # The rating is deliberately NOT an ampacity (DR-2 raised the flat 100 MVA
  # below 69 kV, which now covers 1,165 sub-50 kV joints). A joint asserts that
  # two records are one electrical point: it stands in for a busbar, not for a
  # conductor, and a busbar is not where a yard's limit lives — the circuits
  # leaving it are. Rating a 13.8 kV joint at a 1,200 A ampacity (28.7 MVA)
  # would manufacture an overload the physical yard does not have, in exactly
  # the census the repair rounds are gated on. 100 MVA at 13.8 kV is 4.2 kA,
  # high for a conductor and unremarkable for a bus, which is the point: it is
  # a floor chosen so the joint never binds.
  defp repair_line_params(voltage_kv, length_km) do
    z_base = voltage_kv * voltage_kv / 100.0

    {r_per_km, x_per_km, rating} =
      cond do
        voltage_kv >= 500 -> {0.010, 0.300, 1800.0}
        voltage_kv >= 345 -> {0.020, 0.335, 900.0}
        voltage_kv >= 230 -> {0.040, 0.370, 450.0}
        voltage_kv >= 138 -> {0.075, 0.400, 250.0}
        voltage_kv >= 69 -> {0.170, 0.450, 130.0}
        true -> {0.200, 0.500, 100.0}
      end

    {Float.round(r_per_km * length_km / z_base, 8),
     max(Float.round(x_per_km * length_km / z_base, 8), 1.0e-5), rating}
  end

  defp interconnection_name(%Geo.Point{coordinates: {lon, lat}}),
    do: interconnection_from_box(lon, lat)

  defp interconnection_name(_), do: nil

  @doc """
  Coarse geographic interconnection guess from a coordinate. This is only a
  FALLBACK for buses that never receive a balancing-authority assignment;
  `reconcile_interconnections_from_ba/0` overrides it wherever a BA is known.

  The ERCOT box is deliberately conservative so it does not swallow
  Eastern-interconnection territory that sits inside the geographic footprint
  of Texas: deep East Texas (Entergy/MISO, lon > -94.0), the Texas Panhandle
  (SPP, lat > 35.0 west of -100.5), and El Paso (Western, lon < -104.0).
  """
  def interconnection_from_box(lon, lat) do
    cond do
      # El Paso and everything west of the Texas grid is Western.
      lon < -104.0 ->
        "Western"

      # ERCOT: the Texas grid, minus the Eastern/Western pockets noted above.
      lat >= 25.8 and lat <= 36.5 and lon >= -104.0 and lon <= -94.0 and
          not (lat > 35.0 and lon < -100.5) ->
        "ERCOT"

      # Everything else in CONUS is Eastern.
      true ->
        "Eastern"
    end
  end

  @doc """
  Map a balancing-authority code to its interconnection name: ERCO -> ERCOT,
  the WECC balancing authorities -> Western, every other BA -> Eastern (SPP,
  MISO, PJM, SERC, ...).
  """
  def interconnection_for_ba_code(code) do
    normalized = code |> to_string() |> String.trim() |> String.upcase()

    cond do
      normalized == "ERCO" -> "ERCOT"
      normalized in @wecc_ba_codes -> "Western"
      true -> "Eastern"
    end
  end

  @doc """
  Reassign each bus's interconnection from its balancing authority.

  Interconnection is first set from a coarse geographic box when the bus is
  created (before any BA is known). A bus's BA is a far more reliable signal of
  which asynchronous system the bus belongs to, so once BA assignment has run
  this pass overrides the box result for every bus that has a BA. Buses without
  a BA keep their box-derived interconnection.

  Returns the number of buses whose interconnection actually changed.
  """
  def reconcile_interconnections_from_ba do
    ic_ids = %{
      "ERCOT" => get_or_create_interconnection("ERCOT"),
      "Western" => get_or_create_interconnection("Western"),
      "Eastern" => get_or_create_interconnection("Eastern")
    }

    ba_ids_by_interconnection =
      from(ba in BalancingAuthority, select: {ba.id, ba.code})
      |> Repo.all()
      |> Enum.group_by(
        fn {_id, code} -> interconnection_for_ba_code(code) end,
        fn {id, _code} -> id end
      )

    Enum.reduce(ba_ids_by_interconnection, 0, fn {ic_name, ba_ids}, changed ->
      ic_id = Map.fetch!(ic_ids, ic_name)

      {n, _} =
        from(b in Bus,
          where:
            b.balancing_authority_id in ^ba_ids and
              fragment("? IS DISTINCT FROM ?", b.interconnection_id, ^ic_id)
        )
        |> Repo.update_all(set: [interconnection_id: ic_id])

      changed + n
    end)
  end

  defp get_or_create_interconnection(name) do
    alias PowerModel.Grid.Interconnection

    case Repo.get_by(Interconnection, name: name) do
      %{id: id} ->
        id

      nil ->
        {:ok, ic} =
          %Interconnection{}
          |> Interconnection.changeset(%{name: name})
          |> Repo.insert(on_conflict: :nothing, conflict_target: [:name])

        # on_conflict: :nothing may return nil id, so re-fetch
        case ic.id do
          nil -> Repo.get_by!(Interconnection, name: name).id
          id -> id
        end
    end
  end

  # One-decimal kv string for bus source_ids ("138.0", "138.4"). See LIN-10.
  defp format_kv(kv), do: :erlang.float_to_binary(kv * 1.0, decimals: 1)

  defp estimate_transformer_rating(high_kv) do
    cond do
      high_kv >= 500 -> 1000.0
      high_kv >= 345 -> 600.0
      high_kv >= 230 -> 400.0
      high_kv >= 138 -> 200.0
      true -> 100.0
    end
  end
end
