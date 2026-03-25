defmodule PowerModel.Ingestion.InternationalConnections do
  @moduledoc """
  Creates known US-Canada and US-Mexico international tie lines with
  boundary equivalent buses representing the foreign grid endpoints.

  Data sourced from NERC/OASIS flowgate listings, EIA-411, and public
  interconnection maps. Coordinates are at the approximate border
  crossing points. Foreign-side buses carry small equivalent generators
  representing import capacity.
  """

  require Logger

  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, Generator, TransmissionLine, Interconnection}

  @us_canada_ties [
    %{name: "HQ Phase II HVDC (Des Cantons–Comerford)",
      us_coords: {-71.96, 44.46}, foreign_coords: {-71.96, 45.01},
      voltage_kv: 450.0, rating_mva: 2000.0, country: "CA", region: "Quebec",
      interconnection: "Eastern", x_pu: 0.005},
    %{name: "HQ HVDC Châteauguay–Sandy Pond",
      us_coords: {-73.75, 42.08}, foreign_coords: {-73.75, 45.35},
      voltage_kv: 450.0, rating_mva: 2000.0, country: "CA", region: "Quebec",
      interconnection: "Eastern", x_pu: 0.005},
    %{name: "Highgate HVDC (VT–QC)",
      us_coords: {-72.02, 44.97}, foreign_coords: {-72.02, 45.02},
      voltage_kv: 120.0, rating_mva: 225.0, country: "CA", region: "Quebec",
      interconnection: "Eastern", x_pu: 0.01},
    %{name: "QC–VT 120kV (Derby Line)",
      us_coords: {-72.13, 44.98}, foreign_coords: {-72.13, 45.01},
      voltage_kv: 120.0, rating_mva: 100.0, country: "CA", region: "Quebec",
      interconnection: "Eastern", x_pu: 0.02},
    %{name: "QC–NY 765kV (Châteauguay–Massena)",
      us_coords: {-74.89, 44.93}, foreign_coords: {-74.10, 45.35},
      voltage_kv: 765.0, rating_mva: 1800.0, country: "CA", region: "Quebec",
      interconnection: "Eastern", x_pu: 0.003},

    %{name: "Niagara Falls 345kV (Beck–Niagara)",
      us_coords: {-79.06, 43.09}, foreign_coords: {-79.08, 43.11},
      voltage_kv: 345.0, rating_mva: 1500.0, country: "CA", region: "Ontario",
      interconnection: "Eastern", x_pu: 0.008},
    %{name: "St. Lawrence 230kV (Cornwall–Massena)",
      us_coords: {-74.89, 44.93}, foreign_coords: {-74.73, 45.02},
      voltage_kv: 230.0, rating_mva: 500.0, country: "CA", region: "Ontario",
      interconnection: "Eastern", x_pu: 0.012},
    %{name: "ON–NY 115kV (Thousand Islands)",
      us_coords: {-76.02, 44.31}, foreign_coords: {-76.02, 44.37},
      voltage_kv: 115.0, rating_mva: 150.0, country: "CA", region: "Ontario",
      interconnection: "Eastern", x_pu: 0.025},

    %{name: "ON–MI 345kV (Lambton–St. Clair)",
      us_coords: {-82.42, 42.60}, foreign_coords: {-82.42, 42.98},
      voltage_kv: 345.0, rating_mva: 1200.0, country: "CA", region: "Ontario",
      interconnection: "Eastern", x_pu: 0.01},
    %{name: "ON–MI 230kV (Detroit–Windsor)",
      us_coords: {-83.04, 42.33}, foreign_coords: {-83.04, 42.31},
      voltage_kv: 230.0, rating_mva: 400.0, country: "CA", region: "Ontario",
      interconnection: "Eastern", x_pu: 0.015},

    %{name: "MB–MN 500kV (Dorsey–Forbes)",
      us_coords: {-96.82, 48.99}, foreign_coords: {-97.15, 49.88},
      voltage_kv: 500.0, rating_mva: 1850.0, country: "CA", region: "Manitoba",
      interconnection: "Eastern", x_pu: 0.006},
    %{name: "MB–MN 230kV (Glenboro–International Falls)",
      us_coords: {-93.41, 48.60}, foreign_coords: {-99.33, 49.18},
      voltage_kv: 230.0, rating_mva: 300.0, country: "CA", region: "Manitoba",
      interconnection: "Eastern", x_pu: 0.02},
    %{name: "MB–ND 230kV (Emerson–Drayton)",
      us_coords: {-97.23, 48.60}, foreign_coords: {-97.23, 49.00},
      voltage_kv: 230.0, rating_mva: 250.0, country: "CA", region: "Manitoba",
      interconnection: "Eastern", x_pu: 0.02},

    %{name: "SK–ND 230kV (Boundary Dam–Tioga)",
      us_coords: {-103.97, 48.99}, foreign_coords: {-104.98, 49.01},
      voltage_kv: 230.0, rating_mva: 150.0, country: "CA", region: "Saskatchewan",
      interconnection: "Eastern", x_pu: 0.03},

    %{name: "NB–ME 345kV (Pt. Lepreau–Orrington)",
      us_coords: {-67.78, 45.04}, foreign_coords: {-66.45, 45.07},
      voltage_kv: 345.0, rating_mva: 1000.0, country: "CA", region: "New Brunswick",
      interconnection: "Eastern", x_pu: 0.01},
    %{name: "NB–ME 138kV (Woodland–St. Stephen)",
      us_coords: {-67.55, 45.19}, foreign_coords: {-67.28, 45.20},
      voltage_kv: 138.0, rating_mva: 200.0, country: "CA", region: "New Brunswick",
      interconnection: "Eastern", x_pu: 0.02},

    %{name: "BC–WA 500kV (Ingledow–Custer)",
      us_coords: {-122.77, 48.96}, foreign_coords: {-122.77, 49.15},
      voltage_kv: 500.0, rating_mva: 3150.0, country: "CA", region: "British Columbia",
      interconnection: "Western", x_pu: 0.004},
    %{name: "BC–WA 230kV (Boundary–Nelway)",
      us_coords: {-117.43, 48.99}, foreign_coords: {-117.43, 49.01},
      voltage_kv: 230.0, rating_mva: 600.0, country: "CA", region: "British Columbia",
      interconnection: "Western", x_pu: 0.015},
    %{name: "BC–WA 230kV (Oliver–Oroville)",
      us_coords: {-119.44, 48.99}, foreign_coords: {-119.44, 49.10},
      voltage_kv: 230.0, rating_mva: 400.0, country: "CA", region: "British Columbia",
      interconnection: "Western", x_pu: 0.015},

    %{name: "AB–MT 230kV (Lethbridge–Shelby)",
      us_coords: {-111.86, 48.99}, foreign_coords: {-112.79, 49.70},
      voltage_kv: 230.0, rating_mva: 300.0, country: "CA", region: "Alberta",
      interconnection: "Western", x_pu: 0.025},
    %{name: "AB–MT 230kV (Aden–Wild Horse)",
      us_coords: {-110.00, 49.00}, foreign_coords: {-110.00, 49.20},
      voltage_kv: 230.0, rating_mva: 300.0, country: "CA", region: "Alberta",
      interconnection: "Western", x_pu: 0.025}
  ]

  @us_mexico_ties [
    %{name: "Eagle Pass HVDC Back-to-Back",
      us_coords: {-100.49, 28.71}, foreign_coords: {-100.49, 28.69},
      voltage_kv: 138.0, rating_mva: 36.0, country: "MX", region: "Coahuila",
      interconnection: "ERCOT", x_pu: 0.01},
    %{name: "Laredo VFT (Railroad)",
      us_coords: {-99.51, 27.51}, foreign_coords: {-99.51, 27.49},
      voltage_kv: 138.0, rating_mva: 100.0, country: "MX", region: "Tamaulipas",
      interconnection: "ERCOT", x_pu: 0.01},
    %{name: "Laredo HVDC Back-to-Back",
      us_coords: {-99.49, 27.50}, foreign_coords: {-99.49, 27.48},
      voltage_kv: 138.0, rating_mva: 100.0, country: "MX", region: "Tamaulipas",
      interconnection: "ERCOT", x_pu: 0.01},
    %{name: "McAllen HVDC Back-to-Back (Sharyland)",
      us_coords: {-98.23, 26.20}, foreign_coords: {-98.23, 26.18},
      voltage_kv: 138.0, rating_mva: 150.0, country: "MX", region: "Tamaulipas",
      interconnection: "ERCOT", x_pu: 0.01},

    %{name: "CA–Baja 230kV (Imperial Valley–La Rosita)",
      us_coords: {-115.57, 32.72}, foreign_coords: {-115.57, 32.66},
      voltage_kv: 230.0, rating_mva: 800.0, country: "MX", region: "Baja California",
      interconnection: "Western", x_pu: 0.01},
    %{name: "CA–Baja 230kV (Otay Mesa–Tijuana)",
      us_coords: {-116.94, 32.56}, foreign_coords: {-116.94, 32.53},
      voltage_kv: 230.0, rating_mva: 400.0, country: "MX", region: "Baja California",
      interconnection: "Western", x_pu: 0.012},
    %{name: "AZ–Sonora 345kV (Nogales)",
      us_coords: {-110.94, 31.34}, foreign_coords: {-110.94, 31.30},
      voltage_kv: 345.0, rating_mva: 400.0, country: "MX", region: "Sonora",
      interconnection: "Western", x_pu: 0.015}
  ]

  @doc """
  Ingest all known international tie lines, creating boundary equivalent
  buses and transmission lines. Idempotent — uses on_conflict: :nothing.
  """
  def run do
    Logger.info("Creating international connections...")

    ties = @us_canada_ties ++ @us_mexico_ties
    counter = :counters.new(1, [:atomics])

    Enum.each(ties, fn tie ->
      case create_tie_line(tie) do
        {:ok, _} ->
          :counters.add(counter, 1, 1)
      end
    end)

    total = :counters.get(counter, 1)
    Logger.info("Created #{total} international tie lines (#{length(@us_canada_ties)} CA, #{length(@us_mexico_ties)} MX defined).")
    {:ok, total}
  end

  defp create_tie_line(tie) do
    ic_id = get_or_create_interconnection(tie.interconnection)

    us_source_id = "intl_us_#{slug(tie.name)}"
    us_bus = ensure_bus(%{
      bus_type: 1,
      base_kv: tie.voltage_kv,
      coordinates: point(tie.us_coords),
      source: "international",
      source_id: us_source_id,
      interconnection_id: ic_id
    })

    foreign_source_id = "intl_#{String.downcase(tie.country)}_#{slug(tie.name)}"
    foreign_bus = ensure_bus(%{
      bus_type: 2,
      base_kv: tie.voltage_kv,
      coordinates: point(tie.foreign_coords),
      source: "international",
      source_id: foreign_source_id,
      interconnection_id: ic_id
    })

    ensure_generator(%{
      bus_id: foreign_bus.id,
      p_max_mw: tie.rating_mva * 0.8,
      fuel_type: "import",
      prime_mover: "DC",
      status: "in_service",
      capacity_factor: 0.5,
      coordinates: point(tie.foreign_coords),
      eia_plant_id: "intl_#{slug(tie.name)}"
    })

    line_source_id = "intl_line_#{slug(tie.name)}"
    geometry = %Geo.LineString{
      coordinates: [tie.us_coords, tie.foreign_coords],
      srid: 4326
    }

    ensure_line(%{
      from_bus_id: us_bus.id,
      to_bus_id: foreign_bus.id,
      voltage_kv: tie.voltage_kv,
      rating_a_mva: tie.rating_mva,
      x_pu: tie.x_pu,
      r_pu: tie.x_pu * 0.1,
      geometry: geometry,
      status: "in_service",
      source: "international",
      source_id: line_source_id
    })

    {:ok, tie.name}
  end

  defp ensure_bus(attrs) do
    case Repo.get_by(Bus, source: attrs.source, source_id: attrs.source_id) do
      nil ->
        {:ok, bus} = %Bus{}
          |> Bus.changeset(attrs)
          |> Repo.insert()
        bus
      bus ->
        bus
    end
  end

  defp ensure_generator(attrs) do
    case Repo.get_by(Generator, eia_plant_id: attrs.eia_plant_id) do
      nil ->
        %Generator{}
        |> Generator.changeset(attrs)
        |> Repo.insert(on_conflict: :nothing)
      gen ->
        {:ok, gen}
    end
  end

  defp ensure_line(attrs) do
    case Repo.get_by(TransmissionLine, source: attrs.source, source_id: attrs.source_id) do
      nil ->
        %TransmissionLine{}
        |> TransmissionLine.changeset(attrs)
        |> Repo.insert()
      line ->
        {:ok, line}
    end
  end

  defp point({lon, lat}) do
    %Geo.Point{coordinates: {lon, lat}, srid: 4326}
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim_trailing("_")
  end

  defp get_or_create_interconnection(name) do
    case Repo.get_by(Interconnection, name: name) do
      %{id: id} -> id
      nil ->
        {:ok, ic} = %Interconnection{}
        |> Interconnection.changeset(%{name: name})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:name])

        case ic.id do
          nil -> Repo.get_by!(Interconnection, name: name).id
          id -> id
        end
    end
  end
end
