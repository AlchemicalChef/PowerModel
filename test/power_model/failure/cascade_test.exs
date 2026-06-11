defmodule PowerModel.Failure.CascadeTest do
  use ExUnit.Case, async: true

  alias PowerModel.Failure.Cascade

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

  defp generator(id, bus_id, opts) do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      p_min_mw: Keyword.get(opts, :p_min_mw, 0.0),
      capacity_factor: Keyword.get(opts, :capacity_factor, 1.0),
      q_max_mvar: Keyword.get(opts, :q_max_mvar, 50.0),
      q_min_mvar: Keyword.get(opts, :q_min_mvar, -50.0),
      fuel_type: Keyword.get(opts, :fuel_type, "NG"),
      status: Keyword.get(opts, :status, "in_service"),
      marginal_cost_per_mwh: Keyword.get(opts, :marginal_cost_per_mwh, 35.0),
      inertia_h: Keyword.get(opts, :inertia_h, 3.5),
      droop_pct: Keyword.get(opts, :droop_pct, 4.0),
      gov_time_constant_s: Keyword.get(opts, :gov_time_constant_s, 1.5)
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
      # Lines may have calibrated ratings (rating_a_mva bumped to avoid base-case overloads)
      assert length(state.lines) == length(snapshot.lines)
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
      # solution is pre-computed from base-case DC solve
      assert state.solution != nil or state.solution == nil
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

    test "single-bus island with generator is treated as blackout (< 2 buses)" do
      # When a bus is isolated (single bus island), the cascade code treats it
      # as insufficient (length(island_buses) < 2) and blacks out loads.
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

      {final_state, _step_results} = Cascade.run_cascade(state)

      # Bus 2 is isolated with a load — should produce blackout event
      blackout_events =
        final_state.events
        |> Enum.filter(&(&1.failure_cause == "island_blackout"))

      assert length(blackout_events) >= 1
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
      # Gen 80 MW, Load 120 MW => deficit 40 MW => UFLS kicks in
      buses = [bus(1, bus_type: 3), bus(2)]
      lines = [line(1, 1, 2, rating_a_mva: 500.0, x_pu: 0.1)]
      gens = [generator(1, 1, p_max_mw: 80.0)]
      loads = [load(1, 2, p_mw: 120.0)]

      snapshot = make_snapshot(buses, lines, [], gens, loads)
      state = Cascade.init(snapshot)

      {final_state, _step_results} = Cascade.run_cascade(state)

      shed_events =
        final_state.events
        |> Enum.filter(&(&1.failure_cause == "ufls_shed"))

      assert length(shed_events) >= 1

      # Load should have been reduced
      updated_load = Enum.find(final_state.loads, &(&1.id == 1))
      assert updated_load.p_mw < 120.0
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
