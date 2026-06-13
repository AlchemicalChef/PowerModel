defmodule PowerModel.Ingestion.LoadEstimatorTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Demographics.CountyPopulation
  alias PowerModel.Grid.{Bus, Generator, Load, WaterFacility}
  alias PowerModel.Ingestion.LoadEstimator

  # Two PQ buses far apart: one in a "metro" (big county population nearby),
  # one in the "desert" (no population). 75 km spread radius means each
  # county's people land on its own nearest bus only.
  setup do
    metro_bus =
      Repo.insert!(%Bus{
        bus_type: 1,
        base_kv: 138.0,
        coordinates: %Geo.Point{coordinates: {-112.0, 33.5}, srid: 4326}
      })

    desert_bus =
      Repo.insert!(%Bus{
        bus_type: 1,
        base_kv: 138.0,
        coordinates: %Geo.Point{coordinates: {-105.0, 40.0}, srid: 4326}
      })

    # 1000 MW capacity at the desert bus -> target load 850 MW total. Under
    # the legacy gen-proximity heuristic the desert bus would get the larger
    # share; population weighting must invert that.
    Repo.insert!(%Generator{p_max_mw: 1000.0, bus_id: desert_bus.id, status: "in_service"})

    %{metro_bus: metro_bus, desert_bus: desert_bus}
  end

  defp load_at(bus_id) do
    Repo.one(
      from l in Load,
        where: l.bus_id == ^bus_id and l.load_type == "constant_power",
        select: l.p_mw
    )
  end

  test "population weighting sends load where people are", %{
    metro_bus: metro_bus,
    desert_bus: desert_bus
  } do
    Repo.insert!(%CountyPopulation{
      fips: "04013",
      name: "Maricopa County",
      state: "Arizona",
      population: 4_000_000,
      coordinates: %Geo.Point{coordinates: {-112.05, 33.45}, srid: 4326}
    })

    assert {:ok, 2} = LoadEstimator.run()

    metro = load_at(metro_bus.id)
    desert = load_at(desert_bus.id)

    # Total target = 850 MW. Metro bus: 80% pop share (all of it) + 10%
    # uniform = 0.9 -> 765 MW. Desert bus: 10% uniform -> 85 MW.
    assert_in_delta metro, 765.0, 1.0
    assert_in_delta desert, 85.0, 1.0
  end

  test "falls back to gen-proximity weighting without county data", %{
    metro_bus: metro_bus,
    desert_bus: desert_bus
  } do
    assert {:ok, 2} = LoadEstimator.run()

    # Legacy: 50% uniform + 50% gen-proportional. Desert bus holds all the
    # generation: 0.25 + 0.5 = 0.75 -> 637.5; metro gets 0.25 -> 212.5.
    assert_in_delta load_at(desert_bus.id), 637.5, 1.0
    assert_in_delta load_at(metro_bus.id), 212.5, 1.0
  end

  test "water facility MW survives re-estimation", %{metro_bus: metro_bus} do
    # Already-mapped facility (bus_id set): map_water_facilities_to_grid
    # will not re-add it, so the estimator must.
    Repo.insert!(%WaterFacility{
      name: "Test Treatment Plant",
      facility_type: "treatment",
      coordinates: %Geo.Point{coordinates: {-112.01, 33.51}, srid: 4326},
      status: "active",
      power_consumption_mw: 12.0,
      bus_id: metro_bus.id
    })

    assert {:ok, 2} = LoadEstimator.run()

    # Gen-proximity fallback gives the metro bus 212.5 MW; water adds 12.
    assert_in_delta load_at(metro_bus.id), 224.5, 1.0
  end

  test "water facility on a bus without a baseline load gets a fresh row" do
    # Mapped to a non-PQ bus: the estimator creates no baseline row there
    slack_bus =
      Repo.insert!(%Bus{
        bus_type: 3,
        base_kv: 345.0,
        coordinates: %Geo.Point{coordinates: {-100.0, 35.0}, srid: 4326}
      })

    Repo.insert!(%WaterFacility{
      name: "Pump Station X",
      facility_type: "pump_station",
      coordinates: %Geo.Point{coordinates: {-100.01, 35.01}, srid: 4326},
      status: "active",
      power_consumption_mw: 7.5,
      bus_id: slack_bus.id
    })

    assert {:ok, 2} = LoadEstimator.run()

    assert_in_delta load_at(slack_bus.id), 7.5, 0.01
  end
end
