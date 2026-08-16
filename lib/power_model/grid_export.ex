defmodule PowerModel.GridExport do
  @moduledoc """
  Export grid data as compact binary/JSON files for the frontend map.

  Callable from both the Mix task (`mix power_model.export_grid_data`) and a
  production release (`PowerModel.Release.export_grid_data/0`) — therefore no
  Mix APIs in here.
  """

  require Logger

  # bus_loads.bin, the map's only bus-level position index:
  #
  #   header: "BLD" tag, version u8, record count u32 (little-endian)
  #   record: bus_id u32, lon f32, lat f32, demand_mw f32
  #
  # v1 carried the three floats and no bus id, so nothing bus-level — a step's
  # `bus_voltage`, a cascade's `ac_overlay` — could be placed on the map
  # (UIW-2). The tag exists because a v1 and a v2 file are otherwise
  # indistinguishable (both open with a plausible u32) and a v1 file read as v2
  # yields coordinates out of misaligned bytes rather than an error.
  @bus_loads_magic <<"BLD", 2>>

  # manifest.bin, the export set's CONTENT tag (UI-M18):
  #
  #   header: "GDM" tag, version u8
  #   body:   term_to_binary(PowerModel.Grid.export_signature/0)
  #
  # Same self-identifying-header discipline as bus_loads.bin above, and for
  # the same reason: a file from an older layout must announce itself rather
  # than decode into a plausible-looking wrong answer. The body is a term
  # rather than a fixed struct so a mismatch can be LOGGED with both sides —
  # "why did it regenerate" is the first question a cold start raises.
  #
  # The tag is written LAST by run/1, so an export that crashed part-way is
  # not certified current by a manifest it never earned.
  @manifest_magic <<"GDM", 1>>
  @manifest_file "manifest.bin"

  @doc """
  Regenerate the map data files at application boot when they are missing,
  empty, in an old layout, or no longer match the database.

  Fly machines get a fresh image filesystem on every cold start, so the
  DB-derived exports must be rebuilt; locally and on warm restarts the files
  exist and this is a no-op. DAT-7: an export produced before ingestion ran
  (0 records) is treated the same as a missing one, so a stale empty file
  can never permanently blank the map.

  UI-M18: the first three checks are about FORMAT and cannot see the database
  move underneath a perfectly well-formed export. After a re-ingest the map
  served 13,290 fewer in-service lines than the DB had — trips the browser
  could neither draw nor repaint — and a demand overlay from before the load
  reallocation, with nothing in the system able to notice. The content tag
  closes that: see `PowerModel.Grid.export_signature/0` for what it covers
  and what it does not.

  Never crashes the supervision tree. A database that cannot answer the
  signature query leaves the existing export alone rather than blanking it.
  """
  def ensure_exported(dir \\ nil) do
    dir = dir || Application.app_dir(:power_model, "priv/static/grid_data")

    cond do
      not usable_export?(Path.join(dir, "transmission.bin")) ->
        Logger.info("grid_data exports missing or empty; regenerating from database")
        run(dir)

      not current_bus_loads?(Path.join(dir, "bus_loads.bin")) ->
        Logger.info("grid_data bus_loads.bin predates the bus-id layout; regenerating")
        run(dir)

      true ->
        ensure_current_content(dir)
    end
  rescue
    e -> Logger.warning("grid_data export at boot failed: #{Exception.message(e)}")
  catch
    kind, reason -> Logger.warning("grid_data export at boot failed: #{kind} #{inspect(reason)}")
  end

  defp ensure_current_content(dir) do
    if Application.get_env(:power_model, :skip_repo, false) do
      # No database to compare against (the test boot, and any release started
      # without one). The format checks above already passed, so the files
      # stand: an instance that cannot read the DB has no basis for calling
      # them stale.
      :ok
    else
      compare_content(dir)
    end
  end

  defp compare_content(dir) do
    signature = PowerModel.Grid.export_signature()

    case read_manifest(dir) do
      {:ok, ^signature} ->
        :ok

      {:ok, stored} ->
        Logger.info(
          "grid_data exports no longer match the database; regenerating " <>
            "(#{describe_drift(stored, signature)})"
        )

        run(dir)

      :error ->
        Logger.info("grid_data exports carry no content tag; regenerating")
        run(dir)
    end
  end

  defp read_manifest(dir) do
    with {:ok, @manifest_magic <> body} <- File.read(Path.join(dir, @manifest_file)),
         {:ok, term} <- safe_term(body) do
      {:ok, term}
    else
      _ -> :error
    end
  end

  defp safe_term(body) do
    {:ok, :erlang.binary_to_term(body, [:safe])}
  rescue
    _ -> :error
  end

  @doc """
  Write the content tag for the export set currently in `dir`.

  Public so a test that hand-writes marker export files can give them a
  GENUINE tag instead of the check being weakened to let untagged files pass.
  """
  def write_manifest(dir) do
    File.write!(
      Path.join(dir, @manifest_file),
      @manifest_magic <> :erlang.term_to_binary(PowerModel.Grid.export_signature())
    )
  end

  # Names only the parts that moved: on a cold start this line is the whole
  # explanation of why the machine spent 30 s re-exporting.
  defp describe_drift(stored, current) do
    [
      drift_pairs("count", stored[:counts], current[:counts]),
      drift_pairs("updated", stored[:updated_at], current[:updated_at])
    ]
    |> List.flatten()
    |> case do
      [] -> "no field differs; tag layout changed"
      diffs -> Enum.join(diffs, ", ")
    end
  end

  defp drift_pairs(label, stored, current) when is_map(stored) and is_map(current) do
    for {key, now} <- Enum.sort(current), Map.get(stored, key) != now do
      "#{key} #{label} #{inspect(Map.get(stored, key))} -> #{inspect(now)}"
    end
  end

  defp drift_pairs(label, _stored, _current), do: ["#{label}s absent from the stored tag"]

  # A usable export exists and holds at least one record (the leading u32 is
  # the record count).
  defp usable_export?(path) do
    case File.read(path) do
      {:ok, <<count::unsigned-little-32, _rest::binary>>} -> count > 0
      _ -> false
    end
  end

  # A v1 bus_loads.bin (no tag, no bus id) parses as garbage under the current
  # reader, and no other file in the export set would trigger a rebuild — so a
  # boot that finds a usable transmission.bin has to check this one too.
  defp current_bus_loads?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, byte_size(@bus_loads_magic))) do
      {:ok, @bus_loads_magic} -> true
      _ -> false
    end
  end

  @doc "Export all map data files into `output_dir`."
  def run(output_dir) do
    File.mkdir_p!(output_dir)

    export_generators(output_dir)
    export_transmission_lines(output_dir)
    export_substations(output_dir)
    export_transformers(output_dir)
    export_bus_loads(output_dir)
    export_water_facilities(output_dir)
    export_datacenters(output_dir)

    # Last, and only on the success path: a manifest written before the files
    # would certify a half-finished export as current (UI-M18).
    write_manifest(output_dir)

    IO.puts("Grid data exported to #{output_dir}/")
    :ok
  end

  defp export_generators(dir) do
    generators = PowerModel.Grid.export_generators()
    count = length(generators)

    binary =
      <<count::unsigned-little-32>> <>
        Enum.reduce(generators, <<>>, fn gen, acc ->
          {lon, lat} = extract_coords(gen.coordinates)
          fuel_code = fuel_type_code(gen.fuel_type)

          acc <>
            <<
              gen.id::unsigned-little-32,
              lon::float-little-32,
              lat::float-little-32,
              gen.p_max_mw || 0.0::float-little-32,
              fuel_code::unsigned-8,
              0::unsigned-8
            >>
        end)

    File.write!(Path.join(dir, "generators.bin"), binary)
    IO.puts("  generators.bin: #{count} records, #{byte_size(binary)} bytes")
  end

  defp export_transmission_lines(dir) do
    lines = PowerModel.Grid.export_transmission_lines()
    count = length(lines)

    binary =
      <<count::unsigned-little-32>> <>
        Enum.reduce(lines, <<>>, fn line, acc ->
          coords = extract_line_coords(line.geometry)
          num_points = length(coords)

          line_header = <<
            line.id::unsigned-little-32,
            line.voltage_kv || 0.0::float-little-32,
            line.rating_a_mva || 0.0::float-little-32,
            num_points::unsigned-little-16,
            0::unsigned-8
          >>

          point_data =
            Enum.reduce(coords, <<>>, fn {lon, lat}, pa ->
              pa <> <<lon::float-little-32, lat::float-little-32>>
            end)

          acc <> line_header <> point_data
        end)

    File.write!(Path.join(dir, "transmission.bin"), binary)
    IO.puts("  transmission.bin: #{count} records, #{byte_size(binary)} bytes")
  end

  defp export_substations(dir) do
    substations = PowerModel.Grid.export_substations()
    count = length(substations)

    binary =
      <<count::unsigned-little-32>> <>
        Enum.reduce(substations, <<>>, fn sub, acc ->
          {lon, lat} = extract_coords(sub.coordinates)

          acc <>
            <<
              sub.id::unsigned-little-32,
              lon::float-little-32,
              lat::float-little-32,
              sub.max_voltage_kv || 0.0::float-little-32,
              0::unsigned-8
            >>
        end)

    File.write!(Path.join(dir, "substations.bin"), binary)
    IO.puts("  substations.bin: #{count} records, #{byte_size(binary)} bytes")
  end

  # Per-bus points for the H3 hexbin overlays (demand density, voltage depth);
  # layout at @bus_loads_magic. Aggregation into H3 cells happens client-side
  # (h3-js) so resolution can follow zoom.
  defp export_bus_loads(dir) do
    loads = PowerModel.Grid.export_bus_loads()
    count = length(loads)

    binary =
      @bus_loads_magic <>
        <<count::unsigned-little-32>> <>
        Enum.reduce(loads, <<>>, fn l, acc ->
          {lon, lat} = extract_coords(l.coordinates)

          acc <>
            <<
              l.bus_id::unsigned-little-32,
              lon::float-little-32,
              lat::float-little-32,
              l.demand_mw || 0.0::float-little-32
            >>
        end)

    File.write!(Path.join(dir, "bus_loads.bin"), binary)
    IO.puts("  bus_loads.bin: #{count} records, #{byte_size(binary)} bytes")
  end

  defp export_transformers(dir) do
    transformers = PowerModel.Grid.export_transformers()
    count = length(transformers)

    binary =
      <<count::unsigned-little-32>> <>
        Enum.reduce(transformers, <<>>, fn t, acc ->
          {lon, lat} = extract_coords(t.coordinates)

          acc <>
            <<
              t.id::unsigned-little-32,
              lon::float-little-32,
              lat::float-little-32,
              t.rated_mva || 0.0::float-little-32,
              0::unsigned-8
            >>
        end)

    File.write!(Path.join(dir, "transformers.bin"), binary)
    IO.puts("  transformers.bin: #{count} records, #{byte_size(binary)} bytes")
  end

  defp export_water_facilities(dir) do
    facilities = PowerModel.Grid.export_water_facilities()
    count = length(facilities)

    json =
      Jason.encode!(%{
        count: count,
        facilities:
          Enum.map(facilities, fn f ->
            {lon, lat} = extract_coords(f.coordinates)

            %{
              id: f.id,
              lon: lon,
              lat: lat,
              # UI-L12: TextLayer crashes on a null label
              name: f.name || "",
              facilityType: water_facility_type_code(f.facility_type),
              capacityMgd: f.capacity_mgd || 0.0,
              powerMw: f.power_consumption_mw || 0.0,
              storageAcreFeet: f.storage_acre_feet || 0.0,
              busId: f.bus_id,
              state: 0
            }
          end)
      })

    File.write!(Path.join(dir, "water_facilities.json"), json)
    IO.puts("  water_facilities.json: #{count} records, #{byte_size(json)} bytes")
  end

  defp export_datacenters(dir) do
    datacenters = PowerModel.Grid.export_datacenters()
    count = length(datacenters)

    json =
      Jason.encode!(%{
        count: count,
        datacenters:
          Enum.map(datacenters, fn d ->
            {lon, lat} = extract_coords(d.coordinates)

            %{
              id: d.id,
              lon: lon,
              lat: lat,
              # UI-L12: TextLayer crashes on a null label
              name: d.name || "",
              operator: d.operator || "",
              facilityType: datacenter_type_code(d.facility_type),
              powerMw: d.power_mw || 0.0,
              busId: d.bus_id,
              state: 0
            }
          end)
      })

    File.write!(Path.join(dir, "datacenters.json"), json)
    IO.puts("  datacenters.json: #{count} records, #{byte_size(json)} bytes")
  end

  defp extract_coords(nil), do: {0.0, 0.0}
  defp extract_coords(%Geo.Point{coordinates: {lon, lat}}), do: {lon, lat}
  defp extract_coords(_), do: {0.0, 0.0}

  defp extract_line_coords(nil), do: []

  defp extract_line_coords(%Geo.LineString{coordinates: coords}) do
    Enum.map(coords, fn
      {lon, lat} -> {lon, lat}
      {lon, lat, _} -> {lon, lat}
    end)
  end

  defp extract_line_coords(_), do: []

  defp fuel_type_code(nil), do: 0

  defp fuel_type_code(ft) do
    case String.upcase(ft) do
      "NG" -> 1
      "SUB" -> 2
      "BIT" -> 3
      "NUC" -> 4
      "WAT" -> 5
      "WND" -> 6
      "SUN" -> 7
      "DFO" -> 8
      "RFO" -> 9
      "WDS" -> 10
      "GEO" -> 11
      "IMPORT" -> 12
      _ -> 0
    end
  end

  defp water_facility_type_code("desalination"), do: 1
  defp water_facility_type_code("wastewater"), do: 2
  defp water_facility_type_code("treatment"), do: 3
  defp water_facility_type_code("pump_station"), do: 4
  defp water_facility_type_code("reservoir"), do: 5
  defp water_facility_type_code("pipeline"), do: 6
  defp water_facility_type_code(_), do: 0

  defp datacenter_type_code("hyperscale"), do: 1
  defp datacenter_type_code("colocation"), do: 2
  defp datacenter_type_code("ai_training"), do: 3
  defp datacenter_type_code("enterprise"), do: 4
  defp datacenter_type_code("crypto"), do: 5
  defp datacenter_type_code(_), do: 0
end
