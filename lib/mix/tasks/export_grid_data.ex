defmodule Mix.Tasks.PowerModel.ExportGridData do
  @moduledoc """
  Export grid data as compact binary files for frontend consumption.

  ## Usage

      mix power_model.export_grid_data

  Writes to priv/static/grid_data/:
    - generators.bin
    - transmission.bin
    - substations.bin
  """

  use Mix.Task

  @shortdoc "Export grid data as binary files for frontend"

  @output_dir "priv/static/grid_data"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    File.mkdir_p!(@output_dir)

    export_generators()
    export_transmission_lines()
    export_substations()
    export_water_facilities()
    export_critical_facilities()

    Mix.shell().info("Grid data exported to #{@output_dir}/")
  end

  defp export_generators do
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

    File.write!(Path.join(@output_dir, "generators.bin"), binary)
    Mix.shell().info("  generators.bin: #{count} records, #{byte_size(binary)} bytes")
  end

  defp export_transmission_lines do
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

    File.write!(Path.join(@output_dir, "transmission.bin"), binary)
    Mix.shell().info("  transmission.bin: #{count} records, #{byte_size(binary)} bytes")
  end

  defp export_substations do
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

    File.write!(Path.join(@output_dir, "substations.bin"), binary)
    Mix.shell().info("  substations.bin: #{count} records, #{byte_size(binary)} bytes")
  end

  defp export_water_facilities do
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

    File.write!(Path.join(@output_dir, "water_facilities.json"), json)
    Mix.shell().info("  water_facilities.json: #{count} records, #{byte_size(json)} bytes")
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

  defp export_critical_facilities do
    facilities = PowerModel.Grid.export_critical_facilities()
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
          category: critical_facility_category_code(f.category),
          facilityType: f.facility_type,
          beds: f.beds,
          trauma: f.trauma,
          powerMw: f.estimated_power_mw || 0.0,
          busId: f.bus_id,
          state: 0
        }
      end)
    })

    File.write!(Path.join(@output_dir, "critical_facilities.json"), json)
    Mix.shell().info("  critical_facilities.json: #{count} records, #{byte_size(json)} bytes")
  end

  defp critical_facility_category_code("hospital"), do: 1
  defp critical_facility_category_code("fire_station"), do: 2
  defp critical_facility_category_code("police_station"), do: 3
  defp critical_facility_category_code("ems_station"), do: 4
  defp critical_facility_category_code(_), do: 0

  defp water_facility_type_code("desalination"), do: 1
  defp water_facility_type_code("wastewater"), do: 2
  defp water_facility_type_code("treatment"), do: 3
  defp water_facility_type_code("pump_station"), do: 4
  defp water_facility_type_code("reservoir"), do: 5
  defp water_facility_type_code("pipeline"), do: 6
  defp water_facility_type_code(_), do: 0
end
