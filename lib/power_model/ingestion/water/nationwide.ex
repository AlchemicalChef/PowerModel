defmodule PowerModel.Ingestion.Water.Nationwide do
  @moduledoc """
  Ingest water infrastructure facilities from nationwide public APIs.

  Data sources:
    - EPA FRS: ~17,000 wastewater treatment plants
    - USACE NID: ~92,000 dams and reservoirs
    - EPA SDWIS: ~25,000 drinking water treatment systems
  """

  alias PowerModel.Repo
  alias PowerModel.Grid.WaterFacility

  @epa_wastewater_url "https://services.arcgis.com/XG15cJAlne2vxtgt/ArcGIS/rest/services/wastewater_treatment_plants_epa_frs/FeatureServer/0"
  @nid_url "https://geospatial.sec.usace.army.mil/dls/rest/services/NID/National_Inventory_of_Dams_Public_Service/FeatureServer/0"
  @drinking_water_url "https://services8.arcgis.com/rGGrs6HCnw87OFOT/arcgis/rest/services/Drinking_Water_Systems/FeatureServer/0"

  @page_size 2000
  @batch_size 500

  def ingest_all do
    IO.puts("=== Nationwide Water Infrastructure Ingestion ===\n")
    {:ok, ww} = ingest_epa_wastewater()
    {:ok, dams} = ingest_dams()
    {:ok, dw} = ingest_drinking_water()
    IO.puts("\n=== Complete: #{ww + dams + dw} total records ===")
    {:ok, ww + dams + dw}
  end

  # ---------------------------------------------------------------------------
  # EPA FRS Wastewater Treatment Plants (~17,000)
  # ---------------------------------------------------------------------------

  def ingest_epa_wastewater do
    IO.puts("--- EPA Wastewater Treatment Plants ---")
    ingest_from_api(@epa_wastewater_url, :wastewater, &parse_wastewater/1)
  end

  defp parse_wastewater(%{"attributes" => attrs, "geometry" => geom}) do
    lon = geom["x"]
    lat = geom["y"]

    if is_number(lon) and is_number(lat) and abs(lon) > 0.1 and abs(lat) > 0.1 do
      registry_id = attrs["REGISTRY_I"] || attrs["REGISTRY_ID"]
      is_major = attrs["CWP_MAJOR"] == "Y" or attrs["CWP_MAJOR"] == "MAJOR"
      capacity_mgd = if is_major, do: 10.0, else: 1.0

      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      %{
        name: parse_name(attrs["CWP_NAME"]),
        facility_type: "wastewater",
        coordinates: %Geo.Point{coordinates: {lon, lat}, srid: 4326},
        city: attrs["CWP_CITY"],
        county: attrs["CWP_COUNTY"],
        state: attrs["CWP_STATE"],
        owner: nil,
        status: parse_epa_status(attrs["CWP_STATUS"]),
        capacity_mgd: capacity_mgd,
        power_consumption_mw: capacity_mgd * 1.0,
        source: "epa",
        source_id: "epa_ww_#{registry_id}",
        inserted_at: now,
        updated_at: now
      }
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp parse_wastewater(_), do: nil

  # ---------------------------------------------------------------------------
  # USACE National Inventory of Dams (~92,000)
  # ---------------------------------------------------------------------------

  def ingest_dams do
    IO.puts("--- USACE National Inventory of Dams ---")
    ingest_from_api(@nid_url, :reservoir, &parse_dam/1)
  end

  defp parse_dam(%{"attributes" => attrs, "geometry" => geom}) do
    lon = geom && (geom["x"] || geom["longitude"])
    lat = geom && (geom["y"] || geom["latitude"])

    # NID sometimes has coords in attributes instead of geometry
    lon = lon || parse_float(attrs["LONGITUDE"])
    lat = lat || parse_float(attrs["LATITUDE"])

    if is_number(lon) and is_number(lat) and abs(lon) > 0.1 and abs(lat) > 0.1 do
      nid_id = attrs["NIDID"] || attrs["FID"] || attrs["OBJECTID"]

      storage =
        parse_float(attrs["NID_STORAGE"]) ||
          parse_float(attrs["NORMAL_STORAGE"]) ||
          parse_float(attrs["MAX_STORAGE"])

      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      %{
        name: parse_name(attrs["NAME"] || attrs["DAM_NAME"]),
        facility_type: "reservoir",
        coordinates: %Geo.Point{coordinates: {lon, lat}, srid: 4326},
        city: attrs["CITY"] || attrs["NEAREST_CITY"],
        county: attrs["COUNTY"] || parse_county(attrs["COUNTYSTATE"]),
        state: attrs["STATE"],
        owner: attrs["PRIMARY_OWNER_TYPE"] || attrs["OWNER_TYPES"],
        status: parse_dam_status(attrs["CONDITION_ASSESSMENT"]),
        capacity_mgd: nil,
        storage_acre_feet: storage,
        power_consumption_mw: 0.1,
        source: "usace_nid",
        source_id: "nid_#{nid_id}",
        inserted_at: now,
        updated_at: now
      }
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp parse_dam(_), do: nil

  # ---------------------------------------------------------------------------
  # EPA Drinking Water Systems (~25,000 community systems)
  # ---------------------------------------------------------------------------

  def ingest_drinking_water do
    IO.puts("--- EPA Drinking Water Systems ---")

    ingest_from_api(@drinking_water_url, :treatment, &parse_drinking_water/1,
      where: "WS_Type='COMM'"
    )
  end

  defp parse_drinking_water(%{"attributes" => attrs, "geometry" => geom}) do
    lon = geom["x"]
    lat = geom["y"]

    if is_number(lon) and is_number(lat) and abs(lon) > 0.1 and abs(lat) > 0.1 do
      pws_id = attrs["PwsId"] || attrs["PWSID"] || attrs["OBJECTID"]
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      %{
        name: parse_name(attrs["WS_Name"] || attrs["WS_NAME"]),
        facility_type: "treatment",
        coordinates: %Geo.Point{coordinates: {lon, lat}, srid: 4326},
        city: attrs["WS_City"] || attrs["WS_CITY"],
        county: attrs["County"] || attrs["COUNTY"],
        state: attrs["WS_State"] || attrs["WS_STATE"],
        owner: attrs["Ownership"] || attrs["OWNERSHIP"],
        status: "active",
        capacity_mgd: nil,
        power_consumption_mw: 0.5,
        source: "epa_sdwis",
        source_id: "sdwis_#{pws_id}",
        inserted_at: now,
        updated_at: now
      }
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp parse_drinking_water(_), do: nil

  # ---------------------------------------------------------------------------
  # Shared ArcGIS paginated streaming
  # ---------------------------------------------------------------------------

  defp ingest_from_api(base_url, _category, parser, opts \\ []) do
    where = Keyword.get(opts, :where, "1=1")
    counter = :counters.new(1, [:atomics])

    case get_count(base_url, where) do
      {:ok, total} -> IO.puts("  Records available: #{total}")
      _ -> :ok
    end

    stream_features(base_url, where)
    |> Stream.map(parser)
    |> Stream.reject(&is_nil/1)
    |> Stream.chunk_every(@batch_size)
    |> Stream.each(fn batch ->
      {inserted, _} =
        Repo.insert_all(WaterFacility, batch,
          on_conflict: :nothing,
          conflict_target: [:source, :source_id]
        )

      :counters.add(counter, 1, inserted)
      total = :counters.get(counter, 1)

      if rem(total, 2000) < @batch_size do
        IO.puts("  #{total} records inserted...")
      end
    end)
    |> Stream.run()

    total = :counters.get(counter, 1)
    IO.puts("  Done: #{total} records inserted.")
    {:ok, total}
  end

  defp get_count(base_url, where) do
    case Req.get("#{base_url}/query",
           params: [where: where, returnCountOnly: "true", f: "json"],
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: %{"count" => count}}} -> {:ok, count}
      {:ok, resp} -> {:error, resp.body}
      {:error, err} -> {:error, err}
    end
  end

  defp stream_features(base_url, where) do
    Stream.resource(
      fn -> 0 end,
      fn
        :done ->
          {:halt, :done}

        offset ->
          case fetch_page(base_url, where, offset) do
            {:ok, features, exceeded} ->
              next = if exceeded, do: offset + @page_size, else: :done
              {features, next}

            {:error, reason} ->
              IO.puts("  API error at offset #{offset}: #{inspect(reason)}")
              {:halt, :done}
          end
      end,
      fn _ -> :ok end
    )
  end

  defp fetch_page(base_url, where, offset) do
    params = [
      where: where,
      outFields: "*",
      f: "json",
      resultRecordCount: @page_size,
      resultOffset: offset,
      returnGeometry: "true",
      outSR: "4326"
    ]

    case Req.get("#{base_url}/query",
           params: params,
           receive_timeout: 120_000,
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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp parse_name(nil), do: "Unknown"

  defp parse_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> "Unknown"
      n -> n
    end
  end

  defp parse_name(_), do: "Unknown"

  defp parse_float(nil), do: nil
  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_integer(v), do: v * 1.0

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp parse_epa_status(nil), do: "active"

  defp parse_epa_status(status) when is_binary(status) do
    case String.upcase(String.trim(status)) do
      s when s in ["ACTIVE", "EFFECTIVE", "OPERATING"] -> "active"
      _ -> "inactive"
    end
  end

  defp parse_epa_status(_), do: "active"

  defp parse_dam_status(nil), do: "active"

  defp parse_dam_status(status) when is_binary(status) do
    case String.upcase(String.trim(status)) do
      s when s in ["SATISFACTORY", "FAIR", "GOOD"] -> "active"
      "NOT RATED" -> "active"
      _ -> "active"
    end
  end

  defp parse_dam_status(_), do: "active"

  defp parse_county(nil), do: nil

  defp parse_county(countystate) when is_binary(countystate) do
    case String.split(countystate, ",") do
      [county | _] -> String.trim(county)
      _ -> countystate
    end
  end

  defp parse_county(_), do: nil
end
