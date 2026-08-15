defmodule PowerModel.GridExportFiltersTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid
  alias PowerModel.GridExport

  alias PowerModel.Grid.{
    Bus,
    Datacenter,
    Generator,
    Interconnection,
    Load,
    Substation,
    Transformer,
    TransmissionLine
  }

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  defp insert_bus(ic, lon, lat) do
    Repo.insert!(%Bus{
      bus_type: 1,
      base_kv: 138.0,
      interconnection_id: ic && ic.id,
      coordinates: point(lon, lat)
    })
  end

  setup do
    ic = Repo.insert!(%Interconnection{name: "ExportIC"})
    b1 = insert_bus(ic, -90.0, 35.0)
    b2 = insert_bus(ic, -89.9, 35.1)
    %{ic: ic, b1: b1, b2: b2}
  end

  describe "export_transmission_lines/0 (DAT-2)" do
    test "mirrors snapshot predicates: unmapped, self-loop, and dc lines are not exported",
         %{b1: b1, b2: b2} do
      good =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 138.0,
          from_bus_id: b1.id,
          to_bus_id: b2.id,
          x_pu: 0.1,
          geometry: %Geo.LineString{coordinates: [{-90.0, 35.0}, {-89.9, 35.1}], srid: 4326},
          status: "in_service"
        })

      unmapped =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 138.0,
          from_bus_id: b1.id,
          to_bus_id: nil,
          x_pu: 0.1,
          geometry: %Geo.LineString{coordinates: [{-90.0, 35.0}, {-89.95, 35.05}], srid: 4326},
          status: "in_service"
        })

      self_loop =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 138.0,
          from_bus_id: b1.id,
          to_bus_id: b1.id,
          x_pu: 0.1,
          geometry: %Geo.LineString{coordinates: [{-90.0, 35.0}, {-89.95, 35.05}], srid: 4326},
          status: "in_service"
        })

      dc =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 500.0,
          from_bus_id: b1.id,
          to_bus_id: b2.id,
          x_pu: 0.01,
          line_type: "dc",
          geometry: %Geo.LineString{coordinates: [{-90.0, 35.0}, {-89.9, 35.1}], srid: 4326},
          status: "in_service"
        })

      ids = Grid.export_transmission_lines() |> Enum.map(& &1.id)

      assert good.id in ids
      refute unmapped.id in ids
      refute self_loop.id in ids
      refute dc.id in ids
    end

    test "geometry-less lines (synthetic ties) export a 2-point geometry from their endpoint buses",
         %{b1: b1, b2: b2} do
      tie =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 138.0,
          from_bus_id: b1.id,
          to_bus_id: b2.id,
          x_pu: 0.05,
          geometry: nil,
          source: "synthetic_tie",
          status: "in_service"
        })

      exported = Grid.export_transmission_lines() |> Enum.find(&(&1.id == tie.id))

      assert %Geo.LineString{coordinates: [{-90.0, 35.0}, {-89.9, 35.1}]} = exported.geometry
    end
  end

  describe "export_transformers/0 (DAT-2)" do
    test "self-loop and cross/nil-interconnection transformers are not exported",
         %{b1: b1, b2: b2} do
      no_ic_bus = insert_bus(nil, -89.8, 35.2)

      good =
        Repo.insert!(%Transformer{
          rated_mva: 200.0,
          x_pu: 0.05,
          from_bus_id: b1.id,
          to_bus_id: b2.id,
          status: "in_service"
        })

      self_loop =
        Repo.insert!(%Transformer{
          rated_mva: 200.0,
          x_pu: 0.05,
          from_bus_id: b1.id,
          to_bus_id: b1.id,
          status: "in_service"
        })

      no_ic =
        Repo.insert!(%Transformer{
          rated_mva: 200.0,
          x_pu: 0.05,
          from_bus_id: b1.id,
          to_bus_id: no_ic_bus.id,
          status: "in_service"
        })

      ids = Grid.export_transformers() |> Enum.map(& &1.id)

      assert good.id in ids
      refute self_loop.id in ids
      refute no_ic.id in ids
    end
  end

  describe "export_substations/0 (DAT-12)" do
    test "substations without coordinates are not exported" do
      with_coords =
        Repo.insert!(%Substation{name: "GEO SUB", coordinates: point(-90.0, 35.0)})

      without_coords = Repo.insert!(%Substation{name: "NULL ISLAND SUB", coordinates: nil})

      ids = Grid.export_substations() |> Enum.map(& &1.id)

      assert with_coords.id in ids
      refute without_coords.id in ids
    end
  end

  describe "headline totals (DAT-13)" do
    test "generation and load totals exclude buses the snapshot excludes", %{ic: ic, b1: b1} do
      ghost_bus = Repo.insert!(%Bus{bus_type: 1, base_kv: 138.0, interconnection_id: ic.id})

      Repo.insert!(%Generator{p_max_mw: 100.0, bus_id: b1.id, status: "in_service"})
      Repo.insert!(%Generator{p_max_mw: 999.0, bus_id: ghost_bus.id, status: "in_service"})

      Repo.insert!(%Load{p_mw: 80.0, q_mvar: 20.0, bus_id: b1.id, status: "in_service"})
      Repo.insert!(%Load{p_mw: 500.0, q_mvar: 100.0, bus_id: ghost_bus.id, status: "in_service"})

      assert Grid.total_generation_capacity(ic.id) == 100.0
      assert %{p_mw: 80.0} = Grid.total_load(ic.id)
    end
  end

  describe "GridExport.ensure_exported/1 (DAT-7)" do
    setup %{b1: b1, b2: b2} do
      Repo.insert!(%TransmissionLine{
        voltage_kv: 138.0,
        from_bus_id: b1.id,
        to_bus_id: b2.id,
        x_pu: 0.1,
        geometry: %Geo.LineString{coordinates: [{-90.0, 35.0}, {-89.9, 35.1}], srid: 4326},
        status: "in_service"
      })

      dir =
        Path.join(System.tmp_dir!(), "grid_export_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "regenerates when the export is empty (0 records)", %{dir: dir} do
      # A pre-ingest export: present but with a zero record count.
      File.write!(Path.join(dir, "transmission.bin"), <<0::unsigned-little-32>>)

      GridExport.ensure_exported(dir)

      assert <<count::unsigned-little-32, _::binary>> =
               File.read!(Path.join(dir, "transmission.bin"))

      assert count == 1
    end

    test "leaves a populated export alone", %{dir: dir} do
      marker = <<7::unsigned-little-32, 1, 2, 3>>
      File.write!(Path.join(dir, "transmission.bin"), marker)

      GridExport.ensure_exported(dir)

      assert File.read!(Path.join(dir, "transmission.bin")) == marker
    end
  end

  describe "datacenter JSON export (UI-L12)" do
    test "nil operator is exported as an empty string, never null", %{b1: b1} do
      Repo.insert!(%Datacenter{
        name: "No Operator DC",
        facility_type: "colocation",
        power_mw: 10.0,
        coordinates: point(-90.0, 35.0),
        operator: nil,
        status: "active",
        bus_id: b1.id
      })

      dir =
        Path.join(System.tmp_dir!(), "grid_export_dc_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      GridExport.run(dir)

      json = File.read!(Path.join(dir, "datacenters.json")) |> Jason.decode!()
      assert [dc] = json["datacenters"]
      assert dc["name"] == "No Operator DC"
      assert dc["operator"] == ""
    end
  end
end
