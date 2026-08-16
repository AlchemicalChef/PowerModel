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

  # ===========================================================================
  # Mho distance relays + PRC-023 load blinder (ROADMAP item 20)
  # ===========================================================================

  # A ~100 mile 345 kV line on a 100 MVA base: |Z| = 0.1005 pu at 84.3°.
  @z_line {0.01, 0.10}
  # The longest line leaving the remote bus — twice as long, so zone 3 reaches
  # well past the protected line and can plausibly see load.
  @z_adjacent {0.02, 0.20}
  # Highest (rate C) rating of the protected line.
  @rating_mva 400.0

  defp z_at(mag, angle_deg) do
    theta = angle_deg * :math.pi() / 180.0
    {mag * :math.cos(theta), mag * :math.sin(theta)}
  end

  defp fault_at(fraction) do
    {r, x} = @z_line
    {fraction * r, fraction * x}
  end

  defp zone_of(z, opts \\ []) do
    Protection.distance_zone(z, @z_line, Keyword.put_new(opts, :z_adjacent, @z_adjacent))
  end

  describe "apparent_impedance/3" do
    test "Z = |V|^2 / S* — hand-computed case" do
      # 1.0 pu volts, 1.0 + j0.5 pu flow:
      #   Z = 1 * (1 + 0.5j) / (1^2 + 0.5^2) = 0.8 + 0.4j
      {r, x} = Protection.apparent_impedance(1.0, 1.0, 0.5)

      assert_in_delta r, 0.8, 1.0e-12
      assert_in_delta x, 0.4, 1.0e-12
    end

    test "unity power factor is purely resistive at the flow's reciprocal" do
      assert {r, x} = Protection.apparent_impedance(1.0, 2.0, 0.0)
      assert_in_delta r, 0.5, 1.0e-12
      assert_in_delta x, 0.0, 1.0e-12
    end

    test "scales with the SQUARE of voltage — the load-encroachment mechanism" do
      {full_r, _} = Protection.apparent_impedance(1.0, 1.0, 0.0)
      {sag_r, _} = Protection.apparent_impedance(0.85, 1.0, 0.0)

      assert_in_delta sag_r, full_r * 0.85 * 0.85, 1.0e-12
      # Depressed voltage at unchanged flow moves the measurement INWARD,
      # toward the relay characteristic. That is 2003 in one line.
      assert sag_r < full_r
    end

    test "the angle equals the power-factor angle of the flow" do
      z = Protection.apparent_impedance(1.0, 1.0, :math.tan(:math.pi() / 6.0))

      assert_in_delta Protection.impedance_angle_deg(z), 30.0, 1.0e-9
    end

    test "no flow means no measurable impedance" do
      assert Protection.apparent_impedance(1.0, 0.0, 0.0) == :infinite
      assert Protection.apparent_impedance_mva(1.0, 0.0, 0.0) == :infinite
      assert Protection.apparent_impedance_mva(1.0, 100.0, 0.0, 0.0) == :infinite
    end

    test "the MVA form is the pu form on the stated base" do
      assert Protection.apparent_impedance_mva(1.0, 100.0, 50.0, 100.0) ==
               Protection.apparent_impedance(1.0, 1.0, 0.5)
    end

    test "the phasor form agrees with the flow form" do
      # S = V * conj(I) = 1.0 * (1.0 + 0.5j) => I = 1.0 - 0.5j
      phasor = Protection.apparent_impedance_phasor({1.0, 0.0}, {1.0, -0.5})
      {r, x} = phasor

      assert_in_delta r, 0.8, 1.0e-12
      assert_in_delta x, 0.4, 1.0e-12
      assert Protection.apparent_impedance_phasor({1.0, 0.0}, {0.0, 0.0}) == :infinite
    end
  end

  describe "mho_reaches/2 and inside_mho?/2" do
    test "reaches are set along the line angle" do
      reaches = Protection.mho_reaches(@z_line, z_adjacent: @z_adjacent)
      line_angle = Protection.impedance_angle_deg(@z_line)

      for zone <- [1, 2, 3] do
        assert_in_delta Protection.impedance_angle_deg(reaches[zone]), line_angle, 1.0e-9
      end
    end

    test "zone 1 underreaches, zone 2 overreaches, zone 3 covers the adjacent line" do
      reaches = Protection.mho_reaches(@z_line, z_adjacent: @z_adjacent)
      line_mag = Protection.impedance_magnitude(@z_line)
      adj_mag = Protection.impedance_magnitude(@z_adjacent)

      assert_in_delta Protection.impedance_magnitude(reaches[1]), 0.85 * line_mag, 1.0e-12
      assert_in_delta Protection.impedance_magnitude(reaches[2]), 1.25 * line_mag, 1.0e-12

      assert_in_delta Protection.impedance_magnitude(reaches[3]),
                      1.2 * (line_mag + adj_mag),
                      1.0e-12
    end

    test "with no adjacency data zone 3 assumes an adjacent line like this one" do
      assumed = Protection.mho_reaches(@z_line)
      explicit = Protection.mho_reaches(@z_line, z_adjacent: @z_line)

      assert assumed == explicit
    end

    test "the characteristic circle passes through the origin and its reach" do
      reach = Protection.mho_reaches(@z_line)[1]

      assert Protection.inside_mho?({0.0, 0.0}, reach)
      assert Protection.inside_mho?(reach, reach)
      # Just past the reach, along the same angle, is out.
      {rr, rx} = reach
      refute Protection.inside_mho?({rr * 1.001, rx * 1.001}, reach)
    end

    test "a degenerate zero-impedance branch has no characteristic" do
      refute Protection.inside_mho?({0.0, 0.0}, {0.0, 0.0})
      assert Protection.mho_reaches({0.0, 0.0})[3] == {0.0, 0.0}
    end

    test "an infinite apparent impedance is inside nothing" do
      refute Protection.inside_mho?(:infinite, Protection.mho_reaches(@z_line)[3])
    end
  end

  describe "distance_zone/3" do
    test "a fault at 50% of the line is in zone 1" do
      result = zone_of(fault_at(0.5))

      assert result.zone == 1
      assert result.delay_s == 0.05
      refute result.blocked
    end

    test "a fault at 110% is in zone 2, not zone 1" do
      result = zone_of(fault_at(1.1))

      assert result.zone == 2
      assert result.delay_s == 0.40
      refute Protection.inside_mho?(fault_at(1.1), result.reaches[1])
    end

    test "a fault on the adjacent line is zone 3 backup" do
      result = zone_of(fault_at(2.0))

      assert result.zone == 3
      assert result.delay_s == 1.50
    end

    test "a fault beyond every reach operates nothing" do
      result = zone_of(fault_at(6.0))

      assert result.zone == nil
      assert result.zone_reached == nil
      assert result.delay_s == :infinity
      refute result.blocked
    end

    test "the mho characteristic is directional — reverse flow never picks up" do
      {r, x} = fault_at(0.5)

      assert zone_of({-r, -x}).zone == nil
    end

    test "zone delays are ordered fastest-first and match the settings" do
      settings = Protection.distance_settings()

      assert settings.delays_s[1] < settings.delays_s[2]
      assert settings.delays_s[2] < settings.delays_s[3]
      assert zone_of(fault_at(0.5)).delay_s == settings.delays_s[1]
    end

    test "an infinite apparent impedance reports no zone and no angle" do
      result = zone_of(:infinite)

      assert result.zone == nil
      assert result.z_mag_pu == :infinity
      assert result.z_angle_deg == nil
    end

    test "reported magnitude and angle describe the measurement" do
      result = zone_of(fault_at(0.5))

      assert_in_delta result.z_mag_pu, Protection.impedance_magnitude(fault_at(0.5)), 1.0e-12
      assert_in_delta result.z_angle_deg, 84.289, 0.01
    end
  end

  describe "PRC-023-4 load blinder" do
    test "the loadability limit is V^2 / (1.5 * rating)" do
      # 400 MVA on a 100 MVA base is 4.0 pu; 0.85^2 / (1.5 * 4.0)
      assert_in_delta Protection.loadability_limit_pu(@rating_mva),
                      0.85 * 0.85 / (1.5 * 4.0),
                      1.0e-12
    end

    test "an unrated branch excludes nothing" do
      assert Protection.loadability_limit_pu(nil) == :infinity
      assert Protection.loadability_limit_pu(0.0) == :infinity
      assert Protection.prc023_load_point(nil) == :infinite
      refute Protection.load_encroachment?({1.0, 0.5}, nil)
    end

    test "the standard's own 150%/0.85 pu/30-degree point must NOT trip" do
      point = Protection.prc023_load_point(@rating_mva)

      # It really is inside zone 3's circle — that is why the blinder exists.
      result = zone_of(point, rating_mva: @rating_mva)
      assert result.zone_reached == 3
      assert result.blocked
      assert result.block_reason == :prc023_load_blinder
      assert result.zone == nil
      assert result.delay_s == :infinity

      # And the point is where the standard says it is.
      assert_in_delta Protection.impedance_angle_deg(point), 30.0, 1.0e-9

      assert_in_delta Protection.impedance_magnitude(point),
                      Protection.loadability_limit_pu(@rating_mva),
                      1.0e-12
    end

    test "heavy load inside zone 3's circle is excluded by the blinder" do
      # 0.15 pu at 25 degrees: beyond the loadability limit, at a load angle,
      # and (checked below) genuinely inside the zone 3 characteristic.
      load = z_at(0.15, 25.0)

      assert Protection.impedance_magnitude(load) >
               Protection.loadability_limit_pu(@rating_mva)

      unblocked = zone_of(load)
      assert unblocked.zone == 3

      blocked = zone_of(load, rating_mva: @rating_mva)
      assert blocked.zone_reached == 3
      assert blocked.zone == nil
      assert blocked.blocked
    end

    test "a real fault is at the line angle and is never blocked" do
      result = zone_of(fault_at(0.5), rating_mva: @rating_mva)

      assert result.zone == 1
      refute result.blocked
      refute Protection.load_encroachment?(fault_at(0.5), @rating_mva)
    end

    test "load heavier than the standard's point is outside the required envelope" do
      # Smaller |Z| than the limit is load more severe than PRC-023 requires
      # the relay to ride through, so the blinder does not claim it.
      inside_limit = z_at(Protection.loadability_limit_pu(@rating_mva) * 0.9, 25.0)

      refute Protection.load_encroachment?(inside_limit, @rating_mva)
    end

    test "load beyond the blinder angle is not claimed as load" do
      beyond_limit = Protection.loadability_limit_pu(@rating_mva) * 1.2

      assert Protection.load_encroachment?(z_at(beyond_limit, 30.0), @rating_mva)
      refute Protection.load_encroachment?(z_at(beyond_limit, 30.001), @rating_mva)
    end

    test "an infinite measurement is not load encroachment" do
      refute Protection.load_encroachment?(:infinite, @rating_mva)
    end

    test "branch_loadability_limit_pu uses the highest rating tier" do
      line = %{rating_a_mva: 400.0, rating_b_mva: 460.0, rating_c_mva: 540.0}

      assert Protection.branch_loadability_limit_pu(line) ==
               Protection.loadability_limit_pu(540.0)

      # A branch with only rate A gets the derived rate C.
      derived = %{rating_a_mva: 400.0}

      assert Protection.branch_loadability_limit_pu(derived) ==
               Protection.loadability_limit_pu(400.0 * PowerModel.Grid.Ratings.rate_c_factor())

      assert Protection.branch_loadability_limit_pu(%{}) == :infinity
    end
  end

  describe "distance_relay_trips/2" do
    test "trips the faulted line and leaves the loaded one alone" do
      branches = [
        %{
          component_type: :line,
          component_id: 1,
          z_line: @z_line,
          z_adjacent: @z_adjacent,
          rating_mva: @rating_mva,
          z_apparent: z_at(0.15, 25.0)
        },
        %{
          component_type: :line,
          component_id: 2,
          z_line: @z_line,
          z_adjacent: @z_adjacent,
          rating_mva: @rating_mva,
          z_apparent: fault_at(0.5)
        }
      ]

      assert [trip] = Protection.distance_relay_trips(branches)
      assert trip.component_id == 2
      assert trip.component_type == "transmission_line"
      assert trip.failure_cause == "distance_zone1"
      assert trip.details.zone == 1
      assert trip.details.delay_s == 0.05
    end

    test "accepts the voltage-and-flow form" do
      # 0.85 pu volts carrying 4.0 + j2.0 pu (400 MW / 200 MVAr, ~120% of a
      # 400 MVA line): Z = 0.1446 + j0.0723, 0.1616 pu at 26.6 degrees. Deep
      # inside zone 3's circle and pure load.
      branch = %{
        component_type: :line,
        component_id: 7,
        z_line: @z_line,
        z_adjacent: @z_adjacent,
        vm_pu: 0.85,
        p_pu: 4.0,
        q_pu: 2.0
      }

      assert [trip] = Protection.distance_relay_trips([branch])
      assert trip.details.zone == 3
      assert_in_delta trip.details.z_angle_deg, 26.565, 0.01

      # ...and with the rating known, the blinder holds it.
      assert Protection.distance_relay_trips([Map.put(branch, :rating_mva, @rating_mva)]) == []
    end

    test "orders trips fastest zone first" do
      branches =
        for {id, frac} <- [{1, 2.0}, {2, 0.5}, {3, 1.1}] do
          %{component_type: :line, component_id: id, z_line: @z_line, z_apparent: fault_at(frac)}
        end

      assert Protection.distance_relay_trips(branches) |> Enum.map(& &1.component_id) ==
               [2, 3, 1]
    end

    test "branches with no impedance or no flow are skipped, not crashed on" do
      branches = [
        %{component_type: :line, component_id: 1, z_apparent: fault_at(0.5)},
        %{component_type: :line, component_id: 2, z_line: @z_line},
        %{
          component_type: :line,
          component_id: 3,
          z_line: @z_line,
          vm_pu: 1.0,
          p_pu: 0.0,
          q_pu: 0.0
        }
      ]

      assert Protection.distance_relay_trips(branches) == []
    end

    test "transformers keep their own component type" do
      branch = %{
        component_type: :transformer,
        component_id: 9,
        z_line: @z_line,
        z_apparent: fault_at(0.5)
      }

      assert [trip] = Protection.distance_relay_trips([branch])
      assert trip.component_type == "transformer"
    end
  end

  # ===========================================================================
  # Two-timescale conductor thermal model (ROADMAP item 20)
  # ===========================================================================

  describe "conductor thermal model" do
    test "rate A loading settles at the continuous design temperature" do
      assert Protection.conductor_steady_state_temp_c(0.0) == 40.0
      assert Protection.conductor_steady_state_temp_c(1.0) == 75.0
      # Rise goes as the square of current.
      assert_in_delta Protection.conductor_steady_state_temp_c(1.5), 118.75, 1.0e-9
      # Direction of flow does not matter to I^2 R.
      assert Protection.conductor_steady_state_temp_c(-1.5) ==
               Protection.conductor_steady_state_temp_c(1.5)
    end

    test "a fresh state sits at ambient and has shed no time" do
      state = Protection.conductor_thermal_state()

      assert state.temp_c == 40.0
      assert state.elapsed_s == 0.0
      refute Protection.conductor_overtemperature?(state)
    end

    test "reaches 63% of the step in one time constant" do
      tau = Protection.conductor_thermal_defaults()[:tau_s]
      state = Protection.conductor_thermal_state()
      target = Protection.conductor_steady_state_temp_c(1.5)

      after_tau = Protection.advance_conductor_temperature(state, 1.5, tau)
      fraction = (after_tau.temp_c - state.temp_c) / (target - state.temp_c)

      assert_in_delta fraction, 1.0 - :math.exp(-1.0), 1.0e-12
      assert_in_delta fraction, 0.6321, 1.0e-4
      assert after_tau.elapsed_s == tau
      assert after_tau.steady_state_c == target
    end

    test "the update is the exact solution, so step size does not change it" do
      state = Protection.conductor_thermal_state()

      one_step = Protection.advance_conductor_temperature(state, 1.5, 600.0)

      many_steps =
        Enum.reduce(1..600, state, fn _, s ->
          Protection.advance_conductor_temperature(s, 1.5, 1.0)
        end)

      assert_in_delta one_step.temp_c, many_steps.temp_c, 1.0e-9
    end

    test "a brief spike does not trip; sustained overload does" do
      state = Protection.conductor_thermal_state()

      spike = Protection.advance_conductor_temperature(state, 1.5, 10.0)
      refute Protection.conductor_overtemperature?(spike)
      assert spike.temp_c < 42.0

      sustained =
        Enum.reduce(1..40, state, fn _, s ->
          Protection.advance_conductor_temperature(s, 1.5, 60.0)
        end)

      assert Protection.conductor_overtemperature?(sustained)
    end

    test "sustained loading below the emergency steady state NEVER trips" do
      state = Protection.conductor_thermal_state()

      # 35 * m^2 = 60 at m = 1.309; below that the conductor asymptotes under
      # the 100 C limit however long the overload lasts.
      day =
        Enum.reduce(1..1440, state, fn _, s ->
          Protection.advance_conductor_temperature(s, 1.3, 60.0)
        end)

      refute Protection.conductor_overtemperature?(day)
      assert Protection.conductor_trip_time_s(state, 1.3) == :infinity
      assert Protection.conductor_trip_time_s(state, 1.0) == :infinity
    end

    test "the predicted trip time matches the integration" do
      state = Protection.conductor_thermal_state()
      predicted = Protection.conductor_trip_time_s(state, 1.5)

      assert is_float(predicted)
      assert predicted > 900.0 and predicted < 1200.0

      just_before = Protection.advance_conductor_temperature(state, 1.5, predicted - 5.0)
      just_after = Protection.advance_conductor_temperature(state, 1.5, predicted + 5.0)

      refute Protection.conductor_overtemperature?(just_before)
      assert Protection.conductor_overtemperature?(just_after)
    end

    test "an already-hot conductor trips immediately" do
      hot = %{Protection.conductor_thermal_state() | temp_c: 105.0}

      assert Protection.conductor_overtemperature?(hot)
      assert Protection.conductor_trip_time_s(hot, 1.5) == 0.0
    end

    test "unloading cools the conductor back toward ambient" do
      hot =
        Enum.reduce(1..40, Protection.conductor_thermal_state(), fn _, s ->
          Protection.advance_conductor_temperature(s, 1.5, 60.0)
        end)

      cooled =
        Enum.reduce(1..40, hot, fn _, s ->
          Protection.advance_conductor_temperature(s, 0.0, 60.0)
        end)

      assert cooled.temp_c < hot.temp_c
      assert cooled.temp_c > 40.0
      assert_in_delta cooled.temp_c, 40.0, 3.0
    end

    test "it is the SLOW timescale — the inverse-time relay wins the race" do
      # 1.5x rate A is 1.11x rate C, where the cascade's IEC element already
      # picks up. The relay must get there first; if the thermal model were
      # faster it would be duplicating the relay rather than complementing it.
      relay_s =
        Protection.overcurrent_trip_time(1.5 / PowerModel.Grid.Ratings.rate_c_factor() * 100.0)

      thermal_s = Protection.conductor_trip_time_s(Protection.conductor_thermal_state(), 1.5)

      assert relay_s < thermal_s
    end

    test "a nil state starts from ambient" do
      assert Protection.advance_conductor_temperature(nil, 1.0, 0.0).temp_c == 40.0
    end

    test "settings are overridable and the defaults are the single source" do
      defaults = Protection.conductor_thermal_defaults()

      assert defaults[:ambient_c] == 40.0
      assert defaults[:emergency_c] == 100.0

      hot_day = Protection.conductor_thermal_state(ambient_c: 45.0)
      assert hot_day.temp_c == 45.0

      assert Protection.conductor_steady_state_temp_c(1.0, ambient_c: 45.0, rated_rise_c: 30.0) ==
               75.0
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

  # ===========================================================================
  # PRC-024 Attachment 2 generator voltage protection (ROADMAP item 20)
  # ===========================================================================

  describe "generator_voltage_trips/4" do
    defp fleet(n \\ 2) do
      for i <- 1..n, do: %{id: i, bus_id: 100 + i, p_max_mw: 500.0, capacity_factor: 0.8}
    end

    # Hold `vm_pu` at every generator's bus for `seconds`, stepping `dt`.
    # Returns `{all_trips, state}` so a test can look at both.
    defp hold(generators, vm_pu, seconds, opts) do
      dt = Keyword.get(opts, :dt, 0.05)
      state = Keyword.get(opts, :state)
      steps = max(round(seconds / dt), 1)

      Enum.reduce(1..steps, {[], state}, fn _step, {acc, st} ->
        voltages =
          Map.new(generators, fn gen -> {gen.bus_id, vm_pu} end)

        {trips, st} = Protection.generator_voltage_trips(generators, voltages, st, dt)
        {acc ++ trips, st}
      end)
    end

    test "a point inside the no-trip zone never trips, however long it is held" do
      # 0.95 pu and 1.05 pu are both inside the continuous band: no envelope
      # bounds their duration at all.
      assert {[], _} = hold(fleet(), 0.95, 600.0, dt: 1.0)
      assert {[], _} = hold(fleet(), 1.05, 600.0, dt: 1.0)

      # 0.90 pu is the boundary itself, and the band is "<0.90" — exclusive.
      assert {[], _} = hold(fleet(), 0.90, 600.0, dt: 1.0)
    end

    test "a shallow dip does not trip: 0.70 pu for 100 ms is inside the zone" do
      assert {[], _} = hold(fleet(), 0.70, 0.1, dt: 0.1)
    end

    test "a 0.60 pu excursion trips only after its boundary duration" do
      # 0.60 pu sits below 0.65, whose allowance is 0.30 s. It is also below
      # 0.75 and 0.90, but those allowances are far away.
      assert {[], state} = hold(fleet(), 0.60, 0.25, dt: 0.05)

      {trips, _} = hold(fleet(), 0.60, 0.10, dt: 0.05, state: state)

      assert length(trips) == 2
      assert Enum.all?(trips, &(&1.failure_cause == "undervoltage_trip"))
      assert Enum.all?(trips, &(&1.details.band_pu == 0.65))
      assert Enum.all?(trips, &(&1.details.allowance_s == 0.30))
      assert Enum.all?(trips, &(&1.details.time_in_band_s > 0.30))
      assert Enum.all?(trips, &(&1.component_type == "generator"))
      assert Enum.map(trips, & &1.component_id) |> Enum.sort() == [1, 2]
    end

    test "the deepest band binds: 0.40 pu gets 0.15 s and not the 0.30 s above it" do
      assert {[], state} = hold(fleet(1), 0.40, 0.10, dt: 0.05)

      {trips, _} = hold(fleet(1), 0.40, 0.10, dt: 0.05, state: state)

      assert [trip] = trips
      assert trip.details.band_pu == 0.45
      assert trip.details.allowance_s == 0.15
    end

    test "the shallowest band still has a limit: 0.85 pu survives 2.9 s and not 3.1" do
      assert {[], state} = hold(fleet(1), 0.85, 2.9, dt: 0.1)

      {trips, _} = hold(fleet(1), 0.85, 0.2, dt: 0.1, state: state)

      assert [trip] = trips
      assert trip.details.band_pu == 0.90
      assert trip.details.allowance_s == 3.0
    end

    test "recovery into the continuous band resets the timers" do
      # Most of the 0.65 pu band's allowance is spent...
      {[], state} = hold(fleet(1), 0.60, 0.25, dt: 0.05)

      # ...then the voltage recovers, which ENDS the excursion.
      {[], state} = hold(fleet(1), 1.00, 1.0, dt: 0.1, state: state)

      # The same dip that would have finished it now starts from zero.
      assert {[], state} = hold(fleet(1), 0.60, 0.25, dt: 0.05, state: state)
      assert {[_], _} = hold(fleet(1), 0.60, 0.10, dt: 0.05, state: state)
    end

    test "climbing out of a band without recovering does NOT reset it" do
      # PRC-024 Attachment 2's clarifications make the envelope CUMULATIVE.
      # 0.2 s below 0.65 pu, then a spell at 0.80 pu (still an excursion —
      # below 0.90 — but out of the 0.65 band), then back down: the 0.65
      # timer resumes from 0.2 s rather than restarting.
      {[], state} = hold(fleet(1), 0.60, 0.20, dt: 0.05)
      {[], state} = hold(fleet(1), 0.80, 1.0, dt: 0.1, state: state)

      {trips, _} = hold(fleet(1), 0.60, 0.15, dt: 0.05, state: state)

      assert [trip] = trips
      assert trip.details.band_pu == 0.65
      assert_in_delta trip.details.time_in_band_s, 0.35, 1.0e-9
    end

    test "the high side is symmetric in shape" do
      # 1.05 pu is continuous; 1.12 pu gets a second; 1.25 pu gets nothing.
      assert {[], _} = hold(fleet(1), 1.05, 60.0, dt: 1.0)

      assert {[], state} = hold(fleet(1), 1.12, 0.9, dt: 0.1)
      {timed, _} = hold(fleet(1), 1.12, 0.2, dt: 0.1, state: state)
      assert [trip] = timed
      assert trip.failure_cause == "overvoltage_trip"
      assert trip.details.band_pu == 1.100
      assert trip.details.allowance_s == 1.00

      {instant, _} = Protection.generator_voltage_trips(fleet(1), 1.25, nil, 0.0)
      assert [trip] = instant
      assert trip.failure_cause == "overvoltage_trip"
      assert trip.details.band_pu == 1.200
      assert trip.details.allowance_s == 0.0
    end

    test "a bus missing from the voltage map keeps its timers" do
      generators = fleet(1)

      {[], state} = hold(generators, 0.60, 0.25, dt: 0.05)
      before = state.generators[1].lv

      # An empty map is a missing READING, not a recovered voltage.
      {trips, held} = Protection.generator_voltage_trips(generators, %{}, state, 5.0)

      assert trips == []
      assert held.generators[1].lv == before

      # And the excursion resumes where it left off.
      assert {[_], _} = hold(generators, 0.60, 0.10, dt: 0.05, state: held)
    end

    test "a generator trips at most once" do
      generators = fleet(1)

      {trips, state} = hold(generators, 0.30, 1.0, dt: 0.05)
      assert length(trips) == 1

      {again, _} = hold(generators, 0.30, 1.0, dt: 0.05, state: state)
      assert again == []
    end

    test "offline units have no breaker left to open" do
      generators = [
        %{id: 1, bus_id: 1, p_max_mw: 500.0, capacity_factor: 0.8},
        %{id: 2, bus_id: 1, p_max_mw: 0.0, capacity_factor: 1.0},
        %{id: 3, bus_id: 1, p_max_mw: 500.0, capacity_factor: 0.0}
      ]

      {trips, _} = hold(generators, 0.30, 1.0, dt: 0.05)
      assert Enum.map(trips, & &1.component_id) == [1]
    end

    test "an island-wide scalar voltage stands in for a per-bus map" do
      {trips, _} = Protection.generator_voltage_trips(fleet(2), 0.30, nil, 1.0)
      assert length(trips) == 2
    end

    test "the deepest sag sorts ahead of the highest swell" do
      generators = [
        %{id: :sag, bus_id: 1, p_max_mw: 500.0, capacity_factor: 1.0},
        %{id: :swell, bus_id: 2, p_max_mw: 500.0, capacity_factor: 1.0}
      ]

      {trips, _} =
        Protection.generator_voltage_trips(generators, %{1 => 0.30, 2 => 1.25}, nil, 1.0)

      assert Enum.map(trips, & &1.component_id) == [:sag, :swell]
    end

    test "the envelopes are exposed as the single source of truth" do
      assert Protection.undervoltage_envelope() == [
               {0.45, 0.15},
               {0.65, 0.30},
               {0.75, 2.00},
               {0.90, 3.00}
             ]

      assert Protection.overvoltage_envelope() == [
               {1.200, 0.0},
               {1.175, 0.20},
               {1.150, 0.50},
               {1.100, 1.00}
             ]

      assert Protection.continuous_voltage_band() == {0.90, 1.100}
    end

    test "monotone in depth: a deeper sag never trips fewer units" do
      counts =
        for vm <- [0.95, 0.88, 0.80, 0.74, 0.64, 0.44] do
          {trips, _} = hold(fleet(4), vm, 2.5, dt: 0.05)
          length(trips)
        end

      assert counts == Enum.sort(counts)
      assert List.last(counts) == 4
    end
  end

  describe "voltage state threading across island splits" do
    test "splitting apportions by key and conserves every timer" do
      generators = [
        %{id: 1, bus_id: 1, p_max_mw: 100.0, capacity_factor: 1.0},
        %{id: 2, bus_id: 2, p_max_mw: 100.0, capacity_factor: 1.0},
        %{id: 3, bus_id: 3, p_max_mw: 100.0, capacity_factor: 1.0}
      ]

      {[], state} =
        Protection.generator_voltage_trips(
          generators,
          %{1 => 0.60, 2 => 0.60, 3 => 0.60},
          nil,
          0.2
        )

      left = Protection.split_voltage_state(state, [1, 2])
      right = Protection.split_voltage_state(state, [3])

      assert Map.keys(left.generators) |> Enum.sort() == [1, 2]
      assert Map.keys(right.generators) == [3]

      # Intensive, so no scaling: each half keeps the timers it had.
      assert left.generators[1] == state.generators[1]
      assert right.generators[3] == state.generators[3]

      # And the split halves still trip on the same total exposure.
      assert {[_], _} =
               Protection.generator_voltage_trips(
                 [Enum.at(generators, 2)],
                 %{3 => 0.60},
                 right,
                 0.15
               )
    end

    test "merging re-joined islands keeps the longest timer and any trip" do
      generators = [%{id: 1, bus_id: 1, p_max_mw: 100.0, capacity_factor: 1.0}]

      {[], short} = Protection.generator_voltage_trips(generators, %{1 => 0.60}, nil, 0.1)
      {[], long} = Protection.generator_voltage_trips(generators, %{1 => 0.60}, nil, 0.25)

      merged = Protection.merge_voltage_states([short, long])
      assert merged.generators[1] == long.generators[1]

      {[_], tripped} = Protection.generator_voltage_trips(generators, %{1 => 0.60}, long, 0.1)
      assert Protection.merge_voltage_states([short, tripped]).generators[1].tripped
    end

    test "a nil state splits into a fresh one" do
      assert Protection.split_voltage_state(nil, [1]) == Protection.fresh_voltage_state()
      assert Protection.merge_voltage_states([nil, nil]) == Protection.fresh_voltage_state()
    end
  end

  describe "gfl_available_fraction/2 — current-ceiling form (default)" do
    test "the default ceiling is 1.2 pu and the knee is derived from it" do
      assert Protection.gfl_current_limit_pu() == 1.2
      assert_in_delta Protection.gfl_knee_pu(), 1.0 / 1.2, 1.0e-12

      # A lightly loaded unit does not reach its knee until far lower voltage.
      assert_in_delta Protection.gfl_knee_pu(0.5), 0.5 / 1.2, 1.0e-12
    end

    test "is unity at and above the knee" do
      assert Protection.gfl_available_fraction(Protection.gfl_knee_pu()) == 1.0
      assert Protection.gfl_available_fraction(0.95) == 1.0
      assert Protection.gfl_available_fraction(1.05) == 1.0
    end

    test "falls proportionally with voltage below the knee" do
      # min(1, V · I_max): the ceiling binds and P follows V down.
      assert_in_delta Protection.gfl_available_fraction(0.50), 0.60, 1.0e-12
      assert_in_delta Protection.gfl_available_fraction(0.35), 0.42, 1.0e-12
      assert Protection.gfl_available_fraction(0.0) == 0.0
    end

    test "0.70 pu is no longer unity — the salvaged knee flattered inverters" do
      # The prior architecture's flat 0.70 knee implied a 1.43 pu ceiling. Under
      # a 1.2 pu ceiling a fully loaded unit is already derated here.
      assert_in_delta Protection.gfl_available_fraction(0.70), 0.84, 1.0e-12
    end

    test "is continuous at the knee" do
      just_below = Protection.gfl_available_fraction(Protection.gfl_knee_pu() - 1.0e-9)
      assert_in_delta just_below, 1.0, 1.0e-8
    end

    test "is monotone in voltage" do
      fractions = for v <- 0..14, do: Protection.gfl_available_fraction(v / 10.0)
      assert fractions == Enum.sort(fractions)
    end

    test "loading moves the knee: a half-loaded unit rides much lower" do
      assert Protection.gfl_available_fraction(0.6, p_set_pu: 0.5) == 1.0
      assert_in_delta Protection.gfl_available_fraction(0.3, p_set_pu: 0.5), 0.72, 1.0e-12
    end

    test "an overridden ceiling applies directly" do
      # A fully loaded unit against a 1.0 pu ceiling delivers exactly V.
      assert_in_delta Protection.gfl_available_fraction(0.5, current_limit_pu: 1.0), 0.5, 1.0e-12
      assert Protection.gfl_available_fraction(0.6, current_limit_pu: 1.0, p_set_pu: 0.5) == 1.0
    end

    test "a unit dispatched above its ceiling is derated even at nominal voltage" do
      assert_in_delta Protection.gfl_available_fraction(1.0,
                        current_limit_pu: 1.0,
                        p_set_pu: 1.1
                      ),
                      1.0 / 1.1,
                      1.0e-12
    end

    test "clamps a negative voltage rather than returning a negative fraction" do
      assert Protection.gfl_available_fraction(-0.2) == 0.0
    end
  end

  describe "gfl_available_fraction/2 — knee form (opt in)" do
    test ":knee_pu reproduces the salvaged pre-reset shape" do
      assert Protection.gfl_available_fraction(0.70, knee_pu: 0.70) == 1.0
      assert Protection.gfl_available_fraction(0.95, knee_pu: 0.70) == 1.0
      assert_in_delta Protection.gfl_available_fraction(0.50, knee_pu: 0.70), 0.5 / 0.7, 1.0e-12
    end

    test ":knee_pu wins when both parameterizations are named" do
      assert Protection.gfl_available_fraction(0.70, knee_pu: 0.70, current_limit_pu: 1.0) == 1.0
    end

    test "a degenerate zero knee derates nothing" do
      assert Protection.gfl_available_fraction(0.1, knee_pu: 0.0) == 1.0
    end
  end

  describe "gfl_derate/3" do
    test "covers inverter-coupled units only" do
      generators = [
        %{id: 1, bus_id: 1, fuel_type: "SUN"},
        %{id: 2, bus_id: 1, fuel_type: "WND"},
        %{id: 3, bus_id: 1, fuel_type: "MWH"},
        %{id: 4, bus_id: 1, fuel_type: "NG"},
        %{id: 5, bus_id: 1, fuel_type: "AB"}
      ]

      fractions = Protection.gfl_derate(generators, %{1 => 0.35})

      assert Map.keys(fractions) |> Enum.sort() == [1, 2, 3]
      assert_in_delta fractions[1], 0.42, 1.0e-12
      # A synchronous machine has no ceiling of this kind: absent, read as 1.0.
      assert Map.get(fractions, 4, 1.0) == 1.0
      # Agricultural byproduct is a steam plant, not an inverter.
      assert Map.get(fractions, 5, 1.0) == 1.0
    end

    test "an explicit :inverter_based flag beats the fuel code" do
      generators = [
        %{id: 1, bus_id: 1, fuel_type: "NG", inverter_based: true},
        %{id: 2, bus_id: 1, fuel_type: "SUN", inverter_based: false}
      ]

      assert Map.keys(Protection.gfl_derate(generators, %{1 => 0.35})) == [1]
    end

    test "a bus with no measurement gets no derate" do
      generators = [%{id: 1, bus_id: 1, fuel_type: "SUN"}, %{id: 2, bus_id: 2, fuel_type: "SUN"}]

      assert Map.keys(Protection.gfl_derate(generators, %{1 => 0.35})) == [1]
    end

    test ":only narrows the pool, for the utility-scale carve-out" do
      generators = [
        %{id: 1, bus_id: 1, fuel_type: "SUN", utility_scale: true},
        %{id: 2, bus_id: 1, fuel_type: "SUN", utility_scale: false}
      ]

      fractions = Protection.gfl_derate(generators, %{1 => 0.35}, only: & &1.utility_scale)

      assert Map.keys(fractions) == [1]
    end
  end
end
