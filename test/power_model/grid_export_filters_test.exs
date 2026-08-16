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

  # UI-M18: the tag is only useful if its counts are the counts the export
  # would actually write. They share the queries' predicates rather than
  # restating them, and this pins that they still agree on a fixture built to
  # exercise every export filter.
  describe "Grid.export_signature/0" do
    test "each count equals what the matching export query returns",
         %{ic: ic, b1: b1, b2: b2} do
      ghost = Repo.insert!(%Bus{bus_type: 1, base_kv: 138.0, interconnection_id: ic.id})
      unmapped = insert_bus(nil, -91.0, 36.0)

      # In the export
      Repo.insert!(%TransmissionLine{
        voltage_kv: 138.0,
        from_bus_id: b1.id,
        to_bus_id: b2.id,
        x_pu: 0.1,
        status: "in_service"
      })

      Repo.insert!(%Generator{
        p_max_mw: 100.0,
        bus_id: b1.id,
        status: "in_service",
        coordinates: point(-90.0, 35.0)
      })

      Repo.insert!(%Load{p_mw: 40.0, q_mvar: 10.0, bus_id: b1.id, status: "in_service"})

      Repo.insert!(%Transformer{
        from_bus_id: b1.id,
        to_bus_id: b2.id,
        rated_mva: 300.0,
        x_pu: 0.08,
        status: "in_service"
      })

      Repo.insert!(%Substation{
        name: "Sig",
        status: "in_service",
        coordinates: point(-90.0, 35.0)
      })

      Repo.insert!(%Datacenter{
        name: "SigDC",
        facility_type: "colocation",
        power_mw: 5.0,
        coordinates: point(-90.0, 35.0),
        status: "active",
        bus_id: b1.id
      })

      # Filtered OUT by one predicate each: no coordinates, no
      # interconnection, out of service, self-loop.
      Repo.insert!(%TransmissionLine{
        voltage_kv: 138.0,
        from_bus_id: b1.id,
        to_bus_id: ghost.id,
        x_pu: 0.1,
        status: "in_service"
      })

      Repo.insert!(%TransmissionLine{
        voltage_kv: 138.0,
        from_bus_id: unmapped.id,
        to_bus_id: b2.id,
        x_pu: 0.1,
        status: "in_service"
      })

      Repo.insert!(%TransmissionLine{
        voltage_kv: 138.0,
        from_bus_id: b1.id,
        to_bus_id: b1.id,
        x_pu: 0.1,
        status: "in_service"
      })

      Repo.insert!(%Generator{p_max_mw: 50.0, bus_id: b1.id, status: "retired"})
      Repo.insert!(%Load{p_mw: 5.0, q_mvar: 1.0, bus_id: ghost.id, status: "in_service"})
      Repo.insert!(%Substation{name: "NoCoords", status: "in_service"})

      counts = Grid.export_signature().counts

      assert counts.transmission_lines == length(Grid.export_transmission_lines())
      assert counts.generators == length(Grid.export_generators())
      assert counts.substations == length(Grid.export_substations())
      assert counts.transformers == length(Grid.export_transformers())
      assert counts.bus_loads == length(Grid.export_bus_loads())
      assert counts.water_facilities == length(Grid.export_water_facilities())
      assert counts.datacenters == length(Grid.export_datacenters())

      # Not a vacuous agreement: the filters really did drop rows.
      assert counts.transmission_lines == 1
      assert counts.generators == 1
      assert counts.substations == 1
      assert counts.bus_loads == 1
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

    test "leaves a populated, current export alone", %{dir: dir} do
      marker = <<7::unsigned-little-32, 1, 2, 3>>
      File.write!(Path.join(dir, "transmission.bin"), marker)
      File.write!(Path.join(dir, "bus_loads.bin"), <<"BLD", 2, 0::unsigned-little-32>>)
      # UI-M18: the marker files stand in for a real export, so they need a
      # real content tag. Writing one is the honest way to say "this export
      # matches the database" -- the alternative, letting untagged files pass,
      # would disable the check this test now shares a module with.
      GridExport.write_manifest(dir)

      GridExport.ensure_exported(dir)

      assert File.read!(Path.join(dir, "transmission.bin")) == marker
    end

    test "an untagged export is regenerated once, then left alone", %{dir: dir} do
      File.write!(Path.join(dir, "transmission.bin"), <<7::unsigned-little-32, 1, 2, 3>>)
      File.write!(Path.join(dir, "bus_loads.bin"), <<"BLD", 2, 0::unsigned-little-32>>)

      GridExport.ensure_exported(dir)
      assert File.exists?(Path.join(dir, "manifest.bin"))

      # And the fresh export certifies itself: a second boot is a no-op, not
      # a rebuild loop.
      marker = <<9::unsigned-little-32, 4, 5, 6>>
      File.write!(Path.join(dir, "transmission.bin"), marker)
      GridExport.ensure_exported(dir)

      assert File.read!(Path.join(dir, "transmission.bin")) == marker
    end

    # UI-M18: the check used to see FORMAT only, so a re-ingest left the map
    # serving the previous topology indefinitely.
    test "regenerates when a row enters the exported set", %{dir: dir, b1: b1, b2: b2} do
      GridExport.run(dir)
      marker = <<7::unsigned-little-32, 1, 2, 3>>
      File.write!(Path.join(dir, "transmission.bin"), marker)

      Repo.insert!(%TransmissionLine{
        voltage_kv: 230.0,
        from_bus_id: b2.id,
        to_bus_id: b1.id,
        x_pu: 0.2,
        geometry: %Geo.LineString{coordinates: [{-89.9, 35.1}, {-90.0, 35.0}], srid: 4326},
        status: "in_service"
      })

      GridExport.ensure_exported(dir)

      assert <<count::unsigned-little-32, _::binary>> =
               File.read!(Path.join(dir, "transmission.bin"))

      assert count == 2, "the new line reached the map"
    end

    # The counts alone cannot see this: the row stays in the export and only
    # its VALUES changed, which is what a demand reallocation looks like.
    test "regenerates when an exported row changes in place", %{dir: dir, b1: b1} do
      load = Repo.insert!(%Load{p_mw: 40.0, q_mvar: 10.0, bus_id: b1.id, status: "in_service"})

      GridExport.run(dir)
      marker = <<7::unsigned-little-32, 1, 2, 3>>
      File.write!(Path.join(dir, "transmission.bin"), marker)

      Repo.update_all(
        from(l in Load, where: l.id == ^load.id),
        set: [p_mw: 95.0, updated_at: NaiveDateTime.add(load.updated_at, 60, :second)]
      )

      GridExport.ensure_exported(dir)

      refute File.read!(Path.join(dir, "transmission.bin")) == marker,
             "an in-place edit to an exported value must move the content tag"

      assert <<"BLD", 2, 1::unsigned-little-32, _bus::unsigned-little-32, _lon::float-little-32,
               _lat::float-little-32, mw::float-little-32>> =
               File.read!(Path.join(dir, "bus_loads.bin"))

      assert_in_delta mw, 95.0, 1.0e-4
    end

    # UIW-2: a bus_loads.bin from before the bus-id layout parses as garbage
    # under the current reader, and nothing else in the export set would
    # trigger a rebuild on a boot that finds transmission.bin populated.
    test "regenerates when bus_loads.bin predates the bus-id layout", %{dir: dir} do
      File.write!(Path.join(dir, "transmission.bin"), <<7::unsigned-little-32, 1, 2, 3>>)
      # v1: bare count, then three floats per record — no tag, no bus id.
      File.write!(Path.join(dir, "bus_loads.bin"), <<1::unsigned-little-32, 0::96>>)

      GridExport.ensure_exported(dir)

      assert <<"BLD", 2, _rest::binary>> = File.read!(Path.join(dir, "bus_loads.bin"))
    end
  end

  describe "bus_loads.bin bus-id channel (UIW-2)" do
    test "each record carries its bus id, and the ids round-trip", %{b1: b1, b2: b2} do
      # Two rows on one bus (a unique index keeps them distinct by load_type):
      # both are real consumption and both belong in the bus total.
      Repo.insert!(%Load{
        bus_id: b1.id,
        p_mw: 40.0,
        q_mvar: 0.0,
        load_type: "constant_power",
        status: "in_service"
      })

      Repo.insert!(%Load{
        bus_id: b1.id,
        p_mw: 25.0,
        q_mvar: 0.0,
        load_type: "datacenter",
        status: "in_service"
      })

      Repo.insert!(%Load{bus_id: b2.id, p_mw: 10.0, q_mvar: 0.0, status: "in_service"})

      dir =
        Path.join(
          System.tmp_dir!(),
          "grid_export_bus_loads_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      GridExport.run(dir)

      assert <<"BLD", 2, count::unsigned-little-32, records::binary>> =
               File.read!(Path.join(dir, "bus_loads.bin"))

      assert count == 2
      assert byte_size(records) == count * 16

      parsed =
        for <<bus_id::unsigned-little-32, lon::float-little-32, lat::float-little-32,
              mw::float-little-32 <- records>>,
            into: %{},
            do: {bus_id, {lon, lat, mw}}

      # The bus id is the join key for every bus-level cascade product; without
      # it nothing on the map can be placed.
      assert Map.keys(parsed) |> Enum.sort() == Enum.sort([b1.id, b2.id])

      {lon, lat, mw} = parsed[b1.id]
      assert_in_delta lon, -90.0, 1.0e-4
      assert_in_delta lat, 35.0, 1.0e-4
      assert_in_delta mw, 65.0, 1.0e-4, "both loads on a bus are summed"

      {_, _, mw2} = parsed[b2.id]
      assert_in_delta mw2, 10.0, 1.0e-4
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
