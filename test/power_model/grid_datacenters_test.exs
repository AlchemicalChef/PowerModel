defmodule PowerModel.GridDatacentersTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid
  alias PowerModel.Grid.{Bus, Datacenter, Load}

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  setup do
    bus =
      Repo.insert!(%Bus{bus_type: 1, base_kv: 138.0, coordinates: point(-77.46, 39.02)})

    far_bus =
      Repo.insert!(%Bus{bus_type: 1, base_kv: 138.0, coordinates: point(-100.0, 45.0)})

    %{bus: bus, far_bus: far_bus}
  end

  test "maps datacenters to nearest bus and creates one flat load row per bus",
       %{bus: bus} do
    Repo.insert!(%Datacenter{
      name: "DC One", facility_type: "hyperscale", power_mw: 100.0,
      coordinates: point(-77.461, 39.021), status: "active"
    })

    Repo.insert!(%Datacenter{
      name: "DC Two", facility_type: "colocation", power_mw: 50.0,
      coordinates: point(-77.459, 39.019), status: "active"
    })

    {mapped, load_rows, unmapped} = Grid.map_datacenters_to_grid(max_km: 10)

    assert mapped == 2
    assert unmapped == 0
    assert load_rows == 1

    # Both campuses share the nearest bus -> one summed flat load row
    load = Repo.one!(from l in Load, where: l.load_type == "datacenter")
    assert load.bus_id == bus.id
    assert_in_delta load.p_mw, 150.0, 1.0e-6
    assert_in_delta load.q_mvar, 150.0 * 0.3287, 1.0e-6
    assert load.status == "in_service"
  end

  test "datacenter beyond max_km stays unmapped and creates no load" do
    Repo.insert!(%Datacenter{
      name: "Remote DC", facility_type: "hyperscale", power_mw: 100.0,
      coordinates: point(-150.0, 60.0), status: "active"
    })

    {mapped, load_rows, unmapped} = Grid.map_datacenters_to_grid(max_km: 10)

    assert mapped == 0
    assert unmapped == 1
    assert load_rows == 0
    assert Repo.aggregate(from(l in Load, where: l.load_type == "datacenter"), :count) == 0
  end

  test "re-running the mapping is idempotent", %{bus: bus} do
    Repo.insert!(%Datacenter{
      name: "DC One", facility_type: "hyperscale", power_mw: 100.0,
      coordinates: point(-77.461, 39.021), status: "active"
    })

    {1, 1, 0} = Grid.map_datacenters_to_grid(max_km: 10)
    {1, 1, 0} = Grid.map_datacenters_to_grid(max_km: 10)

    loads = Repo.all(from l in Load, where: l.load_type == "datacenter")
    assert [load] = loads
    assert load.bus_id == bus.id
    assert_in_delta load.p_mw, 100.0, 1.0e-6
  end

  test "datacenter loads can coexist with a baseline load on the same bus", %{bus: bus} do
    Repo.insert!(%Load{
      bus_id: bus.id, p_mw: 25.0, q_mvar: 8.0,
      load_type: "constant_power", status: "in_service"
    })

    Repo.insert!(%Datacenter{
      name: "DC One", facility_type: "hyperscale", power_mw: 100.0,
      coordinates: point(-77.461, 39.021), status: "active"
    })

    {1, 1, 0} = Grid.map_datacenters_to_grid(max_km: 10)

    loads = Repo.all(from l in Load, where: l.bus_id == ^bus.id, order_by: l.load_type)
    assert length(loads) == 2
    assert Enum.map(loads, & &1.load_type) |> Enum.sort() == ["constant_power", "datacenter"]
  end
end
