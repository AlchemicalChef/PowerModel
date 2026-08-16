defmodule PowerModel.Ingestion.Cleanup do
  @moduledoc """
  Re-map synthetic/demo components to real substation buses.

  Generators on synthetic buses get moved to the nearest real substation bus.
  Remaining generators that can't find a substation bus get a tie-line created.
  Unmapped transmission lines get a wider-radius endpoint search.
  Orphaned synthetic buses get deleted.
  """

  import Ecto.Query
  require Logger
  alias PowerModel.Repo

  alias PowerModel.Grid.{
    Bus,
    Datacenter,
    Generator,
    Load,
    TransmissionLine,
    Transformer,
    WaterFacility
  }

  alias PowerModel.Ingestion.BusMapper

  # Wide search for generators (100km should cover any plant near a transmission corridor)
  @gen_remap_radius_m 100_000

  # Wide search for line endpoints
  @line_remap_radius_m 50_000

  # Voltage tolerance for matching (±20%)
  @voltage_tolerance 0.20

  # Degrees of longitude per km at the highest CONUS latitude (49 deg N), where
  # a degree of longitude is shortest. Used to widen the planar bounding box in
  # `within/2` so it can never exclude a point the geography test would accept.
  @deg_per_km 1.0 / 73.0

  def run do
    IO.puts("=== Cleanup: Re-mapping synthetic components to real ones ===\n")
    remap_generators()
    remap_unmapped_lines()
    connect_isolated_generators()
    cleanup_orphaned_buses()
    resize_transformers()
    IO.puts("\n=== Cleanup complete ===")
  end

  @doc """
  Re-rate substation banks against the load their low side now carries
  (TOPO-6), delegating to `BusMapper.resize_transformers_to_through_load/0`.

  It runs here, and not in `map_buses`, because of pipeline order:
  `create_substation_transformers` fires long before `LoadEstimator` exists to
  say what any low side will carry, and cleanup is the first BusMapper-owned
  stage that runs after the loads are written.
  """
  def resize_transformers do
    %{resized: resized, added_mva: added} = BusMapper.resize_transformers_to_through_load()

    IO.puts(
      "\nSubstation banks re-rated to their low-side load: #{resized} " <>
        "(+#{Float.round(added, 1)} MVA)"
    )

    %{resized: resized, added_mva: added}
  end

  @doc """
  Move generators from synthetic buses to the nearest real substation bus that
  can evacuate them.

  PLT-7: when the generator's current bus carries an interconnection, only
  substation buses in the SAME interconnection are candidates — a 100 km
  search radius can otherwise relocate a plant across an asynchronous seam
  (e.g. from ERCOT into the Eastern interconnection).

  LIN13-B: the candidate filter is the same voltage/size floor
  `BusMapper.map_generators_to_buses/0` applies, for the same reason and with
  the same LIN-8 reversal. Without it this pass undoes that one — its search
  radius is ten times wider and its old tie-break took the LOWEST level of
  whatever yard it found, so a GW-scale plant that `map_buses` had placed on
  EHV could be dragged back down onto a 13.8 kV bus 90 km away.
  """
  def remap_generators do
    # Find all generators on synthetic buses
    gens_on_synth =
      Repo.all(
        from g in Generator,
          join: b in Bus,
          on: g.bus_id == b.id,
          where: b.source == "synthetic" and g.status == "in_service",
          preload: [bus: b]
      )

    IO.puts("Generators on synthetic buses: #{length(gens_on_synth)}")

    capacity = BusMapper.connected_branch_capacity()
    plant_mw = plant_nameplate_index()

    {remapped, kept} =
      Enum.reduce(gens_on_synth, {0, 0}, fn gen, {ok, skip} ->
        point = gen.bus.coordinates || gen.coordinates
        mw = Map.get(plant_mw, gen.eia_plant_id) || gen.p_max_mw || 0.0

        target =
          point &&
            find_evacuating_bus(
              point,
              @gen_remap_radius_m,
              gen.bus.interconnection_id,
              BusMapper.plant_voltage_floor(mw),
              mw,
              capacity
            )

        case target do
          nil ->
            {ok, skip + 1}

          bus ->
            gen
            |> Ecto.Changeset.change(%{bus_id: bus.id})
            |> Repo.update!()

            {ok + 1, skip}
        end
      end)

    IO.puts("  Remapped to substation buses: #{remapped}")

    IO.puts(
      "  Could not remap (no substation within #{div(@gen_remap_radius_m, 1000)}km): #{kept}"
    )
  end

  @doc """
  Re-map transmission line endpoints that have nil bus IDs.
  Uses wider radius and falls back to any-voltage bus.
  """
  def remap_unmapped_lines do
    lines =
      Repo.all(
        from l in TransmissionLine,
          where: l.status == "in_service" and (is_nil(l.from_bus_id) or is_nil(l.to_bus_id))
      )

    IO.puts("\nUnmapped lines: #{length(lines)}")

    {mapped_from, mapped_to, still_unmapped} =
      Enum.reduce(lines, {0, 0, 0}, fn line, {mf, mt, um} ->
        changes = %{}

        changes =
          if is_nil(line.from_bus_id) do
            from_point = get_line_endpoint(line.geometry, :from)

            case find_bus_for_line(from_point, line.voltage_kv) do
              nil -> changes
              bus -> Map.put(changes, :from_bus_id, bus.id)
            end
          else
            changes
          end

        changes =
          if is_nil(line.to_bus_id) do
            to_point = get_line_endpoint(line.geometry, :to)

            case find_bus_for_line(to_point, line.voltage_kv) do
              nil -> changes
              bus -> Map.put(changes, :to_bus_id, bus.id)
            end
          else
            changes
          end

        # Drop the fills if the endpoints would resolve to the same bus: a
        # wider-radius search must not synthesize a self-loop the snap pass
        # already refused to create.
        resolved_from = changes[:from_bus_id] || line.from_bus_id
        resolved_to = changes[:to_bus_id] || line.to_bus_id

        changes =
          if not is_nil(resolved_from) and resolved_from == resolved_to do
            Logger.warning(
              "Cleanup: skipping self-loop on transmission line #{line.id} " <>
                "(endpoints resolve to bus #{resolved_from})"
            )

            %{}
          else
            changes
          end

        if map_size(changes) > 0 do
          line |> Ecto.Changeset.change(changes) |> Repo.update!()
          from_ok = if changes[:from_bus_id], do: 1, else: 0
          to_ok = if changes[:to_bus_id], do: 1, else: 0
          {mf + from_ok, mt + to_ok, um}
        else
          {mf, mt, um + 1}
        end
      end)

    IO.puts("  From-bus mapped: #{mapped_from}")
    IO.puts("  To-bus mapped: #{mapped_to}")
    IO.puts("  Still unmapped: #{still_unmapped}")
  end

  @doc """
  For generators still on synthetic buses (couldn't remap), create a short
  tie-line from their synthetic bus to the nearest real substation bus.
  This connects them electrically to the grid.
  """
  def connect_isolated_generators do
    # Find synthetic buses that still have generators but no lines
    synth_buses =
      Repo.all(
        from b in Bus,
          join: g in Generator,
          on: g.bus_id == b.id,
          left_join: l1 in TransmissionLine,
          on: l1.from_bus_id == b.id,
          left_join: l2 in TransmissionLine,
          on: l2.to_bus_id == b.id,
          where:
            b.source == "synthetic" and g.status == "in_service" and
              is_nil(l1.id) and is_nil(l2.id),
          distinct: b.id,
          select: b
      )

    IO.puts("\nIsolated synthetic buses with generators: #{length(synth_buses)}")

    connected =
      Enum.reduce(synth_buses, 0, fn bus, count ->
        # Same-interconnection restriction as remap_generators (PLT-7): a
        # synthetic tie must not weld two asynchronous systems together.
        case find_nearest_substation_bus(
               bus.coordinates,
               @gen_remap_radius_m,
               bus.interconnection_id
             ) do
          nil ->
            count

          target_bus ->
            # Create a short tie-line connecting this bus to the grid
            distance_km = haversine_km(bus.coordinates, target_bus.coordinates)
            voltage_kv = max(bus.base_kv, target_bus.base_kv)
            {r_pu, x_pu, b_pu, rating} = line_params_for_voltage(voltage_kv, distance_km)

            %TransmissionLine{}
            |> TransmissionLine.changeset(%{
              from_bus_id: bus.id,
              to_bus_id: target_bus.id,
              voltage_kv: voltage_kv,
              r_pu: r_pu,
              x_pu: x_pu,
              b_pu: b_pu,
              rating_a_mva: rating,
              length_km: distance_km,
              source: "synthetic_tie",
              source_id: "tie_#{bus.id}_#{target_bus.id}",
              status: "in_service"
            })
            |> Repo.insert(on_conflict: :nothing, conflict_target: [:source, :source_id])

            count + 1
        end
      end)

    IO.puts("  Connected via tie-lines: #{connected}")
  end

  @doc """
  Delete synthetic buses that nothing references.

  DAT-3: "orphaned" must mean unreferenced by EVERY table that points at
  buses — generators, lines, transformers, loads, water facilities, and
  datacenters. Missing the last three either crashed the delete on the
  loads FK mid-task or silently stranded water/datacenter records.
  """
  def cleanup_orphaned_buses do
    # Find synthetic buses with no references
    orphaned =
      Repo.all(
        from b in Bus,
          left_join: g in Generator,
          on: g.bus_id == b.id,
          left_join: l1 in TransmissionLine,
          on: l1.from_bus_id == b.id,
          left_join: l2 in TransmissionLine,
          on: l2.to_bus_id == b.id,
          left_join: t1 in Transformer,
          on: t1.from_bus_id == b.id,
          left_join: t2 in Transformer,
          on: t2.to_bus_id == b.id,
          left_join: ld in Load,
          on: ld.bus_id == b.id,
          left_join: w in WaterFacility,
          on: w.bus_id == b.id,
          left_join: d in Datacenter,
          on: d.bus_id == b.id,
          where:
            b.source == "synthetic" and
              is_nil(g.id) and is_nil(l1.id) and is_nil(l2.id) and
              is_nil(t1.id) and is_nil(t2.id) and
              is_nil(ld.id) and is_nil(w.id) and is_nil(d.id),
          select: b.id
      )

    IO.puts("\nOrphaned synthetic buses (no references): #{length(orphaned)}")

    if length(orphaned) > 0 do
      {deleted, _} = Repo.delete_all(from b in Bus, where: b.id in ^orphaned)
      IO.puts("  Deleted: #{deleted}")
    end
  end

  # Find nearest bus from a real substation (not synthetic). When an
  # interconnection id is given, only buses in that interconnection are
  # candidates (PLT-7); nil means the source interconnection is unknown and
  # no restriction applies.
  #
  # With a bus per voltage level, the nearest substation offers several buses
  # at one coordinate. Prefer its LOWEST level: this call places generators and
  # their synthetic ties, and the tie is a near-zero-impedance weld between the
  # generator's 13.8 kV bus and whatever it lands on (LIN-8, still open) — the
  # lowest level at least keeps that weld to the smallest ratio available
  # instead of leaving the choice to the planner.
  # Radius filter that can actually use the GiST index on `buses.coordinates`.
  #
  # `ST_DWithin(coordinates::geography, ...)` cannot: the index is on the
  # GEOMETRY, so casting both sides to geography forces a sequential scan of
  # every bus — measured at 23-41 ms per call, which at national scale is tens
  # of thousands of full scans. The planar `ST_DWithin` on the raw geometry is
  # index-backed but works in degrees, so it runs first as a deliberately
  # generous bounding filter and the exact geography test runs on what
  # survives.
  defmacrop within(coordinates, point, radius_m) do
    quote do
      fragment(
        "ST_DWithin(?, ?, ?) AND ST_DWithin(?::geography, ?::geography, ?)",
        unquote(coordinates),
        unquote(point),
        ^(unquote(radius_m) / 1000.0 * @deg_per_km),
        unquote(coordinates),
        unquote(point),
        ^unquote(radius_m)
      )
    end
  end

  # Whole-plant nameplate by EIA plant id: the size test asks how much steel
  # is behind the switchyard, not how big one machine of it is.
  defp plant_nameplate_index do
    from(g in Generator,
      where: g.status == "in_service" and not is_nil(g.eia_plant_id) and g.eia_plant_id != "",
      group_by: g.eia_plant_id,
      select: {g.eia_plant_id, sum(g.p_max_mw)}
    )
    |> Repo.all()
    |> Map.new(fn {plant, mw} -> {plant, (mw || 0.0) * 1.0} end)
  end

  # Nearest substation bus at or above `min_kv` that can carry `plant_mw`,
  # ranked the way BusMapper ranks: capacity first, then distance, then the
  # LOWEST qualifying level. Falls back to the unfiltered nearest bus when no
  # candidate clears the floor, so the floor can never leave a plant stranded
  # on its synthetic bus.
  defp find_evacuating_bus(point, radius_m, interconnection_id, nil, _plant_mw, _capacity),
    do: find_nearest_substation_bus(point, radius_m, interconnection_id)

  defp find_evacuating_bus(point, radius_m, interconnection_id, min_kv, plant_mw, capacity) do
    needed = BusMapper.stranding_headroom() * plant_mw

    candidates =
      from(b in Bus,
        where:
          b.source == "substation" and within(b.coordinates, ^point, radius_m) and
            b.base_kv >= ^min_kv,
        order_by: [
          asc: fragment("ST_Distance(?::geography, ?::geography)", b.coordinates, ^point)
        ],
        limit: 25,
        select: %{
          bus: b,
          distance: fragment("ST_Distance(?::geography, ?::geography)", b.coordinates, ^point)
        }
      )
      |> then(fn query ->
        if interconnection_id do
          from b in query, where: b.interconnection_id == ^interconnection_id
        else
          query
        end
      end)
      |> Repo.all()

    case candidates do
      [] ->
        find_nearest_substation_bus(point, radius_m, interconnection_id)

      candidates ->
        candidates
        |> Enum.min_by(fn %{bus: bus, distance: distance} ->
          short = if Map.get(capacity, bus.id, 0.0) >= needed, do: 0, else: 1
          {short, distance, bus.base_kv, bus.id}
        end)
        |> Map.fetch!(:bus)
    end
  end

  defp find_nearest_substation_bus(nil, _radius, _interconnection_id), do: nil

  defp find_nearest_substation_bus(point, radius_m, interconnection_id) do
    from(b in Bus,
      where: b.source == "substation" and within(b.coordinates, ^point, radius_m),
      order_by: [
        asc: fragment("ST_Distance(?::geography, ?::geography)", b.coordinates, ^point),
        asc: b.base_kv,
        asc: b.id
      ],
      limit: 1
    )
    |> then(fn query ->
      if interconnection_id do
        from b in query, where: b.interconnection_id == ^interconnection_id
      else
        query
      end
    end)
    |> Repo.one()
  end

  # Find nearest bus for a line endpoint: try voltage-matched substation buses
  # first, then any bus at a matching voltage.
  #
  # A substation now carries a bus for EVERY voltage level it has, all at the
  # same coordinate, so several of them fall inside the +/-20% window at once
  # and distance cannot tell them apart. Rank the voltage match after distance
  # so a 345 kV endpoint lands on the yard's 345 kV bus instead of whichever
  # level the planner returned first (LIN-5).
  defp find_bus_for_line(nil, _kv), do: nil

  defp find_bus_for_line(point, voltage_kv) do
    tolerance = voltage_kv * @voltage_tolerance
    low = voltage_kv - tolerance
    high = voltage_kv + tolerance

    substation_match =
      Repo.one(
        from b in Bus,
          where:
            b.source == "substation" and
              within(b.coordinates, ^point, @line_remap_radius_m) and
              b.base_kv >= ^low and b.base_kv <= ^high,
          order_by: [
            asc: fragment("ST_Distance(?::geography, ?::geography)", b.coordinates, ^point),
            asc: fragment("abs(? - ?)", b.base_kv, ^voltage_kv),
            asc: b.id
          ],
          limit: 1
      )

    # Fall back to any bus (including synthetic) at matching voltage
    substation_match ||
      Repo.one(
        from b in Bus,
          where:
            within(b.coordinates, ^point, @line_remap_radius_m) and
              b.base_kv >= ^low and b.base_kv <= ^high,
          order_by: [
            asc: fragment("ST_Distance(?::geography, ?::geography)", b.coordinates, ^point),
            asc: fragment("abs(? - ?)", b.base_kv, ^voltage_kv),
            asc: b.id
          ],
          limit: 1
      )
  end

  defp get_line_endpoint(%Geo.LineString{coordinates: coords}, :from) do
    case List.first(coords) do
      {lon, lat} -> %Geo.Point{coordinates: {lon, lat}, srid: 4326}
      {lon, lat, _} -> %Geo.Point{coordinates: {lon, lat}, srid: 4326}
      _ -> nil
    end
  end

  defp get_line_endpoint(%Geo.LineString{coordinates: coords}, :to) do
    case List.last(coords) do
      {lon, lat} -> %Geo.Point{coordinates: {lon, lat}, srid: 4326}
      {lon, lat, _} -> %Geo.Point{coordinates: {lon, lat}, srid: 4326}
      _ -> nil
    end
  end

  defp get_line_endpoint(_, _), do: nil

  defp haversine_km(%Geo.Point{coordinates: {lon1, lat1}}, %Geo.Point{coordinates: {lon2, lat2}}) do
    r = 6371.0
    dlat = (lat2 - lat1) * :math.pi() / 180
    dlon = (lon2 - lon1) * :math.pi() / 180
    lat1_r = lat1 * :math.pi() / 180
    lat2_r = lat2 * :math.pi() / 180

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(lat1_r) * :math.cos(lat2_r) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    Float.round(r * c, 2)
  end

  defp haversine_km(_, _), do: 10.0

  # Estimated line parameters by voltage class
  defp line_params_for_voltage(voltage_kv, length_km) do
    base_mva = 100.0
    z_base = voltage_kv * voltage_kv / base_mva

    {r_per_km, x_per_km, _b_per_km, rating} =
      cond do
        voltage_kv >= 500 -> {0.010, 0.300, 4.0, 1800.0}
        voltage_kv >= 345 -> {0.020, 0.335, 3.6, 900.0}
        voltage_kv >= 230 -> {0.040, 0.370, 3.3, 450.0}
        voltage_kv >= 138 -> {0.075, 0.400, 3.0, 250.0}
        voltage_kv >= 69 -> {0.170, 0.450, 2.7, 130.0}
        true -> {0.200, 0.500, 2.5, 100.0}
      end

    r_pu = r_per_km * length_km / z_base
    x_pu = x_per_km * length_km / z_base
    # Keep x_pu minimum to avoid numerical issues
    x_pu = max(x_pu, 0.001)
    {Float.round(r_pu, 6), Float.round(x_pu, 6), 0.0, rating}
  end
end
