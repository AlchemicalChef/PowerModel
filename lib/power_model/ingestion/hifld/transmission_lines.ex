defmodule PowerModel.Ingestion.HIFLD.TransmissionLines do
  @moduledoc """
  Ingest transmission lines from HIFLD Electric Power Transmission Lines.

  Three sources, in order of preference:

    1. **The vendored HIFLD Next snapshot** (`ingest/1` on a `.geojsonl` or
       `.geojson` file) — 94,619 features, public domain, checksummed in
       `data/vendored/PROVENANCE.md`. This is the default the ingest task
       picks when the file is present. Produce it with
       `scripts/convert_vendored_hifld.py`.
    2. A local shapefile directory (`ingest/1` on a directory).
    3. The ArcGIS REST API (`ingest_from_api/0`) — documented fallback only.
       It serves an unofficial 52,244-feature mirror uploaded in Sept 2023,
       roughly half the vendored snapshot, from an org that is not HIFLD
       (REVIEW DAT-19; HIFLD Open was shut down 2025-08-26).

  Only the vendored path restores circuits that carry no voltage of their own
  (TOPO-1, `parse_geojson_feature/2`). The inference needs the whole snapshot
  indexed by yard before any feature is parsed, which the two other sources —
  a live paging API and a shapefile reader — do not offer; they still drop
  those features, as they did before.
  """

  alias PowerModel.Repo
  alias PowerModel.Grid.TransmissionLine
  alias PowerModel.Ingestion.HIFLD.API
  alias PowerModel.Ingestion.HIFLD.EndpointMatcher
  alias PowerModel.Ingestion.HIFLD.GeoJSON
  alias PowerModel.Ingestion.HIFLD.Names
  alias PowerModel.Ingestion.HIFLD.Substations

  @service "Electric_Power_Transmission_Lines"

  # Voltage a restored circuit falls back to when neither of its yards has a
  # known level (TOPO-1). Equal to `BusMapper`'s `@default_bus_kv`, and that
  # equality is the point: those yards have no voltage anywhere in HIFLD, so
  # BusMapper gives them a 138 kV bus regardless, and a restored circuit at
  # any other voltage would have no bus to land on.
  @default_kv 138.0

  # A voltage above this is not a line voltage in HIFLD, it is the
  # pole-to-pole rating of an HVDC bipole written into the AC field (LIN-12:
  # the PDCI, source_id 200823, carries VOLTAGE 1000 for a +/-500 kV link).
  # Such a line must never lend its voltage to a yard or to a neighbouring
  # circuit. Same cap as `Substations.augment_voltage_levels_from_lines/0`.
  @max_ac_kv 765.0

  @doc """
  Ingest from HIFLD ArcGIS REST API (default).
  """
  def ingest_from_api do
    {:ok, total} = API.count(@service)
    IO.puts("Fetching #{total} transmission lines from HIFLD API...")

    counter = :counters.new(1, [:atomics])

    @service
    |> API.stream_features()
    |> Stream.map(&parse_api_feature/1)
    |> Stream.filter(& &1)
    |> Stream.chunk_every(500)
    |> Stream.each(fn batch ->
      insert_batch(batch)
      :counters.add(counter, 1, length(batch))
      count = :counters.get(counter, 1)
      if rem(count, 2000) == 0, do: IO.puts("  #{count}/#{total} lines inserted...")
    end)
    |> Stream.run()

    final = :counters.get(counter, 1)
    IO.puts("Inserted #{final} transmission lines.")
    {:ok, final}
  end

  @doc """
  Ingest from a local file or directory.

  A `.geojsonl`/`.geojson`/`.json` FILE is the vendored HIFLD Next snapshot
  (see `ingest_geojson/1`); a DIRECTORY is a HIFLD shapefile export.
  """
  def ingest(path) do
    cond do
      File.dir?(path) -> ingest_shapefile(path)
      File.regular?(path) -> ingest_geojson(path)
      true -> raise "HIFLD transmission line source not found at #{path}"
    end
  end

  @doc """
  Ingest the vendored HIFLD Next snapshot from GeoJSON.

  Reads newline-delimited features or a single FeatureCollection (see
  `PowerModel.Ingestion.HIFLD.GeoJSON`) and upserts on `{source, source_id}`,
  so re-running is idempotent. Returns `{:ok, inserted}`.

  Reads the file TWICE: the first pass builds the yard voltage index
  (`build_yard_voltage_index/1`) that gives the no-voltage circuits a voltage
  to be restored at, the second inserts. Only features with fewer than two
  coordinates or without an id are skipped now.
  """
  def ingest_geojson(path) do
    IO.puts("Ingesting transmission lines from #{path}...")

    index = build_yard_voltage_index(path)
    IO.puts("  Yards named by at least one line of known voltage: #{map_size(index)}")

    # 1 = features seen, 2 = inserted, 3 = skipped (no geometry / no id),
    # 4..7 = restored circuits by inference (see `@voltage_sources`)
    counter = :counters.new(7, [:atomics])

    path
    |> GeoJSON.stream_features!()
    |> Stream.map(fn feature ->
      :counters.add(counter, 1, 1)
      parse_geojson_feature(feature, index)
    end)
    |> Stream.filter(fn
      nil ->
        :counters.add(counter, 3, 1)
        false

      attrs ->
        count_voltage_source(counter, attrs.voltage_source)
        true
    end)
    |> Stream.chunk_every(1000)
    |> Stream.each(fn batch ->
      insert_batch(batch)
      :counters.add(counter, 2, length(batch))
      count = :counters.get(counter, 2)
      if rem(count, 10_000) < 1000, do: IO.puts("  #{count} lines inserted...")
    end)
    |> Stream.run()

    seen = :counters.get(counter, 1)
    inserted = :counters.get(counter, 2)
    skipped = :counters.get(counter, 3)
    restored = restored_counts(counter)

    IO.puts(
      "Read #{seen} features: #{inserted} lines inserted, #{skipped} skipped (no geometry)."
    )

    IO.puts(
      "  Restored #{Enum.sum(Map.values(restored))} circuits with no HIFLD voltage: " <>
        "#{restored.shared_level} from a level shared by both yards, " <>
        "#{restored.single_yard} from the one yard with levels, " <>
        "#{restored.straddle} straddling two yards with no level in common, " <>
        "#{restored.default} at the #{@default_kv} kV default (neither yard has a level). " <>
        "All stamped params_version 0 for the estimator."
    )

    {:ok, inserted}
  end

  # Restoration bookkeeping. `:hifld` (the feature carried its own voltage) is
  # not counted -- it is `inserted` minus the four inference categories.
  @voltage_sources [shared_level: 4, single_yard: 5, straddle: 6, default: 7]

  defp count_voltage_source(counter, source) do
    case @voltage_sources[source] do
      nil -> :ok
      slot -> :counters.add(counter, slot, 1)
    end
  end

  defp restored_counts(counter) do
    Map.new(@voltage_sources, fn {source, slot} -> {source, :counters.get(counter, slot)} end)
  end

  @doc """
  Index every yard named by a line that carries its own voltage:
  `%{normalized_name => [{lon, lat, voltage_kv}]}`.

  This is the evidence `parse_geojson_feature/2` restores no-voltage circuits
  from, and it is deliberately built from the SNAPSHOT rather than from the
  database: the pipeline ingests lines before substations, so at this point
  there is no substation table to consult, and a file-derived index makes the
  restoration independent of ingest order. Measured against the substation
  layer it costs almost nothing — the yards a no-voltage circuit names are the
  ones with no voltage on record anywhere (13,520 of them), so adding
  MAX_VOLT/MIN_VOLT to this index moves the endpoint-inferred count by 19 out
  of 8,814 (TOPO-7: the rest is the OSM wave's voltage backfill).

  It is also the guarantee that a restored circuit HAS a bus to land on: a
  level in this index is a level some line terminates at, so
  `Substations.augment_voltage_levels_from_lines/0` will write it into the
  yard and `BusMapper` will give it a bus.

  HVDC and above-#{trunc(@max_ac_kv)} kV lines are left out for the reason
  `augment_voltage_levels_from_lines/0` leaves them out (LIN-12).
  """
  def build_yard_voltage_index(path) do
    path
    |> GeoJSON.stream_features!()
    |> Enum.reduce(%{}, &index_feature/2)
  end

  defp index_feature(%{"properties" => props} = feature, acc) do
    voltage = parse_voltage(props["VOLTAGE"], props["VOLT_CLASS"])

    with true <- is_number(voltage) and voltage > 0 and voltage <= @max_ac_kv,
         false <- line_type_from(props["VOLT_CLASS"], props["TYPE"]) == "dc",
         [_ | _] = parts <- GeoJSON.line_parts(feature) do
      acc
      |> put_yard_voltage(props["SUB_1"], first_coordinate(parts), voltage)
      |> put_yard_voltage(props["SUB_2"], last_coordinate(parts), voltage)
    else
      _ -> acc
    end
  end

  defp index_feature(_, acc), do: acc

  defp put_yard_voltage(acc, name, {lon, lat}, voltage) do
    if Names.identifying?(name) do
      Map.update(
        acc,
        Names.normalize(name),
        [{lon, lat, voltage}],
        &[{lon, lat, voltage} | &1]
      )
    else
      acc
    end
  end

  defp put_yard_voltage(acc, _name, _point, _voltage), do: acc

  defp first_coordinate([part | _]), do: List.first(part)
  defp first_coordinate(_), do: nil

  defp last_coordinate(parts), do: parts |> List.last() |> List.last()

  @doc """
  Parse one vendored GeoJSON feature into an insertable attrs map, or nil.

  Field names follow the HIFLD Next schema: `source_ID` is the stable line id
  (the ArcGIS mirror calls it `ID`), and geometry arrives as LineString or
  MultiLineString rather than ArcGIS `paths`. Everything downstream —
  per-part length, HVDC marking, status mapping — is shared with the API path.

  ## Circuits with no voltage of their own (TOPO-1)

  8,814 of the snapshot's 94,619 features (9.3%) carry the `-999999` VOLTAGE
  sentinel AND an unparseable VOLT_CLASS. Dropping them silently cost real
  connectivity: 1,452 of the `connectivity_repair` joints BusMapper later
  invents at a placeholder 138 kV / 250 MVA reconnect the exact yard pair one
  of these circuits already names, and whole load pockets (475 MW behind one
  repair bridge in downtown Chicago; 301 MW at Ashburn) lost every real path
  they had.

  They are now inserted with a voltage INFERRED from the yards they name,
  taking the first rule that applies (`index` from
  `build_yard_voltage_index/1`):

    1. `:shared_level` — the highest level both yards have, within the 5%
       tolerance that makes 115 kV and 120 kV one level. Invents nothing:
       both ends already have a bus there.
    2. `:single_yard` — only one yard has levels: its LOWEST. An unlabelled
       HIFLD circuit off a multi-level yard is far more often the
       sub-transmission side than the EHV side, and understating voltage
       understates the rating and overstates the per-unit impedance, so the
       restored path is never stronger than the evidence for it.
    3. `:straddle` — both yards have levels but share none:
       `min(max(a), max(b))`, the highest class both terminals could carry.
       The weakest of the three inferences (403 circuits) and the only one
       that can add a level to a yard that did not have it.
    4. `:default` — neither yard has any level: #{@default_kv} kV, which is
       the bus BusMapper gives those yards anyway.

  The inference is recorded on the returned map as `:voltage_source` (`:hifld`
  when the feature carried its own voltage) for counting and tests; it is not
  a column and never reaches the database. Restored rows are stamped
  `params_version: 0` so `ParameterEstimator` gives them an impedance and
  ratings from the inferred class like any other row.

  There is deliberately no "this voltage was inferred" column: the restored
  set is exactly reproducible from the pinned snapshot at any time (it is the
  features this function restores, keyed by the stable `source_ID`), which a
  stored flag could only drift from. A later pass that learns a circuit's real
  voltage — ROADMAP item 24, the OSM wave, for the 5,117 yards with no
  voltage on record that a restored circuit names — must write
  `params_version: 0` alongside the new voltage, or the estimator will read
  the row as current and leave the impedance on the old class.
  """
  def parse_geojson_feature(feature, index \\ %{})

  def parse_geojson_feature(%{"properties" => props} = feature, index) do
    parts = GeoJSON.line_parts(feature)
    coords = Enum.concat(parts)
    source_id = to_string(props["source_ID"] || props["ID"] || props["OBJECTID"])

    if length(coords) >= 2 && source_id != "" do
      {voltage, voltage_source} = feature_voltage(props, parts, index)

      %{
        voltage_kv: voltage,
        voltage_source: voltage_source,
        geometry: %Geo.LineString{coordinates: coords, srid: 4326},
        length_km: parts_length_km(parts),
        source: "hifld",
        source_id: source_id,
        status: parse_status(props["STATUS"]),
        line_type: line_type_from(props["VOLT_CLASS"], props["TYPE"]),
        owner: props["OWNER"],
        sub_1: props["SUB_1"],
        sub_2: props["SUB_2"],
        naics_code: props["NAICS_CODE"],
        naics_desc: props["NAICS_DESC"],
        from_bus_id: nil,
        to_bus_id: nil
      }
    end
  end

  def parse_geojson_feature(_, _index), do: nil

  # {voltage_kv, :hifld | :shared_level | :single_yard | :straddle | :default}
  defp feature_voltage(props, parts, index) do
    case parse_voltage(props["VOLTAGE"], props["VOLT_CLASS"]) do
      voltage when is_number(voltage) and voltage > 0 ->
        {voltage, :hifld}

      _ ->
        infer_voltage(
          yard_levels(index, props["SUB_1"], first_coordinate(parts)),
          yard_levels(index, props["SUB_2"], last_coordinate(parts))
        )
    end
  end

  # Levels are descending, so `hd` is the yard's highest and `List.last` its
  # lowest. See `parse_geojson_feature/2` for why each rule picks the end it
  # picks.
  defp infer_voltage(nil, nil), do: {@default_kv, :default}
  defp infer_voltage(levels, nil), do: {List.last(levels), :single_yard}
  defp infer_voltage(nil, levels), do: {List.last(levels), :single_yard}

  defp infer_voltage(left, right) do
    case Enum.find(left, fn kv -> Enum.any?(right, &same_level?(&1, kv)) end) do
      nil -> {min(hd(left), hd(right)), :straddle}
      shared -> {shared, :shared_level}
    end
  end

  # The levels of the yard `name` names, descending, or nil when the name
  # identifies no yard in the index within the name-match radius. Same key and
  # same radius as `EndpointMatcher` uses to attribute endpoints, so a level
  # found here is a level that endpoint will actually be able to snap to.
  defp yard_levels(index, name, {lon, lat}) do
    with true <- Names.identifying?(name),
         [_ | _] = entries <- Map.get(index, Names.normalize(name), []) do
      entries
      |> Enum.filter(fn {elon, elat, _kv} ->
        EndpointMatcher.haversine_km(lat, lon, elat, elon) <=
          EndpointMatcher.name_match_radius_km()
      end)
      |> Enum.map(fn {_lon, _lat, kv} -> kv end)
      |> case do
        [] -> nil
        voltages -> Substations.cluster_voltage_levels(voltages)
      end
    else
      _ -> nil
    end
  end

  defp yard_levels(_index, _name, _point), do: nil

  # Two records of the same physical level (115 kV and 120 kV are one yard
  # level), matching `Substations.cluster_voltage_levels/1`'s tolerance.
  defp same_level?(a, b), do: abs(a - b) / max(a, b) <= 0.05

  defp ingest_shapefile(path) do
    path
    |> read_shapefile()
    |> Flow.from_enumerable(max_demand: 100)
    |> Flow.map(&parse_shapefile_feature/1)
    |> Flow.filter(& &1)
    |> Flow.map(&insert_line/1)
    |> Flow.run()
  end

  @doc """
  Backfill HIFLD fields (TYPE, OWNER, SUB_1, SUB_2, NAICS) on existing records
  by re-fetching from the API and updating in place.
  """
  def backfill_hifld_fields do
    import Ecto.Query

    # Count lines needing backfill (those with nil sub_1)
    total =
      Repo.one(
        from tl in TransmissionLine,
          where: tl.source == "hifld" and is_nil(tl.sub_1),
          select: count()
      )

    IO.puts("Lines needing backfill: #{total}")

    if total == 0 do
      IO.puts("Nothing to backfill.")
      return_ok()
    end

    counter = :counters.new(1, [:atomics])

    @service
    |> API.stream_features()
    |> Stream.chunk_every(500)
    |> Stream.each(fn batch ->
      updates =
        Enum.map(batch, fn %{"attributes" => attrs} ->
          source_id = to_string(attrs["ID"] || attrs["OBJECTID_1"])

          {source_id,
           %{
             line_type: line_type_from(attrs["VOLT_CLASS"], attrs["TYPE"]),
             owner: attrs["OWNER"],
             sub_1: attrs["SUB_1"],
             sub_2: attrs["SUB_2"],
             naics_code: attrs["NAICS_CODE"],
             naics_desc: attrs["NAICS_DESC"]
           }}
        end)

      source_ids = Enum.map(updates, &elem(&1, 0))
      update_map = Map.new(updates)

      lines =
        Repo.all(
          from tl in TransmissionLine,
            where: tl.source == "hifld" and tl.source_id in ^source_ids
        )

      Enum.each(lines, fn line ->
        if fields = Map.get(update_map, line.source_id) do
          line
          |> Ecto.Changeset.change(fields)
          |> Repo.update()
        end
      end)

      :counters.add(counter, 1, length(batch))
      count = :counters.get(counter, 1)
      if rem(count, 5000) == 0, do: IO.puts("  Backfilled #{count} lines...")
    end)
    |> Stream.run()

    IO.puts("Backfill complete: #{:counters.get(counter, 1)} lines processed.")
    {:ok, :counters.get(counter, 1)}
  end

  defp return_ok, do: {:ok, 0}

  # API parsing

  @doc false
  # Public for tests. Parses one ArcGIS feature into an insertable attrs map.
  def parse_api_feature(%{"attributes" => attrs, "geometry" => geom}) do
    try do
      voltage = parse_voltage(attrs["VOLTAGE"], attrs["VOLT_CLASS"])
      source_id = to_string(attrs["ID"] || attrs["OBJECTID_1"])

      # ArcGIS paths are nested per PART: [[[lon, lat(, z)], ...], ...].
      # Parse each part on its own (dropping any Z) so a multi-part geometry
      # never contributes phantom "bridge" segments between parts.
      parts = parse_paths(geom["paths"] || [])
      coords = Enum.concat(parts)

      if voltage && voltage > 0 && length(coords) >= 2 do
        # Geometry is stored as a single LineString (downstream endpoint
        # snapping and export expect one), which preserves the true line
        # endpoints (first point of first part / last point of last part).
        # The electrical length is computed per part BEFORE concatenation, so
        # the gap between parts never feeds impedance estimation.
        geometry = %Geo.LineString{coordinates: coords, srid: 4326}

        %{
          voltage_kv: voltage,
          geometry: geometry,
          length_km: parts_length_km(parts),
          source: "hifld",
          source_id: source_id,
          status: parse_status(attrs["STATUS"]),
          line_type: line_type_from(attrs["VOLT_CLASS"], attrs["TYPE"]),
          owner: attrs["OWNER"],
          sub_1: attrs["SUB_1"],
          sub_2: attrs["SUB_2"],
          naics_code: attrs["NAICS_CODE"],
          naics_desc: attrs["NAICS_DESC"],
          from_bus_id: nil,
          to_bus_id: nil
        }
      end
    rescue
      _ -> nil
    end
  end

  def parse_api_feature(_), do: nil

  @doc """
  Parse ArcGIS `paths` (nested arrays, one per part) into a list of parts,
  each a list of `{lon, lat}` tuples. Z (and any further) coordinates are
  dropped explicitly; malformed points and degenerate parts (< 2 points)
  are discarded.
  """
  def parse_paths(paths) when is_list(paths) do
    paths
    |> Enum.map(fn
      part when is_list(part) ->
        part
        |> Enum.map(fn
          [lon, lat | _] when is_number(lon) and is_number(lat) -> {lon, lat}
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end)
    |> Enum.filter(fn part -> length(part) >= 2 end)
  end

  def parse_paths(_), do: []

  @doc """
  Sum geodesic length (km) over parts, each part a list of `{lon, lat}`.
  Lengths are summed WITHIN each part only -- no segment is counted between
  the end of one part and the start of the next.
  """
  def parts_length_km([]), do: nil

  def parts_length_km(parts) when is_list(parts) do
    parts
    |> Enum.map(&part_length_km/1)
    |> Enum.sum()
    |> max(0.1)
  end

  defp part_length_km(part) do
    part
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{lon1, lat1}, {lon2, lat2}] -> haversine_km(lat1, lon1, lat2, lon2) end)
    |> Enum.sum()
  end

  @doc """
  Determine `line_type` from HIFLD attributes: HVDC lines (VOLT_CLASS `"DC"`,
  or a TYPE beginning with `"DC"` such as `"DC; OVERHEAD"`) get the canonical
  `"dc"` marker, which AC snapshot queries exclude. Everything else keeps the
  raw TYPE value.
  """
  def line_type_from(volt_class, type) do
    cond do
      is_binary(volt_class) and String.upcase(String.trim(volt_class)) == "DC" -> "dc"
      is_binary(type) and String.starts_with?(String.upcase(String.trim(type)), "DC") -> "dc"
      true -> type
    end
  end

  # Batch insert using Repo.insert_all for speed

  defp insert_batch(batch) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      Enum.map(batch, fn attrs ->
        %{
          voltage_kv: attrs.voltage_kv,
          geometry: attrs.geometry,
          source: attrs.source,
          source_id: attrs.source_id,
          status: attrs.status,
          line_type: attrs[:line_type],
          owner: attrs[:owner],
          sub_1: attrs[:sub_1],
          sub_2: attrs[:sub_2],
          naics_code: attrs[:naics_code],
          naics_desc: attrs[:naics_desc],
          from_bus_id: nil,
          to_bus_id: nil,
          r_pu: nil,
          x_pu: nil,
          b_pu: nil,
          rating_a_mva: nil,
          length_km: attrs[:length_km],
          # Explicit, not left to the column default: every row this ingester
          # writes — restored circuits included — has to be BELOW
          # `ParameterEstimator.params_version/0` or the estimator will not
          # give it an impedance or a rating at all.
          params_version: 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(TransmissionLine, entries,
      on_conflict: :nothing,
      conflict_target: [:source, :source_id]
    )
  end

  defp insert_line(nil), do: :ok

  defp insert_line(attrs) do
    %TransmissionLine{}
    |> TransmissionLine.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:source, :source_id])
  end

  # Shapefile support

  defp read_shapefile(path) do
    shp_path = Path.join(path, "Electric_Power_Transmission_Lines.shp")

    if File.exists?(shp_path) do
      Exshape.from_zip(shp_path)
    else
      zip_path = Path.join(path, "Electric_Power_Transmission_Lines.zip")

      if File.exists?(zip_path) do
        Exshape.from_zip(zip_path)
      else
        raise "Transmission line shapefile not found at #{path}"
      end
    end
  end

  defp parse_shapefile_feature({shape, dbf_row}) do
    try do
      parts = extract_parts(shape)
      coords = Enum.concat(parts)
      voltage = parse_voltage(get_field(dbf_row, "VOLTAGE"), get_field(dbf_row, "VOLT_CLASS"))
      source_id = to_string(get_field(dbf_row, "ID") || get_field(dbf_row, "OBJECTID"))

      if voltage && voltage > 0 && length(coords) >= 2 do
        %{
          voltage_kv: voltage,
          # Concatenated for storage; length computed per part (see
          # parse_api_feature for rationale).
          geometry: %Geo.LineString{coordinates: coords, srid: 4326},
          length_km: parts_length_km(parts),
          source: "hifld",
          source_id: source_id,
          status: parse_status(get_field(dbf_row, "STATUS")),
          line_type: line_type_from(get_field(dbf_row, "VOLT_CLASS"), get_field(dbf_row, "TYPE")),
          owner: get_field(dbf_row, "OWNER"),
          sub_1: get_field(dbf_row, "SUB_1"),
          sub_2: get_field(dbf_row, "SUB_2"),
          naics_code: get_field(dbf_row, "NAICS_CODE"),
          naics_desc: get_field(dbf_row, "NAICS_DESC"),
          from_bus_id: nil,
          to_bus_id: nil
        }
      end
    rescue
      _ -> nil
    end
  end

  # Shapefile polylines carry parts as nested point lists; keep parts separate
  # (like parse_paths/1) and drop Z by matching only x/y. A flat list of
  # points (single-part polyline) is treated as one part.
  defp extract_parts(%Exshape.Shp.Polyline{points: points}) when is_list(points) do
    points
    |> Enum.map(fn
      part when is_list(part) -> part
      point -> [point]
    end)
    |> Enum.map(fn part ->
      part
      |> Enum.map(fn
        %{x: lon, y: lat} when is_number(lon) and is_number(lat) -> {lon, lat}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
    end)
    |> merge_singleton_parts()
    |> Enum.filter(fn part -> length(part) >= 2 end)
  end

  defp extract_parts(_), do: []

  # A flat (non-nested) point list becomes many 1-point "parts"; merge them
  # back into a single part. Genuinely nested inputs keep their parts.
  defp merge_singleton_parts(parts) do
    if Enum.all?(parts, fn part -> length(part) <= 1 end) do
      [Enum.concat(parts)]
    else
      parts
    end
  end

  defp get_field(row, field_name) when is_map(row) do
    Map.get(row, field_name) || Map.get(row, String.downcase(field_name))
  end

  defp get_field(_, _), do: nil

  # Shared helpers

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
    # e.g. "100-161" -> take midpoint
    case Regex.run(~r/(\d+)\s*[-–]\s*(\d+)/, val) do
      [_, low, high] ->
        {l, _} = Integer.parse(low)
        {h, _} = Integer.parse(high)
        (l + h) / 2.0

      _ ->
        case Float.parse(String.replace(val, ~r/[^0-9.]/, "")) do
          {f, _} when f > 0 -> f
          _ -> nil
        end
    end
  end

  defp parse_volt_class(_), do: nil

  # Status codes that explicitly mark a line as not energized. Anything else
  # -- nil, "NOT AVAILABLE", unknown codes -- is treated as in service:
  # HIFLD's STATUS field is sparsely populated (only a few dozen records are
  # genuinely inactive), and mapping unknowns to out_of_service discards
  # ~20% of the real network.
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
