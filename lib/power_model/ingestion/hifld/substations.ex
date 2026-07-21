defmodule PowerModel.Ingestion.HIFLD.Substations do
  @moduledoc """
  Ingest substations from HIFLD data.

  Two modes:
  1. From shapefile (if available)
  2. Derived from transmission line endpoint data via the API
     (using SUB_1/SUB_2 fields and line endpoint coordinates)
  """

  alias PowerModel.Repo
  alias PowerModel.Grid.Substation
  alias PowerModel.Ingestion.HIFLD.API

  @service "Electric_Power_Transmission_Lines"

  @doc """
  Derive substations from transmission line API data.
  Groups lines by SUB_1/SUB_2 name and uses endpoint coordinates.
  """
  def derive_from_api do
    IO.puts("Deriving substations from transmission line endpoints...")

    # Collect substation name -> {coordinates, voltages} mapping
    sub_data =
      @service
      |> API.stream_features(fields: "SUB_1,SUB_2,VOLTAGE,VOLT_CLASS")
      |> Stream.flat_map(&extract_sub_refs/1)
      |> Enum.reduce(%{}, fn {name, lon, lat, voltage}, acc ->
        existing = Map.get(acc, name, %{lons: [], lats: [], voltages: []})

        Map.put(acc, name, %{
          lons: [lon | existing.lons],
          lats: [lat | existing.lats],
          voltages: if(voltage, do: [voltage | existing.voltages], else: existing.voltages)
        })
      end)

    IO.puts("Found #{map_size(sub_data)} unique substation references.")

    # Filter out UNKNOWN/TAP substations with no real name
    sub_data =
      sub_data
      |> Enum.reject(fn {name, _} ->
        is_nil(name) or name == "" or
          String.starts_with?(String.upcase(name), "UNKNOWN") or
          String.starts_with?(String.upcase(name), "TAP")
      end)
      |> Map.new()

    IO.puts("After filtering unknowns: #{map_size(sub_data)} substations.")

    counter = :counters.new(1, [:atomics])

    sub_data
    |> Enum.chunk_every(500)
    |> Enum.each(fn batch ->
      entries =
        Enum.map(batch, fn {name, data} ->
          build_substation(name, data)
        end)

      insert_batch(entries)
      :counters.add(counter, 1, length(batch))
      count = :counters.get(counter, 1)
      if rem(count, 2000) < 500, do: IO.puts("  #{count} substations inserted...")
    end)

    final = :counters.get(counter, 1)
    IO.puts("Inserted #{final} substations.")
    {:ok, final}
  end

  @doc """
  Ingest from local shapefile directory.
  """
  def ingest(path) do
    path
    |> read_shapefile()
    |> Flow.from_enumerable(max_demand: 100)
    |> Flow.map(&parse_substation/1)
    |> Flow.filter(& &1)
    |> Flow.map(&insert_substation/1)
    |> Flow.run()
  end

  # API derivation helpers

  defp extract_sub_refs(%{"attributes" => attrs, "geometry" => geom}) do
    paths = geom["paths"] || []
    voltage = parse_voltage(attrs["VOLTAGE"], attrs["VOLT_CLASS"])

    refs = []

    # SUB_1 -> first point of first path
    refs =
      case {attrs["SUB_1"], first_point(paths)} do
        {name, {lon, lat}} when is_binary(name) and name != "" ->
          [{name, lon, lat, voltage} | refs]

        _ ->
          refs
      end

    # SUB_2 -> last point of last path
    refs =
      case {attrs["SUB_2"], last_point(paths)} do
        {name, {lon, lat}} when is_binary(name) and name != "" ->
          [{name, lon, lat, voltage} | refs]

        _ ->
          refs
      end

    refs
  end

  defp extract_sub_refs(_), do: []

  defp first_point([]), do: nil

  defp first_point([path | _]) when is_list(path) do
    case path do
      [[lon, lat | _] | _] -> {lon, lat}
      _ -> nil
    end
  end

  defp first_point(_), do: nil

  defp last_point([]), do: nil

  defp last_point(paths) when is_list(paths) do
    path = List.last(paths)

    case List.last(path || []) do
      [lon, lat | _] -> {lon, lat}
      _ -> nil
    end
  end

  defp last_point(_), do: nil

  defp build_substation(name, data) do
    # Average coordinates across all references
    avg_lon = Enum.sum(data.lons) / length(data.lons)
    avg_lat = Enum.sum(data.lats) / length(data.lats)

    voltages = Enum.uniq(data.voltages) |> Enum.sort(:desc)
    max_kv = List.first(voltages)
    min_kv = List.last(voltages)

    # Use name as hifld_id since we don't have real HIFLD IDs
    hifld_id = name

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %{
      name: name,
      max_voltage_kv: max_kv,
      min_voltage_kv: if(min_kv != max_kv, do: min_kv, else: nil),
      coordinates: %Geo.Point{coordinates: {avg_lon, avg_lat}, srid: 4326},
      hifld_id: hifld_id,
      status: "in_service",
      inserted_at: now,
      updated_at: now
    }
  end

  defp insert_batch(entries) do
    Repo.insert_all(Substation, entries, on_conflict: :nothing, conflict_target: [:hifld_id])
  end

  # Shapefile support

  defp read_shapefile(path) do
    shp_path = Path.join(path, "Electric_Substations.shp")

    if File.exists?(shp_path) do
      Exshape.from_zip(shp_path)
    else
      zip_path = Path.join(path, "Electric_Substations.zip")

      if File.exists?(zip_path) do
        Exshape.from_zip(zip_path)
      else
        raise "Substation shapefile not found at #{path}"
      end
    end
  end

  defp parse_substation({shape, dbf_row}) do
    try do
      coords = extract_point(shape)
      name = get_field(dbf_row, "NAME") || get_field(dbf_row, "SUBSTATION") || "Unknown"
      max_kv = parse_float(get_field(dbf_row, "MAX_VOLT") || get_field(dbf_row, "VOLTAGE"))
      min_kv = parse_float(get_field(dbf_row, "MIN_VOLT"))
      hifld_id = to_string(get_field(dbf_row, "ID") || get_field(dbf_row, "OBJECTID"))

      if coords do
        %{
          name: String.trim(name),
          max_voltage_kv: max_kv,
          min_voltage_kv: min_kv,
          coordinates: coords,
          hifld_id: hifld_id,
          status: parse_status(get_field(dbf_row, "STATUS"))
        }
      end
    rescue
      _ -> nil
    end
  end

  defp insert_substation(nil), do: :ok

  defp insert_substation(attrs) do
    %Substation{}
    |> Substation.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:hifld_id])
  end

  defp extract_point(%Exshape.Shp.Point{x: lon, y: lat}) do
    %Geo.Point{coordinates: {lon, lat}, srid: 4326}
  end

  defp extract_point(_), do: nil

  defp get_field(row, field_name) when is_map(row) do
    Map.get(row, field_name) || Map.get(row, String.downcase(field_name))
  end

  defp get_field(_, _), do: nil

  defp parse_float(nil), do: nil
  defp parse_float(val) when is_number(val), do: val * 1.0

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_voltage(nil, volt_class), do: parse_volt_class(volt_class)
  defp parse_voltage(val, _) when is_number(val) and val > 0, do: val * 1.0

  defp parse_voltage(val, volt_class) when is_binary(val) do
    case Float.parse(String.trim(val)) do
      {f, _} when f > 0 -> f
      _ -> parse_volt_class(volt_class)
    end
  end

  defp parse_voltage(_, volt_class), do: parse_volt_class(volt_class)

  defp parse_volt_class(nil), do: nil

  defp parse_volt_class(val) when is_binary(val) do
    case Regex.run(~r/(\d+)\s*[-–]\s*(\d+)/, val) do
      [_, low, high] ->
        {l, _} = Integer.parse(low)
        {h, _} = Integer.parse(high)
        (l + h) / 2.0

      _ ->
        nil
    end
  end

  defp parse_volt_class(_), do: nil

  defp parse_status(nil), do: "in_service"

  defp parse_status(status) when is_binary(status) do
    normalized = status |> String.upcase() |> String.trim()

    if normalized in ["IN SERVICE", "ACTIVE", "OPERATIONAL"],
      do: "in_service",
      else: "out_of_service"
  end

  defp parse_status(_), do: "in_service"
end
