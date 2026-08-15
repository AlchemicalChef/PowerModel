defmodule PowerModel.Failure.CascadeFrequencyTest do
  @moduledoc """
  Persistent island frequency state, generator protection feedback, the
  cascade clock and the ramp-limited reserve tiers, end to end through
  `PowerModel.Failure.Cascade` (ROADMAP items 15 and 16, REVIEW CAS-16).

  These are the four mechanisms that turn a sequence of independent snapshots
  into a cascade that COMPOUNDS: a second disturbance starts where the first
  one left the frequency, machines that cannot ride the excursion out leave
  the fleet inside the same step, time actually passes, and reserves can only
  arrive as fast as the fleet ramps.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Failure.Cascade

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp bus(id, type \\ 1) do
    %{id: id, bus_type: type, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0}
  end

  # Ratings are deliberately enormous: these tests are about frequency, and a
  # thermal trip would change the subject.
  defp line(id, from, to) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      voltage_kv: 138.0,
      r_pu: 0.01,
      x_pu: 0.1,
      b_pu: 0.02,
      rating_a_mva: 100_000.0
    }
  end

  defp gen(id, bus_id, p_max_mw, fuel \\ "NG") do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: p_max_mw,
      capacity_factor: 1.0,
      fuel_type: fuel,
      q_max_mvar: 5_000.0,
      q_min_mvar: -5_000.0
    }
  end

  defp load(id, bus_id, p_mw), do: %{id: id, bus_id: bus_id, p_mw: p_mw, q_mvar: 0.0}

  # ---------------------------------------------------------------------------
  # Observation helpers
  # ---------------------------------------------------------------------------

  # The lowest frequency any island reached, read off the frequency history
  # the cascade keeps for generator protection.
  defp nadir(state) do
    case Enum.flat_map(state.island_states, & &1.exposure) do
      [] -> 60.0
      records -> records |> Enum.map(& &1.frequency) |> Enum.min()
    end
  end

  defp shed_mw(state) do
    state.events
    |> Enum.filter(&(&1.failure_cause == "ufls_shed"))
    |> Enum.map(&Map.get(&1.details, :shed_mw, 0.0))
    |> Enum.sum()
  end

  defp causes(state, step), do: state.events |> Enum.filter(&(&1.step == step))

  # ===========================================================================
  # Item 15: the state persists, and disturbances compound
  # ===========================================================================

  describe "persistent island frequency state" do
    # Six identical machines carrying 1000 MW; losing one is a sixth of the
    # island's generation, deep enough to matter and shallow enough that the
    # island survives it.
    defp six_unit_island do
      %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2)],
        transformers: [],
        generators: for(i <- 1..6, do: gen(i, 1, 400.0)),
        loads: [load(1, 2, 1000.0)]
      }
    end

    test "two trips two events apart reach a worse nadir than either alone" do
      # The whole point of item 15: before it, every disturbance restarted at
      # 60.0 Hz with untouched governors and every UFLS stage rearmed, so a
      # cascade could never build.
      {after_first, _} = six_unit_island() |> Cascade.init() |> Cascade.trip_generator(1)
      {compounded, _} = Cascade.trip_generator(after_first, 2)

      {independent, _} = six_unit_island() |> Cascade.init() |> Cascade.trip_generator(2)

      # The same second trip, evaluated from a depressed frequency with the
      # governors already deployed, goes strictly deeper...
      assert nadir(compounded) < nadir(independent)

      # ...and takes strictly more customers with it.
      assert shed_mw(compounded) > shed_mw(independent)

      # The first trip alone is the control: identical to the second alone,
      # because the two machines are identical.
      assert_in_delta nadir(after_first), nadir(independent), 1.0e-9
    end

    test "the island carries its frequency state, and its governors, forward" do
      {state, _} = six_unit_island() |> Cascade.init() |> Cascade.trip_generator(1)

      assert [record] = state.island_states
      assert record.buses == MapSet.new([1, 2])
      assert record.frequency_state != nil

      # The island did not return to 60.0 Hz: it settled somewhere below it,
      # holding the gap with governor output, and that is where the next
      # disturbance will start from.
      assert record.frequency_state.frequency < 60.0
      assert record.frequency_state.time > 0.0
      assert map_size(record.frequency_state.gov_state) > 0
    end

    test "an island with no disturbance at all runs no frequency simulation" do
      snapshot = %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2)],
        transformers: [],
        generators: [gen(1, 1, 1000.0)],
        loads: [load(1, 2, 500.0)]
      }

      {state, steps} = snapshot |> Cascade.init() |> Cascade.run_cascade()

      assert [record] = state.island_states
      assert record.frequency_state == nil
      assert record.exposure == []
      assert Enum.all?(steps, &(&1.simulated_time == 0.0))
    end

    test "a split shares the parent's state out by load, and both halves keep it" do
      # One island until line 3 opens, then two: 900 MW of load on one side,
      # 100 MW on the other. Both were synchronised an instant earlier, so
      # both carry the excursion forward; the cumulative megawatts are shared
      # by load so the small half is not handed the big half's shed.
      snapshot = %{
        buses: [bus(1, 3), bus(2), bus(3, 3), bus(4)],
        lines: [line(1, 1, 2), line(2, 3, 4), line(3, 2, 3)],
        transformers: [],
        generators: [gen(1, 1, 1200.0), gen(2, 3, 300.0), gen(3, 1, 400.0)],
        loads: [load(1, 2, 900.0), load(2, 4, 100.0)]
      }

      # Open a deficit first, so there is a state worth inheriting. Both
      # halves keep a machine, so both stay alive through the split.
      {state, _} = snapshot |> Cascade.init() |> Cascade.trip_generator(3)
      assert [%{frequency_state: parent}] = state.island_states
      assert parent != nil

      # ...then split the island.
      {split, _} = Cascade.trip_line(state, 3)

      big = Enum.find(split.island_states, &MapSet.member?(&1.buses, 2))
      small = Enum.find(split.island_states, &MapSet.member?(&1.buses, 4))

      assert big.frequency_state != nil
      assert small.frequency_state != nil

      # Neither half restarted: both carry the parent's frequency clock
      # forward rather than beginning a fresh one at 60.0 Hz.
      assert big.frequency_state.time >= parent.time
      assert small.frequency_state.time >= parent.time
      assert small.frequency_state.time > 0.0

      # The cumulative megawatts ARE apportioned: the 100 MW half does not
      # inherit the 900 MW half's shed load as its damping base.
      assert parent.cumulative_shed_mw > 0.0
      assert small.frequency_state.cumulative_shed_mw < big.frequency_state.cumulative_shed_mw
    end
  end

  # ===========================================================================
  # Item 15: generator protection feeds back into the same step
  # ===========================================================================

  describe "generator frequency protection inside the step" do
    test "an island driven below 57 Hz loses its machines in the step that drove it" do
      # 40% of the island's generation goes at once. The UFLS program reaches
      # ~27% of connected load and no further, so the frequency falls through
      # every stage into the PRC-024 instantaneous band.
      snapshot = %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2)],
        transformers: [],
        generators: [gen(1, 1, 400.0), gen(2, 1, 600.0)],
        loads: [load(1, 2, 1000.0)]
      }

      {state, steps} = snapshot |> Cascade.init() |> Cascade.trip_generator(1)

      [trip] = Enum.filter(state.events, &(&1.failure_cause == "underfrequency_trip"))
      assert trip.component_type == "generator"
      assert trip.component_id == 2
      assert trip.details.band_hz == 57.0

      # SAME STEP: the machine's trip, the island going dark and the balance
      # that reports it all carry the same step number.
      blackouts = Enum.filter(state.events, &(&1.failure_cause == "island_blackout"))
      assert blackouts != []
      assert Enum.all?(blackouts, &(&1.step == trip.step))

      same_step = causes(state, trip.step) |> Enum.map(& &1.failure_cause) |> Enum.uniq()
      assert "generator_frequency_trips" in same_step

      # The step's own balance already shows the generation gone.
      step = Enum.find(steps, &(&1.step == trip.step))
      assert_in_delta step.balance.dispatched_gen_mw, 0.0, 1.0e-9
      assert_in_delta step.balance.served_load_mw, 0.0, 1.0e-9

      # And the island really did lose generation it never started losing.
      assert MapSet.member?(state.tripped_generators, 2)
    end

    test "an island that rides the excursion out keeps every machine" do
      # The same island, a smaller loss: the stages fire, the frequency is
      # arrested above 57 Hz, and nothing else trips.
      snapshot = %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2)],
        transformers: [],
        generators: [gen(1, 1, 150.0), gen(2, 1, 2000.0)],
        loads: [load(1, 2, 1000.0)]
      }

      {state, _steps} = snapshot |> Cascade.init() |> Cascade.trip_generator(1)

      assert state.tripped_generators == MapSet.new([1])
      assert Enum.filter(state.events, &(&1.failure_cause == "underfrequency_trip")) == []
      assert nadir(state) > 57.0
    end

    test "the aggregated island event stands beside the per-unit trips" do
      snapshot = %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2)],
        transformers: [],
        generators: [gen(1, 1, 400.0), gen(2, 1, 300.0), gen(3, 1, 300.0)],
        loads: [load(1, 2, 1000.0)]
      }

      {state, _steps} = snapshot |> Cascade.init() |> Cascade.trip_generator(1)

      units = Enum.filter(state.events, &(&1.failure_cause == "underfrequency_trip"))
      assert length(units) == 2
      assert Enum.all?(units, &(&1.component_type == "generator"))

      [aggregate] =
        Enum.filter(state.events, &(&1.failure_cause == "generator_frequency_trips"))

      assert aggregate.component_type == "island"
      assert aggregate.component_id == 1
      assert aggregate.details.unit_count == 2
      assert aggregate.details.trip_cause == "underfrequency_trip"
      assert aggregate.details.band_hz == 57.0
      assert aggregate.details.tripped_mw > 0.0
      assert Enum.all?(units, &(&1.step == aggregate.step))
    end
  end

  # ===========================================================================
  # Item 15: the ordering the whole step hangs on
  # ===========================================================================

  describe "step ordering" do
    test "reserves act before the trajectory, so a covered deficit never reaches UFLS" do
      # A loss entirely inside what the governors deliver in the nadir window:
      # if the trajectory ran BEFORE the reserves, this island would shed.
      snapshot = %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2)],
        transformers: [],
        generators: [gen(1, 1, 60.0), gen(2, 1, 2000.0)],
        loads: [load(1, 2, 1000.0)]
      }

      {state, _} = snapshot |> Cascade.init() |> Cascade.trip_generator(1)

      assert shed_mw(state) == 0.0
      assert nadir(state) > 59.3
      assert map_size(state.primary_reserve) > 0
    end

    test "rooftop inverters and generator relays read the same trajectory" do
      # Both protections are evaluated against ONE segment, so the frequency
      # the rooftop reacted to is the frequency the relays saw. Here the
      # island goes deep enough for both to operate in the same step.
      snapshot = %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2)],
        transformers: [],
        generators: [gen(1, 1, 400.0), gen(2, 1, 600.0)],
        loads: [load(1, 2, 1000.0)],
        btm_solar: [
          %{
            bus_id: 2,
            sector: "residential",
            capacity_mw: 100.0,
            output_mw: 50.0,
            legacy_fraction: 0.30
          }
        ]
      }

      {state, _} = snapshot |> Cascade.init() |> Cascade.trip_generator(1)

      [btm] = Enum.filter(state.events, &(&1.failure_cause == "btm_trip"))
      [relay | _] = Enum.filter(state.events, &(&1.failure_cause == "underfrequency_trip"))

      assert btm.step == relay.step
      assert btm.details.nadir <= 59.3

      # The rooftop went first — it reacted to the frequency the island
      # reached BEFORE anything else left — and the relays operated on the
      # excursion that included the rooftop's own departure.
      assert relay.details.frequency_hz <= btm.details.nadir
    end

    test "the extended conservation identity survives generator trips" do
      # Generator trips move megawatts between served, shed and blackout
      # through the paths that already existed; the identity's SHAPE is
      # unchanged, rooftop source term included.
      snapshot = %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2)],
        transformers: [],
        generators: [gen(1, 1, 400.0), gen(2, 1, 600.0)],
        loads: [load(1, 2, 1000.0)],
        btm_solar: [
          %{
            bus_id: 2,
            sector: "residential",
            capacity_mw: 100.0,
            output_mw: 50.0,
            legacy_fraction: 0.30
          }
        ]
      }

      {state, steps} = snapshot |> Cascade.init() |> Cascade.trip_generator(1)

      for step <- steps do
        b = step.balance

        assert_in_delta b.served_load_mw + b.shed_load_mw + b.blackout_load_mw,
                        b.original_load_mw + b.btm_tripped_mw,
                        0.01
      end

      b = Cascade.balance(state)

      assert_in_delta b.served_load_mw + b.shed_load_mw + b.blackout_load_mw,
                      b.original_load_mw + b.btm_tripped_mw,
                      0.01

      assert b.btm_tripped_mw > 0.0
      assert MapSet.size(state.tripped_generators) > 1
    end
  end

  # ===========================================================================
  # Item 16: ramp-limited reserve tiers
  # ===========================================================================

  describe "ramp-limited reserve tiers" do
    # Identical islands, identical operating points, identical nameplate
    # headroom (1,070 MW idle on the surviving machine). The only difference
    # is what the technology can deliver in the ten seconds that decide the
    # nadir.
    defp fleet_island(fuel) do
      %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2)],
        transformers: [],
        generators: [gen(1, 1, 150.0, fuel), gen(2, 1, 2000.0, fuel)],
        loads: [load(1, 2, 1000.0)]
      }
    end

    test "a slow fleet sheds where a fast one does not, on the same headroom" do
      {coal, _} = fleet_island("BIT") |> Cascade.init() |> Cascade.trip_generator(1)
      {hydro, _} = fleet_island("WAT") |> Cascade.init() |> Cascade.trip_generator(1)

      # Same island, same 70 MW hole, same 1,070 MW of idle nameplate.
      assert_in_delta Cascade.balance(coal).original_load_mw,
                      Cascade.balance(hydro).original_load_mw,
                      1.0e-9

      # The coal fleet reaches 2% of nameplate in the nadir window and sheds
      # customers for it; the hydro fleet reaches 15% and does not.
      assert shed_mw(coal) > 0.0
      assert shed_mw(hydro) == 0.0
      assert nadir(coal) <= 59.3
      assert nadir(hydro) > 59.3
    end

    test "the idle nameplate is real, and it is not the point" do
      {coal, _} = fleet_island("BIT") |> Cascade.init() |> Cascade.trip_generator(1)

      surviving = Enum.find(coal.generators, &(&1.id == 2))
      dispatched = Map.fetch!(coal.dispatch, 2)

      # Over a gigawatt of headroom sat on the machine while the island shed.
      assert surviving.p_max_mw - dispatched > 1_000.0
      assert shed_mw(coal) > 0.0
    end

    test "the deficit clock is what the tiers ramp on" do
      {state, _} = fleet_island("BIT") |> Cascade.init() |> Cascade.trip_generator(1)

      # The island still holds a sustained gap (the governors are holding it),
      # so its deficit clock is running and the slower tiers keep working.
      assert [record] = state.island_states

      if map_size(state.primary_reserve) > 0 do
        assert is_number(record.deficit_since_s)
      else
        assert record.deficit_since_s == nil
      end
    end
  end

  # ===========================================================================
  # CAS-16: the clock
  # ===========================================================================

  describe "the cascade clock" do
    test "a step whose only trips are frequency-driven still advances time" do
      # REVIEW CAS-16: this step used to advance 0 s, which made every
      # ramp-limited or time-aware mechanism downstream meaningless.
      snapshot = %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2)],
        transformers: [],
        generators: [gen(1, 1, 1000.0)],
        loads: [load(1, 2, 1100.0)]
      }

      {_state, steps} = snapshot |> Cascade.init() |> Cascade.run_cascade()

      [first | _] = steps
      assert Enum.any?(first.trips, &(&1.failure_cause == "ufls_shed"))
      assert first.simulated_time > 0.0

      # Monotone, and bounded by one frequency window per step.
      times = Enum.map(steps, & &1.simulated_time)
      assert times == Enum.sort(times)

      for {a, b} <- Enum.zip(times, tl(times)) do
        assert b - a <= 30.0 + 1.0e-9
      end
    end

    test "a quiet network's clock does not move at all" do
      snapshot = %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2)],
        transformers: [],
        generators: [gen(1, 1, 1000.0)],
        loads: [load(1, 2, 500.0)]
      }

      {state, steps} = snapshot |> Cascade.init() |> Cascade.run_cascade()

      assert state.simulated_time == 0.0
      assert Enum.all?(steps, &(&1.simulated_time == 0.0))
    end

    test "the clock advance is the trajectory's settling time, not the window" do
      # A disturbance that settles well inside the 30 s window advances the
      # clock by the time it actually took.
      snapshot = %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2)],
        transformers: [],
        generators: [gen(1, 1, 60.0), gen(2, 1, 2000.0)],
        loads: [load(1, 2, 1000.0)]
      }

      {_state, steps} = snapshot |> Cascade.init() |> Cascade.trip_generator(1)

      advance = List.first(steps).simulated_time
      assert advance > 0.0
      assert advance < 30.0
    end
  end
end
