defmodule PowerModel.Grid do
  @moduledoc """
  Context for power grid data queries and operations.
  """

  import Ecto.Query
  alias PowerModel.Repo

  alias PowerModel.Grid.{
    Bus,
    Generator,
    TransmissionLine,
    Load,
    Substation,
    Transformer,
    Interconnection,
    WaterFacility,
    Datacenter
  }

  # Interconnections

  def list_interconnections do
    Repo.all(Interconnection)
  end

  def get_interconnection!(id), do: Repo.get!(Interconnection, id)

  def get_interconnection_by_name(name) do
    Repo.get_by(Interconnection, name: name)
  end

  # Buses

  def list_buses(opts \\ []) do
    Bus
    |> maybe_filter_interconnection(opts[:interconnection_id])
    |> maybe_filter_bus_type(opts[:bus_type])
    |> Repo.all()
  end

  def get_bus!(id), do: Repo.get!(Bus, id)

  def count_buses(interconnection_id \\ nil) do
    Bus
    |> maybe_filter_interconnection(interconnection_id)
    |> Repo.aggregate(:count)
  end

  # Generators

  def list_generators(opts \\ []) do
    Generator
    |> maybe_join_bus(opts)
    |> maybe_filter_fuel_type(opts[:fuel_type])
    |> Repo.all()
  end

  def get_generator!(id), do: Repo.get!(Generator, id)

  # DAT-13: headline totals mirror the snapshot predicates (geolocated bus
  # with an interconnection) so reported GW match what is actually simulated;
  # coordinate-less imports and unmapped fleets are excluded exactly as
  # get_grid_snapshot excludes them.
  def total_generation_capacity(interconnection_id \\ nil) do
    query =
      from g in Generator,
        join: b in Bus,
        on: g.bus_id == b.id,
        where:
          g.status == "in_service" and
            not is_nil(b.coordinates) and not is_nil(b.interconnection_id),
        select: sum(g.p_max_mw)

    query
    |> maybe_filter_bus_interconnection(interconnection_id)
    |> Repo.one() || 0.0
  end

  # Transmission Lines

  def list_transmission_lines(opts \\ []) do
    TransmissionLine
    |> maybe_filter_voltage(opts[:min_voltage_kv])
    |> maybe_filter_status(opts[:status])
    |> Repo.all()
  end

  def get_transmission_line!(id), do: Repo.get!(TransmissionLine, id)

  # Simulations operate on the geolocated network that the map displays.
  # Imported cases whose buses carry no coordinates (e.g. the SyntheticUSA
  # MATPOWER component) are invisible and unclickable on the map, so they are
  # excluded from snapshots entirely.
  #
  # Branches whose endpoints sit in DIFFERENT interconnections are data
  # artifacts: the Eastern, Western, and ERCOT systems are asynchronous and
  # joined only by DC ties, never by AC lines. Including such branches fuses
  # the interconnections into one fictitious electrical network where a trip
  # in Arizona ripples into Indiana.
  #
  # LIN-6: HVDC lines (line_type == "dc", written at HIFLD ingest from
  # VOLT_CLASS) are excluded from all AC snapshots — a DC link carries a
  # CONTROLLED flow, not one set by its series impedance, so modeling e.g.
  # the Pacific DC Intertie as a giant AC line absorbs Western N-S flow that
  # actually rides the AC paths. Proper treatment is a pair of fixed
  # injections at the converter buses (future work); until then the ties are
  # simply not part of the AC network.
  def in_service_lines(interconnection_id) do
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
      select: tl
    )
    |> Repo.all()
  end

  # Loads

  def list_loads(opts \\ []) do
    Load
    |> maybe_filter_status(opts[:status])
    |> Repo.all()
  end

  # DAT-13: same snapshot-aligned filters as total_generation_capacity/1.
  def total_load(interconnection_id \\ nil) do
    query =
      from l in Load,
        join: b in Bus,
        on: l.bus_id == b.id,
        where:
          l.status == "in_service" and
            not is_nil(b.coordinates) and not is_nil(b.interconnection_id),
        select: %{p_mw: sum(l.p_mw), q_mvar: sum(l.q_mvar)}

    query
    |> maybe_filter_bus_interconnection(interconnection_id)
    |> Repo.one()
  end

  # Substations

  def list_substations, do: Repo.all(Substation)
  def get_substation!(id), do: Repo.get!(Substation, id)

  # Transformers

  def list_transformers, do: Repo.all(Transformer)
  def get_transformer!(id), do: Repo.get!(Transformer, id)

  def in_service_transformers(interconnection_id) do
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
      select: t
    )
    |> Repo.all()
  end

  # Topology helpers

  def get_bus_branches(bus_id) do
    lines =
      from(tl in TransmissionLine,
        where:
          (tl.from_bus_id == ^bus_id or tl.to_bus_id == ^bus_id) and tl.status == "in_service"
      )
      |> Repo.all()

    transformers =
      from(t in Transformer,
        where: (t.from_bus_id == ^bus_id or t.to_bus_id == ^bus_id) and t.status == "in_service"
      )
      |> Repo.all()

    %{lines: lines, transformers: transformers}
  end

  @doc """
  Snapshot of one interconnection's grid (largest connected component among
  geolocated buses — the network the map displays and the user can interact
  with; coordinate-less imports are excluded).

  Options:
  - `:hour` — a `DateTime`; when given (and EIA-930 demand data is loaded),
    load `p_mw`/`q_mvar` are scaled so each balancing authority's total
    matches its actual demand for that hour. See `PowerModel.Demand`.
  """
  def get_grid_snapshot(interconnection_id, opts \\ []) do
    lines = in_service_lines(interconnection_id)
    transformers = in_service_transformers(interconnection_id)

    # Find the largest connected component to exclude data fragments
    main_bus_ids = largest_connected_component(lines, transformers)
    main_list = MapSet.to_list(main_bus_ids)

    # Filter lines/transformers to only those within the main component
    lines =
      Enum.filter(lines, fn l ->
        MapSet.member?(main_bus_ids, l.from_bus_id) and MapSet.member?(main_bus_ids, l.to_bus_id)
      end)

    transformers =
      Enum.filter(transformers, fn t ->
        MapSet.member?(main_bus_ids, t.from_bus_id) and MapSet.member?(main_bus_ids, t.to_bus_id)
      end)

    buses =
      if main_list != [] do
        from(b in Bus, where: b.id in ^main_list) |> Repo.all()
      else
        []
      end

    generators =
      if main_list != [] do
        from(g in Generator,
          where: g.status == "in_service" and g.bus_id in ^main_list
        )
        |> Repo.all()
      else
        []
      end

    loads =
      if main_list != [] do
        from(l in Load,
          where: l.status == "in_service" and l.bus_id in ^main_list
        )
        |> Repo.all()
      else
        []
      end

    water_facilities =
      if main_list != [] do
        from(w in WaterFacility,
          where: w.status == "active" and w.bus_id in ^main_list
        )
        |> Repo.all()
      else
        []
      end

    datacenters =
      if main_list != [] do
        from(d in Datacenter,
          where: d.status == "active" and d.bus_id in ^main_list
        )
        |> Repo.all()
      else
        []
      end

    %{
      buses: buses,
      lines: lines,
      transformers: transformers,
      generators: generators,
      loads: maybe_scale_loads(loads, buses, opts[:hour]),
      water_facilities: water_facilities,
      datacenters: datacenters
    }
  end

  @doc """
  Snapshot of the full grid (largest connected component).
  Accepts the same options as `get_grid_snapshot/2`.
  """
  def get_full_grid_snapshot(opts \\ []) do
    # Geo-located endpoints only, no cross-interconnection branches, no DC
    # ties -- see in_service_lines/1 for rationale.
    lines =
      from(tl in TransmissionLine,
        join: fb in Bus,
        on: tl.from_bus_id == fb.id,
        join: tb in Bus,
        on: tl.to_bus_id == tb.id,
        where:
          tl.status == "in_service" and
            tl.from_bus_id != tl.to_bus_id and
            (is_nil(tl.line_type) or tl.line_type != "dc") and
            not is_nil(fb.coordinates) and not is_nil(tb.coordinates) and
            not is_nil(fb.interconnection_id) and
            fb.interconnection_id == tb.interconnection_id,
        select: tl
      )
      |> Repo.all()

    transformers =
      from(t in Transformer,
        join: fb in Bus,
        on: t.from_bus_id == fb.id,
        join: tb in Bus,
        on: t.to_bus_id == tb.id,
        where:
          t.status == "in_service" and
            t.from_bus_id != t.to_bus_id and
            not is_nil(fb.coordinates) and not is_nil(tb.coordinates) and
            not is_nil(fb.interconnection_id) and
            fb.interconnection_id == tb.interconnection_id,
        select: t
      )
      |> Repo.all()

    # Find the largest connected component to exclude data fragments
    main_bus_ids = largest_connected_component(lines, transformers)
    main_list = MapSet.to_list(main_bus_ids)

    lines =
      Enum.filter(lines, fn l ->
        MapSet.member?(main_bus_ids, l.from_bus_id) and MapSet.member?(main_bus_ids, l.to_bus_id)
      end)

    transformers =
      Enum.filter(transformers, fn t ->
        MapSet.member?(main_bus_ids, t.from_bus_id) and MapSet.member?(main_bus_ids, t.to_bus_id)
      end)

    buses =
      if main_list != [] do
        from(b in Bus, where: b.id in ^main_list) |> Repo.all()
      else
        []
      end

    generators =
      if main_list != [] do
        from(g in Generator,
          where: g.status == "in_service" and g.bus_id in ^main_list
        )
        |> Repo.all()
      else
        []
      end

    loads =
      if main_list != [] do
        from(l in Load, where: l.status == "in_service" and l.bus_id in ^main_list) |> Repo.all()
      else
        []
      end

    water_facilities =
      if main_list != [] do
        from(w in WaterFacility, where: w.status == "active" and w.bus_id in ^main_list)
        |> Repo.all()
      else
        []
      end

    datacenters =
      if main_list != [] do
        from(d in Datacenter, where: d.status == "active" and d.bus_id in ^main_list)
        |> Repo.all()
      else
        []
      end

    %{
      buses: buses,
      lines: lines,
      transformers: transformers,
      generators: generators,
      loads: maybe_scale_loads(loads, buses, opts[:hour]),
      water_facilities: water_facilities,
      datacenters: datacenters
    }
  end

  defp maybe_scale_loads(loads, _buses, nil), do: loads

  defp maybe_scale_loads(loads, buses, %DateTime{} = hour) do
    PowerModel.Demand.scale_loads(loads, buses, hour)
  end

  # Export data for binary grid files
  #
  # DAT-2: the map export and the solver snapshot must describe the SAME
  # network in both directions — a line the solver cannot simulate must not
  # be clickable (it would answer :not_in_network), and a line the solver
  # DOES simulate must be visible (synthetic ties had no geometry, so their
  # trips were invisible). Export filters therefore mirror the snapshot
  # predicates of in_service_lines/1 / in_service_transformers/1, and
  # geometry-less lines are drawn as a 2-point segment between their
  # endpoint buses.

  def export_generators do
    from(g in Generator,
      join: b in Bus,
      on: g.bus_id == b.id,
      where:
        g.status == "in_service" and not is_nil(g.coordinates) and
          not is_nil(b.coordinates) and not is_nil(b.interconnection_id),
      select: %{
        id: g.id,
        coordinates: g.coordinates,
        p_max_mw: g.p_max_mw,
        fuel_type: g.fuel_type,
        bus_id: g.bus_id
      }
    )
    |> Repo.all()
  end

  def export_transmission_lines do
    from(tl in TransmissionLine,
      join: fb in Bus,
      on: tl.from_bus_id == fb.id,
      join: tb in Bus,
      on: tl.to_bus_id == tb.id,
      where:
        tl.status == "in_service" and
          tl.from_bus_id != tl.to_bus_id and
          (is_nil(tl.line_type) or tl.line_type != "dc") and
          not is_nil(fb.coordinates) and not is_nil(tb.coordinates) and
          not is_nil(fb.interconnection_id) and
          fb.interconnection_id == tb.interconnection_id,
      select: %{
        id: tl.id,
        geometry: tl.geometry,
        voltage_kv: tl.voltage_kv,
        rating_a_mva: tl.rating_a_mva,
        from_bus_id: tl.from_bus_id,
        to_bus_id: tl.to_bus_id,
        from_bus_coordinates: fb.coordinates,
        to_bus_coordinates: tb.coordinates
      }
    )
    |> Repo.all()
    |> Enum.map(&with_endpoint_geometry/1)
  end

  # Synthetic ties (and any other geometry-less line) get a straight 2-point
  # geometry between their endpoint buses so the map can draw and repaint
  # them during cascades.
  defp with_endpoint_geometry(%{geometry: %Geo.LineString{coordinates: [_ | _]}} = line) do
    Map.drop(line, [:from_bus_coordinates, :to_bus_coordinates])
  end

  defp with_endpoint_geometry(line) do
    geometry =
      case {line.from_bus_coordinates, line.to_bus_coordinates} do
        {%Geo.Point{coordinates: from}, %Geo.Point{coordinates: to}} ->
          %Geo.LineString{coordinates: [from, to], srid: 4326}

        _ ->
          line.geometry
      end

    line
    |> Map.put(:geometry, geometry)
    |> Map.drop([:from_bus_coordinates, :to_bus_coordinates])
  end

  def export_substations do
    # DAT-12: substations without coordinates would render at Null Island.
    from(s in Substation,
      where: s.status == "in_service" and not is_nil(s.coordinates),
      select: %{
        id: s.id,
        coordinates: s.coordinates,
        max_voltage_kv: s.max_voltage_kv,
        name: s.name
      }
    )
    |> Repo.all()
  end

  # Water Facilities

  def list_water_facilities(opts \\ []) do
    WaterFacility
    |> maybe_filter_county(opts[:county])
    |> maybe_filter_facility_type(opts[:facility_type])
    |> Repo.all()
  end

  def export_water_facilities do
    from(w in WaterFacility,
      where: w.status == "active",
      select: %{
        id: w.id,
        coordinates: w.coordinates,
        facility_type: w.facility_type,
        capacity_mgd: w.capacity_mgd,
        power_consumption_mw: w.power_consumption_mw,
        storage_acre_feet: w.storage_acre_feet,
        name: w.name,
        bus_id: w.bus_id
      }
    )
    |> Repo.all()
  end

  @doc """
  Per-bus total demand (MW) at geolocated buses, for the H3 demand-density
  overlay. Sums every in-service load on a bus — population/water
  `constant_power` rows and flat `datacenter` rows alike, since both are real
  consumption. Buses with no load or no coordinates are omitted.

  This is the baseline (unscaled) spatial distribution; the EIA-930 per-BA
  hour scaling rescales magnitudes per snapshot but not the relative shape.
  """
  def export_bus_loads do
    from(l in Load,
      join: b in Bus,
      on: l.bus_id == b.id,
      where: l.status == "in_service" and not is_nil(b.coordinates),
      group_by: [b.id, b.coordinates],
      select: %{coordinates: b.coordinates, demand_mw: sum(l.p_mw)}
    )
    |> Repo.all()
  end

  def export_transformers do
    # Positioned at their from-bus (transformers join two voltage levels at
    # the same physical substation). Filters mirror in_service_transformers/1
    # (DAT-2) so every exported transformer is simulatable.
    from(t in Transformer,
      join: fb in Bus,
      on: t.from_bus_id == fb.id,
      join: tb in Bus,
      on: t.to_bus_id == tb.id,
      where:
        t.status == "in_service" and
          t.from_bus_id != t.to_bus_id and
          not is_nil(fb.coordinates) and not is_nil(tb.coordinates) and
          not is_nil(fb.interconnection_id) and
          fb.interconnection_id == tb.interconnection_id,
      select: %{
        id: t.id,
        coordinates: fb.coordinates,
        rated_mva: t.rated_mva,
        from_bus_id: t.from_bus_id,
        to_bus_id: t.to_bus_id
      }
    )
    |> Repo.all()
  end

  def export_datacenters do
    from(d in Datacenter,
      where: d.status == "active",
      select: %{
        id: d.id,
        coordinates: d.coordinates,
        facility_type: d.facility_type,
        power_mw: d.power_mw,
        name: d.name,
        operator: d.operator,
        bus_id: d.bus_id
      }
    )
    |> Repo.all()
  end

  # Private helpers

  # Components below this size are data fragments, not real subsystems.
  @min_component_buses 200

  # BFS over the grid topology, keeping EVERY connected component large
  # enough to be a real electrical system (Eastern, Western, ERCOT live as
  # separate components once cross-interconnection data artifacts are
  # filtered out — each is simulated as its own island). Small fragments
  # from incomplete data are dropped. Falls back to the single largest
  # component when nothing reaches the threshold (small test grids).
  defp largest_connected_component(lines, transformers) do
    adj = build_adjacency(lines, transformers)
    all_bus_ids = Map.keys(adj)

    {components, _} =
      Enum.reduce(all_bus_ids, {[], MapSet.new()}, fn id, {comps, visited} ->
        if MapSet.member?(visited, id) do
          {comps, visited}
        else
          {comp, visited} = bfs_component([id], [], MapSet.put(visited, id), adj)
          {[comp | comps], visited}
        end
      end)

    case components do
      [] ->
        MapSet.new()

      _ ->
        kept = Enum.filter(components, &(length(&1) >= @min_component_buses))

        case kept do
          [] -> MapSet.new(Enum.max_by(components, &length/1))
          _ -> kept |> List.flatten() |> MapSet.new()
        end
    end
  end

  defp build_adjacency(lines, transformers) do
    adj = %{}

    adj =
      Enum.reduce(lines, adj, fn l, acc ->
        acc
        |> Map.update(l.from_bus_id, [l.to_bus_id], &[l.to_bus_id | &1])
        |> Map.update(l.to_bus_id, [l.from_bus_id], &[l.from_bus_id | &1])
      end)

    Enum.reduce(transformers, adj, fn t, acc ->
      acc
      |> Map.update(t.from_bus_id, [t.to_bus_id], &[t.to_bus_id | &1])
      |> Map.update(t.to_bus_id, [t.from_bus_id], &[t.from_bus_id | &1])
    end)
  end

  defp bfs_component([], comp, visited, _adj), do: {comp, visited}

  defp bfs_component([node | rest], comp, visited, adj) do
    neighbors = Map.get(adj, node, [])

    {new_queue, visited} =
      Enum.reduce(neighbors, {rest, visited}, fn n, {q, v} ->
        if MapSet.member?(v, n), do: {q, v}, else: {[n | q], MapSet.put(v, n)}
      end)

    bfs_component(new_queue, [node | comp], visited, adj)
  end

  defp maybe_filter_interconnection(query, nil), do: query

  defp maybe_filter_interconnection(query, id) do
    from b in query, where: b.interconnection_id == ^id
  end

  defp maybe_filter_bus_type(query, nil), do: query

  defp maybe_filter_bus_type(query, type) do
    from b in query, where: b.bus_type == ^type
  end

  defp maybe_join_bus(query, opts) do
    if opts[:interconnection_id] do
      from g in query,
        join: b in Bus,
        on: g.bus_id == b.id,
        where: b.interconnection_id == ^opts[:interconnection_id]
    else
      query
    end
  end

  defp maybe_filter_fuel_type(query, nil), do: query

  defp maybe_filter_fuel_type(query, type) do
    from g in query, where: g.fuel_type == ^type
  end

  defp maybe_filter_voltage(query, nil), do: query

  defp maybe_filter_voltage(query, min_kv) do
    from tl in query, where: tl.voltage_kv >= ^min_kv
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status) do
    from q in query, where: q.status == ^status
  end

  defp maybe_filter_bus_interconnection(query, nil), do: query

  defp maybe_filter_bus_interconnection(query, id) do
    from [_, b] in query, where: b.interconnection_id == ^id
  end

  defp maybe_filter_county(query, nil), do: query

  defp maybe_filter_county(query, county) do
    from w in query, where: w.county == ^county
  end

  defp maybe_filter_facility_type(query, nil), do: query

  defp maybe_filter_facility_type(query, type) do
    from w in query, where: w.facility_type == ^type
  end

  # Water-Grid Integration

  @doc """
  Map each water facility to its nearest bus (within max_km).
  Creates a Load record for each facility with power_consumption_mw.
  Returns {mapped_count, load_count}.
  """
  def map_water_facilities_to_grid(opts \\ []) do
    max_km = Keyword.get(opts, :max_km, 20)
    max_meters = max_km * 1000

    # Only facilities not yet mapped: re-running must not re-ADD their MW to
    # the shared bus loads (the merge below is additive, not idempotent).
    facilities =
      from(w in WaterFacility,
        where: w.status == "active" and not is_nil(w.coordinates) and is_nil(w.bus_id)
      )
      |> Repo.all()

    mapped =
      Enum.reduce(facilities, {0, 0}, fn facility, {map_count, load_count} ->
        # Find nearest bus within range
        nearest =
          from(b in Bus,
            where: not is_nil(b.coordinates),
            where:
              fragment(
                "ST_DWithin(?::geography, ?::geography, ?)",
                b.coordinates,
                ^facility.coordinates,
                ^max_meters
              ),
            order_by:
              fragment(
                "ST_Distance(?::geography, ?::geography)",
                b.coordinates,
                ^facility.coordinates
              ),
            limit: 1
          )
          |> Repo.one()

        case nearest do
          nil ->
            {map_count, load_count}

          bus ->
            # Update water facility with bus_id
            facility
            |> Ecto.Changeset.change(%{bus_id: bus.id})
            |> Repo.update!()

            # Add water facility power consumption to the bus's baseline load
            # (never the datacenter load row, which is held flat)
            lc =
              if facility.power_consumption_mw && facility.power_consumption_mw > 0 do
                existing_load =
                  from(l in Load,
                    where: l.bus_id == ^bus.id and l.load_type == "constant_power"
                  )
                  |> Repo.one()

                case existing_load do
                  nil ->
                    # No load on this bus yet — create one
                    q_mvar = facility.power_consumption_mw * 0.3287

                    %Load{}
                    |> Load.changeset(%{
                      bus_id: bus.id,
                      p_mw: facility.power_consumption_mw,
                      q_mvar: q_mvar,
                      load_type: "constant_power",
                      status: "in_service"
                    })
                    |> Repo.insert!()

                    1

                  load ->
                    # Add to existing load
                    new_p = load.p_mw + facility.power_consumption_mw
                    new_q = (load.q_mvar || 0.0) + facility.power_consumption_mw * 0.3287

                    load
                    |> Ecto.Changeset.change(%{p_mw: new_p, q_mvar: new_q})
                    |> Repo.update!()

                    1
                end
              else
                0
              end

            {map_count + 1, load_count + lc}
        end
      end)

    mapped
  end

  @doc """
  Re-merge mapped water facility MW into the `constant_power` bus loads.

  `map_water_facilities_to_grid/1` adds each facility's MW into its bus's
  baseline load exactly once (guarded by `is_nil(bus_id)`), so when the load
  estimator rebuilds those rows the water MW is lost. This re-applies it for
  every already-mapped facility. NOT idempotent on its own — call it exactly
  once after each load re-estimation (LoadEstimator.run/0 does).

  Returns `{updated_count, inserted_count}`.
  """
  def reapply_water_facility_loads do
    q_ratio = 0.3287

    # Add water MW into existing constant_power rows
    %{num_rows: updated} =
      Repo.query!(
        """
        UPDATE loads l
        SET p_mw = l.p_mw + w.total_mw,
            q_mvar = COALESCE(l.q_mvar, 0) + w.total_mw * $1
        FROM (
          SELECT bus_id, SUM(power_consumption_mw) AS total_mw
          FROM water_facilities
          WHERE status = 'active' AND bus_id IS NOT NULL AND power_consumption_mw > 0
          GROUP BY bus_id
        ) w
        WHERE l.bus_id = w.bus_id AND l.load_type = 'constant_power'
        """,
        [q_ratio]
      )

    # Facilities mapped to buses with no constant_power row (e.g. non-PQ
    # buses) get a fresh row, as the original mapping did
    %{num_rows: inserted} =
      Repo.query!(
        """
        INSERT INTO loads (bus_id, p_mw, q_mvar, load_type, status, inserted_at, updated_at)
        SELECT w.bus_id, SUM(w.power_consumption_mw), SUM(w.power_consumption_mw) * $1,
               'constant_power', 'in_service', NOW(), NOW()
        FROM water_facilities w
        LEFT JOIN loads l ON l.bus_id = w.bus_id AND l.load_type = 'constant_power'
        WHERE w.status = 'active' AND w.bus_id IS NOT NULL
          AND w.power_consumption_mw > 0 AND l.id IS NULL
        GROUP BY w.bus_id
        """,
        [q_ratio]
      )

    {updated, inserted}
  end

  @doc """
  Get water facilities connected to a set of bus IDs.
  Used during cascade to determine which facilities lose power.
  """
  def get_water_facilities_for_buses(bus_ids) when is_list(bus_ids) do
    from(w in WaterFacility,
      where: w.bus_id in ^bus_ids and w.status == "active"
    )
    |> Repo.all()
  end

  @doc """
  Map datacenters to their nearest grid bus and (re)build their load rows.

  Loads are rebuilt deterministically: all `load_type: "datacenter"` rows are
  replaced by one row per bus summing the draw of every campus mapped there
  (PF 0.95, flat profile — see `PowerModel.Demand`). Re-running is idempotent.

  Returns `{mapped_count, load_rows, unmapped_count}`.
  """
  def map_datacenters_to_grid(opts \\ []) do
    max_km = Keyword.get(opts, :max_km, 30)
    max_meters = max_km * 1000

    datacenters =
      from(d in Datacenter,
        where: d.status == "active" and not is_nil(d.coordinates)
      )
      |> Repo.all()

    {mapped, unmapped} =
      Enum.reduce(datacenters, {0, 0}, fn dc, {mapped, unmapped} ->
        nearest =
          from(b in Bus,
            where: not is_nil(b.coordinates),
            where:
              fragment(
                "ST_DWithin(?::geography, ?::geography, ?)",
                b.coordinates,
                ^dc.coordinates,
                ^max_meters
              ),
            order_by:
              fragment("ST_Distance(?::geography, ?::geography)", b.coordinates, ^dc.coordinates),
            limit: 1
          )
          |> Repo.one()

        case nearest do
          nil ->
            IO.puts("  No bus within #{max_km} km of datacenter: #{dc.name}")
            {mapped, unmapped + 1}

          bus ->
            dc |> Ecto.Changeset.change(%{bus_id: bus.id}) |> Repo.update!()
            {mapped + 1, unmapped}
        end
      end)

    load_rows = rebuild_datacenter_loads()

    {mapped, load_rows, unmapped}
  end

  defp rebuild_datacenter_loads do
    {:ok, count} = Repo.transaction(fn -> do_rebuild_datacenter_loads() end)
    count
  end

  defp do_rebuild_datacenter_loads do
    Repo.delete_all(from l in Load, where: l.load_type == "datacenter")

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      from(d in Datacenter,
        where: d.status == "active" and not is_nil(d.bus_id),
        group_by: d.bus_id,
        select: {d.bus_id, sum(d.power_mw)}
      )
      |> Repo.all()
      |> Enum.map(fn {bus_id, p_mw} ->
        %{
          bus_id: bus_id,
          p_mw: p_mw,
          q_mvar: p_mw * 0.3287,
          load_type: "datacenter",
          status: "in_service",
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} = Repo.insert_all(Load, rows)
    count
  end

  @doc "Datacenters connected to a set of bus IDs (cascade power-loss checks)."
  def get_datacenters_for_buses(bus_ids) when is_list(bus_ids) do
    from(d in Datacenter,
      where: d.bus_id in ^bus_ids and d.status == "active"
    )
    |> Repo.all()
  end

  @doc """
  Get grid snapshot including water facilities and datacenters for a
  geographic region.

  DAT-11: branch predicates match `get_full_grid_snapshot/1` (mapped,
  geolocated endpoints in one interconnection, no self-loops, no DC ties) so
  the regional network is a subset of what the solver simulates. Accepts the
  same `:hour` option as the other snapshots.
  """
  def get_regional_grid_snapshot(bounds, opts \\ []) do
    {west, south, east, north} = bounds

    buses =
      from(b in Bus,
        where: not is_nil(b.coordinates),
        where:
          fragment(
            "ST_Within(?, ST_MakeEnvelope(?, ?, ?, ?, 4326))",
            b.coordinates,
            ^west,
            ^south,
            ^east,
            ^north
          )
      )
      |> Repo.all()

    bus_ids = MapSet.new(buses, & &1.id)

    lines =
      from(tl in TransmissionLine,
        join: fb in Bus,
        on: tl.from_bus_id == fb.id,
        join: tb in Bus,
        on: tl.to_bus_id == tb.id,
        where:
          tl.status == "in_service" and tl.from_bus_id != tl.to_bus_id and
            (is_nil(tl.line_type) or tl.line_type != "dc") and
            not is_nil(fb.coordinates) and not is_nil(tb.coordinates) and
            not is_nil(fb.interconnection_id) and
            fb.interconnection_id == tb.interconnection_id,
        where:
          fragment(
            "ST_Intersects(?, ST_MakeEnvelope(?, ?, ?, ?, 4326))",
            tl.geometry,
            ^west,
            ^south,
            ^east,
            ^north
          ),
        select: tl
      )
      |> Repo.all()

    # Include buses referenced by lines but outside the bbox (the join
    # predicates above guarantee they are geolocated and carry an
    # interconnection).
    extra_bus_ids =
      lines
      |> Enum.flat_map(fn l -> [l.from_bus_id, l.to_bus_id] end)
      |> Enum.reject(&MapSet.member?(bus_ids, &1))
      |> Enum.uniq()

    extra_buses =
      if extra_bus_ids != [] do
        from(b in Bus, where: b.id in ^extra_bus_ids) |> Repo.all()
      else
        []
      end

    all_buses = buses ++ extra_buses
    all_bus_id_list = MapSet.to_list(MapSet.new(all_buses, & &1.id))

    transformers =
      from(t in Transformer,
        join: fb in Bus,
        on: t.from_bus_id == fb.id,
        join: tb in Bus,
        on: t.to_bus_id == tb.id,
        where:
          t.status == "in_service" and t.from_bus_id != t.to_bus_id and
            not is_nil(fb.coordinates) and not is_nil(tb.coordinates) and
            not is_nil(fb.interconnection_id) and
            fb.interconnection_id == tb.interconnection_id,
        where: t.from_bus_id in ^all_bus_id_list or t.to_bus_id in ^all_bus_id_list,
        select: t
      )
      |> Repo.all()

    generators =
      from(g in Generator,
        where: g.status == "in_service" and g.bus_id in ^all_bus_id_list
      )
      |> Repo.all()

    loads =
      from(l in Load,
        where: l.status == "in_service" and l.bus_id in ^all_bus_id_list
      )
      |> Repo.all()

    water_facilities =
      from(w in WaterFacility,
        where: w.status == "active" and w.bus_id in ^all_bus_id_list
      )
      |> Repo.all()

    datacenters =
      from(d in Datacenter,
        where: d.status == "active" and d.bus_id in ^all_bus_id_list
      )
      |> Repo.all()

    %{
      buses: all_buses,
      lines: lines,
      transformers: transformers,
      generators: generators,
      loads: maybe_scale_loads(loads, all_buses, opts[:hour]),
      water_facilities: water_facilities,
      datacenters: datacenters
    }
  end
end
