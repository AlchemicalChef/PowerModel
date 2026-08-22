defmodule PowerModel.GridDatacentersTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid
  alias PowerModel.Grid.{Bus, Datacenter, Load, TransmissionLine}

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  defp bus(base_kv, {lon, lat}, opts \\ []) do
    Repo.insert!(%Bus{
      bus_type: Keyword.get(opts, :bus_type, 1),
      base_kv: base_kv,
      coordinates: point(lon, lat),
      source: "substation",
      source_id: "#{Keyword.get(opts, :yard, System.unique_integer([:positive]))}_#{base_kv}kV"
    })
  end

  defp line(from, to, rating_mva) do
    Repo.insert!(%TransmissionLine{
      from_bus_id: from.id,
      to_bus_id: to.id,
      voltage_kv: min(from.base_kv, to.base_kv),
      rating_a_mva: rating_mva,
      x_pu: 0.01,
      status: "in_service"
    })
  end

  # A meshed 138 kV yard (two 200 MVA circuits -> 320 MW of branch cap, held to
  # the 150 MW its class delivers) and a far one to tie the lines to. Campuses
  # may only land on a PQ bus that carries lines of its own, so a bare bus is
  # not a fixture the placer will accept.
  setup do
    bus = bus(138.0, {-77.46, 39.02})
    far_bus = bus(138.0, {-100.0, 45.0})
    tie = bus(138.0, {-77.30, 39.02})

    line(bus, tie, 200.0)
    line(bus, far_bus, 200.0)
    line(far_bus, tie, 200.0)

    %{bus: bus, far_bus: far_bus, tie: tie}
  end

  test "maps datacenters to nearest bus and creates one flat load row per bus",
       %{bus: bus} do
    Repo.insert!(%Datacenter{
      name: "DC One",
      facility_type: "hyperscale",
      power_mw: 100.0,
      coordinates: point(-77.461, 39.021),
      status: "active"
    })

    Repo.insert!(%Datacenter{
      name: "DC Two",
      facility_type: "colocation",
      power_mw: 50.0,
      coordinates: point(-77.459, 39.019),
      status: "active"
    })

    {mapped, load_rows, unmapped} = Grid.map_datacenters_to_grid(max_km: 10)

    assert mapped == 2
    assert unmapped == 0
    assert load_rows == 1

    # Both campuses share the nearest bus -> one summed flat load row
    load = Repo.one!(from l in Load, where: l.load_type == "datacenter")
    assert load.bus_id == bus.id
    assert_in_delta load.p_mw, 150.0, 1.0e-6
    # Same 0.95 pf ratio LoadEstimator writes its rows at, rounded the same way.
    assert_in_delta load.q_mvar, Float.round(150.0 * :math.tan(:math.acos(0.95)), 2), 1.0e-6
    assert load.status == "in_service"
  end

  test "a datacenter beyond the whole search stays unmapped and creates no load" do
    # `max_km` is where the search STARTS; it doubles from there rather than
    # dropping to a lower voltage class. This campus is ~3,000 km from anything.
    Repo.insert!(%Datacenter{
      name: "Remote DC",
      facility_type: "hyperscale",
      power_mw: 100.0,
      coordinates: point(-150.0, 60.0),
      status: "active"
    })

    {mapped, load_rows, unmapped} = Grid.map_datacenters_to_grid(max_km: 10)

    assert mapped == 0
    assert unmapped == 1
    assert load_rows == 0
    assert Repo.aggregate(from(l in Load, where: l.load_type == "datacenter"), :count) == 0
  end

  test "re-running the mapping is idempotent", %{bus: bus} do
    Repo.insert!(%Datacenter{
      name: "DC One",
      facility_type: "hyperscale",
      power_mw: 100.0,
      coordinates: point(-77.461, 39.021),
      status: "active"
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
      bus_id: bus.id,
      p_mw: 25.0,
      q_mvar: 8.0,
      load_type: "constant_power",
      status: "in_service"
    })

    Repo.insert!(%Datacenter{
      name: "DC One",
      facility_type: "hyperscale",
      power_mw: 100.0,
      coordinates: point(-77.461, 39.021),
      status: "active"
    })

    {1, 1, 0} = Grid.map_datacenters_to_grid(max_km: 10)

    loads = Repo.all(from l in Load, where: l.bus_id == ^bus.id, order_by: l.load_type)
    assert length(loads) == 2
    assert Enum.map(loads, & &1.load_type) |> Enum.sort() == ["constant_power", "datacenter"]
  end

  describe "interconnection class (DAT-22)" do
    test "a campus above 250 MW passes a nearer 138 kV yard for a 230 kV one", %{bus: bus} do
      # The old rule took the nearest bus of any kind: 400 MW landed on a
      # 13.8 kV bus in San Antonio and 350 MW on a branchless PV bus.
      ehv = bus(230.0, {-77.40, 39.02})
      far = bus(230.0, {-77.20, 39.02})
      line(ehv, far, 600.0)
      line(ehv, far, 600.0)

      Repo.insert!(%Datacenter{
        name: "Hyperscale",
        facility_type: "hyperscale",
        power_mw: 300.0,
        coordinates: point(-77.461, 39.021),
        status: "active"
      })

      {1, 1, 0} = Grid.map_datacenters_to_grid(max_km: 30)

      load = Repo.one!(from l in Load, where: l.load_type == "datacenter")
      assert load.bus_id == ehv.id
      refute load.bus_id == bus.id
      assert_in_delta load.p_mw, 300.0, 1.0e-6
    end

    test "never lands below the 60 kV load-serving floor, whatever is nearest" do
      distribution = bus(13.8, {-77.4601, 39.0201})
      tie = bus(13.8, {-77.4602, 39.0202})
      line(distribution, tie, 100.0)
      line(distribution, tie, 100.0)

      Repo.insert!(%Datacenter{
        name: "Colo",
        facility_type: "colocation",
        power_mw: 100.0,
        coordinates: point(-77.4601, 39.0201),
        status: "active"
      })

      {1, 1, 0} = Grid.map_datacenters_to_grid(max_km: 30)

      load = Repo.one!(from l in Load, where: l.load_type == "datacenter")
      refute load.bus_id == distribution.id
    end

    test "never lands on a bus with no line of its own", %{bus: bus} do
      # A bus reached only through banks is the far side of a transformer, and
      # a PV bus is not a delivery point at all.
      branchless = Repo.insert!(%Bus{bus_type: 2, base_kv: 138.0, coordinates: point(-77.4601, 39.0201)})

      Repo.insert!(%Datacenter{
        name: "Campus",
        facility_type: "hyperscale",
        power_mw: 100.0,
        coordinates: point(-77.4601, 39.0201),
        status: "active"
      })

      {1, 1, 0} = Grid.map_datacenters_to_grid(max_km: 30)

      load = Repo.one!(from l in Load, where: l.load_type == "datacenter")
      refute load.bus_id == branchless.id
      assert load.bus_id == bus.id
    end

    test "prefers a meshed yard over a nearer one hanging off a single circuit" do
      # 300 MW behind one branch is 300 MW lost on any trip of it. Both yards
      # clear the campus's 230 kV floor, so meshing is what separates them.
      spur = bus(230.0, {-77.4601, 39.0201})
      spur_far = bus(230.0, {-77.10, 39.02})
      line(spur, spur_far, 900.0)

      hub = bus(230.0, {-77.35, 39.02})
      meshed = bus(230.0, {-77.40, 39.02})
      line(meshed, spur_far, 600.0)
      line(meshed, hub, 600.0)

      Repo.insert!(%Datacenter{
        name: "Hyperscale",
        facility_type: "hyperscale",
        power_mw: 300.0,
        coordinates: point(-77.4601, 39.0201),
        status: "active"
      })

      {1, 1, 0} = Grid.map_datacenters_to_grid(max_km: 30)

      load = Repo.one!(from l in Load, where: l.load_type == "datacenter")
      refute load.bus_id == spur.id
      assert load.bus_id == meshed.id
    end

    test "a campus no single yard can host is split across yards", %{bus: bus} do
      # The 138 kV class delivers 150 MW; a 250 MW campus takes two feeds, as
      # Council Bluffs does on the real network.
      second = bus(138.0, {-77.45, 39.02})
      line(second, bus, 200.0)
      line(second, bus, 200.0)

      Repo.insert!(%Datacenter{
        name: "Big Campus",
        facility_type: "hyperscale",
        power_mw: 250.0,
        coordinates: point(-77.461, 39.021),
        status: "active"
      })

      {1, 2, 0} = Grid.map_datacenters_to_grid(max_km: 30)

      loads = Repo.all(from l in Load, where: l.load_type == "datacenter", order_by: [desc: l.p_mw])
      assert length(loads) == 2
      assert_in_delta Enum.sum(Enum.map(loads, & &1.p_mw)), 250.0, 0.01
      assert Enum.all?(loads, &(&1.p_mw <= 150.0 + 1.0e-6))

      # The anchor FK is the yard carrying the largest share.
      dc = Repo.one!(from d in Datacenter)
      assert dc.bus_id == hd(loads).bus_id
    end

    test "no yard is filled past what its class delivers", %{bus: bus} do
      for n <- 1..3 do
        Repo.insert!(%Datacenter{
          name: "Hall #{n}",
          facility_type: "colocation",
          power_mw: 60.0,
          coordinates: point(-77.461, 39.021),
          status: "active"
        })
      end

      {3, _rows, 0} = Grid.map_datacenters_to_grid(max_km: 30)

      held =
        Repo.one(from l in Load, where: l.load_type == "datacenter" and l.bus_id == ^bus.id, select: l.p_mw)

      assert held <= 150.0 + 1.0e-6

      total = Repo.one(from l in Load, where: l.load_type == "datacenter", select: sum(l.p_mw))
      assert_in_delta total, 180.0, 0.01
    end
  end
end
