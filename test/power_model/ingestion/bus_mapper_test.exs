defmodule PowerModel.Ingestion.BusMapperTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid

  alias PowerModel.Grid.{
    Bus,
    BalancingAuthority,
    Interconnection,
    Substation,
    Transformer,
    TransmissionLine
  }

  alias PowerModel.Ingestion.{BusMapper, Cleanup}

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  defp line_string(from, to) do
    %Geo.LineString{coordinates: [from, to], srid: 4326}
  end

  defp insert_ic(name), do: Repo.insert!(%Interconnection{name: name})

  defp insert_ba(code), do: Repo.insert!(%BalancingAuthority{code: code, name: code})

  defp substation_buses(sub) do
    prefix = "#{sub.id}_"

    Repo.all(
      from b in Bus,
        where: b.source == "substation" and like(b.source_id, ^(prefix <> "%"))
    )
  end

  defp substation_bus_kvs(sub), do: sub |> substation_buses() |> Enum.map(& &1.base_kv)

  # {high kV, low kV} of every transformer, ordered down the level chain.
  defp transformer_level_pairs(status \\ nil) do
    query =
      from t in Transformer,
        join: fb in Bus,
        on: t.from_bus_id == fb.id,
        join: tb in Bus,
        on: t.to_bus_id == tb.id,
        select: {fb.base_kv, tb.base_kv}

    query
    |> then(fn q -> if status, do: from(t in q, where: t.status == ^status), else: q end)
    |> Repo.all()
    |> Enum.sort_by(fn {high, _low} -> -high end)
  end

  defp in_service_transformer_level_pairs, do: transformer_level_pairs("in_service")

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

  describe "substation buses and transformers" do
    test "transformer impedances are rebased to the system base from rated_mva (LIN-3)" do
      sub =
        Repo.insert!(%Substation{
          name: "TEST 345/138",
          max_voltage_kv: 345.0,
          min_voltage_kv: 138.0,
          coordinates: point(-90.0, 35.0)
        })

      BusMapper.run()

      xfmr = Repo.one!(Transformer)
      # 345 kV high side -> 600 MVA rating; 10% / 0.3% on the bank's own base
      # rebased to the 100 MVA system base.
      assert xfmr.rated_mva == 600.0
      assert_in_delta xfmr.x_pu, 0.1 * (100.0 / 600.0), 1.0e-9
      assert_in_delta xfmr.r_pu, 0.003 * (100.0 / 600.0), 1.0e-9

      # Buses carry one-decimal kv source_ids (LIN-10).
      source_ids =
        Repo.all(from b in Bus, where: b.source == "substation", select: b.source_id)

      assert Enum.sort(source_ids) == Enum.sort(["#{sub.id}_345.0kV", "#{sub.id}_138.0kV"])
    end

    test "re-running map_buses does not duplicate transformers (LIN-4/DAT-1)" do
      Repo.insert!(%Substation{
        name: "TEST 500/230",
        max_voltage_kv: 500.0,
        min_voltage_kv: 230.0,
        coordinates: point(-91.0, 36.0)
      })

      BusMapper.run()
      BusMapper.run()

      assert Repo.aggregate(Transformer, :count) == 1
    end

    test "MATPOWER transformers are left alone by the re-map (foreign parameters)" do
      # Imported case-file impedances are real data; the generic 10%/0.3%
      # recipe must never overwrite them.
      hv =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 345.0,
          source: "matpower",
          source_id: "mp_1",
          coordinates: point(-90.0, 35.0)
        })

      lv =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          source: "matpower",
          source_id: "mp_2",
          coordinates: point(-90.0, 35.0)
        })

      # Reversed terminals and a case-file impedance, both of which the re-map
      # would "correct" if it claimed authority over this row.
      xfmr =
        Repo.insert!(%Transformer{
          from_bus_id: lv.id,
          to_bus_id: hv.id,
          rated_mva: 250.0,
          r_pu: 0.0012,
          x_pu: 0.0457,
          tap_ratio: 0.98,
          params_version: 0
        })

      assert %{recomputed: 0, retired: 0} = BusMapper.remap_stale_transformers()

      reloaded = Repo.get!(Transformer, xfmr.id)
      assert reloaded.from_bus_id == lv.id
      assert reloaded.x_pu == 0.0457
      assert reloaded.tap_ratio == 0.98
      assert reloaded.params_version == 0
    end

    test "near-integer voltage levels get distinct buses (LIN-10)" do
      # round/1 collapsed 138.0 and 138.4 into the same source_id, silently
      # dropping one voltage level's bus.
      sub =
        Repo.insert!(%Substation{
          name: "TEST 138.4/138.0",
          max_voltage_kv: 138.4,
          min_voltage_kv: 138.0,
          coordinates: point(-92.0, 37.0)
        })

      BusMapper.run()

      source_ids =
        Repo.all(from b in Bus, where: b.source == "substation", select: b.source_id)

      assert Enum.sort(source_ids) == Enum.sort(["#{sub.id}_138.4kV", "#{sub.id}_138.0kV"])
    end
  end

  describe "voltage_levels/1" do
    test "prefers the stored list, descending" do
      sub = %Substation{voltage_levels: [138.0, 500.0, 345.0], max_voltage_kv: 500.0}
      assert BusMapper.voltage_levels(sub) == [500.0, 345.0, 138.0]
    end

    test "falls back to max/min for rows ingested before the column existed" do
      sub = %Substation{voltage_levels: nil, max_voltage_kv: 345.0, min_voltage_kv: 115.0}
      assert BusMapper.voltage_levels(sub) == [345.0, 115.0]
    end

    test "falls back to 138 kV when nothing usable is stored" do
      assert BusMapper.voltage_levels(%Substation{voltage_levels: []}) == [138.0]
      assert BusMapper.voltage_levels(%Substation{voltage_levels: [0.0, nil]}) == [138.0]
    end

    test "levels that would share a one-decimal bus source_id collapse" do
      sub = %Substation{voltage_levels: [138.44, 138.41, 115.0]}
      assert BusMapper.voltage_levels(sub) == [138.44, 115.0]
    end
  end

  describe "one bus per voltage level (LIN-5)" do
    test "every stored level gets its own bus" do
      sub =
        Repo.insert!(%Substation{
          name: "KEYSTONE",
          voltage_levels: [500.0, 345.0, 138.0, 115.0],
          max_voltage_kv: 500.0,
          min_voltage_kv: 115.0,
          coordinates: point(-90.0, 35.0)
        })

      BusMapper.run()

      assert Enum.sort(substation_bus_kvs(sub)) == [115.0, 138.0, 345.0, 500.0]

      source_ids =
        Repo.all(from b in Bus, where: b.source == "substation", select: b.source_id)

      assert Enum.sort(source_ids) ==
               Enum.sort([
                 "#{sub.id}_500.0kV",
                 "#{sub.id}_345.0kV",
                 "#{sub.id}_138.0kV",
                 "#{sub.id}_115.0kV"
               ])
    end

    test "transformers chain adjacent levels only, never the extremes" do
      Repo.insert!(%Substation{
        name: "KEYSTONE",
        voltage_levels: [500.0, 345.0, 138.0, 115.0],
        coordinates: point(-90.0, 35.0)
      })

      BusMapper.run()

      # The old max/min-only scheme could only produce the 500/115 weld.
      assert transformer_level_pairs() == [{500.0, 345.0}, {345.0, 138.0}, {138.0, 115.0}]
    end

    test "rating comes from the genuine high side whatever order the pair arrives in" do
      sub =
        Repo.insert!(%Substation{
          name: "TEST 500/230",
          voltage_levels: [500.0, 230.0],
          coordinates: point(-90.0, 35.0)
        })

      BusMapper.run()

      [high, low] = Enum.sort_by(substation_buses(sub), & &1.base_kv, :desc)

      forward = BusMapper.transformer_attrs(high, low)
      reversed = BusMapper.transformer_attrs(low, high)

      assert forward == reversed
      # 500 kV high side -> 1000 MVA, NOT the 400 MVA a 230 kV terminal implies.
      assert forward.rated_mva == 1000.0
      assert forward.from_bus_id == high.id
      assert forward.to_bus_id == low.id
      assert_in_delta forward.x_pu, 0.1 * (100.0 / 1000.0), 1.0e-9
      assert forward.params_version == BusMapper.params_version()
    end

    test "creation stamps the current params version" do
      Repo.insert!(%Substation{
        name: "TEST 345/138",
        voltage_levels: [345.0, 138.0],
        coordinates: point(-90.0, 35.0)
      })

      BusMapper.run()

      assert Repo.one!(Transformer).params_version == BusMapper.params_version()
    end
  end

  describe "endpoint snapping across levels" do
    test "a 345 kV line at a KEYSTONE-class yard snaps to the 345 kV bus" do
      keystone =
        Repo.insert!(%Substation{
          name: "KEYSTONE",
          voltage_levels: [500.0, 345.0, 138.0, 115.0],
          coordinates: point(-90.0, 35.0)
        })

      far =
        Repo.insert!(%Substation{
          name: "CONEMAUGH",
          voltage_levels: [500.0, 345.0],
          coordinates: point(-89.0, 35.0)
        })

      line =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 345.0,
          status: "in_service",
          geometry: line_string({-90.0, 35.0}, {-89.0, 35.0})
        })

      BusMapper.run()

      reloaded = Repo.get!(TransmissionLine, line.id)
      assert Repo.get!(Bus, reloaded.from_bus_id).base_kv == 345.0
      assert Repo.get!(Bus, reloaded.to_bus_id).base_kv == 345.0
      assert Repo.get!(Bus, reloaded.from_bus_id).source_id == "#{keystone.id}_345.0kV"
      assert Repo.get!(Bus, reloaded.to_bus_id).source_id == "#{far.id}_345.0kV"
    end

    test "the closest level wins when several sit inside the +/-10% window" do
      # 320 and 345 are more than 5% apart, so both survive clustering and both
      # fall inside a 345 kV line's window — at the SAME coordinate, where
      # distance cannot separate them.
      sub =
        Repo.insert!(%Substation{
          name: "TWO NEAR LEVELS",
          voltage_levels: [345.0, 320.0],
          coordinates: point(-90.0, 35.0)
        })

      Repo.insert!(%Substation{
        name: "REMOTE",
        voltage_levels: [345.0],
        coordinates: point(-89.0, 35.0)
      })

      line =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 345.0,
          status: "in_service",
          geometry: line_string({-90.0, 35.0}, {-89.0, 35.0})
        })

      BusMapper.run()

      from_bus = Repo.get!(Bus, Repo.get!(TransmissionLine, line.id).from_bus_id)
      assert from_bus.base_kv == 345.0
      assert from_bus.source_id == "#{sub.id}_345.0kV"
    end
  end

  describe "re-map mode (ROADMAP item 8)" do
    test "a substation that gains a level gains a bus and keeps the old ones (DAT-9)" do
      sub =
        Repo.insert!(%Substation{
          name: "GROWING",
          voltage_levels: [500.0, 115.0],
          coordinates: point(-90.0, 35.0)
        })

      BusMapper.run()

      [bus_500, bus_115] = Enum.sort_by(substation_buses(sub), & &1.base_kv, :desc)

      # Something already points at the low-side bus; a re-ingest must not
      # orphan it.
      line =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 115.0,
          status: "in_service",
          from_bus_id: bus_115.id,
          to_bus_id: bus_500.id
        })

      sub
      |> Ecto.Changeset.change(%{voltage_levels: [500.0, 345.0, 138.0, 115.0]})
      |> Repo.update!()

      BusMapper.remap()

      assert Enum.sort(substation_bus_kvs(sub)) == [115.0, 138.0, 345.0, 500.0]
      # The original buses survive with their ids, so the line still resolves.
      assert Repo.get(Bus, bus_500.id)
      assert Repo.get(Bus, bus_115.id)
      reloaded = Repo.get!(TransmissionLine, line.id)
      assert reloaded.from_bus_id == bus_115.id
      assert reloaded.to_bus_id == bus_500.id
    end

    test "the weld across the gained levels is retired in favour of the chain" do
      sub =
        Repo.insert!(%Substation{
          name: "GROWING",
          voltage_levels: [500.0, 138.0],
          coordinates: point(-90.0, 35.0)
        })

      BusMapper.run()

      weld = Repo.one!(Transformer)
      # Pretend it was written by the previous recipe.
      weld |> Ecto.Changeset.change(%{params_version: 0}) |> Repo.update!()

      sub
      |> Ecto.Changeset.change(%{voltage_levels: [500.0, 345.0, 138.0]})
      |> Repo.update!()

      assert %{transformers_retired: 1} = BusMapper.remap()

      assert Repo.get!(Transformer, weld.id).status == "out_of_service"

      assert in_service_transformer_level_pairs() == [{500.0, 345.0}, {345.0, 138.0}]
    end

    test "a stale bank is reoriented high side first and re-rated" do
      sub =
        Repo.insert!(%Substation{
          name: "REVERSED",
          voltage_levels: [345.0, 138.0],
          coordinates: point(-90.0, 35.0)
        })

      BusMapper.create_substation_buses()
      [high, low] = Enum.sort_by(substation_buses(sub), & &1.base_kv, :desc)

      # The defect: the writer trusted row order and rated the bank off the
      # 138 kV terminal it happened to list first.
      stale =
        Repo.insert!(%Transformer{
          from_bus_id: low.id,
          to_bus_id: high.id,
          rated_mva: 200.0,
          r_pu: 0.003,
          x_pu: 0.1,
          params_version: 0
        })

      assert %{recomputed: 1, retired: 0} = BusMapper.remap_stale_transformers()

      reloaded = Repo.get!(Transformer, stale.id)
      assert reloaded.from_bus_id == high.id
      assert reloaded.to_bus_id == low.id
      assert reloaded.rated_mva == 600.0
      assert_in_delta reloaded.x_pu, 0.1 * (100.0 / 600.0), 1.0e-9
      assert reloaded.params_version == BusMapper.params_version()
    end

    test "rows already at the current version are not churned" do
      Repo.insert!(%Substation{
        name: "CURRENT",
        voltage_levels: [345.0, 138.0],
        coordinates: point(-90.0, 35.0)
      })

      BusMapper.run()

      assert %{
               transformers_created: 0,
               transformers_recomputed: 0,
               transformers_retired: 0,
               buses_created: 0
             } = BusMapper.remap()
    end
  end

  describe "unordered transformer pair key" do
    test "a reversed duplicate cannot be created" do
      sub =
        Repo.insert!(%Substation{
          name: "PAIR",
          voltage_levels: [345.0, 138.0],
          coordinates: point(-90.0, 35.0)
        })

      BusMapper.create_substation_buses()
      [high, low] = Enum.sort_by(substation_buses(sub), & &1.base_kv, :desc)

      # A bank recorded low side first — the ordered (from, to) index let this
      # through as a second row between the same two buses.
      Repo.insert!(%Transformer{
        from_bus_id: low.id,
        to_bus_id: high.id,
        rated_mva: 600.0,
        x_pu: 0.02
      })

      assert BusMapper.create_substation_transformers() == 0
      assert Repo.aggregate(Transformer, :count) == 1
    end

    test "the unique index itself rejects the reversed twin" do
      sub =
        Repo.insert!(%Substation{
          name: "PAIR",
          voltage_levels: [345.0, 138.0],
          coordinates: point(-90.0, 35.0)
        })

      BusMapper.create_substation_buses()
      [high, low] = Enum.sort_by(substation_buses(sub), & &1.base_kv, :desc)

      Repo.insert!(%Transformer{
        from_bus_id: high.id,
        to_bus_id: low.id,
        rated_mva: 600.0,
        x_pu: 0.02
      })

      assert_raise Ecto.ConstraintError, ~r/transformers_bus_pair_index/, fn ->
        Repo.insert!(%Transformer{
          from_bus_id: low.id,
          to_bus_id: high.id,
          rated_mva: 600.0,
          x_pu: 0.02
        })
      end
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
