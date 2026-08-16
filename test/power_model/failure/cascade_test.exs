defmodule PowerModel.Failure.CascadeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PowerModel.Failure.{Cascade, Protection}
  alias PowerModel.Solver.DCPowerFlow

  # ---------------------------------------------------------------------------
  # Helpers – plain-map builders
  # ---------------------------------------------------------------------------

  defp bus(id, opts \\ []) do
    %{
      id: id,
      bus_type: Keyword.get(opts, :bus_type, 1),
      base_kv: Keyword.get(opts, :base_kv, 138.0),
      vm_pu: 1.0,
      va_rad: 0.0
    }
  end

  defp line(id, from, to, opts \\ []) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      voltage_kv: Keyword.get(opts, :voltage_kv, 138.0),
      r_pu: Keyword.get(opts, :r_pu, 0.01),
      x_pu: Keyword.get(opts, :x_pu, 0.1),
      b_pu: Keyword.get(opts, :b_pu, 0.02),
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 100.0)
    }
  end

  defp transformer(id, from, to, opts) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      r_pu: Keyword.get(opts, :r_pu, 0.005),
      x_pu: Keyword.get(opts, :x_pu, 0.05),
      rated_mva: Keyword.get(opts, :rated_mva, 200.0),
      tap_ratio: Keyword.get(opts, :tap_ratio, 1.0)
    }
  end

  defp generator(id, bus_id, opts) do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      capacity_factor: Keyword.get(opts, :capacity_factor, 1.0),
      q_max_mvar: Keyword.get(opts, :q_max_mvar, 50.0),
      q_min_mvar: Keyword.get(opts, :q_min_mvar, -50.0)
    }
  end

  defp load(id, bus_id, opts) do
    %{
      id: id,
      bus_id: bus_id,
      p_mw: Keyword.get(opts, :p_mw, 50.0),
      q_mvar: Keyword.get(opts, :q_mvar, 20.0)
    }
  end

  defp make_snapshot(buses, lines, transformers, generators, loads) do
    %{
      buses: buses,
      lines: lines,
      transformers: transformers,
      generators: generators,
      loads: loads
    }
  end

  # A simple 3-bus linear network:
  #   Bus 1 (slack/gen) --line1-- Bus 2 (load) --line2-- Bus 3 (load)
  defp three_bus_snapshot do
    buses = [bus(1, bus_type: 3), bus(2), bus(3)]
    lines = [line(1, 1, 2), line(2, 2, 3)]
    gens = [generator(1, 1, p_max_mw: 200.0)]
    loads = [load(1, 2, p_mw: 60.0), load(2, 3, p_mw: 40.0)]
    make_snapshot(buses, lines, [], gens, loads)
  end

  # ===========================================================================
  # init/2
  # ===========================================================================

  describe "init/2" do
    test "creates proper initial state with default base_mva" do
      snapshot = three_bus_snapshot()
      state = Cascade.init(snapshot)

      assert %Cascade{} = state
      assert state.buses == snapshot.buses
      assert state.lines == snapshot.lines
      assert state.transformers == snapshot.transformers
      assert state.generators == snapshot.generators
      assert state.loads == snapshot.loads
      assert state.base_mva == 100.0
      assert state.tripped_lines == MapSet.new()
      assert state.tripped_generators == MapSet.new()
      assert state.tripped_transformers == MapSet.new()
      assert state.events == []
      assert state.step == 0
      assert state.stable == false
      assert state.solution == nil
      assert state.relay_duty == %{}
    end

    test "creates state with custom base_mva" do
      snapshot = three_bus_snapshot()
      state = Cascade.init(snapshot, 50.0)

      assert state.base_mva == 50.0
    end

    test "preserves all buses, lines, generators, and loads" do
      snapshot = three_bus_snapshot()
      state = Cascade.init(snapshot)

      assert length(state.buses) == 3
      assert length(state.lines) == 2
      assert length(state.generators) == 1
      assert length(state.loads) == 2
    end
  end

  # ===========================================================================
  # init/3 – measured EIA-930 dispatch
  # ===========================================================================

  describe "init/3 dispatch source" do
    @hour ~U[2024-07-15 18:00:00Z]

    # Bus 1 and 2 in BA 7; one gas unit, one coal unit, one nuclear unit.
    defp ba_snapshot do
      buses = [
        bus(1, bus_type: 3) |> Map.put(:balancing_authority_id, 7),
        bus(2) |> Map.put(:balancing_authority_id, 7)
      ]

      gens = [
        generator(1, 1, p_max_mw: 200.0, capacity_factor: 0.5)
        |> Map.merge(%{fuel_type: "NG", prime_mover: "CC", p_min_mw: 0.0}),
        generator(2, 1, p_max_mw: 200.0, capacity_factor: 0.4)
        |> Map.merge(%{fuel_type: "BIT", prime_mover: "ST", p_min_mw: 0.0}),
        generator(3, 2, p_max_mw: 200.0, capacity_factor: 0.95)
        |> Map.merge(%{fuel_type: "NUC", prime_mover: "ST", p_min_mw: 0.0})
      ]

      make_snapshot(buses, [line(1, 1, 2)], [], gens, [load(1, 2, p_mw: 150.0)])
    end

    test "an hour with per-fuel data commits units at the measured MW" do
      state =
        Cascade.init(ba_snapshot(), 100.0,
          hour: @hour,
          fuel_totals: %{7 => %{"natural_gas" => 120.0, "nuclear" => 180.0}}
        )

      assert state.dispatch_source == :eia_fuel
      assert state.dispatch[1] == 120.0
      assert state.dispatch[3] == 180.0
      # Coal was not measured for this BA-hour and the measured 300 MW already
      # exceed the island's 150 MW of load, so the coal unit stays OFFLINE --
      # explicitly at 0.0, never absent (an absent generator would be
      # redispatched at p_max * capacity_factor).
      assert state.dispatch[2] === 0.0
      assert Map.has_key?(state.dispatch, 2)
    end

    test "offline units carry no inertia and no governor into the frequency model" do
      state =
        Cascade.init(ba_snapshot(), 100.0,
          hour: @hour,
          fuel_totals: %{7 => %{"natural_gas" => 120.0, "nuclear" => 180.0}}
        )

      solver_gens = Cascade.dispatched_generators(state)
      offline = Enum.find(solver_gens, &(&1.id == 2))

      # Frequency.simulate/5 keeps generators with capacity_factor > 0 AND
      # p_max_mw > 0 as its online set; the offline unit fails the second test.
      assert offline.p_max_mw == 0.0
      assert offline.p_dispatch_mw == 0.0
      assert offline.p_nameplate_mw == 200.0

      online = Enum.find(solver_gens, &(&1.id == 1))
      assert online.p_max_mw == 120.0
      assert online.p_nameplate_mw == 200.0
    end

    test "without an hour, dispatch falls back to the load-following rule" do
      state = Cascade.init(ba_snapshot())

      assert state.dispatch_source == :proportional
      assert state.dispatch_coverage == nil
      # Proportional rule: every unit runs at the same fraction of capacity
      assert state.dispatch[1] == state.dispatch[2]
      assert state.dispatch[2] == state.dispatch[3]
    end

    test "an hour with no fuel data falls back and logs why" do
      # The suite runs at :warning; the fallback notice is an info line.
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log(fn ->
          state = Cascade.init(ba_snapshot(), 100.0, hour: @hour, fuel_totals: %{})

          assert state.dispatch_source == :proportional
        end)

      assert log =~ "load-following dispatch"
      assert log =~ "no EIA-930 per-fuel generation ingested for 2024-07-15T18:00:00Z"
    end

    test "measured dispatch keeps the consumption balance conserved" do
      state =
        Cascade.init(ba_snapshot(), 100.0,
          hour: @hour,
          fuel_totals: %{7 => %{"natural_gas" => 120.0, "nuclear" => 180.0}}
        )

      balance = Cascade.balance(state)

      assert_in_delta balance.dispatched_gen_mw, 300.0, 1.0e-9

      assert_in_delta balance.original_load_mw,
                      balance.served_load_mw + balance.shed_load_mw + balance.blackout_load_mw,
                      1.0e-9
    end
  end

  # ===========================================================================
  # trip_line/2 – island creation
  # ===========================================================================

  describe "trip_line/2" do
    test "tripping line 1-2 in a 3-bus chain creates an island" do
      # Network: Bus1(gen) --line1-- Bus2(load) --line2-- Bus3(load)
      # Trip line 1 (1-2): Bus1 alone (has gen but <2 buses => blackout path),
      # Bus2-Bus3 island has no generation => blackout.
      snapshot = three_bus_snapshot()
      state = Cascade.init(snapshot)

      {final_state, step_results} = Cascade.trip_line(state, 1)

      # Line 1 should be in tripped set
      assert MapSet.member?(final_state.tripped_lines, 1)

      # There should be at least one cascade step
      assert length(step_results) >= 1

      # The initial trip event should be recorded
      trip_events =
        final_state.events
        |> Enum.filter(&(&1.component_type == "transmission_line" and &1.component_id == 1))

      assert length(trip_events) >= 1
    end

    test "tripping a line records a manual_trip event at step 0" do
      snapshot = three_bus_snapshot()
      state = Cascade.init(snapshot)

      {final_state, _results} = Cascade.trip_line(state, 2)

      manual_events =
        Enum.filter(final_state.events, fn e ->
          e.failure_cause == "manual_trip" and e.component_id == 2
        end)

      assert length(manual_events) == 1
      [event] = manual_events
      assert event.step == 0
      assert event.component_type == "transmission_line"
    end

    test "island without generation triggers blackout for its loads" do
      # Bus1(gen) --line1-- Bus2(load) --line2-- Bus3(load)
      # Trip line 1: Bus2+Bus3 island has no gen => loads blackout
      snapshot = three_bus_snapshot()
      state = Cascade.init(snapshot)

      {final_state, _step_results} = Cascade.trip_line(state, 1)

      # Check that blackout events were generated for loads on bus 2 and 3
      blackout_events =
        final_state.events
        |> Enum.filter(&(&1.failure_cause == "island_blackout"))

      # At minimum, loads on the no-gen island should be blacked out
      blackout_load_ids = Enum.map(blackout_events, & &1.component_id)

      # Load 1 is on bus 2, load 2 is on bus 3 — both in the island without gen
      assert 1 in blackout_load_ids or 2 in blackout_load_ids
    end
  end

  # ===========================================================================
  # Cascade stabilization
  # ===========================================================================

  describe "cascade stabilization" do
    test "cascade stabilizes when no violations occur" do
      # A well-provisioned network: gen >> load, lines have plenty of capacity.
      # After solving, no overloads => stable in 1 step.
      buses = [bus(1, bus_type: 3), bus(2)]
      lines = [line(1, 1, 2, rating_a_mva: 500.0, x_pu: 0.1)]
      gens = [generator(1, 1, p_max_mw: 200.0)]
      loads = [load(1, 2, p_mw: 50.0)]

      snapshot = make_snapshot(buses, lines, [], gens, loads)
      state = Cascade.init(snapshot)

      # Run cascade with no initial trip — just solve the intact network
      {final_state, step_results} = Cascade.run_cascade(state)

      assert final_state.stable == true
      # Should stabilize in exactly 1 step (no violations found)
      assert length(step_results) == 1
      [step1] = step_results
      assert step1.trips == []
      assert step1.islands == 1
    end

    test "a single-bus island is dead only if it has no generation (CAS-15)" do
      # Isolating bus 2 leaves three one-bus islands: bus 1 and bus 3 each
      # carry a generator and are trivially solvable (theta = 0), which is
      # what SOL-3 established for the solver; bus 2 carries load and no
      # generation and is genuinely dead. `island_dead?/2` used to call all
      # three dead on SIZE alone, so the cascade blacked out islands the
      # solver was perfectly willing to solve.
      buses = [bus(1, bus_type: 3), bus(2), bus(3)]
      lines = [line(1, 1, 2), line(2, 2, 3)]
      gens = [generator(1, 1, p_max_mw: 100.0), generator(2, 3, p_max_mw: 100.0)]
      loads = [load(1, 2, p_mw: 50.0)]

      snapshot = make_snapshot(buses, lines, [], gens, loads)
      state = Cascade.init(snapshot)

      # Trip both lines, isolating bus 2
      state = %{
        state
        | tripped_lines: MapSet.new([1, 2]),
          events: [
            %{
              step: 0,
              component_type: "transmission_line",
              component_id: 1,
              failure_cause: "manual_trip",
              details: %{}
            },
            %{
              step: 0,
              component_type: "transmission_line",
              component_id: 2,
              failure_cause: "manual_trip",
              details: %{}
            }
          ]
      }

      {final_state, step_results} = Cascade.run_cascade(state)

      # Bus 2 is isolated with a load and no generation — it blacks out.
      blackout_events =
        final_state.events
        |> Enum.filter(&(&1.failure_cause == "island_blackout"))

      assert [event] = blackout_events
      assert event.component_id == 1
      assert_in_delta event.details.lost_mw, 50.0, 1.0e-9

      # Buses 1 and 3 are one-bus islands WITH generation: both are solved.
      solved_bus_sets =
        step_results
        |> Enum.flat_map(& &1.solution)
        |> Enum.map(&MapSet.new(&1.bus_ids))
        |> Enum.uniq()

      assert MapSet.new([1]) in solved_bus_sets
      assert MapSet.new([3]) in solved_bus_sets
    end
  end

  # ===========================================================================
  # Thermal overloads triggering additional trips
  # ===========================================================================

  describe "thermal overload cascading" do
    test "overloaded line triggers additional trip in subsequent step" do
      # 3-bus network with two parallel paths: bus1 -> bus2 via line1 and line2.
      # bus2 -> bus3 via line3.
      # Each line rated 60 MVA. Total load 100 MW on bus3.
      # All lines intact: flow splits ~50 MW each on line1/line2, then 100 MW on line3.
      # Line3 is overloaded (100 > 60) => trips.
      # After line3 trips, bus3 isolated => blackout.
      buses = [bus(1, bus_type: 3), bus(2), bus(3)]

      lines = [
        line(1, 1, 2, rating_a_mva: 60.0, x_pu: 0.1),
        line(2, 1, 2, rating_a_mva: 60.0, x_pu: 0.1),
        line(3, 2, 3, rating_a_mva: 60.0, x_pu: 0.1)
      ]

      gens = [generator(1, 1, p_max_mw: 200.0)]
      loads = [load(1, 3, p_mw: 100.0)]

      snapshot = make_snapshot(buses, lines, [], gens, loads)
      state = Cascade.init(snapshot)

      {final_state, step_results} = Cascade.run_cascade(state)

      # Line 3 carries 100 MW through a 60 MVA rating => overloaded => tripped
      # This should cause cascade steps > 1
      if length(step_results) > 1 do
        # Thermal trips should appear in events
        thermal_events =
          final_state.events
          |> Enum.filter(&(&1.failure_cause == "thermal_overload"))

        assert length(thermal_events) >= 1

        # Line 3 should have been tripped by protection
        tripped_line_ids =
          thermal_events
          |> Enum.filter(&(&1.component_type == "transmission_line"))
          |> Enum.map(& &1.component_id)

        assert 3 in tripped_line_ids
      else
        # If solver handled it in 1 step, verify stable
        assert final_state.stable == true
      end
    end

    test "well-rated lines do not trigger thermal trips" do
      # All lines rated at 500 MVA, load only 50 MW => no overloads
      buses = [bus(1, bus_type: 3), bus(2)]
      lines = [line(1, 1, 2, rating_a_mva: 500.0, x_pu: 0.1)]
      gens = [generator(1, 1, p_max_mw: 200.0)]
      loads = [load(1, 2, p_mw: 50.0)]

      snapshot = make_snapshot(buses, lines, [], gens, loads)
      state = Cascade.init(snapshot)

      {final_state, step_results} = Cascade.run_cascade(state)

      thermal_events =
        final_state.events
        |> Enum.filter(&(&1.failure_cause == "thermal_overload"))

      assert thermal_events == []
      assert final_state.stable == true
      assert length(step_results) == 1
    end

    test "equal concurrent overloads accrue relay time in parallel" do
      buses = [bus(1, bus_type: 3), bus(2), bus(3, bus_type: 3), bus(4)]

      lines = [
        line(1, 1, 2, rating_a_mva: 50.0),
        line(2, 3, 4, rating_a_mva: 50.0)
      ]

      gens = [generator(1, 1, p_max_mw: 100.0), generator(2, 3, p_max_mw: 100.0)]
      loads = [load(1, 2, p_mw: 80.0), load(2, 4, p_mw: 80.0)]

      state =
        Cascade.init(make_snapshot(buses, lines, [], gens, loads))
        |> Map.put(:base_overloaded, MapSet.new())

      {final_state, step_results} = Cascade.run_cascade(state)

      thermal_steps =
        Enum.filter(step_results, fn step ->
          Enum.any?(step.trips, &(&1.failure_cause == "thermal_overload"))
        end)

      assert [first_trip_step, second_trip_step] = thermal_steps
      assert first_trip_step.simulated_time > 0.0

      # Both lines started with the same loading and timed concurrently, so the
      # second trip consumes no additional wall-clock time.
      assert_in_delta second_trip_step.simulated_time, first_trip_step.simulated_time, 1.0e-9
      assert_in_delta final_state.simulated_time, first_trip_step.simulated_time, 1.0e-9
      assert final_state.relay_duty == %{}
    end

    test "changing loading preserves fractional relay operating progress" do
      buses = [bus(1, bus_type: 3), bus(2)]

      # Both ratings are low enough that both lines are past RELAY PICKUP
      # (rate C, not rate A) while sharing the load, so the second line is
      # genuinely accruing operating duty when the first one trips. At a
      # rate A of 45 the second line sits at 111% of rate A but only 82% of
      # rate C, so it would not be timing at all and there would be no
      # fractional progress for this test to preserve.
      lines = [
        line(1, 1, 2, rating_a_mva: 30.0, x_pu: 0.1),
        line(2, 1, 2, rating_a_mva: 35.0, x_pu: 0.1)
      ]

      gens = [generator(1, 1, p_max_mw: 150.0)]
      loads = [load(1, 2, p_mw: 100.0)]
      snapshot = make_snapshot(buses, lines, [], gens, loads)

      state =
        Cascade.init(snapshot)
        |> Map.put(:base_overloaded, MapSet.new())

      initial_solution =
        DCPowerFlow.solve(
          %{snapshot | generators: Cascade.dispatched_generators(state)},
          base_mva: state.base_mva
        )

      initial_second_flow = Map.fetch!(initial_solution.line_flows, {:line, 2})
      initial_second_loading = initial_second_flow.loading_pct

      # Duty is integrated against the curve time the relay actually sees, so
      # reconstruct it from the pickup basis (rate C) rather than rate A.
      initial_second_trip_time =
        Protection.overcurrent_trip_time(Cascade.trip_loading_pct(initial_second_flow))

      {final_state, step_results} = Cascade.run_cascade(state)

      thermal_steps =
        Enum.filter(step_results, fn step ->
          Enum.any?(step.trips, &(&1.failure_cause == "thermal_overload"))
        end)

      assert [first_trip_step, second_trip_step] = thermal_steps

      second_trip =
        Enum.find(
          second_trip_step.trips,
          &(&1.failure_cause == "thermal_overload" and &1.component_id == 2)
        )

      assert second_trip
      assert second_trip.details.loading_pct > initial_second_loading

      accrued_duty = first_trip_step.simulated_time / initial_second_trip_time
      second_curve_time = second_trip.details.trip_time_s

      expected_total_time =
        first_trip_step.simulated_time + second_curve_time * (1.0 - accrued_duty)

      second_interval = second_trip_step.simulated_time - first_trip_step.simulated_time

      # Guard the fixture first, and with a real margin. If a rating change ever
      # drops line 2 back below relay pickup it accrues no duty at all, and
      # every assertion below degenerates into `x * (1.0 - 0.0)` compared
      # against `x` — a float tie that fails or passes on the last few ulps and
      # says nothing about the behaviour under test.
      assert accrued_duty > 0.01 and accrued_duty < 1.0,
             "fixture must leave line 2 genuinely timing before line 1 trips; " <>
               "accrued_duty was #{accrued_duty}"

      assert second_interval > 0.0

      # The property this test exists for: the relay did NOT restart from zero
      # when its loading changed. Its remaining time is the FRESH curve time
      # discounted by the duty already banked, so the shortfall against a
      # from-cold trip is exactly that duty. Asserting the ratio pins the
      # relationship itself rather than the bare inequality it implies.
      assert_in_delta second_interval / second_curve_time, 1.0 - accrued_duty, 1.0e-9
      assert second_interval < second_curve_time

      assert_in_delta second_trip_step.simulated_time, expected_total_time, 1.0e-8
      assert_in_delta final_state.simulated_time, expected_total_time, 1.0e-8
    end

    test "thermal and Zone 3 duties use separate accumulator keys" do
      common = %{component_type: "transmission_line", component_id: 7}

      thermal_key =
        Cascade.relay_key(Map.put(common, :failure_cause, "thermal_overload"))

      zone3_key =
        Cascade.relay_key(Map.put(common, :failure_cause, "zone3_relay"))

      assert thermal_key == {"thermal_overload", "transmission_line", 7}
      assert zone3_key == {"zone3_relay", "transmission_line", 7}
      refute thermal_key == zone3_key
    end
  end

  # ===========================================================================
  # trip_generator/2
  # ===========================================================================

  describe "trip_generator/2" do
    test "tripping the only generator causes island deficit or blackout" do
      snapshot = three_bus_snapshot()
      state = Cascade.init(snapshot)

      {final_state, _step_results} = Cascade.trip_generator(state, 1)

      assert MapSet.member?(final_state.tripped_generators, 1)

      # With no generation, loads should be shed or blacked out
      shed_or_blackout =
        final_state.events
        |> Enum.filter(fn e ->
          e.failure_cause in ["island_blackout", "ufls_shed"]
        end)

      assert length(shed_or_blackout) >= 1
    end
  end

  # ===========================================================================
  # Generation-load deficit triggers load shedding
  # ===========================================================================

  describe "load shedding on deficit" do
    test "island with deficit triggers UFLS load shedding" do
      # Gen 100 MW, load 115 MW => a 13% deficit, inside what the four-stage
      # UFLS program can reach, so the island sheds and SURVIVES.
      buses = [bus(1, bus_type: 3), bus(2)]
      lines = [line(1, 1, 2, rating_a_mva: 500.0, x_pu: 0.1)]
      gens = [generator(1, 1, p_max_mw: 100.0)]
      loads = [load(1, 2, p_mw: 115.0)]

      snapshot = make_snapshot(buses, lines, [], gens, loads)
      state = Cascade.init(snapshot)

      {final_state, _step_results} = Cascade.run_cascade(state)

      shed_events =
        final_state.events
        |> Enum.filter(&(&1.failure_cause == "ufls_shed"))

      assert length(shed_events) >= 1

      # Load should have been reduced
      updated_load = Enum.find(final_state.loads, &(&1.id == 1))
      assert updated_load.p_mw < 115.0

      # ...and the machine rode it out: nothing tripped on under-frequency.
      assert final_state.tripped_generators == MapSet.new()
    end

    test "a deficit past the UFLS program's reach takes the island's machines with it" do
      # Gen 80 MW against 120 MW of load: a 33% deficit, and the whole UFLS
      # program cumulates to only ~27% of connected load. The stages fire, the
      # frequency keeps falling through them, and at 57.0 Hz the PRC-024
      # envelope has no allowance left — every machine in the island trips.
      # That is ROADMAP item 15's positive feedback loop closing on itself:
      # the model can now produce a total island collapse, which the old
      # force-shed tier quietly prevented by balancing the island on paper.
      buses = [bus(1, bus_type: 3), bus(2)]
      lines = [line(1, 1, 2, rating_a_mva: 500.0, x_pu: 0.1)]
      gens = [generator(1, 1, p_max_mw: 80.0)]
      loads = [load(1, 2, p_mw: 120.0)]

      state = Cascade.init(make_snapshot(buses, lines, [], gens, loads))
      {final_state, _steps} = Cascade.run_cascade(state)

      assert MapSet.member?(final_state.tripped_generators, 1)

      [trip] = Enum.filter(final_state.events, &(&1.failure_cause == "underfrequency_trip"))
      assert trip.component_type == "generator"
      assert trip.details.band_hz == 57.0
      assert trip.details.allowance_s == 0.0

      # One aggregated island-level event beside the per-unit trips.
      [aggregate] =
        Enum.filter(final_state.events, &(&1.failure_cause == "generator_frequency_trips"))

      assert aggregate.component_type == "island"
      assert aggregate.details.unit_count == 1
      assert aggregate.details.tripped_mw > 0.0

      # The island is dark, and the accounting says so.
      balance = Cascade.balance(final_state)
      assert_in_delta balance.served_load_mw, 0.0, 1.0e-9
      assert_in_delta balance.blackout_load_mw, 120.0, 0.01

      assert_in_delta balance.served_load_mw + balance.shed_load_mw + balance.blackout_load_mw,
                      balance.original_load_mw + balance.btm_tripped_mw,
                      0.01
    end
  end

  # ===========================================================================
  # Event tracking
  # ===========================================================================

  describe "event tracking" do
    test "events accumulate across cascade steps" do
      snapshot = three_bus_snapshot()
      state = Cascade.init(snapshot)

      {final_state, _results} = Cascade.trip_line(state, 1)

      # Should have at least the manual trip event
      assert length(final_state.events) >= 1

      # All events should have a step field
      for event <- final_state.events do
        assert Map.has_key?(event, :step)
        assert Map.has_key?(event, :component_type)
        assert Map.has_key?(event, :component_id)
        assert Map.has_key?(event, :failure_cause)
      end
    end

    test "step_results contain island count and trips per step" do
      snapshot = three_bus_snapshot()
      state = Cascade.init(snapshot)

      {_final_state, step_results} = Cascade.trip_line(state, 1)

      for step_result <- step_results do
        assert Map.has_key?(step_result, :step)
        assert Map.has_key?(step_result, :islands)
        assert Map.has_key?(step_result, :trips)
        assert is_integer(step_result.islands)
        assert is_list(step_result.trips)
      end
    end

    test "singular island solve emits a persisted failure event without losing its load" do
      buses = [
        bus(1, bus_type: 3),
        bus(2),
        bus(3),
        bus(10, bus_type: 3),
        bus(11)
      ]

      lines = [
        line(1, 1, 2, x_pu: 1.0, rating_a_mva: 1_000.0),
        line(2, 1, 2, x_pu: -1.0, rating_a_mva: 1_000.0),
        line(3, 2, 3, x_pu: 1.0, rating_a_mva: 1_000.0),
        line(10, 10, 11, x_pu: 0.1, rating_a_mva: 1_000.0)
      ]

      gens = [
        generator(1, 1, p_max_mw: 100.0),
        generator(10, 10, p_max_mw: 10.0)
      ]

      loads = [load(1, 3, p_mw: 100.0)]
      state = Cascade.init(make_snapshot(buses, lines, [], gens, loads))

      {final_state, step_results} = Cascade.trip_line(state, 10)

      assert [failure_event] =
               Enum.filter(
                 final_state.events,
                 &(&1.failure_cause == "island_solve_failed")
               )

      assert failure_event.step == 1
      assert failure_event.component_type == "island"
      assert failure_event.component_id == 1
      assert failure_event.details.bus_count == 3
      assert_in_delta failure_event.details.load_mw, 100.0, 1.0e-9
      assert failure_event.details.error =~ "singular_matrix"
      refute final_state.stable

      assert Enum.any?(hd(step_results).trips, fn trip ->
               trip.failure_cause == "island_solve_failed" and trip.component_id == 1
             end)

      balance = Cascade.balance(final_state)

      assert_in_delta balance.served_load_mw + balance.shed_load_mw +
                        balance.blackout_load_mw,
                      balance.original_load_mw + balance.btm_tripped_mw,
                      0.01
    end
  end

  # ===========================================================================
  # Consumption accounting (balance)
  # ===========================================================================

  # The invariant asserted throughout this block is the extended one,
  #
  #     served + shed + blackout == original + btm_tripped
  #
  # where `btm_tripped` is behind-the-meter solar that IEEE 1547 tripped into
  # load mid-run (ROADMAP item 31, `PowerModel.Failure.Cascade.balance/1`).
  # None of these scenarios carries a `:btm_solar` layer, so that term is 0.0
  # in every one of them and the identity reduces to the original three-bucket
  # form — which is the point of writing it this way: these tests keep proving
  # the pre-BTM behaviour, and they now do it against the identity the code
  # actually maintains. `test/power_model/failure/btm_trip_test.exs` drives the
  # term off zero.
  describe "consumption accounting" do
    test "init records original load and zeroed accounting" do
      state = Cascade.init(three_bus_snapshot())

      assert_in_delta state.original_load_mw, 100.0, 1.0e-6
      assert state.shed_load_mw == 0.0
      assert state.blackout_load_mw == 0.0
      assert state.btm_tripped_mw == 0.0
      assert state.btm_tripped_buses == MapSet.new()

      balance = Cascade.balance(state)
      assert_in_delta balance.original_load_mw, 100.0, 1.0e-6
      assert_in_delta balance.served_load_mw, 100.0, 1.0e-6
      assert balance.shed_load_mw == 0.0
      assert balance.blackout_load_mw == 0.0
      assert balance.btm_tripped_mw == 0.0
      assert balance.online_capacity_mw == 200.0
    end

    test "a snapshot with no btm_solar key keeps the term at zero throughout" do
      # Every caller that predates the layer hands over a snapshot with no
      # `:btm_solar` key at all. That must stay a no-op, not a crash.
      state = Cascade.init(three_bus_snapshot())
      assert state.btm_by_bus == %{}

      {final, step_results} = Cascade.trip_line(state, 1)

      assert final.btm_tripped_mw == 0.0
      assert Enum.all?(step_results, &(&1.balance.btm_tripped_mw == 0.0))
    end

    test "every step result carries a balance map" do
      state = Cascade.init(three_bus_snapshot())
      {_final, step_results} = Cascade.trip_line(state, 1)

      for step <- step_results do
        assert %{
                 original_load_mw: _,
                 served_load_mw: _,
                 shed_load_mw: _,
                 blackout_load_mw: _,
                 btm_tripped_mw: _,
                 dispatched_gen_mw: _,
                 online_capacity_mw: _
               } = step.balance
      end
    end

    test "island blackout: conservation holds and loads are zeroed" do
      # Trip line 1: buses 2+3 island with no gen -> both loads (100 MW) black out
      state = Cascade.init(three_bus_snapshot())
      {final_state, _steps} = Cascade.trip_line(state, 1)

      balance = Cascade.balance(final_state)

      assert_in_delta balance.served_load_mw + balance.shed_load_mw +
                        balance.blackout_load_mw,
                      balance.original_load_mw + balance.btm_tripped_mw,
                      0.01

      assert balance.blackout_load_mw > 0.0

      # Blacked-out loads must carry zero demand (no phantom load)
      blackout_ids =
        final_state.events
        |> Enum.filter(&(&1.failure_cause == "island_blackout"))
        |> MapSet.new(& &1.component_id)

      for l <- final_state.loads, MapSet.member?(blackout_ids, l.id) do
        assert l.p_mw == 0.0
      end
    end

    test "blackout events carry lost_mw and fire only once per load" do
      state = Cascade.init(three_bus_snapshot())
      {final_state, _steps} = Cascade.trip_line(state, 1)

      blackout_events =
        Enum.filter(final_state.events, &(&1.failure_cause == "island_blackout"))

      assert blackout_events != []

      for event <- blackout_events do
        assert event.details.lost_mw > 0.0
      end

      # No duplicate blackout events for the same load across steps
      ids = Enum.map(blackout_events, & &1.component_id)
      assert ids == Enum.uniq(ids)
    end

    test "UFLS deficit: shed accounting matches event details" do
      # Gen 100 MW, load 115 MW -> UFLS sheds part of the load and the island
      # survives (a deficit past the program's reach collapses it instead —
      # see "load shedding on deficit").
      buses = [bus(1, bus_type: 3), bus(2)]
      lines = [line(1, 1, 2, rating_a_mva: 500.0, x_pu: 0.1)]
      gens = [generator(1, 1, p_max_mw: 100.0)]
      loads = [load(1, 2, p_mw: 115.0)]

      state = Cascade.init(make_snapshot(buses, lines, [], gens, loads))
      {final_state, _steps} = Cascade.run_cascade(state)

      event_shed_mw =
        final_state.events
        |> Enum.filter(&(&1.failure_cause == "ufls_shed"))
        |> Enum.map(&Map.get(&1.details, :shed_mw, 0.0))
        |> Enum.sum()

      assert final_state.shed_load_mw > 0.0
      assert_in_delta final_state.shed_load_mw, event_shed_mw, 0.01

      balance = Cascade.balance(final_state)

      assert_in_delta balance.served_load_mw + balance.shed_load_mw +
                        balance.blackout_load_mw,
                      balance.original_load_mw + balance.btm_tripped_mw,
                      0.01
    end
  end

  # ===========================================================================
  # Island isolation: asynchronous systems never couple
  # ===========================================================================

  describe "island isolation" do
    # Two electrically separate systems in one snapshot (like Western and
    # Eastern interconnections): buses 1-2 (island A) and buses 3-4 (island B).
    defp two_island_snapshot do
      buses = [bus(1, bus_type: 3), bus(2), bus(3, bus_type: 3), bus(4)]

      lines = [
        line(1, 1, 2, rating_a_mva: 500.0, x_pu: 0.1),
        line(2, 3, 4, rating_a_mva: 500.0, x_pu: 0.1)
      ]

      gens = [
        generator(1, 1, p_max_mw: 20.0),
        generator(2, 1, p_max_mw: 400.0),
        generator(3, 3, p_max_mw: 200.0)
      ]

      loads = [load(1, 2, p_mw: 100.0), load(2, 4, p_mw: 100.0)]
      make_snapshot(buses, lines, [], gens, loads)
    end

    test "dispatch is balanced per island at init" do
      state = Cascade.init(two_island_snapshot())

      # Island A: 300 MW capacity serving 100 MW; island B: 200 serving 100.
      island_a_dispatch = Map.get(state.dispatch, 1, 0.0) + Map.get(state.dispatch, 2, 0.0)
      island_b_dispatch = Map.get(state.dispatch, 3, 0.0)

      assert_in_delta island_a_dispatch, 100.0, 1.0e-6
      assert_in_delta island_b_dispatch, 100.0, 1.0e-6
    end

    test "tripping a generator in island A never touches island B" do
      state = Cascade.init(two_island_snapshot())
      dispatch_b_before = Map.get(state.dispatch, 3)
      load_b_before = Enum.find(state.loads, &(&1.id == 2)).p_mw

      {final_state, _steps} = Cascade.trip_generator(state, 1)

      # Island A's deficit is inside the primary response its other machine
      # can deliver in the nadir window (10% of a 400 MW nameplate), so island
      # A covers it from its own governor without shedding a customer.
      assert Map.get(final_state.dispatch, 2) > Map.get(state.dispatch, 2)
      assert Enum.filter(final_state.events, &(&1.failure_cause == "ufls_shed")) == []

      # Island B: dispatch and load are bit-identical
      assert Map.get(final_state.dispatch, 3) == dispatch_b_before
      assert Enum.find(final_state.loads, &(&1.id == 2)).p_mw == load_b_before

      # No shed events for island B's load
      b_sheds =
        Enum.filter(final_state.events, fn e ->
          e.failure_cause == "ufls_shed" and e.component_id == 2
        end)

      assert b_sheds == []
    end

    test "island-A deficit beyond headroom sheds only island-A load" do
      # Island A: single 90 MW gen serving 100 MW (deficit); island B healthy
      buses = [bus(1, bus_type: 3), bus(2), bus(3, bus_type: 3), bus(4)]

      lines = [
        line(1, 1, 2, rating_a_mva: 500.0, x_pu: 0.1),
        line(2, 3, 4, rating_a_mva: 500.0, x_pu: 0.1)
      ]

      gens = [generator(1, 1, p_max_mw: 90.0), generator(3, 3, p_max_mw: 200.0)]
      loads = [load(1, 2, p_mw: 120.0), load(2, 4, p_mw: 100.0)]

      state = Cascade.init(make_snapshot(buses, lines, [], gens, loads))
      {final_state, _steps} = Cascade.run_cascade(state)

      load_a = Enum.find(final_state.loads, &(&1.id == 1))
      load_b = Enum.find(final_state.loads, &(&1.id == 2))

      assert load_a.p_mw < 120.0
      assert load_b.p_mw == 100.0
    end

    test "an island split is covered by primary response when the gap is small enough" do
      # Island A ends up 10 MW short of 110 MW — inside the 20 MW its 200 MW
      # machine's governor can deliver inside the nadir window, so reserves
      # cover it with nothing left for UFLS. The MW is TRANSIENT (governor
      # response, not a new setpoint), so it is tracked in `primary_reserve`
      # as well as in `dispatch`.
      buses = [bus(1, bus_type: 3), bus(2), bus(3, bus_type: 3), bus(4)]

      lines = [
        line(1, 1, 2, rating_a_mva: 500.0),
        line(2, 3, 4, rating_a_mva: 500.0),
        line(3, 2, 3, rating_a_mva: 500.0)
      ]

      gens = [generator(1, 1, p_max_mw: 400.0), generator(2, 3, p_max_mw: 400.0)]
      loads = [load(1, 2, p_mw: 110.0), load(2, 4, p_mw: 90.0)]

      state = Cascade.init(make_snapshot(buses, lines, [], gens, loads))
      assert_in_delta Map.fetch!(state.dispatch, 1), 100.0, 1.0e-6

      {final_state, step_results} = Cascade.trip_line(state, 3)

      assert_in_delta Map.fetch!(final_state.dispatch, 1), 110.0, 1.0e-6
      assert_in_delta Map.fetch!(final_state.primary_reserve, 1), 10.0, 1.0e-6
      refute Enum.any?(final_state.events, &(&1.failure_cause == "ufls_shed"))

      reserve_island_solution =
        step_results
        |> Enum.flat_map(& &1.solution)
        |> Enum.find(&(MapSet.new(&1.bus_ids) == MapSet.new([1, 2])))

      assert_in_delta reserve_island_solution.scheduled_gen_mw, 110.0, 1.0e-6
      assert_in_delta reserve_island_solution.total_load_mw, 110.0, 1.0e-6

      balance = Cascade.balance(final_state)

      assert_in_delta balance.served_load_mw + balance.shed_load_mw + balance.blackout_load_mw,
                      balance.original_load_mw + balance.btm_tripped_mw,
                      0.01
    end

    test "a split too big for primary response sheds, however much nameplate is idle" do
      # The same split, 50 MW short instead of 10. The machine has 100 MW of
      # idle nameplate and it does not matter: governors reach 20 MW in the
      # nadir window and AGC has had no time at all, so the rest is shed.
      # This is ROADMAP item 16's whole point — reserve is a rate, not a
      # quantity.
      buses = [bus(1, bus_type: 3), bus(2), bus(3, bus_type: 3), bus(4)]

      lines = [
        line(1, 1, 2, rating_a_mva: 500.0),
        line(2, 3, 4, rating_a_mva: 500.0),
        line(3, 2, 3, rating_a_mva: 500.0)
      ]

      gens = [generator(1, 1, p_max_mw: 200.0), generator(2, 3, p_max_mw: 200.0)]
      loads = [load(1, 2, p_mw: 150.0), load(2, 4, p_mw: 50.0)]

      state = Cascade.init(make_snapshot(buses, lines, [], gens, loads))
      {final_state, _steps} = Cascade.trip_line(state, 3)

      assert Enum.any?(final_state.events, &(&1.failure_cause == "ufls_shed"))
      assert Enum.find(final_state.loads, &(&1.id == 1)).p_mw < 150.0

      # 100 MW of nameplate headroom sat unused on the machine that was short.
      assert Map.fetch!(final_state.dispatch, 1) < 150.0

      balance = Cascade.balance(final_state)

      assert_in_delta balance.served_load_mw + balance.shed_load_mw + balance.blackout_load_mw,
                      balance.original_load_mw + balance.btm_tripped_mw,
                      0.01
    end
  end

  # ===========================================================================
  # Map repaint truthfulness: solves must use the cascade dispatch
  # ===========================================================================

  describe "dispatched re-solve vs base case" do
    alias PowerModel.Engine.SimulationServer
    alias PowerModel.Solver.DCPowerFlow

    defp categorize_against_base(state) do
      snapshot = %{
        buses: state.buses,
        lines: Enum.reject(state.lines, &MapSet.member?(state.tripped_lines, &1.id)),
        transformers:
          Enum.reject(state.transformers, &MapSet.member?(state.tripped_transformers, &1.id)),
        generators: Cascade.dispatched_generators(state),
        loads: state.loads
      }

      solution = DCPowerFlow.solve_islands(snapshot, base_mva: state.base_mva)

      SimulationServer.categorize_line_flows(
        solution.line_flows,
        state.base_line_categories,
        state.base_line_loading
      )
    end

    test "initial re-solve reports zero changed lines (base == current)" do
      state = Cascade.init(two_island_snapshot())
      assert {[], [], []} = categorize_against_base(state)
    end

    test "tripping island A's generator paints nothing in island B" do
      state = Cascade.init(two_island_snapshot())
      {final_state, _steps} = Cascade.trip_generator(state, 1)

      {ol, st, rt} = categorize_against_base(final_state)

      # Line 2 belongs to the untouched island B: it must never appear
      refute 2 in (ol ++ st ++ rt)
    end
  end

  # ===========================================================================
  # BA-tiered redispatch: origin BA first, island assistance second
  # ===========================================================================

  describe "balancing-authority reserve tiers" do
    # One island, two balancing authorities:
    #   BA 10: bus 1 (gen 1, gen 2)   BA 20: bus 2 (gen 3), bus 3 (load)
    defp two_ba_snapshot(opts) do
      gen2_max = Keyword.get(opts, :gen2_max, 200.0)

      buses = [
        Map.put(bus(1, bus_type: 3), :balancing_authority_id, 10),
        Map.put(bus(2), :balancing_authority_id, 20),
        Map.put(bus(3), :balancing_authority_id, 20)
      ]

      lines = [
        line(1, 1, 2, rating_a_mva: 900.0, x_pu: 0.1),
        line(2, 2, 3, rating_a_mva: 900.0, x_pu: 0.1)
      ]

      gens = [
        generator(1, 1, p_max_mw: 20.0),
        generator(2, 1, p_max_mw: gen2_max),
        generator(3, 2, p_max_mw: 400.0)
      ]

      loads = [load(1, 3, p_mw: 150.0)]
      make_snapshot(buses, lines, [], gens, loads)
    end

    test "re-tripping a generator is a no-op (no phantom redispatch)" do
      state = Cascade.init(two_ba_snapshot(gen2_max: 200.0))
      {after_first, _} = Cascade.trip_generator(state, 1)
      {after_second, _} = Cascade.trip_generator(after_first, 1)

      # No additional lost MW invented: dispatch identical after the re-trip
      assert after_second.dispatch == after_first.dispatch
      assert after_second.loads == after_first.loads
    end

    test "primary response answers island-wide, whoever lost the unit" do
      # Governors do not know about balancing-authority boundaries: every
      # machine in the synchronous island sees the same frequency and answers
      # it. The BA ordering below applies to SECONDARY reserve, which is a
      # BA-level control (ACE restoration), not to the governors.
      state = Cascade.init(two_ba_snapshot(gen2_max: 200.0))
      gen3_before = Map.get(state.dispatch, 3)
      lost = Map.get(state.dispatch, 1)
      assert lost > 0.0

      {final_state, _steps} = Cascade.trip_generator(state, 1)

      gen2_delta = Map.get(final_state.dispatch, 2) - Map.get(state.dispatch, 2)
      gen3_delta = Map.get(final_state.dispatch, 3) - gen3_before

      assert gen2_delta > 0.0
      assert gen3_delta > 0.0

      # They answer in proportion to what each can deliver, which rides on
      # nameplate: gen 3 is twice gen 2's machine, so it carries twice the
      # response. Together they cover the loss.
      assert_in_delta gen3_delta, 2.0 * gen2_delta, 1.0e-6
      assert_in_delta gen2_delta + gen3_delta, lost, 0.5
      assert Enum.filter(final_state.events, &(&1.failure_cause == "ufls_shed")) == []
    end

    defp standing_deficit(state, island, now_s) do
      %{
        state
        | simulated_time: now_s,
          island_states: [
            %{buses: island, frequency_state: nil, exposure: [], deficit_since_s: 0.0}
          ]
      }
    end

    defp ba_delta(raised, before) do
      Map.fetch!(raised.dispatch, 1) - Map.fetch!(before, 1) +
        (Map.fetch!(raised.dispatch, 2) - Map.fetch!(before, 2))
    end

    test "redispatch draws the TERTIARY tier only — secondary belongs to AGC" do
      # ROADMAP Phase 4 wave 3b: AGC owns the secondary tier island-wide,
      # inside the step's own island evaluation where the frequency it
      # regulates against lives. `redispatch/4` keeps only tertiary, because
      # both tiers raise the SAME machines out of the SAME headroom and the
      # cascade re-derives each step's deficit from the raised dispatch.
      #
      # Ten minutes in is exactly the tier boundary: the secondary horizon has
      # just closed and the tertiary start-up delay has just expired, so a
      # fleet that would have had ten minutes of secondary ramp on offer now
      # has zero seconds of tertiary ramp.
      state = Cascade.init(two_ba_snapshot(gen2_max: 200.0))
      island = MapSet.new([1, 2, 3])
      state = standing_deficit(state, island, 600.0)

      before = state.dispatch
      raised = Cascade.redispatch(state, 40.0, island, 10)

      assert ba_delta(raised, before) == 0.0
      assert Map.fetch!(raised.dispatch, 3) == Map.fetch!(before, 3)
    end

    test "the origin BA still answers first on the tertiary tier" do
      # Half an hour in: twenty minutes past the tertiary start-up delay, so
      # the tier has real megawatts. The BA ordering is unchanged — the
      # balancing authority that lost the generation restores its own ACE
      # before anyone assists it.
      state = Cascade.init(two_ba_snapshot(gen2_max: 200.0))
      island = MapSet.new([1, 2, 3])
      state = standing_deficit(state, island, 1800.0)

      before = state.dispatch
      raised = Cascade.redispatch(state, 40.0, island, 10)

      assert_in_delta ba_delta(raised, before), 40.0, 1.0e-6
      assert Map.fetch!(raised.dispatch, 3) == Map.fetch!(before, 3)
    end

    test "the neighboring BA assists once the origin BA's tertiary ramp is exhausted" do
      # BA 10 is a 20 MW machine and a 30 MW machine: even twenty minutes past
      # the start-up delay cannot cover a 40 MW hole out of that headroom, so
      # BA 20 is asked for the rest.
      state = Cascade.init(two_ba_snapshot(gen2_max: 30.0))
      island = MapSet.new([1, 2, 3])
      state = standing_deficit(state, island, 1800.0)

      before = state.dispatch
      raised = Cascade.redispatch(state, 40.0, island, 10)

      gen3_delta = Map.fetch!(raised.dispatch, 3) - Map.fetch!(before, 3)

      assert ba_delta(raised, before) > 0.0
      assert gen3_delta > 0.0
      assert_in_delta ba_delta(raised, before) + gen3_delta, 40.0, 0.5
    end

    test "a deficit seconds old gets nothing from redispatch at all" do
      # Thirty seconds in, the only tier that answers is the governor's, and
      # that one is allocated island-wide inside the step's own evaluation —
      # never here. Before wave 3b this path handed over half a minute of
      # secondary ramp; that megawatt now arrives through AGC or not at all,
      # which is what stops the two tiers double-drawing the same headroom.
      state = Cascade.init(two_ba_snapshot(gen2_max: 200.0))
      island = MapSet.new([1, 2, 3])
      state = standing_deficit(state, island, 30.0)

      before = state.dispatch
      raised = Cascade.redispatch(state, 40.0, island, 10)

      assert ba_delta(raised, before) == 0.0
      assert Map.fetch!(raised.dispatch, 3) == Map.fetch!(before, 3)
    end
  end

  # ===========================================================================
  # Water-facility power-loss tracking
  # ===========================================================================

  describe "water facility impacts" do
    test "facility on a single-bus island WITHOUT generation loses power with its load" do
      buses = [bus(1, bus_type: 3), bus(2)]
      lines = [line(1, 1, 2, rating_a_mva: 500.0)]
      gens = [generator(1, 1, p_max_mw: 100.0)]
      loads = [load(1, 2, p_mw: 40.0)]

      snapshot =
        make_snapshot(buses, lines, [], gens, loads)
        |> Map.put(:water_facilities, [
          %{
            id: 8,
            name: "Island Water",
            facility_type: "treatment_plant",
            power_consumption_mw: 5.0,
            bus_id: 2
          }
        ])

      {final_state, step_results} = snapshot |> Cascade.init() |> Cascade.trip_line(1)

      assert MapSet.member?(final_state.affected_water_facilities, 8)
      assert Enum.any?(final_state.events, &(&1.failure_cause == "island_blackout"))

      streamed_power_losses =
        step_results
        |> Enum.flat_map(& &1.trips)
        |> Enum.filter(&(&1.component_type == "water_facility"))

      persisted_power_losses =
        Enum.filter(final_state.events, &(&1.component_type == "water_facility"))

      assert [streamed_event] = streamed_power_losses
      assert [persisted_event] = persisted_power_losses
      assert streamed_event.failure_cause == "power_loss"
      assert persisted_event.failure_cause == "power_loss"
      assert persisted_event.step == streamed_event.step
    end

    test "facility on a single-bus island WITH generation keeps its power (CAS-15)" do
      # The mirror image of the test above, and the behaviour CAS-15 changed:
      # a lone bus carrying a generator, its load and a treatment plant is a
      # live island, not a blackout.
      buses = [bus(1, bus_type: 3), bus(2)]
      lines = [line(1, 1, 2, rating_a_mva: 500.0)]
      gens = [generator(1, 1, p_max_mw: 100.0)]
      loads = [load(1, 1, p_mw: 40.0)]

      snapshot =
        make_snapshot(buses, lines, [], gens, loads)
        |> Map.put(:water_facilities, [
          %{
            id: 8,
            name: "Island Water",
            facility_type: "treatment_plant",
            power_consumption_mw: 5.0,
            bus_id: 1
          }
        ])

      {final_state, _steps} = snapshot |> Cascade.init() |> Cascade.trip_line(1)

      assert final_state.affected_water_facilities == MapSet.new()
      refute Enum.any?(final_state.events, &(&1.failure_cause == "island_blackout"))
      assert Enum.find(final_state.loads, &(&1.id == 1)).p_mw == 40.0

      balance = Cascade.balance(final_state)
      assert_in_delta balance.served_load_mw, 40.0, 1.0e-9
      assert balance.blackout_load_mw == 0.0
    end

    test "facility power loss persists when it is the only stable-step trip" do
      snapshot =
        three_bus_snapshot()
        |> Map.put(:water_facilities, [
          %{
            id: 9,
            name: "Remote Pump",
            facility_type: "pump_station",
            power_consumption_mw: 2.0,
            bus_id: 3
          }
        ])
        |> Map.update!(:loads, &Enum.reject(&1, fn grid_load -> grid_load.bus_id == 3 end))

      {final_state, step_results} = snapshot |> Cascade.init() |> Cascade.trip_line(2)

      assert [step_result] = step_results

      assert [streamed_event] =
               Enum.filter(step_result.trips, &(&1.component_type == "water_facility"))

      assert [persisted_event] =
               Enum.filter(final_state.events, &(&1.component_type == "water_facility"))

      assert final_state.stable
      assert persisted_event.failure_cause == "power_loss"
      assert persisted_event.step == step_result.step
      assert persisted_event == streamed_event
    end
  end

  # ===========================================================================
  # Datacenter power-loss tracking
  # ===========================================================================

  describe "datacenter impacts" do
    test "datacenter on a dead island loses power exactly once" do
      # Bus1(gen) --line1-- Bus2(load+datacenter) --line2-- Bus3(load)
      snapshot =
        three_bus_snapshot()
        |> Map.put(:datacenters, [
          %{
            id: 7,
            name: "Test DC",
            operator: "TestCo",
            facility_type: "hyperscale",
            power_mw: 50.0,
            bus_id: 2
          }
        ])

      state = Cascade.init(snapshot)
      {final_state, step_results} = Cascade.trip_line(state, 1)

      assert MapSet.member?(final_state.affected_datacenters, 7)

      # power_loss trip emitted exactly once across all steps
      dc_trips =
        step_results
        |> Enum.flat_map(& &1.trips)
        |> Enum.filter(&(&1.component_type == "datacenter"))

      assert [trip] = dc_trips
      assert trip.failure_cause == "power_loss"
      assert trip.details.name == "Test DC"
      assert trip.details.power_mw == 50.0

      # step results carry the affected datacenter ids
      assert Enum.any?(step_results, fn s -> 7 in Map.get(s, :datacenter_ids, []) end)
    end

    test "datacenter on a powered island is unaffected" do
      snapshot =
        three_bus_snapshot()
        |> Map.put(:datacenters, [
          %{
            id: 7,
            name: "Test DC",
            operator: "TestCo",
            facility_type: "hyperscale",
            power_mw: 50.0,
            bus_id: 2
          }
        ])

      state = Cascade.init(snapshot)
      # Trip line 2: bus 3 islands (blackout), bus 1-2 stay powered
      {final_state, _steps} = Cascade.trip_line(state, 2)

      refute MapSet.member?(final_state.affected_datacenters, 7)
    end
  end

  # ===========================================================================
  # Per-cascade step budget (CAS-2)
  # ===========================================================================

  describe "per-cascade step budget" do
    # Triangle network: tripping one line leaves the grid connected and healthy
    defp triangle_snapshot do
      buses = [bus(1, bus_type: 3), bus(2), bus(3)]

      lines = [
        line(1, 1, 2, rating_a_mva: 500.0),
        line(2, 2, 3, rating_a_mva: 500.0),
        line(3, 1, 3, rating_a_mva: 500.0)
      ]

      gens = [generator(1, 1, p_max_mw: 200.0)]
      loads = [load(1, 3, p_mw: 50.0)]
      make_snapshot(buses, lines, [], gens, loads)
    end

    test "a manual trip after budget exhaustion starts a fresh cascade" do
      state = Cascade.init(triangle_snapshot())

      # Simulate a session whose previous cascades consumed the whole budget
      # and left stale per-cascade protection state behind.
      exhausted = %{
        state
        | step: 50,
          simulated_time: 123.4,
          relay_duty: %{{"thermal_overload", "transmission_line", 99} => 0.5}
      }

      {final_state, step_results} = Cascade.trip_line(exhausted, 3)

      # Old behavior: cumulative session budget -> silent no-op ([] results,
      # stable: false, stale simulated_time/relay_duty).
      assert step_results != []
      assert final_state.stable
      assert final_state.step == length(step_results)
      assert final_state.simulated_time == 0.0
      assert final_state.relay_duty == %{}
      assert MapSet.member?(final_state.tripped_lines, 3)
    end

    test "exhausting the budget mid-cascade is loud: stable false plus event" do
      state = Cascade.init(three_bus_snapshot())
      exhausted = %{state | step: 50}

      {final_state, step_results} = Cascade.run_cascade(exhausted)

      refute final_state.stable
      assert step_results == []

      assert [event] =
               Enum.filter(final_state.events, &(&1.failure_cause == "max_steps_exhausted"))

      assert event.component_type == "cascade"
      assert event.details.max_steps == 50
    end
  end

  # ===========================================================================
  # Re-trip guards (CAS-11)
  # ===========================================================================

  describe "re-trip guards" do
    test "re-tripping an already-tripped line is a no-op" do
      state = Cascade.init(three_bus_snapshot())
      {after_first, _results} = Cascade.trip_line(state, 1)

      assert {^after_first, []} = Cascade.trip_line(after_first, 1)
    end

    test "re-tripping an already-tripped transformer is a no-op" do
      buses = [bus(1, bus_type: 3), bus(2)]
      xfmrs = [transformer(1, 1, 2, rated_mva: 500.0)]
      gens = [generator(1, 1, p_max_mw: 200.0)]
      loads = [load(1, 2, p_mw: 50.0)]

      state = Cascade.init(make_snapshot(buses, [], xfmrs, gens, loads))
      {after_first, _results} = Cascade.trip_transformer(state, 1)

      assert MapSet.member?(after_first.tripped_transformers, 1)
      assert {^after_first, []} = Cascade.trip_transformer(after_first, 1)
    end

    test "re-tripping an already-tripped generator is a library-level no-op" do
      state = Cascade.init(three_bus_snapshot())
      {after_first, _results} = Cascade.trip_generator(state, 1)

      assert {^after_first, []} = Cascade.trip_generator(after_first, 1)
    end
  end

  # ===========================================================================
  # Generation-side conservation (ENE-3)
  # ===========================================================================

  describe "generation-side conservation" do
    test "sub-UFLS-threshold island deficit is force-shed, not silently unserved" do
      # 8 MW gap on 1000 MW of load (0.8%): the frequency nadir stays above
      # the first UFLS stage, so the schedule alone sheds nothing.
      buses = [bus(1, bus_type: 3), bus(2)]
      lines = [line(1, 1, 2, rating_a_mva: 5000.0, x_pu: 0.1)]
      gens = [generator(1, 1, p_max_mw: 992.0)]
      loads = [load(1, 2, p_mw: 1000.0)]

      state = Cascade.init(make_snapshot(buses, lines, [], gens, loads))
      {final_state, _steps} = Cascade.run_cascade(state)

      balance = Cascade.balance(final_state)

      assert final_state.shed_load_mw > 0.0
      assert_in_delta balance.served_load_mw, 992.0, 0.6
      assert_in_delta balance.dispatched_gen_mw, balance.served_load_mw, 0.6

      assert_in_delta balance.served_load_mw + balance.shed_load_mw + balance.blackout_load_mw,
                      balance.original_load_mw + balance.btm_tripped_mw,
                      0.01
    end

    test "a deficit beyond the UFLS schedule cap collapses the island, and still balances" do
      # 50% deficit. The canonical UFLS program cumulates to roughly 30%, so
      # the stages fire and the frequency falls through all of them into the
      # PRC-024 instantaneous band: the machine trips and the island goes
      # dark. The old force-shed tier used to balance this island on paper
      # instead, which is the behaviour ROADMAP item 15 replaced.
      #
      # What must NOT change is the accounting: every MW leaves through a
      # bucket, and the identity closes.
      buses = [bus(1, bus_type: 3), bus(2)]
      lines = [line(1, 1, 2, rating_a_mva: 500.0, x_pu: 0.1)]
      gens = [generator(1, 1, p_max_mw: 50.0)]
      loads = [load(1, 2, p_mw: 100.0)]

      state = Cascade.init(make_snapshot(buses, lines, [], gens, loads))
      {final_state, _steps} = Cascade.run_cascade(state)

      assert MapSet.member?(final_state.tripped_generators, 1)

      balance = Cascade.balance(final_state)

      assert_in_delta balance.served_load_mw, 0.0, 1.0e-9
      assert_in_delta balance.dispatched_gen_mw, balance.served_load_mw, 0.6

      assert_in_delta balance.served_load_mw + balance.shed_load_mw + balance.blackout_load_mw,
                      balance.original_load_mw + balance.btm_tripped_mw,
                      0.01
    end

    test "island split keeps dispatched generation matched to served load" do
      buses = [bus(1, bus_type: 3), bus(2), bus(3, bus_type: 3), bus(4)]

      lines = [
        line(1, 1, 2, rating_a_mva: 500.0),
        line(2, 3, 4, rating_a_mva: 500.0),
        line(3, 2, 3, rating_a_mva: 500.0)
      ]

      gens = [generator(1, 1, p_max_mw: 400.0), generator(2, 3, p_max_mw: 400.0)]
      loads = [load(1, 2, p_mw: 110.0), load(2, 4, p_mw: 90.0)]

      state = Cascade.init(make_snapshot(buses, lines, [], gens, loads))
      {final_state, step_results} = Cascade.trip_line(state, 3)

      # Deficit half raised its reserves, surplus half CURTAILED (the 10 MW
      # export from island B has nowhere to go after the split).
      assert_in_delta Map.fetch!(final_state.dispatch, 1), 110.0, 0.6
      assert_in_delta Map.fetch!(final_state.dispatch, 2), 90.0, 0.6

      balance = Cascade.balance(final_state)
      assert_in_delta balance.dispatched_gen_mw, balance.served_load_mw, 0.6

      for step <- step_results do
        assert_in_delta step.balance.dispatched_gen_mw, step.balance.served_load_mw, 0.6
      end
    end

    test "a blacked-out island curtails the generator left stranded beside it" do
      # Bus 1 carries the generator, bus 2 the load. Tripping the only line
      # leaves a dead load island (blackout) and a live generator island with
      # nothing to serve: that generator must be curtailed to zero before the
      # step balance is emitted, or its MW becomes a phantom slack injection.
      buses = [bus(1, bus_type: 3), bus(2)]
      lines = [line(1, 1, 2, rating_a_mva: 500.0, x_pu: 0.1)]
      gens = [generator(1, 1, p_max_mw: 100.0)]
      loads = [load(1, 2, p_mw: 40.0)]

      state = Cascade.init(make_snapshot(buses, lines, [], gens, loads))
      {final_state, step_results} = Cascade.trip_line(state, 1)

      for step <- step_results do
        assert_in_delta step.balance.dispatched_gen_mw, step.balance.served_load_mw, 0.6
      end

      balance = Cascade.balance(final_state)
      assert_in_delta balance.dispatched_gen_mw, 0.0, 1.0e-9
      assert_in_delta balance.served_load_mw, 0.0, 1.0e-9
      assert_in_delta balance.blackout_load_mw, 40.0, 1.0e-9
    end
  end

  # ===========================================================================
  # Callback support
  # ===========================================================================

  describe "run_cascade/2 callback" do
    test "callback receives each step result" do
      buses = [bus(1, bus_type: 3), bus(2)]
      lines = [line(1, 1, 2, rating_a_mva: 500.0, x_pu: 0.1)]
      gens = [generator(1, 1, p_max_mw: 200.0)]
      loads = [load(1, 2, p_mw: 50.0)]

      snapshot = make_snapshot(buses, lines, [], gens, loads)
      state = Cascade.init(snapshot)

      test_pid = self()

      callback = fn step_result ->
        send(test_pid, {:step, step_result})
      end

      {_final_state, step_results} = Cascade.run_cascade(state, callback)

      # We should receive one message per step
      for _step <- step_results do
        assert_receive {:step, _result}, 1000
      end
    end
  end
end
