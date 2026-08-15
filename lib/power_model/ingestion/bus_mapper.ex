defmodule PowerModel.Ingestion.BusMapper do
  @moduledoc """
  Maps generators, transmission lines to buses via substations.

  Strategy:
  0. Merge terminating-line voltages into each substation's level list
     (`Substations.augment_voltage_levels_from_lines/0`) so a level a line
     actually terminates at always has a bus to land on
  1. One bus per substation per voltage level — EVERY level in
     `substations.voltage_levels`, not just the max and min (LIN-5)
  2. Map generators to nearest substation bus (10km radius)
  3. Map transmission line endpoints by HIFLD SUB_1/SUB_2 NAME first, with a
     tiered geometric snap as the fallback (see
     `map_transmission_line_buses/0`)
  4. Chain transformers across ADJACENT voltage levels at each substation

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
    TransmissionLine,
    Substation,
    Transformer
  }

  alias PowerModel.Ingestion.HIFLD.{EndpointMatcher, Names, Substations}

  @gen_match_radius_m 10_000

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
    map_generators_to_buses()
    map_transmission_line_buses()
    create_substation_transformers()
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
    map_generators_to_buses()
    map_transmission_line_buses()
    created = create_substation_transformers()
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
  Attach every unmapped generator to the nearest bus within
  #{div(@gen_match_radius_m, 1000)} km, or to a synthetic bus at the plant.

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
          coordinates: g.coordinates,
          lon: fragment("ST_X(?::geometry)", g.coordinates),
          lat: fragment("ST_Y(?::geometry)", g.coordinates)
        }
      )
      |> Repo.all()

    grid = build_grid(load_bus_index().all)
    radius_km = @gen_match_radius_m / 1000.0

    # Passing nil for the voltage matches at any level; the grid's tie-break
    # takes the LOWEST level of the yard, because a generator connects at the
    # bottom of it — its GSU is not modeled (LIN-8).
    {assignments, synthetic} =
      Enum.reduce(generators, {[], []}, fn gen, {assigned, unassigned} ->
        case nearest_in_grid(grid, gen.lon, gen.lat, radius_km, nil) do
          {bus_id, _key} -> {[{gen.id, bus_id} | assigned], unassigned}
          nil -> {assigned, [gen | unassigned]}
        end
      end)

    apply_generator_bus_updates(assignments)
    create_synthetic_generator_buses(synthetic)

    Logger.info(
      "BusMapper: #{length(assignments)} generators mapped to substation buses, " <>
        "#{length(synthetic)} on synthetic buses"
    )

    %{mapped: length(assignments), synthetic: length(synthetic)}
  end

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

    {updates, stats} =
      Enum.reduce(lines, {[], %{}}, fn line, {updates, stats} ->
        {from_bus, stats} =
          resolve_endpoint(
            context,
            line.sub_1,
            point(line.from_lon, line.from_lat),
            line.voltage_kv,
            stats
          )

        {to_bus, stats} =
          resolve_endpoint(
            context,
            line.sub_2,
            point(line.to_lon, line.to_lat),
            line.voltage_kv,
            stats
          )

        resolved_from = from_bus || line.from_bus_id
        resolved_to = to_bus || line.to_bus_id

        cond do
          not is_nil(resolved_from) and resolved_from == resolved_to ->
            # Both endpoints on one bus is electrically meaningless. Leave the
            # line unmapped so cleanup can retry with a wider radius.
            {updates, bump(stats, :self_loop_skipped)}

          is_nil(from_bus) and is_nil(to_bus) ->
            {updates, stats}

          true ->
            {[{line.id, from_bus, to_bus} | updates], stats}
        end
      end)

    apply_line_bus_updates(updates)
    report_endpoint_stats(stats, 2 * length(lines))

    Map.put(stats, :lines_updated, length(updates))
  end

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
        self-loops skipped:       #{Map.get(stats, :self_loop_skipped, 0)}\
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
  # by owning substation the name path needs.
  defp load_bus_index do
    all =
      from(b in Bus,
        where: not is_nil(b.coordinates),
        select: %{
          id: b.id,
          base_kv: b.base_kv,
          source: b.source,
          source_id: b.source_id,
          lon: fragment("ST_X(?::geometry)", b.coordinates),
          lat: fragment("ST_Y(?::geometry)", b.coordinates)
        }
      )
      |> Repo.all()
      |> Enum.map(fn b -> {b.id, b.base_kv, b.lon, b.lat, b.source, b.source_id} end)

    by_substation =
      all
      |> Enum.filter(fn {_id, _kv, _lon, _lat, source, _sid} -> source == "substation" end)
      |> Enum.group_by(
        fn {_id, _kv, _lon, _lat, _source, sid} -> substation_id_from_source_id(sid) end,
        fn {id, kv, lon, lat, _source, _sid} -> {id, kv, lon, lat} end
      )
      |> Map.delete(nil)

    %{
      all: Enum.map(all, fn {id, kv, lon, lat, _s, _sid} -> {id, kv, lon, lat} end),
      by_substation: by_substation
    }
  end

  # Grid hash over {id, base_kv, lon, lat} tuples, keyed by #{@grid_cell_deg}-degree cell.
  defp build_grid(items) do
    Enum.group_by(items, fn {_id, _kv, lon, lat} -> cell(lon, lat) end)
  end

  defp cell(lon, lat), do: {floor(lon / @grid_cell_deg), floor(lat / @grid_cell_deg)}

  # Nearest grid member within radius_km whose level is within tolerance of
  # voltage_kv (nil voltage_kv means any level). Ties break on the closer
  # level, then id, so the result never depends on map ordering.
  defp nearest_in_grid(grid, lon, lat, radius_km, voltage_kv) do
    lat_span = ceil(radius_km / (111.32 * @grid_cell_deg))

    lon_km_per_deg = max(111.32 * :math.cos(lat * :math.pi() / 180.0), 1.0e-6)
    lon_span = ceil(radius_km / (lon_km_per_deg * @grid_cell_deg))

    {cx, cy} = cell(lon, lat)

    for dx <- -lon_span..lon_span, dy <- -lat_span..lat_span, reduce: nil do
      best ->
        grid
        |> Map.get({cx + dx, cy + dy}, [])
        |> Enum.reduce(best, fn {id, base_kv, blon, blat}, acc ->
          if level_matches?(base_kv, voltage_kv) do
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
    end
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
    substation_buses()
    |> Enum.flat_map(fn {_sub_id, buses} -> adjacent_bus_pairs(buses) end)
    |> Enum.reduce(0, fn {high, low}, inserted ->
      case Repo.insert(
             Transformer.changeset(%Transformer{}, transformer_attrs(high, low)),
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
  """
  def transformer_attrs(%Bus{} = bus_a, %Bus{} = bus_b) do
    {high, low} = order_by_voltage(bus_a, bus_b)
    rated_mva = estimate_transformer_rating(high.base_kv)

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

  Returns `%{joined_name: n, joined_proximity: n, components_before: n,
  components_after: n}`.
  """
  def repair_connectivity(opts \\ []) do
    name_radius_km = Keyword.get(opts, :name_radius_km, @repair_name_radius_km)
    proximity_km = Keyword.get(opts, :proximity_km, @repair_proximity_km)

    buses = repair_bus_rows()
    uf = components(buses)
    before = count_roots(uf, buses)

    IO.puts("Connectivity repair: #{length(buses)} buses in #{before} components")

    {uf, name_joints} = join_by_shared_name(buses, uf, name_radius_km)
    {uf, proximity_joints} = join_by_proximity(buses, uf, proximity_km)

    joints = name_joints ++ proximity_joints
    insert_repair_lines(joints)

    after_count = count_roots(uf, buses)

    IO.puts(
      "  Joints: #{length(name_joints)} by shared name, #{length(proximity_joints)} by proximity " <>
        "(<= #{proximity_km} km, same level, same interconnection)"
    )

    IO.puts("  Components: #{before} -> #{after_count}")

    %{
      joined_name: length(name_joints),
      joined_proximity: length(proximity_joints),
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
    lat_span = ceil(radius_km / (111.32 * @grid_cell_deg))
    lon_km_per_deg = max(111.32 * :math.cos(lat * :math.pi() / 180.0), 1.0e-6)
    lon_span = ceil(radius_km / (lon_km_per_deg * @grid_cell_deg))
    {cx, cy} = cell(lon, lat)

    for dx <- -lon_span..lon_span,
        dy <- -lat_span..lat_span,
        member <- Map.get(grid, {cx + dx, cy + dy}, []),
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
