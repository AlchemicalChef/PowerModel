defmodule PowerModel.Ingestion.HIFLD.Substations do
  @moduledoc """
  Ingest substations from HIFLD data.

  Three modes:
  1. From shapefile (if available)
  2. Derived from transmission line endpoint data via the API
     (using SUB_1/SUB_2 fields and line endpoint coordinates)
  3. From Rutgers University HIFLD mirror (~8,700 real substation records)
  """

  require Logger

  alias PowerModel.Repo
  alias PowerModel.Grid.Substation
  alias PowerModel.Ingestion.HIFLD.API
  import Ecto.Query

  @service "Electric_Power_Transmission_Lines"

  @rutgers_url "https://oceandata.rad.rutgers.edu/arcgis/rest/services/RenewableEnergy/HIFLD_Electric_SubstationsTransmissionLines/MapServer/0/query"
  @rutgers_page_size 1000

  @doc """
  Derive substations from transmission line API data.
  Groups lines by SUB_1/SUB_2 name and uses endpoint coordinates.
  """
  def derive_from_api do
    IO.puts("Deriving substations from transmission line endpoints...")

    sub_data = @service
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

    sub_data = sub_data
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
      entries = Enum.map(batch, fn {name, data} ->
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
  Ingest substations from the Rutgers University HIFLD mirror.

  Fetches ~8,700 real substation records with metadata (name, voltages, type,
  status, city, state, county). Matches against existing derived substations
  by proximity (within 1km) and enriches them, or inserts new records.
  """
  def ingest_from_rutgers do
    Logger.info("Fetching substations from Rutgers HIFLD mirror...")

    features = fetch_all_rutgers_features()
    Logger.info("Fetched #{length(features)} substations from Rutgers mirror")

    existing = Repo.all(from s in Substation, select: {s.id, s.name, s.coordinates, s.hifld_id})
    Logger.info("Loaded #{length(existing)} existing substations for matching")

    spatial_index = build_spatial_index(existing)

    counter = :counters.new(2, [:atomics])

    features
    |> Enum.map(&parse_rutgers_feature/1)
    |> Enum.filter(& &1)
    |> Enum.chunk_every(500)
    |> Enum.each(fn batch ->
      Enum.each(batch, fn attrs ->
        case find_nearest_existing(attrs, spatial_index) do
          {:match, existing_id} ->
            enrich_existing(existing_id, attrs)
            :counters.add(counter, 1, 1)

          :no_match ->
            insert_new_rutgers(attrs)
            :counters.add(counter, 2, 1)
        end
      end)

      total = :counters.get(counter, 1) + :counters.get(counter, 2)
      if rem(total, 1000) < 500 do
        Logger.info("  processed #{total} (#{:counters.get(counter, 1)} enriched, #{:counters.get(counter, 2)} new)...")
      end
    end)

    updated = :counters.get(counter, 1)
    inserted = :counters.get(counter, 2)
    Logger.info("Rutgers import done: #{updated} enriched, #{inserted} new substations")
    {:ok, %{enriched: updated, inserted: inserted}}
  end

  defp fetch_all_rutgers_features do
    Stream.resource(
      fn -> 0 end,
      fn
        :done -> {:halt, :done}
        offset ->
          case fetch_rutgers_page(offset) do
            {:ok, features} when length(features) < @rutgers_page_size ->
              {features, :done}
            {:ok, features} ->
              {features, offset + @rutgers_page_size}
            {:error, reason} ->
              Logger.warning("Rutgers API error at offset #{offset}: #{inspect(reason)}")
              {:halt, :done}
          end
      end,
      fn _ -> :ok end
    )
    |> Enum.to_list()
  end

  defp fetch_rutgers_page(offset) do
    params = [
      where: "1=1",
      outFields: "NAME,CITY,STATE,ZIP,TYPE,STATUS,COUNTY,LATITUDE,LONGITUDE,NAICS_CODE,NAICS_DESC,SOURCE,LINES,MAX_VOLT,MIN_VOLT,MAX_INFER,MIN_INFER",
      f: "json",
      resultRecordCount: @rutgers_page_size,
      resultOffset: offset,
      returnGeometry: "true",
      outSR: "4326"
    ]

    case Req.get(@rutgers_url, params: params, receive_timeout: 60_000, retry: :transient, max_retries: 3) do
      {:ok, %{status: 200, body: %{"features" => features}}} when is_list(features) ->
        {:ok, features}
      {:ok, %{status: 200, body: %{"error" => error}}} ->
        {:error, error}
      {:ok, resp} ->
        {:error, "HTTP #{resp.status}"}
      {:error, err} ->
        {:error, err}
    end
  end

  defp parse_rutgers_feature(%{"attributes" => attrs, "geometry" => geom}) do
    lon = geom["x"] || parse_float_val(attrs["LONGITUDE"])
    lat = geom["y"] || parse_float_val(attrs["LATITUDE"])

    if is_number(lon) and is_number(lat) and abs(lat) > 0.1 do
      name = clean_name(attrs["NAME"])
      max_kv = parse_float_val(attrs["MAX_VOLT"]) || parse_float_val(attrs["MAX_INFER"])
      min_kv = parse_float_val(attrs["MIN_VOLT"]) || parse_float_val(attrs["MIN_INFER"])

      objectid = attrs["OBJECTID"] || attrs["FID"]
      hifld_id = if objectid, do: "rutgers_#{objectid}", else: "rutgers_#{name}"

      %{
        name: name || "Unknown",
        max_voltage_kv: max_kv,
        min_voltage_kv: if(min_kv && min_kv != max_kv, do: min_kv, else: nil),
        lon: lon,
        lat: lat,
        hifld_id: hifld_id,
        status: parse_status(attrs["STATUS"]),
        city: attrs["CITY"],
        state: attrs["STATE"],
        county: attrs["COUNTY"],
        type: attrs["TYPE"],
        lines: parse_int_val(attrs["LINES"]),
        source: attrs["SOURCE"]
      }
    end
  end
  defp parse_rutgers_feature(_), do: nil

  defp clean_name(nil), do: nil
  defp clean_name(name) when is_binary(name) do
    trimmed = String.trim(name)
    if trimmed == "" or String.upcase(trimmed) in ["UNKNOWN", "NOT AVAILABLE", "N/A"],
      do: nil,
      else: trimmed
  end

  defp parse_float_val(nil), do: nil
  defp parse_float_val(val) when is_number(val) and val > 0, do: val * 1.0
  defp parse_float_val(val) when is_binary(val) do
    case Float.parse(String.trim(val)) do
      {f, _} when f > 0 -> f
      _ -> nil
    end
  end
  defp parse_float_val(_), do: nil

  defp parse_int_val(nil), do: nil
  defp parse_int_val(val) when is_integer(val), do: val
  defp parse_int_val(val) when is_float(val), do: round(val)
  defp parse_int_val(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end
  defp parse_int_val(_), do: nil

  @grid_size 0.01

  defp build_spatial_index(substations) do
    Enum.reduce(substations, %{}, fn {id, name, coords, hifld_id}, acc ->
      case coords do
        %Geo.Point{coordinates: {lon, lat}} ->
          bucket = {trunc(lon / @grid_size), trunc(lat / @grid_size)}
          entry = %{id: id, name: name, lon: lon, lat: lat, hifld_id: hifld_id}
          Map.update(acc, bucket, [entry], &[entry | &1])
        _ ->
          acc
      end
    end)
  end

  defp find_nearest_existing(attrs, spatial_index) do
    bx = trunc(attrs.lon / @grid_size)
    by = trunc(attrs.lat / @grid_size)

    candidates =
      for dx <- -1..1, dy <- -1..1 do
        Map.get(spatial_index, {bx + dx, by + dy}, [])
      end
      |> List.flatten()

    case candidates do
      [] ->
        :no_match

      list ->
        best = Enum.min_by(list, fn sub ->
          haversine_approx(attrs.lon, attrs.lat, sub.lon, sub.lat)
        end)

        dist = haversine_approx(attrs.lon, attrs.lat, best.lon, best.lat)
        if dist < 1.0, do: {:match, best.id}, else: :no_match
    end
  end

  defp haversine_approx(lon1, lat1, lon2, lat2) do
    dlat = (lat2 - lat1) * 111.0
    dlon = (lon2 - lon1) * 111.0 * :math.cos(lat1 * :math.pi() / 180.0)
    :math.sqrt(dlat * dlat + dlon * dlon)
  end

  defp enrich_existing(substation_id, attrs) do
    updates =
      %{}
      |> maybe_put(:max_voltage_kv, attrs.max_voltage_kv)
      |> maybe_put(:min_voltage_kv, attrs.min_voltage_kv)

    updates = if attrs.name do
      sub = Repo.get(Substation, substation_id)
      if sub && sub.name == sub.hifld_id do
        Map.put(updates, :name, attrs.name)
      else
        updates
      end
    else
      updates
    end

    if map_size(updates) > 0 do
      from(s in Substation, where: s.id == ^substation_id)
      |> Repo.update_all(set: Enum.to_list(updates))
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp insert_new_rutgers(attrs) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entry = %{
      name: attrs.name || "Unknown",
      max_voltage_kv: attrs.max_voltage_kv,
      min_voltage_kv: attrs.min_voltage_kv,
      coordinates: %Geo.Point{coordinates: {attrs.lon, attrs.lat}, srid: 4326},
      hifld_id: attrs.hifld_id,
      status: attrs.status,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(Substation, [entry], on_conflict: :nothing, conflict_target: [:hifld_id])
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

  defp extract_sub_refs(%{"attributes" => attrs, "geometry" => geom}) do
    paths = geom["paths"] || []
    voltage = parse_voltage(attrs["VOLTAGE"], attrs["VOLT_CLASS"])

    refs = []

    refs = case {attrs["SUB_1"], first_point(paths)} do
      {name, {lon, lat}} when is_binary(name) and name != "" ->
        [{name, lon, lat, voltage} | refs]
      _ -> refs
    end

    refs = case {attrs["SUB_2"], last_point(paths)} do
      {name, {lon, lat}} when is_binary(name) and name != "" ->
        [{name, lon, lat, voltage} | refs]
      _ -> refs
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
    avg_lon = Enum.sum(data.lons) / length(data.lons)
    avg_lat = Enum.sum(data.lats) / length(data.lats)

    voltages = Enum.uniq(data.voltages) |> Enum.sort(:desc)
    max_kv = List.first(voltages)
    min_kv = List.last(voltages)

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
      _ -> nil
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
