defmodule PowerModel.Grid do
  @moduledoc """
  Context for power grid data queries and operations.
  """

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, Generator, TransmissionLine, Load, Substation, Transformer, Interconnection, WaterFacility, CriticalFacility}

  def list_interconnections do
    Repo.all(Interconnection)
  end

  def get_interconnection!(id), do: Repo.get!(Interconnection, id)

  def get_interconnection_by_name(name) do
    Repo.get_by(Interconnection, name: name)
  end

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

  def list_generators(opts \\ []) do
    Generator
    |> maybe_join_bus(opts)
    |> maybe_filter_fuel_type(opts[:fuel_type])
    |> Repo.all()
  end

  def get_generator!(id), do: Repo.get!(Generator, id)

  def total_generation_capacity(interconnection_id \\ nil) do
    query = from g in Generator,
      join: b in Bus, on: g.bus_id == b.id,
      where: g.status == "in_service",
      select: sum(g.p_max_mw)

    query
    |> maybe_filter_bus_interconnection(interconnection_id)
    |> Repo.one() || 0.0
  end

  def list_transmission_lines(opts \\ []) do
    TransmissionLine
    |> maybe_filter_voltage(opts[:min_voltage_kv])
    |> maybe_filter_status(opts[:status])
    |> Repo.all()
  end

  def get_transmission_line!(id), do: Repo.get!(TransmissionLine, id)

  def in_service_lines(interconnection_id) do
    from(tl in TransmissionLine,
      join: fb in Bus, on: tl.from_bus_id == fb.id,
      where: tl.status == "in_service" and fb.interconnection_id == ^interconnection_id
        and not is_nil(tl.from_bus_id) and not is_nil(tl.to_bus_id),
      select: tl
    )
    |> Repo.all()
  end

  def list_loads(opts \\ []) do
    Load
    |> maybe_filter_status(opts[:status])
    |> Repo.all()
  end

  def total_load(interconnection_id \\ nil) do
    query = from l in Load,
      join: b in Bus, on: l.bus_id == b.id,
      where: l.status == "in_service",
      select: %{p_mw: sum(l.p_mw), q_mvar: sum(l.q_mvar)}

    query
    |> maybe_filter_bus_interconnection(interconnection_id)
    |> Repo.one()
  end

  def list_substations, do: Repo.all(Substation)
  def get_substation!(id), do: Repo.get!(Substation, id)

  def list_transformers, do: Repo.all(Transformer)
  def get_transformer!(id), do: Repo.get!(Transformer, id)

  def in_service_transformers(interconnection_id) do
    from(t in Transformer,
      join: fb in Bus, on: t.from_bus_id == fb.id,
      where: t.status == "in_service" and fb.interconnection_id == ^interconnection_id
        and not is_nil(t.from_bus_id) and not is_nil(t.to_bus_id),
      select: t
    )
    |> Repo.all()
  end

  def get_bus_branches(bus_id) do
    lines = from(tl in TransmissionLine,
      where: (tl.from_bus_id == ^bus_id or tl.to_bus_id == ^bus_id) and tl.status == "in_service"
    ) |> Repo.all()

    transformers = from(t in Transformer,
      where: (t.from_bus_id == ^bus_id or t.to_bus_id == ^bus_id) and t.status == "in_service"
    ) |> Repo.all()

    %{lines: lines, transformers: transformers}
  end

  @snapshot_cache_table :grid_snapshot_cache

  def get_grid_snapshot(interconnection_id) do
    # Check ETS cache first
    ensure_cache_table()

    case :ets.lookup(@snapshot_cache_table, interconnection_id) do
      [{^interconnection_id, snapshot, cached_at}] ->
        # Cache hit — use if less than 5 minutes old
        age_ms = System.monotonic_time(:millisecond) - cached_at
        if age_ms < 300_000 do
          snapshot
        else
          load_and_cache_snapshot(interconnection_id)
        end

      [] ->
        load_and_cache_snapshot(interconnection_id)
    end
  end

  defp ensure_cache_table do
    if :ets.whereis(@snapshot_cache_table) == :undefined do
      :ets.new(@snapshot_cache_table, [:named_table, :set, :public, read_concurrency: true])
    end
  end

  defp load_and_cache_snapshot(interconnection_id) do
    lines = in_service_lines(interconnection_id)
    transformers = in_service_transformers(interconnection_id)
    snapshot = build_snapshot_from_topology(lines, transformers)
    :ets.insert(@snapshot_cache_table, {interconnection_id, snapshot, System.monotonic_time(:millisecond)})
    snapshot
  end

  @doc "Clear the grid snapshot cache (call after data changes)"
  def clear_snapshot_cache do
    ensure_cache_table()
    :ets.delete_all_objects(@snapshot_cache_table)
  end

  def get_full_grid_snapshot do
    lines = from(tl in TransmissionLine,
      where: tl.status == "in_service" and not is_nil(tl.from_bus_id) and not is_nil(tl.to_bus_id)
    ) |> Repo.all()
    transformers = from(t in Transformer,
      where: t.status == "in_service" and not is_nil(t.from_bus_id) and not is_nil(t.to_bus_id)
    ) |> Repo.all()
    build_snapshot_from_topology(lines, transformers)
  end

  defp build_snapshot_from_topology(lines, transformers) do
    main_bus_ids = largest_connected_component(lines, transformers)
    main_list = MapSet.to_list(main_bus_ids)

    lines = Enum.filter(lines, fn l ->
      MapSet.member?(main_bus_ids, l.from_bus_id) and MapSet.member?(main_bus_ids, l.to_bus_id)
    end)
    transformers = Enum.filter(transformers, fn t ->
      MapSet.member?(main_bus_ids, t.from_bus_id) and MapSet.member?(main_bus_ids, t.to_bus_id)
    end)

    if main_list == [] do
      %{buses: [], lines: [], transformers: [], generators: [], loads: [], water_facilities: [], critical_facilities: []}
    else
      buses = from(b in Bus, where: b.id in ^main_list) |> Repo.all()
      generators = from(g in Generator,
        where: g.status == "in_service" and g.bus_id in ^main_list) |> Repo.all()
      loads = from(l in Load,
        where: l.status == "in_service" and l.bus_id in ^main_list) |> Repo.all()
      water_facilities = from(w in WaterFacility,
        where: w.status == "active" and w.bus_id in ^main_list) |> Repo.all()
      critical_facilities = from(cf in CriticalFacility,
        where: cf.status == "active" and cf.bus_id in ^main_list) |> Repo.all()

      %{
        buses: buses,
        lines: lines,
        transformers: transformers,
        generators: generators,
        loads: loads,
        water_facilities: water_facilities,
        critical_facilities: critical_facilities
      }
    end
  end

  def export_generators do
    from(g in Generator,
      where: g.status == "in_service" and not is_nil(g.coordinates),
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
      where: tl.status == "in_service",
      select: %{
        id: tl.id,
        geometry: tl.geometry,
        voltage_kv: tl.voltage_kv,
        rating_a_mva: tl.rating_a_mva,
        from_bus_id: tl.from_bus_id,
        to_bus_id: tl.to_bus_id
      }
    )
    |> Repo.all()
  end

  def export_substations do
    from(s in Substation,
      where: s.status == "in_service",
      select: %{
        id: s.id,
        coordinates: s.coordinates,
        max_voltage_kv: s.max_voltage_kv,
        name: s.name
      }
    )
    |> Repo.all()
  end

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
      [] -> MapSet.new()
      _ ->
        largest = Enum.max_by(components, &length/1)
        MapSet.new(largest)
    end
  end

  defp build_adjacency(lines, transformers) do
    adj = %{}

    adj = Enum.reduce(lines, adj, fn l, acc ->
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
        join: b in Bus, on: g.bus_id == b.id,
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

  @doc """
  Map each water facility to its nearest bus (within max_km).
  Creates a Load record for each facility with power_consumption_mw.
  Returns {mapped_count, load_count}.
  """
  def map_water_facilities_to_grid(opts \\ []) do
    max_km = Keyword.get(opts, :max_km, 20)
    max_meters = max_km * 1000

    facilities = from(w in WaterFacility,
      where: w.status == "active" and not is_nil(w.coordinates)
    ) |> Repo.all()

    mapped = Enum.reduce(facilities, {0, 0}, fn facility, {map_count, load_count} ->
      nearest = from(b in Bus,
        where: not is_nil(b.coordinates),
        where: fragment("ST_DWithin(?::geography, ?::geography, ?)",
          b.coordinates, ^facility.coordinates, ^max_meters),
        order_by: fragment("ST_Distance(?::geography, ?::geography)",
          b.coordinates, ^facility.coordinates),
        limit: 1
      ) |> Repo.one()

      case nearest do
        nil ->
          {map_count, load_count}
        bus ->
          facility
          |> Ecto.Changeset.change(%{bus_id: bus.id})
          |> Repo.update!()

          lc = if facility.power_consumption_mw && facility.power_consumption_mw > 0 do
            existing_load = from(l in Load, where: l.bus_id == ^bus.id) |> Repo.one()

            case existing_load do
              nil ->
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
  Get water facilities connected to a set of bus IDs.
  Used during cascade to determine which facilities lose power.
  """
  def get_water_facilities_for_buses(bus_ids) when is_list(bus_ids) do
    from(w in WaterFacility,
      where: w.bus_id in ^bus_ids and w.status == "active"
    ) |> Repo.all()
  end

  # --- Critical Facilities ---

  def list_critical_facilities(opts \\ []) do
    CriticalFacility
    |> maybe_filter_category(opts[:category])
    |> maybe_filter_cf_state(opts[:state])
    |> Repo.all()
  end

  def export_critical_facilities do
    from(cf in CriticalFacility,
      where: cf.status == "active" and not is_nil(cf.coordinates),
      select: %{
        id: cf.id,
        coordinates: cf.coordinates,
        name: cf.name,
        category: cf.category,
        facility_type: cf.facility_type,
        beds: cf.beds,
        trauma: cf.trauma,
        estimated_power_mw: cf.estimated_power_mw,
        bus_id: cf.bus_id
      }
    )
    |> Repo.all()
  end

  def get_critical_facilities_for_buses(bus_ids) when is_list(bus_ids) do
    from(cf in CriticalFacility,
      where: cf.bus_id in ^bus_ids and cf.status == "active"
    ) |> Repo.all()
  end

  def map_critical_facilities_to_grid(opts \\ []) do
    max_km = Keyword.get(opts, :max_km, 20)
    max_meters = max_km * 1000

    facilities = from(cf in CriticalFacility,
      where: cf.status == "active" and not is_nil(cf.coordinates)
    ) |> Repo.all()

    {mapped, loads} = Enum.reduce(facilities, {0, 0}, fn facility, {map_count, load_count} ->
      nearest = from(b in Bus,
        where: not is_nil(b.coordinates),
        where: fragment("ST_DWithin(?::geography, ?::geography, ?)",
          b.coordinates, ^facility.coordinates, ^max_meters),
        order_by: fragment("ST_Distance(?::geography, ?::geography)",
          b.coordinates, ^facility.coordinates),
        limit: 1
      ) |> Repo.one()

      case nearest do
        nil ->
          {map_count, load_count}
        bus ->
          facility
          |> Ecto.Changeset.change(%{bus_id: bus.id})
          |> Repo.update!()

          lc = if facility.estimated_power_mw && facility.estimated_power_mw > 0 do
            existing_load = from(l in Load, where: l.bus_id == ^bus.id) |> Repo.one()

            case existing_load do
              nil ->
                q_mvar = facility.estimated_power_mw * 0.3287
                %Load{}
                |> Load.changeset(%{
                  bus_id: bus.id,
                  p_mw: facility.estimated_power_mw,
                  q_mvar: q_mvar,
                  load_type: "constant_power",
                  status: "in_service"
                })
                |> Repo.insert!()
                1
              load ->
                new_p = load.p_mw + facility.estimated_power_mw
                new_q = (load.q_mvar || 0.0) + facility.estimated_power_mw * 0.3287
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

    {mapped, loads}
  end

  defp maybe_filter_category(query, nil), do: query
  defp maybe_filter_category(query, category) do
    from q in query, where: q.category == ^category
  end

  defp maybe_filter_cf_state(query, nil), do: query
  defp maybe_filter_cf_state(query, state) do
    from q in query, where: q.state == ^state
  end

  @doc """
  Get grid snapshot including water facilities for a geographic region.
  """
  def get_regional_grid_snapshot(bounds) do
    {west, south, east, north} = bounds

    buses = from(b in Bus,
      where: not is_nil(b.coordinates),
      where: fragment("ST_Within(?, ST_MakeEnvelope(?, ?, ?, ?, 4326))",
        b.coordinates, ^west, ^south, ^east, ^north)
    ) |> Repo.all()

    bus_ids = MapSet.new(buses, & &1.id)

    lines = from(tl in TransmissionLine,
      where: tl.status == "in_service" and not is_nil(tl.from_bus_id) and not is_nil(tl.to_bus_id),
      where: fragment("ST_Intersects(?, ST_MakeEnvelope(?, ?, ?, ?, 4326))",
        tl.geometry, ^west, ^south, ^east, ^north)
    ) |> Repo.all()

    extra_bus_ids = lines
    |> Enum.flat_map(fn l -> [l.from_bus_id, l.to_bus_id] end)
    |> Enum.reject(&MapSet.member?(bus_ids, &1))
    |> Enum.uniq()

    extra_buses = if extra_bus_ids != [] do
      from(b in Bus, where: b.id in ^extra_bus_ids) |> Repo.all()
    else
      []
    end

    all_buses = buses ++ extra_buses
    all_bus_ids = MapSet.new(all_buses, & &1.id)

    transformers = from(t in Transformer,
      where: t.status == "in_service",
      where: t.from_bus_id in ^MapSet.to_list(all_bus_ids) or t.to_bus_id in ^MapSet.to_list(all_bus_ids)
    ) |> Repo.all()

    generators = from(g in Generator,
      where: g.status == "in_service" and g.bus_id in ^MapSet.to_list(all_bus_ids)
    ) |> Repo.all()

    loads = from(l in Load,
      where: l.status == "in_service" and l.bus_id in ^MapSet.to_list(all_bus_ids)
    ) |> Repo.all()

    water_facilities = from(w in WaterFacility,
      where: w.status == "active" and w.bus_id in ^MapSet.to_list(all_bus_ids)
    ) |> Repo.all()

    critical_facilities = from(cf in CriticalFacility,
      where: cf.status == "active" and cf.bus_id in ^MapSet.to_list(all_bus_ids)
    ) |> Repo.all()

    %{
      buses: all_buses,
      lines: lines,
      transformers: transformers,
      generators: generators,
      loads: loads,
      water_facilities: water_facilities,
      critical_facilities: critical_facilities
    }
  end
end
