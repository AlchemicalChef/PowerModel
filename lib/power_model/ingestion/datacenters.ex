defmodule PowerModel.Ingestion.Datacenters do
  @moduledoc """
  Curated dataset of major US datacenter campuses.

  `power_mw` values are ESTIMATES of total campus grid draw (IT load plus
  cooling/overhead) assembled from public reporting, utility filings, and
  announced capacities — campus-level approximations, not metered values.
  Re-ingesting refreshes estimates in place (upsert on source/source_id).

  Datacenter demand is modeled as flat 24/7 load: `Grid.map_datacenters_to_grid/1`
  creates `loads` rows with `load_type: "datacenter"` which are held constant
  by `PowerModel.Demand` hourly scaling.
  """

  alias PowerModel.Repo
  alias PowerModel.Grid.Datacenter

  # {name, operator, facility_type, city, state, lon, lat, power_mw_estimate}
  @campuses [
    # ── Northern Virginia ("Data Center Alley") ──────────────────────────
    {"AWS Ashburn (US-East-1)", "Amazon Web Services", "hyperscale", "Ashburn", "VA", -77.487,
     39.045, 800.0},
    {"AWS Manassas", "Amazon Web Services", "hyperscale", "Manassas", "VA", -77.52, 38.78, 400.0},
    {"AWS Chantilly", "Amazon Web Services", "hyperscale", "Chantilly", "VA", -77.44, 38.89,
     300.0},
    {"Equinix Ashburn Campus", "Equinix", "colocation", "Ashburn", "VA", -77.46, 39.015, 300.0},
    {"Digital Realty Ashburn", "Digital Realty", "colocation", "Ashburn", "VA", -77.45, 39.02,
     250.0},
    {"QTS Ashburn", "QTS", "colocation", "Ashburn", "VA", -77.50, 39.03, 250.0},
    {"CloudHQ Manassas", "CloudHQ", "colocation", "Manassas", "VA", -77.49, 38.79, 200.0},
    {"Vantage Ashburn", "Vantage", "colocation", "Ashburn", "VA", -77.47, 39.05, 150.0},
    {"STACK Ashburn", "STACK Infrastructure", "colocation", "Ashburn", "VA", -77.42, 39.02,
     200.0},
    {"Google Loudoun County", "Google", "hyperscale", "Ashburn", "VA", -77.46, 39.00, 300.0},
    {"Microsoft Boydton", "Microsoft", "hyperscale", "Boydton", "VA", -78.387, 36.667, 650.0},
    {"Meta Henrico", "Meta", "hyperscale", "Sandston", "VA", -77.25, 37.55, 300.0},

    # ── Southeast ─────────────────────────────────────────────────────────
    {"Google Lenoir", "Google", "hyperscale", "Lenoir", "NC", -81.539, 35.910, 300.0},
    {"Apple Maiden", "Apple", "hyperscale", "Maiden", "NC", -81.18, 35.55, 200.0},
    {"Meta Forest City", "Meta", "hyperscale", "Forest City", "NC", -81.870, 35.334, 300.0},
    {"Google Moncks Corner", "Google", "hyperscale", "Moncks Corner", "SC", -80.013, 33.196,
     300.0},
    {"Google Douglas County", "Google", "hyperscale", "Lithia Springs", "GA", -84.58, 33.74,
     350.0},
    {"Meta Stanton Springs", "Meta", "hyperscale", "Social Circle", "GA", -83.72, 33.55, 400.0},
    {"QTS Atlanta Metro", "QTS", "colocation", "Atlanta", "GA", -84.39, 33.65, 250.0},
    {"Meta Huntsville", "Meta", "hyperscale", "Huntsville", "AL", -86.69, 34.77, 350.0},
    {"Google Jackson County", "Google", "hyperscale", "Bridgeport", "AL", -85.76, 34.88, 250.0},
    {"Meta Gallatin", "Meta", "hyperscale", "Gallatin", "TN", -86.45, 36.39, 250.0},
    {"xAI Colossus", "xAI", "ai_training", "Memphis", "TN", -90.15, 35.06, 250.0},

    # ── Texas ─────────────────────────────────────────────────────────────
    {"Microsoft San Antonio", "Microsoft", "hyperscale", "San Antonio", "TX", -98.38, 29.42,
     400.0},
    {"Meta Fort Worth", "Meta", "hyperscale", "Fort Worth", "TX", -97.31, 32.93, 400.0},
    {"Google Midlothian", "Google", "hyperscale", "Midlothian", "TX", -96.99, 32.46, 300.0},
    {"Digital Realty Richardson", "Digital Realty", "colocation", "Richardson", "TX", -96.70,
     32.99, 200.0},
    {"Stargate Abilene", "OpenAI / Crusoe", "ai_training", "Abilene", "TX", -99.78, 32.41, 600.0},

    # ── Ohio / Midwest ────────────────────────────────────────────────────
    {"AWS New Albany (US-East-2)", "Amazon Web Services", "hyperscale", "New Albany", "OH",
     -82.79, 40.08, 600.0},
    {"Google New Albany", "Google", "hyperscale", "New Albany", "OH", -82.75, 40.07, 400.0},
    {"Meta New Albany", "Meta", "hyperscale", "New Albany", "OH", -82.70, 40.06, 400.0},
    {"Microsoft Northlake", "Microsoft", "hyperscale", "Northlake", "IL", -87.91, 41.92, 200.0},
    {"Equinix Elk Grove Village", "Equinix", "colocation", "Elk Grove Village", "IL", -87.99,
     42.00, 150.0},
    {"Meta DeKalb", "Meta", "hyperscale", "DeKalb", "IL", -88.71, 41.93, 300.0},

    # ── Iowa / Nebraska / Oklahoma / Wyoming ──────────────────────────────
    {"Google Council Bluffs", "Google", "hyperscale", "Council Bluffs", "IA", -95.862, 41.221,
     900.0},
    {"Meta Altoona", "Meta", "hyperscale", "Altoona", "IA", -93.474, 41.649, 500.0},
    {"Microsoft West Des Moines", "Microsoft", "hyperscale", "West Des Moines", "IA", -93.78,
     41.56, 450.0},
    {"Google Papillion", "Google", "hyperscale", "Papillion", "NE", -96.08, 41.13, 250.0},
    {"Meta Sarpy County", "Meta", "hyperscale", "Papillion", "NE", -96.10, 41.10, 300.0},
    {"Google Pryor Creek", "Google", "hyperscale", "Pryor", "OK", -95.33, 36.24, 500.0},
    {"Microsoft Cheyenne", "Microsoft", "hyperscale", "Cheyenne", "WY", -104.86, 41.13, 200.0},

    # ── Arizona / Nevada / Utah / New Mexico ──────────────────────────────
    {"Microsoft Goodyear", "Microsoft", "hyperscale", "Goodyear", "AZ", -112.36, 33.44, 300.0},
    {"Meta Mesa", "Meta", "hyperscale", "Mesa", "AZ", -111.66, 33.31, 400.0},
    {"Google Mesa", "Google", "hyperscale", "Mesa", "AZ", -111.74, 33.27, 300.0},
    {"CyrusOne Chandler", "CyrusOne", "colocation", "Chandler", "AZ", -111.93, 33.30, 200.0},
    {"Switch Core Campus", "Switch", "colocation", "Las Vegas", "NV", -115.18, 36.07, 300.0},
    {"Switch Citadel", "Switch", "colocation", "Tahoe Reno Industrial Center", "NV", -119.44,
     39.54, 350.0},
    {"Apple Reno", "Apple", "hyperscale", "Reno", "NV", -119.44, 39.51, 100.0},
    {"Meta Eagle Mountain", "Meta", "hyperscale", "Eagle Mountain", "UT", -112.01, 40.31, 400.0},
    {"NSA Utah Data Center", "US Government", "enterprise", "Bluffdale", "UT", -111.934, 40.426,
     65.0},
    {"Meta Los Lunas", "Meta", "hyperscale", "Los Lunas", "NM", -106.71, 34.78, 350.0},

    # ── Pacific Northwest / California ────────────────────────────────────
    {"Meta Prineville", "Meta", "hyperscale", "Prineville", "OR", -120.80, 44.285, 350.0},
    {"Apple Prineville", "Apple", "hyperscale", "Prineville", "OR", -120.85, 44.30, 150.0},
    {"Google The Dalles", "Google", "hyperscale", "The Dalles", "OR", -121.18, 45.600, 350.0},
    {"AWS Boardman (US-West-2)", "Amazon Web Services", "hyperscale", "Boardman", "OR", -119.70,
     45.84, 700.0},
    {"Microsoft Quincy", "Microsoft", "hyperscale", "Quincy", "WA", -119.85, 47.23, 400.0},
    {"Sabey Intergate.Quincy", "Sabey", "colocation", "Quincy", "WA", -119.86, 47.21, 150.0},
    {"Equinix Great Oaks", "Equinix", "colocation", "San Jose", "CA", -121.78, 37.24, 200.0},
    {"Vantage Santa Clara", "Vantage", "colocation", "Santa Clara", "CA", -121.97, 37.37, 300.0}
  ]

  @doc """
  Upsert the curated campus list. Returns `{:ok, count}`.
  """
  def ingest do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      Enum.map(@campuses, fn {name, operator, type, city, state, lon, lat, power_mw} ->
        %{
          name: name,
          operator: operator,
          facility_type: type,
          city: city,
          state: state,
          coordinates: %Geo.Point{coordinates: {lon, lat}, srid: 4326},
          status: "active",
          power_mw: power_mw,
          source: "curated",
          source_id: slug(name),
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(Datacenter, entries,
        on_conflict:
          {:replace,
           [:operator, :facility_type, :coordinates, :city, :state, :power_mw, :updated_at]},
        conflict_target: [:source, :source_id]
      )

    total_mw = entries |> Enum.map(& &1.power_mw) |> Enum.sum()

    IO.puts(
      "  Datacenters upserted: #{count} campuses, " <>
        "#{Float.round(total_mw / 1000.0, 1)} GW estimated total draw"
    )

    {:ok, count}
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
