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
  """

  alias PowerModel.Repo
  alias PowerModel.Grid.TransmissionLine
  alias PowerModel.Ingestion.HIFLD.API
  alias PowerModel.Ingestion.HIFLD.GeoJSON

  @service "Electric_Power_Transmission_Lines"

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

  Features without a usable voltage (VOLTAGE sentinel `-999999` AND an
  unparseable VOLT_CLASS) or with fewer than two coordinates are skipped and
  counted in the printed summary rather than inserted at a guessed voltage.
  """
  def ingest_geojson(path) do
    IO.puts("Ingesting transmission lines from #{path}...")

    # 1 = features seen, 2 = inserted, 3 = skipped (no voltage / no geometry)
    counter = :counters.new(3, [:atomics])

    path
    |> GeoJSON.stream_features!()
    |> Stream.map(fn feature ->
      :counters.add(counter, 1, 1)
      parse_geojson_feature(feature)
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
      if rem(count, 10_000) < 1000, do: IO.puts("  #{count} lines inserted...")
    end)
    |> Stream.run()

    seen = :counters.get(counter, 1)
    inserted = :counters.get(counter, 2)
    skipped = :counters.get(counter, 3)

    IO.puts(
      "Read #{seen} features: #{inserted} lines inserted, #{skipped} skipped (no usable voltage or geometry)."
    )

    {:ok, inserted}
  end

  @doc """
  Parse one vendored GeoJSON feature into an insertable attrs map, or nil.

  Field names follow the HIFLD Next schema: `source_ID` is the stable line id
  (the ArcGIS mirror calls it `ID`), and geometry arrives as LineString or
  MultiLineString rather than ArcGIS `paths`. Everything downstream —
  per-part length, HVDC marking, status mapping — is shared with the API path.
  """
  def parse_geojson_feature(%{"properties" => props} = feature) do
    parts = GeoJSON.line_parts(feature)
    coords = Enum.concat(parts)
    voltage = parse_voltage(props["VOLTAGE"], props["VOLT_CLASS"])
    source_id = to_string(props["source_ID"] || props["ID"] || props["OBJECTID"])

    if voltage && voltage > 0 && length(coords) >= 2 && source_id != "" do
      %{
        voltage_kv: voltage,
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

  def parse_geojson_feature(_), do: nil

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
