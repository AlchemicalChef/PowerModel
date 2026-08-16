defmodule PowerModel.Failure.CascadeVoltageTest do
  @moduledoc """
  The voltage chain wired into the cascade loop (ROADMAP Phase 4 item 20).

  Every test here turns on one contract that only exists once an island has a
  real AC solution: the QSS-AC pass itself, UVLS, IEEE 1547 rooftop voltage
  trips, PRC-024 generator ride-through, and the ordering and double-count
  guards between them.

  ## How these fixtures reach the voltage layer at all

  Two facts shape every fixture below.

    * An island's voltage layer is the AC solution from the END of the
      PREVIOUS segment, so nothing voltage-driven can happen in step 1. Each
      fixture therefore has to survive into step 2.
    * The voltage timers integrate `simulated_time`, and a cascade step only
      advances the clock when a relay finishes timing or an island's frequency
      trajectory runs. A quiet island advances 0 s and no definite-time relay
      ever fires, however low its voltage sits.

  Both are satisfied the same way: the island carries a small SUSTAINED
  generation shortfall. That drives a frequency trajectory, which advances the
  clock by its settling time, which is the `dt` the voltage timers then get.
  """

  use ExUnit.Case, async: true

  alias PowerModel.Failure.{Cascade, LoadShedding, Protection, Reserves}
  alias PowerModel.Grid.BtmSolar

  # ---------------------------------------------------------------------------
  # Fixture
  # ---------------------------------------------------------------------------

  defp bus(id, opts \\ []) do
    %{
      id: id,
      bus_type: Keyword.get(opts, :bus_type, 1),
      base_kv: 138.0,
      vm_pu: 1.0,
      va_rad: 0.0
    }
  end

  defp line(id, from, to, opts) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      voltage_kv: 138.0,
      r_pu: Keyword.get(opts, :r_pu, 0.02),
      x_pu: Keyword.get(opts, :x_pu, 0.25),
      b_pu: 0.0,
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 500.0)
    }
  end

  defp generator(id, bus_id, opts) do
    %{
      id: id,
      bus_id: bus_id,
      fuel_type: Keyword.get(opts, :fuel_type, "NG"),
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      p_nameplate_mw: Keyword.get(opts, :p_max_mw, 100.0),
      capacity_factor: 1.0,
      q_max_mvar: Keyword.get(opts, :q_max_mvar, 200.0),
      q_min_mvar: Keyword.get(opts, :q_min_mvar, -200.0)
    }
  end

  defp load(id, bus_id, p_mw, q_mvar) do
    %{id: id, bus_id: bus_id, p_mw: p_mw, q_mvar: q_mvar}
  end

  defp btm(bus_id, output_mw, legacy_fraction) do
    %{
      bus_id: bus_id,
      sector: "residential",
      output_mw: output_mw,
      legacy_fraction: legacy_fraction
    }
  end

  # A two-bus radial deliberately sized so the far bus sags into the UVLS and
  # 1547 bands: 0.25 pu of series reactance carrying ~0.45 pu of reactive
  # demand is a ~0.12 pu drop, which no amount of slack-bus support fixes
  # because the drop is across the line, not at the source.
  #
  # `shortfall_mw` is what the generator CANNOT cover, and it is the fixture's
  # clock: the island answers it with a frequency trajectory whose settling
  # time becomes the `dt` every voltage timer integrates.
  defp sagging_snapshot(opts \\ []) do
    load_mw = Keyword.get(opts, :load_mw, 100.0)
    q_mvar = Keyword.get(opts, :q_mvar, 45.0)
    shortfall = Keyword.get(opts, :shortfall_mw, 5.0)
    btm_entries = Keyword.get(opts, :btm, [])

    %{
      buses: [bus(1, bus_type: 3), bus(2)],
      lines: [line(1, 1, 2, x_pu: Keyword.get(opts, :x_pu, 0.25))],
      transformers: [],
      generators: [generator(1, 1, p_max_mw: load_mw - shortfall)],
      loads: [load(1, 2, load_mw, q_mvar)],
      btm_solar: btm_entries
    }
  end

  # Same radial, loaded PAST the nose: FDPF cannot converge, so the island runs
  # DC-only. This is the COMMON case at real demand (REVIEW LIN-13 measured
  # that no interconnection has an AC solution there), and it is what the
  # honest-degradation rule has to hold for.
  defp infeasible_snapshot do
    %{
      sagging_snapshot(load_mw: 140.0, q_mvar: 70.0, shortfall_mw: 5.0)
      | generators: [
          generator(1, 1, p_max_mw: 135.0),
          generator(2, 2, p_max_mw: 1.0, q_max_mvar: 0.5, q_min_mvar: -0.5)
        ]
    }
  end

  # The same radial with one small, tight-Q machine AT the sagging bus. It hits
  # its reactive limit, switches PV to PQ, and floats down with the bus — which
  # is the only way a generator terminal voltage ends up inside the PRC-024
  # envelope at all, since a PV bus is held at its setpoint by construction.
  defp sagging_generator_snapshot do
    %{
      sagging_snapshot(load_mw: 100.0, q_mvar: 45.0)
      | generators: [
          generator(1, 1, p_max_mw: 94.0),
          generator(2, 2, p_max_mw: 1.0, q_max_mvar: 0.5, q_min_mvar: -0.5)
        ]
    }
  end

  defp run(snapshot) do
    state = Cascade.init(snapshot, 100.0)
    Cascade.run_cascade(state)
  end

  defp causes(state), do: Enum.frequencies_by(state.events, & &1.failure_cause)

  defp events(state, cause), do: Enum.filter(state.events, &(&1.failure_cause == cause))

  defp shed_mw(state, cause) do
    state |> events(cause) |> Enum.map(&Map.get(&1.details, :shed_mw, 0.0)) |> Enum.sum()
  end

  defp conservation_residual(state) do
    b = Cascade.balance(state)
    b.served_load_mw + b.shed_load_mw + b.blackout_load_mw - b.original_load_mw - b.btm_tripped_mw
  end

  # ===========================================================================
  # The QSS-AC pass itself
  # ===========================================================================

  describe "the QSS-AC pass" do
    test "an island that solves AC carries a voltage layer and is counted" do
      {state, _steps} = run(sagging_snapshot())

      assert state.voltage_layer.islands_ac > 0
      assert state.voltage_layer.ac_solves == state.voltage_layer.islands_ac

      layer = Enum.find(state.island_states, & &1.ac_voltage)
      assert layer, "expected at least one island to end the run with a voltage layer"

      # A real AC profile, not the DC solve's flat 1.0 pu.
      assert Enum.min(Map.values(layer.ac_voltage.vm_by_bus)) < 0.95
    end

    test "the counters partition every island-solve into AC or DC-only" do
      {state, _steps} = run(sagging_snapshot())
      v = state.voltage_layer

      assert v.islands_ac + v.islands_dc_only ==
               v.ac_solves + v.ac_diverged + v.ac_skipped
    end

    test "an island that cannot solve AC runs DC-only and no voltage mechanism fires" do
      # The honest-degradation rule, and the case that matters most: at real
      # demand this is what EVERY interconnection does. The island still gets
      # its DC solve and its whole frequency chain; what it does not get is a
      # voltage layer, and nothing downstream is handed a flat 1.0 pu instead.
      {state, _steps} = run(infeasible_snapshot())

      assert state.voltage_layer.islands_ac == 0
      assert state.voltage_layer.islands_dc_only > 0
      assert state.voltage_layer.ac_diverged > 0

      assert Enum.all?(state.island_states, &is_nil(&1.ac_voltage))

      c = causes(state)
      assert c["uvls_shed"] == nil
      assert c["btm_voltage_trip"] == nil
      assert c["undervoltage_trip"] == nil
      assert c["voltage_violation"] == nil

      # The frequency chain is untouched by the AC failure.
      assert c["ufls_shed"] != nil
      assert_in_delta conservation_residual(state), 0.0, 1.0e-6
    end

    test "a diverged island is not re-solved every step while nothing about it moves" do
      {state, _steps} = run(infeasible_snapshot())

      assert state.voltage_layer.ac_skipped > 0,
             "an island with no AC solution must stop being retried once its " <>
               "bus count, branch count and load have all stopped moving"
    end
  end

  # ===========================================================================
  # UVLS
  # ===========================================================================

  describe "UVLS in the cascade loop" do
    test "a sagging bus sheds through the staged program" do
      {state, _steps} = run(sagging_snapshot())

      uvls = events(state, "uvls_shed")
      assert uvls != [], "expected UVLS to fire on a bus below 0.92 pu"

      detail = hd(uvls).details
      assert detail.vm_pu < 0.92
      assert detail.stages != []
      assert detail.shed_mw > 0.0
    end

    test "UVLS and UFLS both shed, and the conservation identity carries both" do
      {state, _steps} = run(sagging_snapshot())

      uvls = shed_mw(state, "uvls_shed")
      frequency = shed_mw(state, "ufls_shed") + shed_mw(state, "load_shed")

      assert uvls > 0.0, "fixture must exercise UVLS"
      assert frequency > 0.0, "fixture must exercise the frequency-driven tier too"

      balance = Cascade.balance(state)
      assert_in_delta balance.shed_load_mw, uvls + frequency, 1.0e-6
      assert_in_delta conservation_residual(state), 0.0, 1.0e-6
    end

    test "UVLS never runs on an island without an AC solution" do
      {state, _steps} = run(infeasible_snapshot())

      assert events(state, "uvls_shed") == []
    end
  end

  # ===========================================================================
  # IEEE 1547 rooftop voltage trips, and the ordering they must keep
  # ===========================================================================

  describe "behind-the-meter voltage trips" do
    test "rooftop trips on voltage and the gross-up lands as load" do
      snapshot = sagging_snapshot(btm: [btm(2, 10.0, 0.3)])
      {state, _steps} = run(snapshot)

      trips = events(state, "btm_voltage_trip")
      assert trips != [], "expected the 1547 voltage elements to operate at this sag"

      assert state.btm_tripped_mw > 0.0
      assert_in_delta state.btm_trip_breakdown.total_mw, state.btm_tripped_mw, 1.0e-6
      assert state.btm_trip_breakdown.voltage_mw > 0.0
      assert BtmSolar.trip_breakdown_balanced?(state.btm_trip_breakdown)

      # The gross-up is a source term in the identity, never a sink.
      assert_in_delta conservation_residual(state), 0.0, 1.0e-6
    end

    test "BTM is grossed up BEFORE UVLS, so UVLS sheds a fraction of demand that exists" do
      # The ordering is observable in the arithmetic. UVLS sheds a fraction of
      # each load's CURRENT p_mw; if the rooftop gross-up ran after it, the
      # same stage would shed the same fraction of a smaller number. Running
      # the fixture with and without rooftop therefore separates the two
      # orderings by the shed MW alone.
      {without, _} = run(sagging_snapshot())
      {with_btm, _} = run(sagging_snapshot(btm: [btm(2, 10.0, 0.3)]))

      bare = shed_mw(without, "uvls_shed")
      grossed = shed_mw(with_btm, "uvls_shed")

      assert with_btm.btm_tripped_mw > 0.0

      assert grossed > bare,
             "UVLS shed #{grossed} MW with rooftop vs #{bare} MW without; " <>
               "the gross-up must precede the shed"
    end

    test "one bus, both Blue Cut halves, every megawatt leaving exactly once" do
      # This fixture fires BOTH mechanisms at the SAME bus: the island dips
      # below 59.3 Hz (taking the legacy fleet on frequency) and the bus sits
      # deep in the 1547 voltage band (taking what is left on voltage). The
      # split is exact and it is the whole guard:
      #
      #   * frequency takes the legacy share and ONLY the legacy share — the
      #     59.3 Hz must-trip does not apply to 1547-2018 inverters;
      #   * voltage then takes the modern share and NOT the legacy share,
      #     because `mark_tripped/3` wrote the frequency trip into its timers
      #     and `btm_tripped_buses` zeroed the legacy megawatts it was offered.
      fleet = 10.0
      legacy_fraction = 0.3
      legacy = fleet * legacy_fraction
      modern = fleet - legacy

      {state, _steps} = run(sagging_snapshot(btm: [btm(2, fleet, legacy_fraction)]))

      assert events(state, "btm_trip") != [], "the frequency half must fire"
      assert events(state, "btm_voltage_trip") != [], "the voltage half must fire"

      breakdown = state.btm_trip_breakdown
      assert BtmSolar.trip_breakdown_balanced?(breakdown)
      assert_in_delta breakdown.frequency_mw, legacy, 1.0e-6
      assert_in_delta breakdown.voltage_mw, modern, 1.0e-6
      assert_in_delta breakdown.total_mw, fleet, 1.0e-6
      assert_in_delta state.btm_tripped_mw, fleet, 1.0e-6
    end
  end

  # ===========================================================================
  # PRC-024 generator voltage ride-through
  # ===========================================================================

  describe "generator voltage trips" do
    test "a generator held below its ride-through envelope trips and is removed" do
      {state, _steps} = run(sagging_generator_snapshot())

      trips = events(state, "undervoltage_trip")
      assert trips != [], "expected PRC-024 to operate on a machine floating at ~0.8 pu"

      trip = hd(trips)
      detail = trip.details

      assert trip.component_id == 2, "the sagging bus's machine is the one at risk"
      assert detail.vm_pu < 0.9
      assert detail.band_pu == 0.9
      assert detail.time_in_band_s > detail.allowance_s

      # The trip is a real generation loss, not just an event.
      assert MapSet.member?(state.tripped_generators, 2)
      assert Map.get(state.dispatch, 2) == 0.0

      # The island-level aggregate rides alongside the individual trips, the
      # same way the frequency side's does.
      assert events(state, "generator_voltage_trips") != []

      assert_in_delta conservation_residual(state), 0.0, 1.0e-6
    end

    test "PRC-024 voltage timers are cumulative and survive an island split by key" do
      # The split half of the contract, exercised directly: the state is keyed
      # by generator and a plain key filter conserves every timer.
      {trips, state} =
        Protection.generator_voltage_trips(
          [
            %{id: 1, bus_id: 1, p_max_mw: 10.0, capacity_factor: 1.0},
            %{id: 2, bus_id: 2, p_max_mw: 10.0, capacity_factor: 1.0}
          ],
          %{1 => 0.80, 2 => 0.80},
          nil,
          1.0
        )

      assert trips == []
      kept = Protection.split_voltage_state(state, [1])

      assert Map.keys(kept.generators) == [1]
      assert kept.generators[1].lv == state.generators[1].lv
    end
  end

  # ===========================================================================
  # Distance relays versus the zone-3 heuristic
  # ===========================================================================

  describe "distance relays" do
    test "the deterministic characteristic and the heuristic never both fire" do
      # `check_zone3_encroachment/6` is probabilistic and needs no impedance;
      # `distance_relay_trips/2` is the real mho characteristic and needs one.
      # Two models of the same relay running together would double the zone-3
      # trip rate on exactly the branches this phase exists to get right, so
      # each island gets exactly one of them — and which one is decided by
      # whether it has an AC solution.
      {ac_run, _} = run(sagging_snapshot())
      {dc_run, _} = run(infeasible_snapshot())

      assert ac_run.voltage_layer.islands_dc_only == 0
      assert dc_run.voltage_layer.islands_ac == 0

      assert causes(ac_run)["zone3_relay"] == nil,
             "the heuristic must be skipped wherever the characteristic can run"

      for zone <- ~w(distance_zone1 distance_zone2 distance_zone3) do
        assert causes(dc_run)[zone] == nil,
               "the characteristic cannot run without an impedance to measure"
      end
    end

    test "distance pickups carry zone-keyed causes so relay duty cannot cross zones" do
      # Relay duty is keyed {cause, type, id}. A branch migrating from zone 3
      # to zone 2 must start a fresh timer rather than inherit the slower
      # zone's accumulated duty, and the zone-keyed cause string is what
      # guarantees it.
      zone3 =
        Cascade.relay_key(%{
          failure_cause: "distance_zone3",
          component_type: "transmission_line",
          component_id: 7
        })

      zone2 =
        Cascade.relay_key(%{
          failure_cause: "distance_zone2",
          component_type: "transmission_line",
          component_id: 7
        })

      thermal =
        Cascade.relay_key(%{
          failure_cause: "thermal_overload",
          component_type: "transmission_line",
          component_id: 7
        })

      assert zone3 != zone2
      assert zone3 != thermal
      assert zone2 != thermal
    end
  end

  # ===========================================================================
  # Conductor thermal: the slow timescale
  # ===========================================================================

  describe "conductor thermal" do
    test "temperature is tracked per branch on the cascade clock" do
      {state, _steps} = run(sagging_snapshot())

      assert map_size(state.conductor_state) > 0

      Enum.each(state.conductor_state, fn {_key, thermal} ->
        assert thermal.temp_c >= 40.0
        assert thermal.elapsed_s >= 0.0
      end)
    end

    test "the thermal model reads RATE A loading, not the rate-C relay basis" do
      # Confusing the two understates temperature by 1.35^2. The two bases are
      # a fixed multiple apart, so the check is arithmetic rather than
      # scenario-dependent.
      flow = %{loading_pct: 150.0, trip_loading_pct: 111.1, p_flow_mw: 150.0}

      rate_a = Protection.conductor_steady_state_temp_c(flow.loading_pct / 100.0)
      rate_c = Protection.conductor_steady_state_temp_c(Cascade.trip_loading_pct(flow) / 100.0)

      assert rate_a > rate_c
      assert_in_delta (rate_a - 40.0) / (rate_c - 40.0), 1.35 * 1.35, 0.02
    end

    test "a branch already cooking in the base case is trip-immune" do
      # The thermal curve cooks from about 131% of rate A; `base_overloaded` is
      # on the rate-C basis and only starts at 135%. A branch in that band is a
      # model artifact and must not trip at t = 0 on impedance error.
      assert Protection.conductor_trip_time_s(%{temp_c: 40.0}, 1.32) != :infinity
      assert Protection.conductor_trip_time_s(%{temp_c: 40.0}, 1.25) == :infinity
    end
  end

  # ===========================================================================
  # AGC and the reserve tiers
  # ===========================================================================

  describe "AGC owns the secondary tier" do
    test "the two secondary tiers are alternatives, never addends" do
      # The contract the cascade's two `Reserves.allocate/4` call sites rest on.
      # `live_island` passes AGC's increment; `redispatch/4` passes an EMPTY
      # increment, which is how it is told "tertiary only". Both draw from one
      # unit's one headroom, and neither may exceed it.
      unit = %{id: 1, fuel_type: "NG", p_dispatch_mw: 50.0, p_nameplate_mw: 100.0}
      headroom = 50.0

      clock = Reserves.allocate([unit], 40.0, 600.0)
      agc = Reserves.allocate([unit], 40.0, 600.0, secondary: {:agc, %{1 => 12.0}})
      tertiary_only = Reserves.allocate([unit], 40.0, 600.0, secondary: {:agc, %{}})

      assert clock.secondary_mw > 0.0, "the open-loop tier still works when selected"
      assert agc.secondary_mw <= 12.0, "AGC's increment is the tier's whole capability"

      assert tertiary_only.secondary_mw == 0.0,
             "an empty AGC increment must leave the secondary tier at zero, " <>
               "which is what keeps redispatch/4 out of AGC's tier"

      for alloc <- [clock, agc, tertiary_only] do
        assert alloc.secondary_mw + alloc.tertiary_mw <= headroom + 1.0e-9
      end
    end

    test "no unit ends a cascade dispatched above its nameplate" do
      # The same no-double-draw property, observed end to end: if the
      # AGC-fed secondary tier and the clock-fed tertiary tier ever both
      # answered the same deficit, a unit would be raised twice out of one
      # headroom and finish above its rating.
      snapshot = %{
        sagging_snapshot(load_mw: 150.0, q_mvar: 60.0, shortfall_mw: 0.0)
        | generators: [
            generator(1, 1, p_max_mw: 200.0, q_max_mvar: 300.0),
            generator(2, 1, p_max_mw: 60.0)
          ]
      }

      state = Cascade.init(snapshot, 100.0)
      {state, _steps} = Cascade.trip_generator(state, 2)

      nameplate = Map.new(snapshot.generators, &{&1.id, &1.p_max_mw})

      Enum.each(state.dispatch, fn {id, mw} ->
        cap = Map.fetch!(nameplate, id)

        assert mw <= cap + 1.0e-6,
               "generator #{id} finished at #{mw} MW against a #{cap} MW nameplate — " <>
                 "the secondary and tertiary tiers double-drew the same headroom"
      end)
    end

    test "each island carries its own AGC controller" do
      {state, _steps} = run(sagging_snapshot(shortfall_mw: 20.0))

      live = Enum.filter(state.island_states, & &1.agc)
      assert live != [], "expected the island to initialise an AGC controller"

      Enum.each(live, fn record ->
        assert record.agc.bias_mw_per_01hz > 0.0
      end)
    end
  end

  # ===========================================================================
  # State threading
  # ===========================================================================

  describe "voltage state across island splits" do
    test "UVLS state splits by key, conserving timers and apportioning the tally" do
      state = %{
        buses: %{
          1 => [%{armed_s: 4.0, tripped: false}],
          2 => [%{armed_s: 7.0, tripped: true}]
        },
        cumulative_shed_mw: 100.0,
        elapsed_s: 12.0
      }

      kept = LoadShedding.split_uvls_state(state, [1])

      assert Map.keys(kept.buses) == [1]
      assert kept.buses[1] == state.buses[1]
      assert_in_delta kept.cumulative_shed_mw, 50.0, 1.0e-9
      assert kept.elapsed_s == 12.0
    end

    test "a fresh UVLS state is returned for an island with no history" do
      assert LoadShedding.split_uvls_state(nil, [1, 2]) == LoadShedding.fresh_uvls_state()
    end

    test "BTM voltage timers split by bus without scaling" do
      {_trips, state} =
        BtmSolar.voltage_trips(
          %{1 => %{legacy_mw: 5.0, modern_mw: 5.0}, 2 => %{legacy_mw: 5.0, modern_mw: 5.0}},
          %{1 => 0.80, 2 => 0.80},
          nil,
          1.0
        )

      kept = BtmSolar.split_voltage_state(state, [2])

      assert Map.keys(kept.buses) == [2]
      assert kept.buses[2] == state.buses[2]
    end
  end
end
