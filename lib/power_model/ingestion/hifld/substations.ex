defmodule PowerModel.Ingestion.HIFLD.Substations do
  @moduledoc """
  Ingest substations from HIFLD data.

  Three modes, in order of preference:

  1. **Native substations from the vendored GeoJSON mirror** (`ingest/1` on a
     `.geojson`/`.geojsonl` file) — 77,946 real yards with NAME, MAX_VOLT and
     MIN_VOLT, checksummed in `data/vendored/PROVENANCE.md`. This is the
     source the ingest task prefers, and the only one that gives line
     endpoints a real substation to be keyed to by name.
  2. From a shapefile directory (`ingest/1` on a directory).
  3. Derived from transmission line endpoint data via the API
     (`derive_from_api/0`, using SUB_1/SUB_2 and line endpoint coordinates) —
     the fallback that invents substations at endpoint centroids because no
     substation layer is available.

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

  ## Voltage levels

  Each cluster's endpoint voltages are collapsed within 5% (115 kV and 120 kV
  records of the same yard are one level) and the whole descending list is
  stored in `voltage_levels`. `max_voltage_kv` / `min_voltage_kv` remain the head and tail
  of that list for compatibility. `BusMapper` gives every stored level its own
  bus, so line endpoints snap to their real level instead of the nearest
  extreme (LIN-5).

  > #### Re-ingest note {: .warning}
  > The `hifld_id` format changed from the bare name to `NAME@lat,lon`.
  > Re-ingesting into an existing database creates the corrected clustered
  > substations ALONGSIDE previously ingested name-keyed rows (the upsert
  > key no longer matches). A cleanup pass for the old rows is out of scope
  > here — re-ingest into a fresh database, or delete substations whose
  > `hifld_id` does not contain `"@"` before re-deriving.
  """

  import Ecto.Query

  alias PowerModel.Repo
  alias PowerModel.Grid.Substation
  alias PowerModel.Grid.TransmissionLine
  alias PowerModel.Ingestion.HIFLD.API
  alias PowerModel.Ingestion.HIFLD.EndpointMatcher
  alias PowerModel.Ingestion.HIFLD.GeoJSON

  @service "Electric_Power_Transmission_Lines"

  # HIFLD writes this in place of a missing numeric value.
  @null_sentinel -999_999

  # Endpoints with the same name within this distance are one substation.
  @cluster_radius_km 5.0

  # Voltage levels within this relative tolerance are one physical level
  # (e.g. 115 kV and 120 kV records of the same yard).
  @voltage_cluster_tolerance 0.05

  # Names that carry no identity: merging them would fuse unrelated endpoints.
  @sentinel_names ["NOT AVAILABLE", "NONE", "DEADHEAD"]

  # Highest voltage that can be a real AC level of a yard. Above it the number
  # is not a bus voltage at all: HIFLD writes an HVDC bipole's pole-to-pole
  # rating into the same VOLTAGE field (LIN-12 — the Pacific DC Intertie,
  # source_id 200823, CELILO->SYLMAR EAST, carries 1000 for a +/-500 kV link).
  # The US grid's highest AC class is 765 kV.
  @max_ac_kv 765.0

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
  Ingest from a local file or directory.

  A `.geojson`/`.geojsonl`/`.json` FILE is the vendored native substation
  layer (see `ingest_geojson/1`); a DIRECTORY is a HIFLD shapefile export.
  """
  def ingest(path) do
    cond do
      File.dir?(path) -> ingest_shapefile(path)
      File.regular?(path) -> ingest_geojson(path)
      true -> raise "HIFLD substation source not found at #{path}"
    end
  end

  @doc """
  Ingest the vendored native substation layer from GeoJSON.

  Every feature is a real surveyed yard, so identity is HIFLD's own record id
  rather than the name+cluster scheme `derive_from_api/0` has to invent
  (LIN-1) — no two rows share an `ID`, and endpoints key to them by name.
  Upserts on `hifld_id`, so re-running is idempotent.

  `-999999` sentinels in MAX_VOLT/MIN_VOLT become nil rather than a
  million-volt yard; a substation left with no voltage at all still ingests
  (BusMapper gives it a default-kV bus) and, once lines are in, picks up its
  real levels from `augment_voltage_levels_from_lines/0`.

  Returns `{:ok, inserted}`.
  """
  def ingest_geojson(path) do
    IO.puts("Ingesting substations from #{path}...")

    # 1 = features seen, 2 = inserted, 3 = skipped (no geometry / no id)
    counter = :counters.new(3, [:atomics])

    path
    |> GeoJSON.stream_features!()
    |> Stream.map(fn feature ->
      :counters.add(counter, 1, 1)
      parse_geojson_substation(feature)
    end)
    |> Stream.filter(fn
      nil ->
        :counters.add(counter, 3, 1)
        false

      _ ->
        true
    end)
    |> Stream.chunk_every(1000)
    |> Stream.each(fn batch ->
      insert_batch(batch)
      :counters.add(counter, 2, length(batch))
      count = :counters.get(counter, 2)
      if rem(count, 10_000) < 1000, do: IO.puts("  #{count} substations inserted...")
    end)
    |> Stream.run()

    seen = :counters.get(counter, 1)
    inserted = :counters.get(counter, 2)
    skipped = :counters.get(counter, 3)

    IO.puts("Read #{seen} features: #{inserted} substations inserted, #{skipped} skipped.")

    {:ok, inserted}
  end

  @doc """
  Parse one native-layer GeoJSON feature into an insertable entry, or nil when
  it has no point geometry or no id.
  """
  def parse_geojson_substation(%{"properties" => props} = feature) do
    with {lon, lat} <- GeoJSON.point_coordinates(feature),
         hifld_id when hifld_id != "" <- native_hifld_id(props) do
      max_kv = sanitize_voltage(props["MAX_VOLT"])
      min_kv = sanitize_voltage(props["MIN_VOLT"])

      levels =
        [max_kv, min_kv]
        |> Enum.reject(&is_nil/1)
        |> cluster_voltage_levels()

      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      %{
        name: props["NAME"] |> to_string() |> String.trim() |> default_name(hifld_id),
        voltage_levels: levels,
        max_voltage_kv: List.first(levels),
        min_voltage_kv: if(length(levels) > 1, do: List.last(levels)),
        coordinates: %Geo.Point{coordinates: {lon * 1.0, lat * 1.0}, srid: 4326},
        hifld_id: hifld_id,
        status: parse_status(props["STATUS"]),
        inserted_at: now,
        updated_at: now
      }
    else
      _ -> nil
    end
  end

  def parse_geojson_substation(_), do: nil

  @doc """
  Merge the voltages of terminating lines into each substation's stored level
  list, and return `%{substations_updated: n, levels_added: n}`.

  The native layer reports only MAX_VOLT and MIN_VOLT, and 18,589 rows report
  neither. A 500/345/138 yard therefore stores 500 and 138 and offers no bus
  at 345, so every 345 kV line terminating there fails its voltage-filtered
  snap and the endpoint is dropped — LIN-5, arriving through the data instead
  of through the code this time. The lines themselves carry the missing
  levels: each one names the two yards it terminates at and its own voltage.

  Endpoints are attributed by name (`EndpointMatcher`), so this runs after
  both lines and substations are ingested and before `map_buses`.

  ## What a line is not allowed to lend (LIN-12)

  DC lines and anything above #{trunc(@max_ac_kv)} kV are excluded. The
  Pacific DC Intertie is stored with `voltage_kv` 1000 — HIFLD's field holds
  the +/-500 kV bipole's pole-to-pole rating — and `grid.ex` correctly keeps
  it out of every AC solve, but this pass had no such filter and seeded a
  1000 kV level into CELILO and SYLMAR EAST. `BusMapper` then built two
  1000 kV buses and the 1000->500 and 1000->230 transformers to reach them,
  and those stubs entered every Western snapshot and censused as a "765 kV+"
  voltage class that does not exist. The corridor's real power transfer is
  carried by `dc_ties`, not by these rows.
  """
  def augment_voltage_levels_from_lines do
    index = EndpointMatcher.build_index()

    # Endpoints come back as four floats per line rather than the geometry:
    # the national snapshot is 94,619 LineStrings and materializing them all
    # to read their first and last point is gigabytes for eight numbers each.
    voltages_by_substation =
      from(l in TransmissionLine,
        where:
          not is_nil(l.voltage_kv) and l.voltage_kv > 0.0 and l.voltage_kv <= @max_ac_kv and
            (is_nil(l.line_type) or l.line_type != "dc") and not is_nil(l.geometry),
        select: %{
          sub_1: l.sub_1,
          sub_2: l.sub_2,
          voltage_kv: l.voltage_kv,
          from_lon: fragment("ST_X(ST_StartPoint(?))", l.geometry),
          from_lat: fragment("ST_Y(ST_StartPoint(?))", l.geometry),
          to_lon: fragment("ST_X(ST_EndPoint(?))", l.geometry),
          to_lat: fragment("ST_Y(ST_EndPoint(?))", l.geometry)
        }
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn line, acc ->
        acc
        |> add_endpoint_voltage(
          index,
          line.sub_1,
          endpoint(line.from_lon, line.from_lat),
          line.voltage_kv
        )
        |> add_endpoint_voltage(
          index,
          line.sub_2,
          endpoint(line.to_lon, line.to_lat),
          line.voltage_kv
        )
      end)

    IO.puts(
      "  Substations named by at least one line endpoint: #{map_size(voltages_by_substation)}"
    )

    apply_augmented_levels(voltages_by_substation)
  end

  defp add_endpoint_voltage(acc, _index, _name, nil, _kv), do: acc

  defp add_endpoint_voltage(acc, index, name, point, kv) do
    case EndpointMatcher.resolve(index, name, point, EndpointMatcher.name_match_radius_km()) do
      {:ok, sub_id, _distance} -> Map.update(acc, sub_id, [kv], &[kv | &1])
      _ -> acc
    end
  end

  defp apply_augmented_levels(voltages_by_substation) when map_size(voltages_by_substation) == 0,
    do: %{substations_updated: 0, levels_added: 0}

  defp apply_augmented_levels(voltages_by_substation) do
    ids = Map.keys(voltages_by_substation)

    updates =
      from(s in Substation, where: s.id in ^ids, select: {s.id, s.voltage_levels})
      |> Repo.all()
      |> Enum.flat_map(fn {id, stored} ->
        stored = stored || []
        merged = cluster_voltage_levels(stored ++ Map.fetch!(voltages_by_substation, id))

        if merged != stored do
          [{id, merged, length(merged) - length(stored)}]
        else
          []
        end
      end)

    Enum.each(Enum.chunk_every(updates, 500), fn chunk ->
      Repo.transaction(fn ->
        Enum.each(chunk, fn {id, levels, _added} ->
          from(s in Substation, where: s.id == ^id)
          |> Repo.update_all(
            set: [
              voltage_levels: levels,
              max_voltage_kv: List.first(levels),
              min_voltage_kv: if(length(levels) > 1, do: List.last(levels)),
              updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
            ]
          )
        end)
      end)
    end)

    added = Enum.reduce(updates, 0, fn {_, _, n}, sum -> sum + max(n, 0) end)

    IO.puts(
      "  Voltage levels augmented from lines: #{length(updates)} substations, +#{added} levels"
    )

    %{substations_updated: length(updates), levels_added: added}
  end

  defp endpoint(lon, lat) when is_number(lon) and is_number(lat), do: {lon, lat}
  defp endpoint(_, _), do: nil

  @doc """
  Turn a HIFLD numeric cell into a voltage, mapping the `#{@null_sentinel}`
  sentinel (18,589 MAX_VOLT / 24,365 MIN_VOLT rows in the vendored layer) and
  any non-positive value to nil.
  """
  def sanitize_voltage(nil), do: nil

  def sanitize_voltage(value) when is_number(value) do
    if value > 0 and value != @null_sentinel, do: value * 1.0
  end

  def sanitize_voltage(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {f, _} -> sanitize_voltage(f)
      :error -> nil
    end
  end

  def sanitize_voltage(_), do: nil

  # HIFLD's own record id. Unique across the vendored layer (verified: 77,946
  # features, 77,946 distinct IDs), and unambiguous against the API-derived
  # "NAME@lat,lon" ids, which always contain an "@".
  defp native_hifld_id(props) do
    (props["ID"] || props["OBJECTID"] || props["GlobalID"] || "") |> to_string() |> String.trim()
  end

  defp default_name("", hifld_id), do: "UNKNOWN#{hifld_id}"
  defp default_name(name, _hifld_id), do: name

  defp ingest_shapefile(path) do
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
      # LIN-5: the whole clustered list, not just its ends. A 500/345/138/115
      # yard used to store 500 and 115 and lose the two levels in between,
      # which is why 345 kV endpoints there had no bus to snap to.
      voltage_levels: voltages,
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
          # The shapefile only reports the extremes, so the stored level list
          # is those two. The API-derived path (build_entries/1) sees every
          # terminating line's voltage and stores the full list.
          voltage_levels: [max_kv, min_kv] |> Enum.reject(&is_nil/1) |> cluster_voltage_levels(),
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
