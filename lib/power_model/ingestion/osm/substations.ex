defmodule PowerModel.Ingestion.OSM.Substations do
  @moduledoc """
  Ingest substations from OpenStreetMap via the Overpass API.

  Queries `power=substation` features across the continental US, state-by-state
  to avoid Overpass timeouts. Matches against existing substations by proximity
  (within 1km) and enriches them, or inserts new records.

  OSM voltage values are in volts (e.g., "345000;138000"), converted to kV.
  """

  require Logger

  alias PowerModel.Repo
  alias PowerModel.Grid.Substation
  import Ecto.Query

  @overpass_url "https://overpass-api.de/api/interpreter"
  @request_delay 5_000
  @grid_size 0.01

  @states ~w(
    AL AZ AR CA CO CT DE FL GA ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT
    NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY DC
  )

  @doc """
  Ingest substations from OpenStreetMap for all contiguous US states.

  Options:
    - `:states` — list of state codes to query (default: all 48 + DC)
  """
  def ingest(opts \\ []) do
    states = Keyword.get(opts, :states, @states)

    Logger.info("Ingesting OSM substations for #{length(states)} states...")

    existing = Repo.all(from s in Substation, select: {s.id, s.name, s.coordinates, s.hifld_id})
    Logger.info("Loaded #{length(existing)} existing substations for matching")

    spatial_index = build_spatial_index(existing)

    counter = :counters.new(3, [:atomics])

    Enum.each(states, fn state ->
      Logger.info("  Querying OSM for #{state}...")

      case fetch_state_substations(state) do
        {:ok, features} ->
          Logger.info("    #{length(features)} features from #{state}")

          features
          |> Enum.map(&parse_osm_feature/1)
          |> Enum.filter(& &1)
          |> Enum.each(fn attrs ->
            case find_nearest_existing(attrs, spatial_index) do
              {:match, existing_id} ->
                enrich_existing(existing_id, attrs)
                :counters.add(counter, 1, 1)

              :no_match ->
                insert_new_osm(attrs)
                :counters.add(counter, 2, 1)
            end
          end)

        {:error, reason} ->
          Logger.warning("    Failed for #{state}: #{inspect(reason)}")
          :counters.add(counter, 3, 1)
      end

      Process.sleep(@request_delay)
    end)

    enriched = :counters.get(counter, 1)
    inserted = :counters.get(counter, 2)
    failed_states = :counters.get(counter, 3)

    Logger.info("""
    OSM substation ingestion complete:
      Enriched: #{enriched}
      New: #{inserted}
      Failed states: #{failed_states}
      Total substations now: #{Repo.aggregate(Substation, :count)}
    """)

    {:ok, %{enriched: enriched, inserted: inserted, failed_states: failed_states}}
  end

  defp fetch_state_substations(state_code) do
    query = """
    [out:json][timeout:120];
    area["ISO3166-2"="US-#{state_code}"]->.state;
    (
      node["power"="substation"](area.state);
      way["power"="substation"](area.state);
      relation["power"="substation"](area.state);
    );
    out center tags;
    """

    case Req.post(@overpass_url,
           form: [data: query],
           receive_timeout: 180_000,
           retry: :transient,
           max_retries: 2,
           retry_delay: fn n -> n * 10_000 end) do
      {:ok, %{status: 200, body: %{"elements" => elements}}} when is_list(elements) ->
        {:ok, elements}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        if String.contains?(body, "rate_limited") or String.contains?(body, "too many requests") do
          Logger.warning("    Rate limited on #{state_code}, waiting 60s...")
          Process.sleep(60_000)
          fetch_state_substations(state_code)
        else
          {:error, "Unexpected response: #{String.slice(body, 0, 200)}"}
        end

      {:ok, %{status: 429}} ->
        Logger.warning("    429 rate limited on #{state_code}, waiting 60s...")
        Process.sleep(60_000)
        fetch_state_substations(state_code)

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body) |> String.slice(0, 200)}"}

      {:error, err} ->
        {:error, err}
    end
  end

  defp parse_osm_feature(%{"type" => type, "tags" => tags} = element) when is_map(tags) do
    {lon, lat} = extract_coordinates(type, element)

    if is_number(lon) and is_number(lat) and
       lat > 24.0 and lat < 50.0 and lon > -125.0 and lon < -66.0 do
      osm_id = element["id"]
      name = tags["name"] || tags["ref"] || tags["description"]
      operator = tags["operator"]
      voltage_str = tags["voltage"]
      substation_type = tags["substation"]

      {max_kv, min_kv} = parse_osm_voltage(voltage_str)

      %{
        name: clean_name(name, operator, osm_id),
        max_voltage_kv: max_kv,
        min_voltage_kv: if(min_kv && min_kv != max_kv, do: min_kv, else: nil),
        lon: lon,
        lat: lat,
        hifld_id: "osm_#{type}_#{osm_id}",
        operator: operator,
        substation_type: substation_type
      }
    end
  end
  defp parse_osm_feature(_), do: nil

  defp extract_coordinates("node", %{"lon" => lon, "lat" => lat}), do: {lon, lat}
  defp extract_coordinates(_, %{"center" => %{"lon" => lon, "lat" => lat}}), do: {lon, lat}
  defp extract_coordinates(_, _), do: {nil, nil}

  defp parse_osm_voltage(nil), do: {nil, nil}
  defp parse_osm_voltage(voltage_str) when is_binary(voltage_str) do
    voltages =
      voltage_str
      |> String.split(~r/[;,\/]/)
      |> Enum.map(&String.trim/1)
      |> Enum.map(fn v ->
        case Float.parse(v) do
          {f, _} when f > 100 -> f / 1000.0
          {f, _} when f > 0 -> f
          _ -> nil
        end
      end)
      |> Enum.filter(& &1)
      |> Enum.sort(:desc)

    case voltages do
      [] -> {nil, nil}
      [single] -> {single, nil}
      [max | rest] -> {max, List.last(rest)}
    end
  end
  defp parse_osm_voltage(_), do: {nil, nil}

  defp clean_name(nil, nil, osm_id), do: "OSM Substation #{osm_id}"
  defp clean_name(nil, operator, osm_id), do: "#{operator} Substation #{osm_id}"
  defp clean_name(name, _operator, _osm_id) when is_binary(name) do
    trimmed = String.trim(name)
    if trimmed == "", do: "OSM Substation (unnamed)", else: trimmed
  end

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

    updates = if attrs.name && not String.starts_with?(attrs.name, "OSM Substation") do
      sub = Repo.get(Substation, substation_id)
      if sub && (sub.name == sub.hifld_id or String.starts_with?(sub.name || "", "UNKNOWN")) do
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

  defp insert_new_osm(attrs) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entry = %{
      name: attrs.name,
      max_voltage_kv: attrs.max_voltage_kv,
      min_voltage_kv: attrs.min_voltage_kv,
      coordinates: %Geo.Point{coordinates: {attrs.lon, attrs.lat}, srid: 4326},
      hifld_id: attrs.hifld_id,
      status: "in_service",
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(Substation, [entry], on_conflict: :nothing, conflict_target: [:hifld_id])
  end

  @doc """
  Get statistics on OSM-sourced substations.
  """
  def stats do
    osm_count = Repo.one(from s in Substation, where: like(s.hifld_id, "osm_%"), select: count())
    with_voltage = Repo.one(from s in Substation,
      where: like(s.hifld_id, "osm_%") and not is_nil(s.max_voltage_kv),
      select: count())
    with_name = Repo.one(from s in Substation,
      where: like(s.hifld_id, "osm_%") and not like(s.name, "OSM Substation%"),
      select: count())

    %{
      total_osm: osm_count,
      with_voltage: with_voltage,
      with_name: with_name
    }
  end
end
