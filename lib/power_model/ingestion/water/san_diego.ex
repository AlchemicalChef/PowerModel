defmodule PowerModel.Ingestion.Water.SanDiego do
  @moduledoc """
  Ingest water infrastructure for San Diego County, with emphasis on Carlsbad.

  Combines:
  1. Hardcoded key facilities (desalination plant, major treatment plants, reservoirs)
     with accurate coordinates and capacity data from public reports
  2. EPA FRS wastewater treatment plants via ArcGIS API
  3. San Diego County Water Authority known facilities
  """

  alias PowerModel.Repo
  alias PowerModel.Grid.WaterFacility

  @carlsbad_facilities [
    %{
      name: "Claude \"Bud\" Lewis Carlsbad Desalination Plant",
      facility_type: "desalination",
      coordinates: {-117.3508, 33.1381},
      city: "Carlsbad",
      county: "San Diego",
      owner: "Poseidon Water",
      capacity_mgd: 50.0,
      power_consumption_mw: 38.0,
      source: "sdcwa",
      source_id: "carlsbad_desal"
    },
    %{
      name: "Encina Water Pollution Control Facility",
      facility_type: "wastewater",
      coordinates: {-117.3210, 33.1170},
      city: "Carlsbad",
      county: "San Diego",
      owner: "Encina Wastewater Authority",
      capacity_mgd: 36.0,
      power_consumption_mw: 4.5,
      source: "epa",
      source_id: "encina_wpcf"
    },
    %{
      name: "Carlsbad Water Recycling Facility",
      facility_type: "treatment",
      coordinates: {-117.3185, 33.1195},
      city: "Carlsbad",
      county: "San Diego",
      owner: "City of Carlsbad",
      capacity_mgd: 4.2,
      power_consumption_mw: 0.8,
      source: "carlsbad",
      source_id: "carlsbad_wrf"
    }
  ]

  @sdcwa_facilities [
    %{
      name: "Twin Oaks Valley Water Treatment Plant",
      facility_type: "treatment",
      coordinates: {-117.1660, 33.1640},
      city: "San Marcos",
      county: "San Diego",
      owner: "SDCWA",
      capacity_mgd: 100.0,
      power_consumption_mw: 8.0,
      source: "sdcwa",
      source_id: "twin_oaks_wtp"
    },
    %{
      name: "Robert A. Perdue Water Treatment Plant",
      facility_type: "treatment",
      coordinates: {-117.0270, 32.8860},
      city: "Lakeside",
      county: "San Diego",
      owner: "Helix Water District",
      capacity_mgd: 106.0,
      power_consumption_mw: 6.0,
      source: "sdcwa",
      source_id: "perdue_wtp"
    },
    %{
      name: "Miramar Water Treatment Plant",
      facility_type: "treatment",
      coordinates: {-117.1090, 32.8910},
      city: "San Diego",
      county: "San Diego",
      owner: "City of San Diego",
      capacity_mgd: 215.0,
      power_consumption_mw: 12.0,
      source: "sdcwa",
      source_id: "miramar_wtp"
    },
    %{
      name: "Alvarado Water Treatment Plant",
      facility_type: "treatment",
      coordinates: {-117.0680, 32.7780},
      city: "San Diego",
      county: "San Diego",
      owner: "City of San Diego",
      capacity_mgd: 200.0,
      power_consumption_mw: 10.0,
      source: "sdcwa",
      source_id: "alvarado_wtp"
    },
    %{
      name: "Otay Water Treatment Plant",
      facility_type: "treatment",
      coordinates: {-116.9370, 32.6270},
      city: "Chula Vista",
      county: "San Diego",
      owner: "City of San Diego",
      capacity_mgd: 34.0,
      power_consumption_mw: 3.0,
      source: "sdcwa",
      source_id: "otay_wtp"
    },
    %{
      name: "Point Loma Wastewater Treatment Plant",
      facility_type: "wastewater",
      coordinates: {-117.2430, 32.6670},
      city: "San Diego",
      county: "San Diego",
      owner: "City of San Diego",
      capacity_mgd: 175.0,
      power_consumption_mw: 15.0,
      source: "sdcwa",
      source_id: "point_loma_wwtp"
    },
    %{
      name: "North City Water Reclamation Plant",
      facility_type: "wastewater",
      coordinates: {-117.1230, 32.8990},
      city: "San Diego",
      county: "San Diego",
      owner: "City of San Diego",
      capacity_mgd: 30.0,
      power_consumption_mw: 4.0,
      source: "sdcwa",
      source_id: "north_city_wrp"
    },
    %{
      name: "South Bay Water Reclamation Plant",
      facility_type: "wastewater",
      coordinates: {-117.0680, 32.5450},
      city: "San Diego",
      county: "San Diego",
      owner: "City of San Diego",
      capacity_mgd: 15.0,
      power_consumption_mw: 2.5,
      source: "sdcwa",
      source_id: "south_bay_wrp"
    },
    %{
      name: "Hale Avenue Resource Recovery Facility",
      facility_type: "wastewater",
      coordinates: {-117.1110, 33.1050},
      city: "Escondido",
      county: "San Diego",
      owner: "City of Escondido",
      capacity_mgd: 18.0,
      power_consumption_mw: 2.5,
      source: "sdcwa",
      source_id: "harrf"
    },
    %{
      name: "San Elijo Water Reclamation Facility",
      facility_type: "wastewater",
      coordinates: {-117.2770, 33.0070},
      city: "Cardiff",
      county: "San Diego",
      owner: "San Elijo JPA",
      capacity_mgd: 5.25,
      power_consumption_mw: 1.2,
      source: "sdcwa",
      source_id: "san_elijo_wrf"
    },
    %{
      name: "Oceanside Water Reclamation Facility",
      facility_type: "wastewater",
      coordinates: {-117.3700, 33.1800},
      city: "Oceanside",
      county: "San Diego",
      owner: "City of Oceanside",
      capacity_mgd: 14.0,
      power_consumption_mw: 2.0,
      source: "sdcwa",
      source_id: "oceanside_wrf"
    },
    %{
      name: "Padre Dam Water Recycling Facility",
      facility_type: "wastewater",
      coordinates: {-116.9530, 32.8550},
      city: "Santee",
      county: "San Diego",
      owner: "Padre Dam MWD",
      capacity_mgd: 3.6,
      power_consumption_mw: 0.8,
      source: "sdcwa",
      source_id: "padre_dam_wrf"
    },
    %{
      name: "Olivenhain Reservoir",
      facility_type: "reservoir",
      coordinates: {-117.1530, 33.0510},
      city: "Encinitas",
      county: "San Diego",
      owner: "SDCWA",
      storage_acre_feet: 24_000.0,
      source: "sdcwa",
      source_id: "olivenhain_res"
    },
    %{
      name: "San Vicente Reservoir",
      facility_type: "reservoir",
      coordinates: {-116.9170, 32.9100},
      city: "Lakeside",
      county: "San Diego",
      owner: "City of San Diego",
      storage_acre_feet: 242_000.0,
      source: "sdcwa",
      source_id: "san_vicente_res"
    },
    %{
      name: "El Capitan Reservoir",
      facility_type: "reservoir",
      coordinates: {-116.8080, 32.8830},
      city: "Lakeside",
      county: "San Diego",
      owner: "City of San Diego",
      storage_acre_feet: 112_800.0,
      source: "sdcwa",
      source_id: "el_capitan_res"
    },
    %{
      name: "Lake Hodges",
      facility_type: "reservoir",
      coordinates: {-117.1050, 33.0640},
      city: "Escondido",
      county: "San Diego",
      owner: "City of San Diego",
      storage_acre_feet: 30_251.0,
      source: "sdcwa",
      source_id: "lake_hodges"
    },
    %{
      name: "Sweetwater Reservoir",
      facility_type: "reservoir",
      coordinates: {-116.9780, 32.6840},
      city: "Spring Valley",
      county: "San Diego",
      owner: "Sweetwater Authority",
      storage_acre_feet: 28_079.0,
      source: "sdcwa",
      source_id: "sweetwater_res"
    },
    %{
      name: "Otay Reservoir",
      facility_type: "reservoir",
      coordinates: {-116.9350, 32.6120},
      city: "Chula Vista",
      county: "San Diego",
      owner: "City of San Diego",
      storage_acre_feet: 49_510.0,
      source: "sdcwa",
      source_id: "otay_res"
    },
    %{
      name: "Lake Murray",
      facility_type: "reservoir",
      coordinates: {-117.0400, 32.7840},
      city: "La Mesa",
      county: "San Diego",
      owner: "City of San Diego",
      storage_acre_feet: 4_684.0,
      source: "sdcwa",
      source_id: "lake_murray"
    },
    %{
      name: "Miramar Reservoir",
      facility_type: "reservoir",
      coordinates: {-117.1070, 32.9130},
      city: "San Diego",
      county: "San Diego",
      owner: "City of San Diego",
      storage_acre_feet: 6_682.0,
      source: "sdcwa",
      source_id: "miramar_res"
    },
    %{
      name: "Twin Oaks Pump Station",
      facility_type: "pump_station",
      coordinates: {-117.1640, 33.1680},
      city: "San Marcos",
      county: "San Diego",
      owner: "SDCWA",
      power_consumption_mw: 5.0,
      source: "sdcwa",
      source_id: "twin_oaks_ps"
    },
    %{
      name: "Vallecitos Pump Station",
      facility_type: "pump_station",
      coordinates: {-117.1920, 33.1350},
      city: "San Marcos",
      county: "San Diego",
      owner: "SDCWA",
      power_consumption_mw: 3.5,
      source: "sdcwa",
      source_id: "vallecitos_ps"
    },
    %{
      name: "Rancho Bernardo Pump Station",
      facility_type: "pump_station",
      coordinates: {-117.0840, 33.0140},
      city: "San Diego",
      county: "San Diego",
      owner: "SDCWA",
      power_consumption_mw: 2.0,
      source: "sdcwa",
      source_id: "rancho_bernardo_ps"
    },
    %{
      name: "Lake Hodges Pump Station",
      facility_type: "pump_station",
      coordinates: {-117.1200, 33.0670},
      city: "Escondido",
      county: "San Diego",
      owner: "Olivenhain MWD",
      power_consumption_mw: 4.0,
      source: "sdcwa",
      source_id: "lake_hodges_ps"
    },
    %{
      name: "San Vicente Pump Station",
      facility_type: "pump_station",
      coordinates: {-116.9200, 32.9050},
      city: "Lakeside",
      county: "San Diego",
      owner: "City of San Diego",
      power_consumption_mw: 3.0,
      source: "sdcwa",
      source_id: "san_vicente_ps"
    }
  ]

  def ingest do
    IO.puts("=== Ingesting San Diego County Water Infrastructure ===\n")

    IO.puts("Step 1: Carlsbad facilities...")
    carlsbad = insert_facilities(@carlsbad_facilities)
    IO.puts("  Inserted: #{carlsbad}")

    IO.puts("Step 2: SDCWA & regional facilities...")
    sdcwa = insert_facilities(@sdcwa_facilities)
    IO.puts("  Inserted: #{sdcwa}")

    IO.puts("Step 3: EPA wastewater plants from API...")
    epa = ingest_epa_wastewater()
    IO.puts("  Inserted: #{epa}")

    total = carlsbad + sdcwa + epa
    IO.puts("\nTotal water facilities: #{total}")
    {:ok, total}
  end

  defp insert_facilities(facilities) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    facilities
    |> Enum.reduce(0, fn attrs, count ->
      {lon, lat} = attrs.coordinates
      point = %Geo.Point{coordinates: {lon, lat}, srid: 4326}

      entry = %{
        name: attrs.name,
        facility_type: attrs.facility_type,
        coordinates: point,
        city: attrs.city,
        county: attrs.county,
        state: Map.get(attrs, :state, "CA"),
        owner: attrs[:owner],
        status: "active",
        capacity_mgd: attrs[:capacity_mgd],
        storage_acre_feet: attrs[:storage_acre_feet],
        power_consumption_mw: attrs[:power_consumption_mw],
        source: attrs.source,
        source_id: attrs.source_id,
        inserted_at: now,
        updated_at: now
      }

      case Repo.insert_all(WaterFacility, [entry],
             on_conflict: :nothing,
             conflict_target: [:source, :source_id]
           ) do
        {1, _} -> count + 1
        _ -> count
      end
    end)
  end

  @epa_api_url "https://services.arcgis.com/XG15cJAlne2vxtgt/ArcGIS/rest/services/wastewater_treatment_plants_epa_frs/FeatureServer/0/query"

  defp ingest_epa_wastewater do
    params = [
      where: "CWP_COUNTY='SAN DIEGO' AND CWP_STATE='CA'",
      outFields: "CWP_NAME,CWP_CITY,CWP_STATUS,CWP_FACILI,CWP_MAJOR_,REGISTRY_I",
      f: "json",
      resultRecordCount: 200,
      returnGeometry: "true",
      outSR: "4326"
    ]

    case Req.get(@epa_api_url, params: params, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"features" => features}}} ->
        now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

        features
        |> Enum.filter(fn f ->
          attrs = f["attributes"]
          name = attrs["CWP_NAME"]
          name && name != "UNKNOWN" && name != ""
        end)
        |> Enum.reduce(0, fn feature, count ->
          attrs = feature["attributes"]
          geom = feature["geometry"]

          if geom && geom["x"] && geom["y"] do
            point = %Geo.Point{coordinates: {geom["x"], geom["y"]}, srid: 4326}
            source_id = "epa_#{attrs["REGISTRY_I"] || attrs["CWP_NAME"]}"

            facility_type =
              case attrs["CWP_FACILI"] do
                "POTW" -> "wastewater"
                _ -> "wastewater"
              end

            entry = %{
              name: attrs["CWP_NAME"],
              facility_type: facility_type,
              coordinates: point,
              city: attrs["CWP_CITY"],
              county: "San Diego",
              state: "CA",
              status: if(attrs["CWP_STATUS"] == "No Violation", do: "active", else: "active"),
              source: "epa",
              source_id: source_id,
              inserted_at: now,
              updated_at: now
            }

            case Repo.insert_all(WaterFacility, [entry],
                   on_conflict: :nothing,
                   conflict_target: [:source, :source_id]
                 ) do
              {1, _} -> count + 1
              _ -> count
            end
          else
            count
          end
        end)

      {:ok, resp} ->
        IO.puts("  EPA API returned status #{resp.status}")
        0

      {:error, err} ->
        IO.puts("  EPA API error: #{inspect(err)}")
        0
    end
  end
end
