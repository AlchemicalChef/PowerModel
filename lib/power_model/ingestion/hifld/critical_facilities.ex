defmodule PowerModel.Ingestion.HIFLD.CriticalFacilities do
  @moduledoc """
  Ingest critical infrastructure facilities from HIFLD ArcGIS REST APIs.

  Data sources:
    - Hospitals: FedMaps HIFLD (rich schema with BEDS, TRAUMA, HELIPAD)
    - Fire/EMS Stations: USGS Structures (via FiaPA4ga0iQKduv3)
    - Police/Law Enforcement: USGS Structures (via FiaPA4ga0iQKduv3)
  """

  alias PowerModel.Repo
  alias PowerModel.Grid.CriticalFacility

  @services %{
    hospital: %{
      url:
        "https://services2.arcgis.com/FiaPA4ga0iQKduv3/arcgis/rest/services/Hospitals/FeatureServer/0",
      parser: :hospital
    },
    fire_station: %{
      url:
        "https://services2.arcgis.com/FiaPA4ga0iQKduv3/arcgis/rest/services/Structures_Medical_Emergency_Response_v1/FeatureServer/2",
      parser: :structures
    },
    police_station: %{
      url:
        "https://services2.arcgis.com/FiaPA4ga0iQKduv3/arcgis/rest/services/Structures_Law_Enforcement_v1/FeatureServer/0",
      parser: :structures
    },
    ems_station: %{
      url:
        "https://services2.arcgis.com/FiaPA4ga0iQKduv3/arcgis/rest/services/Structures_Medical_Emergency_Response_v1/FeatureServer/1",
      parser: :structures
    }
  }

  @page_size 2000
  @batch_size 500

  def ingest_all do
    for {category, _} <- @services do
      ingest(category)
    end
  end

  def ingest(category) when is_atom(category) do
    %{url: base_url, parser: parser} = Map.fetch!(@services, category)
    counter = :counters.new(1, [:atomics])

    IO.puts("Fetching #{category} from #{base_url}...")

    case get_count(base_url) do
      {:ok, total} -> IO.puts("  Total records available: #{total}")
      _ -> :ok
    end

    stream_features(base_url)
    |> Stream.map(&parse_feature(&1, category, parser))
    |> Stream.reject(&is_nil/1)
    |> Stream.chunk_every(@batch_size)
    |> Stream.each(fn batch ->
      {inserted, _} =
        Repo.insert_all(CriticalFacility, batch,
          on_conflict: :nothing,
          conflict_target: [:source, :source_id]
        )

      :counters.add(counter, 1, inserted)
      total = :counters.get(counter, 1)

      if rem(total, 2000) < @batch_size do
        IO.puts("  #{category}: #{total} records inserted...")
      end
    end)
    |> Stream.run()

    total = :counters.get(counter, 1)
    IO.puts("  #{category}: #{total} total records inserted.")
    {:ok, total}
  end

  # --- Direct ArcGIS API (not using shared HIFLD.API since these are on different servers) ---

  defp get_count(base_url) do
    case Req.get("#{base_url}/query",
           params: [where: "1=1", returnCountOnly: "true", f: "json"],
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: %{"count" => count}}} -> {:ok, count}
      {:ok, resp} -> {:error, resp.body}
      {:error, err} -> {:error, err}
    end
  end

  defp stream_features(base_url) do
    Stream.resource(
      fn -> 0 end,
      fn
        :done ->
          {:halt, :done}

        offset ->
          case fetch_page(base_url, offset) do
            {:ok, features, exceeded_limit} ->
              next = if exceeded_limit, do: offset + @page_size, else: :done
              {features, next}

            {:error, reason} ->
              IO.puts("  API error at offset #{offset}: #{inspect(reason)}")
              {:halt, :done}
          end
      end,
      fn _ -> :ok end
    )
  end

  defp fetch_page(base_url, offset) do
    params = [
      where: "1=1",
      outFields: "*",
      f: "json",
      resultRecordCount: @page_size,
      resultOffset: offset,
      returnGeometry: "true",
      outSR: "4326"
    ]

    case Req.get("#{base_url}/query",
           params: params,
           receive_timeout: 60_000,
           retry: :transient,
           max_retries: 3
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        if body["error"] do
          {:error, body["error"]}
        else
          features = body["features"] || []
          exceeded = body["exceededTransferLimit"] == true
          {:ok, features, exceeded}
        end

      {:ok, resp} ->
        {:error, "HTTP #{resp.status}"}

      {:error, err} ->
        {:error, err}
    end
  end

  # --- Parsers ---

  # Hospital parser: rich schema with BEDS, TRAUMA, HELIPAD, OWNER, TYPE
  defp parse_feature(%{"attributes" => attrs, "geometry" => geom}, category, :hospital) do
    lon = geom["x"]
    lat = geom["y"]

    if is_number(lon) and is_number(lat) do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      object_id = attrs["FID"] || attrs["OBJECTID"]

      %{
        name: parse_name(attrs["NAME"]),
        category: Atom.to_string(category),
        facility_type: attrs["TYPE"],
        coordinates: %Geo.Point{coordinates: {lon, lat}, srid: 4326},
        address: attrs["ADDRESS"],
        city: attrs["CITY"],
        county: attrs["COUNTY"],
        state: attrs["STATE"],
        zip: parse_zip(attrs["ZIP"]),
        owner: attrs["OWNER"],
        status: parse_status(attrs["STATUS"]),
        beds: parse_int(attrs["BEDS"]),
        trauma: parse_trauma(attrs["TRAUMA"]),
        helipad: attrs["HELIPAD"] == "Y",
        total_staff: parse_int(attrs["TTL_STAFF"]),
        estimated_power_mw: estimate_power(category, attrs),
        source: "hifld",
        source_id: "#{category}_#{object_id}",
        inserted_at: now,
        updated_at: now
      }
    else
      nil
    end
  rescue
    _ -> nil
  end

  # USGS Structures parser: shared schema for fire, police, EMS
  defp parse_feature(%{"attributes" => attrs, "geometry" => geom}, category, :structures) do
    lon = geom["x"]
    lat = geom["y"]

    if is_number(lon) and is_number(lat) do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      object_id = attrs["OBJECTID"] || attrs["PERMANENT_IDENTIFIER"]

      %{
        name: parse_name(attrs["NAME"]),
        category: Atom.to_string(category),
        facility_type: fcode_to_type(attrs["FCODE"], category),
        coordinates: %Geo.Point{coordinates: {lon, lat}, srid: 4326},
        address: attrs["ADDRESS"],
        city: attrs["CITY"],
        county: nil,
        state: attrs["STATE"],
        zip: parse_zip(attrs["ZIPCODE"]),
        owner: nil,
        status: "active",
        estimated_power_mw: estimate_power(category, attrs),
        source: "hifld",
        source_id: "#{category}_#{object_id}",
        inserted_at: now,
        updated_at: now
      }
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp parse_feature(_, _, _), do: nil

  # Category is authoritative since we query from distinct layers/services.
  # FCODE sub-typing only within the correct category context.
  defp fcode_to_type(_, :fire_station), do: "Fire Station"
  defp fcode_to_type(_, :ems_station), do: "EMS Station"
  defp fcode_to_type(74027, :police_station), do: "Sheriff"
  defp fcode_to_type(_, :police_station), do: "Police Station"
  defp fcode_to_type(_, _), do: nil

  defp parse_name(nil), do: "Unknown"

  defp parse_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> "Unknown"
      n -> n
    end
  end

  defp parse_name(_), do: "Unknown"

  defp parse_zip(nil), do: nil
  defp parse_zip(zip) when is_binary(zip), do: String.trim(zip)

  defp parse_zip(zip) when is_number(zip),
    do: zip |> round() |> Integer.to_string() |> String.pad_leading(5, "0")

  defp parse_zip(_), do: nil

  defp parse_status(nil), do: "active"

  defp parse_status(status) when is_binary(status) do
    case String.upcase(String.trim(status)) do
      s when s in ["OPEN", "ACTIVE", "IN SERVICE"] -> "active"
      s when s in ["CLOSED", "INACTIVE", "OUT OF SERVICE"] -> "inactive"
      _ -> "active"
    end
  end

  defp parse_status(_), do: "active"

  defp parse_trauma(nil), do: nil
  defp parse_trauma("NOT AVAILABLE"), do: nil
  defp parse_trauma(t) when is_binary(t), do: String.trim(t)
  defp parse_trauma(_), do: nil

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_integer(v) and v >= 0, do: v
  defp parse_int(v) when is_float(v) and v >= 0, do: round(v)

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp estimate_power(:hospital, attrs) do
    beds = parse_int(attrs["BEDS"]) || 100
    beds * 0.008
  end

  defp estimate_power(:fire_station, _attrs), do: 0.05
  defp estimate_power(:police_station, _attrs), do: 0.08
  defp estimate_power(:ems_station, _attrs), do: 0.04
end
