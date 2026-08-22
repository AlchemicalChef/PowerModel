defmodule PowerModel.Ingestion.LoadEstimatorTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Demographics.CountyPopulation
  alias PowerModel.Grid.{Bus, Generator, Load, Transformer, TransmissionLine, WaterFacility}
  alias PowerModel.Ingestion.LoadEstimator

  # Two 500 kV yards far apart: one in a "metro" (big county population
  # nearby), one in the "desert" (no population), tied by a line big enough
  # that the capability cap never binds. The county spread radius with a single
  # county in the table is the 120 km ceiling, so 2.5 radii reach the metro bus
  # and nowhere near the desert one.
  #
  # 500 kV because 765 MW is what these fixtures put on the metro bus, and the
  # class ceiling says no 138 kV yard delivers that.
  setup do
    metro_bus = bus(1, 500.0, {-112.0, 33.5})
    desert_bus = bus(2, 500.0, {-105.0, 40.0})
    line(metro_bus, desert_bus, 5000.0)

    # 1000 MW capacity at the desert bus -> target load 850 MW total. Under
    # the legacy gen-proximity heuristic the desert bus would get the larger
    # share; population weighting must invert that.
    Repo.insert!(%Generator{p_max_mw: 1000.0, bus_id: desert_bus.id, status: "in_service"})

    %{metro_bus: metro_bus, desert_bus: desert_bus}
  end

  defp bus(substation_id, base_kv, {lon, lat}, bus_type \\ 1) do
    Repo.insert!(%Bus{
      bus_type: bus_type,
      base_kv: base_kv,
      coordinates: %Geo.Point{coordinates: {lon, lat}, srid: 4326},
      source: "substation",
      source_id: "#{substation_id}_#{base_kv}kV"
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

  defp bank(high, low, rated_mva) do
    Repo.insert!(%Transformer{
      from_bus_id: high.id,
      to_bus_id: low.id,
      rated_mva: rated_mva,
      x_pu: 0.1,
      status: "in_service"
    })
  end

  defp county(fips, population, {lon, lat}) do
    Repo.insert!(%CountyPopulation{
      fips: fips,
      name: "County #{fips}",
      state: "Arizona",
      population: population,
      coordinates: %Geo.Point{coordinates: {lon, lat}, srid: 4326}
    })
  end

  defp load_at(bus_id) do
    Repo.one(
      from l in Load,
        where: l.bus_id == ^bus_id and l.load_type == "constant_power",
        select: l.p_mw
    )
  end

  defp total_load do
    Repo.one(from l in Load, where: l.load_type == "constant_power", select: sum(l.p_mw)) || 0.0
  end

  test "population weighting sends load where people are", %{
    metro_bus: metro_bus,
    desert_bus: desert_bus
  } do
    county("04013", 4_000_000, {-112.05, 33.45})

    assert {:ok, 2} = LoadEstimator.run()

    # Total target = 850 MW. Metro bus: 80% pop share (all of it) + 10%
    # uniform = 0.9 -> 765 MW. Desert bus: 10% uniform -> 85 MW.
    assert_in_delta load_at(metro_bus.id), 765.0, 1.0
    assert_in_delta load_at(desert_bus.id), 85.0, 1.0
  end

  test "falls back to gen-proximity weighting without county data", %{
    metro_bus: metro_bus,
    desert_bus: desert_bus
  } do
    assert {:ok, 2} = LoadEstimator.run()

    # Legacy: 50% uniform + 50% gen-proportional. Desert bus holds all the
    # generation: 0.25 + 0.5 = 0.75 -> 637.5; metro gets 0.25 -> 212.5.
    assert_in_delta load_at(desert_bus.id), 637.5, 1.0
    assert_in_delta load_at(metro_bus.id), 212.5, 1.0
  end

  test "water facility MW survives re-estimation", %{metro_bus: metro_bus} do
    # Already-mapped facility (bus_id set): map_water_facilities_to_grid
    # will not re-add it, so the estimator must.
    Repo.insert!(%WaterFacility{
      name: "Test Treatment Plant",
      facility_type: "treatment",
      coordinates: %Geo.Point{coordinates: {-112.01, 33.51}, srid: 4326},
      status: "active",
      power_consumption_mw: 12.0,
      bus_id: metro_bus.id
    })

    assert {:ok, 2} = LoadEstimator.run()

    # Gen-proximity fallback gives the metro bus 212.5 MW; water adds 12.
    assert_in_delta load_at(metro_bus.id), 224.5, 1.0
  end

  test "water facility on a bus without a baseline load gets a fresh row" do
    # A slack bus is not a load-serving candidate, so the estimator creates no
    # baseline row there.
    slack_bus = bus(3, 345.0, {-100.0, 35.0}, 3)

    Repo.insert!(%WaterFacility{
      name: "Pump Station X",
      facility_type: "pump_station",
      coordinates: %Geo.Point{coordinates: {-100.01, 35.01}, srid: 4326},
      status: "active",
      power_consumption_mw: 7.5,
      bus_id: slack_bus.id
    })

    assert {:ok, 2} = LoadEstimator.run()

    assert_in_delta load_at(slack_bus.id), 7.5, 0.01
  end

  describe "candidate rules" do
    test "a yard takes load once, on its lowest networked level", %{metro_bus: metro_bus} do
      # The metro yard also has a 33 kV and a 69 kV bus, all at the same point.
      # The old rule ranked candidates by distance and gave every level the
      # county's weight; GALE and HARVARD each held their county share twice.
      sub_kv = bus(1, 69.0, {-112.0, 33.5})
      distribution = bus(1, 33.0, {-112.0, 33.5})
      bank(metro_bus, sub_kv, 200.0)
      bank(sub_kv, distribution, 100.0)

      county("04013", 4_000_000, {-112.05, 33.45})

      assert {:ok, 2} = LoadEstimator.run()

      # The 69 kV bus is the lowest level above the floor but its only branches
      # are banks, so the network never delivers to it; the 138 kV bus is the
      # yard's connection point and takes the whole share, once.
      assert load_at(sub_kv.id) == nil
      assert load_at(distribution.id) == nil
      assert_in_delta load_at(metro_bus.id), 765.0, 1.0
    end

    test "a yard's lower level takes the load when it carries a line too", %{
      metro_bus: metro_bus,
      desert_bus: desert_bus
    } do
      sub_kv = bus(1, 69.0, {-112.0, 33.5})
      bank(metro_bus, sub_kv, 200.0)
      line(sub_kv, desert_bus, 300.0)

      county("04013", 4_000_000, {-112.05, 33.45})

      assert {:ok, 2} = LoadEstimator.run()

      assert load_at(metro_bus.id) == nil
      assert is_number(load_at(sub_kv.id))
    end

    test "load below the load-serving floor moves up to the yard", %{metro_bus: metro_bus} do
      distribution = bus(1, 13.8, {-112.0, 33.5})
      bank(metro_bus, distribution, 200.0)
      county("04013", 4_000_000, {-112.05, 33.45})

      assert {:ok, 2} = LoadEstimator.run()

      assert load_at(distribution.id) == nil
      assert_in_delta load_at(metro_bus.id), 765.0, 1.0
    end

    test "a bus outside every balancing authority carries nothing", %{metro_bus: metro_bus} do
      # Its weight would never be rescaled by Demand.scale_loads/3, so it would
      # reach every snapshot as permanent synthetic load.
      ba =
        Repo.insert!(%PowerModel.Grid.BalancingAuthority{code: "TEST", name: "Test Authority"})

      Repo.update!(Ecto.Changeset.change(metro_bus, balancing_authority_id: ba.id))

      unmapped = bus(4, 138.0, {-112.01, 33.49})
      line(unmapped, metro_bus, 500.0)
      county("04013", 4_000_000, {-112.05, 33.45})

      assert {:ok, 1} = LoadEstimator.run()

      assert load_at(unmapped.id) == nil
      assert_in_delta load_at(metro_bus.id), 850.0, 1.0
    end

    test "a bus with no branch carries nothing", %{desert_bus: desert_bus} do
      stranded = bus(4, 138.0, {-105.05, 40.05})
      county("04013", 4_000_000, {-105.02, 40.02})

      assert {:ok, 2} = LoadEstimator.run()

      assert load_at(stranded.id) == nil
      # The whole population term went to the bus that has a branch: 680 MW
      # plus its 85 MW share of the uniform floor.
      assert_in_delta load_at(desert_bus.id), 765.0, 1.0
    end
  end

  describe "capability cap" do
    test "overflow goes to the county's other buses, not over the branch", %{
      metro_bus: metro_bus,
      desert_bus: desert_bus
    } do
      # A small yard right next to the county's interior point, fed by one
      # 100 MVA line: it may take 80 MW and no more.
      small = bus(5, 138.0, {-112.04, 33.46})
      line(small, desert_bus, 100.0)

      county("04013", 4_000_000, {-112.05, 33.45})

      assert {:ok, 3} = LoadEstimator.run()

      assert_in_delta load_at(small.id), 80.0, 0.1
      assert_in_delta total_load(), 850.0, 1.0
      # The county's population lands on the metro bus instead of overloading
      # the small yard, which stops at its 100 MVA line.
      assert load_at(metro_bus.id) > 600.0
    end

    test "an inflated stored bank rating does not raise the cap", %{metro_bus: metro_bus} do
      # DR-4's resize sizes a bank from the load standing behind it, so a bank
      # rating on a database it has run against already encodes the
      # misplacement. The cap anchors on the class-standard rating instead: a
      # 138 kV bank is 200 MVA whatever the row says.
      low = bus(6, 69.0, {-112.06, 33.44})
      feeder = bus(6, 138.0, {-112.06, 33.44})
      line(feeder, metro_bus, 5000.0)
      line(low, metro_bus, 100.0)
      bank(feeder, low, 4000.0)

      county("04013", 4_000_000, {-112.05, 33.45})

      caps = LoadEstimator.capability(LoadEstimator.network())

      # 0.8 x (its own 100 MVA line + the 200 MVA class standard for a 138 kV
      # bank), not 0.8 x the stored 4000 MVA.
      assert_in_delta caps[low.id].cap_mw, 240.0, 0.1

      assert {:ok, 3} = LoadEstimator.run()

      # What it actually takes is the tighter of the two rules: 240 MW of
      # branch, 50 MW of 69 kV delivery.
      assert_in_delta load_at(low.id), 50.0, 0.1
    end

    test "a bank is held to what reaches its far terminal", %{metro_bus: metro_bus} do
      # HARVARD's shape exactly: no level of the yard at or above the floor
      # carries a line, so the load falls back to the 66 kV bus, whose only
      # branch is a bank reached through a 55 MVA 33 kV line. The bank's class
      # rating is 100 MVA but it can never deliver more than the line does.
      low = bus(7, 66.0, {-112.06, 33.44})
      distribution = bus(7, 33.0, {-112.06, 33.44})
      line(distribution, metro_bus, 55.0)
      bank(low, distribution, 100.0)

      county("04013", 4_000_000, {-112.05, 33.45})

      assert {:ok, 3} = LoadEstimator.run()

      assert_in_delta load_at(low.id), 0.8 * 55.0, 0.1
    end
  end

  describe "class ceiling" do
    test "circuits passing through a yard are transfer, not delivery", %{
      metro_bus: metro_bus,
      desert_bus: desert_bus
    } do
      # Mesa's bus 76087 exactly: two big 69 kV circuits, one in and one out,
      # summed into 186 MW of "capability" on a yard whose banks step down at
      # 20-30 MVA a piece. It held 208.7 MW and would not solve.
      hub = bus(10, 69.0, {-112.03, 33.47})
      line(hub, metro_bus, 300.0)
      line(hub, desert_bus, 300.0)

      county("04013", 4_000_000, {-112.05, 33.45})

      caps = LoadEstimator.capability(LoadEstimator.network())
      assert_in_delta caps[hub.id].cap_mw, 480.0, 0.1
      assert_in_delta caps[hub.id].delivery_cap_mw, 50.0, 0.1

      assert {:ok, 3} = LoadEstimator.run()

      assert_in_delta load_at(hub.id), 50.0, 0.1
      assert_in_delta total_load(), 850.0, 1.0
    end

    test "MW another placer already committed is not offered twice", %{metro_bus: metro_bus} do
      # Datacenter rows are written by Grid.map_datacenters_to_grid/0 and held
      # FLAT by Demand.scale_loads/3, so they are the bus's load at every hour
      # and the estimator may only fill what is left.
      small = bus(5, 138.0, {-112.04, 33.46})
      line(small, metro_bus, 100.0)

      Repo.insert!(%Load{
        bus_id: small.id,
        p_mw: 60.0,
        q_mvar: 19.7,
        load_type: "datacenter",
        status: "in_service"
      })

      county("04013", 4_000_000, {-112.05, 33.45})

      assert {:ok, 3} = LoadEstimator.run()

      # 0.8 x its 100 MVA line is 80 MW, of which the campus holds 60.
      assert_in_delta load_at(small.id), 20.0, 0.1
    end

    test "water facility MW is reserved out of the ceiling, not stacked on top", %{
      metro_bus: metro_bus
    } do
      # reapply_water_facility_loads/0 merges the plant into the SAME row this
      # allocation writes, and it runs after the caps. Three 69 kV buses sat at
      # 51-54 MW against a 50 MW ceiling because the cap held the spread and
      # the treatment plant went on afterwards.
      hub = bus(10, 69.0, {-112.03, 33.47})
      line(hub, metro_bus, 300.0)

      Repo.insert!(%WaterFacility{
        name: "Big Treatment Plant",
        facility_type: "treatment",
        coordinates: %Geo.Point{coordinates: {-112.03, 33.47}, srid: 4326},
        status: "active",
        power_consumption_mw: 12.0,
        bus_id: hub.id
      })

      county("04013", 4_000_000, {-112.05, 33.45})

      assert {:ok, 3} = LoadEstimator.run()

      # 38 MW of spread plus the 12 MW plant, not 50 plus 12.
      assert_in_delta load_at(hub.id), 50.0, 0.1
    end

    test "a bus whose ceiling is spoken for drops out of the candidate set", %{
      metro_bus: metro_bus
    } do
      small = bus(5, 138.0, {-112.04, 33.46})
      line(small, metro_bus, 500.0)

      Repo.insert!(%Load{
        bus_id: small.id,
        p_mw: 150.0,
        q_mvar: 49.3,
        load_type: "datacenter",
        status: "in_service"
      })

      county("04013", 4_000_000, {-112.05, 33.45})

      assert {:ok, 2} = LoadEstimator.run()

      assert load_at(small.id) == nil
      assert_in_delta total_load(), 850.0, 1.0
    end
  end

  describe "reallocate/0" do
    setup %{metro_bus: metro_bus} do
      small = bus(5, 138.0, {-112.04, 33.46})
      line(small, metro_bus, 100.0)
      county("04013", 4_000_000, {-112.05, 33.45})
      %{small: small}
    end

    test "holds the baseline total fixed and is idempotent", %{small: small} do
      assert {:ok, 3} = LoadEstimator.run()
      before_total = total_load()

      assert {:ok, first} = LoadEstimator.reallocate()
      assert_in_delta total_load(), before_total, 0.5
      assert_in_delta load_at(small.id), 80.0, 0.1

      assert {:ok, second} = LoadEstimator.reallocate()
      assert_in_delta total_load(), before_total, 0.5
      assert second.moved_mw <= first.moved_mw + 0.5
    end

    test "water facility MW is not added twice", %{metro_bus: metro_bus} do
      Repo.insert!(%WaterFacility{
        name: "Test Treatment Plant",
        facility_type: "treatment",
        coordinates: %Geo.Point{coordinates: {-112.01, 33.51}, srid: 4326},
        status: "active",
        power_consumption_mw: 12.0,
        bus_id: metro_bus.id
      })

      assert {:ok, 3} = LoadEstimator.run()
      after_run = load_at(metro_bus.id)

      assert {:ok, _} = LoadEstimator.reallocate()
      assert {:ok, _} = LoadEstimator.reallocate()

      assert_in_delta load_at(metro_bus.id), after_run, 0.5
    end
  end

  describe "capability/1" do
    test "counts class-standard banks and line ratings, never stored bank MVA" do
      high = bus(8, 230.0, {-100.0, 40.0})
      low = bus(8, 69.0, {-100.0, 40.0})
      far = bus(9, 230.0, {-100.5, 40.0})
      line(high, far, 600.0)
      bank(high, low, 9999.0)

      caps = LoadEstimator.capability(LoadEstimator.network())

      # A 230 kV bank is 400 MVA by class, whatever the row says.
      assert_in_delta caps[high.id].capability_mva, 1000.0, 0.01
      assert_in_delta caps[high.id].cap_mw, 800.0, 0.01
      assert caps[high.id].line_degree == 1

      # The low side sees only the bank, held to the 600 MVA that reaches it.
      assert_in_delta caps[low.id].capability_mva, 400.0, 0.01
      assert caps[low.id].line_degree == 0
    end
  end
end
