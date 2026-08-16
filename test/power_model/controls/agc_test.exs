defmodule PowerModel.Controls.AGCTest do
  @moduledoc """
  Closed-loop secondary frequency control (ROADMAP Phase 4, Wave 3).

  The property under test throughout: primary response ARRESTS an excursion
  and secondary control ENDS it. Governor droop is proportional control, so an
  island that loses generation settles at an offset and stays there with its
  governors permanently deployed — arrested, but neither back at 60 Hz nor
  ready for the next trip. Everything below is a statement about the loop that
  closes that gap, and the closed-form cases are chosen so the arithmetic can
  be checked by hand.
  """
  # Not async: the ERCOT case reads the shared development fleet through
  # `PowerModel.FleetRepo` and sets the contingency-reserve application env.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias PowerModel.Controls.AGC
  alias PowerModel.Failure.Reserves
  alias PowerModel.FleetRepo
  alias PowerModel.Solver.Frequency

  @f0 60.0

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A unit at a chosen operating point, in the shape the cascade hands around.
  defp unit(id, fuel, nameplate, dispatched) do
    %{
      id: id,
      fuel_type: fuel,
      p_max_mw: dispatched,
      capacity_factor: 1.0,
      p_dispatch_mw: dispatched,
      p_nameplate_mw: nameplate
    }
  end

  # Two gas machines holding 20% headroom each: 1,600 MW out of 2,000 MW.
  defp toy_fleet, do: [unit(1, "NG", 1000.0, 800.0), unit(2, "NG", 1000.0, 800.0)]

  defp toy_load, do: 1600.0

  # ---------------------------------------------------------------------------
  # A segmented closed-loop driver
  # ---------------------------------------------------------------------------
  #
  # This is the shape Wave 3b wires into the cascade: one frequency segment per
  # AGC cycle, the controller reading the segment's MEAN frequency (which is
  # the ACE integral over the segment, not a sample of its endpoint) and its
  # setpoint deltas fed back as generation added — a NEGATIVE new imbalance in
  # `Frequency.simulate_with_state/4`'s `lost_mw` convention.

  defp closed_loop(fleet, load_mw, trip_mw, opts) do
    segment_s = Keyword.get(opts, :segment_s, 4.0)
    duration_s = Keyword.get(opts, :duration_s, 300.0)
    dt = Keyword.get(opts, :dt_seconds, 0.1)
    agc0 = Keyword.get(opts, :agc)

    {traj0, fstate0} =
      Frequency.simulate_with_state(fleet, loads(load_mw, 0.0), trip_mw,
        dt_seconds: dt,
        duration_seconds: segment_s
      )

    segments = max(round(duration_s / segment_s) - 1, 0)

    acc0 = %{trajectory: traj0, fstate: fstate0, fleet: fleet, agc: agc0, commands: []}

    result =
      Enum.reduce(1..segments//1, acc0, fn _i, acc ->
        t1 = acc.fstate.time
        f_mean = Frequency.mean_frequency(acc.trajectory, t1 - segment_s, t1)

        {agc, deltas} =
          if acc.agc,
            do: AGC.step(acc.agc, %{frequency_hz: f_mean}, segment_s),
            else: {nil, %{}}

        added = deltas |> Map.values() |> Enum.sum()
        fleet = raise_fleet(acc.fleet, deltas)

        {seg, fstate} =
          Frequency.simulate_with_state(
            fleet,
            loads(load_mw, acc.fstate.cumulative_shed_mw),
            -added,
            dt_seconds: dt,
            duration_seconds: segment_s,
            initial_state: acc.fstate
          )

        %{
          acc
          | trajectory: acc.trajectory ++ tl(seg),
            fstate: fstate,
            fleet: fleet,
            agc: agc,
            commands: [%{t: t1, added_mw: added} | acc.commands]
        }
      end)

    %{result | commands: Enum.reverse(result.commands)}
  end

  defp loads(load_mw, shed_mw), do: [%{id: 1, p_mw: load_mw - shed_mw, q_mvar: 0.0}]

  defp raise_fleet(fleet, deltas) do
    Enum.map(fleet, fn g ->
      case Map.get(deltas, g.id) do
        mw when is_number(mw) and mw != 0.0 ->
          %{g | p_max_mw: g.p_max_mw + mw, p_dispatch_mw: g.p_dispatch_mw + mw}

        _ ->
          g
      end
    end)
  end

  # The last instant at which the trajectory was outside the band, i.e. how
  # long restoration took.
  defp settling_time(trajectory, tol) do
    trajectory
    |> Enum.reverse()
    |> Enum.reduce_while(0.0, fn r, _acc ->
      if abs(r.frequency - @f0) <= tol, do: {:cont, r.time}, else: {:halt, r.time}
    end)
  end

  defp at_time(trajectory, t), do: Enum.find(trajectory, List.last(trajectory), &(&1.time >= t))

  # ===========================================================================
  # Area Control Error
  # ===========================================================================

  describe "area control error" do
    test "ACE < 0 means under-generation, matching the NERC sign convention" do
      state = AGC.init(toy_fleet(), load_mw: toy_load(), bias_mw_per_01hz: 100.0)

      # 0.1 Hz low on a 100 MW/0.1 Hz bias: the area is 100 MW short.
      assert_in_delta AGC.area_control_error(state, %{frequency_hz: 59.9}), -100.0, 1.0e-9

      # ...and the mirror image above 60 Hz.
      assert_in_delta AGC.area_control_error(state, %{frequency_hz: 60.1}), 100.0, 1.0e-9

      # At nominal there is nothing to correct.
      assert AGC.area_control_error(state, %{frequency_hz: @f0}) == 0.0
    end

    test "a step loss gives ACE = -10 B Δf, and the controller raises generation" do
      state = AGC.init(toy_fleet(), load_mw: toy_load(), bias_mw_per_01hz: 100.0)

      {state, deltas} = AGC.step(state, %{frequency_hz: 59.8}, 4.0)

      assert_in_delta state.ace_mw, -200.0, 1.0e-9
      assert map_size(deltas) == 2

      # Under-generation raises setpoints: every delta is positive.
      assert Enum.all?(deltas, fn {_id, mw} -> mw > 0.0 end)
    end

    test "the interchange term is carried when a tie schedule exists" do
      state = AGC.init(toy_fleet(), load_mw: toy_load(), bias_mw_per_01hz: 100.0)

      # Exporting 50 MW less than scheduled, at nominal frequency: 50 MW short.
      ace =
        AGC.area_control_error(state, %{
          frequency_hz: @f0,
          net_interchange_mw: 150.0,
          scheduled_interchange_mw: 200.0
        })

      assert_in_delta ace, -50.0, 1.0e-9

      # Both terms together.
      both =
        AGC.area_control_error(state, %{
          frequency_hz: 59.9,
          net_interchange_mw: 150.0,
          scheduled_interchange_mw: 200.0
        })

      assert_in_delta both, -150.0, 1.0e-9
    end

    test "an undisturbed island issues no setpoints at all" do
      state = AGC.init(toy_fleet(), load_mw: toy_load())

      # Exactly nominal, and inside the ±0.002 Hz noise floor: nothing moves,
      # and nothing accumulates for later.
      {state, deltas} = AGC.step(state, %{frequency_hz: @f0}, 4.0)
      assert deltas == %{}
      assert state.integral_mw_s == 0.0

      {state, deltas} = AGC.step(state, %{frequency_hz: 60.0015}, 4.0)
      assert deltas == %{}
      assert state.integral_mw_s == 0.0
      assert state.dispatched_mw == 0.0

      # A full hour of jitter inside the deadband still commands nothing.
      state =
        Enum.reduce(1..900, state, fn i, s ->
          f = @f0 + if(rem(i, 2) == 0, do: 0.0018, else: -0.0018)
          {s, deltas} = AGC.step(s, %{frequency_hz: f}, 4.0)
          assert deltas == %{}
          s
        end)

      assert state.dispatched_mw == 0.0
    end

    test "just outside the noise floor the controller does act" do
      state = AGC.init(toy_fleet(), load_mw: toy_load())

      {_state, deltas} = AGC.step(state, %{frequency_hz: 59.99}, 4.0)
      assert map_size(deltas) == 2
      assert Enum.all?(deltas, fn {_id, mw} -> mw > 0.0 end)
    end
  end

  # ===========================================================================
  # Which units regulate, and in what proportion
  # ===========================================================================

  describe "participation" do
    test "only governor-duty, synchronised units with headroom regulate" do
      fleet = [
        # regulates
        unit(1, "NG", 1000.0, 800.0),
        # no governor duty (base-loaded nuclear)
        unit(2, "NUC", 1000.0, 800.0),
        # no governor duty (inverter-based)
        unit(3, "WND", 1000.0, 500.0),
        # at its cap: nothing left to regulate with
        unit(4, "NG", 1000.0, 1000.0),
        # not synchronised: a tertiary resource, not an AGC one
        unit(5, "NG", 1000.0, 0.0),
        # regulates
        unit(6, "WAT", 500.0, 300.0)
      ]

      state = AGC.init(fleet, load_mw: 3000.0)
      assert AGC.participating_ids(state) == [1, 6]
      assert_in_delta AGC.reserve_capacity_mw(state), 400.0, 1.0e-9
    end

    test "factors follow available secondary ramp and sum to one" do
      # Gas ramps at 8%/min, coal at 2%/min: 4:1 on equal nameplate.
      fleet = [unit(1, "NG", 1000.0, 500.0), unit(2, "BIT", 1000.0, 500.0)]
      state = AGC.init(fleet, load_mw: 1000.0)

      assert_in_delta state.participation[1], 0.8, 1.0e-9
      assert_in_delta state.participation[2], 0.2, 1.0e-9
      assert_in_delta Enum.sum(Map.values(state.participation)), 1.0, 1.0e-12
    end

    test "real ramp data on the generator map overrides the fuel table" do
      fleet = [
        Map.put(unit(1, "NG", 1000.0, 500.0), :ramp_rate_mw_per_min, 10.0),
        unit(2, "NG", 1000.0, 500.0)
      ]

      state = AGC.init(fleet, load_mw: 1000.0)

      # 10 MW/min against the table's 80 MW/min.
      assert_in_delta state.participation[1], 10.0 / 90.0, 1.0e-9
    end
  end

  # ===========================================================================
  # The bias setting
  # ===========================================================================

  describe "frequency bias" do
    test "is the island's own natural response, floored at the BAL-005 1%" do
      fleet = toy_fleet()

      # Composition: two 1 GW gas machines at 40% duty share, answering the
      # 0.1 Hz reference less the 0.036 Hz governor deadband, plus load
      # damping D·P·Δf/f0.
      governor = 2 * (0.064 / 60.0 / 0.05 * 1000.0 * 0.40)
      load_term = 1.0 * toy_load() * 0.1 / 60.0

      assert_in_delta AGC.natural_response_mw_per_01hz(fleet, toy_load()),
                      governor + load_term,
                      1.0e-9

      state = AGC.init(fleet, load_mw: toy_load())
      assert_in_delta state.bias_mw_per_01hz, governor + load_term, 1.0e-9

      # A fleet whose composition responds with almost nothing still carries at
      # least 1% of peak demand per 0.1 Hz.
      weak = AGC.init([unit(1, "BLQ", 100.0, 50.0)], load_mw: 100_000.0)
      assert_in_delta weak.bias_mw_per_01hz, 1000.0, 1.0e-9
    end

    test "units with no governor duty contribute nothing to it" do
      assert AGC.unit_natural_response_mw_per_01hz(unit(1, "NUC", 1000.0, 800.0)) == 0.0
      assert AGC.unit_natural_response_mw_per_01hz(unit(2, "WND", 1000.0, 800.0)) == 0.0

      # ...nor does a machine that is not spinning.
      assert AGC.unit_natural_response_mw_per_01hz(unit(3, "NG", 1000.0, 0.0)) == 0.0
    end

    test "with B = β, |ACE| reads directly as the megawatts the island is short" do
      # This is the property the gains are dimensioned against: at the primary
      # settling point 10·β·|Δf| is the deficit itself.
      fleet = toy_fleet()
      state = AGC.init(fleet, load_mw: toy_load())
      beta = state.bias_mw_per_01hz

      # A 100 MW loss settles (against β) at Δf = -100/(10 β).
      df = -100.0 / (10.0 * beta)
      ace = AGC.area_control_error(state, %{frequency_hz: @f0 + df})

      assert_in_delta ace, -100.0, 1.0e-9
    end
  end

  # ===========================================================================
  # Cycle semantics
  # ===========================================================================

  describe "the 4-second cycle" do
    test "no setpoints are issued between cycle boundaries" do
      state = AGC.init(toy_fleet(), load_mw: toy_load())

      {state, d1} = AGC.step(state, %{frequency_hz: 59.9}, 1.0)
      {state, d2} = AGC.step(state, %{frequency_hz: 59.9}, 1.0)
      {state, d3} = AGC.step(state, %{frequency_hz: 59.9}, 1.0)
      assert d1 == %{} and d2 == %{} and d3 == %{}

      # ...but ACE has been accumulating the whole time.
      assert state.integral_mw_s < 0.0

      {state, d4} = AGC.step(state, %{frequency_hz: 59.9}, 1.0)
      assert map_size(d4) == 2
      assert state.cycles == 1
      assert state.since_cycle_s == 0.0
    end

    test "an arbitrary dt reaches the same command as the cycle it spans" do
      # A PI law is a function of the accumulated integral, not of how many
      # times it was sampled — so a caller stepping one 4 s cascade segment
      # gets exactly what four 1 s cycles would have produced.
      coarse = AGC.init(toy_fleet(), load_mw: toy_load())
      fine = AGC.init(toy_fleet(), load_mw: toy_load())

      {coarse, dc} = AGC.step(coarse, %{frequency_hz: 59.9}, 4.0)

      {fine, df} =
        Enum.reduce(1..4, {fine, %{}}, fn _i, {s, _} ->
          AGC.step(s, %{frequency_hz: 59.9}, 1.0)
        end)

      assert_in_delta coarse.dispatched_mw, fine.dispatched_mw, 1.0e-9
      assert_in_delta Enum.sum(Map.values(dc)), Enum.sum(Map.values(df)), 1.0e-9
    end

    test "a segment longer than a cycle still gets one command, ramped over it" do
      state = AGC.init(toy_fleet(), load_mw: toy_load())
      {state, deltas} = AGC.step(state, %{frequency_hz: 55.0}, 30.0)

      # Ramp is measured from the last command, not from the cycle length:
      # 30 s of 8%/min on 1,000 MW nameplate is 40 MW per machine.
      assert state.cycles == 1
      assert_in_delta Map.fetch!(deltas, 1), 40.0, 1.0e-6
      assert_in_delta Map.fetch!(deltas, 2), 40.0, 1.0e-6
    end
  end

  # ===========================================================================
  # Ramp and reserve limits
  # ===========================================================================

  describe "per-unit limits" do
    test "no unit moves faster than its own ramp" do
      # A deep excursion asks for far more than the fleet can ramp in 4 s.
      fleet = [unit(1, "NG", 1000.0, 500.0), unit(2, "BIT", 1000.0, 500.0)]
      state = AGC.init(fleet, load_mw: 1000.0)

      {state, deltas} = AGC.step(state, %{frequency_hz: 57.0}, 4.0)

      # 8%/min and 2%/min of 1,000 MW over 4 s.
      assert_in_delta Map.fetch!(deltas, 1), 80.0 * 4.0 / 60.0, 1.0e-9
      assert_in_delta Map.fetch!(deltas, 2), 20.0 * 4.0 / 60.0, 1.0e-9
      assert state.saturated?
    end

    test "a clipped unit's share is redistributed to units that still have room" do
      # Unit 2 has 5 MW of headroom against unit 1's 500 MW, but ramps fast
      # enough to be handed a large share by participation alone.
      fleet = [unit(1, "WAT", 1000.0, 500.0), unit(2, "WAT", 1000.0, 995.0)]
      state = AGC.init(fleet, load_mw: 1000.0)

      {_state, deltas} = AGC.step(state, %{frequency_hz: 59.0}, 60.0)

      # Unit 2 stops at its headroom...
      assert_in_delta Map.fetch!(deltas, 2), 5.0, 1.0e-6

      # ...and the command it could not take went to unit 1, which is nowhere
      # near its own 250 MW/min ramp limit over the minute.
      assert Map.fetch!(deltas, 1) > 5.0
    end

    test "the fleet is never raised past the reserve it carries" do
      fleet = toy_fleet()
      state = AGC.init(fleet, load_mw: toy_load())
      capacity = AGC.reserve_capacity_mw(state)

      # Ten minutes of a collapse-deep excursion.
      state =
        Enum.reduce(1..150, state, fn _i, s ->
          {s, _deltas} = AGC.step(s, %{frequency_hz: 57.0}, 4.0)
          s
        end)

      assert_in_delta AGC.dispatched_mw(state), capacity, 1.0e-6
      assert_in_delta AGC.reserve_remaining_mw(state), 0.0, 1.0e-6

      # Per unit, too.
      for {_id, mw} <- state.dispatched_by_unit, do: assert(mw <= 200.0 + 1.0e-6)
    end
  end

  # ===========================================================================
  # Anti-windup
  # ===========================================================================

  describe "anti-windup" do
    test "a saturated controller holds an honest ACE and does not overshoot" do
      fleet = toy_fleet()
      state = AGC.init(fleet, load_mw: toy_load())
      capacity = AGC.reserve_capacity_mw(state)

      # Ten minutes short by far more than the fleet carries.
      exhausted =
        Enum.reduce(1..150, state, fn _i, s ->
          {s, _} = AGC.step(s, %{frequency_hz: 58.0}, 4.0)
          s
        end)

      # The reserve is gone, the error persists, and the integrator has NOT
      # run away: what it holds is exactly the position the fleet reached.
      assert exhausted.saturated?
      assert exhausted.ace_mw < 0.0
      assert_in_delta AGC.dispatched_mw(exhausted), capacity, 1.0e-6

      # The commanded POSITION — both PI terms together — sits exactly on the
      # reserve the fleet carries, not somewhere far beyond it.
      commanded = -(exhausted.kp * exhausted.ace_mw + exhausted.ki * exhausted.integral_mw_s)
      assert_in_delta commanded, capacity, 1.0e-6

      # Recovery, over-frequency: a wound-up integrator would keep commanding
      # UP for as many cycles as it took to unwind the excess. This one
      # reverses on the very next cycle, because its integral never claimed
      # more than the fleet delivered.
      {reversed, deltas} = AGC.step(exhausted, %{frequency_hz: 60.5}, 4.0)
      assert map_size(deltas) == 2
      assert Enum.all?(deltas, fn {_id, mw} -> mw < 0.0 end)
      assert AGC.dispatched_mw(reversed) < capacity
      assert AGC.dispatched_mw(reversed) >= 0.0

      # Recovery to nominal: the proportional term's own contribution goes
      # away with the error it was answering, so the position eases back by
      # exactly that much and no more — the whole overshoot a saturated PI
      # loop is capable of here, and it is 5% of the error by construction.
      {_settled, deltas} = AGC.step(exhausted, %{frequency_hz: @f0}, 4.0)
      backdown = -Enum.sum(Map.values(deltas))
      assert backdown > 0.0
      assert backdown <= exhausted.kp * abs(exhausted.ace_mw) + 1.0e-9
    end

    test "the integrator is bounded by the reserve in both directions" do
      state = AGC.init(toy_fleet(), load_mw: toy_load())
      capacity = AGC.reserve_capacity_mw(state)

      wound =
        Enum.reduce(1..500, state, fn _i, s ->
          {s, _} = AGC.step(s, %{frequency_hz: 57.0}, 4.0)
          s
        end)

      assert -wound.ki * wound.integral_mw_s <= capacity + 1.0e-6

      # Over-frequency: AGC gives back what it added and stops at the
      # measured operating point — it does not curtail the dispatch below it.
      unwound =
        Enum.reduce(1..500, wound, fn _i, s ->
          {s, _} = AGC.step(s, %{frequency_hz: 63.0}, 4.0)
          s
        end)

      assert_in_delta AGC.dispatched_mw(unwound), 0.0, 1.0e-6
      assert Enum.all?(Map.values(unwound.dispatched_by_unit), &(&1 >= -1.0e-9))
    end
  end

  # ===========================================================================
  # Closed-loop restoration on a toy island
  # ===========================================================================

  describe "restoration on a two-generator island" do
    test "PI returns the island to 60 Hz and releases the governors" do
      fleet = toy_fleet()
      # 80 MW lost out of 1,600: deep enough to be a real event (the nadir
      # reaches 59.43 Hz) and shallow enough that no UFLS stage arms, so the
      # comparison is purely primary-versus-secondary.
      trip = 80.0

      open = closed_loop(fleet, toy_load(), trip, duration_s: 300.0)

      closed =
        closed_loop(fleet, toy_load(), trip,
          duration_s: 300.0,
          agc: AGC.init(fleet, load_mw: toy_load())
        )

      open_final = List.last(open.trajectory)
      closed_final = List.last(closed.trajectory)

      # Open loop: arrested, and stuck there. The governors are still holding
      # the island up, which is the primary reserve that is no longer
      # available for the next contingency.
      assert open_final.frequency < 59.9
      assert open_final.gov_response_mw > 10.0
      assert open_final.load_shed_mw == 0.0

      # Closed loop: back at nominal, with the governors released — secondary
      # control's two jobs, both done.
      assert_in_delta closed_final.frequency, @f0, 0.005
      assert_in_delta closed_final.gov_response_mw, 0.0, 1.0
      assert closed_final.load_shed_mw == 0.0

      # ...and the megawatts AGC dispatched are the megawatts that were lost.
      assert_in_delta AGC.dispatched_mw(closed.agc), trip, trip * 0.02

      # Restoration is monotone: no excursion above nominal on the way back.
      assert Enum.all?(closed.trajectory, &(&1.frequency <= @f0 + 0.01))

      # Single-digit minutes to inside ±0.01 Hz.
      settled = settling_time(closed.trajectory, 0.01)
      assert settled < 540.0, "restoration took #{settled} s"
    end

    test "recovery frees UFLS stages that armed but had not yet tripped" do
      # A loss deep enough to arm the first stage. Because the arming delay is
      # 0.1 s the stage still fires here; what the test pins is that the
      # frequency is back above every threshold long before the schedule could
      # walk any further down it.
      fleet = toy_fleet()

      closed =
        closed_loop(fleet, toy_load(), 200.0,
          duration_s: 300.0,
          agc: AGC.init(fleet, load_mw: toy_load())
        )

      final = List.last(closed.trajectory)

      # The first stage fired at the nadir; the deeper ones never did.
      assert final.load_shed_mw > 0.0
      assert final.load_shed_mw < toy_load() * 0.076
      assert_in_delta final.frequency, @f0, 0.01

      # AGC covered exactly what UFLS did not.
      assert_in_delta AGC.dispatched_mw(closed.agc), 200.0 - final.load_shed_mw, 2.0
    end
  end

  # ===========================================================================
  # Island splits
  # ===========================================================================

  describe "apportioning across an island split" do
    test "units follow their island, the integrator starts fresh, position survives" do
      fleet = [
        unit(1, "NG", 1000.0, 800.0),
        unit(2, "NG", 1000.0, 800.0),
        unit(3, "WAT", 500.0, 300.0)
      ]

      state = AGC.init(fleet, load_mw: 3000.0)
      {state, deltas} = AGC.step(state, %{frequency_hz: 59.5}, 4.0)

      assert state.integral_mw_s != 0.0
      assert map_size(deltas) == 3

      [north, south] =
        AGC.apportion(state, [
          %{unit_ids: [1, 2], load_mw: 2000.0},
          %{unit_ids: [3], load_mw: 1000.0}
        ])

      assert AGC.participating_ids(north) == [1, 2]
      assert AGC.participating_ids(south) == [3]

      # A new area's ACE is a new signal: the integrator resets in both.
      assert north.integral_mw_s == 0.0
      assert south.integral_mw_s == 0.0
      assert north.ace_mw == 0.0
      assert north.cycles == 0

      # What each machine has already been raised by is a property of the
      # machine, and it survives.
      assert_in_delta north.dispatched_mw + south.dispatched_mw,
                      AGC.dispatched_mw(state),
                      1.0e-9

      assert Map.keys(north.dispatched_by_unit) == [1, 2]
      assert Map.keys(south.dispatched_by_unit) == [3]

      # Participation and bias are recomputed from the surviving composition.
      assert_in_delta Enum.sum(Map.values(north.participation)), 1.0, 1.0e-12
      assert_in_delta south.participation[3], 1.0, 1.0e-12
      assert north.bias_mw_per_01hz < state.bias_mw_per_01hz
      assert south.bias_mw_per_01hz < state.bias_mw_per_01hz

      # Tie schedules do not survive a separation.
      assert north.scheduled_interchange_mw == 0.0
    end

    test "reserve accounting follows the split, so neither half can over-draw" do
      fleet = [unit(1, "NG", 1000.0, 800.0), unit(2, "NG", 1000.0, 800.0)]
      state = AGC.init(fleet, load_mw: 1600.0)

      # Raise both units for a while, then separate them.
      state =
        Enum.reduce(1..10, state, fn _i, s ->
          {s, _} = AGC.step(s, %{frequency_hz: 59.5}, 4.0)
          s
        end)

      [a, b] = AGC.apportion(state, [%{unit_ids: [1]}, %{unit_ids: [2]}])

      # Each child knows how much of its own unit's 200 MW headroom is spent.
      assert_in_delta AGC.reserve_remaining_mw(a) + AGC.reserve_remaining_mw(b),
                      AGC.reserve_remaining_mw(state),
                      1.0e-9

      assert AGC.reserve_capacity_mw(a) == 200.0
      assert AGC.reserve_remaining_mw(a) < 200.0

      # Driven to exhaustion, a child stops at ITS unit's headroom, not the
      # parent's.
      exhausted =
        Enum.reduce(1..200, a, fn _i, s ->
          {s, _} = AGC.step(s, %{frequency_hz: 57.0}, 4.0)
          s
        end)

      assert_in_delta AGC.dispatched_mw(exhausted), 200.0, 1.0e-6
    end

    test "units in no island are dropped, and the load is apportioned when unknown" do
      fleet = [unit(1, "NG", 1000.0, 800.0), unit(2, "NG", 1000.0, 800.0)]
      state = AGC.init(fleet, load_mw: 1600.0)

      [only] = AGC.apportion(state, [%{unit_ids: [1]}])

      assert AGC.participating_ids(only) == [1]
      # Half the base dispatch went with it, so half the load is assumed.
      assert_in_delta only.island_load_mw, 800.0, 1.0e-9
    end
  end

  # ===========================================================================
  # The contract with Reserves: never both tiers
  # ===========================================================================

  describe "AGC-fed secondary reserve" do
    setup do
      units = [unit(1, "NG", 1000.0, 800.0), unit(2, "BIT", 1000.0, 800.0)]
      state = AGC.init(units, load_mw: 1600.0)
      {state, deltas} = AGC.step(state, %{frequency_hz: 59.5}, 4.0)

      %{units: units, agc: state, deltas: deltas}
    end

    test "the secondary tier delivers what AGC dispatched, not what the clock allows",
         %{units: units, deltas: deltas} do
      requested = deltas |> Map.values() |> Enum.sum()

      agc_fed = Reserves.allocate(units, 400.0, 600.0, secondary: {:agc, deltas})
      clocked = Reserves.allocate(units, 400.0, 600.0)

      assert agc_fed.secondary_source == :agc
      assert clocked.secondary_source == :clock

      # Ten minutes on the clock offers the whole 400 MW of headroom; AGC
      # offers the ~7 MW the frequency error actually called for.
      assert_in_delta agc_fed.secondary_capability_mw, requested, 1.0e-9
      assert_in_delta clocked.secondary_capability_mw, 400.0, 1.0e-9
      assert agc_fed.secondary_mw < clocked.secondary_mw
    end

    test "the AGC tier ignores the clock entirely", %{units: units, deltas: deltas} do
      # The whole point: this tier is a measurement of the island, not of
      # elapsed time. Every elapsed value gives the same answer.
      for elapsed <- [0.0, 1.0, 30.0, 600.0, 86_400.0, :infinity] do
        alloc = Reserves.allocate(units, 400.0, elapsed, secondary: {:agc, deltas})

        assert_in_delta alloc.secondary_capability_mw,
                        deltas |> Map.values() |> Enum.sum(),
                        1.0e-9
      end
    end

    test "the two paths are alternatives, and neither can over-draw the fleet",
         %{units: units, deltas: deltas} do
      requested = deltas |> Map.values() |> Enum.sum()

      clocked = Reserves.allocate(units, 400.0, 600.0)
      agc_fed = Reserves.allocate(units, 400.0, 600.0, secondary: {:agc, deltas})

      # Whichever tier answers, no unit is raised past the headroom it has,
      # and the sustained draw never exceeds the fleet's physical reserve.
      for alloc <- [clocked, agc_fed] do
        for u <- units do
          assert Map.get(alloc.sustained_by_unit, u.id, 0.0) <=
                   u.p_nameplate_mw - u.p_dispatch_mw + 1.0e-9
        end

        assert alloc.secondary_mw + alloc.tertiary_mw <= 400.0 + 1.0e-9
      end

      # And the megawatts are never summed across paths: the AGC-fed secondary
      # tier is bounded by AGC's own dispatch, which is bounded by the same
      # headroom the clocked tier draws from. Running the same step through
      # both would raise the fleet by more than it carries.
      assert agc_fed.secondary_mw <= requested + 1.0e-9
      assert agc_fed.secondary_mw + clocked.secondary_mw > 400.0
    end

    test "tertiary stays on the clock in both modes", %{units: units, deltas: deltas} do
      # Before the start-up delay there is no tertiary anywhere...
      early = Reserves.allocate(units, 400.0, 60.0, secondary: {:agc, deltas})
      assert early.tertiary_capability_mw == 0.0

      # ...and past it the tier answers on elapsed time exactly as it always
      # did, with AGC's draw already deducted from each unit's headroom.
      late = Reserves.allocate(units, 400.0, 1200.0, secondary: {:agc, deltas})
      assert late.tertiary_capability_mw > 0.0

      requested = deltas |> Map.values() |> Enum.sum()
      clock_only = Reserves.allocate(units, 400.0, 1200.0)

      assert_in_delta late.tertiary_capability_mw + requested,
                      clock_only.secondary_capability_mw + clock_only.tertiary_capability_mw,
                      1.0
    end

    test "the legacy three-argument call is untouched", %{units: units} do
      assert Reserves.allocate(units, 400.0, 600.0) ==
               Reserves.allocate(units, 400.0, 600.0, [])

      assert Reserves.secondary_capability_mw(hd(units), 600.0) == 200.0
    end
  end

  # ===========================================================================
  # The ERCOT design contingency on the ingested fleet
  # ===========================================================================

  @trip_mw 1375.0

  describe "ERCOT's N-1 design contingency with AGC in the loop" do
    setup do
      case FleetRepo.connect() do
        :ok ->
          if FleetRepo.aggregate(PowerModel.Grid.Generator, :count) > 0 do
            :ok
          else
            {:skip, "development database has no ingested fleet"}
          end

        {:error, reason} ->
          {:skip, "development database unavailable: #{inspect(reason)}"}
      end
    end

    @tag :db
    @tag timeout: 600_000
    test "secondary control restores 60 Hz where primary response only arrests it" do
      %{fleet: fleet, load_mw: load_mw} = ercot_operating_point()

      agc = AGC.init(fleet, load_mw: load_mw)

      open = closed_loop(fleet, load_mw, @trip_mw, duration_s: 600.0)
      closed = closed_loop(fleet, load_mw, @trip_mw, duration_s: 600.0, agc: agc)

      report("open loop (primary + the clock-ramped tiers)", open, nil, load_mw)
      report("with AGC", closed, closed.agc, load_mw)

      open_final = List.last(open.trajectory)
      closed_final = List.last(closed.trajectory)

      # Primary response alone leaves a standing offset — arrested, not
      # restored, with the governors still holding the island up.
      assert open_final.frequency < 59.95
      assert open_final.gov_response_mw > 100.0

      # AGC closes it: back at nominal, and the governors released, which is
      # the primary reserve restored for the next contingency.
      assert_in_delta closed_final.frequency, @f0, 0.01
      assert closed_final.gov_response_mw < open_final.gov_response_mw * 0.1

      # BAL-002 gives 15 minutes for contingency-event recovery. This event is
      # an order of magnitude inside it.
      settled = settling_time(closed.trajectory, 0.01)

      assert settled < 540.0,
             "restoration took #{Float.round(settled, 1)} s (#{Float.round(settled / 60, 2)} min)"

      # Neither case sheds: ENE-19's hold-back is what pays for this.
      assert closed_final.load_shed_mw == 0.0
      assert_in_delta AGC.dispatched_mw(closed.agc), @trip_mw, @trip_mw * 0.05
    end

    @tag :db
    @tag timeout: 600_000
    test "AGC's contribution inside the nadir window leaves β in the BAL-003 band" do
      %{fleet: fleet, load_mw: load_mw} = ercot_operating_point()

      open = closed_loop(fleet, load_mw, @trip_mw, duration_s: 60.0)

      closed =
        closed_loop(fleet, load_mw, @trip_mw,
          duration_s: 60.0,
          agc: AGC.init(fleet, load_mw: load_mw)
        )

      # Two 4 s cycles fit inside the 10 s nadir window, and both are ramp
      # limited. Bound what they add.
      nadir_window_mw =
        closed.commands
        |> Enum.filter(&(&1.t <= Frequency.nadir_window_seconds()))
        |> Enum.map(& &1.added_mw)
        |> Enum.sum()

      beta_open = beta_of(open.trajectory)
      beta_closed = beta_of(closed.trajectory)

      IO.puts("""

      ── β with AGC in the loop ─────────────────────────────
        AGC MW inside the 10 s nadir window   #{Float.round(nadir_window_mw, 1)} MW (#{Float.round(nadir_window_mw / @trip_mw * 100, 2)}% of the trip)
        nadir      open #{Float.round(Frequency.nadir(open.trajectory), 4)} Hz   with AGC #{Float.round(Frequency.nadir(closed.trajectory), 4)} Hz
        β (20-52 s window)  open #{Float.round(beta_open, 0)}   with AGC #{Float.round(beta_closed, 0)} MW/0.1 Hz
      """)

      # The nadir is set by inertia and governor delivery rate; AGC's first two
      # ramp-limited cycles are a small fraction of the event.
      assert nadir_window_mw < @trip_mw * 0.25

      assert_in_delta Frequency.nadir(open.trajectory),
                      Frequency.nadir(closed.trajectory),
                      0.02

      # β measured with AGC running is HIGHER — the value-B window now
      # contains secondary MW as well as primary — but it stays inside the
      # ERCOT BAL-003 acceptance band the Phase 3 gate is written against.
      # (That gate itself measures the open-loop swing model, which AGC does
      # not touch: this is a bound on what wiring AGC into the cascade would
      # do to the same reading.)
      assert beta_closed > beta_open
      assert beta_open >= 381.0 * 0.7 and beta_open <= 700.0 * 1.3

      assert beta_closed <= 700.0 * 1.3,
             "β with AGC in the loop is #{Float.round(beta_closed, 0)} MW/0.1 Hz, above the ERCOT band"
    end
  end

  # ---------------------------------------------------------------------------
  # Database fixtures
  # ---------------------------------------------------------------------------

  defp beta_of(trajectory) do
    value_b = Frequency.mean_frequency(trajectory, 20.0, 52.0)
    df = @f0 - value_b
    if df > 0.0, do: @trip_mw / df * 0.1, else: :infinity
  end

  # ERCOT at the modal demand hour, dispatched with the ENE-19 contingency
  # reserve requirement held — the same operating point
  # `contingency_reserve_test.exs` accepts against.
  defp ercot_operating_point do
    alias PowerModel.Dispatch
    alias PowerModel.Grid.{Bus, Generator, Interconnection}

    hour = modal_demand_hour()

    generators =
      FleetRepo.all(
        from(g in Generator,
          join: b in Bus,
          on: b.id == g.bus_id,
          where: g.status == "in_service" and not is_nil(b.coordinates),
          select: %{
            id: g.id,
            bus_id: g.bus_id,
            fuel_type: g.fuel_type,
            prime_mover: g.prime_mover,
            p_max_mw: g.p_max_mw,
            p_min_mw: g.p_min_mw,
            summer_capacity_mw: g.summer_capacity_mw,
            winter_capacity_mw: g.winter_capacity_mw,
            capacity_factor: g.capacity_factor,
            status: g.status,
            utility_scale: g.utility_scale
          }
        )
      )

    bus_interconnection =
      FleetRepo.all(
        from(b in Bus,
          join: i in Interconnection,
          on: i.id == b.interconnection_id,
          select: {b.id, i.name}
        )
      )
      |> Map.new()

    Application.put_env(:power_model, :contingency_reserve_mw, Dispatch.contingency_reserves())
    on_exit(fn -> Application.delete_env(:power_model, :contingency_reserve_mw) end)

    {:ok, %{dispatch: dispatch}} =
      Dispatch.for_hour(generators, hour,
        bus_ba:
          FleetRepo.all(from(b in Bus, select: {b.id, b.balancing_authority_id})) |> Map.new(),
        bus_interconnection: bus_interconnection,
        fuel_totals: fuel_totals_at(hour),
        storage_profile: %{}
      )

    fleet =
      generators
      |> Enum.filter(&(Map.get(bus_interconnection, &1.bus_id) == "ERCOT"))
      |> Enum.map(&shape(&1, Map.get(dispatch, &1.id, 0.0)))

    %{fleet: fleet, load_mw: ercot_demand_mw(hour)}
  end

  defp shape(generator, mw) do
    generator
    |> Map.put(:p_max_mw, mw)
    |> Map.put(:capacity_factor, if(mw > 0.0, do: 1.0, else: 0.0))
    |> Map.put(:p_dispatch_mw, mw)
    |> Map.put(:p_nameplate_mw, generator.p_max_mw)
  end

  defp report(label, run, agc, load_mw) do
    traj = run.trajectory
    final = List.last(traj)

    IO.puts("""

    ── ERCOT N-1 (#{@trip_mw} MW), #{label} ──────────────────
      island load           #{Float.round(load_mw / 1000, 2)} GW
      nadir                 #{Float.round(Frequency.nadir(traj), 4)} Hz
      at 60 s               #{Float.round(at_time(traj, 60.0).frequency, 4)} Hz
      at 180 s              #{Float.round(at_time(traj, 180.0).frequency, 4)} Hz
      at 300 s              #{Float.round(at_time(traj, 300.0).frequency, 4)} Hz
      final                 #{Float.round(final.frequency, 5)} Hz @ #{final.time} s
      governor MW deployed  #{final.gov_response_mw}
      UFLS shed             #{final.load_shed_mw} MW
      inside +/-0.01 Hz at  #{Float.round(settling_time(traj, 0.01), 1)} s\
    #{if agc do
      "\n  AGC dispatched        #{Float.round(AGC.dispatched_mw(agc), 1)} MW on #{length(AGC.participating_ids(agc))} units" <> "\n  AGC bias B            #{Float.round(agc.bias_mw_per_01hz, 1)} MW/0.1 Hz" <> "\n  AGC reserve left      #{Float.round(AGC.reserve_remaining_mw(agc), 0)} MW of #{Float.round(AGC.reserve_capacity_mw(agc), 0)} MW" <> "\n  final ACE             #{Float.round(agc.ace_mw, 2)} MW"
    else
      ""
    end}
    """)
  end

  defp modal_demand_hour do
    FleetRepo.all(
      from(d in PowerModel.Demand.BADemandHour,
        group_by: d.timestamp_utc,
        select: {d.timestamp_utc, count(d.id)}
      )
    )
    |> Enum.max_by(fn {ts, n} -> {n, DateTime.to_unix(ts)} end)
    |> elem(0)
  end

  defp fuel_totals_at(hour) do
    FleetRepo.all(
      from(f in PowerModel.Demand.BAFuelHour,
        join: ba in PowerModel.Grid.BalancingAuthority,
        on: ba.code == f.ba_code,
        where: f.timestamp_utc == ^hour,
        select: {ba.id, f.fuel, f.net_generation_mw}
      )
    )
    |> Enum.reduce(%{}, fn {ba_id, fuel, mw}, acc ->
      Map.update(acc, ba_id, %{fuel => mw}, &Map.put(&1, fuel, mw))
    end)
  end

  defp ercot_demand_mw(hour) do
    alias PowerModel.Grid.{Bus, Interconnection, Load}

    demand =
      FleetRepo.all(
        from(d in PowerModel.Demand.BADemandHour,
          where: d.timestamp_utc == ^hour,
          select: {d.balancing_authority_id, d.demand_mw}
        )
      )
      |> Map.new()

    baseline =
      FleetRepo.all(
        from(l in Load,
          join: b in Bus,
          on: b.id == l.bus_id,
          join: i in Interconnection,
          on: i.id == b.interconnection_id,
          where: l.status == "in_service" and not is_nil(b.balancing_authority_id),
          group_by: [b.balancing_authority_id, i.name],
          select: {b.balancing_authority_id, i.name, sum(l.p_mw)}
        )
      )

    totals =
      Enum.reduce(baseline, %{}, fn {ba, _ic, mw}, acc ->
        Map.update(acc, ba, mw || 0.0, &(&1 + (mw || 0.0)))
      end)

    baseline
    |> Enum.filter(fn {_ba, ic, _mw} -> ic == "ERCOT" end)
    |> Enum.reduce(0.0, fn {ba, _ic, mw}, acc ->
      total = Map.get(totals, ba, 0.0)
      share = if total > 0.0, do: (mw || 0.0) / total, else: 0.0
      acc + (Map.get(demand, ba) || 0.0) * share
    end)
  end
end
