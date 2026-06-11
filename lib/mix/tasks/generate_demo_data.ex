defmodule Mix.Tasks.PowerModel.GenerateDemoData do
  @moduledoc """
  Generate synthetic demo grid data for frontend visualization.
  Creates binary files matching the format expected by DataStore.js
  without requiring a database or real data ingestion.

  ## Usage

      mix power_model.generate_demo_data
  """

  use Mix.Task

  @shortdoc "Generate synthetic demo binary grid data"

  @output_dir "priv/static/grid_data"

  @generator_sites [
    {-73.98, 40.75, 1200.0, 4, "Indian Point, NY"},
    {-76.61, 39.28, 900.0, 3, "Brandon Shores, MD"},
    {-80.84, 35.22, 2200.0, 4, "McGuire, NC"},
    {-82.52, 27.95, 1800.0, 1, "Manatee, FL"},
    {-87.62, 41.88, 1400.0, 1, "Fisk, IL"},
    {-83.04, 42.33, 1100.0, 3, "Monroe, MI"},
    {-84.39, 33.75, 3600.0, 4, "Vogtle, GA"},
    {-86.78, 36.16, 1000.0, 5, "Old Hickory, TN"},
    {-90.07, 29.95, 2000.0, 1, "Nine Mile Point, LA"},
    {-71.06, 42.36, 1500.0, 1, "Mystic, MA"},
    {-75.16, 39.95, 800.0, 1, "Schuylkill, PA"},
    {-81.69, 41.50, 1300.0, 4, "Perry, OH"},
    {-77.03, 38.90, 600.0, 1, "DC Peaker"},
    {-79.93, 40.44, 700.0, 1, "Pittsburgh"},
    {-74.17, 40.74, 500.0, 1, "Newark, NJ"},
    {-88.00, 42.00, 1800.0, 4, "Byron, IL"},
    {-85.76, 38.25, 800.0, 2, "Mill Creek, KY"},
    {-93.27, 44.98, 900.0, 1, "Riverside, MN"},
    {-92.17, 38.58, 600.0, 3, "Callaway, MO"},
    {-78.64, 35.77, 1100.0, 1, "Raleigh, NC"},
    {-122.33, 47.61, 1500.0, 5, "Grand Coulee, WA"},
    {-121.47, 38.58, 1200.0, 1, "Sacramento, CA"},
    {-118.24, 34.05, 2000.0, 1, "LA Basin, CA"},
    {-112.07, 33.45, 3000.0, 4, "Palo Verde, AZ"},
    {-111.89, 40.76, 500.0, 2, "Hunter, UT"},
    {-104.99, 39.74, 800.0, 1, "Cherokee, CO"},
    {-116.21, 43.62, 400.0, 5, "Boise Hydro, ID"},
    {-122.68, 45.52, 600.0, 5, "Portland Hydro, OR"},
    {-115.14, 36.17, 900.0, 7, "Nevada Solar"},
    {-119.79, 36.74, 700.0, 7, "CA Solar Farm"},
    {-106.65, 35.08, 500.0, 1, "Albuquerque, NM"},
    {-117.16, 32.72, 800.0, 1, "San Diego, CA"},
    {-109.05, 44.42, 300.0, 6, "WY Wind"},
    {-120.50, 46.60, 400.0, 6, "WA Wind"},
    {-97.74, 30.27, 2400.0, 4, "South Texas Nuclear"},
    {-96.80, 32.78, 1800.0, 1, "Dallas Gas"},
    {-95.36, 29.76, 2200.0, 1, "Houston Gas"},
    {-98.49, 29.42, 1000.0, 1, "San Antonio"},
    {-101.85, 35.20, 1200.0, 6, "TX Panhandle Wind"},
    {-100.44, 31.44, 800.0, 6, "West TX Wind"},
    {-97.33, 27.80, 600.0, 6, "Corpus Wind"},
    {-96.40, 30.67, 500.0, 7, "TX Solar"}
  ]

  @substation_sites [
    {-73.95, 40.78, 345.0},
    {-74.00, 40.70, 138.0},
    {-76.60, 39.30, 500.0},
    {-76.55, 39.25, 230.0},
    {-80.80, 35.20, 500.0},
    {-80.90, 35.25, 230.0},
    {-82.50, 27.90, 230.0},
    {-82.45, 28.00, 138.0},
    {-87.60, 41.85, 345.0},
    {-87.65, 41.90, 138.0},
    {-83.00, 42.30, 345.0},
    {-83.10, 42.35, 138.0},
    {-84.40, 33.80, 500.0},
    {-84.35, 33.70, 230.0},
    {-86.75, 36.15, 230.0},
    {-86.80, 36.20, 138.0},
    {-90.10, 29.90, 230.0},
    {-90.05, 30.00, 138.0},
    {-71.05, 42.35, 345.0},
    {-71.10, 42.40, 138.0},
    {-75.15, 39.95, 230.0},
    {-75.20, 39.90, 138.0},
    {-81.70, 41.50, 345.0},
    {-79.90, 40.45, 230.0},
    {-77.00, 38.90, 230.0},
    {-78.60, 35.75, 230.0},
    {-88.00, 42.05, 345.0},
    {-85.75, 38.20, 230.0},
    {-93.25, 45.00, 345.0},
    {-92.20, 38.60, 230.0},
    {-122.30, 47.60, 500.0},
    {-122.35, 47.55, 230.0},
    {-121.45, 38.55, 500.0},
    {-121.50, 38.60, 230.0},
    {-118.20, 34.00, 500.0},
    {-118.30, 34.10, 230.0},
    {-112.05, 33.45, 500.0},
    {-112.10, 33.50, 230.0},
    {-111.90, 40.75, 345.0},
    {-104.95, 39.70, 345.0},
    {-116.20, 43.60, 230.0},
    {-122.65, 45.50, 230.0},
    {-115.10, 36.15, 345.0},
    {-119.80, 36.75, 230.0},
    {-106.60, 35.05, 230.0},
    {-117.15, 32.70, 230.0},
    {-109.00, 44.40, 230.0},
    {-120.45, 46.55, 230.0},
    {-97.70, 30.25, 345.0},
    {-97.75, 30.30, 138.0},
    {-96.80, 32.80, 345.0},
    {-96.75, 32.75, 138.0},
    {-95.35, 29.75, 345.0},
    {-95.40, 29.80, 138.0},
    {-98.50, 29.45, 345.0},
    {-98.45, 29.40, 138.0},
    {-101.80, 35.15, 345.0},
    {-100.40, 31.40, 230.0},
    {-97.30, 27.80, 230.0},
    {-96.35, 30.65, 138.0}
  ]

  @impl Mix.Task
  def run(_args) do
    File.mkdir_p!(@output_dir)

    generators = build_generators()
    substations = build_substations()
    lines = build_transmission_lines(substations)

    write_generators(generators)
    write_transmission_lines(lines)
    write_substations(substations)

    Mix.shell().info("""
    Demo data generated in #{@output_dir}/:
      generators.bin:   #{length(generators)} generators
      transmission.bin: #{length(lines)} lines
      substations.bin:  #{length(substations)} substations
    """)
  end

  defp build_generators do
    @generator_sites
    |> Enum.with_index(1)
    |> Enum.map(fn {{lon, lat, mw, fuel, _name}, id} ->
      %{id: id, lon: lon, lat: lat, p_max_mw: mw, fuel_code: fuel}
    end)
  end

  defp build_substations do
    @substation_sites
    |> Enum.with_index(1)
    |> Enum.map(fn {{lon, lat, kv}, id} ->
      %{id: id, lon: lon, lat: lat, max_voltage_kv: kv}
    end)
  end

  defp build_transmission_lines(substations) do
    sub_list = Enum.to_list(substations)
    n = length(sub_list)

    pairs =
      for i <- 0..(n - 2), j <- (i + 1)..(n - 1) do
        s1 = Enum.at(sub_list, i)
        s2 = Enum.at(sub_list, j)
        dist = haversine_km(s1.lon, s1.lat, s2.lon, s2.lat)
        voltage = min(s1.max_voltage_kv, s2.max_voltage_kv)

        max_dist =
          case voltage do
            v when v >= 500 -> 800.0
            v when v >= 345 -> 500.0
            v when v >= 230 -> 300.0
            _ -> 100.0
          end

        if dist < max_dist and dist > 5.0 do
          {s1, s2, dist, voltage}
        else
          nil
        end
      end
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn {_, _, dist, _} -> dist end)
      |> Enum.take(150)

    pairs
    |> Enum.with_index(1)
    |> Enum.map(fn {{s1, s2, _dist, voltage}, id} ->
      rating =
        case voltage do
          v when v >= 500 -> 1800.0
          v when v >= 345 -> 900.0
          v when v >= 230 -> 450.0
          _ -> 250.0
        end

      %{
        id: id,
        voltage_kv: voltage,
        rating_mva: rating,
        path: [{s1.lon, s1.lat}, {s2.lon, s2.lat}]
      }
    end)
  end

  defp write_generators(generators) do
    count = length(generators)

    binary =
      <<count::unsigned-little-32>> <>
        Enum.reduce(generators, <<>>, fn gen, acc ->
          acc <>
            <<
              gen.id::unsigned-little-32,
              gen.lon::float-little-32,
              gen.lat::float-little-32,
              gen.p_max_mw::float-little-32,
              gen.fuel_code::unsigned-8,
              0::unsigned-8
            >>
        end)

    path = Path.join(@output_dir, "generators.bin")
    File.write!(path, binary)
    Mix.shell().info("  generators.bin: #{count} records, #{byte_size(binary)} bytes")
  end

  defp write_transmission_lines(lines) do
    count = length(lines)

    binary =
      <<count::unsigned-little-32>> <>
        Enum.reduce(lines, <<>>, fn line, acc ->
          num_points = length(line.path)

          header = <<
            line.id::unsigned-little-32,
            line.voltage_kv::float-little-32,
            line.rating_mva::float-little-32,
            num_points::unsigned-little-16,
            0::unsigned-8
          >>

          point_data =
            Enum.reduce(line.path, <<>>, fn {lon, lat}, pa ->
              pa <> <<lon::float-little-32, lat::float-little-32>>
            end)

          acc <> header <> point_data
        end)

    path = Path.join(@output_dir, "transmission.bin")
    File.write!(path, binary)
    Mix.shell().info("  transmission.bin: #{count} records, #{byte_size(binary)} bytes")
  end

  defp write_substations(substations) do
    count = length(substations)

    binary =
      <<count::unsigned-little-32>> <>
        Enum.reduce(substations, <<>>, fn sub, acc ->
          acc <>
            <<
              sub.id::unsigned-little-32,
              sub.lon::float-little-32,
              sub.lat::float-little-32,
              sub.max_voltage_kv::float-little-32,
              0::unsigned-8
            >>
        end)

    path = Path.join(@output_dir, "substations.bin")
    File.write!(path, binary)
    Mix.shell().info("  substations.bin: #{count} records, #{byte_size(binary)} bytes")
  end

  defp haversine_km(lon1, lat1, lon2, lat2) do
    r = 6371.0
    dlat = deg_to_rad(lat2 - lat1)
    dlon = deg_to_rad(lon2 - lon1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(deg_to_rad(lat1)) * :math.cos(deg_to_rad(lat2)) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    r * c
  end

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0
end
