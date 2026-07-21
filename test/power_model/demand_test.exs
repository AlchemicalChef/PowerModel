defmodule PowerModel.DemandTest do
  use PowerModel.DataCase, async: false

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
