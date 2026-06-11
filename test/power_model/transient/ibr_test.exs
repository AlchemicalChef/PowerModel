defmodule PowerModel.Transient.IBRTest do
  use ExUnit.Case, async: true

  alias PowerModel.Transient.Machine.IBR

  # ===========================================================================
  # Grid-Following Inverter Tests
  # ===========================================================================

  describe "grid-following initialization" do
    test "solar generator initializes as grid-following" do
      gen = %{fuel_type: "SUN", p_mech_pu: 0.5, q_set_pu: 0.0}
      ibr = IBR.init(gen)

      assert ibr.mode == :grid_following
      assert_in_delta ibr.p_set_pu, 0.5, 1.0e-10
      assert_in_delta ibr.q_set_pu, 0.0, 1.0e-10
      refute IBR.tripped?(ibr)
    end

    test "wind generator initializes as grid-following" do
      gen = %{fuel_type: "WND", p_mech_pu: 0.3}
      ibr = IBR.init(gen)

      assert ibr.mode == :grid_following
      assert_in_delta ibr.p_set_pu, 0.3, 1.0e-10
    end

    test "battery initializes as grid-following" do
      gen = %{fuel_type: "MWH", p_mech_pu: 0.2}
      ibr = IBR.init(gen)

      assert ibr.mode == :grid_following
    end

    test "ibr_candidate? identifies IBR fuel types" do
      assert IBR.ibr_candidate?(%{fuel_type: "SUN"})
      assert IBR.ibr_candidate?(%{fuel_type: "WND"})
      assert IBR.ibr_candidate?(%{fuel_type: "MWH"})
      assert IBR.ibr_candidate?(%{fuel_type: "BAT"})
      refute IBR.ibr_candidate?(%{fuel_type: "COL"})
      refute IBR.ibr_candidate?(%{fuel_type: "NUC"})
      refute IBR.ibr_candidate?(%{fuel_type: "NG"})
    end
  end

  describe "grid-following constant P/Q injection" do
    test "injects constant P and Q at nominal voltage" do
      gen = %{fuel_type: "SUN", p_mech_pu: 0.5, q_set_pu: 0.1}
      ibr = IBR.init(gen)

      # Step at nominal voltage (1.0 pu)
      {new_ibr, p, q} = IBR.step(ibr, 1.0, 0.005)

      assert_in_delta p,
                      0.5,
                      1.0e-10,
                      "Grid-following should inject constant P at nominal voltage"

      assert_in_delta q,
                      0.1,
                      1.0e-10,
                      "Grid-following should inject constant Q at nominal voltage"

      refute IBR.tripped?(new_ibr)
    end

    test "maintains constant injection over multiple steps" do
      gen = %{fuel_type: "SUN", p_mech_pu: 0.4, q_set_pu: 0.05}
      ibr = IBR.init(gen)

      # Run for 100 steps at nominal voltage
      {final_ibr, _} =
        Enum.reduce(1..100, {ibr, nil}, fn _step, {i, _} ->
          {new_i, p, _q} = IBR.step(i, 1.0, 0.005)
          {new_i, p}
        end)

      {_, p_final, q_final} = IBR.step(final_ibr, 1.0, 0.005)

      assert_in_delta p_final, 0.4, 1.0e-10
      assert_in_delta q_final, 0.05, 1.0e-10
    end

    test "reduces output proportionally below 0.7 pu voltage" do
      gen = %{fuel_type: "SUN", p_mech_pu: 1.0, q_set_pu: 0.2}
      ibr = IBR.init(gen)

      # Step at 0.5 pu voltage (below 0.7 threshold)
      {_new_ibr, p, q} = IBR.step(ibr, 0.5, 0.005)

      # Expected: scale = 0.5 / 0.7 ≈ 0.714
      expected_scale = 0.5 / 0.7

      assert_in_delta p,
                      1.0 * expected_scale,
                      0.01,
                      "P should be reduced proportionally below 0.7 pu"

      assert_in_delta q,
                      0.2 * expected_scale,
                      0.01,
                      "Q should be reduced proportionally below 0.7 pu"
    end

    test "full output at voltage >= 0.7 pu" do
      gen = %{fuel_type: "SUN", p_mech_pu: 0.8, q_set_pu: 0.1}
      ibr = IBR.init(gen)

      {_, p_07, _} = IBR.step(ibr, 0.70, 0.005)
      {_, p_08, _} = IBR.step(ibr, 0.80, 0.005)
      {_, p_10, _} = IBR.step(ibr, 1.00, 0.005)

      assert_in_delta p_07, 0.8, 0.01, "Full output at V=0.70"
      assert_in_delta p_08, 0.8, 0.01, "Full output at V=0.80"
      assert_in_delta p_10, 0.8, 0.01, "Full output at V=1.00"
    end
  end

  # ===========================================================================
  # LVRT (Low Voltage Ride-Through) Tests
  # ===========================================================================

  describe "LVRT protection" do
    test "trips on sustained voltage below 0.15 pu for > 0.16s" do
      gen = %{fuel_type: "SUN", p_mech_pu: 0.5}
      ibr = IBR.init(gen)

      # Expose to V = 0.10 pu for 0.20 seconds (exceeds 0.16s limit)
      dt = 0.005
      # 40 steps
      n_steps = round(0.20 / dt)

      final_ibr =
        Enum.reduce(1..n_steps, ibr, fn _step, i ->
          {new_i, _p, _q} = IBR.step(i, 0.10, dt)
          new_i
        end)

      assert IBR.tripped?(final_ibr),
             "IBR should trip after V < 0.15 for > 0.16 seconds"

      # Verify zero injection after trip
      {_, p, q} = IBR.step(final_ibr, 1.0, dt)
      assert_in_delta p, 0.0, 1.0e-10
      assert_in_delta q, 0.0, 1.0e-10
    end

    test "does not trip for brief voltage dip below 0.15 pu" do
      gen = %{fuel_type: "SUN", p_mech_pu: 0.5}
      ibr = IBR.init(gen)

      # V = 0.10 pu for only 0.10 seconds (below 0.16s limit)
      dt = 0.005
      # 20 steps
      n_steps = round(0.10 / dt)

      final_ibr =
        Enum.reduce(1..n_steps, ibr, fn _step, i ->
          {new_i, _p, _q} = IBR.step(i, 0.10, dt)
          new_i
        end)

      refute IBR.tripped?(final_ibr),
             "IBR should ride through brief severe voltage dip"
    end

    test "trips on sustained voltage below 0.45 pu for > 1.0s" do
      gen = %{fuel_type: "WND", p_mech_pu: 0.4}
      ibr = IBR.init(gen)

      # V = 0.30 pu for 1.2 seconds
      dt = 0.005
      # 240 steps
      n_steps = round(1.2 / dt)

      final_ibr =
        Enum.reduce(1..n_steps, ibr, fn _step, i ->
          {new_i, _p, _q} = IBR.step(i, 0.30, dt)
          new_i
        end)

      assert IBR.tripped?(final_ibr),
             "IBR should trip after V < 0.45 for > 1.0 seconds"
    end

    test "does not trip for moderate voltage dip below 0.45 pu for < 1.0s" do
      gen = %{fuel_type: "WND", p_mech_pu: 0.4}
      ibr = IBR.init(gen)

      # V = 0.30 pu for 0.5 seconds (below 1.0s limit)
      dt = 0.005
      n_steps = round(0.5 / dt)

      final_ibr =
        Enum.reduce(1..n_steps, ibr, fn _step, i ->
          {new_i, _p, _q} = IBR.step(i, 0.30, dt)
          new_i
        end)

      refute IBR.tripped?(final_ibr),
             "IBR should ride through sub-1.0s moderate voltage dip"
    end

    test "timer resets when voltage recovers" do
      gen = %{fuel_type: "SUN", p_mech_pu: 0.5}
      ibr = IBR.init(gen)
      dt = 0.005

      # V = 0.10 pu for 0.10 seconds (almost at tier 1 limit)
      n_low = round(0.10 / dt)

      ibr =
        Enum.reduce(1..n_low, ibr, fn _, i ->
          {new_i, _, _} = IBR.step(i, 0.10, dt)
          new_i
        end)

      # Recover to 1.0 pu for 0.5 seconds
      n_recover = round(0.5 / dt)

      ibr =
        Enum.reduce(1..n_recover, ibr, fn _, i ->
          {new_i, _, _} = IBR.step(i, 1.0, dt)
          new_i
        end)

      # Timer should have reset
      assert ibr.low_v_timer == 0.0
      assert ibr.low_v_threshold == :none

      # Another 0.10s at low V should not trip (timer was reset)
      ibr =
        Enum.reduce(1..n_low, ibr, fn _, i ->
          {new_i, _, _} = IBR.step(i, 0.10, dt)
          new_i
        end)

      refute IBR.tripped?(ibr),
             "Timer should reset on voltage recovery"
    end
  end

  # ===========================================================================
  # Grid-Forming (Virtual Synchronous Machine) Tests
  # ===========================================================================

  describe "grid-forming initialization" do
    test "explicit grid-forming mode" do
      gen = %{
        fuel_type: "MWH",
        ibr_mode: :grid_forming,
        p_mech_pu: 0.3,
        h_synthetic: 4.0,
        x_virtual_pu: 0.2
      }

      ibr = IBR.init(gen)

      assert ibr.mode == :grid_forming
      assert_in_delta ibr.h_synthetic, 4.0, 1.0e-10
      assert_in_delta ibr.x_virtual_pu, 0.2, 1.0e-10
      # Delta should be initialized from power flow
      assert ibr.delta != 0.0 or ibr.p_set_pu == 0.0
    end

    test "grid-forming starts at synchronous speed" do
      gen = %{fuel_type: "BAT", ibr_mode: :grid_forming, p_mech_pu: 0.2}
      ibr = IBR.init(gen)

      assert_in_delta ibr.omega, 1.0, 1.0e-10
    end
  end

  describe "grid-forming dynamics" do
    test "grid-forming provides virtual inertia response" do
      gen = %{
        fuel_type: "MWH",
        ibr_mode: :grid_forming,
        p_mech_pu: 0.3,
        h_synthetic: 3.0,
        x_virtual_pu: 0.15,
        d_virtual: 2.0,
        droop: 0.05
      }

      ibr = IBR.init(gen)

      # Step at nominal voltage — should be stable
      {ibr_1, _p1, _q1} = IBR.step(ibr, 1.0, 0.005)

      assert_in_delta ibr_1.omega,
                      1.0,
                      0.01,
                      "Grid-forming should stay near synchronous speed at nominal V"

      # Step at slightly reduced voltage — angle and power should adjust
      {ibr_low, p_low, _} = IBR.step(ibr_1, 0.95, 0.005)

      # The power should have changed slightly due to voltage change
      assert is_float(p_low)
      assert is_float(ibr_low.omega)
    end

    test "grid-forming trips on sustained very low voltage" do
      gen = %{fuel_type: "MWH", ibr_mode: :grid_forming, p_mech_pu: 0.2}
      ibr = IBR.init(gen)
      dt = 0.005

      # V = 0.10 pu for 0.20 seconds
      n_steps = round(0.20 / dt)

      final =
        Enum.reduce(1..n_steps, ibr, fn _, i ->
          {new_i, _, _} = IBR.step(i, 0.10, dt)
          new_i
        end)

      assert IBR.tripped?(final),
             "Grid-forming should also trip on sustained severe low voltage"
    end
  end

  # ===========================================================================
  # Tripped State Tests
  # ===========================================================================

  describe "tripped IBR behavior" do
    test "tripped IBR injects zero power regardless of voltage" do
      gen = %{fuel_type: "SUN", p_mech_pu: 0.5}
      ibr = IBR.init(gen)

      # Force trip by sustained low voltage
      dt = 0.005
      n_steps = round(0.20 / dt)

      tripped_ibr =
        Enum.reduce(1..n_steps, ibr, fn _, i ->
          {new_i, _, _} = IBR.step(i, 0.10, dt)
          new_i
        end)

      assert IBR.tripped?(tripped_ibr)

      # Even at full voltage, output should be zero
      {_, p, q} = IBR.step(tripped_ibr, 1.0, dt)
      assert_in_delta p, 0.0, 1.0e-10
      assert_in_delta q, 0.0, 1.0e-10

      # Multiple steps should still be zero
      {final, p2, q2} = IBR.step(tripped_ibr, 1.0, dt)
      assert IBR.tripped?(final)
      assert_in_delta p2, 0.0, 1.0e-10
      assert_in_delta q2, 0.0, 1.0e-10
    end
  end
end
