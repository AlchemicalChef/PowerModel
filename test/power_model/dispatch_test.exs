defmodule PowerModel.DispatchTest do
  use PowerModel.DataCase, async: false

  alias PowerModel.Demand.{BADemandHour, BAFuelHour}
  alias PowerModel.Dispatch
  alias PowerModel.Grid.{BalancingAuthority, Bus, Generator}

  # July -> EIA summer capability season
  @hour ~U[2024-07-15 18:00:00Z]
  # January -> winter
  @winter_hour ~U[2024-01-15 18:00:00Z]

  defp gen(id, opts) do
    Enum.into(opts, %{
      id: id,
      bus_id: Keyword.get(opts, :bus_id, 1),
      fuel_type: "NG",
      prime_mover: "CC",
      p_max_mw: 100.0,
      p_min_mw: 0.0,
      capacity_factor: 0.5,
      status: "in_service"
    })
  end

  defp pv(id, opts), do: gen(id, Keyword.merge([fuel_type: "SUN", prime_mover: "PV"], opts))

  # Two-BA, two-bus world: BA 1 on bus 1, BA 2 on bus 2.
  defp bus_ba, do: %{1 => 1, 2 => 2}

  describe "merit order" do
    test "fills units by capacity factor descending, capping each at capability" do
      gens = [
        gen(1, bus_id: 1, capacity_factor: 0.2, p_max_mw: 100.0),
        gen(2, bus_id: 1, capacity_factor: 0.9, p_max_mw: 100.0),
        gen(3, bus_id: 1, capacity_factor: 0.5, p_max_mw: 100.0)
      ]

      {:ok, %{dispatch: dispatch}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 150.0}}
        )

      # 150 MW: the 0.9-CF unit fills to its 100 MW cap, the 0.5-CF unit takes
      # the remaining 50, the 0.2-CF unit never starts.
      assert dispatch[2] == 100.0
      assert dispatch[3] == 50.0
      assert dispatch[1] == 0.0
    end

    test "every generator appears in the map, offline ones as an explicit 0.0" do
      gens = [
        gen(1, bus_id: 1, capacity_factor: 0.9),
        gen(2, bus_id: 1, capacity_factor: 0.1),
        # out of service: never dispatched, still present
        gen(3, bus_id: 1, status: "retired", capacity_factor: 0.9)
      ]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 40.0}}
        )

      assert Map.keys(dispatch) |> Enum.sort() == [1, 2, 3]
      assert dispatch[1] == 40.0
      assert dispatch[2] == 0.0
      assert dispatch[3] == 0.0
      assert coverage.online_units == 1
      assert coverage.offline_units == 2
    end

    test "measured MW beyond the fleet's capability are reported as unserved" do
      gens = [gen(1, bus_id: 1, p_max_mw: 100.0)]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 250.0}}
        )

      assert dispatch[1] == 100.0
      assert_in_delta coverage.unserved_mw, 150.0, 1.0e-9
    end
  end

  describe "minimum load" do
    test "a unit that cannot hold its p_min is left offline, not part-loaded" do
      gens = [
        gen(1, bus_id: 1, capacity_factor: 0.9, p_max_mw: 100.0, p_min_mw: 60.0),
        gen(2, bus_id: 1, capacity_factor: 0.8, p_max_mw: 100.0, p_min_mw: 80.0),
        gen(3, bus_id: 1, capacity_factor: 0.7, p_max_mw: 50.0, p_min_mw: 10.0)
      ]

      {:ok, %{dispatch: dispatch}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 130.0}}
        )

      # Unit 1 takes 100. Unit 2 would get 30 MW, below its 80 MW minimum, so
      # it stays offline and unit 3 -- next in merit order, small enough --
      # picks the 30 MW up.
      assert dispatch[1] == 100.0
      assert dispatch[2] == 0.0
      assert dispatch[3] == 30.0
    end

    test "a p_min above capability does not make the unit undispatchable" do
      gens = [gen(1, bus_id: 1, p_max_mw: 40.0, p_min_mw: 90.0)]

      {:ok, %{dispatch: dispatch}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 100.0}}
        )

      assert dispatch[1] == 40.0
    end
  end

  describe "seasonal capability" do
    test "caps at summer capability in summer, winter capability in winter" do
      gens = [
        gen(1, bus_id: 1, p_max_mw: 100.0)
        |> Map.merge(%{summer_capacity_mw: 85.0, winter_capacity_mw: 95.0})
      ]

      totals = %{1 => %{"natural_gas" => 200.0}}

      {:ok, %{dispatch: summer}} =
        Dispatch.for_hour(gens, @hour, bus_ba: bus_ba(), fuel_totals: totals)

      {:ok, %{dispatch: winter}} =
        Dispatch.for_hour(gens, @winter_hour, bus_ba: bus_ba(), fuel_totals: totals)

      assert summer[1] == 85.0
      assert winter[1] == 95.0
    end

    test "falls back to nameplate when the seasonal columns do not exist" do
      gens = [gen(1, bus_id: 1, p_max_mw: 100.0)]

      {:ok, %{dispatch: dispatch}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 200.0}}
        )

      assert dispatch[1] == 100.0
    end

    test "falls back to summer capability when only that column exists" do
      gens = [gen(1, bus_id: 1, p_max_mw: 100.0) |> Map.put(:summer_capacity_mw, 85.0)]

      {:ok, %{dispatch: dispatch}} =
        Dispatch.for_hour(gens, @winter_hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 200.0}}
        )

      assert dispatch[1] == 85.0
    end
  end

  describe "absolute MW" do
    test "each BA dispatches exactly its measured fuel MW, whatever the load is" do
      gens = [
        gen(1, bus_id: 1, fuel_type: "NG", p_max_mw: 500.0, capacity_factor: 0.6),
        gen(2, bus_id: 1, fuel_type: "NUC", p_max_mw: 500.0, capacity_factor: 0.95),
        gen(3, bus_id: 2, fuel_type: "WND", p_max_mw: 500.0, capacity_factor: 0.4)
      ]

      totals = %{
        1 => %{"natural_gas" => 300.0, "nuclear" => 400.0},
        2 => %{"wind" => 120.0}
      }

      # Loads deliberately do NOT match generation: BA 1 exports, BA 2 imports.
      loads = [%{bus_id: 1, p_mw: 500.0}, %{bus_id: 2, p_mw: 300.0}]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour, bus_ba: bus_ba(), fuel_totals: totals, loads: loads)

      assert dispatch[1] == 300.0
      assert dispatch[2] == 400.0
      assert dispatch[3] == 120.0

      # sum(dispatch per BA) == that BA's measured fuel total
      assert_in_delta coverage.by_ba[1].dispatched_mw, 700.0, 1.0e-9
      assert_in_delta coverage.by_ba[2].dispatched_mw, 120.0, 1.0e-9

      # ... so gen - load reproduces interchange instead of self-sufficiency
      assert_in_delta coverage.by_ba[1].implied_interchange_mw, 200.0, 1.0e-9
      assert_in_delta coverage.by_ba[2].implied_interchange_mw, -180.0, 1.0e-9
    end

    test "storage charging (negative measured MW) dispatches nothing" do
      gens = [gen(1, bus_id: 1, fuel_type: "MWH", prime_mover: "BA", p_max_mw: 100.0)]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"other" => -50.0}}
        )

      assert dispatch[1] == 0.0
      assert coverage.by_ba[1].by_fuel["other"].target_mw == -50.0
    end
  end

  describe "utility-scale solar and wind" do
    test "measured solar fills utility-scale units only; onsite runs on its own CF" do
      gens = [
        pv(1, bus_id: 1, p_max_mw: 100.0, capacity_factor: 0.3, utility_scale: true),
        pv(2, bus_id: 1, p_max_mw: 200.0, capacity_factor: 0.25, utility_scale: true),
        pv(3, bus_id: 1, p_max_mw: 40.0, capacity_factor: 0.2, utility_scale: false)
      ]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"solar" => 150.0}}
        )

      # The 150 measured MW go to the two grid-scale units in merit order.
      assert dispatch[1] == 100.0
      assert dispatch[2] == 50.0
      # The onsite array is not part of that measurement: it runs at its own
      # capacity factor, 40 MW * 0.2.
      assert_in_delta dispatch[3], 8.0, 1.0e-9

      solar = coverage.by_ba[1].by_fuel["solar"]
      # Every measured MW is still placed, and none of them went to the onsite
      # unit: the pool's target and dispatched MW are untouched by it.
      assert_in_delta solar.target_mw, 150.0, 1.0e-9
      assert_in_delta solar.dispatched_mw, 150.0, 1.0e-9
      assert solar.units == 2
      assert solar.online_units == 2
      assert_in_delta coverage.unserved_mw, 0.0, 1.0e-9

      # The onsite MW are reported beside the target, never inside it.
      assert_in_delta solar.onsite_mw, 8.0, 1.0e-9
      assert solar.onsite_units == 1
      assert_in_delta coverage.onsite_mw, 8.0, 1.0e-9
      assert coverage.onsite_units == 1

      # The BA total does include them — they are real injections at real
      # buses, so 150 measured + 8 onsite reach the network.
      assert_in_delta coverage.by_ba[1].dispatched_mw, 158.0, 1.0e-9
    end

    test "the same fleet tagged utility-scale puts the onsite unit in the pool instead" do
      # Contrast with the test above: as a pool member the 0.2-CF unit is last
      # in merit order and the 150 measured MW never reach it.
      gens = [
        pv(1, bus_id: 1, p_max_mw: 100.0, capacity_factor: 0.3, utility_scale: true),
        pv(2, bus_id: 1, p_max_mw: 200.0, capacity_factor: 0.25, utility_scale: true),
        pv(3, bus_id: 1, p_max_mw: 40.0, capacity_factor: 0.2, utility_scale: true)
      ]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"solar" => 150.0}}
        )

      assert dispatch[3] == 0.0
      assert coverage.onsite_mw == 0.0
      assert coverage.by_ba[1].by_fuel["solar"].units == 3
    end

    test "onsite wind is held out of the measured wind column too" do
      gens = [
        gen(1,
          bus_id: 1,
          fuel_type: "WND",
          prime_mover: "WT",
          p_max_mw: 100.0,
          utility_scale: true
        ),
        gen(2,
          bus_id: 1,
          fuel_type: "WND",
          prime_mover: "WT",
          p_max_mw: 20.0,
          capacity_factor: 0.4,
          utility_scale: false
        )
      ]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour, bus_ba: bus_ba(), fuel_totals: %{1 => %{"wind" => 60.0}})

      assert dispatch[1] == 60.0
      assert_in_delta dispatch[2], 8.0, 1.0e-9
      assert_in_delta coverage.by_ba[1].by_fuel["wind"].target_mw, 60.0, 1.0e-9
      assert_in_delta coverage.by_ba[1].by_fuel["wind"].onsite_mw, 8.0, 1.0e-9
    end

    test "the onsite operating point is capped at seasonal capability, not nameplate" do
      gens = [
        pv(1, bus_id: 1, p_max_mw: 100.0, capacity_factor: 0.5, utility_scale: true),
        pv(2, bus_id: 1, p_max_mw: 100.0, capacity_factor: 0.5, utility_scale: false)
        |> Map.put(:summer_capacity_mw, 40.0)
      ]

      {:ok, %{dispatch: dispatch}} =
        Dispatch.for_hour(gens, @hour, bus_ba: bus_ba(), fuel_totals: %{1 => %{"solar" => 10.0}})

      # 40 MW of summer capability at CF 0.5, not 100 MW of nameplate.
      assert_in_delta dispatch[2], 20.0, 1.0e-9
    end

    test "measured solar with no utility-scale unit to carry it is reported unmatched" do
      # Before sector tagging the onsite array absorbed the measurement and the
      # gap disappeared. The BA's utility-scale solar is genuinely missing from
      # the model, and coverage has to say so.
      gens = [pv(1, bus_id: 1, p_max_mw: 40.0, capacity_factor: 0.2, utility_scale: false)]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"solar" => 300.0}}
        )

      assert_in_delta dispatch[1], 8.0, 1.0e-9
      assert [%{ba_id: 1, fuel: "solar", mw: 300.0}] = coverage.unmatched
      assert_in_delta coverage.unmatched_mw, 300.0, 1.0e-9
    end

    test "sector plays no part in any other fuel" do
      # EIA-930's gas column counts industrial cogeneration; only solar and
      # wind are utility-scale-only measurements.
      gens = [
        gen(1, bus_id: 1, fuel_type: "NG", capacity_factor: 0.4, utility_scale: true),
        gen(2, bus_id: 1, fuel_type: "NG", capacity_factor: 0.9, utility_scale: false)
      ]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 150.0}}
        )

      # The industrial unit wins the merit order like any other gas unit.
      assert dispatch[2] == 100.0
      assert dispatch[1] == 50.0
      assert coverage.onsite_mw == 0.0
      assert coverage.by_ba[1].by_fuel["natural_gas"].units == 2
    end

    test "a fixture without the field, or an unset column, dispatches as utility-scale" do
      # Only the EIA-860 ingest sets utility_scale; plain-map fixtures and
      # MATPOWER imports have no value at all, and NULL means "not derived",
      # not "onsite".
      gens = [
        pv(1, bus_id: 1, p_max_mw: 100.0, capacity_factor: 0.3),
        pv(2, bus_id: 1, p_max_mw: 100.0, capacity_factor: 0.2, utility_scale: nil)
      ]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"solar" => 150.0}}
        )

      assert dispatch[1] == 100.0
      assert dispatch[2] == 50.0
      assert coverage.onsite_units == 0
      assert coverage.by_ba[1].by_fuel["solar"].units == 2
    end

    test "onsite MW count as generation already placed on the island" do
      gens = [
        gen(1, bus_id: 1, fuel_type: "NG", p_max_mw: 100.0),
        pv(2, bus_id: 1, p_max_mw: 40.0, capacity_factor: 0.5, utility_scale: false),
        # No coal measurement exists for BA 1, so this one goes to the fallback
        gen(3, bus_id: 1, fuel_type: "BIT", p_max_mw: 200.0, capacity_factor: 0.5)
      ]

      {:ok, %{dispatch: dispatch}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 30.0}},
          loads: [%{bus_id: 1, p_mw: 100.0}],
          islands: [MapSet.new([1])]
        )

      assert dispatch[1] == 30.0
      assert_in_delta dispatch[2], 20.0, 1.0e-9
      # 100 MW load - (30 measured + 20 onsite) = 50 MW residual, taken against
      # the coal unit's 100 MW expected output. Ignoring the onsite MW here
      # would ask the coal unit to serve 70 MW the array is already serving.
      assert_in_delta dispatch[3], 50.0, 1.0e-9
    end
  end

  describe "island fallback" do
    test "unmeasured units share the load their island's measured fuels left" do
      gens = [
        gen(1, bus_id: 1, fuel_type: "NG", p_max_mw: 100.0),
        # No BA-fuel measurement exists for coal in BA 1
        gen(2, bus_id: 1, fuel_type: "BIT", p_max_mw: 200.0, capacity_factor: 0.5)
      ]

      loads = [%{bus_id: 1, p_mw: 150.0}]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 60.0}},
          loads: loads,
          islands: [MapSet.new([1])]
        )

      # 150 MW load - 60 MW measured = 90 MW residual, and the coal unit's
      # expected output (200 * 0.5) is 100 MW, so it runs at 90 of it.
      assert dispatch[1] == 60.0
      assert_in_delta dispatch[2], 90.0, 1.0e-9
      assert_in_delta coverage.fallback_mw, 90.0, 1.0e-9
      assert [%{fuel: "coal", ba_id: 1}] = coverage.missing
    end

    test "unmeasured units stay offline when the measurement already covers the load" do
      gens = [
        gen(1, bus_id: 1, fuel_type: "NG", p_max_mw: 300.0),
        gen(2, bus_id: 1, fuel_type: "BIT", p_max_mw: 200.0)
      ]

      {:ok, %{dispatch: dispatch}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 200.0}},
          loads: [%{bus_id: 1, p_mw: 150.0}],
          islands: [MapSet.new([1])]
        )

      assert dispatch[1] == 200.0
      assert dispatch[2] == 0.0
    end

    test "residuals never cross island boundaries" do
      gens = [
        gen(1, bus_id: 1, fuel_type: "NG", p_max_mw: 300.0),
        gen(2, bus_id: 2, fuel_type: "BIT", p_max_mw: 200.0, capacity_factor: 1.0)
      ]

      {:ok, %{dispatch: dispatch}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 200.0}},
          # island 1 is well supplied; island 2 has 80 MW of load and only the
          # unmeasured coal unit to serve it
          loads: [%{bus_id: 1, p_mw: 150.0}, %{bus_id: 2, p_mw: 80.0}],
          islands: [MapSet.new([1]), MapSet.new([2])]
        )

      assert dispatch[1] == 200.0
      assert_in_delta dispatch[2], 80.0, 1.0e-9
    end

    test "generators on buses without a BA fall back too" do
      gens = [gen(1, bus_id: 99, fuel_type: "NG", p_max_mw: 100.0, capacity_factor: 0.6)]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 60.0}},
          loads: [%{bus_id: 99, p_mw: 40.0}]
        )

      assert_in_delta dispatch[1], 40.0, 1.0e-9
      assert [%{ba_id: nil, fuel: "natural_gas"}] = coverage.missing
    end
  end

  describe "fuel classification" do
    test "maps EIA energy-source codes onto the EIA-930 fuel columns" do
      assert Dispatch.fuel_for(%{fuel_type: "NG", prime_mover: "CC"}) == "natural_gas"
      assert Dispatch.fuel_for(%{fuel_type: "BIT", prime_mover: "ST"}) == "coal"
      assert Dispatch.fuel_for(%{fuel_type: "NUC", prime_mover: "ST"}) == "nuclear"
      assert Dispatch.fuel_for(%{fuel_type: "DFO", prime_mover: "IC"}) == "petroleum"
      assert Dispatch.fuel_for(%{fuel_type: "WND", prime_mover: "WT"}) == "wind"
      assert Dispatch.fuel_for(%{fuel_type: "SUN", prime_mover: "PV"}) == "solar"
    end

    test "hydro splits on prime mover, storage and geothermal fold into other" do
      assert Dispatch.fuel_for(%{fuel_type: "WAT", prime_mover: "HY"}) == "hydro"
      # EIA-930 reports pumped storage outside the hydro column
      assert Dispatch.fuel_for(%{fuel_type: "WAT", prime_mover: "PS"}) == "other"
      assert Dispatch.fuel_for(%{fuel_type: "MWH", prime_mover: "BA"}) == "other"
      assert Dispatch.fuel_for(%{fuel_type: "GEO", prime_mover: "ST"}) == "other"
      assert Dispatch.fuel_for(%{fuel_type: "LFG", prime_mover: "IC"}) == "other"
    end

    test "units EIA-930 does not report as generation stay outside the canonical set" do
      # Import pseudo-generators stand in for interchange; letting them compete
      # for another fuel's measured MW would double-count that fuel.
      assert Dispatch.fuel_for(%{fuel_type: "import", prime_mover: nil}) == "import"
      assert Dispatch.fuel_for(%{fuel_type: nil, prime_mover: nil}) == "unknown"
    end
  end

  describe "no data" do
    test "declines the hour when no BA reported any fuel" do
      assert Dispatch.for_hour([gen(1, bus_id: 1)], @hour, fuel_totals: %{}) ==
               {:error, :no_fuel_data}
    end

    @tag :db
    test "declines an hour with no rows in the database" do
      assert Dispatch.for_hour([gen(1, bus_id: 1)], @hour) == {:error, :no_fuel_data}
    end
  end

  describe "database-backed dispatch" do
    @tag :db
    test "reads measured fuel MW, BA codes and reported interchange from the repo" do
      ba = Repo.insert!(%BalancingAuthority{code: "CISO", name: "California ISO"})
      bus = Repo.insert!(%Bus{base_kv: 230.0, source: "test", balancing_authority_id: ba.id})

      nuclear =
        Repo.insert!(%Generator{
          bus_id: bus.id,
          fuel_type: "NUC",
          prime_mover: "ST",
          p_max_mw: 2_500.0,
          p_min_mw: 0.0,
          capacity_factor: 0.95
        })

      gas =
        Repo.insert!(%Generator{
          bus_id: bus.id,
          fuel_type: "NG",
          prime_mover: "CC",
          p_max_mw: 1_000.0,
          p_min_mw: 0.0,
          capacity_factor: 0.4
        })

      Repo.insert!(%BAFuelHour{
        ba_code: "CISO",
        timestamp_utc: @hour,
        fuel: "nuclear",
        net_generation_mw: 2_240.0
      })

      Repo.insert!(%BAFuelHour{
        ba_code: "CISO",
        timestamp_utc: @hour,
        fuel: "natural_gas",
        net_generation_mw: 600.0
      })

      Repo.insert!(%BADemandHour{
        balancing_authority_id: ba.id,
        timestamp_utc: @hour,
        demand_mw: 3_000.0,
        total_interchange_mw: -160.0
      })

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour([nuclear, gas], @hour, loads: [%{bus_id: bus.id, p_mw: 3_000.0}])

      assert dispatch[nuclear.id] == 2_240.0
      assert dispatch[gas.id] == 600.0

      ba_coverage = coverage.by_ba[ba.id]
      assert ba_coverage.code == "CISO"
      assert_in_delta ba_coverage.target_mw, 2_840.0, 1.0e-9
      # gen - load = -160 MW, matching what EIA reported for the same hour
      assert_in_delta ba_coverage.implied_interchange_mw, -160.0, 1.0e-9
      assert ba_coverage.reported_interchange_mw == -160.0
    end

    @tag :db
    test "a minute past the hour resolves to the same hour's data" do
      ba = Repo.insert!(%BalancingAuthority{code: "ERCO", name: "ERCOT"})
      bus = Repo.insert!(%Bus{base_kv: 345.0, source: "test", balancing_authority_id: ba.id})

      g =
        Repo.insert!(%Generator{
          bus_id: bus.id,
          fuel_type: "WND",
          prime_mover: "WT",
          p_max_mw: 900.0,
          capacity_factor: 0.35
        })

      Repo.insert!(%BAFuelHour{
        ba_code: "ERCO",
        timestamp_utc: @hour,
        fuel: "wind",
        net_generation_mw: 700.0
      })

      {:ok, %{dispatch: dispatch}} =
        Dispatch.for_hour([g], DateTime.add(@hour, 42 * 60, :second))

      assert dispatch[g.id] == 700.0
    end
  end
end
