defmodule PowerModel.Ingestion.CleanupOrphansTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid.{Bus, Datacenter, Generator, Interconnection, Load, WaterFacility}
  alias PowerModel.Ingestion.Cleanup

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  defp synthetic_bus(lon, lat, extra \\ []) do
    Repo.insert!(
      struct!(
        %Bus{
          bus_type: 1,
          base_kv: 138.0,
          source: "synthetic",
          source_id: "synth_#{System.unique_integer([:positive])}",
          coordinates: point(lon, lat)
        },
        extra
      )
    )
  end

  describe "cleanup_orphaned_buses/0 (DAT-3)" do
    test "buses referenced only by loads, water facilities, or datacenters survive" do
      load_bus = synthetic_bus(-90.0, 35.0)
      Repo.insert!(%Load{p_mw: 5.0, bus_id: load_bus.id, status: "in_service"})

      water_bus = synthetic_bus(-90.1, 35.1)

      Repo.insert!(%WaterFacility{
        name: "Test Plant",
        facility_type: "treatment",
        coordinates: point(-90.1, 35.1),
        bus_id: water_bus.id,
        status: "active"
      })

      dc_bus = synthetic_bus(-90.2, 35.2)

      Repo.insert!(%Datacenter{
        name: "Test DC",
        facility_type: "hyperscale",
        power_mw: 50.0,
        coordinates: point(-90.2, 35.2),
        bus_id: dc_bus.id,
        status: "active"
      })

      truly_orphaned = synthetic_bus(-90.3, 35.3)

      # Under the old query the load-referenced bus was selected for deletion
      # and the loads FK (on_delete: :restrict) crashed the whole pass.
      Cleanup.cleanup_orphaned_buses()

      assert Repo.get(Bus, load_bus.id)
      assert Repo.get(Bus, water_bus.id)
      assert Repo.get(Bus, dc_bus.id)
      refute Repo.get(Bus, truly_orphaned.id)
    end
  end

  describe "water_facilities.bus_id FK (DAT-3 migration)" do
    test "deleting a bus nils the facility reference instead of dangling" do
      bus = synthetic_bus(-91.0, 36.0)

      facility =
        Repo.insert!(%WaterFacility{
          name: "Detachable Plant",
          facility_type: "pump_station",
          coordinates: point(-91.0, 36.0),
          bus_id: bus.id,
          status: "active"
        })

      Repo.delete!(bus)

      assert Repo.get!(WaterFacility, facility.id).bus_id == nil
    end
  end

  describe "remap_generators/0 (PLT-7)" do
    test "prefers a farther substation bus in the generator's interconnection over a nearer one across the seam" do
      eastern = Repo.insert!(%Interconnection{name: "Eastern"})
      ercot = Repo.insert!(%Interconnection{name: "ERCOT"})

      synth = synthetic_bus(-94.5, 32.0, interconnection_id: ercot.id)

      gen =
        Repo.insert!(%Generator{
          p_max_mw: 100.0,
          bus_id: synth.id,
          status: "in_service",
          coordinates: point(-94.5, 32.0)
        })

      # ~10 km away but across the asynchronous seam.
      _near_wrong_ic =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          source: "substation",
          source_id: "sub_east_138.0kV",
          coordinates: point(-94.4, 32.0),
          interconnection_id: eastern.id
        })

      # ~50 km away in the generator's own interconnection.
      same_ic =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          source: "substation",
          source_id: "sub_ercot_138.0kV",
          coordinates: point(-95.0, 32.0),
          interconnection_id: ercot.id
        })

      Cleanup.remap_generators()

      assert Repo.get!(Generator, gen.id).bus_id == same_ic.id
    end

    test "generators on buses without an interconnection still remap to the nearest substation" do
      synth = synthetic_bus(-92.0, 33.0)

      gen =
        Repo.insert!(%Generator{
          p_max_mw: 50.0,
          bus_id: synth.id,
          status: "in_service",
          coordinates: point(-92.0, 33.0)
        })

      nearest =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          source: "substation",
          source_id: "sub_any_138.0kV",
          coordinates: point(-92.05, 33.0)
        })

      Cleanup.remap_generators()

      assert Repo.get!(Generator, gen.id).bus_id == nearest.id
    end
  end
end
