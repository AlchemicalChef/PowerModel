defmodule PowerModel.GridSnapshotHourTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Demand.BADemandHour
  alias PowerModel.Grid
  alias PowerModel.Grid.{BalancingAuthority, Bus, Generator, Load, TransmissionLine}

  @hour ~U[2024-07-15 20:00:00Z]

  setup do
    ba = Repo.insert!(%BalancingAuthority{code: "CISO", name: "California ISO"})

    # Minimal connected grid: snapshots keep only the largest connected
    # component among geolocated buses, so two coordinate-bearing buses
    # joined by an in-service line are required.
    bus1 =
      Repo.insert!(%Bus{
        bus_type: 3,
        base_kv: 138.0,
        balancing_authority_id: ba.id,
        coordinates: %Geo.Point{coordinates: {-117.1, 32.7}, srid: 4326}
      })

    bus2 =
      Repo.insert!(%Bus{
        bus_type: 1,
        base_kv: 138.0,
        balancing_authority_id: ba.id,
        coordinates: %Geo.Point{coordinates: {-117.0, 32.8}, srid: 4326}
      })

    Repo.insert!(%TransmissionLine{
      voltage_kv: 138.0,
      from_bus_id: bus1.id,
      to_bus_id: bus2.id,
      x_pu: 0.1,
      rating_a_mva: 200.0,
      status: "in_service"
    })

    Repo.insert!(%Generator{p_max_mw: 100.0, bus_id: bus1.id, status: "in_service"})

    Repo.insert!(%Load{p_mw: 80.0, q_mvar: 24.0, bus_id: bus2.id, status: "in_service"})

    # Actual demand for the hour: 160 MW (baseline 80 MW -> factor 2.0)
    Repo.insert!(%BADemandHour{
      balancing_authority_id: ba.id,
      timestamp_utc: @hour,
      demand_mw: 160.0
    })

    %{ba: ba, bus2: bus2}
  end

  test "snapshot without hour keeps baseline loads" do
    snapshot = Grid.get_full_grid_snapshot()

    assert [load] = snapshot.loads
    assert load.p_mw == 80.0
    assert load.q_mvar == 24.0
  end

  test "snapshot with hour scales loads to actual BA demand" do
    snapshot = Grid.get_full_grid_snapshot(hour: @hour)

    assert [load] = snapshot.loads
    assert_in_delta load.p_mw, 160.0, 1.0e-6
    assert_in_delta load.q_mvar, 48.0, 1.0e-6
  end

  test "snapshot with hour lacking demand data falls back to baseline" do
    snapshot = Grid.get_full_grid_snapshot(hour: ~U[2031-01-01 00:00:00Z])

    assert [load] = snapshot.loads
    assert load.p_mw == 80.0
  end

  test "coordinate-less networks are excluded even when larger than the geo network" do
    # A 3-bus chain WITHOUT coordinates (like the SyntheticUSA MATPOWER
    # import) would win largest-connected-component; the snapshot must still
    # pick the displayed (geolocated) 2-bus network.
    ghost1 = Repo.insert!(%Bus{bus_type: 3, base_kv: 138.0})
    ghost2 = Repo.insert!(%Bus{bus_type: 1, base_kv: 138.0})
    ghost3 = Repo.insert!(%Bus{bus_type: 1, base_kv: 138.0})

    for {a, b} <- [{ghost1, ghost2}, {ghost2, ghost3}] do
      Repo.insert!(%TransmissionLine{
        voltage_kv: 138.0,
        from_bus_id: a.id,
        to_bus_id: b.id,
        x_pu: 0.1,
        status: "in_service"
      })
    end

    Repo.insert!(%Load{p_mw: 999.0, bus_id: ghost2.id, status: "in_service"})

    snapshot = Grid.get_full_grid_snapshot()

    assert length(snapshot.buses) == 2
    assert Enum.all?(snapshot.buses, & &1.coordinates)
    assert [load] = snapshot.loads
    assert load.p_mw == 80.0
  end
end
