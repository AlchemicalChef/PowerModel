defmodule PowerModel.GridSnapshotHourTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Demand.BADemandHour
  alias PowerModel.Grid

  alias PowerModel.Grid.{
    BalancingAuthority,
    Bus,
    Generator,
    Load,
    Transformer,
    TransmissionLine
  }

  @hour ~U[2024-07-15 20:00:00Z]

  setup do
    ba = Repo.insert!(%BalancingAuthority{code: "CISO", name: "California ISO"})
    ic = Repo.insert!(%PowerModel.Grid.Interconnection{name: "TestIC"})

    # Minimal connected grid: snapshots keep only the largest connected
    # component among geolocated buses, so two coordinate-bearing buses
    # joined by an in-service line are required.
    bus1 =
      Repo.insert!(%Bus{
        bus_type: 3,
        base_kv: 138.0,
        balancing_authority_id: ba.id,
        interconnection_id: ic.id,
        coordinates: %Geo.Point{coordinates: {-117.1, 32.7}, srid: 4326}
      })

    bus2 =
      Repo.insert!(%Bus{
        bus_type: 1,
        base_kv: 138.0,
        balancing_authority_id: ba.id,
        interconnection_id: ic.id,
        coordinates: %Geo.Point{coordinates: {-117.0, 32.8}, srid: 4326}
      })

    line =
      Repo.insert!(%TransmissionLine{
        voltage_kv: 138.0,
        from_bus_id: bus1.id,
        to_bus_id: bus2.id,
        x_pu: 0.1,
        rating_a_mva: 200.0,
        geometry: %Geo.LineString{
          coordinates: [{-117.1, 32.7}, {-117.0, 32.8}],
          srid: 4326
        },
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

    %{ba: ba, bus1: bus1, bus2: bus2, normal_line: line}
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
    ic2 = Repo.insert!(%PowerModel.Grid.Interconnection{name: "GhostIC"})
    ghost1 = Repo.insert!(%Bus{bus_type: 3, base_kv: 138.0, interconnection_id: ic2.id})
    ghost2 = Repo.insert!(%Bus{bus_type: 1, base_kv: 138.0, interconnection_id: ic2.id})
    ghost3 = Repo.insert!(%Bus{bus_type: 1, base_kv: 138.0, interconnection_id: ic2.id})

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

  test "AC snapshots exclude DC lines (LIN-6)", %{
    bus1: bus1,
    bus2: bus2,
    normal_line: normal_line
  } do
    dc_line =
      Repo.insert!(%TransmissionLine{
        voltage_kv: 500.0,
        from_bus_id: bus1.id,
        to_bus_id: bus2.id,
        x_pu: 0.01,
        rating_a_mva: 3100.0,
        line_type: "dc",
        geometry: %Geo.LineString{
          coordinates: [{-117.1, 32.7}, {-117.0, 32.8}],
          srid: 4326
        },
        status: "in_service"
      })

    ic = Repo.get_by!(PowerModel.Grid.Interconnection, name: "TestIC")

    for lines <- [
          Grid.in_service_lines(ic.id),
          Grid.get_full_grid_snapshot().lines,
          Grid.get_regional_grid_snapshot({-117.2, 32.6, -116.9, 32.9}).lines
        ] do
      ids = Enum.map(lines, & &1.id)
      assert normal_line.id in ids
      refute dc_line.id in ids
    end
  end

  test "regional snapshot carries the :datacenters key and scales loads by hour (DAT-11)" do
    bounds = {-117.2, 32.6, -116.9, 32.9}

    snapshot = Grid.get_regional_grid_snapshot(bounds)
    assert Map.has_key?(snapshot, :datacenters)
    assert [load] = snapshot.loads
    assert load.p_mw == 80.0

    scaled = Grid.get_regional_grid_snapshot(bounds, hour: @hour)
    assert [scaled_load] = scaled.loads
    assert_in_delta scaled_load.p_mw, 160.0, 1.0e-6
  end

  test "regional snapshot excludes lines with unmapped or interconnection-less endpoints (DAT-11)",
       %{bus1: bus1, normal_line: normal_line} do
    no_ic_bus =
      Repo.insert!(%Bus{
        bus_type: 1,
        base_kv: 138.0,
        coordinates: %Geo.Point{coordinates: {-117.05, 32.75}, srid: 4326}
      })

    bad_line =
      Repo.insert!(%TransmissionLine{
        voltage_kv: 138.0,
        from_bus_id: bus1.id,
        to_bus_id: no_ic_bus.id,
        x_pu: 0.1,
        geometry: %Geo.LineString{
          coordinates: [{-117.1, 32.7}, {-117.05, 32.75}],
          srid: 4326
        },
        status: "in_service"
      })

    unmapped_line =
      Repo.insert!(%TransmissionLine{
        voltage_kv: 138.0,
        from_bus_id: bus1.id,
        to_bus_id: nil,
        x_pu: 0.1,
        geometry: %Geo.LineString{
          coordinates: [{-117.1, 32.7}, {-117.06, 32.74}],
          srid: 4326
        },
        status: "in_service"
      })

    snapshot = Grid.get_regional_grid_snapshot({-117.2, 32.6, -116.9, 32.9})
    ids = Enum.map(snapshot.lines, & &1.id)

    assert normal_line.id in ids
    refute bad_line.id in ids
    refute unmapped_line.id in ids
  end

  test "regional and full snapshots exclude self-loop branches", %{
    bus1: bus1,
    bus2: bus2,
    normal_line: normal_line
  } do
    normal_transformer =
      Repo.insert!(%Transformer{
        rated_mva: 150.0,
        x_pu: 0.08,
        from_bus_id: bus1.id,
        to_bus_id: bus2.id,
        status: "in_service"
      })

    self_loop_line =
      Repo.insert!(%TransmissionLine{
        voltage_kv: 138.0,
        from_bus_id: bus1.id,
        to_bus_id: bus1.id,
        x_pu: 0.1,
        b_pu: 0.04,
        rating_a_mva: 200.0,
        geometry: %Geo.LineString{
          coordinates: [{-117.1, 32.7}, {-117.05, 32.75}],
          srid: 4326
        },
        status: "in_service"
      })

    self_loop_transformer =
      Repo.insert!(%Transformer{
        rated_mva: 150.0,
        x_pu: 0.08,
        from_bus_id: bus1.id,
        to_bus_id: bus1.id,
        status: "in_service"
      })

    for snapshot <- [
          Grid.get_regional_grid_snapshot({-117.2, 32.6, -116.9, 32.9}),
          Grid.get_full_grid_snapshot()
        ] do
      assert Enum.any?(snapshot.lines, &(&1.id == normal_line.id))
      refute Enum.any?(snapshot.lines, &(&1.id == self_loop_line.id))

      assert Enum.any?(snapshot.transformers, &(&1.id == normal_transformer.id))
      refute Enum.any?(snapshot.transformers, &(&1.id == self_loop_transformer.id))
    end
  end
end
