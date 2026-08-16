defmodule PowerModel.DispatchTest do
  use PowerModel.DataCase, async: false

  alias PowerModel.Demand.{BADemandHour, BAFuelHour}
  alias PowerModel.Dispatch
  alias PowerModel.Dispatch.Storage
  alias PowerModel.Grid.{BalancingAuthority, Bus, Generator, Load}
  alias PowerModel.Solver.{DCPowerFlow, Frequency}

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

    test "a negative measured fuel column still floors at zero for non-storage units" do
      # Storage has its own schedule (see the "storage" describe block); every
      # other fuel keeps the old behaviour, since nothing else in the pool can
      # consume power.
      gens = [gen(1, bus_id: 1, fuel_type: "GEO", prime_mover: "ST", p_max_mw: 100.0)]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"other" => -50.0}}
        )

      assert dispatch[1] == 0.0
      assert coverage.by_ba[1].by_fuel["other"].target_mw == -50.0
    end
  end

  # ---------------------------------------------------------------------------
  # The snapshot's share (REVIEW ENE-20)
  # ---------------------------------------------------------------------------

  describe "snapshot share" do
    test "a BA at share 0.5 is offered half of every fuel, mix untouched" do
      gens = [
        gen(1, bus_id: 1, fuel_type: "BIT", p_max_mw: 500.0, capacity_factor: 0.9),
        gen(2, bus_id: 1, fuel_type: "NG", p_max_mw: 500.0, capacity_factor: 0.4),
        # A second BA at full share: its measurement is untouched.
        gen(3, bus_id: 2, fuel_type: "WND", p_max_mw: 500.0)
      ]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{
            1 => %{"coal" => 300.0, "natural_gas" => 100.0},
            2 => %{"wind" => 120.0}
          },
          ba_snapshot_share: %{1 => 0.5}
        )

      assert dispatch[1] == 150.0
      assert dispatch[2] == 50.0
      assert dispatch[3] == 120.0

      ba = coverage.by_ba[1]
      assert ba.share == 0.5
      assert ba.by_fuel["coal"].target_mw == 150.0
      # The published measurement is kept beside the target it was scaled into.
      assert ba.by_fuel["coal"].reported_mw == 300.0
      # Same share on both fuels, so the BA's fuel mix is exactly as published.
      assert ba.by_fuel["natural_gas"].target_mw == 50.0
      assert coverage.by_ba[2].share == 1.0
      assert_in_delta coverage.share.aggregate, 320.0 / 520.0, 1.0e-12
      assert coverage.share.partial_bas == 1
    end

    test "an offline unit is still an explicit 0.0 at a partial share" do
      gens = [
        gen(1, bus_id: 1, capacity_factor: 0.9, p_max_mw: 100.0),
        gen(2, bus_id: 1, capacity_factor: 0.1, p_max_mw: 100.0)
      ]

      {:ok, %{dispatch: dispatch}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 160.0}},
          ba_snapshot_share: %{1 => 0.5}
        )

      assert dispatch[1] == 80.0
      assert dispatch[2] == 0.0
    end

    test "without the option and without a database every share is 1.0" do
      # The property that keeps every repo-free fixture in this file valid:
      # absent means whole, so nothing is scaled.
      gens = [gen(1, bus_id: 1, p_max_mw: 500.0)]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"natural_gas" => 300.0}}
        )

      assert dispatch[1] == 300.0
      assert coverage.by_ba[1].share == 1.0
      assert coverage.share.aggregate == 1.0
    end

    test "the interchange identity is compared against the share of what EIA reported" do
      gens = [gen(1, bus_id: 1, fuel_type: "BIT", p_max_mw: 500.0)]

      {:ok, %{coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"coal" => 400.0}},
          loads: [%{bus_id: 1, p_mw: 100.0}],
          ba_snapshot_share: %{1 => 0.5}
        )

      ba = coverage.by_ba[1]
      # 200 MW placed against 100 MW of served load: the snapshot's half of a
      # BA exporting 200 MW, which is what half of the reported figure means.
      assert ba.implied_interchange_mw == 100.0
      assert ba.reported_interchange_mw == nil
      assert ba.scaled_interchange_mw == nil
      assert ba.share == 0.5
    end
  end

  describe "identity anchoring (ENE20-C)" do
    test "a screened BA's budget comes from demand + interchange, in its published mix" do
      gens = [
        gen(1, bus_id: 1, fuel_type: "WAT", prime_mover: "HY", p_max_mw: 20_000.0),
        gen(2, bus_id: 1, fuel_type: "NUC", p_max_mw: 20_000.0)
      ]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          # BPAT's shape: the published net-generation column is 4,000 MW
          # short of the demand and interchange published beside it.
          fuel_totals: %{1 => %{"hydro" => 6_000.0, "nuclear" => 2_000.0}},
          ba_identity_anchor: %{1 => 12_000.0}
        )

      # 12,000 MW spread 3:1, the proportions the fuel columns report.
      assert dispatch[1] == 9_000.0
      assert dispatch[2] == 3_000.0
      assert coverage.by_ba[1].identity_correction_mw == 4_000.0
      assert coverage.share.bas_corrected == 1
      assert coverage.share.identity_correction_mw == 4_000.0
    end

    test "the snapshot's share applies to the anchored budget too" do
      gens = [gen(1, bus_id: 1, fuel_type: "WAT", prime_mover: "HY", p_max_mw: 20_000.0)]

      {:ok, %{dispatch: dispatch}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"hydro" => 6_000.0}},
          ba_identity_anchor: %{1 => 12_000.0},
          ba_snapshot_share: %{1 => 0.25}
        )

      assert dispatch[1] == 3_000.0
    end

    test "an unscreened BA keeps its published measurement" do
      gens = [gen(1, bus_id: 1, fuel_type: "BIT", p_max_mw: 500.0)]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(gens, @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"coal" => 300.0}},
          ba_identity_anchor: %{2 => 9_999.0}
        )

      assert dispatch[1] == 300.0
      assert coverage.by_ba[1].identity_correction_mw == 0.0
      assert coverage.share.bas_corrected == 0
    end
  end

  describe "minimum-load lumpiness (ENE20-B)" do
    # ERCO's four nuclear units, to the MW: minimum loads at 90-97% of
    # seasonal capability, totalling 4,775 MW against a 4,808 MW target.
    defp erco_nuclear do
      [
        {6380, 1_235.0, 1_112.0},
        {6392, 1_225.0, 1_103.0},
        {5836, 1_340.0, 1_280.0},
        {5857, 1_320.0, 1_280.0}
      ]
      |> Enum.map(fn {id, capability, p_min} ->
        gen(id,
          bus_id: 1,
          fuel_type: "NUC",
          prime_mover: "ST",
          p_max_mw: capability,
          summer_capacity_mw: capability,
          winter_capacity_mw: capability,
          p_min_mw: p_min,
          capacity_factor: 0.925
        )
      end)
    end

    test "a target between two commitment points runs the whole group, not one fewer" do
      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(erco_nuclear(), @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"nuclear" => 4_808.4}}
        )

      # A merit fill loads three units flat out and offers the 4th only the
      # 1,008 MW left over — below its 1,280 MW minimum, so it used to stay
      # cold and strand a gigawatt.
      assert coverage.by_ba[1].by_fuel["nuclear"].online_units == 4
      assert_in_delta coverage.unserved_mw, 0.0, 1.0e-6
      assert_in_delta Enum.sum(Map.values(dispatch)), 4_808.4, 1.0e-6

      for unit <- erco_nuclear() do
        mw = dispatch[unit.id]
        assert mw >= unit.p_min_mw - 1.0e-9, "unit #{unit.id} at #{mw} is below its minimum"
        assert mw <= unit.p_max_mw + 1.0e-9, "unit #{unit.id} at #{mw} is above its capability"
      end
    end

    test "MW the group genuinely cannot hold are still reported unserved" do
      # Below every minimum load in the group: no commitment can bracket it.
      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(erco_nuclear(), @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"nuclear" => 800.0}}
        )

      assert Enum.all?(Map.values(dispatch), &(&1 == 0.0))
      assert_in_delta coverage.unserved_mw, 800.0, 1.0e-9
    end

    test "a merit fill that places every MW is left alone" do
      # The rule must not reach groups the merit order already served. Here
      # the marginal unit's share (1,140 MW) clears its own 1,112 MW minimum,
      # so the merit fill places all 3,800 MW and the last unit stays cold —
      # a re-load would have started it for no reason.
      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour(erco_nuclear(), @hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"nuclear" => 3_800.0}}
        )

      assert dispatch[5836] == 1_340.0
      assert dispatch[5857] == 1_320.0
      assert dispatch[6380] == 1_140.0
      assert dispatch[6392] == 0.0
      assert_in_delta coverage.unserved_mw, 0.0, 1.0e-9
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

  # ---------------------------------------------------------------------------
  # Storage (ROADMAP item 17)
  # ---------------------------------------------------------------------------

  # CISO's measured net load (EIA-930 demand minus its utility-scale solar) and
  # its "other" column, for the 24 hours beginning 2024-07-15 20:00 UTC. Every
  # storage fact this fleet needs is visible in the two columns: net load
  # troughs at midday under the solar (14.8 GW at 19:00 UTC, 12:00 PDT) and
  # peaks on the evening ramp (36.7 GW at 04:00 UTC, 21:00 PDT), while "other"
  # swings from -4,926 MW to +4,547 MW across the same hours — a battery fleet
  # showing through a column EIA reports NET of it.
  @ciso_day [
    {15_904, -3_162},
    {16_673, -1_769},
    {18_738, -53},
    {20_940, 49},
    {22_703, -191},
    {25_680, 727},
    {30_604, 2_695},
    {35_914, 4_547},
    {36_653, 4_146},
    {35_196, 4_061},
    {32_901, 1_144},
    {30_527, -381},
    {28_625, 149},
    {26_912, 283},
    {25_844, -120},
    {25_216, -53},
    {24_995, 309},
    {25_675, 910},
    {24_764, 934},
    {20_849, -2_410},
    {18_310, -4_349},
    {17_212, -4_926},
    {15_803, -4_858},
    {14_767, -4_078}
  ]

  @ciso_profile_start ~U[2024-07-14 20:00:00Z]

  # The storage day is the UTC calendar day, which for CISO runs 17:00 PDT to
  # 16:59 PDT and so holds a whole evening peak and a whole midday trough.
  @ciso_window_start ~U[2024-07-16 00:00:00Z]
  # 12:00 PDT: the day's lowest net load, and so its deepest charging hour.
  @ciso_deepest_charge_utc ~U[2024-07-16 19:00:00Z]
  # 18:00-21:00 PDT: the evening ramp, and the hours CISO's own "other" column
  # is positive. 17:00 PDT is the crossover — the measured column is still
  # slightly negative there (-191 MW), so it belongs to neither half.
  @ciso_evening_ramp_utc 1..4 |> Enum.map(&DateTime.add(~U[2024-07-16 00:00:00Z], &1 * 3600))
  @ciso_capability_mw 11_663.0

  defp battery(id, opts) do
    gen(id, Keyword.merge([fuel_type: "MWH", prime_mover: "BA", capacity_factor: 0.06], opts))
  end

  defp ciso_batteries do
    [
      battery(10, bus_id: 1, p_max_mw: 7_000.0),
      battery(11, bus_id: 1, p_max_mw: 4_663.0)
    ]
  end

  # `other_fun` rewrites the measured "other" column, so a test can ask what
  # the schedule does with a column that never evidences charging, or one far
  # deeper than the fleet could absorb.
  defp ciso_profile(days \\ 3, other_fun \\ & &1) do
    for day <- 0..(days - 1), {{net_load, other_mw}, index} <- Enum.with_index(@ciso_day) do
      %{
        hour: DateTime.add(@ciso_profile_start, (day * 24 + index) * 3600, :second),
        net_load_mw: net_load * 1.0,
        other_mw: other_fun.(other_mw * 1.0)
      }
    end
  end

  defp storage_mw(dispatch), do: Map.get(dispatch, 10, 0.0) + Map.get(dispatch, 11, 0.0)

  # A column that neither evidences charging nor bounds discharge, so the duty
  # cycle runs on its own terms.
  defp unsigned_column, do: ciso_profile(3, fn _ -> 20_000.0 end)

  @erco_capability_mw 7_849.6

  # ERCOT's measured net load (EIA-930 demand minus utility-scale solar) and
  # its "other" column for ten July 2024 days, exported from ba_demand_hour
  # and ba_fuel_hour. Unlike CISO's, this column never goes negative across
  # the week, which is what puts ERCOT on the uncalibrated duty cycle.
  defp erco_profile do
    Path.join(__DIR__, "../fixtures/eia930_erco_net_load_2024_07.csv")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.map(fn line ->
      [timestamp, net_load, other] = String.split(line, ",")
      {:ok, hour, _} = DateTime.from_iso8601(timestamp)

      %{
        hour: hour,
        net_load_mw: String.to_float(net_load),
        other_mw: if(other == "", do: nil, else: String.to_float(other))
      }
    end)
  end

  # The fleet's MW for one hour, with storage the only thing on the system.
  # The measured "other" for the hour comes from the same profile the schedule
  # is built from, the way the database serves both.
  defp ciso_storage_at(hour, opts \\ []) do
    profile = Keyword.get(opts, :profile, ciso_profile())

    dispatch_opts =
      [
        bus_ba: bus_ba(),
        fuel_totals:
          Keyword.get_lazy(opts, :fuel_totals, fn -> measured_other(profile, hour) end),
        storage_profile: %{1 => profile}
      ]
      |> then(fn o ->
        case Keyword.fetch(opts, :share) do
          {:ok, share} -> Keyword.put(o, :ba_snapshot_share, %{1 => share})
          :error -> o
        end
      end)

    {:ok, %{dispatch: dispatch, coverage: coverage}} =
      Dispatch.for_hour(Keyword.get(opts, :generators, ciso_batteries()), hour, dispatch_opts)

    {storage_mw(dispatch), coverage}
  end

  defp measured_other(profile, hour) do
    case Enum.find(profile, &(DateTime.compare(&1.hour, hour) == :eq)) do
      nil -> %{1 => %{}}
      record -> %{1 => %{"other" => record.other_mw || 0.0}}
    end
  end

  defp ciso_day_hours do
    Enum.map(0..23, &DateTime.add(@ciso_window_start, &1 * 3600, :second))
  end

  describe "storage duty cycle" do
    test "a day of charging and discharging cancels to zero energy" do
      day = Enum.map(ciso_day_hours(), fn hour -> elem(ciso_storage_at(hour), 0) end)

      # Every hour is scheduled from the same day window, so the deviations
      # that shape it sum to zero and the fleet ends the day where it started.
      assert_in_delta Enum.sum(day), 0.0, 1.0e-6
      # ... and it is genuinely cycling, not idling at zero.
      assert Enum.count(day, &(&1 > 0.0)) >= 8
      assert Enum.count(day, &(&1 < 0.0)) >= 8
    end

    test "discharges across the evening net-load peak and charges in the midday trough" do
      for hour <- @ciso_evening_ramp_utc do
        {mw, _} = ciso_storage_at(hour)
        assert mw > 0.0, "expected discharge at #{hour}, got #{mw} MW"
      end

      # 08:00-12:00 PDT, the solar-driven bottom of the duck curve, where the
      # measured column runs -2,410 to -4,926 MW.
      for hour <- [~U[2024-07-16 15:00:00Z], ~U[2024-07-16 17:00:00Z], @ciso_deepest_charge_utc] do
        {mw, _} = ciso_storage_at(hour)
        assert mw < 0.0, "expected charging at #{hour}, got #{mw} MW"
      end

      # The deepest discharge of the day falls on the evening ramp.
      peak =
        ciso_day_hours()
        |> Enum.max_by(fn hour -> elem(ciso_storage_at(hour), 0) end)

      assert peak in @ciso_evening_ramp_utc
    end

    test "power respects nameplate in both directions" do
      for hour <- ciso_day_hours() do
        {mw, _} = ciso_storage_at(hour)
        assert abs(mw) <= @ciso_capability_mw + 1.0e-9
      end
    end

    test "the daily cycle fits the assumed 4-hour energy capacity" do
      day = Enum.map(ciso_day_hours(), fn hour -> elem(ciso_storage_at(hour), 0) end)
      capacity_mwh = Storage.duration_hours() * @ciso_capability_mw

      discharge_mwh = day |> Enum.map(&max(&1, 0.0)) |> Enum.sum()
      assert discharge_mwh <= capacity_mwh + 1.0e-9
      assert discharge_mwh > 0.0

      # SOC, tracked as the energy put in minus the energy taken back out.
      soc =
        Enum.scan(day, 0.0, fn mw, level -> level - mw end)

      assert_in_delta List.last(soc), 0.0, 1.0e-6
      assert Enum.max(soc) - Enum.min(soc) <= capacity_mwh + 1.0e-9
    end

    test "the schedule is stable across the hours of one day window" do
      # Every hour of a window resolves the same anchor, mean and gain, so the
      # 24 hourly calls describe one coherent cycle rather than 24 unrelated
      # operating points.
      gains =
        ciso_day_hours()
        |> Enum.map(fn hour ->
          {_mw, coverage} = ciso_storage_at(hour)
          stat = coverage.storage.by_ba[1]
          {stat.gain, stat.window_start, stat.window_hours}
        end)
        |> Enum.uniq()

      assert [{_gain, @ciso_window_start, 24}] = gains
    end
  end

  describe "storage calibration" do
    test "calibrates the fleet's deepest charging hour to the other column's negative" do
      # -4,926 MW is the most negative CISO's "other" column reaches in the
      # day, and it is a FLOOR on charging: geothermal and biomass generation
      # in the same column mask the rest. It is a DAILY magnitude, so it binds
      # the gain rather than any one hour.
      {mw, coverage} = ciso_storage_at(@ciso_deepest_charge_utc)
      {loose_mw, loose} = ciso_storage_at(@ciso_deepest_charge_utc, profile: unsigned_column())

      stat = coverage.storage.by_ba[1]
      assert stat.path == :calibrated
      assert stat.observed_other_min_mw == -4_926.0
      assert mw < 0.0

      # The evidence pulls the fleet BELOW what the duty cycle alone proposed.
      assert stat.gain < loose.storage.by_ba[1].gain
      assert mw > loose_mw
    end

    test "runs the pure duty cycle where the column never evidences charging" do
      {mw, coverage} = ciso_storage_at(@ciso_deepest_charge_utc, profile: unsigned_column())

      stat = coverage.storage.by_ba[1]
      assert stat.path == :duty_cycle
      # Nothing binds but the 4-hour energy capacity: the day proposes 5.36
      # nameplate-hours of discharge and is scaled to 4.
      assert_in_delta stat.gain, 4.0 / 5.361, 0.01
      assert_in_delta mw, -@ciso_capability_mw * stat.gain * 0.8222, 5.0
      assert abs(mw) <= @ciso_capability_mw
    end

    test "the whole profile window is share-scaled, not just the dispatched hour" do
      # REVIEW ENE-24. The dispatched hour's "other" arrives through
      # `fuel_totals`, which ENE-20 already share-scales; the other 23 hours of
      # the same window came straight from the BA's published column. The
      # charging floor the gain calibrates against is a DAILY minimum over all
      # 24, so it was reading a BA-sized number against a snapshot-sized fleet,
      # and the error grows with (1 - share).
      {_full_mw, full} = ciso_storage_at(@ciso_deepest_charge_utc)
      {_half_mw, half} = ciso_storage_at(@ciso_deepest_charge_utc, share: 0.5)

      assert full.storage.by_ba[1].observed_other_min_mw == -4_926.0
      assert half.storage.by_ba[1].observed_other_min_mw == -2_463.0
      assert half.storage.by_ba[1].path == :calibrated
    end

    test "no hour discharges past the snapshot's share of the measured column" do
      # The ceiling `cap_to_measurement` applies, stated in the units the
      # schedule is actually in. Before ENE-24 this held on the dispatched hour
      # alone and the other 23 were bounded by the whole BA's column.
      share = 0.4
      profile = ciso_profile()

      for hour <- ciso_day_hours() do
        {mw, _coverage} = ciso_storage_at(hour, share: share)
        record = Enum.find(profile, &(DateTime.compare(&1.hour, hour) == :eq))
        ceiling = share * max(record.other_mw, 0.0)

        assert mw <= ceiling + 1.0e-6,
               "hour #{hour} discharged #{mw} MW past the #{ceiling} MW share of the column"
      end
    end

    test "a share-scaled day still cancels to zero energy" do
      # The phantom-energy invariant is not bought back by the rescaling.
      day = Enum.map(ciso_day_hours(), fn hour -> elem(ciso_storage_at(hour, share: 0.5), 0) end)

      assert_in_delta Enum.sum(day), 0.0, 1.0e-6
      assert Enum.count(day, &(&1 > 0.0)) >= 8
    end

    test "scale_profile/2 leaves a whole-BA snapshot and a missing share alone" do
      records = [
        %{hour: @ciso_window_start, net_load_mw: 100.0, other_mw: 40.0},
        %{hour: @ciso_window_start, net_load_mw: 80.0, other_mw: nil}
      ]

      profile = %{1 => records, 2 => records}

      assert PowerModel.Dispatch.Storage.scale_profile(profile, %{}) == profile
      assert PowerModel.Dispatch.Storage.scale_profile(profile, %{1 => 1.0}) == profile

      scaled = PowerModel.Dispatch.Storage.scale_profile(profile, %{1 => 0.25})

      assert [%{net_load_mw: 25.0, other_mw: 10.0}, %{net_load_mw: 20.0, other_mw: nil}] =
               scaled[1]

      # An absent BA is 1.0, matching every other share reader in Dispatch.
      assert scaled[2] == records
    end

    test "calibration only ever reduces the gain" do
      # An "other" column ten times as deep as measured — deeper than the
      # fleet could absorb. The calibration stops binding rather than pushing
      # the fleet past its nameplate.
      deep = ciso_profile(3, &(&1 * 10))

      {mw, coverage} = ciso_storage_at(@ciso_deepest_charge_utc, profile: deep)
      {_, loose} = ciso_storage_at(@ciso_deepest_charge_utc, profile: unsigned_column())

      assert coverage.storage.by_ba[1].path == :calibrated
      assert coverage.storage.by_ba[1].gain == loose.storage.by_ba[1].gain
      assert abs(mw) <= @ciso_capability_mw + 1.0e-9
    end

    test "storage with no profile for its BA sits idle instead of generating" do
      {mw, coverage} =
        ciso_storage_at(~U[2024-07-16 04:00:00Z],
          profile: [],
          fuel_totals: %{1 => %{"other" => 5_000.0}}
        )

      assert mw == 0.0
      assert coverage.storage.by_ba[1].path == :no_profile
      assert coverage.storage.net_mw == 0.0
      # The phantom this replaces: without a schedule the batteries used to
      # fill the "other" target in merit order and generate all day.
      assert coverage.storage.units == 2
    end

    test "storage in a BA that reported no other column at all sits idle" do
      # 1,380 MW of the fleet lives in BAs EIA publishes no "other" column
      # for. There is nothing to place discharge into and nothing to bound it,
      # and scheduling the charging half alone would be invented load.
      {mw, coverage} =
        ciso_storage_at(@ciso_deepest_charge_utc, fuel_totals: %{1 => %{"solar" => 100.0}})

      assert mw == 0.0
      assert coverage.storage.by_ba[1].path == :unreported
    end
  end

  describe "storage and the fuel-anchored pool" do
    test "the other target drops by the modeled storage, and the BA still totals what EIA reported" do
      geothermal = gen(1, bus_id: 1, fuel_type: "GEO", prime_mover: "ST", p_max_mw: 3_000.0)
      hour = ~U[2024-07-16 04:00:00Z]

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour([geothermal | ciso_batteries()], hour,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"other" => 8_000.0}},
          storage_profile: %{1 => ciso_profile()},
          loads: [%{bus_id: 1, p_mw: 4_000.0}]
        )

      storage = storage_mw(dispatch)
      assert storage > 0.0

      other = coverage.by_ba[1].by_fuel["other"]
      # The pool is asked for the measurement MINUS what the batteries did, so
      # the same MW is never dispatched twice.
      assert other.reported_mw == 8_000.0
      assert_in_delta other.target_mw, 8_000.0 - storage, 1.0e-9
      assert_in_delta dispatch[1], 8_000.0 - storage, 1.0e-9

      # ... and the two halves still add back up to the measurement, so the
      # interchange identity survives the carve-out.
      assert_in_delta coverage.by_ba[1].dispatched_mw, 8_000.0, 1.0e-9
      assert_in_delta coverage.by_ba[1].implied_interchange_mw, 4_000.0, 1.0e-9
      assert_in_delta coverage.by_ba[1].storage_mw, storage, 1.0e-9
    end

    test "a charging fleet raises the pool target, because the column is measured net of it" do
      geothermal = gen(1, bus_id: 1, fuel_type: "GEO", prime_mover: "ST", p_max_mw: 8_000.0)

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour([geothermal | ciso_batteries()], @ciso_deepest_charge_utc,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"other" => -1_000.0}},
          storage_profile: %{1 => ciso_profile()},
          loads: [%{bus_id: 1, p_mw: 1_000.0}]
        )

      storage = storage_mw(dispatch)
      assert storage < 0.0

      # -1,000 MW reported while the fleet absorbed ~2,800 MW means the
      # non-storage plant in the column generated ~1,800 MW, not zero.
      assert_in_delta coverage.by_ba[1].by_fuel["other"].target_mw, -1_000.0 - storage, 1.0e-9
      assert dispatch[1] > 0.0
      assert_in_delta coverage.by_ba[1].dispatched_mw, -1_000.0, 1.0e-9
    end

    test "the pool target floors at zero rather than going negative" do
      geothermal = gen(1, bus_id: 1, fuel_type: "GEO", prime_mover: "ST", p_max_mw: 2_000.0)

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour([geothermal | ciso_batteries()], @ciso_deepest_charge_utc,
          bus_ba: bus_ba(),
          # A column MORE negative than the charging the model scheduled: the
          # pool would have to generate negative MW to make up the difference.
          fuel_totals: %{1 => %{"other" => -8_000.0}},
          storage_profile: %{1 => ciso_profile()}
        )

      assert storage_mw(dispatch) > -8_000.0
      assert coverage.by_ba[1].by_fuel["other"].target_mw == 0.0
      assert dispatch[1] == 0.0
    end

    test "a BA whose only other plant is its batteries still appears in coverage" do
      hour = ~U[2024-07-16 04:00:00Z]

      {mw, coverage} =
        ciso_storage_at(hour, fuel_totals: %{1 => %{"other" => 5_000.0}})

      assert mw > 0.0
      assert coverage.by_ba[1].storage_mw == mw
      assert_in_delta coverage.by_ba[1].dispatched_mw, mw, 1.0e-9
      # The measurement the batteries carried is not also reported missing.
      assert coverage.unmatched == []
    end

    test "charging counts as placed generation, so the island fallback sees a deeper residual" do
      # An unmeasured coal unit shares whatever load the measured fuels left.
      # A battery pulling power off the island makes that residual LARGER, and
      # ignoring the sign would have made it smaller.
      coal = gen(1, bus_id: 1, fuel_type: "BIT", p_max_mw: 20_000.0, capacity_factor: 1.0)

      {:ok, %{dispatch: dispatch}} =
        Dispatch.for_hour([coal | ciso_batteries()], @ciso_deepest_charge_utc,
          bus_ba: bus_ba(),
          fuel_totals: %{1 => %{"solar" => 0.0, "other" => -1_000.0}},
          storage_profile: %{1 => ciso_profile()},
          loads: [%{bus_id: 1, p_mw: 10_000.0}],
          islands: [MapSet.new([1])]
        )

      storage = storage_mw(dispatch)
      assert storage < 0.0
      assert_in_delta dispatch[1], 10_000.0 - storage, 1.0e-9
    end
  end

  describe "storage in the consumption chain" do
    test "a charging battery reaches the DC solve as a load at its bus" do
      # The shape Cascade.apply_dispatch/2 hands the solver: p_max_mw is the
      # dispatched MW and capacity_factor is 1.0, so a negative dispatch is a
      # negative injection. Bus 2 generates, bus 3 charges; the line between
      # them must carry the sum.
      solve = fn battery_mw ->
        DCPowerFlow.solve(%{
          buses:
            Enum.map([1, 2, 3], fn id ->
              %{id: id, bus_type: if(id == 1, do: 3, else: 1), base_kv: 138.0}
            end),
          lines: [
            %{
              id: 1,
              from_bus_id: 1,
              to_bus_id: 2,
              r_pu: 0.01,
              x_pu: 0.1,
              b_pu: 0.0,
              rating_a_mva: 1_000.0
            },
            %{
              id: 2,
              from_bus_id: 2,
              to_bus_id: 3,
              r_pu: 0.01,
              x_pu: 0.1,
              b_pu: 0.0,
              rating_a_mva: 1_000.0
            }
          ],
          transformers: [],
          generators: [
            %{id: 1, bus_id: 1, p_max_mw: 300.0, capacity_factor: 1.0},
            %{id: 2, bus_id: 3, p_max_mw: battery_mw, capacity_factor: 1.0}
          ],
          loads: [%{id: 1, bus_id: 2, p_mw: 200.0}]
        })
      end

      charging = solve.(-100.0)
      idle = solve.(0.0)

      flow = fn solution, line_id -> Map.fetch!(solution.line_flows, {:line, line_id}) end

      # Bus 3 draws 100 MW that has to arrive over line 2 from bus 2, on top of
      # the 200 MW load there: the slack at bus 1 carries 300 MW, not 200.
      assert_in_delta flow.(charging, 2).p_flow_mw, 100.0, 1.0e-6
      assert_in_delta flow.(charging, 1).p_flow_mw, 300.0, 1.0e-6
      assert_in_delta flow.(idle, 2).p_flow_mw, 0.0, 1.0e-6
      assert_in_delta flow.(idle, 1).p_flow_mw, 200.0, 1.0e-6
    end

    test "a charging battery contributes no inertia and no governor response" do
      # Frequency.simulate/5 keeps only units with p_max_mw > 0 online, and a
      # charging battery is not spinning: the trajectory must be identical with
      # and without it.
      gas = %{p_max_mw: 1_000.0, capacity_factor: 1.0, fuel_type: "gas", prime_mover: "CC"}

      charging = %{
        p_max_mw: -400.0,
        capacity_factor: 1.0,
        fuel_type: "MWH",
        prime_mover: "BA"
      }

      loads = [%{p_mw: 900.0}]

      assert Frequency.simulate([gas, charging], loads, 100.0) ==
               Frequency.simulate([gas], loads, 100.0)
    end
  end

  describe "storage phantom-energy regression" do
    test "a week of ERCOT storage nets to zero energy instead of 729 GWh of phantom" do
      batteries = [
        battery(10, bus_id: 1, p_max_mw: 5_000.0),
        battery(11, bus_id: 1, p_max_mw: 2_849.6)
      ]

      profile = %{1 => erco_profile()}

      week_at = fn hour ->
        {:ok, %{dispatch: dispatch, coverage: coverage}} =
          Dispatch.for_hour(batteries, hour,
            bus_ba: bus_ba(),
            fuel_totals: measured_other(erco_profile(), hour),
            storage_profile: profile
          )

        {storage_mw(dispatch), coverage.storage.by_ba[1]}
      end

      # Start the week on a day boundary so it spans seven whole cycles.
      {_mw, first} = week_at.(~U[2024-07-15 12:00:00Z])
      start = first.window_start

      week =
        Enum.map(0..167, fn offset ->
          {mw, _} = week_at.(DateTime.add(start, offset * 3600, :second))
          mw
        end)

      discharge_gwh = week |> Enum.map(&max(&1, 0.0)) |> Enum.sum() |> Kernel./(1000.0)
      charge_gwh = week |> Enum.map(&min(&1, 0.0)) |> Enum.sum() |> Kernel./(1000.0)

      # The phantom: the legacy pro-rata rule ran this fleet at the ERCOT
      # fleet-wide utilization all week, ~729 GWh of energy no battery made.
      # Fuel-anchored merit order cut that to ~18 GWh; the duty cycle takes it
      # to zero and supplies the charging half that never existed at all.
      assert_in_delta discharge_gwh + charge_gwh, 0.0, 0.001
      assert discharge_gwh > 20.0
      assert discharge_gwh <= 7 * Storage.duration_hours() * @erco_capability_mw / 1000.0

      # Seven complete cycles, each self-contained.
      for day <- 0..6 do
        assert_in_delta week |> Enum.slice(day * 24, 24) |> Enum.sum(), 0.0, 1.0e-6
      end
    end

    test "ERCOT takes the duty-cycle path: its other column shows no charging that week" do
      {:ok, %{coverage: coverage}} =
        Dispatch.for_hour([battery(10, bus_id: 1, p_max_mw: 7_849.6)], ~U[2024-07-16 12:00:00Z],
          bus_ba: bus_ba(),
          fuel_totals: measured_other(erco_profile(), ~U[2024-07-16 12:00:00Z]),
          storage_profile: %{1 => erco_profile()}
        )

      stat = coverage.storage.by_ba[1]
      assert stat.path == :duty_cycle
      # The signal a calibration would need: 5% of the fleet's capability.
      assert stat.observed_other_min_mw > -0.05 * @erco_capability_mw
      assert stat.gain > 0.0
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
    test "computes the share and the identity anchor from the database" do
      # REVIEW ENE-20 end to end: half of the BA's load universe sits on a
      # bus the snapshot does not hold, and the BA's published identity never
      # closes — so the units are offered half of `demand + interchange`
      # rather than all of the net-generation column.
      ba = Repo.insert!(%BalancingAuthority{code: "BPAT", name: "Bonneville"})
      in_snapshot = insert_geolocated_bus(ba)
      off_snapshot = insert_geolocated_bus(ba)

      Repo.insert!(%Load{bus_id: in_snapshot.id, p_mw: 400.0, status: "in_service"})
      Repo.insert!(%Load{bus_id: off_snapshot.id, p_mw: 400.0, status: "in_service"})

      hydro =
        Repo.insert!(%Generator{
          bus_id: in_snapshot.id,
          fuel_type: "WAT",
          prime_mover: "HY",
          p_max_mw: 5_000.0,
          p_min_mw: 0.0,
          capacity_factor: 0.5
        })

      # 4,417 hours of a broken identity: generation 1,000 MW against a demand
      # and interchange totalling 2,000. The per-fuel row is written for every
      # one of them, not just the dispatched hour — REVIEW ENE-23 moved the
      # screen onto the fuel SUM, so an hour with no fuel series is an hour the
      # screen has nothing to measure.
      for offset <- 0..29 do
        hour = DateTime.add(@hour, offset * 3600, :second)

        Repo.insert!(%BAFuelHour{
          ba_code: "BPAT",
          timestamp_utc: hour,
          fuel: "hydro",
          net_generation_mw: 1_000.0
        })

        Repo.insert!(%BADemandHour{
          balancing_authority_id: ba.id,
          timestamp_utc: hour,
          demand_mw: 1_200.0,
          net_generation_mw: 1_000.0,
          total_interchange_mw: 800.0
        })
      end

      screened = PowerModel.Demand.broken_identity_bas()
      assert screened[ba.id].closure_rate == 0.0
      assert screened[ba.id].hours == 30
      assert PowerModel.Demand.broken_identity_anchors(@hour)[ba.id] == 2_000.0

      {:ok, %{dispatch: dispatch, coverage: coverage}} =
        Dispatch.for_hour([hydro], @hour,
          islands: [MapSet.new([in_snapshot.id])],
          loads: [%{bus_id: in_snapshot.id, p_mw: 600.0}]
        )

      assert coverage.by_ba[ba.id].share == 0.5
      # Half of 2,000, not half of the 1,000 MW the fuel column claims.
      assert dispatch[hydro.id] == 1_000.0
      assert coverage.by_ba[ba.id].identity_correction_mw == 500.0
      assert coverage.by_ba[ba.id].scaled_interchange_mw == 400.0
    end

    @tag :db
    test "a BA publishing generation but no demand row is reported unanchored" do
      # REVIEW ENE-20 (ENE20-E): DEAA/GRID/HGMA/AVRN publish fuel MW with no
      # demand row to anchor them. Their MW are real exports, so they are
      # dispatched — and named, so the residual stays attributable.
      ba = Repo.insert!(%BalancingAuthority{code: "GRID", name: "Gridforce"})
      bus = insert_geolocated_bus(ba)

      g =
        Repo.insert!(%Generator{
          bus_id: bus.id,
          fuel_type: "NG",
          prime_mover: "CT",
          p_max_mw: 200.0,
          p_min_mw: 0.0,
          capacity_factor: 0.5
        })

      Repo.insert!(%BAFuelHour{
        ba_code: "GRID",
        timestamp_utc: @hour,
        fuel: "natural_gas",
        net_generation_mw: 900.0
      })

      {:ok, %{coverage: coverage}} = Dispatch.for_hour([g], @hour)

      assert [%{code: "GRID", published_mw: 900.0, dispatched_mw: 200.0}] = coverage.unanchored
      assert coverage.unanchored_mw == 900.0
      assert coverage.no_data == []
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

  # A geolocated, BA-assigned bus: the population `snapshot_load_shares/1`
  # measures its universe over.
  defp insert_geolocated_bus(ba) do
    Repo.insert!(%Bus{
      base_kv: 230.0,
      source: "test",
      source_id: "bus-#{System.unique_integer([:positive])}",
      coordinates: %Geo.Point{coordinates: {-122.0, 45.6}, srid: 4326},
      balancing_authority_id: ba.id
    })
  end
end
