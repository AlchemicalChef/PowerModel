defmodule PowerModel.GridExport do
  @moduledoc """
  Export grid data as compact binary/JSON files for the frontend map.

  Callable from both the Mix task (`mix power_model.export_grid_data`) and a
  production release (`PowerModel.Release.export_grid_data/0`) — therefore no
  Mix APIs in here.
  """

  require Logger

  @doc """
  Regenerate the map data files at application boot when they are missing.

  Fly machines get a fresh image filesystem on every cold start, so the
  DB-derived exports must be rebuilt; locally and on warm restarts the files
  exist and this is a no-op. Never crashes the supervision tree.
  """
  def ensure_exported do
    dir = Application.app_dir(:power_model, "priv/static/grid_data")

    if File.exists?(Path.join(dir, "transmission.bin")) do
      :ok
    else
      Logger.info("grid_data exports missing; regenerating from database")
      run(dir)
    end
  rescue
    e -> Logger.warning("grid_data export at boot failed: #{Exception.message(e)}")
  catch
    kind, reason -> Logger.warning("grid_data export at boot failed: #{kind} #{inspect(reason)}")
  end

  @doc "Export all map data files into `output_dir`."
  def run(output_dir) do
    File.mkdir_p!(output_dir)

    export_generators(output_dir)
    export_transmission_lines(output_dir)
    export_substations(output_dir)
    export_transformers(output_dir)
    export_water_facilities(output_dir)
    export_datacenters(output_dir)

    IO.puts("Grid data exported to #{output_dir}/")
    :ok
  end

  defp export_generators(dir) do
    generators = PowerModel.Grid.export_generators()
    count = length(generators)

    binary = <<count::unsigned-little-32>> <>
      Enum.reduce(generators, <<>>, fn gen, acc ->
        {lon, lat} = extract_coords(gen.coordinates)
        fuel_code = fuel_type_code(gen.fuel_type)

        acc <> <<
          gen.id::unsigned-little-32,
          lon::float-little-32,
          lat::float-little-32,
          (gen.p_max_mw || 0.0)::float-little-32,
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

    binary = <<count::unsigned-little-32>> <>
      Enum.reduce(lines, <<>>, fn line, acc ->
        coords = extract_line_coords(line.geometry)
        num_points = length(coords)

        line_header = <<
          line.id::unsigned-little-32,
          (line.voltage_kv || 0.0)::float-little-32,
          (line.rating_a_mva || 0.0)::float-little-32,
          num_points::unsigned-little-16,
          0::unsigned-8
        >>

        point_data = Enum.reduce(coords, <<>>, fn {lon, lat}, pa ->
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

    binary = <<count::unsigned-little-32>> <>
      Enum.reduce(substations, <<>>, fn sub, acc ->
        {lon, lat} = extract_coords(sub.coordinates)

        acc <> <<
          sub.id::unsigned-little-32,
          lon::float-little-32,
          lat::float-little-32,
          (sub.max_voltage_kv || 0.0)::float-little-32,
          0::unsigned-8
        >>
      end)

    File.write!(Path.join(dir, "substations.bin"), binary)
    IO.puts("  substations.bin: #{count} records, #{byte_size(binary)} bytes")
  end

  defp export_transformers(dir) do
    transformers = PowerModel.Grid.export_transformers()
    count = length(transformers)

    binary = <<count::unsigned-little-32>> <>
      Enum.reduce(transformers, <<>>, fn t, acc ->
        {lon, lat} = extract_coords(t.coordinates)

        acc <> <<
          t.id::unsigned-little-32,
          lon::float-little-32,
          lat::float-little-32,
          (t.rated_mva || 0.0)::float-little-32,
          0::unsigned-8
        >>
      end)

    File.write!(Path.join(dir, "transformers.bin"), binary)
    IO.puts("  transformers.bin: #{count} records, #{byte_size(binary)} bytes")
  end

  defp export_water_facilities(dir) do
    facilities = PowerModel.Grid.export_water_facilities()
    count = length(facilities)

    json = Jason.encode!(%{
      count: count,
      facilities: Enum.map(facilities, fn f ->
        {lon, lat} = extract_coords(f.coordinates)
        %{
          id: f.id,
          lon: lon,
          lat: lat,
          name: f.name,
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

    json = Jason.encode!(%{
      count: count,
      datacenters: Enum.map(datacenters, fn d ->
        {lon, lat} = extract_coords(d.coordinates)
        %{
          id: d.id,
          lon: lon,
          lat: lat,
          name: d.name,
          operator: d.operator,
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
