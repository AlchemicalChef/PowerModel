defmodule PowerModel.Ingestion.BusMapper do
  @moduledoc """
  Maps generators, transmission lines to buses via substations.

  Strategy:
  1. One bus per substation per voltage level
  2. Map generators to nearest substation bus (10km radius)
  3. Map transmission line endpoints via HIFLD SUB_1/SUB_2 + fallback to nearest
  4. Create transformers between voltage-level buses at multi-voltage substations
  """

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, Generator, TransmissionLine, Substation, Transformer}

  @gen_match_radius_m 10_000
  @line_match_radius_m 5_000

  def run do
    create_substation_buses()
    map_generators_to_buses()
    map_transmission_line_buses()
    create_substation_transformers()
  end

  defp create_substation_buses do
    substations = Repo.all(Substation)

    Enum.each(substations, fn sub ->
      voltage_levels = determine_voltage_levels(sub)

      Enum.each(voltage_levels, fn kv ->
        attrs = %{
          bus_type: 1,
          base_kv: kv,
          vm_pu: 1.0,
          va_rad: 0.0,
          coordinates: sub.coordinates,
          source: "substation",
          source_id: "#{sub.id}_#{round(kv)}kV",
          interconnection_id: determine_interconnection(sub.coordinates)
        }

        %Bus{}
        |> Bus.changeset(attrs)
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:source, :source_id])
      end)
    end)
  end

  defp determine_voltage_levels(sub) do
    levels = []
    levels = if sub.max_voltage_kv, do: [sub.max_voltage_kv | levels], else: levels
    levels = if sub.min_voltage_kv && sub.min_voltage_kv != sub.max_voltage_kv do
      [sub.min_voltage_kv | levels]
    else
      levels
    end

    case levels do
      [] -> [138.0]
      l -> l
    end
  end

  defp map_generators_to_buses do
    generators = from(g in Generator, where: is_nil(g.bus_id) and not is_nil(g.coordinates))
                 |> Repo.all()

    Enum.each(generators, fn gen ->
      nearest_bus = find_nearest_bus(gen.coordinates, @gen_match_radius_m)

      if nearest_bus do
        gen
        |> Ecto.Changeset.change(%{bus_id: nearest_bus.id})
        |> Repo.update()
      else
        {:ok, bus} = %Bus{}
        |> Bus.changeset(%{
          bus_type: 2,
          base_kv: 13.8,
          coordinates: gen.coordinates,
          source: "synthetic",
          source_id: "gen_#{gen.id}"
        })
        |> Repo.insert()

        gen
        |> Ecto.Changeset.change(%{bus_id: bus.id})
        |> Repo.update()
      end
    end)
  end

  defp map_transmission_line_buses do
    lines = from(tl in TransmissionLine,
      where: is_nil(tl.from_bus_id) or is_nil(tl.to_bus_id)
    ) |> Repo.all()

    Enum.each(lines, fn line ->
      from_point = get_line_endpoint(line.geometry, :from)
      to_point = get_line_endpoint(line.geometry, :to)

      from_bus = find_nearest_bus_at_voltage(from_point, line.voltage_kv, @line_match_radius_m)
      to_bus = find_nearest_bus_at_voltage(to_point, line.voltage_kv, @line_match_radius_m)

      changes = %{}
      changes = if from_bus, do: Map.put(changes, :from_bus_id, from_bus.id), else: changes
      changes = if to_bus, do: Map.put(changes, :to_bus_id, to_bus.id), else: changes

      if map_size(changes) > 0 do
        line
        |> Ecto.Changeset.change(changes)
        |> Repo.update()
      end
    end)
  end

  defp create_substation_transformers do
    buses_by_source = from(b in Bus,
      where: b.source == "substation",
      select: b
    ) |> Repo.all() |> Enum.group_by(fn b ->
      b.source_id |> String.split("_") |> List.first()
    end)

    Enum.each(buses_by_source, fn {_sub_id, buses} ->
      if length(buses) >= 2 do
        sorted = Enum.sort_by(buses, & &1.base_kv, :desc)
        sorted
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [high, low] ->
          rated_mva = estimate_transformer_rating(high.base_kv)

          %Transformer{}
          |> Transformer.changeset(%{
            from_bus_id: high.id,
            to_bus_id: low.id,
            rated_mva: rated_mva,
            r_pu: 0.003,
            x_pu: 0.1,
            tap_ratio: 1.0
          })
          |> Repo.insert(on_conflict: :nothing)
        end)
      end
    end)
  end

  defp find_nearest_bus(point, radius_m) do
    from(b in Bus,
      where: fragment("ST_DWithin(?::geography, ?::geography, ?)",
                       b.coordinates, ^point, ^radius_m),
      order_by: fragment("ST_Distance(?::geography, ?::geography)",
                          b.coordinates, ^point),
      limit: 1
    )
    |> Repo.one()
  end

  defp find_nearest_bus_at_voltage(nil, _kv, _radius), do: nil
  defp find_nearest_bus_at_voltage(point, voltage_kv, radius_m) do
    tolerance = voltage_kv * 0.1

    from(b in Bus,
      where: fragment("ST_DWithin(?::geography, ?::geography, ?)",
                       b.coordinates, ^point, ^radius_m)
             and b.base_kv >= ^(voltage_kv - tolerance)
             and b.base_kv <= ^(voltage_kv + tolerance),
      order_by: fragment("ST_Distance(?::geography, ?::geography)",
                          b.coordinates, ^point),
      limit: 1
    )
    |> Repo.one()
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

  defp determine_interconnection(nil), do: nil
  defp determine_interconnection(%Geo.Point{coordinates: {lon, lat}}) do
    cond do
      lat >= 25.8 and lat <= 36.5 and lon >= -104.0 and lon <= -93.5 ->
        get_or_create_interconnection("ERCOT")

      lon < -104.0 ->
        get_or_create_interconnection("Western")

      true ->
        get_or_create_interconnection("Eastern")
    end
  end
  defp determine_interconnection(_), do: nil

  defp get_or_create_interconnection(name) do
    alias PowerModel.Grid.Interconnection

    case Repo.get_by(Interconnection, name: name) do
      %{id: id} -> id
      nil ->
        {:ok, ic} = %Interconnection{}
        |> Interconnection.changeset(%{name: name})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:name])

        case ic.id do
          nil -> Repo.get_by!(Interconnection, name: name).id
          id -> id
        end
    end
  end

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
