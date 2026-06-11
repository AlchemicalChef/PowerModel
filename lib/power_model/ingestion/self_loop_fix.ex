defmodule PowerModel.Ingestion.SelfLoopFix do
  @moduledoc """
  Fix self-loop transmission lines (from_bus_id == to_bus_id).

  Steps:
  1. Create buses for any substations that don't have buses yet (new OSM substations)
  2. Clear bus assignments on self-loop lines
  3. Re-map endpoints with a self-loop guard: if both endpoints resolve to the
     same bus, find the second-nearest bus for the endpoint farther from that bus.
  """

  require Logger

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, TransmissionLine, Substation, Interconnection}

  @line_match_radius_m 10_000

  def run do
    Logger.info("=== Self-Loop Fix ===")

    create_missing_substation_buses()

    self_loop_count = count_self_loops()
    Logger.info("Self-loops before fix: #{self_loop_count}")

    clear_self_loop_assignments()
    remap_self_loop_lines()

    remaining = count_self_loops()
    fixed = self_loop_count - remaining
    Logger.info("=== Fix Complete ===")
    Logger.info("Fixed: #{fixed}, Remaining: #{remaining}")
    {:ok, %{before: self_loop_count, fixed: fixed, remaining: remaining}}
  end

  defp count_self_loops do
    Repo.one(
      from tl in TransmissionLine,
        where: not is_nil(tl.from_bus_id) and tl.from_bus_id == tl.to_bus_id,
        select: count()
    )
  end

  defp create_missing_substation_buses do
    existing_source_ids =
      from(b in Bus, where: b.source == "substation", select: b.source_id)
      |> Repo.all()
      |> MapSet.new()

    substations = Repo.all(Substation)

    missing =
      Enum.filter(substations, fn sub ->
        voltage_levels = determine_voltage_levels(sub)

        Enum.any?(voltage_levels, fn kv ->
          source_id = "#{sub.id}_#{round(kv)}kV"
          not MapSet.member?(existing_source_ids, source_id)
        end)
      end)

    Logger.info("Creating buses for #{length(missing)} substations without buses...")

    counter = :counters.new(1, [:atomics])

    missing
    |> Enum.chunk_every(1000)
    |> Enum.each(fn batch ->
      entries =
        Enum.flat_map(batch, fn sub ->
          voltage_levels = determine_voltage_levels(sub)
          ic_id = determine_interconnection(sub.coordinates)
          now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

          Enum.filter(voltage_levels, fn kv ->
            not MapSet.member?(existing_source_ids, "#{sub.id}_#{round(kv)}kV")
          end)
          |> Enum.map(fn kv ->
            %{
              bus_type: 1,
              base_kv: kv,
              vm_pu: 1.0,
              va_rad: 0.0,
              coordinates: sub.coordinates,
              source: "substation",
              source_id: "#{sub.id}_#{round(kv)}kV",
              interconnection_id: ic_id,
              inserted_at: now,
              updated_at: now
            }
          end)
        end)

      if length(entries) > 0 do
        Repo.insert_all(Bus, entries,
          on_conflict: :nothing,
          conflict_target: [:source, :source_id]
        )
      end

      :counters.add(counter, 1, length(entries))
      count = :counters.get(counter, 1)
      if rem(count, 10_000) < 1000, do: Logger.info("  #{count} buses created...")
    end)

    new_bus_count = :counters.get(counter, 1)
    total_buses = Repo.aggregate(Bus, :count)
    Logger.info("Created #{new_bus_count} new buses. Total buses: #{total_buses}")
  end

  defp clear_self_loop_assignments do
    {count, _} =
      from(tl in TransmissionLine,
        where: not is_nil(tl.from_bus_id) and tl.from_bus_id == tl.to_bus_id
      )
      |> Repo.update_all(set: [from_bus_id: nil, to_bus_id: nil])

    Logger.info("Cleared bus assignments on #{count} self-loop lines")
  end

  defp remap_self_loop_lines do
    lines =
      from(tl in TransmissionLine,
        where: is_nil(tl.from_bus_id) and is_nil(tl.to_bus_id) and not is_nil(tl.geometry),
        select: %{id: tl.id, voltage_kv: tl.voltage_kv, geometry: tl.geometry}
      )
      |> Repo.all()

    Logger.info("Re-mapping #{length(lines)} lines...")

    counter = :counters.new(3, [:atomics])

    lines
    |> Enum.chunk_every(500)
    |> Enum.each(fn batch ->
      Enum.each(batch, fn line ->
        from_point = get_line_endpoint(line.geometry, :from)
        to_point = get_line_endpoint(line.geometry, :to)

        from_bus = find_nearest_bus_at_voltage(from_point, line.voltage_kv, @line_match_radius_m)
        to_bus = find_nearest_bus_at_voltage(to_point, line.voltage_kv, @line_match_radius_m)

        {from_bus, to_bus} =
          resolve_self_loop(from_bus, to_bus, from_point, to_point, line.voltage_kv)

        cond do
          from_bus && to_bus && from_bus.id != to_bus.id ->
            from(tl in TransmissionLine, where: tl.id == ^line.id)
            |> Repo.update_all(set: [from_bus_id: from_bus.id, to_bus_id: to_bus.id])

            :counters.add(counter, 1, 1)

          from_bus && to_bus ->
            from(tl in TransmissionLine, where: tl.id == ^line.id)
            |> Repo.update_all(set: [from_bus_id: from_bus.id, to_bus_id: to_bus.id])

            :counters.add(counter, 2, 1)

          true ->
            changes = []
            changes = if from_bus, do: [from_bus_id: from_bus.id] ++ changes, else: changes
            changes = if to_bus, do: [to_bus_id: to_bus.id] ++ changes, else: changes

            if length(changes) > 0 do
              from(tl in TransmissionLine, where: tl.id == ^line.id)
              |> Repo.update_all(set: changes)
            end

            :counters.add(counter, 3, 1)
        end
      end)

      total = :counters.get(counter, 1) + :counters.get(counter, 2) + :counters.get(counter, 3)

      if rem(total, 5000) < 500 do
        Logger.info(
          "  #{total}/#{length(lines)} — fixed: #{:counters.get(counter, 1)}, still loops: #{:counters.get(counter, 2)}, unmapped: #{:counters.get(counter, 3)}"
        )
      end
    end)

    Logger.info(
      "Mapping results: fixed=#{:counters.get(counter, 1)}, still_loops=#{:counters.get(counter, 2)}, unmapped=#{:counters.get(counter, 3)}"
    )
  end

  defp resolve_self_loop(nil, _, _, _, _), do: {nil, nil}
  defp resolve_self_loop(_, nil, _, _, _), do: {nil, nil}

  defp resolve_self_loop(from_bus, to_bus, from_point, to_point, voltage_kv)
       when from_bus.id == to_bus.id do
    from_dist = point_distance(from_point, from_bus.coordinates)
    to_dist = point_distance(to_point, to_bus.coordinates)

    if from_dist > to_dist do
      case find_second_nearest_bus(from_point, voltage_kv, from_bus.id) do
        nil -> {from_bus, to_bus}
        alt -> {alt, to_bus}
      end
    else
      case find_second_nearest_bus(to_point, voltage_kv, to_bus.id) do
        nil -> {from_bus, to_bus}
        alt -> {from_bus, alt}
      end
    end
  end

  defp resolve_self_loop(from_bus, to_bus, _, _, _), do: {from_bus, to_bus}

  defp find_second_nearest_bus(nil, _kv, _exclude), do: nil

  defp find_second_nearest_bus(point, voltage_kv, exclude_bus_id) do
    tolerance = voltage_kv * 0.1

    from(b in Bus,
      where:
        fragment(
          "ST_DWithin(?::geography, ?::geography, ?)",
          b.coordinates,
          ^point,
          ^@line_match_radius_m
        ) and
          b.base_kv >= ^(voltage_kv - tolerance) and
          b.base_kv <= ^(voltage_kv + tolerance) and
          b.id != ^exclude_bus_id,
      order_by: fragment("ST_Distance(?::geography, ?::geography)", b.coordinates, ^point),
      limit: 1
    )
    |> Repo.one()
  end

  defp find_nearest_bus_at_voltage(nil, _kv, _radius), do: nil

  defp find_nearest_bus_at_voltage(point, voltage_kv, radius_m) do
    tolerance = voltage_kv * 0.1

    from(b in Bus,
      where:
        fragment("ST_DWithin(?::geography, ?::geography, ?)", b.coordinates, ^point, ^radius_m) and
          b.base_kv >= ^(voltage_kv - tolerance) and
          b.base_kv <= ^(voltage_kv + tolerance),
      order_by: fragment("ST_Distance(?::geography, ?::geography)", b.coordinates, ^point),
      limit: 1
    )
    |> Repo.one()
  end

  defp point_distance(nil, _), do: 999_999.0
  defp point_distance(_, nil), do: 999_999.0

  defp point_distance(%Geo.Point{coordinates: {lon1, lat1}}, %Geo.Point{coordinates: {lon2, lat2}}) do
    dlat = (lat2 - lat1) * 111.0
    dlon = (lon2 - lon1) * 111.0 * :math.cos(lat1 * :math.pi() / 180.0)
    :math.sqrt(dlat * dlat + dlon * dlon)
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

  defp determine_voltage_levels(sub) do
    levels = []
    levels = if sub.max_voltage_kv, do: [sub.max_voltage_kv | levels], else: levels

    levels =
      if sub.min_voltage_kv && sub.min_voltage_kv != sub.max_voltage_kv do
        [sub.min_voltage_kv | levels]
      else
        levels
      end

    case levels do
      [] -> [138.0]
      l -> l
    end
  end

  defp determine_interconnection(nil), do: nil

  defp determine_interconnection(%Geo.Point{coordinates: {lon, lat}}) do
    cond do
      lat >= 25.8 and lat <= 36.5 and lon >= -104.0 and lon <= -93.5 ->
        get_ic_id("ERCOT")

      lon < -104.0 ->
        get_ic_id("Western")

      true ->
        get_ic_id("Eastern")
    end
  end

  defp determine_interconnection(_), do: nil

  defp get_ic_id(name) do
    case Repo.get_by(Interconnection, name: name) do
      %{id: id} -> id
      nil -> nil
    end
  end
end
