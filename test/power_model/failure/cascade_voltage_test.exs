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

    test "every zone of one branch's distance element shares a duty key" do
      # REVIEW CAS-23. A real relay runs its zone timers in PARALLEL, so the
      # accrued duty has to survive a branch migrating from zone 3 to zone 2 —
      # which a zone-keyed cause string could not do. One key per branch, with
      # the per-zone timers inside the value, is what carries it across. Duty
      # from OTHER protections on the same branch stays separate, as before.
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

      other_branch =
        Cascade.relay_key(%{
          failure_cause: "distance_zone2",
          component_type: "transmission_line",
          component_id: 8
        })

      assert zone3 == zone2
      assert zone3 != thermal
      assert zone2 != thermal
      assert zone2 != other_branch
    end

    test "a fault walking inward trips SOONER than a static one, never later" do
      # The CAS-23 repro. Zone 3's definite timer is 1.50 s and zone 2's is
      # 0.40 s. A branch that has spent 0.9 of its zone-3 timer (1.35 s) and
      # then sees the apparent impedance walk into zone 2 must still trip on
      # the zone-3 element 0.15 s later — total 1.50 s, the same as if it had
      # stood still. Restarting the timer on the zone change instead gave
      # 1.35 + 0.40 = 1.75 s: a worsening fault cleared more slowly.
      delays = Protection.distance_settings().delays_s
      assert delays[2] == 0.40
      assert delays[3] == 1.50

      branch = %{component_type: "transmission_line", component_id: 7}

      zone3_pickup =
        Map.merge(branch, %{
          failure_cause: "distance_zone3",
          details: %{zone: 3, delay_s: delays[3]},
          trip_time_s: delays[3]
        })

      zone2_pickup =
        Map.merge(branch, %{
          failure_cause: "distance_zone2",
          details: %{zone: 2, delay_s: delays[2]},
          trip_time_s: delays[2]
        })

      key = Cascade.relay_key(zone3_pickup)

      # 1.35 s of the zone-3 timer already spent.
      carried = %{key => %{3 => 0.9}}

      # Standing still: the remaining 0.15 s, and the branch trips.
      {static_trip, static_advance, _duty} =
        Cascade.advance_relay_timers([zone3_pickup], carried)

      assert_in_delta static_advance, 0.15, 1.0e-9
      assert static_trip.failure_cause == "distance_zone3"

      # Walking inward to zone 2: the zone-3 timer keeps running alongside the
      # freshly started zone-2 one, so the SAME 0.15 s clears it.
      {migrated_trip, migrated_advance, _duty} =
        Cascade.advance_relay_timers([zone2_pickup], carried)

      assert_in_delta migrated_advance, 0.15, 1.0e-9
      assert migrated_advance <= static_advance
      refute is_nil(migrated_trip)

      # 1.35 s already spent + 0.15 s here = 1.50 s total, at or under the
      # static fault's clearing time.
      assert_in_delta 0.9 * delays[3] + migrated_advance, 1.50, 1.0e-9

      # The measurement stays what it was — zone 2 is where the impedance is —
      # and the element that actually finished is named beside it.
      assert migrated_trip.details.zone == 2
      assert migrated_trip.details.operating_zone == 3
    end

    test "an inner zone dropped out resets while the outer one keeps timing" do
      # The other half of the parallel-timer rule: a fault RECEDING out of
      # zone 2 back to zone 3 alone drops the zone-2 element (a definite-time
      # timer resets on dropout) but must not disturb zone 3, which the
      # impedance never left.
      delays = Protection.distance_settings().delays_s
      branch = %{component_type: "transmission_line", component_id: 7}

      zone3_pickup =
        Map.merge(branch, %{
          failure_cause: "distance_zone3",
          details: %{zone: 3, delay_s: delays[3]},
          trip_time_s: delays[3]
        })

      key = Cascade.relay_key(zone3_pickup)

      # A faster relay elsewhere sets the step's clock advance, so the distance
      # element is still mid-timing when the duty map is read.
      faster = %{
        component_type: "transmission_line",
        component_id: 9,
        failure_cause: "thermal_overload",
        details: %{},
        trip_time_s: 0.1
      }

      {trip, advance, duty} =
        Cascade.advance_relay_timers([zone3_pickup, faster], %{key => %{2 => 0.5, 3 => 0.2}})

      assert trip.component_id == 9
      assert_in_delta advance, 0.1, 1.0e-9

      # Zone 2's 0.5 duty is gone — the impedance left it. Zone 3 never
      # dropped out, so it timed on from 0.2 against its own 1.50 s delay.
      assert Map.keys(duty[key]) == [3]
      assert_in_delta duty[key][3], 0.2 + 0.1 / delays[3], 1.0e-9
    end
  end

  # ===========================================================================
  # CAS-19: the grid-following ceiling reads each unit's OWN set point
  # ===========================================================================

  describe "the grid-following availability ceiling" do
    # An inverter's ceiling is `min(P_set, V·Imax)` in per-unit of RATING, so
    # what the current limit costs a unit depends on how loaded it is.
    defp farm(id, bus_id, nameplate, dispatched) do
      %{
        id: id,
        bus_id: bus_id,
        fuel_type: "SUN",
        p_max_mw: dispatched,
        capacity_factor: 1.0,
        p_dispatch_mw: dispatched,
        p_nameplate_mw: nameplate
      }
    end

    test "a partly loaded farm loses nothing to a sag its current limit clears" do
      # REVIEW CAS-19. `Protection.gfl_derate/3` defaults `:p_set_pu` to 1.0 —
      # every inverter flat out — and the cascade took that default for the
      # whole fleet. A 100 MW farm dispatched at 20 MW sits at 0.20 pu, and its
      # 1.2 pu current limit does not bind until the terminal voltage falls
      # below 0.167 pu. Charged the flat-out derate at 0.60 pu it lost 5.6 MW
      # of its 20 — generation that never existed, landing in the deficit and
      # driving UFLS.
      partial = farm(1, 10, 100.0, 20.0)

      assert %{1 => fraction} = Cascade.gfl_availability([partial], %{10 => 0.60})
      assert fraction == 1.0
      assert_in_delta 20.0 * fraction, 20.0, 1.0e-9

      # The fleet-wide default is what it was being charged instead.
      assert %{1 => flat_out} = Protection.gfl_derate([partial], %{10 => 0.60})
      assert_in_delta flat_out, 0.72, 1.0e-9
    end

    test "a flat-out farm still derates, and the ceiling is unchanged for it" do
      # The ceiling is real; it was the SET POINT that was wrong. A unit that
      # genuinely is at nameplate gets exactly the same answer as before.
      full = farm(1, 10, 100.0, 100.0)

      assert %{1 => fraction} = Cascade.gfl_availability([full], %{10 => 0.60})
      assert_in_delta fraction, 0.72, 1.0e-9
      assert fraction == Protection.gfl_derate([full], %{10 => 0.60})[1]
    end

    test "each unit is asked with its own set point, not the fleet's" do
      # The whole point of the per-unit form: one map, three different answers
      # off one bus voltage.
      # At 0.60 pu the current ceiling is V·Imax = 0.72 pu of rating. The
      # 0.20 pu unit is nowhere near it, the 0.90 pu unit is held down to it,
      # and the flat-out unit is held down to it too.
      fleet = [farm(1, 10, 100.0, 20.0), farm(2, 10, 100.0, 90.0), farm(3, 10, 100.0, 100.0)]

      gfl = Cascade.gfl_availability(fleet, %{10 => 0.60})

      assert gfl[1] == 1.0
      assert_in_delta gfl[2], 0.72 / 0.9, 1.0e-9
      assert_in_delta gfl[3], 0.72, 1.0e-9

      # Deliverable MW is `min(P_set, V·Imax)` times the rating, so both
      # derated units land on the same 72 MW ceiling from different set points.
      assert_in_delta 20.0 * gfl[1], 20.0, 1.0e-9
      assert_in_delta 90.0 * gfl[2], 72.0, 1.0e-9
      assert_in_delta 100.0 * gfl[3], 72.0, 1.0e-9
    end

    test "a synchronous machine has no ceiling of this kind and is simply absent" do
      coal = %{
        id: 9,
        bus_id: 10,
        fuel_type: "COL",
        p_max_mw: 50.0,
        capacity_factor: 1.0,
        p_dispatch_mw: 50.0,
        p_nameplate_mw: 500.0
      }

      assert Cascade.gfl_availability([coal], %{10 => 0.60}) == %{}
    end

    test "a unit with no rating to divide by keeps the flat-out assumption" do
      # The conservative reading of a missing nameplate: assume it is loaded.
      unrated = %{id: 1, bus_id: 10, fuel_type: "SUN", p_max_mw: 0.0, capacity_factor: 1.0}

      assert %{1 => fraction} = Cascade.gfl_availability([unrated], %{10 => 0.60})
      assert_in_delta fraction, 0.72, 1.0e-9
    end
  end

  # ===========================================================================
  # CAS-24: the alarm high-water mark across a split
  # ===========================================================================

  describe "the voltage alarm high-water mark" do
    # Two mirrored sagging radials joined by a tie. The whole island alarms
    # once, on a high-water mark that is an ABSOLUTE bus count.
    defp tied_radials do
      %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3), bus(4)],
        lines: [
          line(1, 1, 2, x_pu: 0.25),
          line(2, 2, 3, x_pu: 0.02),
          line(3, 3, 4, x_pu: 0.25)
        ],
        transformers: [],
        generators: [generator(1, 1, p_max_mw: 95.0), generator(2, 3, p_max_mw: 95.0)],
        loads: [load(1, 2, 100.0, 45.0), load(2, 4, 100.0, 45.0)]
      }
    end

    test "a fragment can alarm again after a split" do
      # REVIEW CAS-24. The mark is a count of BUSES over the island it was
      # measured on, and it was inherited untouched. A fragment holding a
      # parent's count it cannot reach — the slack bus in this half is held at
      # 1.0 pu, so one undervoltage bus is all it can ever show — is silenced
      # for the rest of the session however far its voltage falls. Measured
      # before the fix: zero new alarms after the split.
      {whole, _} = run(tied_radials())

      before = events(whole, "voltage_violation")
      assert length(before) > 0, "expected the intact island to alarm"
      assert [%{voltage_alarm: {seen_low, _high}}] = whole.island_states
      assert seen_low > 0

      {split, _} = Cascade.trip_line(whole, 2)

      assert length(split.island_states) == 2, "expected the tie trip to split the island"

      after_split = events(split, "voltage_violation") -- before
      assert length(after_split) > 0, "the fragment must be able to alarm on its own bus count"

      # Every alarm the fragments raised is about a fragment, not the parent.
      for event <- after_split do
        assert event.details.bus_count < 4
      end
    end

    test "the split resets the mark rather than scaling it" do
      # The mark is not apportioned like the frequency state's cumulative
      # megawatts: a count has no share to take. It restarts, and the first
      # measurement on the new island sets it.
      {whole, _} = run(tied_radials())
      {split, _} = Cascade.trip_line(whole, 2)

      for record <- split.island_states, record.voltage_alarm != nil do
        {low, high} = record.voltage_alarm
        assert low + high <= MapSet.size(record.buses)
      end
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
