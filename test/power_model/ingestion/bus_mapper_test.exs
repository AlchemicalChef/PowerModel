defmodule PowerModel.Ingestion.BusMapperTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid
  alias PowerModel.Grid.{Bus, BalancingAuthority, Interconnection, TransmissionLine}
  alias PowerModel.Ingestion.{BusMapper, Cleanup}

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  defp line_string(from, to) do
    %Geo.LineString{coordinates: [from, to], srid: 4326}
  end

  defp insert_ic(name), do: Repo.insert!(%Interconnection{name: name})

  defp insert_ba(code), do: Repo.insert!(%BalancingAuthority{code: code, name: code})

  describe "interconnection_from_box/2 (geographic fallback)" do
    test "keeps Eastern-interconnection Texas pockets out of the ERCOT box" do
      # Deep East Texas (Entergy/MISO) sits east of -94.0.
      assert BusMapper.interconnection_from_box(-93.7, 30.1) == "Eastern"
      # Texas Panhandle (SPP) is north of 35.0 and west of -100.5.
      assert BusMapper.interconnection_from_box(-101.8, 35.4) == "Eastern"
    end

    test "El Paso and points west are Western" do
      assert BusMapper.interconnection_from_box(-106.4, 31.8) == "Western"
      assert BusMapper.interconnection_from_box(-115.0, 36.0) == "Western"
    end

    test "the core Texas grid stays ERCOT" do
      # Dallas / Fort Worth
      assert BusMapper.interconnection_from_box(-97.0, 32.8) == "ERCOT"
      # Houston (west of the -94.0 East Texas cutoff)
      assert BusMapper.interconnection_from_box(-95.4, 29.8) == "ERCOT"
      # Amarillo latitude but EAST of -100.5 is still ERCOT (not the Panhandle)
      assert BusMapper.interconnection_from_box(-100.0, 35.4) == "ERCOT"
    end

    test "box edges resolve on the intended side" do
      # lon exactly -94.0 is inside ERCOT; a hair east is Eastern.
      assert BusMapper.interconnection_from_box(-94.0, 31.0) == "ERCOT"
      assert BusMapper.interconnection_from_box(-93.99, 31.0) == "Eastern"
      # lat exactly 35.0 is not "north of 35.0", so the Panhandle carve-out
      # does not apply.
      assert BusMapper.interconnection_from_box(-101.8, 35.0) == "ERCOT"
    end

    test "the rest of CONUS is Eastern" do
      assert BusMapper.interconnection_from_box(-86.2, 39.8) == "Eastern"
    end
  end

  describe "interconnection_for_ba_code/1" do
    test "ERCO is ERCOT, WECC BAs are Western, everything else is Eastern" do
      assert BusMapper.interconnection_for_ba_code("ERCO") == "ERCOT"
      assert BusMapper.interconnection_for_ba_code("CISO") == "Western"
      assert BusMapper.interconnection_for_ba_code("EPE") == "Western"
      assert BusMapper.interconnection_for_ba_code("SWPP") == "Eastern"
      assert BusMapper.interconnection_for_ba_code("MISO") == "Eastern"
      assert BusMapper.interconnection_for_ba_code("PJM") == "Eastern"
    end

    test "codes are normalized (case and surrounding whitespace)" do
      assert BusMapper.interconnection_for_ba_code(" erco ") == "ERCOT"
      assert BusMapper.interconnection_for_ba_code("ciso") == "Western"
    end
  end

  describe "reconcile_interconnections_from_ba/0" do
    test "overrides the box result from the BA, leaving BA-less buses alone" do
      ercot = insert_ic("ERCOT")
      eastern = insert_ic("Eastern")
      western = insert_ic("Western")

      swpp = insert_ba("SWPP")
      ciso = insert_ba("CISO")
      erco = insert_ba("ERCO")

      # Boxed ERCOT (Panhandle) but the BA says SPP/Eastern.
      b1 =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          interconnection_id: ercot.id,
          balancing_authority_id: swpp.id
        })

      # Boxed Eastern but the BA says Western.
      b2 =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          interconnection_id: eastern.id,
          balancing_authority_id: ciso.id
        })

      # No BA -> keeps its box-derived interconnection.
      b3 = Repo.insert!(%Bus{bus_type: 1, base_kv: 138.0, interconnection_id: ercot.id})
      # Boxed Eastern but the BA is ERCO.
      b4 =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          interconnection_id: eastern.id,
          balancing_authority_id: erco.id
        })

      # Already correct -> not rewritten (and not counted).
      b5 =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          interconnection_id: western.id,
          balancing_authority_id: ciso.id
        })

      changed = BusMapper.reconcile_interconnections_from_ba()

      assert changed == 3
      assert Repo.get!(Bus, b1.id).interconnection_id == eastern.id
      assert Repo.get!(Bus, b2.id).interconnection_id == western.id
      assert Repo.get!(Bus, b3.id).interconnection_id == ercot.id
      assert Repo.get!(Bus, b4.id).interconnection_id == ercot.id
      assert Repo.get!(Bus, b5.id).interconnection_id == western.id
    end

    test "is idempotent: a second pass changes nothing" do
      insert_ic("Eastern")
      insert_ic("Western")
      ciso = insert_ba("CISO")

      Repo.insert!(%Bus{bus_type: 1, base_kv: 138.0, balancing_authority_id: ciso.id})

      assert BusMapper.reconcile_interconnections_from_ba() == 1
      assert BusMapper.reconcile_interconnections_from_ba() == 0
    end
  end

  describe "self-loop guards" do
    test "cleanup refuses to map both endpoints to the same bus" do
      # A single substation bus with two line endpoints nearby: without the
      # guard both would snap to it and create a self-loop.
      bus =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          source: "substation",
          source_id: "sub_a_138kV",
          coordinates: point(-90.0, 35.0)
        })

      line =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 138.0,
          status: "in_service",
          geometry: line_string({-90.01, 35.0}, {-90.02, 35.0}),
          from_bus_id: nil,
          to_bus_id: nil
        })

      Cleanup.remap_unmapped_lines()

      reloaded = Repo.get!(TransmissionLine, line.id)
      assert is_nil(reloaded.from_bus_id)
      assert is_nil(reloaded.to_bus_id)
      # The bus exists so the endpoints *could* have snapped; the guard is what
      # kept them nil.
      assert bus.id
    end

    test "cleanup still maps a line whose endpoints reach two distinct buses" do
      bus_a =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          source: "substation",
          source_id: "sub_a_138kV",
          coordinates: point(-90.0, 35.0)
        })

      bus_b =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          source: "substation",
          source_id: "sub_b_138kV",
          coordinates: point(-89.0, 35.0)
        })

      line =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 138.0,
          status: "in_service",
          geometry: line_string({-90.0, 35.0}, {-89.0, 35.0}),
          from_bus_id: nil,
          to_bus_id: nil
        })

      Cleanup.remap_unmapped_lines()

      reloaded = Repo.get!(TransmissionLine, line.id)
      assert reloaded.from_bus_id == bus_a.id
      assert reloaded.to_bus_id == bus_b.id
    end

    test "snapshot queries exclude self-loop lines" do
      ic = insert_ic("Eastern")

      b1 =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          coordinates: point(-90.0, 35.0),
          interconnection_id: ic.id
        })

      b2 =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          coordinates: point(-90.1, 35.1),
          interconnection_id: ic.id
        })

      normal =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 138.0,
          status: "in_service",
          from_bus_id: b1.id,
          to_bus_id: b2.id
        })

      loop =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 138.0,
          status: "in_service",
          from_bus_id: b1.id,
          to_bus_id: b1.id
        })

      ids = Grid.in_service_lines(ic.id) |> Enum.map(& &1.id)

      assert normal.id in ids
      refute loop.id in ids
    end
  end
end
