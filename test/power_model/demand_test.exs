defmodule PowerModel.DemandTest do
  use PowerModel.DataCase, async: false

  require Logger

  import ExUnit.CaptureLog

  @moduletag :db

  alias PowerModel.Demand
  alias PowerModel.Demand.BADemandHour
  alias PowerModel.Grid.BalancingAuthority

  @hour ~U[2024-07-15 20:00:00Z]

  setup do
    ciso = Repo.insert!(%BalancingAuthority{code: "CISO", name: "California ISO"})
    erco = Repo.insert!(%BalancingAuthority{code: "ERCO", name: "ERCOT"})

    Repo.insert!(%BADemandHour{
      balancing_authority_id: ciso.id,
      timestamp_utc: @hour,
      demand_mw: 200.0
    })

    Repo.insert!(%BADemandHour{
      balancing_authority_id: erco.id,
      timestamp_utc: @hour,
      demand_mw: 50.0
    })

    %{ciso: ciso, erco: erco}
  end

  # scale_loads/3 operates on snapshot data (plain maps work like structs here)
  defp grid(ciso_id, erco_id) do
    buses = [
      %{id: 1, balancing_authority_id: ciso_id},
      %{id: 2, balancing_authority_id: ciso_id},
      %{id: 3, balancing_authority_id: erco_id},
      %{id: 4, balancing_authority_id: nil}
    ]

    loads = [
      %{id: 1, bus_id: 1, p_mw: 60.0, q_mvar: 18.0},
      %{id: 2, bus_id: 2, p_mw: 40.0, q_mvar: 12.0},
      %{id: 3, bus_id: 3, p_mw: 100.0, q_mvar: 30.0},
      %{id: 4, bus_id: 4, p_mw: 25.0, q_mvar: 7.5}
    ]

    {buses, loads}
  end

  test "available_range/0 reflects ingested data" do
    assert {min_ts, max_ts} = Demand.available_range()
    assert DateTime.compare(min_ts, @hour) == :eq
    assert DateTime.compare(max_ts, @hour) == :eq
  end

  test "ba_scale_factors/3 computes actual/baseline per BA", %{ciso: ciso, erco: erco} do
    {buses, loads} = grid(ciso.id, erco.id)
    factors = Demand.ba_scale_factors(loads, buses, @hour)

    # CISO baseline 100 MW vs actual 200 MW -> 2.0
    assert_in_delta factors[ciso.id], 2.0, 1.0e-9
    # ERCO baseline 100 MW vs actual 50 MW -> 0.5
    assert_in_delta factors[erco.id], 0.5, 1.0e-9
  end

  test "scale_loads/3 makes each BA's loads sum to its actual demand",
       %{ciso: ciso, erco: erco} do
    {buses, loads} = grid(ciso.id, erco.id)
    scaled = Demand.scale_loads(loads, buses, @hour)

    ciso_total =
      scaled |> Enum.filter(&(&1.bus_id in [1, 2])) |> Enum.map(& &1.p_mw) |> Enum.sum()

    erco_total =
      scaled |> Enum.filter(&(&1.bus_id == 3)) |> Enum.map(& &1.p_mw) |> Enum.sum()

    assert_in_delta ciso_total, 200.0, 1.0e-6
    assert_in_delta erco_total, 50.0, 1.0e-6
  end

  test "q scales by the same factor, preserving power factor", %{ciso: ciso, erco: erco} do
    {buses, loads} = grid(ciso.id, erco.id)
    scaled = Demand.scale_loads(loads, buses, @hour)

    load1 = Enum.find(scaled, &(&1.id == 1))
    assert_in_delta load1.p_mw, 120.0, 1.0e-6
    assert_in_delta load1.q_mvar, 36.0, 1.0e-6
    assert_in_delta load1.q_mvar / load1.p_mw, 18.0 / 60.0, 1.0e-9
  end

  test "loads on buses without a BA keep their baseline", %{ciso: ciso, erco: erco} do
    {buses, loads} = grid(ciso.id, erco.id)
    scaled = Demand.scale_loads(loads, buses, @hour)

    load4 = Enum.find(scaled, &(&1.id == 4))
    assert load4.p_mw == 25.0
    assert load4.q_mvar == 7.5
  end

  describe "interconnection utilization aggregation" do
    alias PowerModel.Grid.{Bus, Generator, Interconnection}

    setup %{ciso: ciso, erco: erco} do
      western = Repo.insert!(%Interconnection{name: "Western"})
      ercot = Repo.insert!(%Interconnection{name: "ERCOT"})

      pt = fn lon, lat -> %Geo.Point{coordinates: {lon, lat}, srid: 4326} end

      # CISO buses in Western; ERCO bus in ERCOT
      b1 =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          coordinates: pt.(-120.0, 37.0),
          interconnection_id: western.id,
          balancing_authority_id: ciso.id
        })

      Repo.insert!(%Bus{
        bus_type: 1,
        base_kv: 138.0,
        coordinates: pt.(-119.0, 36.0),
        interconnection_id: western.id,
        balancing_authority_id: ciso.id
      })

      b3 =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          coordinates: pt.(-97.0, 31.0),
          interconnection_id: ercot.id,
          balancing_authority_id: erco.id
        })

      Repo.insert!(%Generator{p_max_mw: 500.0, bus_id: b1.id, status: "in_service"})
      Repo.insert!(%Generator{p_max_mw: 300.0, bus_id: b3.id, status: "in_service"})
      # Out-of-service capacity must not count
      Repo.insert!(%Generator{p_max_mw: 999.0, bus_id: b1.id, status: "retired"})

      %{western: western, ercot: ercot}
    end

    test "capacity sums in-service generation per interconnection",
         %{western: western, ercot: ercot} do
      capacity = Demand.interconnection_capacity()

      assert capacity[western.id] == 500.0
      assert capacity[ercot.id] == 300.0
    end

    test "BA -> interconnection map follows bus majority",
         %{ciso: ciso, erco: erco, western: western, ercot: ercot} do
      map = Demand.ba_interconnection_map()

      assert map[ciso.id] == western.id
      assert map[erco.id] == ercot.id
    end

    test "hourly demand aggregates per interconnection for a date",
         %{western: western, ercot: ercot} do
      demand = Demand.interconnection_demand_for_date(~D[2024-07-15])

      # Setup seeded CISO=200 and ERCO=50 at 20:00 UTC
      assert demand[western.id][20] == 200.0
      assert demand[ercot.id][20] == 50.0
    end

    test "peak demand date is the day of the highest national hour" do
      assert Demand.peak_demand_date() == ~D[2024-07-15]
    end
  end

  test "hour with no demand data leaves all loads at baseline", %{ciso: ciso, erco: erco} do
    {buses, loads} = grid(ciso.id, erco.id)
    scaled = Demand.scale_loads(loads, buses, ~U[2031-01-01 00:00:00Z])

    assert scaled == loads
  end

  test "datacenter loads are held flat; others scale to demand minus DC", %{ciso: ciso} do
    buses = [
      %{id: 1, balancing_authority_id: ciso.id},
      %{id: 2, balancing_authority_id: ciso.id}
    ]

    loads = [
      %{id: 1, bus_id: 1, p_mw: 50.0, q_mvar: 15.0, load_type: "constant_power"},
      %{id: 2, bus_id: 2, p_mw: 40.0, q_mvar: 12.0, load_type: "datacenter"}
    ]

    # CISO actual demand 200: DC stays at 40, other load scales to 160
    scaled = Demand.scale_loads(loads, buses, @hour)

    dc = Enum.find(scaled, &(&1.id == 2))
    other = Enum.find(scaled, &(&1.id == 1))

    assert dc.p_mw == 40.0
    assert dc.q_mvar == 12.0
    assert_in_delta other.p_mw, 160.0, 1.0e-6
    assert_in_delta Enum.sum(Enum.map(scaled, & &1.p_mw)), 200.0, 1.0e-6
  end

  test "national fallback also holds datacenter loads flat" do
    buses = [%{id: 1, balancing_authority_id: nil}, %{id: 2, balancing_authority_id: nil}]

    loads = [
      %{id: 1, bus_id: 1, p_mw: 100.0, q_mvar: 30.0, load_type: "constant_power"},
      %{id: 2, bus_id: 2, p_mw: 50.0, q_mvar: 15.0, load_type: "datacenter"}
    ]

    # National actual 250 (200 + 50): DC flat at 50, other scales to 200
    scaled = Demand.scale_loads(loads, buses, @hour)

    dc = Enum.find(scaled, &(&1.id == 2))
    other = Enum.find(scaled, &(&1.id == 1))

    assert dc.p_mw == 50.0
    assert_in_delta other.p_mw, 200.0, 1.0e-6
    assert_in_delta Enum.sum(Enum.map(scaled, & &1.p_mw)), 250.0, 1.0e-6
  end

  test "latest_demand_hour/0 returns the most recent hour with demand rows", %{ciso: ciso} do
    later = ~U[2024-07-16 05:00:00Z]

    Repo.insert!(%BADemandHour{
      balancing_authority_id: ciso.id,
      timestamp_utc: later,
      demand_mw: 10.0
    })

    assert DateTime.compare(Demand.latest_demand_hour(), later) == :eq
  end

  test "latest_demand_hour/0 is nil when no demand data exists" do
    Repo.delete_all(BADemandHour)
    assert Demand.latest_demand_hour() == nil
  end

  describe "latest_demand_hour/0 hour completeness (ENE-13)" do
    @full_hour ~U[2024-07-15 18:00:00Z]
    @near_full_hour ~U[2024-07-15 19:00:00Z]
    @boundary_hour ~U[2024-07-15 20:00:00Z]

    # The tail of a bulk EIA-930 file: 53 BAs report the body of the file, one
    # BA has a routine gap in the second-to-last hour, and only the 17 BAs that
    # had already filed appear in the file's final hour.
    defp seed_boundary_file do
      Repo.delete_all(BADemandHour)

      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      {_, bas} =
        Repo.insert_all(
          BalancingAuthority,
          for i <- 1..53 do
            %{code: "B#{i}", name: "BA #{i}", inserted_at: now, updated_at: now}
          end,
          returning: [:id]
        )

      ids = Enum.map(bas, & &1.id)

      rows =
        for {hour, reporting} <- [
              {@full_hour, ids},
              {@near_full_hour, Enum.drop(ids, 1)},
              {@boundary_hour, Enum.take(ids, 17)}
            ],
            ba_id <- reporting do
          %{
            balancing_authority_id: ba_id,
            timestamp_utc: hour,
            demand_mw: 1_000.0,
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(BADemandHour, rows)
    end

    test "skips the truncated final hour and returns the last complete one" do
      seed_boundary_file()

      # 17 of 53 is the measured boundary-hour case: defaulting to it left
      # two-thirds of the country on the synthetic baseline.
      assert DateTime.compare(Demand.latest_demand_hour(), @near_full_hour) == :eq
    end

    test "an hour missing a single BA still counts as complete" do
      seed_boundary_file()
      Repo.delete_all(from d in BADemandHour, where: d.timestamp_utc == ^@boundary_hour)

      assert DateTime.compare(Demand.latest_demand_hour(), @near_full_hour) == :eq
    end
  end

  test "regional snapshot with no BA-scalable loads keeps baseline (ENE-2)" do
    # All buses in ONE interconnection, none BA-mapped: scaling the region to
    # NATIONAL demand would inflate it severalfold. Must stay at baseline.
    buses = [
      %{id: 1, balancing_authority_id: nil, interconnection_id: 55},
      %{id: 2, balancing_authority_id: nil, interconnection_id: 55}
    ]

    loads = [
      %{id: 1, bus_id: 1, p_mw: 60.0, q_mvar: 18.0},
      %{id: 2, bus_id: 2, p_mw: 40.0, q_mvar: 12.0}
    ]

    log =
      capture_log(fn ->
        assert Demand.scale_loads(loads, buses, @hour) == loads
      end)

    assert log =~ "regional snapshot"
    assert log =~ "100.0 MW"
  end

  test "multi-interconnection snapshot without BAs still gets the national fallback (ENE-2)" do
    buses = [
      %{id: 1, balancing_authority_id: nil, interconnection_id: 1},
      %{id: 2, balancing_authority_id: nil, interconnection_id: 2}
    ]

    loads = [
      %{id: 1, bus_id: 1, p_mw: 60.0, q_mvar: 18.0},
      %{id: 2, bus_id: 2, p_mw: 40.0, q_mvar: 12.0}
    ]

    scaled = Demand.scale_loads(loads, buses, @hour)

    assert_in_delta Enum.sum(Enum.map(scaled, & &1.p_mw)), 250.0, 1.0e-6
  end

  test "partial demand coverage logs the unmatched MW and BA codes (ENE-8)", %{ciso: ciso} do
    miso = Repo.insert!(%BalancingAuthority{code: "MISO", name: "Midcontinent ISO"})

    buses = [
      %{id: 1, balancing_authority_id: ciso.id},
      %{id: 2, balancing_authority_id: ciso.id},
      %{id: 4, balancing_authority_id: nil},
      %{id: 5, balancing_authority_id: miso.id}
    ]

    loads = [
      %{id: 1, bus_id: 1, p_mw: 60.0, q_mvar: 18.0},
      %{id: 2, bus_id: 2, p_mw: 40.0, q_mvar: 12.0},
      %{id: 4, bus_id: 4, p_mw: 25.0, q_mvar: 7.5},
      %{id: 5, bus_id: 5, p_mw: 30.0, q_mvar: 9.0}
    ]

    log =
      capture_log(fn ->
        scaled = Demand.scale_loads(loads, buses, @hour)

        # CISO scaled by 2.0; MISO (no demand rows) and unmapped kept baseline
        assert Enum.find(scaled, &(&1.id == 1)).p_mw == 120.0
        assert Enum.find(scaled, &(&1.id == 4)).p_mw == 25.0
        assert Enum.find(scaled, &(&1.id == 5)).p_mw == 30.0
      end)

    assert log =~ "55.0 MW kept synthetic baseline"
    assert log =~ "25.0 MW on buses without a BA"
    assert log =~ "MISO (30.0 MW)"
  end

  test "zero-demand row keeps that BA at baseline instead of zeroing it (ENE-9)",
       %{ciso: ciso} do
    zero_ba = Repo.insert!(%BalancingAuthority{code: "ZERO", name: "Zero Demand BA"})

    Repo.insert!(%BADemandHour{
      balancing_authority_id: zero_ba.id,
      timestamp_utc: @hour,
      demand_mw: 0.0
    })

    buses = [
      %{id: 1, balancing_authority_id: ciso.id},
      %{id: 2, balancing_authority_id: ciso.id},
      %{id: 10, balancing_authority_id: zero_ba.id}
    ]

    loads = [
      %{id: 1, bus_id: 1, p_mw: 60.0, q_mvar: 18.0},
      %{id: 2, bus_id: 2, p_mw: 40.0, q_mvar: 12.0},
      %{id: 10, bus_id: 10, p_mw: 40.0, q_mvar: 12.0}
    ]

    log =
      capture_log(fn ->
        factors = Demand.ba_scale_factors(loads, buses, @hour)
        refute Map.has_key?(factors, zero_ba.id)

        scaled = Demand.scale_loads(loads, buses, @hour)
        zero_load = Enum.find(scaled, &(&1.id == 10))
        assert zero_load.p_mw == 40.0
        assert zero_load.q_mvar == 12.0
      end)

    assert log =~ "non-positive"
  end

  # ENE-17: a BA's scale factor divides by the BA's TOTAL geolocated baseline
  # in the database, never by the slice of it a snapshot happens to hold. The
  # fixtures here therefore live in the DATABASE (unlike the plain maps above,
  # which exercise the documented no-database-loads fallback).
  describe "total-baseline denominator (ENE-17)" do
    alias PowerModel.Grid.{Bus, Interconnection, Load}

    setup do
      %{ic: Repo.insert!(%Interconnection{name: "ENE17 IC"})}
    end

    defp insert_ba_demand(code, demand_mw) do
      ba = Repo.insert!(%BalancingAuthority{code: code, name: code})

      Repo.insert!(%BADemandHour{
        balancing_authority_id: ba.id,
        timestamp_utc: @hour,
        demand_mw: demand_mw
      })

      ba
    end

    # One geolocated bus + one in-service load per MW value, all in `ba`.
    # Returns `{buses, loads}` as the structs a snapshot carries.
    defp insert_loads(ba, ic, mws, load_type \\ "constant_power") do
      mws
      |> Enum.map(fn mw ->
        n = System.unique_integer([:positive])

        bus =
          Repo.insert!(%Bus{
            bus_type: 1,
            base_kv: 138.0,
            coordinates: %Geo.Point{coordinates: {-96.0 - n / 1000.0, 32.0}, srid: 4326},
            interconnection_id: ic.id,
            balancing_authority_id: ba.id
          })

        load =
          Repo.insert!(%Load{
            bus_id: bus.id,
            p_mw: mw,
            q_mvar: mw * 0.3,
            load_type: load_type,
            status: "in_service"
          })

        {bus, load}
      end)
      |> Enum.unzip()
    end

    test "a straddling BA's stray buses get their SHARE of demand, not all of it", %{ic: ic} do
      # The measured ENE-17 case: a regionally-scoped snapshot holds a handful
      # of a big BA's buses. Before the fix the factor was 69_000/200 = 345x
      # and those two buses carried the ENTIRE 69 GW of MISO demand.
      miso = insert_ba_demand("MISO", 69_000.0)
      {stray_buses, stray_loads} = insert_loads(miso, ic, [120.0, 80.0])
      {_rest_buses, _rest_loads} = insert_loads(miso, ic, [49_900.0, 49_900.0])

      log =
        capture_log(fn ->
          factors = Demand.ba_scale_factors(stray_loads, stray_buses, @hour)

          # 69_000 / 100_000 total geolocated baseline
          assert_in_delta factors[miso.id], 0.69, 1.0e-9
          # ... and nowhere near the 17.2x-345x blowup the old denominator gave
          assert factors[miso.id] < 2.0

          scaled = Demand.scale_loads(stray_loads, stray_buses, @hour)
          served = scaled |> Enum.map(& &1.p_mw) |> Enum.sum()

          # 0.2% of MISO's baseline is in this snapshot, so it serves 0.2% of
          # MISO's demand (138 MW), not 69_000 MW.
          assert_in_delta served, 138.0, 1.0e-6
        end)

      refute log =~ "outside [0.05, 2.0]"
    end

    test "a BA with half its baseline in the snapshot serves half its demand", %{ic: ic} do
      # The national case: keeping only the largest connected component drops
      # a BA to a fraction of its buses.
      ba = insert_ba_demand("HALF", 1_000.0)
      {buses, loads} = insert_loads(ba, ic, [100.0, 100.0])
      insert_loads(ba, ic, [100.0, 100.0])

      scaled = Demand.scale_loads(loads, buses, @hour)

      assert_in_delta Enum.sum(Enum.map(scaled, & &1.p_mw)), 500.0, 1.0e-6
    end

    test "a fully-covered BA scales exactly as before", %{ic: ic} do
      # When every one of a BA's loads is in the snapshot, scoped baseline ==
      # total baseline: the factor is the old one and served == demand.
      ba = insert_ba_demand("WHOLE", 300.0)
      {buses, loads} = insert_loads(ba, ic, [60.0, 40.0])

      factors = Demand.ba_scale_factors(loads, buses, @hour)
      assert_in_delta factors[ba.id], 3.0, 1.0e-9

      scaled = Demand.scale_loads(loads, buses, @hour)
      assert_in_delta Enum.sum(Enum.map(scaled, & &1.p_mw)), 300.0, 1.0e-6
    end

    test "datacenter MW is subtracted over the whole BA, not the slice", %{ic: ic} do
      # BA universe: 100 MW of shapeable load + 40 MW of flat datacenter,
      # 200 MW of demand -> shapeable factor (200 - 40) / 100 = 1.6.
      ba = insert_ba_demand("DCBA", 200.0)
      {dc_buses, dc_loads} = insert_loads(ba, ic, [40.0], "datacenter")
      {half_buses, half_loads} = insert_loads(ba, ic, [50.0])
      {other_buses, other_loads} = insert_loads(ba, ic, [50.0])

      factors = Demand.ba_scale_factors(half_loads, half_buses, @hour)
      assert_in_delta factors[ba.id], 1.6, 1.0e-9

      # Half the shapeable load and no datacenter: 80 MW.
      scaled = Demand.scale_loads(half_loads, half_buses, @hour)
      assert_in_delta Enum.sum(Enum.map(scaled, & &1.p_mw)), 80.0, 1.0e-6

      # The whole BA still reproduces demand exactly, datacenter flat.
      whole_buses = dc_buses ++ half_buses ++ other_buses
      whole_loads = dc_loads ++ half_loads ++ other_loads
      whole = Demand.scale_loads(whole_loads, whole_buses, @hour)

      assert Enum.find(whole, &(&1.load_type == "datacenter")).p_mw == 40.0
      assert_in_delta Enum.sum(Enum.map(whole, & &1.p_mw)), 200.0, 1.0e-6
    end

    test "served demand is conserved when scopes partition a BA's buses", %{ic: ic} do
      # The property the single rule buys: scope the same BA any way you like
      # and the served MW still add up to its real demand.
      ba = insert_ba_demand("SPLIT", 900.0)
      {a_buses, a_loads} = insert_loads(ba, ic, [30.0, 70.0])
      {b_buses, b_loads} = insert_loads(ba, ic, [200.0])
      {c_buses, c_loads} = insert_loads(ba, ic, [25.0], "datacenter")

      served = fn loads, buses ->
        loads |> Demand.scale_loads(buses, @hour) |> Enum.map(& &1.p_mw) |> Enum.sum()
      end

      total =
        served.(a_loads, a_buses) + served.(b_loads, b_buses) + served.(c_loads, c_buses)

      assert_in_delta total, 900.0, 1.0e-6
    end

    test "baseline_coverage/2 reports each BA's scoped share", %{ic: ic} do
      ba = insert_ba_demand("COVER", 400.0)
      {buses, loads} = insert_loads(ba, ic, [25.0])
      insert_loads(ba, ic, [75.0])

      coverage = Demand.baseline_coverage(loads, buses)

      assert coverage[ba.id].snapshot_baseline_mw == 25.0
      assert coverage[ba.id].total_baseline_mw == 100.0
      assert_in_delta coverage[ba.id].share, 0.25, 1.0e-9
    end

    test "scale_loads/3 logs the share of real demand the snapshot serves", %{ic: ic} do
      ba = insert_ba_demand("SHARE", 400.0)
      {buses, loads} = insert_loads(ba, ic, [25.0])
      insert_loads(ba, ic, [75.0])

      # The coverage line is informational; the test env logs :warning and up.
      Logger.put_module_level(Demand, :info)
      on_exit(fn -> Logger.delete_module_level(Demand) end)

      log = capture_log([level: :info], fn -> Demand.scale_loads(loads, buses, @hour) end)

      assert log =~ "snapshot holds 25.0% of the geolocated load baseline"
      assert log =~ "SHARE 25.0%"
    end

    test "a BA with no geolocated loads in the database keeps the scoped denominator" do
      # Synthetic fixtures and un-ingested networks: there is no wider universe
      # to divide by, so the snapshot's own baseline is the best estimate of it.
      ba = insert_ba_demand("NODB", 300.0)
      buses = [%{id: -1, balancing_authority_id: ba.id}]
      loads = [%{id: -1, bus_id: -1, p_mw: 100.0, q_mvar: 30.0}]

      factors = Demand.ba_scale_factors(loads, buses, @hour)

      assert_in_delta factors[ba.id], 3.0, 1.0e-9
    end
  end

  test "snapshot with no BA-mappable loads falls back to uniform national scaling" do
    # All buses unmapped (synthetic network): national demand 250 MW vs
    # baseline 100 MW -> every load scales by 2.5
    buses = [%{id: 1, balancing_authority_id: nil}, %{id: 2, balancing_authority_id: nil}]

    loads = [
      %{id: 1, bus_id: 1, p_mw: 60.0, q_mvar: 18.0},
      %{id: 2, bus_id: 2, p_mw: 40.0, q_mvar: 12.0}
    ]

    scaled = Demand.scale_loads(loads, buses, @hour)

    assert_in_delta Enum.sum(Enum.map(scaled, & &1.p_mw)), 250.0, 1.0e-6
    load1 = Enum.find(scaled, &(&1.id == 1))
    assert_in_delta load1.p_mw, 150.0, 1.0e-6
    assert_in_delta load1.q_mvar, 45.0, 1.0e-6
  end
end
