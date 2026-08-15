defmodule PowerModel.Ingestion.Water.SanDiegoUpsertTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid.WaterFacility
  alias PowerModel.Ingestion.Water.SanDiego

  @facility %{
    name: "Test Desal Plant",
    facility_type: "desalination",
    coordinates: {-117.35, 33.14},
    city: "Carlsbad",
    county: "San Diego",
    owner: "Test Water",
    capacity_mgd: 50.0,
    power_consumption_mw: 38.0,
    source: "sdcwa",
    source_id: "test_desal"
  }

  test "re-ingesting replaces curated values instead of freezing the first insert (DAT-8)" do
    assert SanDiego.upsert_facilities([@facility]) == 1

    corrected = %{@facility | capacity_mgd: 54.0, power_consumption_mw: 40.0, owner: "Poseidon"}
    assert SanDiego.upsert_facilities([corrected]) == 1

    facility = Repo.get_by!(WaterFacility, source: "sdcwa", source_id: "test_desal")
    assert facility.capacity_mgd == 54.0
    assert facility.power_consumption_mw == 40.0
    assert facility.owner == "Poseidon"

    # Still one row: this is an upsert, not a duplicate insert.
    assert Repo.aggregate(WaterFacility, :count) == 1
  end

  test "re-ingest does not clobber bus mapping" do
    SanDiego.upsert_facilities([@facility])

    bus =
      Repo.insert!(%PowerModel.Grid.Bus{
        bus_type: 1,
        base_kv: 138.0,
        coordinates: %Geo.Point{coordinates: {-117.35, 33.14}, srid: 4326}
      })

    Repo.get_by!(WaterFacility, source_id: "test_desal")
    |> Ecto.Changeset.change(%{bus_id: bus.id})
    |> Repo.update!()

    SanDiego.upsert_facilities([@facility])

    assert Repo.get_by!(WaterFacility, source_id: "test_desal").bus_id == bus.id
  end
end
