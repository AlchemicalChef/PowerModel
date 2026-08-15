defmodule PowerModel.Solver.FrequencyTest do
  use ExUnit.Case, async: true

  alias PowerModel.Solver.Frequency

  test "under-frequency load shedding arrests the decline" do
    generators = [%{p_max_mw: 1000.0, capacity_factor: 0.9, fuel_type: "wind"}]
    loads = [%{p_mw: 900.0}]

    trajectory = Frequency.simulate(generators, loads, 50.0)
    final_record = List.last(trajectory)

    assert Frequency.nadir(trajectory) > 58.5
    assert final_record.load_shed_mw <= 0.075 * 900.0 + 0.01
  end

  # ROADMAP item 14 rebased this fixture. It used to lose 100 MW — 10% of the
  # machine's nameplate — and assert the governor carried it without reaching
  # the first UFLS stage. Textbook 5% droop does deliver 10% of nameplate, at
  # 0.3 Hz; deliverable primary response does not, and asserting that it did
  # was one of the assertions pinning the measured 5–16x over-delivery. The
  # loss is now 30 MW, which the fleet's duty-scaled droop genuinely covers,
  # and the companion test below pins the old number as the failure it is.
  test "governor response prevents UFLS for a deliverable generation loss" do
    generators = [%{p_max_mw: 1000.0, capacity_factor: 0.5, fuel_type: "gas"}]
    loads = [%{p_mw: 500.0}]

    trajectory = Frequency.simulate(generators, loads, 30.0)

    assert Frequency.nadir(trajectory) > 59.3
    assert Enum.all?(trajectory, &(&1.load_shed_mw == 0.0))
    assert Enum.any?(trajectory, &(&1.gov_response_mw > 0.0))
  end

  test "a loss beyond the fleet's deliverable response reaches UFLS (item 14)" do
    generators = [%{p_max_mw: 1000.0, capacity_factor: 0.5, fuel_type: "gas"}]
    loads = [%{p_mw: 500.0}]

    trajectory = Frequency.simulate(generators, loads, 100.0)

    # 100 MW is 10% of nameplate. Nameplate droop would answer it at 0.3 Hz;
    # a fleet at 40% primary duty cannot, and the island reaches UFLS.
    assert Frequency.nadir(trajectory) < 59.3
    assert List.last(trajectory).load_shed_mw > 0.0

    # ...and the response that IS delivered stays inside the sustained
    # primary-response ceiling: 1.0 %/s over the 10 s nadir window.
    ceiling = Frequency.primary_response_capability_mw(hd(generators))
    assert ceiling == 100.0
    assert Enum.all?(trajectory, &(&1.gov_response_mw <= ceiling + 1.0e-9))
  end

  # Rebased with the test above: the load loss was 200 MW, 40% of the island's
  # demand. Backing down is rate-limited exactly as ramping up is, so a
  # 1,000 MW machine can shed at most its 100 MW primary-response ceiling —
  # against a 200 MW surplus the frequency runs to the 65 Hz clamp, which is
  # physically right (that is an over-frequency event, and PRC-024 over-
  # frequency protection is what answers it) but is not what this test is
  # about. 30 MW keeps the excursion inside the linear band.
  test "governors back down generation after load loss" do
    generators = [%{p_max_mw: 1000.0, capacity_factor: 0.5, fuel_type: "gas"}]
    loads = [%{p_mw: 500.0}]

    trajectory = Frequency.simulate(generators, loads, -30.0)
    settling_frequency = Frequency.settling_frequency(trajectory)

    assert Enum.max_by(trajectory, & &1.frequency).frequency < 65.0
    assert settling_frequency > 60.0
    assert settling_frequency < 65.0
    assert Enum.all?(trajectory, &(&1.gov_response_mw <= 0.0))
    assert Enum.any?(trajectory, &(&1.gov_response_mw < 0.0))
  end

  test "imports contribute no synchronous inertia" do
    {h_sys, s_sys} =
      Frequency.system_inertia([%{p_max_mw: 2000.0, fuel_type: "import"}])

    assert h_sys == 0.0
    assert s_sys == 2000.0
  end

  test "an empty de-energized system does not divide by zero" do
    trajectory = Frequency.simulate([], [], 100.0)

    assert length(trajectory) > 1
    assert Enum.all?(trajectory, &is_float(&1.frequency))
  end

  test "one crossed UFLS threshold sheds exactly one incremental stage" do
    generators = [%{p_max_mw: 1000.0, capacity_factor: 0.9, fuel_type: "wind"}]
    loads = [%{p_mw: 900.0}]

    trajectory = Frequency.simulate(generators, loads, 15.0)
    expected_stage_mw = 0.075 * 900.0

    assert Frequency.nadir(trajectory) < 59.3
    assert Frequency.nadir(trajectory) > 58.9
    assert List.last(trajectory).load_shed_mw == expected_stage_mw
    assert Enum.uniq(Enum.map(trajectory, & &1.load_shed_mw)) == [0.0, expected_stage_mw]
  end

  test "2HS floor is continuous across small fleet changes (ENE-4)" do
    loads = [%{p_mw: 15.0}]
    wind = fn mw -> %{p_max_mw: mw, capacity_factor: 1.0, fuel_type: "wind"} end
    gas = fn mw -> %{p_max_mw: mw, capacity_factor: 1.0, fuel_type: "gas"} end

    # h_sys straddles the old `h_sys < 0.01 -> 0.5` floor: 0.0098 vs 0.0105.
    # Flooring the H constant made these near-identical fleets differ ~47x in
    # first-step RoCoF; flooring the 2HS product keeps them within a few %.
    fleet_a = [gas.(2.8), wind.(997.2)]
    fleet_b = [gas.(3.0), wind.(997.0)]

    first_step_drop = fn fleet ->
      trajectory = Frequency.simulate(fleet, loads, 0.5)
      60.0 - Enum.at(trajectory, 1).frequency
    end

    drop_a = first_step_drop.(fleet_a)
    drop_b = first_step_drop.(fleet_b)

    assert drop_a > 0.0
    assert drop_b > 0.0
    assert max(drop_a, drop_b) / min(drop_a, drop_b) < 2.0
  end

  test "an unstable caller-supplied dt is shrunk to satisfy the Euler bound (ENE-5)" do
    # beta = dt*D*Pload/(2HS) = 5.0 * 1.0 * 900 / 900 = 5.0 > 2: the raw step
    # diverges into a 55/65 Hz square wave (Swing.lean beta_lt_two_iff).
    # simulate/5 must shrink dt so beta <= 1 and integrate stably.
    generators = [%{p_max_mw: 1000.0, capacity_factor: 0.9, fuel_type: "wind"}]
    loads = [%{p_mw: 900.0}]

    trajectory = Frequency.simulate(generators, loads, 3.0, 5.0, 30.0)

    # dt shrunk 5.0 -> 1.0 (beta 5 -> 1): 30 steps, first record at t=1.0
    assert Enum.at(trajectory, 1).time == 1.0
    assert length(trajectory) == 31

    # Stable decay to the ~59.8 Hz equilibrium: no oscillation, no UFLS
    assert Enum.all?(trajectory, &(&1.frequency >= 59.5))
    assert List.last(trajectory).load_shed_mw == 0.0
    refute Frequency.collapsed?(trajectory)
  end

  test "clamp-touching trajectories are flagged collapsed (ENE-5)" do
    loads = [%{p_mw: 100.0}]

    trajectory = Frequency.simulate([], loads, 100.0)

    assert Frequency.collapsed?(trajectory)
    assert Frequency.nadir(trajectory) == 55.0
    refute hd(trajectory).collapsed
    assert List.last(trajectory).collapsed
  end

  test "duration shorter than one time step returns only the initial record (ENE-11)" do
    generators = [%{p_max_mw: 100.0, capacity_factor: 0.5, fuel_type: "gas"}]
    loads = [%{p_mw: 50.0}]

    assert [record] = Frequency.simulate(generators, loads, 10.0, 0.1, 0.04)
    assert record.time == 0.0
    assert record.frequency == 60.0
    refute record.collapsed
  end

  test "UFLS stages shed a fraction of the currently-connected load (ENE-6)" do
    # Slow nuclear fleet with a deep deficit: stages trip sequentially, so
    # stage 2 must shed 7.5% of (900 - 67.5), not of the original 900.
    generators = [%{p_max_mw: 1000.0, capacity_factor: 0.9, fuel_type: "NUC"}]
    loads = [%{p_mw: 900.0}]

    trajectory = Frequency.simulate(generators, loads, 200.0)

    shed_values = trajectory |> Enum.map(& &1.load_shed_mw) |> Enum.uniq()

    assert [zero, first, second | _] = shed_values
    assert zero == 0.0
    assert_in_delta first, 0.075 * 900.0, 0.01
    assert_in_delta second - first, 0.075 * (900.0 - 67.5), 0.02
  end

  test "EIA fuel codes map to their fuel classes (PLT-3)" do
    h = fn code ->
      {h_sys, _s_sys} = Frequency.system_inertia([%{p_max_mw: 100.0, fuel_type: code}])
      h_sys
    end

    for code <- ["SUB", "LIG", "RC", "WC", "BIT"] do
      assert h.(code) == 4.0, "#{code} should carry coal inertia"
    end

    assert h.("NUC") == 6.0
    assert h.("NG") == 3.5
    assert h.("WAT") == 3.0
    assert h.("WND") == 0.0
    assert h.("SUN") == 0.0
    # battery storage: inverter-based, zero inertia
    assert h.("MWH") == 0.0
    # oil-fired steam units
    assert h.("DFO") == 4.0
    assert h.("RFO") == 4.0
    assert h.("GEO") == 3.5
  end

  test "MWH storage provides no governor response (PLT-3)" do
    generators = [%{p_max_mw: 100.0, capacity_factor: 0.5, fuel_type: "MWH"}]
    loads = [%{p_mw: 50.0}]

    trajectory = Frequency.simulate(generators, loads, 10.0)

    assert Enum.all?(trajectory, &(&1.gov_response_mw == 0.0))
  end

  # Rebased: the original read step 2 (t = 0.2 s) of a 5 MW disturbance, where
  # the deadband and the 0.10 %/s geothermal delivery rate now put the
  # geothermal response below the record's 2-decimal rounding — it reads
  # exactly 0.0, not because nothing happened but because 0.00028 MW rounds
  # there. A 20 MW disturbance read at 1 s keeps both responses measurable and
  # tests the same thing: geothermal answers like a steam plant, not a CT.
  test "GEO responds with a slow steam governor, not a fast gas turbine (PLT-3)" do
    loads = [%{p_mw: 50.0}]

    gov_at_1s = fn fuel ->
      [%{p_max_mw: 100.0, capacity_factor: 0.5, fuel_type: fuel}]
      |> Frequency.simulate(loads, 20.0)
      |> Enum.find(&(&1.time == 1.0))
      |> Map.get(:gov_response_mw)
    end

    geo = gov_at_1s.("GEO")
    gas = gov_at_1s.("NG")

    assert geo > 0.0
    assert gas > geo * 5.0
  end

  # ===========================================================================
  # Machine constants (ROADMAP item 14)
  # ===========================================================================

  describe "machine constants table" do
    test "every fuel class carries a complete row" do
      for {class, row} <- Frequency.machine_constants() do
        assert is_float(row.inertia_h_s), "#{class} inertia"
        assert is_float(row.gov_time_s), "#{class} gov time"
        assert is_boolean(row.governor_duty?), "#{class} duty flag"
        assert row.primary_duty_fraction >= 0.0 and row.primary_duty_fraction <= 1.0
        assert row.primary_response_rate_pct_per_s >= 0.0
        assert row.secondary_ramp_pct_per_min >= 0.0
      end
    end

    test "classes with no governor duty carry no primary response rate" do
      for {class, row} <- Frequency.machine_constants(), not row.governor_duty? do
        assert row.primary_response_rate_pct_per_s == 0.0 or class == "storage",
               "#{class} has no governor duty but a nonzero primary rate"
      end
    end

    test "primary response is faster than the sustained secondary ramp" do
      # A machine answering a governor draws on stored steam or water; it can
      # put MW on the system faster than its boiler or reservoir can sustain.
      for {class, row} <- Frequency.machine_constants(), row.governor_duty? do
        primary_pct_per_min = row.primary_response_rate_pct_per_s * 60.0

        assert primary_pct_per_min > row.secondary_ramp_pct_per_min,
               "#{class}: primary #{primary_pct_per_min} %/min is not above secondary #{row.secondary_ramp_pct_per_min} %/min"
      end
    end

    test "accessors scale the table by nameplate, not by dispatch" do
      gen = %{p_max_mw: 500.0, capacity_factor: 0.5, fuel_type: "NG"}

      # gas: 1.00 %/s, 8 %/min
      assert_in_delta Frequency.primary_response_rate_mw_per_s(gen), 5.0, 1.0e-9
      assert_in_delta Frequency.secondary_ramp_mw_per_min(gen), 40.0, 1.0e-9

      # 5 MW/s over the 10 s nadir window is 50 MW, well inside the 250 MW of
      # headroom this unit has, so capability is rate-limited not headroom-
      # limited.
      assert_in_delta Frequency.primary_response_capability_mw(gen), 50.0, 1.0e-9
    end

    test "primary capability is capped by headroom when the unit is nearly loaded" do
      gen = %{p_max_mw: 500.0, capacity_factor: 0.98, fuel_type: "NG"}

      assert_in_delta Frequency.primary_response_capability_mw(gen), 10.0, 1.0e-9
    end

    test "capability reads the cascade's solver-shaped generator maps" do
      # The cascade hands the solver p_max_mw = dispatched MW with the physical
      # values riding along; capability must read those, not the reshaped ones.
      gen = %{
        p_max_mw: 490.0,
        capacity_factor: 1.0,
        fuel_type: "NG",
        p_dispatch_mw: 490.0,
        p_nameplate_mw: 500.0
      }

      assert_in_delta Frequency.primary_response_rate_mw_per_s(gen), 5.0, 1.0e-9
      assert_in_delta Frequency.primary_response_capability_mw(gen), 10.0, 1.0e-9
    end
  end

  describe "governor duty (ROADMAP item 14)" do
    test "nuclear provides no primary response" do
      refute Frequency.governor_duty?(%{p_max_mw: 1000.0, fuel_type: "NUC"})

      generators = [%{p_max_mw: 1000.0, capacity_factor: 0.6, fuel_type: "NUC"}]
      trajectory = Frequency.simulate(generators, [%{p_mw: 600.0}], 20.0)

      assert Enum.all?(trajectory, &(&1.gov_response_mw == 0.0))
      assert Frequency.primary_response_capability_mw(hd(generators)) == 0.0
    end

    test "wind, solar, imports and biogas engines carry no duty either" do
      for code <- ["WND", "SUN", "import", "LFG", "OBG"] do
        refute Frequency.governor_duty?(%{p_max_mw: 100.0, fuel_type: code}),
               "#{code} should not be on primary frequency control"
      end
    end

    test "batteries are off duty until the fast-frequency-response hook is armed" do
      plain = %{p_max_mw: 100.0, capacity_factor: 0.2, fuel_type: "MWH"}
      armed = Map.put(plain, :ffr_enabled, true)

      refute Frequency.governor_duty?(plain)
      refute Frequency.fast_frequency_response?(plain)
      assert Frequency.primary_response_capability_mw(plain) == 0.0

      assert Frequency.governor_duty?(armed)
      assert Frequency.fast_frequency_response?(armed)
      # 10 %/s over the window is the whole machine; headroom (80 MW) binds.
      assert_in_delta Frequency.primary_response_capability_mw(armed), 80.0, 1.0e-9

      loads = [%{p_mw: 100.0}]
      assert Enum.all?(Frequency.simulate([plain], loads, 10.0), &(&1.gov_response_mw == 0.0))
      assert Enum.any?(Frequency.simulate([armed], loads, 10.0), &(&1.gov_response_mw > 0.0))
    end
  end

  describe "deliverable primary response (ROADMAP item 14)" do
    test "the delivery rate limits how fast governor MW can arrive" do
      # Coal at 0.20 %/s: a 1,000 MW unit may add at most 2 MW per second,
      # whatever droop demands. A deep disturbance makes the demand enormous,
      # so the rate is what the early trajectory follows.
      generators = [%{p_max_mw: 1000.0, capacity_factor: 0.4, fuel_type: "BIT"}]
      trajectory = Frequency.simulate(generators, [%{p_mw: 400.0}], 200.0)

      for record <- trajectory do
        assert record.gov_response_mw <= 2.0 * record.time + 1.0e-6,
               "at t=#{record.time}s the governor had delivered #{record.gov_response_mw} MW, above the 2 MW/s limit"
      end
    end

    test "rate limits deepen the nadir without moving the settling point much" do
      # Same droop demand, different delivery rates: the fast machine arrests
      # the decline higher up. Both settle near the same place because neither
      # rate binds once the transient is over.
      loads = [%{p_mw: 400.0}]
      gas = [%{p_max_mw: 1000.0, capacity_factor: 0.4, fuel_type: "NG"}]
      # Coal shares gas's inertia band closely enough that this is a fair
      # comparison of DELIVERY, not of rotor size.
      coal = [%{p_max_mw: 1000.0, capacity_factor: 0.4, fuel_type: "BIT"}]

      fast = Frequency.simulate(gas, loads, 40.0)
      slow = Frequency.simulate(coal, loads, 40.0)

      assert Frequency.nadir(fast) > Frequency.nadir(slow)
    end

    test "the governor deadband swallows excursions smaller than 0.036 Hz" do
      assert Frequency.governor_deadband_hz() == 0.036

      # Sized so the settling deviation stays inside the deadband: 5,000 MW of
      # load damps 0.5 MW of loss in well under 36 mHz.
      generators = [%{p_max_mw: 10_000.0, capacity_factor: 0.5, fuel_type: "NG"}]
      trajectory = Frequency.simulate(generators, [%{p_mw: 5_000.0}], 0.5)

      assert Frequency.settling_frequency(trajectory) > 60.0 - Frequency.governor_deadband_hz()
      assert Enum.all?(trajectory, &(&1.gov_response_mw == 0.0))
    end
  end

  describe "ENE-14: oil and biomass/waste fuel classes" do
    test "biomass and waste codes get steam dynamics, not gas-turbine dynamics" do
      for code <- ~w(BLQ WDS WDL MSW MSB MSN OBS OBL AB SLW TDF PC WH BFG SGC SGP PUR OTH) do
        assert Frequency.fuel_class(%{fuel_type: code}) == "biomass",
               "#{code} should carry biomass steam dynamics"
      end

      row = Frequency.machine_constants("biomass")
      assert row.inertia_h_s == 4.0
      assert row.gov_time_s == 5.0
      refute row.gov_time_s == Frequency.machine_constants("gas").gov_time_s
    end

    test "biogas engines are their own class, slower rotor and no duty" do
      for code <- ~w(LFG OBG OG) do
        assert Frequency.fuel_class(%{fuel_type: code}) == "waste_gas"
      end

      row = Frequency.machine_constants("waste_gas")
      assert row.inertia_h_s == 2.0
      refute row.governor_duty?
    end

    test "oil codes map to oil, never to gas" do
      for code <- ~w(DFO RFO KER JF WO PG) do
        assert Frequency.fuel_class(%{fuel_type: code}) == "oil", "#{code}"
      end

      assert Frequency.machine_constants("oil").gov_time_s == 5.0
    end

    test "COL stays mapped to coal even though no simulated bus carries it" do
      # The 268 GW that carried COL sat on coordinate-less MATPOWER buses and
      # is not in the re-ingested database at all. Mapped so that if such rows
      # ever return they cannot silently become combustion turbines.
      assert Frequency.fuel_class(%{fuel_type: "COL"}) == "coal"
    end

    test "unknown fuels still fall back to gas dynamics" do
      assert Frequency.fuel_class(%{fuel_type: "ZZZ"}) == "gas"
      assert Frequency.fuel_class(%{fuel_type: nil}) == "gas"
      assert Frequency.fuel_class(nil) == "gas"
    end

    test "fuel class names resolve to themselves" do
      for class <- Map.keys(Frequency.machine_constants()) do
        assert Frequency.fuel_class(class) == class
      end
    end
  end

  # ===========================================================================
  # Persistent frequency state (ROADMAP item 15)
  # ===========================================================================

  describe "persistent frequency state" do
    defp fleet do
      [
        %{id: 1, p_max_mw: 1000.0, capacity_factor: 0.5, fuel_type: "NG"},
        %{id: 2, p_max_mw: 400.0, capacity_factor: 0.5, fuel_type: "BIT"}
      ]
    end

    defp island_loads, do: [%{id: 1, p_mw: 700.0}]

    test "simulate/3..6 is unchanged: same trajectory, state simply discarded" do
      trajectory = Frequency.simulate(fleet(), island_loads(), 25.0)

      {with_state, state} =
        Frequency.simulate_with_state(fleet(), island_loads(), 25.0)

      assert trajectory == with_state
      # The records round for display; the state keeps full precision so a
      # resumed segment does not inherit a rounding step.
      assert_in_delta state.frequency, Frequency.settling_frequency(trajectory), 1.0e-6
      assert state.lost_mw == 25.0
      assert_in_delta state.total_load_mw, 700.0, 1.0e-9
    end

    test "a second trip from a depressed start reaches a strictly worse nadir" do
      {first, state} = Frequency.simulate_with_state(fleet(), island_loads(), 25.0)

      assert Frequency.settling_frequency(first) < 60.0

      # The SAME second disturbance, once from the depressed state and once
      # from a cold 60.0 Hz start.
      {compounded, _} =
        Frequency.simulate_with_state(fleet(), island_loads(), 25.0, initial_state: state)

      {fresh, _} = Frequency.simulate_with_state(fleet(), island_loads(), 25.0)

      assert Frequency.nadir(compounded) < Frequency.nadir(fresh)
      assert Frequency.settling_frequency(compounded) < Frequency.settling_frequency(fresh)

      # And worse than where the first disturbance left it, which is the
      # positive feedback the cascade was missing.
      assert Frequency.nadir(compounded) < Frequency.nadir(first)
    end

    test "the resumed segment picks up the clock and the frequency where it left off" do
      {_first, state} = Frequency.simulate_with_state(fleet(), island_loads(), 25.0)

      {second, _} =
        Frequency.simulate_with_state(fleet(), island_loads(), 5.0, initial_state: state)

      resumed = hd(second)
      assert resumed.time == Float.round(state.time, 4)
      assert resumed.frequency == Float.round(state.frequency, 6)
      assert List.last(second).time > state.time
    end

    test "governor output already deployed is carried, not re-earned" do
      {_first, state} = Frequency.simulate_with_state(fleet(), island_loads(), 25.0)

      deployed = state.gov_state |> Map.values() |> Enum.sum()
      assert deployed > 0.0

      {second, _} =
        Frequency.simulate_with_state(fleet(), island_loads(), 5.0, initial_state: state)

      # The segment opens with the MW the fleet is already holding.
      assert_in_delta hd(second).gov_response_mw, deployed, 0.01
    end

    test "governor state follows generator ids through a changed fleet" do
      {_first, state} = Frequency.simulate_with_state(fleet(), island_loads(), 25.0)

      assert Map.keys(state.gov_state) |> Enum.sort() == [1, 2]
      unit_2_mw = Map.fetch!(state.gov_state, 2)
      assert unit_2_mw > 0.0

      # Unit 1 trips; unit 3 comes online. Unit 2 must resume where it was,
      # unit 3 must start from nothing, unit 1 must simply disappear.
      changed = [
        %{id: 2, p_max_mw: 400.0, capacity_factor: 0.5, fuel_type: "BIT"},
        %{id: 3, p_max_mw: 200.0, capacity_factor: 0.5, fuel_type: "NG"}
      ]

      {trajectory, next} =
        Frequency.simulate_with_state(changed, island_loads(), 100.0, initial_state: state)

      assert Map.keys(next.gov_state) |> Enum.sort() == [2, 3]
      assert_in_delta hd(trajectory).gov_response_mw, unit_2_mw, 0.01
    end

    test "UFLS stages already spent cannot fire again" do
      # First disturbance deep enough to spend stage 1.
      {first, state} = Frequency.simulate_with_state(fleet(), island_loads(), 120.0)

      assert Frequency.nadir(first) < 59.3
      spent = Enum.count(state.ufls_state, & &1.tripped)
      assert spent >= 1

      shed_after_first = state.cumulative_shed_mw
      assert shed_after_first > 0.0

      # A second disturbance on the loads UFLS left connected.
      remaining = [%{id: 1, p_mw: 700.0 - shed_after_first}]

      {_second, next} =
        Frequency.simulate_with_state(fleet(), remaining, 30.0, initial_state: state)

      # Stages only ever accumulate...
      assert Enum.count(next.ufls_state, & &1.tripped) >= spent

      # ...and every stage that had already tripped stays tripped, so no
      # breaker is closed and reopened to shed the same megawatts twice.
      for {before_stage, after_stage} <- Enum.zip(state.ufls_state, next.ufls_state) do
        if before_stage.tripped, do: assert(after_stage.tripped)
      end
    end

    test "the load base tracks load shed between segments" do
      {_first, state} = Frequency.simulate_with_state(fleet(), island_loads(), 120.0)
      shed = state.cumulative_shed_mw
      assert shed > 0.0

      # Caller passes the CURRENTLY CONNECTED loads; the base is rebuilt as
      # connected + already-shed, recovering the original 700 MW.
      remaining = [%{id: 1, p_mw: 700.0 - shed}]

      {_second, next} =
        Frequency.simulate_with_state(fleet(), remaining, 0.0, initial_state: state)

      assert_in_delta next.total_load_mw, 700.0, 0.01

      # A further 100 MW shed by the cascade between segments shrinks the base
      # by exactly that much.
      thinner = [%{id: 1, p_mw: 700.0 - shed - 100.0}]

      {_third, after_shed} =
        Frequency.simulate_with_state(fleet(), thinner, 0.0, initial_state: state)

      assert_in_delta after_shed.total_load_mw, 600.0, 0.01
    end

    test "lost MW accumulate across segments instead of replacing each other" do
      {_a, s1} = Frequency.simulate_with_state(fleet(), island_loads(), 25.0)
      {_b, s2} = Frequency.simulate_with_state(fleet(), island_loads(), 15.0, initial_state: s1)

      assert s1.lost_mw == 25.0
      assert s2.lost_mw == 40.0
    end

    test "a resumed segment with no new loss holds its frequency" do
      # Nothing new happened: the island is already in equilibrium, and the
      # continuation must not drift back toward 60 Hz on its own.
      {_first, state} = Frequency.simulate_with_state(fleet(), island_loads(), 25.0)

      {held, next} =
        Frequency.simulate_with_state(fleet(), island_loads(), 0.0, initial_state: state)

      assert_in_delta Frequency.settling_frequency(held), state.frequency, 0.01
      assert_in_delta next.frequency, state.frequency, 0.01
    end

    test "the collapsed flag is sticky across segments" do
      {_first, state} = Frequency.simulate_with_state([], [%{p_mw: 100.0}], 100.0)
      assert state.collapsed

      {resumed, next} =
        Frequency.simulate_with_state([], [%{p_mw: 100.0}], 0.0, initial_state: state)

      assert next.collapsed
      assert Frequency.collapsed?(resumed)
      assert hd(resumed).collapsed
    end
  end

  describe "mean_frequency/3" do
    test "averages the samples inside the window" do
      trajectory = [
        %{time: 0.0, frequency: 60.0},
        %{time: 10.0, frequency: 59.8},
        %{time: 20.0, frequency: 59.6},
        %{time: 30.0, frequency: 59.4}
      ]

      assert_in_delta Frequency.mean_frequency(trajectory, 20.0, 30.0), 59.5, 1.0e-9
    end

    test "falls back to the settling value when the window is empty" do
      trajectory = [%{time: 0.0, frequency: 60.0}, %{time: 1.0, frequency: 59.9}]

      assert Frequency.mean_frequency(trajectory, 20.0, 52.0) == 59.9
    end
  end
end
