defmodule PowerModel.Ingestion.Cleanup do
  @moduledoc """
  Re-map synthetic/demo components to real substation buses.

  Generators on synthetic buses get moved to the nearest real substation bus.
  Remaining generators that can't find a substation bus get a tie-line created.
  Unmapped transmission lines get a wider-radius endpoint search.
  Orphaned synthetic buses get deleted.
  """

  require Logger

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, Generator, TransmissionLine, Transformer}

  @gen_remap_radius_m 100_000

  @line_remap_radius_m 50_000

  @voltage_tolerance 0.20

  def run do
    Logger.info("=== Cleanup: Re-mapping synthetic components to real ones ===\n")
    remap_generators()
    remap_unmapped_lines()
    connect_isolated_generators()
    cleanup_orphaned_buses()
    Logger.info("\n=== Cleanup complete ===")
  end

  @doc """
  Move generators from synthetic buses to nearest real substation bus.
  """
  def remap_generators do
    gens_on_synth = Repo.all(
      from g in Generator,
        join: b in Bus, on: g.bus_id == b.id,
        where: b.source == "synthetic" and g.status == "in_service",
        preload: [bus: b]
    )

    Logger.info("Generators on synthetic buses: #{length(gens_on_synth)}")

    {remapped, kept} =
      Enum.reduce(gens_on_synth, {0, 0}, fn gen, {ok, skip} ->
        point = gen.bus.coordinates || gen.coordinates

        if point do
          case find_nearest_substation_bus(point, @gen_remap_radius_m) do
            nil ->
              {ok, skip + 1}
            bus ->
              gen
              |> Ecto.Changeset.change(%{bus_id: bus.id})
              |> Repo.update!()
              {ok + 1, skip}
          end
        else
          {ok, skip + 1}
        end
      end)

    Logger.info("  Remapped to substation buses: #{remapped}")
    Logger.info("  Could not remap (no substation within #{div(@gen_remap_radius_m, 1000)}km): #{kept}")
  end

  @doc """
  Re-map transmission line endpoints that have nil bus IDs.
  Uses wider radius and falls back to any-voltage bus.
  """
  def remap_unmapped_lines do
    lines = Repo.all(
      from l in TransmissionLine,
        where: l.status == "in_service" and (is_nil(l.from_bus_id) or is_nil(l.to_bus_id))
    )

    Logger.info("\nUnmapped lines: #{length(lines)}")

    {mapped_from, mapped_to, still_unmapped} =
      Enum.reduce(lines, {0, 0, 0}, fn line, {mf, mt, um} ->
        changes = %{}

        changes = if is_nil(line.from_bus_id) do
          from_point = get_line_endpoint(line.geometry, :from)
          case find_bus_for_line(from_point, line.voltage_kv) do
            nil -> changes
            bus -> Map.put(changes, :from_bus_id, bus.id)
          end
        else
          changes
        end

        changes = if is_nil(line.to_bus_id) do
          to_point = get_line_endpoint(line.geometry, :to)
          case find_bus_for_line(to_point, line.voltage_kv) do
            nil -> changes
            bus -> Map.put(changes, :to_bus_id, bus.id)
          end
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

    Logger.info("  From-bus mapped: #{mapped_from}")
    Logger.info("  To-bus mapped: #{mapped_to}")
    Logger.info("  Still unmapped: #{still_unmapped}")
  end

  @doc """
  For generators still on synthetic buses (couldn't remap), create a short
  tie-line from their synthetic bus to the nearest real substation bus.
  This connects them electrically to the grid.
  """
  def connect_isolated_generators do
    synth_buses = Repo.all(
      from b in Bus,
        join: g in Generator, on: g.bus_id == b.id,
        left_join: l1 in TransmissionLine, on: l1.from_bus_id == b.id,
        left_join: l2 in TransmissionLine, on: l2.to_bus_id == b.id,
        where: b.source == "synthetic" and g.status == "in_service"
          and is_nil(l1.id) and is_nil(l2.id),
        distinct: b.id,
        select: b
    )

    Logger.info("\nIsolated synthetic buses with generators: #{length(synth_buses)}")

    connected =
      Enum.reduce(synth_buses, 0, fn bus, count ->
        case find_nearest_substation_bus(bus.coordinates, @gen_remap_radius_m) do
          nil -> count
          target_bus ->
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

    Logger.info("  Connected via tie-lines: #{connected}")
  end

  @doc """
  Delete synthetic buses that have no generators, no lines, and no loads.
  """
  def cleanup_orphaned_buses do
    orphaned = Repo.all(
      from b in Bus,
        left_join: g in Generator, on: g.bus_id == b.id,
        left_join: l1 in TransmissionLine, on: l1.from_bus_id == b.id,
        left_join: l2 in TransmissionLine, on: l2.to_bus_id == b.id,
        left_join: t1 in Transformer, on: t1.from_bus_id == b.id,
        left_join: t2 in Transformer, on: t2.to_bus_id == b.id,
        where: b.source == "synthetic"
          and is_nil(g.id) and is_nil(l1.id) and is_nil(l2.id)
          and is_nil(t1.id) and is_nil(t2.id),
        select: b.id
    )

    Logger.info("\nOrphaned synthetic buses (no references): #{length(orphaned)}")

    if length(orphaned) > 0 do
      {deleted, _} = Repo.delete_all(from b in Bus, where: b.id in ^orphaned)
      Logger.info("  Deleted: #{deleted}")
    end
  end

  defp find_nearest_substation_bus(nil, _radius), do: nil
  defp find_nearest_substation_bus(point, radius_m) do
    Repo.one(
      from b in Bus,
        where: b.source == "substation"
          and fragment("ST_DWithin(?::geography, ?::geography, ?)",
                       b.coordinates, ^point, ^radius_m),
        order_by: fragment("ST_Distance(?::geography, ?::geography)",
                            b.coordinates, ^point),
        limit: 1
    )
  end

  defp find_bus_for_line(nil, _kv), do: nil
  defp find_bus_for_line(point, voltage_kv) do
    tolerance = voltage_kv * @voltage_tolerance

    result = Repo.one(
      from b in Bus,
        where: b.source == "substation"
          and fragment("ST_DWithin(?::geography, ?::geography, ?)",
                       b.coordinates, ^point, ^@line_remap_radius_m)
          and b.base_kv >= ^(voltage_kv - tolerance)
          and b.base_kv <= ^(voltage_kv + tolerance),
        order_by: fragment("ST_Distance(?::geography, ?::geography)",
                            b.coordinates, ^point),
        limit: 1
    )

    result || Repo.one(
      from b in Bus,
        where: fragment("ST_DWithin(?::geography, ?::geography, ?)",
                         b.coordinates, ^point, ^@line_remap_radius_m)
               and b.base_kv >= ^(voltage_kv - tolerance)
               and b.base_kv <= ^(voltage_kv + tolerance),
        order_by: fragment("ST_Distance(?::geography, ?::geography)",
                            b.coordinates, ^point),
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
    a = :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(lat1_r) * :math.cos(lat2_r) *
        :math.sin(dlon / 2) * :math.sin(dlon / 2)
    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    Float.round(r * c, 2)
  end
  defp haversine_km(_, _), do: 10.0

  defp line_params_for_voltage(voltage_kv, length_km) do
    base_mva = 100.0
    z_base = voltage_kv * voltage_kv / base_mva

    {r_per_km, x_per_km, _b_per_km, rating} = cond do
      voltage_kv >= 500 -> {0.010, 0.300, 4.0, 1800.0}
      voltage_kv >= 345 -> {0.020, 0.335, 3.6, 900.0}
      voltage_kv >= 230 -> {0.040, 0.370, 3.3, 450.0}
      voltage_kv >= 138 -> {0.075, 0.400, 3.0, 250.0}
      voltage_kv >= 69  -> {0.170, 0.450, 2.7, 130.0}
      true              -> {0.200, 0.500, 2.5, 100.0}
    end

    r_pu = r_per_km * length_km / z_base
    x_pu = x_per_km * length_km / z_base
    x_pu = max(x_pu, 0.001)
    {Float.round(r_pu, 6), Float.round(x_pu, 6), 0.0, rating}
  end
end
