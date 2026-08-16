defmodule PowerModel.Failure.BtmTripTest do
  @moduledoc """
  IEEE 1547 behind-the-meter inverter tripping inside the cascade
  (ROADMAP Phase 2.5 item 31).

  The mechanism under test is the one that makes the `:btm_solar` layer worth
  carrying at all: rooftop PV is invisible in the operating point because
  EIA-930 demand is metered net of it, so when legacy (1547-2003) inverters
  must-trip at 59.3 Hz, what appears is not lost generation but **new load** —
  the gross demand that was always sitting behind the meter.

  The pairing these tests pin is the vicious one: the legacy rooftop fleet is
  gone AT 59.3 Hz while the first UFLS stage only arms BELOW it, so UFLS opens
  its breakers on a deficit that the rooftop trip itself deepened.
  """

  use ExUnit.Case, async: false

  alias PowerModel.Failure.Cascade
  alias PowerModel.Grid.BtmSolar

  # ---------------------------------------------------------------------------
  # Fixture builders
  # ---------------------------------------------------------------------------

  defp bus(id, opts \\ []) do
    %{
      id: id,
      bus_type: Keyword.get(opts, :bus_type, 1),
      base_kv: 138.0,
      vm_pu: Keyword.get(opts, :vm_pu, 1.0),
      va_rad: 0.0
    }
  end

  defp line(id, from, to, opts \\ []) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      voltage_kv: 138.0,
      r_pu: 0.01,
      x_pu: 0.1,
      b_pu: 0.02,
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 1_000.0)
    }
  end

  defp generator(id, bus_id, p_max_mw) do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: p_max_mw,
      capacity_factor: 1.0,
      q_max_mvar: 50.0,
      q_min_mvar: -50.0
    }
  end

  defp load(id, bus_id, p_mw) do
    %{id: id, bus_id: bus_id, p_mw: p_mw, q_mvar: 0.0}
  end

  # A snapshot entry as `PowerModel.Grid.BtmSolar.output_at/3` produces it:
  # one row per {bus_id, sector}, output already shaped by the hour's capacity
  # factor, legacy share stamped on every row.
  defp btm(bus_id, output_mw, opts \\ []) do
    entry = %{
      bus_id: bus_id,
      sector: Keyword.get(opts, :sector, "residential"),
      capacity_mw: Keyword.get(opts, :capacity_mw, output_mw * 2.0),
      output_mw: output_mw
    }

    case Keyword.fetch(opts, :legacy_fraction) do
      {:ok, f} -> Map.put(entry, :legacy_fraction, f)
      # Deliberately omitted so the cascade falls back to the configured share.
      :error -> entry
    end
  end

  # Two buses, one generator, one load, one fat line. `available` is nameplate;
  # the initial load-following dispatch starts below it and the cascade raises
  # into the headroom, so the island's deficit is exactly `load - gen`.
  defp island_snapshot(gen_mw, load_mw, btm_entries) do
    %{
      buses: [bus(1, bus_type: 3), bus(2)],
      lines: [line(1, 1, 2)],
      transformers: [],
      generators: [generator(1, 1, gen_mw)],
      loads: [load(1, 2, load_mw)],
      btm_solar: btm_entries
    }
  end

  # ---------------------------------------------------------------------------
  # Observation helpers
  # ---------------------------------------------------------------------------

  defp events(state, cause), do: Enum.filter(state.events, &(&1.failure_cause == cause))

  defp shed_mw(state) do
    state
    |> events("ufls_shed")
    |> Enum.map(&Map.get(&1.details, :shed_mw, 0.0))
    |> Enum.sum()
  end

  defp served_mw(state), do: Enum.sum(Enum.map(state.loads, & &1.p_mw))

  # served + shed + blackout == original + btm_tripped
  defp assert_conserved(state) do
    b = Cascade.balance(state)

    assert_in_delta b.served_load_mw + b.shed_load_mw + b.blackout_load_mw,
                    b.original_load_mw + b.btm_tripped_mw,
                    0.01

    b
  end

  # ===========================================================================
  # The trigger
  # ===========================================================================

  describe "the 59.3 Hz must-trip threshold" do
    test "an island dipping to 59.3 Hz trips exactly the legacy share, as LOAD" do
      # 100 MW of generation against 102 MW of demand: a 2 MW shortfall, which
      # the swing model takes to 59.29 Hz. 40 MW of rooftop sits at the load
      # bus; 30% of it is on 1547-2003 inverters.
      snapshot = island_snapshot(100.0, 102.0, [btm(2, 40.0, legacy_fraction: 0.30)])
      {state, _steps} = Cascade.run_cascade(Cascade.init(snapshot))

      assert [event] = events(state, "btm_trip")
      assert event.component_type == "btm_solar"
      assert event.component_id == 2
      assert_in_delta event.details.tripped_mw, 12.0, 1.0e-9
      assert event.details.bus_count == 1
      assert event.details.nadir <= 59.3

      # The other 70% is 1547-2018 and rides through: 28 MW of rooftop is
      # still generating and still invisible.
      assert_in_delta state.btm_tripped_mw, 12.0, 1.0e-9
      assert state.btm_tripped_buses == MapSet.new([2])
    end

    test "an island whose nadir stays above 59.3 Hz keeps its rooftop, in full daylight" do
      # A 1 MW shortfall bottoms out at 59.41 Hz — above the legacy must-trip
      # point, so the inverters ride through even though 40 MW is flowing.
      snapshot = island_snapshot(100.0, 101.0, [btm(2, 40.0, legacy_fraction: 0.30)])
      {state, _steps} = Cascade.run_cascade(Cascade.init(snapshot))

      assert events(state, "btm_trip") == []
      assert state.btm_tripped_mw == 0.0
      assert state.btm_tripped_buses == MapSet.new()

      # ...and this is not a case where nothing happened: the 1 MW gap is
      # still closed, it is just closed without any rooftop leaving.
      assert shed_mw(state) > 0.0
      assert_conserved(state)
    end

    test "tripping is a load INCREASE at the bus, not a generation removal" do
      snapshot = island_snapshot(100.0, 102.0, [btm(2, 40.0, legacy_fraction: 0.30)])
      state = Cascade.init(snapshot)

      # Nothing was ever materialized for rooftop, so there is no generator to
      # find and none to lose.
      assert length(state.generators) == 1
      {final, _steps} = Cascade.run_cascade(state)
      assert length(final.generators) == 1
      assert final.tripped_generators == MapSet.new()

      # The 12 MW shows up as demand: served + shed must exceed the original
      # 102 MW by exactly the tripped rooftop.
      b = assert_conserved(final)
      assert_in_delta b.served_load_mw + b.shed_load_mw, 102.0 + 12.0, 0.01
    end
  end

  # ===========================================================================
  # The vicious pairing
  # ===========================================================================

  describe "the vicious pairing: rooftop sheds before the first UFLS stage arms" do
    test "UFLS is evaluated on the deficit the rooftop trip deepened" do
      snapshot = island_snapshot(100.0, 102.0, [btm(2, 40.0, legacy_fraction: 0.30)])
      {state, _steps} = Cascade.run_cascade(Cascade.init(snapshot))

      [btm_event] = events(state, "btm_trip")
      shed_events = events(state, "ufls_shed")
      assert shed_events != []

      ufls_nadirs =
        shed_events
        |> Enum.map(&Map.get(&1.details, :frequency_nadir))
        |> Enum.filter(&is_number/1)

      assert ufls_nadirs != []

      # The ordering, stated as arithmetic: the inverters reacted to the
      # frequency the island reached with its rooftop still on, and UFLS then
      # opened on a strictly WORSE frequency — the one the trip produced.
      for nadir <- ufls_nadirs do
        assert nadir < btm_event.details.nadir
      end
    end

    test "a 2 MW shortfall sheds 7x more customer load once 12 MW of rooftop leaves" do
      # The amplification, measured against the same island with the legacy
      # share set to zero (every inverter 1547-2018, all riding through).
      with_legacy =
        island_snapshot(100.0, 102.0, [btm(2, 40.0, legacy_fraction: 0.30)])
        |> Cascade.init()
        |> Cascade.run_cascade()
        |> elem(0)

      without_legacy =
        island_snapshot(100.0, 102.0, [btm(2, 40.0, legacy_fraction: 0.0)])
        |> Cascade.init()
        |> Cascade.run_cascade()
        |> elem(0)

      assert events(without_legacy, "btm_trip") == []
      assert without_legacy.btm_tripped_mw == 0.0

      # 2 MW short of generation, 14 MW of customers in the dark: the event's
      # consequence is 7x its physical size, and 12 of those 14 MW are there
      # only because the rooftop fleet left.
      assert_in_delta shed_mw(without_legacy), 2.0, 0.01
      assert_in_delta shed_mw(with_legacy), 14.0, 0.01

      # It reaches a deeper point on the UFLS program, not just a bigger
      # fraction of the same stage: the pre-trip nadir arms stage 1 only, the
      # post-trip nadir arms stage 2 as well.
      assert ufls_stage(without_legacy) == 1
      assert ufls_stage(with_legacy) == 2

      # Grid-served load is NOT where the harm shows up — an island always
      # converges to serving exactly the generation it has, with or without
      # the trip. What changes is how many customers are outside that number.
      assert_in_delta served_mw(with_legacy), served_mw(without_legacy), 1.0e-9

      assert_conserved(with_legacy)
      assert_conserved(without_legacy)
    end

    test "each tripped megawatt of rooftop is paid for one-for-one in load shed" do
      # Not a coincidence but the conservation identity, read sideways: with
      # the island converging to the same served MW either way, the whole
      # `btm_tripped` source term has to leave through the shed bucket.
      for fraction <- [0.15, 0.30, 0.60] do
        with_legacy =
          island_snapshot(100.0, 102.0, [btm(2, 40.0, legacy_fraction: fraction)])
          |> Cascade.init()
          |> Cascade.run_cascade()
          |> elem(0)

        without_legacy =
          island_snapshot(100.0, 102.0, [])
          |> Cascade.init()
          |> Cascade.run_cascade()
          |> elem(0)

        assert_in_delta with_legacy.btm_tripped_mw, 40.0 * fraction, 1.0e-9

        assert_in_delta shed_mw(with_legacy) - shed_mw(without_legacy),
                        with_legacy.btm_tripped_mw,
                        0.01
      end
    end

    test "amplification scales with the legacy share" do
      results =
        for fraction <- [0.0, 0.15, 0.30, 0.60] do
          state =
            island_snapshot(100.0, 102.0, [btm(2, 40.0, legacy_fraction: fraction)])
            |> Cascade.init()
            |> Cascade.run_cascade()
            |> elem(0)

          assert_conserved(state)
          {shed_mw(state), ufls_nadir(state)}
        end

      sheds = Enum.map(results, &elem(&1, 0))
      nadirs = Enum.map(results, &elem(&1, 1))

      # Measured: 2.0, 8.0, 14.0, 26.0 MW shed as the legacy share rises.
      assert sheds == Enum.sort(sheds)
      assert Enum.uniq(sheds) == sheds

      # ...against a monotonically deeper frequency excursion, which is the
      # mechanism doing the amplifying.
      assert nadirs == nadirs |> Enum.sort() |> Enum.reverse()
      assert Enum.uniq(nadirs) == nadirs
    end
  end

  defp ufls_nadir(state) do
    state
    |> events("ufls_shed")
    |> Enum.map(&Map.get(&1.details, :frequency_nadir))
    |> Enum.filter(&is_number/1)
    |> Enum.min(fn -> 60.0 end)
  end

  defp ufls_stage(state) do
    state
    |> ufls_nadir()
    |> PowerModel.Failure.Protection.ufls_schedule()
    |> Keyword.get(:stage, 0)
  end

  # ===========================================================================
  # Zero output, aggregation, and re-trip
  # ===========================================================================

  describe "night and missing data" do
    test "zero output is a clean no-op, identical to having no layer at all" do
      # 3am, or a BA with no fuel row for the hour. Zero output is the correct
      # inert state, not an error: rooftop tripping in the dark releases
      # nothing, because nothing was flowing.
      night =
        island_snapshot(100.0, 102.0, [btm(2, 0.0, legacy_fraction: 0.30)])
        |> Cascade.init()
        |> Cascade.run_cascade()
        |> elem(0)

      no_layer =
        island_snapshot(100.0, 102.0, [])
        |> Cascade.init()
        |> Cascade.run_cascade()
        |> elem(0)

      assert events(night, "btm_trip") == []
      assert night.btm_tripped_mw == 0.0
      assert night.btm_by_bus == %{}

      assert Enum.map(night.loads, & &1.p_mw) == Enum.map(no_layer.loads, & &1.p_mw)
      assert_in_delta shed_mw(night), shed_mw(no_layer), 1.0e-9
      assert night.stable == no_layer.stable
    end
  end

  describe "per-bus aggregation" do
    test "a bus carrying all three sectors trips once, for their combined output" do
      three_sectors = [
        btm(2, 20.0, sector: "residential", legacy_fraction: 0.30),
        btm(2, 12.0, sector: "commercial", legacy_fraction: 0.30),
        btm(2, 8.0, sector: "industrial", legacy_fraction: 0.30)
      ]

      split =
        island_snapshot(100.0, 102.0, three_sectors)
        |> Cascade.init()
        |> Cascade.run_cascade()
        |> elem(0)

      whole =
        island_snapshot(100.0, 102.0, [btm(2, 40.0, legacy_fraction: 0.30)])
        |> Cascade.init()
        |> Cascade.run_cascade()
        |> elem(0)

      # One event, one bus, one aggregate — never three trips of the same bus.
      assert [event] = events(split, "btm_trip")
      assert event.details.bus_count == 1
      assert_in_delta event.details.tripped_mw, 12.0, 1.0e-9

      assert_in_delta split.btm_tripped_mw, whole.btm_tripped_mw, 1.0e-9
      assert_in_delta served_mw(split), served_mw(whole), 1.0e-9
    end

    test "one aggregated event covers every bus that trips in an island" do
      # Three load buses, each with rooftop, all in one island: one event
      # carrying the island total, never one event per bus.
      snapshot = %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3), bus(4)],
        lines: [line(1, 1, 2), line(2, 2, 3), line(3, 3, 4)],
        transformers: [],
        generators: [generator(1, 1, 100.0)],
        loads: [load(1, 2, 34.0), load(2, 3, 34.0), load(3, 4, 34.0)],
        btm_solar: [
          btm(2, 10.0, legacy_fraction: 0.30),
          btm(3, 10.0, legacy_fraction: 0.30),
          btm(4, 20.0, legacy_fraction: 0.30)
        ]
      }

      {state, _steps} = Cascade.run_cascade(Cascade.init(snapshot))

      assert [event] = events(state, "btm_trip")
      assert event.details.bus_count == 3
      assert_in_delta event.details.tripped_mw, 12.0, 1.0e-9
      assert state.btm_tripped_buses == MapSet.new([2, 3, 4])
      assert_conserved(state)
    end
  end

  describe "no reconnection inside a cascade" do
    test "tripped rooftop never trips twice, however many steps or splits follow" do
      # Two islands' worth of buses joined by one line: after the rooftop
      # trips, splitting the island must not re-trip the same buses, because
      # the tripped set is keyed by BUS, not by island.
      snapshot = %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3, bus_type: 3), bus(4)],
        lines: [line(1, 1, 2), line(2, 2, 3), line(3, 3, 4)],
        transformers: [],
        generators: [generator(1, 1, 60.0), generator(2, 3, 60.0)],
        loads: [load(1, 2, 61.0), load(2, 4, 61.0)],
        btm_solar: [
          btm(2, 30.0, legacy_fraction: 0.30),
          btm(4, 30.0, legacy_fraction: 0.30)
        ]
      }

      {first, _steps} = Cascade.run_cascade(Cascade.init(snapshot))
      assert first.btm_tripped_mw > 0.0
      tripped_after_first = first.btm_tripped_mw
      buses_after_first = first.btm_tripped_buses

      # Split the system in two and run the cascade again on the halves.
      {second, _steps} = Cascade.trip_line(first, 2)

      assert second.btm_tripped_buses == buses_after_first
      assert_in_delta second.btm_tripped_mw, tripped_after_first, 1.0e-9

      # 1547 mandates a delayed, permissive reconnection: nothing inside a
      # cascade brings these inverters back, so exactly one event stands.
      assert length(events(second, "btm_trip")) == length(events(first, "btm_trip"))
    end
  end

  # ===========================================================================
  # Configuration
  # ===========================================================================

  describe "legacy_fraction configuration" do
    setup do
      original = Application.get_env(:power_model, :btm_legacy_fraction)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:power_model, :btm_legacy_fraction)
          value -> Application.put_env(:power_model, :btm_legacy_fraction, value)
        end
      end)

      :ok
    end

    test "the entry's stamped share is what trips" do
      state =
        island_snapshot(100.0, 102.0, [btm(2, 40.0, legacy_fraction: 0.50)])
        |> Cascade.init()
        |> Cascade.run_cascade()
        |> elem(0)

      assert_in_delta state.btm_tripped_mw, 20.0, 1.0e-9
    end

    test "a configured override reaches the cascade through the snapshot" do
      Application.put_env(:power_model, :btm_legacy_fraction, 0.45)
      assert BtmSolar.legacy_fraction() == 0.45

      # Entries built the way the layer builds them, carrying the configured
      # share rather than a hard-coded one.
      entries = [btm(2, 40.0, legacy_fraction: BtmSolar.legacy_fraction())]

      state =
        island_snapshot(100.0, 102.0, entries)
        |> Cascade.init()
        |> Cascade.run_cascade()
        |> elem(0)

      assert_in_delta state.btm_tripped_mw, 18.0, 1.0e-9
    end

    test "an entry with no stamped share falls back to the configured one" do
      Application.put_env(:power_model, :btm_legacy_fraction, 0.25)

      state =
        island_snapshot(100.0, 102.0, [btm(2, 40.0)])
        |> Cascade.init()
        |> Cascade.run_cascade()
        |> elem(0)

      assert_in_delta state.btm_tripped_mw, 10.0, 1.0e-9
    end

    test "a zero legacy share leaves the whole fleet riding through" do
      state =
        island_snapshot(100.0, 102.0, [btm(2, 40.0, legacy_fraction: 0.0)])
        |> Cascade.init()
        |> Cascade.run_cascade()
        |> elem(0)

      assert state.btm_by_bus == %{}
      assert events(state, "btm_trip") == []
    end
  end

  # ===========================================================================
  # Blue Cut: a utility unit trips at a high-insolation hour
  # ===========================================================================

  describe "Blue Cut-style scenario" do
    # 2016-08-16: a fault on the Blue Cut fire day took ~1,200 MW of inverter
    # generation off the CAISO system, most of it reacting to a disturbance it
    # should have ridden through. Here: a 20 MW unit trips out of a 120 MW
    # island at an hour with 40 MW of rooftop flowing. The unit is sized so
    # that reserves absorb most of it and the residual excursion lands inside
    # the physical frequency range — a bigger unit pins the swing model at its
    # 55 Hz clamp, where every scenario looks alike.
    defp blue_cut_snapshot(legacy_fraction) do
      %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3)],
        lines: [line(1, 1, 2), line(2, 2, 3)],
        transformers: [],
        generators: [generator(1, 1, 100.0), generator(2, 3, 20.0)],
        loads: [load(1, 2, 102.0)],
        btm_solar: [btm(2, 40.0, legacy_fraction: legacy_fraction)]
      }
    end

    test "the unit trip pulls the rooftop down with it, and the rooftop deepens the shed" do
      {with_legacy, _} =
        blue_cut_snapshot(0.30) |> Cascade.init() |> Cascade.trip_generator(2)

      {without_legacy, _} =
        blue_cut_snapshot(0.0) |> Cascade.init() |> Cascade.trip_generator(2)

      # Direction: the rooftop leaves, and it leaves as demand.
      assert [event] = events(with_legacy, "btm_trip")
      assert event.details.nadir <= 59.3
      refute event.details.nadir == 55.0

      # Magnitude: exactly the legacy share of what was flowing, no more.
      assert_in_delta event.details.tripped_mw, 12.0, 1.0e-9
      assert_in_delta with_legacy.btm_tripped_mw, 12.0, 1.0e-9

      # Feedback: governors answered 10 MW of the 17 MW loss inside the nadir
      # window (ROADMAP item 16 — the rest of the machine's headroom is real
      # but unreachable in ten seconds), the island shed two UFLS stages for
      # the residual, and the rooftop leaving pushed it onto a third.
      assert_in_delta shed_mw(without_legacy), 15.3, 0.01
      assert_in_delta shed_mw(with_legacy), 25.65, 0.01

      # The extra shed is bigger than the rooftop that caused it, because the
      # deeper excursion reaches a further UFLS stage on a larger base.
      assert shed_mw(with_legacy) - shed_mw(without_legacy) > 0.0

      # ...via a deeper frequency excursion, which is the loop closing.
      assert ufls_nadir(with_legacy) < ufls_nadir(without_legacy)
      assert ufls_stage(with_legacy) > ufls_stage(without_legacy)

      assert_conserved(with_legacy)
      assert_conserved(without_legacy)
    end

    test "the generator-trip redispatch path accounts its rooftop trip too" do
      # This scenario opens its deficit through `redispatch/4` — the manual
      # generator trip raises reserves before the cascade loop starts — and
      # the rooftop is then evaluated inside the island solve that follows,
      # which is the single place that owns the frequency trajectory.
      {state, _} = blue_cut_snapshot(0.30) |> Cascade.init() |> Cascade.trip_generator(2)

      b = assert_conserved(state)
      assert_in_delta b.btm_tripped_mw, 12.0, 1.0e-9
      assert_in_delta b.original_load_mw, 102.0, 1.0e-9

      # Every btm_trip event carries a step, like every other cascade event.
      for event <- events(state, "btm_trip") do
        assert is_integer(event.step)
        assert Map.has_key?(event.details, :tripped_mw)
        assert Map.has_key?(event.details, :bus_count)
        assert Map.has_key?(event.details, :nadir)
      end
    end
  end

  # ===========================================================================
  # Accounting
  # ===========================================================================

  describe "extended conservation identity" do
    test "balance/1 carries the btm_tripped bucket and it starts at zero" do
      state = Cascade.init(island_snapshot(100.0, 102.0, [btm(2, 40.0, legacy_fraction: 0.30)]))

      b = Cascade.balance(state)
      assert b.btm_tripped_mw == 0.0
      assert_in_delta b.original_load_mw, 102.0, 1.0e-9

      # With nothing tripped, the extended identity IS the original identity.
      assert_in_delta b.served_load_mw + b.shed_load_mw + b.blackout_load_mw,
                      b.original_load_mw,
                      1.0e-9
    end

    test "every step result's balance conserves under the extended identity" do
      snapshot = island_snapshot(100.0, 102.0, [btm(2, 40.0, legacy_fraction: 0.30)])
      {_final, steps} = Cascade.run_cascade(Cascade.init(snapshot))

      assert steps != []

      for step <- steps do
        b = step.balance

        assert_in_delta b.served_load_mw + b.shed_load_mw + b.blackout_load_mw,
                        b.original_load_mw + b.btm_tripped_mw,
                        0.01
      end
    end

    test "tripped rooftop that later blacks out lands in the blackout bucket" do
      # Bus 2 grosses up when the rooftop trips; then the island loses its
      # generator entirely and everything still standing goes dark. The MW
      # that entered as btm_tripped must leave through shed/blackout, never
      # vanish.
      snapshot = island_snapshot(100.0, 102.0, [btm(2, 40.0, legacy_fraction: 0.30)])
      {state, _} = Cascade.run_cascade(Cascade.init(snapshot))
      assert state.btm_tripped_mw > 0.0

      {dark, _} = Cascade.trip_line(state, 1)

      b = assert_conserved(dark)
      assert b.blackout_load_mw > 0.0
      assert_in_delta b.served_load_mw, 0.0, 1.0e-9
    end

    test "the identity survives a run where the rooftop trips in more than one island" do
      snapshot = %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3, bus_type: 3), bus(4)],
        lines: [line(1, 1, 2), line(2, 3, 4)],
        transformers: [],
        generators: [generator(1, 1, 100.0), generator(2, 3, 100.0)],
        loads: [load(1, 2, 102.0), load(2, 4, 102.0)],
        btm_solar: [
          btm(2, 40.0, legacy_fraction: 0.30),
          btm(4, 20.0, legacy_fraction: 0.30)
        ]
      }

      {state, _steps} = Cascade.run_cascade(Cascade.init(snapshot))

      # Two electrically separate islands, so two aggregated events — one per
      # island per step, never one for the pair and never one per bus.
      assert length(events(state, "btm_trip")) == 2
      assert_in_delta state.btm_tripped_mw, 18.0, 1.0e-9
      assert state.btm_tripped_buses == MapSet.new([2, 4])

      assert_conserved(state)
    end
  end

  # ===========================================================================
  # The frequency model must not be degraded
  # ===========================================================================

  describe "frequency-model interplay" do
    test "the rooftop trip is invisible above 59.3 Hz, so the response band is untouched" do
      # Everything the β / frequency-response validation exercises lives above
      # the must-trip point. Sweeping shallow deficits, no rooftop moves and
      # every result matches the no-layer run exactly.
      for load_mw <- [100.2, 100.5, 100.8, 101.0] do
        with_layer =
          island_snapshot(100.0, load_mw, [btm(2, 40.0, legacy_fraction: 0.30)])
          |> Cascade.init()
          |> Cascade.run_cascade()
          |> elem(0)

        without =
          island_snapshot(100.0, load_mw, [])
          |> Cascade.init()
          |> Cascade.run_cascade()
          |> elem(0)

        assert events(with_layer, "btm_trip") == []
        assert with_layer.btm_tripped_mw == 0.0
        assert Enum.map(with_layer.loads, & &1.p_mw) == Enum.map(without.loads, & &1.p_mw)
        assert_in_delta shed_mw(with_layer), shed_mw(without), 1.0e-9
      end
    end

    test "a bus with no energized load has nothing to hand its rooftop back to" do
      # Rooftop behind a de-energized feeder is disconnected with the feeder.
      # Bus 3 carries rooftop but zero demand, so it contributes nothing and
      # is not recorded as tripped.
      snapshot = %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3)],
        lines: [line(1, 1, 2), line(2, 2, 3)],
        transformers: [],
        generators: [generator(1, 1, 100.0)],
        loads: [load(1, 2, 102.0), load(2, 3, 0.0)],
        btm_solar: [
          btm(2, 40.0, legacy_fraction: 0.30),
          btm(3, 40.0, legacy_fraction: 0.30)
        ]
      }

      {state, _steps} = Cascade.run_cascade(Cascade.init(snapshot))

      assert [event] = events(state, "btm_trip")
      assert event.details.bus_count == 1
      assert_in_delta event.details.tripped_mw, 12.0, 1.0e-9
      assert state.btm_tripped_buses == MapSet.new([2])
      assert_conserved(state)
    end
  end

  # ===========================================================================
  # The VOLTAGE half of Blue Cut — IEEE 1547 voltage trips (pure layer)
  # ===========================================================================
  #
  # These exercise `PowerModel.Grid.BtmSolar`'s pure envelope functions
  # directly. The cascade wiring is Wave 3b's; what is pinned here is the math
  # and the state shapes it will thread.

  describe "BtmSolar.fleet_by_bus/1" do
    test "splits output by vintage and aggregates the sectors of one bus" do
      entries = [
        btm(1, 100.0, legacy_fraction: 0.30, sector: "residential"),
        btm(1, 50.0, legacy_fraction: 0.30, sector: "commercial")
      ]

      assert %{1 => mw} = BtmSolar.fleet_by_bus(entries)
      assert_in_delta mw.legacy_mw, 45.0, 1.0e-9
      assert_in_delta mw.modern_mw, 105.0, 1.0e-9
    end

    test "drops buses with nothing to lose" do
      entries = [btm(1, 0.0, legacy_fraction: 0.30), %{sector: "residential", output_mw: 10.0}]

      assert BtmSolar.fleet_by_bus(entries) == %{}
    end

    test "falls back to the configured legacy share when a row carries none" do
      assert %{1 => mw} = BtmSolar.fleet_by_bus([btm(1, 100.0)])
      assert_in_delta mw.legacy_mw, 100.0 * BtmSolar.legacy_fraction(), 1.0e-9
    end
  end

  describe "BtmSolar.voltage_trips/5 — legacy versus modern" do
    defp fleet(bus_id \\ 1), do: %{bus_id => %{legacy_mw: 30.0, modern_mw: 70.0}}

    test "V = 0.40 pu for 0.2 s trips the legacy fraction only" do
      {trips, _state} = BtmSolar.voltage_trips(fleet(), %{1 => 0.40}, nil, 0.2)

      assert %{1 => detail} = trips
      assert_in_delta detail.tripped_mw, 30.0, 1.0e-9
      assert_in_delta detail.by_vintage.legacy, 30.0, 1.0e-9
      assert detail.by_vintage.modern == 0.0

      # 1547-2003 UV2: below 0.50 pu, 0.16 s.
      assert [%{vintage: :legacy, element: :uv2, threshold_pu: 0.50, clearing_s: 0.16}] =
               detail.elements
    end

    test "modern Category III rides through the same excursion" do
      # Cat III UV2 sits at 0.50 pu with a 2 s clearing time, so the modern
      # fleet is still there long after the legacy fleet has gone.
      {trips, state} = BtmSolar.voltage_trips(fleet(), %{1 => 0.40}, nil, 0.2)
      assert trips[1].by_vintage.modern == 0.0
      refute state.buses[1].modern.tripped

      # ...and it does eventually go, once its own clearing time is reached.
      {trips, _} = BtmSolar.voltage_trips(fleet(), %{1 => 0.40}, state, 2.0)
      assert_in_delta trips[1].by_vintage.modern, 70.0, 1.0e-9
      assert trips[1].by_vintage.legacy == 0.0
    end

    test "Category II is NOT the same answer as Category III at 0.40 pu" do
      # Cat II's UV2 is 0.45 pu / 0.16 s — nearly as brittle as legacy. This
      # is why the default category is a documented choice, not a detail.
      {trips, _} =
        BtmSolar.voltage_trips(fleet(), %{1 => 0.40}, nil, 0.2, modern_category: :category_ii)

      assert_in_delta trips[1].tripped_mw, 100.0, 1.0e-9
      assert_in_delta trips[1].by_vintage.modern, 70.0, 1.0e-9
    end

    test "V = 0.85 for 2.5 s trips legacy on the 0.50-0.88 band" do
      {trips, _} = BtmSolar.voltage_trips(fleet(), %{1 => 0.85}, nil, 2.5)

      assert_in_delta trips[1].tripped_mw, 30.0, 1.0e-9

      assert [%{vintage: :legacy, element: :uv1, threshold_pu: 0.88, clearing_s: 2.0}] =
               trips[1].elements
    end

    test "0.85 pu is inside the modern envelope for a long time" do
      # Cat III UV1 is 0.88 pu / 21 s.
      {trips, state} = BtmSolar.voltage_trips(fleet(), %{1 => 0.85}, nil, 2.5)
      refute state.buses[1].modern.tripped
      assert trips[1].by_vintage.modern == 0.0

      {trips, _} = BtmSolar.voltage_trips(fleet(), %{1 => 0.85}, state, 19.0)
      assert_in_delta trips[1].by_vintage.modern, 70.0, 1.0e-9
    end

    test "an excursion shorter than the clearing time trips nothing" do
      assert {trips, _} = BtmSolar.voltage_trips(fleet(), %{1 => 0.40}, nil, 0.1)
      assert trips == %{}
    end

    test "normal voltage trips nothing, however long it is held" do
      {trips, _} = BtmSolar.voltage_trips(fleet(), %{1 => 1.0}, nil, 3600.0)
      assert trips == %{}
    end

    test "the over-voltage elements fire too" do
      # OV2 is 1.20 pu / 0.16 s in EVERY vintage, 2003 and 2018 alike, so a
      # 1.25 pu bus takes the whole rooftop fleet with it.
      {trips, _} = BtmSolar.voltage_trips(fleet(), %{1 => 1.25}, nil, 0.2)
      assert_in_delta trips[1].tripped_mw, 100.0, 1.0e-9
      assert Enum.map(trips[1].elements, & &1.element) == [:ov2, :ov2]

      # OV1 is where they diverge: 1 s legacy, 13 s for Category III.
      {trips, _} = BtmSolar.voltage_trips(fleet(), %{1 => 1.15}, nil, 1.5)
      assert [%{vintage: :legacy, element: :ov1, threshold_pu: 1.10}] = trips[1].elements
    end

    test "a definite-time element resets when the voltage clears its threshold" do
      {%{}, state} = BtmSolar.voltage_trips(fleet(), %{1 => 0.85}, nil, 1.5)
      {%{}, state} = BtmSolar.voltage_trips(fleet(), %{1 => 1.0}, state, 0.1)

      # The 2 s UV1 timer restarted, so 1.5 s more is not enough.
      assert {trips, _} = BtmSolar.voltage_trips(fleet(), %{1 => 0.85}, state, 1.5)
      assert trips == %{}
    end

    test "a bus missing from the voltage map keeps its timers" do
      {%{}, state} = BtmSolar.voltage_trips(fleet(), %{1 => 0.85}, nil, 1.5)
      before = state.buses[1].legacy.timers

      {trips, held} = BtmSolar.voltage_trips(fleet(), %{}, state, 60.0)

      assert trips == %{}
      assert held.buses[1].legacy.timers == before

      # ...and the excursion resumes where it left off, rather than restarting.
      assert {trips, _} = BtmSolar.voltage_trips(fleet(), %{1 => 0.85}, held, 0.6)
      assert_in_delta trips[1].tripped_mw, 30.0, 1.0e-9
    end

    test "a bus trips at most once per vintage" do
      {trips, state} = BtmSolar.voltage_trips(fleet(), %{1 => 0.40}, nil, 0.2)
      assert map_size(trips) == 1

      {again, _} = BtmSolar.voltage_trips(fleet(), %{1 => 0.40}, state, 5.0)
      assert again[1].by_vintage.legacy == 0.0
    end

    test "a frequency trip recorded into the state blocks a second voltage trip" do
      # The double-counting guard between the two Blue Cut halves: the
      # cascade's 59.3 Hz trip already took this bus's legacy fleet.
      state = BtmSolar.mark_tripped(nil, 1, [:legacy])

      {trips, _} = BtmSolar.voltage_trips(fleet(), %{1 => 0.40}, state, 0.2)

      assert trips == %{}
    end

    test "an island-wide scalar voltage stands in for a per-bus map" do
      fleet = Map.merge(fleet(1), fleet(2))

      {trips, _} = BtmSolar.voltage_trips(fleet, 0.40, nil, 0.2)

      assert Map.keys(trips) |> Enum.sort() == [1, 2]
    end

    test "tripped_mw_by_bus/1 flattens to what a gross-up needs" do
      {trips, _} = BtmSolar.voltage_trips(fleet(), %{1 => 0.40}, nil, 0.2)

      assert %{1 => mw} = BtmSolar.tripped_mw_by_bus(trips)
      assert_in_delta mw, 30.0, 1.0e-9
    end

    test "the settings tables are exposed as the single source of truth" do
      assert BtmSolar.voltage_trip_settings(:legacy) == [
               {:uv2, :under, 0.50, 0.16},
               {:uv1, :under, 0.88, 2.00},
               {:ov2, :over, 1.20, 0.16},
               {:ov1, :over, 1.10, 1.00}
             ]

      assert BtmSolar.voltage_trip_settings(:category_iii) == [
               {:uv2, :under, 0.50, 2.00},
               {:uv1, :under, 0.88, 21.0},
               {:ov2, :over, 1.20, 0.16},
               {:ov1, :over, 1.10, 13.0}
             ]

      assert BtmSolar.modern_category() == :category_iii
    end
  end

  describe "BtmSolar voltage state threading across island splits" do
    test "splitting apportions by key and conserves every timer" do
      fleet = %{
        1 => %{legacy_mw: 10.0, modern_mw: 20.0},
        2 => %{legacy_mw: 10.0, modern_mw: 20.0},
        3 => %{legacy_mw: 10.0, modern_mw: 20.0}
      }

      {%{}, state} = BtmSolar.voltage_trips(fleet, 0.85, nil, 1.5)

      left = BtmSolar.split_voltage_state(state, [1, 2])
      right = BtmSolar.split_voltage_state(state, [3])

      assert Map.keys(left.buses) |> Enum.sort() == [1, 2]
      assert Map.keys(right.buses) == [3]

      # Intensive: the halves keep the timers unscaled...
      assert left.buses[1] == state.buses[1]
      assert right.buses[3] == state.buses[3]

      # ...so the remaining exposure still finishes the element on schedule.
      assert {trips, _} = BtmSolar.voltage_trips(fleet, 0.85, right, 0.6)
      assert Map.keys(trips) == [3]
    end

    test "merging re-joined islands keeps the longest timer and any trip" do
      fleet = fleet(1)

      {%{}, short} = BtmSolar.voltage_trips(fleet, %{1 => 0.85}, nil, 0.5)
      {%{}, long} = BtmSolar.voltage_trips(fleet, %{1 => 0.85}, nil, 1.5)

      merged = BtmSolar.merge_voltage_states([short, long])
      assert merged.buses[1].legacy == long.buses[1].legacy

      {_, tripped} = BtmSolar.voltage_trips(fleet, %{1 => 0.85}, long, 1.0)
      assert BtmSolar.merge_voltage_states([short, tripped]).buses[1].legacy.tripped
    end

    test "a nil state splits into a fresh one" do
      assert BtmSolar.split_voltage_state(nil, [1]) == BtmSolar.fresh_voltage_state()
      assert BtmSolar.merge_voltage_states([nil]) == BtmSolar.fresh_voltage_state()
    end
  end

  describe "cause-tagged btm_tripped bookkeeping" do
    test "an island-level event distinguishes voltage from frequency" do
      fleet = Map.merge(fleet(1), fleet(2))
      {trips, _} = BtmSolar.voltage_trips(fleet, 0.40, nil, 0.2)

      event = BtmSolar.voltage_trip_event(trips)

      assert event.component_type == "btm_solar"
      assert event.failure_cause == "btm_voltage_trip"
      assert event.details.cause == :voltage
      assert event.component_id == 1
      assert event.details.bus_count == 2
      assert_in_delta event.details.tripped_mw, 60.0, 1.0e-9
      assert_in_delta event.details.legacy_mw, 60.0, 1.0e-9
      assert event.details.modern_mw == 0.0
      assert_in_delta event.details.vm_pu_min, 0.40, 1.0e-9

      # ONE event for the whole island, never one per bus.
      refute is_list(event)
    end

    test "nothing tripped means no event at all" do
      assert BtmSolar.voltage_trip_event(%{}) == nil
    end

    test "the breakdown of mixed frequency and voltage trips still balances" do
      breakdown =
        BtmSolar.fresh_trip_breakdown()
        |> BtmSolar.record_trip(:frequency, 12.0)
        |> BtmSolar.record_trip(:voltage, 30.0)
        |> BtmSolar.record_trip(:frequency, 4.5)

      assert_in_delta breakdown.frequency_mw, 16.5, 1.0e-9
      assert_in_delta breakdown.voltage_mw, 30.0, 1.0e-9
      assert_in_delta breakdown.total_mw, 46.5, 1.0e-9
      assert BtmSolar.trip_breakdown_balanced?(breakdown)
    end

    test "total_mw is exactly the conservation identity's btm_tripped term" do
      # The identity `served + shed + blackout == original + btm_tripped` keeps
      # its shape: the breakdown refines one number, it does not add a term.
      breakdown =
        Enum.reduce(
          [{:frequency, 1.0}, {:voltage, 2.0}, {:voltage, 3.5}],
          BtmSolar.fresh_trip_breakdown(),
          fn
            {cause, mw}, acc -> BtmSolar.record_trip(acc, cause, mw)
          end
        )

      assert_in_delta breakdown.total_mw, breakdown.frequency_mw + breakdown.voltage_mw, 1.0e-12
      assert_in_delta breakdown.total_mw, 6.5, 1.0e-9
    end
  end
end
