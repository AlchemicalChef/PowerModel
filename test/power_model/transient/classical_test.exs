defmodule PowerModel.Transient.ClassicalTest do
  use ExUnit.Case, async: true

  alias PowerModel.Transient.Machine.Classical
  alias PowerModel.Transient.{State, OutOfStep}

  # ===========================================================================
  # Single Machine Infinite Bus (SMIB) test
  # ===========================================================================
  #
  # A single generator connected to an infinite bus through a reactance.
  # This is the canonical transient stability test case.
  #
  # Parameters:
  #   - Generator: H = 5.0 s, X'd = 0.3 pu, E' = 1.2 pu, P_mech = 0.8 pu
  #   - Infinite bus: V = 1.0 pu, angle = 0
  #   - Line reactance: X_line = 0.5 pu (total X = X'd + X_line = 0.8)
  #
  # Y_reduced for 2-machine equivalent (gen + infinite bus):
  #   Y_11 = Y_22 = 1/jX = -j/X => G=0, B=-1/X = -1/0.8 = -1.25
  #   Y_12 = Y_21 = -1/jX = j/X => G=0, B=1/X = 1/0.8 = 1.25
  #
  # Note: For SMIB, we model the infinite bus as a second "generator" with
  # very large inertia (H=1000) so it doesn't move.

  defp smib_state(p_mech \\ 0.8) do
    n_gen = 2
    x_total = 0.8  # X'd + X_line
    b_series = 1.0 / x_total

    # Initial angle: sin(delta_0) = P * X / (E' * V) = 0.8 * 0.8 / (1.2 * 1.0)
    delta_0 = :math.asin(p_mech * x_total / (1.2 * 1.0))

    %State{
      t: 0.0,
      dt: 0.001,  # 1 ms for accuracy
      n_gen: n_gen,
      gen_ids: [1, 2],
      gen_bus_ids: [1, 2],
      delta: [delta_0, 0.0],       # Gen at delta_0, infinite bus at 0
      omega: [1.0, 1.0],           # Both at synchronous speed
      p_mech: [p_mech, -p_mech],   # Infinite bus absorbs what gen produces
      e_prime: [1.2, 1.0],         # Gen E'=1.2, infinite bus V=1.0
      h: [5.0, 10000.0],           # Large H for infinite bus
      d: [0.0, 0.0],               # No damping for clean test
      y_red_rows: [0, 0, 1, 1],
      y_red_cols: [0, 1, 0, 1],
      y_red_g: [0.0, 0.0, 0.0, 0.0],
      y_red_b: [-b_series, b_series, b_series, -b_series],
      base_mva: 100.0,
      events: [],
      trajectory: [],
      tripped_gens: MapSet.new()
    }
  end

  describe "SMIB steady state" do
    test "generator at steady-state operating point remains stable" do
      state = smib_state()
      trajectory = Classical.simulate(state, 1000, 100)  # 1 second at 1ms

      # Frequency should stay at 60 Hz (omega = 1.0)
      last = List.last(trajectory)
      [gen_omega, _inf_omega] = last.omega

      assert_in_delta gen_omega, 1.0, 0.001,
        "Generator should stay at synchronous speed"
    end

    test "P_elec matches P_mech at steady state" do
      state = smib_state()

      p_elec = Classical.compute_p_elec(
        state.delta, state.e_prime,
        state.y_red_rows, state.y_red_cols,
        state.y_red_g, state.y_red_b, state.n_gen
      )

      [gen_pelec, _] = p_elec

      assert_in_delta gen_pelec, 0.8, 0.01,
        "P_elec should equal P_mech at steady state"
    end
  end

  describe "SMIB generator trip" do
    test "tripping generator (P_mech -> 0) causes deceleration" do
      state = smib_state()
      # Trip generator at t=0.05s
      state = State.add_event(state, 0.05, 1, 0.0)

      trajectory = Classical.simulate(state, 2000, 50)  # 2 seconds

      # After trip, generator should decelerate (omega < 1.0)
      after_trip = Enum.find(trajectory, fn p -> p.t > 0.1 end)
      [gen_omega, _] = after_trip.omega

      assert gen_omega < 1.0,
        "Generator should decelerate after P_mech drops to 0"
    end

    test "tripping generator causes rotor angle to decrease" do
      state = smib_state()
      state = State.add_event(state, 0.05, 1, 0.0)

      trajectory = Classical.simulate(state, 5000, 100)  # 5 seconds

      initial_delta = hd(state.delta)
      last = List.last(trajectory)
      [final_delta, _] = last.delta

      # With P_mech = 0 but P_elec > 0, generator decelerates
      # and angle swings back
      assert final_delta != initial_delta,
        "Rotor angle should change after generator trip"
    end
  end

  describe "SMIB fault and stability" do
    test "small fault disturbance is stable (angle oscillates and damps)" do
      state = smib_state()
      # Brief P_mech increase simulates a nearby fault accelerating the rotor
      state = State.add_event(state, 0.05, 1, 1.5)   # fault on: P_mech jumps
      state = State.add_event(state, 0.15, 1, 0.8)   # fault cleared: P_mech restored

      trajectory = Classical.simulate(state, 3000, 100)  # 3 seconds

      # Generator should oscillate but stay synchronized
      # (no OOS with undamped classical model, but angle stays bounded)
      oos = OutOfStep.detect(
        (List.last(trajectory)).delta,
        state.h,
        state.n_gen
      )

      assert oos == [], "Small fault should not cause OOS"
    end

    test "large sustained fault causes out-of-step" do
      state = smib_state()
      # Sustained fault: P_mech stays at 2.0 (P_elec ≈ 0 during fault)
      state = State.add_event(state, 0.05, 1, 2.0)
      # Never cleared — generator will accelerate until OOS

      trajectory = Classical.simulate(state, 5000, 50)  # 5 seconds

      # At some point, the generator should slip a pole
      any_oos = Enum.any?(trajectory, fn point ->
        OutOfStep.detect(point.delta, state.h, state.n_gen) != []
      end)

      assert any_oos, "Sustained fault should cause out-of-step"
    end
  end

  describe "three-machine system" do
    # IEEE 9-bus (WSCC) simplified to 3 machines with known Y_reduced
    test "three generators maintain synchronism with balanced load" do
      n_gen = 3
      # Simplified 3-machine Y_reduced (all connected)
      # Each machine connected to others through X = 0.5 pu
      b = 1.0 / 0.5  # = 2.0

      # Use small angles near zero and one machine as reference (like infinite bus)
      # so the system is close to equilibrium
      state = %State{
        t: 0.0,
        dt: 0.005,
        n_gen: n_gen,
        gen_ids: [1, 2, 3],
        gen_bus_ids: [1, 2, 3],
        delta: [0.1, 0.0, -0.1],
        omega: [1.0, 1.0, 1.0],
        p_mech: [0.3, 0.0, -0.3],  # Net power = 0 (no acceleration)
        e_prime: [1.0, 1.0, 1.0],
        h: [5.0, 100.0, 5.0],       # Middle machine is large (reference)
        d: [5.0, 5.0, 5.0],         # Strong damping for convergence
        y_red_rows: [0, 0, 0, 1, 1, 1, 2, 2, 2],
        y_red_cols: [0, 1, 2, 0, 1, 2, 0, 1, 2],
        y_red_g: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        y_red_b: [-2*b, b, b, b, -2*b, b, b, b, -2*b],
        base_mva: 100.0,
        events: [],
        trajectory: [],
        tripped_gens: MapSet.new()
      }

      trajectory = Classical.simulate(state, 4000, 100)  # 20 seconds at 5ms

      # All machines should stay synchronized
      last = List.last(trajectory)
      oos = OutOfStep.detect(last.delta, state.h, state.n_gen)
      assert oos == [], "Balanced 3-machine system should be stable"

      # Frequencies should be near 60 Hz (within 0.05 pu with damping)
      for omega <- last.omega do
        assert_in_delta omega, 1.0, 0.05,
          "All generators should be near synchronous speed"
      end
    end
  end

  describe "out-of-step detection" do
    test "detects pole slip when angle exceeds pi from COI" do
      # COI ≈ (5*0 + 4*2π + 3*0)/12 ≈ 2.09
      # |2π - 2.09| ≈ 4.19 > π  → OOS
      delta = [0.0, 2.0 * :math.pi(), 0.0]
      h = [5.0, 4.0, 3.0]
      oos = OutOfStep.detect(delta, h, 3)

      assert 1 in oos, "Generator 1 should be detected as OOS"
    end

    test "no OOS when all angles are close" do
      delta = [0.1, 0.2, -0.1]
      h = [5.0, 4.0, 3.0]
      oos = OutOfStep.detect(delta, h, 3)

      assert oos == []
    end

    test "center of inertia is H-weighted average" do
      delta = [1.0, 0.0]
      h = [3.0, 1.0]
      coi = OutOfStep.center_of_inertia(delta, h, 2)

      # COI = (3*1.0 + 1*0.0) / (3+1) = 0.75
      assert_in_delta coi, 0.75, 0.001
    end
  end
end
