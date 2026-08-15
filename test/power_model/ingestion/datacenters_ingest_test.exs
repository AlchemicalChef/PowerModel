defmodule PowerModel.Ingestion.DatacentersIngestTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid.Datacenter
  alias PowerModel.Ingestion.Datacenters

  test "curated campuses absent from the list are deactivated on re-ingest (DAT-6)" do
    # A campus from a previous vintage of the curated list.
    Repo.insert!(%Datacenter{
      name: "Ghost Campus",
      facility_type: "hyperscale",
      power_mw: 500.0,
      coordinates: %Geo.Point{coordinates: {-80.0, 40.0}, srid: 4326},
      status: "active",
      source: "curated",
      source_id: "ghost-campus"
    })

    # A non-curated row must never be touched by the curated reconciliation.
    Repo.insert!(%Datacenter{
      name: "Manual Entry",
      facility_type: "colocation",
      power_mw: 20.0,
      coordinates: %Geo.Point{coordinates: {-81.0, 41.0}, srid: 4326},
      status: "active",
      source: "manual",
      source_id: "manual-entry"
    })

    {:ok, count} = Datacenters.ingest()
    assert count > 0

    assert Repo.get_by!(Datacenter, source_id: "ghost-campus").status == "inactive"
    assert Repo.get_by!(Datacenter, source_id: "manual-entry").status == "active"

    # Every campus actually in the list stays active.
    active_curated =
      Repo.aggregate(
        from(d in Datacenter, where: d.source == "curated" and d.status == "active"),
        :count
      )

    assert active_curated == count
  end

  test "a campus that returns to the list is reactivated" do
    Repo.insert!(%Datacenter{
      name: "AWS Ashburn (US-East-1)",
      facility_type: "hyperscale",
      power_mw: 800.0,
      coordinates: %Geo.Point{coordinates: {-77.487, 39.045}, srid: 4326},
      status: "inactive",
      source: "curated",
      source_id: "aws-ashburn-us-east-1"
    })

    {:ok, _} = Datacenters.ingest()

    assert Repo.get_by!(Datacenter, source_id: "aws-ashburn-us-east-1").status == "active"
  end
end
