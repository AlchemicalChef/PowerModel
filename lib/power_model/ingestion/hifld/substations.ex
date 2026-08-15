defmodule PowerModel.Ingestion.HIFLD.Substations do
  @moduledoc """
  Ingest substations from HIFLD data.

  Two modes:
  1. From shapefile (if available)
  2. Derived from transmission line endpoint data via the API
     (using SUB_1/SUB_2 fields and line endpoint coordinates)

  ## Substation identity (API-derived mode)

  HIFLD substation names are NOT unique nationally (e.g. "MIDWAY" names
  endpoints thousands of km apart), so identity is `name + geographic
  cluster`: endpoints sharing a name are grouped with a ~5 km union-find
  clustering pass, and each cluster becomes its own substation with
  `hifld_id = "NAME@lat,lon"` (cluster centroid, 2 decimals).

  Sentinel names ("NOT AVAILABLE", "NONE", "DEADHEAD", and UNKNOWN*/TAP*
  prefixes) carry no identity at all, so they are never merged by name;
  each such endpoint gets a per-endpoint coordinate-derived id
  (`"NAME@lat,lon"` at 3 decimals, ~110 m).

  > #### Re-ingest note {: .warning}
  > The `hifld_id` format changed from the bare name to `NAME@lat,lon`.
  > Re-ingesting into an existing database creates the corrected clustered
  > substations ALONGSIDE previously ingested name-keyed rows (the upsert
  > key no longer matches). A cleanup pass for the old rows is out of scope
  > here — re-ingest into a fresh database, or delete substations whose
  > `hifld_id` does not contain `"@"` before re-deriving.
  """

  alias PowerModel.Repo
  alias PowerModel.Grid.Substation
  alias PowerModel.Ingestion.HIFLD.API

  @service "Electric_Power_Transmission_Lines"

  # Endpoints with the same name within this distance are one substation.
  @cluster_radius_km 5.0

  # Voltage levels within this relative tolerance are one physical level
  # (e.g. 115 kV and 120 kV records of the same yard).
  @voltage_cluster_tolerance 0.05

  # Names that carry no identity: merging them would fuse unrelated endpoints.
  @sentinel_names ["NOT AVAILABLE", "NONE", "DEADHEAD"]

  @doc """
  Derive substations from transmission line API data.

  Groups lines by SUB_1/SUB_2 name, clusters same-name endpoints
  geographically (~#{@cluster_radius_km} km), and uses per-cluster centroid
  coordinates. See the moduledoc for the identity scheme.
  """
  def derive_from_api do
    IO.puts("Deriving substations from transmission line endpoints...")

    endpoints =
      @service
      |> API.stream_features(fields: "SUB_1,SUB_2,VOLTAGE,VOLT_CLASS")
      |> Stream.flat_map(&extract_sub_refs/1)
      |> Enum.to_list()

    IO.puts("Found #{length(endpoints)} substation endpoint references.")

    entries = build_entries(endpoints)

    IO.puts("Clustered into #{length(entries)} substations.")

    counter = :counters.new(1, [:atomics])

    entries
    |> Enum.chunk_every(500)
    |> Enum.each(fn batch ->
      insert_batch(batch)
      :counters.add(counter, 1, length(batch))
      count = :counters.get(counter, 1)
      if rem(count, 2000) < 500, do: IO.puts("  #{count} substations inserted...")
    end)

    final = :counters.get(counter, 1)
    IO.puts("Inserted #{final} substations.")
    {:ok, final}
  end

  @doc """
  Build substation insert entries from a list of endpoint references
  `{name, lon, lat, voltage_kv_or_nil}`.

  Named endpoints are grouped by name and clustered within
  ~#{@cluster_radius_km} km; sentinel-named endpoints get per-endpoint
  coordinate-derived identities instead of merging.
  """
  def build_entries(endpoints) do
    endpoints =
      Enum.map(endpoints, fn {name, lon, lat, voltage} ->
        {String.trim(name), lon, lat, voltage}
      end)

    {sentinels, named} =
      Enum.split_with(endpoints, fn {name, _, _, _} -> sentinel_name?(name) end)

    named_entries =
      named
      |> Enum.group_by(fn {name, _, _, _} -> name end)
      |> Enum.flat_map(fn {name, eps} ->
        eps
        |> Enum.map(fn {_, lon, lat, voltage} -> {lon, lat, voltage} end)
        |> cluster_endpoints(@cluster_radius_km)
        |> Enum.map(&build_cluster_substation(name, &1, 2))
      end)

    # Sentinel names carry no identity: one substation per (rounded) endpoint
    # coordinate, never merged across locations.
    sentinel_entries =
      sentinels
      |> Enum.group_by(fn {name, lon, lat, _} ->
        {name, Float.round(lat * 1.0, 3), Float.round(lon * 1.0, 3)}
      end)
      |> Enum.map(fn {{name, _, _}, eps} ->
        cluster = Enum.map(eps, fn {_, lon, lat, voltage} -> {lon, lat, voltage} end)
        build_cluster_substation(name, cluster, 3)
      end)

    named_entries ++ sentinel_entries
  end

  @doc """
  True for names that do not identify a real substation and therefore must
  not be merged by name: #{inspect(@sentinel_names)} and the UNKNOWN*/TAP*
  prefixes.
  """
  def sentinel_name?(name) when is_binary(name) do
    up = name |> String.trim() |> String.upcase()

    up == "" or up in @sentinel_names or
      String.starts_with?(up, "UNKNOWN") or
      String.starts_with?(up, "TAP")
  end

  @doc """
  Cluster endpoints `{lon, lat, voltage_or_nil}` with union-find: any two
  endpoints within `radius_km` are in the same cluster (transitively).
  Returns a list of clusters (each a list of the input tuples).
  """
  def cluster_endpoints(endpoints, radius_km) do
    indexed = Enum.with_index(endpoints)
    parents = Map.new(indexed, fn {_, i} -> {i, i} end)

    parents =
      for {{lon1, lat1, _}, i} <- indexed,
          {{lon2, lat2, _}, j} <- indexed,
          i < j,
          reduce: parents do
        acc ->
          if haversine_km(lat1, lon1, lat2, lon2) <= radius_km do
            union(acc, i, j)
          else
            acc
          end
      end

    indexed
    |> Enum.group_by(fn {_, i} -> find_root(parents, i) end)
    |> Map.values()
    |> Enum.map(fn members -> Enum.map(members, &elem(&1, 0)) end)
  end

  @doc """
  Merge voltage levels within #{trunc(@voltage_cluster_tolerance * 100)}% of
  each other into one level (e.g. `[115.0, 120.0] -> [120.0]`), returning
  representative levels sorted descending. The representative is the highest
  level of each group.
  """
  def cluster_voltage_levels(voltages) do
    voltages
    |> Enum.uniq()
    |> Enum.sort(:desc)
    |> Enum.reduce([], fn v, acc ->
      case acc do
        [rep | _] when (rep - v) / rep <= @voltage_cluster_tolerance -> acc
        _ -> [v | acc]
      end
    end)
    |> Enum.reverse()
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

  # cluster: [{lon, lat, voltage_or_nil}]; id_decimals controls hifld_id
  # coordinate precision (2 for named clusters, 3 for per-endpoint sentinels).
  defp build_cluster_substation(name, cluster, id_decimals) do
    n = length(cluster)
    avg_lon = (cluster |> Enum.map(&elem(&1, 0)) |> Enum.sum()) / n
    avg_lat = (cluster |> Enum.map(&elem(&1, 1)) |> Enum.sum()) / n

    voltages =
      cluster
      |> Enum.map(&elem(&1, 2))
      |> Enum.reject(&is_nil/1)
      |> cluster_voltage_levels()

    max_kv = List.first(voltages)
    min_kv = List.last(voltages)

    hifld_id = "#{name}@#{fmt_coord(avg_lat, id_decimals)},#{fmt_coord(avg_lon, id_decimals)}"

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

  defp fmt_coord(value, decimals), do: :erlang.float_to_binary(value * 1.0, decimals: decimals)

  # Union-find (no path compression -- per-name groups are small)

  defp find_root(parents, i) do
    parent = Map.fetch!(parents, i)
    if parent == i, do: i, else: find_root(parents, parent)
  end

  defp union(parents, i, j) do
    ri = find_root(parents, i)
    rj = find_root(parents, j)
    if ri == rj, do: parents, else: Map.put(parents, ri, rj)
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

  # Status codes that explicitly mark a substation as not energized. Anything
  # else -- including nil, "NOT AVAILABLE", and unknown codes -- is treated as
  # in service: HIFLD's status field is sparsely populated, and discarding
  # unknowns removes large swaths of the real network.
  @out_of_service_statuses [
    "INACTIVE",
    "RETIRED",
    "UNDER CONSTRUCTION",
    "PROPOSED",
    "DECOMMISSIONED"
  ]

  @doc """
  Map a HIFLD STATUS value to `"in_service"` / `"out_of_service"`.

  Only explicit outage codes (#{Enum.join(@out_of_service_statuses, ", ")})
  are out of service; unknown or missing statuses (incl. "NOT AVAILABLE")
  are in service.
  """
  def parse_status(status) when is_binary(status) do
    if String.upcase(String.trim(status)) in @out_of_service_statuses,
      do: "out_of_service",
      else: "in_service"
  end

  def parse_status(_), do: "in_service"

  defp haversine_km(lat1, lon1, lat2, lon2) do
    r = 6371.0
    dlat = (lat2 - lat1) * :math.pi() / 180.0
    dlon = (lon2 - lon1) * :math.pi() / 180.0
    lat1_r = lat1 * :math.pi() / 180.0
    lat2_r = lat2 * :math.pi() / 180.0

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(lat1_r) * :math.cos(lat2_r) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    r * c
  end
end
