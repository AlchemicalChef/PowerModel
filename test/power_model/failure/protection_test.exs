defmodule PowerModel.Failure.ProtectionTest do
  use ExUnit.Case, async: true

  alias PowerModel.Failure.Protection

  describe "overcurrent_trip_time/2" do
    test "returns infinity at or below pickup" do
      assert Protection.overcurrent_trip_time(99.0) == :infinity
      assert Protection.overcurrent_trip_time(100.0) == :infinity
    end

    test "follows the IEC standard-inverse curve" do
      assert_in_delta Protection.overcurrent_trip_time(110.0), 73.4, 0.734
      assert_in_delta Protection.overcurrent_trip_time(150.0), 17.2, 0.172
      assert_in_delta Protection.overcurrent_trip_time(200.0), 10.0, 0.1
    end

    test "returns a large finite time just above pickup" do
      trip_time = Protection.overcurrent_trip_time(100.0001)

      assert is_float(trip_time)
      assert trip_time > 1_000_000.0
    end

    test "decreases monotonically as loading increases" do
      times = Enum.map([100.0001, 110.0, 150.0, 200.0], &Protection.overcurrent_trip_time/1)

      assert Enum.chunk_every(times, 2, 1, :discard)
             |> Enum.all?(fn [earlier, later] -> earlier > later end)
    end
  end

  describe "zone3_trip_probability/2" do
    test "matches the documented loading and voltage anchors" do
      assert_in_delta Protection.zone3_trip_probability(100.0, 0.8), 0.833, 0.001
      assert Protection.zone3_trip_probability(120.0, 0.75) == 1.0
    end

    test "is zero when neither loading nor voltage contributes" do
      assert Protection.zone3_trip_probability(80.0, 0.9) == 0.0
    end

    test "equals the voltage factor alone at exactly 80 percent loading" do
      expected_voltage_factor = (0.9 - 0.8) / 0.15

      assert_in_delta Protection.zone3_trip_probability(80.0, 0.8),
                      expected_voltage_factor,
                      1.0e-12
    end
  end

  describe "check_zone3_encroachment/6" do
    test "uses flow endpoints when line and transformer IDs collide" do
      line_flows = %{
        {:line, 42} => %{
          from_bus_id: 1,
          to_bus_id: 2,
          p_flow_mw: 100.0,
          loading_pct: 100.0
        },
        {:transformer, 42} => %{
          from_bus_id: 3,
          to_bus_id: 4,
          p_flow_mw: 100.0,
          loading_pct: 100.0
        }
      }

      mixed_components = [
        %{id: 42, from_bus_id: 1, to_bus_id: 2},
        %{id: 42, from_bus_id: 3, to_bus_id: 4}
      ]

      trips =
        Protection.check_zone3_encroachment(
          line_flows,
          mixed_components,
          [],
          [0.8, 0.85, 1.0, 1.0],
          [0.0, 0.0, 0.0, 0.0],
          %{1 => 0, 2 => 1, 3 => 2, 4 => 3}
        )

      assert [trip] = trips
      assert trip.component_type == "transmission_line"
      assert trip.component_id == 42
      assert trip.details.v_from_pu == 0.8
      assert trip.details.v_to_pu == 0.85
      assert trip.details.trip_probability > 0.5
    end
  end

  describe "existing protection behavior" do
    test "retains the canonical UFLS first stage" do
      assert Protection.ufls_schedule(59.0) == [stage: 1, shed_fraction: 0.075]
    end
  end

  # ===========================================================================
  # PRC-024-shaped generator frequency protection (ROADMAP item 15)
  # ===========================================================================

  describe "generator_frequency_trips/2" do
    # A flat excursion: `hz` held for `seconds`, sampled every 0.1 s, opening
    # and closing at nominal so nothing depends on the endpoints.
    defp excursion(hz, seconds) do
      steps = round(seconds / 0.1)

      [%{time: 0.0, frequency: 60.0}] ++
        for(i <- 1..max(steps, 1), do: %{time: i * 0.1, frequency: hz}) ++
        [%{time: (max(steps, 1) + 1) * 0.1, frequency: 60.0}]
    end

    defp units(n \\ 3) do
      for i <- 1..n, do: %{id: i, p_max_mw: 500.0, capacity_factor: 0.8, fuel_type: "NG"}
    end

    defp causes(trips), do: trips |> Enum.map(& &1.failure_cause) |> Enum.uniq()

    test "nothing trips on an excursion inside every band" do
      assert Protection.generator_frequency_trips(excursion(59.6, 300.0), units()) == []
      assert Protection.generator_frequency_trips(excursion(60.4, 300.0), units()) == []
    end

    test "below 57.0 Hz the protection operates instantaneously" do
      trips = Protection.generator_frequency_trips(excursion(56.9, 0.1), units())

      assert length(trips) == 3
      assert causes(trips) == ["underfrequency_trip"]
      assert Enum.all?(trips, &(&1.details.band_hz == 57.0))
      assert Enum.all?(trips, &(&1.details.allowance_s == 0.0))
      assert Enum.all?(trips, &(&1.component_type == "generator"))
      assert Enum.map(trips, & &1.component_id) == [1, 2, 3]
    end

    test "the 58.0 Hz band allows 30 seconds and not a step more" do
      # Just inside: 30 s at 57.9 Hz is survivable.
      assert Protection.generator_frequency_trips(excursion(57.9, 30.0), units()) == []

      # Just outside: one more sample interval and the band is exhausted.
      trips = Protection.generator_frequency_trips(excursion(57.9, 30.2), units())

      assert length(trips) == 3
      assert Enum.all?(trips, &(&1.details.band_hz == 58.0))
      assert Enum.all?(trips, &(&1.details.allowance_s == 30.0))
      assert Enum.all?(trips, &(&1.details.time_in_band_s > 30.0))
    end

    test "the 59.4 Hz band allows minutes" do
      assert Protection.generator_frequency_trips(excursion(59.3, 179.0), units()) == []

      trips = Protection.generator_frequency_trips(excursion(59.3, 181.0), units())
      assert Enum.all?(trips, &(&1.details.band_hz == 59.4))
      assert Enum.all?(trips, &(&1.details.allowance_s == 180.0))
    end

    test "the high side is symmetric in shape" do
      assert Protection.generator_frequency_trips(excursion(61.4, 29.0), units()) == []

      instant = Protection.generator_frequency_trips(excursion(61.9, 0.1), units())
      assert causes(instant) == ["overfrequency_trip"]
      assert Enum.all?(instant, &(&1.details.band_hz == 61.8))

      timed = Protection.generator_frequency_trips(excursion(61.6, 31.0), units())
      assert causes(timed) == ["overfrequency_trip"]
      assert Enum.all?(timed, &(&1.details.band_hz == 61.5))
    end

    test "the deepest violated band is the one reported" do
      # 30+ s below 58.0 also means 30+ s below 59.4, but 58.0 is the more
      # severe finding and is what the event should say.
      trips = Protection.generator_frequency_trips(excursion(57.5, 40.0), units())
      assert Enum.all?(trips, &(&1.details.band_hz == 58.0))
    end

    test "an excursion that crosses both sides reports the under-frequency side" do
      trajectory =
        excursion(56.5, 0.5) ++
          for(i <- 1..5, do: %{time: 10.0 + i * 0.1, frequency: 62.0})

      trips = Protection.generator_frequency_trips(trajectory, units())
      assert causes(trips) == ["underfrequency_trip"]
    end

    test "offline units have no breaker left to open" do
      fleet = [
        %{id: 1, p_max_mw: 500.0, capacity_factor: 0.8, fuel_type: "NG"},
        # dispatched to zero by the merit order
        %{id: 2, p_max_mw: 0.0, capacity_factor: 1.0, fuel_type: "NG"},
        %{id: 3, p_max_mw: 500.0, capacity_factor: 0.0, fuel_type: "NG"}
      ]

      trips = Protection.generator_frequency_trips(excursion(56.0, 0.2), fleet)
      assert Enum.map(trips, & &1.component_id) == [1]
    end

    test "a flat-excursion summary drives the instantaneous bands" do
      assert [_, _, _] =
               Protection.generator_frequency_trips(%{frequency_hz: 56.5}, units())

      assert Protection.generator_frequency_trips(%{frequency_hz: 58.5}, units()) == []

      # ...and with a duration, the timed bands too.
      trips =
        Protection.generator_frequency_trips(
          %{frequency_hz: 58.5, duration_s: 200.0},
          units()
        )

      assert Enum.all?(trips, &(&1.details.band_hz == 59.4))
    end

    test "a nadir-only summary is accepted under its own key" do
      assert [_ | _] = Protection.generator_frequency_trips(%{nadir_hz: 56.0}, units())
    end

    test "an empty fleet trips nothing, however deep the excursion" do
      assert Protection.generator_frequency_trips(excursion(55.0, 60.0), []) == []
    end

    test "monotone in depth: a deeper excursion never trips fewer units" do
      fleet = units(5)

      counts =
        for hz <- [59.8, 59.5, 59.35, 59.0, 58.5, 57.9, 57.5, 56.9] do
          length(Protection.generator_frequency_trips(excursion(hz, 35.0), fleet))
        end

      assert counts == Enum.sort(counts)
      assert List.last(counts) == 5
    end

    test "monotone in duration: a longer excursion never trips fewer units" do
      fleet = units(5)

      counts =
        for seconds <- [1.0, 10.0, 29.0, 31.0, 100.0, 179.0, 200.0] do
          length(Protection.generator_frequency_trips(excursion(57.9, seconds), fleet))
        end

      assert counts == Enum.sort(counts)
    end

    test "monotone against a real swing trajectory as the disturbance grows" do
      alias PowerModel.Solver.Frequency

      generators = [%{id: 1, p_max_mw: 1000.0, capacity_factor: 0.6, fuel_type: "NG"}]
      loads = [%{p_mw: 600.0}]

      counts =
        for lost <- [10.0, 50.0, 100.0, 200.0, 400.0, 800.0] do
          trajectory = Frequency.simulate(generators, loads, lost, 0.1, 120.0)
          length(Protection.generator_frequency_trips(trajectory, generators))
        end

      assert counts == Enum.sort(counts)
      assert List.last(counts) == 1
    end

    test "the envelopes are exposed as the single source of truth for the bands" do
      assert Protection.underfrequency_envelope() == [{57.0, 0.0}, {58.0, 30.0}, {59.4, 180.0}]
      assert Protection.overfrequency_envelope() == [{61.8, 0.0}, {61.5, 30.0}, {60.6, 180.0}]
    end
  end

  describe "estimate_frequency/3 static fallback (ENE-7)" do
    test "is the damping-consistent steady state f0*(1 - deficit/(D*load))" do
      # 0.5% deficit with D = 1.0 -> 60 * (1 - 0.005) = 59.7 Hz
      assert_in_delta Protection.estimate_frequency(99.5, 100.0), 59.7, 1.0e-9
      # 1% deficit -> 59.4 Hz (old droop estimate said 59.97)
      assert_in_delta Protection.estimate_frequency(99.0, 100.0), 59.4, 1.0e-9
    end

    test "clamps to the simulator's [55, 65] Hz band" do
      # 10% deficit -> 54 Hz unclamped -> floor 55
      assert Protection.estimate_frequency(90.0, 100.0) == 55.0
      # Large surplus -> ceiling 65
      assert Protection.estimate_frequency(200.0, 100.0) == 65.0
    end

    test "returns base frequency when there is no load" do
      assert Protection.estimate_frequency(50.0, 0.0) == 60.0
      assert Protection.estimate_frequency(50.0, 0.0, 59.5) == 59.5
    end

    test "total generation loss drives the full UFLS schedule" do
      freq = Protection.estimate_frequency(0.0, 100.0)
      assert freq == 55.0

      schedule = Protection.ufls_schedule(freq)
      assert schedule[:stage] == 4
      assert_in_delta schedule[:shed_fraction], 0.30, 1.0e-9
    end
  end
end
