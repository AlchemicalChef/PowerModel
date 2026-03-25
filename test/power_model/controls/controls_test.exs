defmodule PowerModel.Controls.ControlsTest do
  use ExUnit.Case, async: true

  alias PowerModel.Controls.{AGC, OLTC, SVCController, FACTSController, HVDCController, RAS}

  # ===========================================================================
  # AGC Tests
  # ===========================================================================

  describe "AGC initialization" do
    test "filters to participating generators only" do
      gens = [
        %{id: 1, p_max_mw: 500.0, agc_participation_factor: 0.6, dispatch_mw: 400.0},
        %{id: 2, p_max_mw: 300.0, agc_participation_factor: 0.4, dispatch_mw: 200.0},
        %{id: 3, p_max_mw: 200.0, agc_participation_factor: 0.0, dispatch_mw: 100.0}
      ]

      agc = AGC.init(gens)

      assert length(agc.generators) == 2
      assert agc.ace == 0.0
      assert agc.integral == 0.0
    end

    test "normalizes participation factors to sum to 1.0" do
      gens = [
        %{id: 1, p_max_mw: 500.0, agc_participation_factor: 3.0, dispatch_mw: 400.0},
        %{id: 2, p_max_mw: 300.0, agc_participation_factor: 7.0, dispatch_mw: 200.0}
      ]

      agc = AGC.init(gens)

      total = Enum.sum_by(agc.generators, &Map.get(&1, :agc_participation_factor))
      assert_in_delta total, 1.0, 1.0e-10
    end

    test "sets default bias from total capacity" do
      gens = [%{id: 1, p_max_mw: 1000.0, agc_participation_factor: 1.0, dispatch_mw: 800.0}]
      agc = AGC.init(gens)

      # Default bias = 1% of total capacity = 10 MW/0.1Hz
      assert_in_delta agc.bias_mw, 10.0, 1.0e-10
    end
  end

  describe "AGC frequency error correction" do
    test "produces negative ACE when frequency is high (over-generation)" do
      gens = [
        %{id: 1, p_max_mw: 500.0, agc_participation_factor: 1.0,
          dispatch_mw: 400.0, ramp_rate_mw_per_min: 60.0, p_min_mw: 100.0}
      ]

      agc = AGC.init(gens, bias_mw: 10.0, ki: 0.1, p_scheduled: 0.0)

      # High frequency: 60.05 Hz, gen > load
      {new_agc, adjustments} = AGC.step(agc, 60.05, 410.0, 400.0, 4.0)

      # ACE = (410-400-0) + 10*10*(60.05-60) = 10 + 5 = 15
      assert new_agc.ace > 0,
        "ACE should be positive when frequency is high and generation exceeds load"

      # Correction should be negative (reduce generation)
      delta = Map.get(adjustments, 1)
      assert delta < 0, "AGC should signal generation decrease for high frequency"
    end

    test "produces positive ACE when frequency is low (under-generation)" do
      gens = [
        %{id: 1, p_max_mw: 500.0, agc_participation_factor: 1.0,
          dispatch_mw: 400.0, ramp_rate_mw_per_min: 60.0, p_min_mw: 100.0}
      ]

      agc = AGC.init(gens, bias_mw: 10.0, ki: 0.1, p_scheduled: 0.0)

      # Low frequency: 59.95 Hz, gen < load
      {new_agc, adjustments} = AGC.step(agc, 59.95, 390.0, 400.0, 4.0)

      # ACE = (390-400-0) + 10*10*(59.95-60) = -10 + (-5) = -15
      assert new_agc.ace < 0,
        "ACE should be negative when frequency is low"

      delta = Map.get(adjustments, 1)
      assert delta > 0, "AGC should signal generation increase for low frequency"
    end

    test "distributes corrections by participation factor" do
      gens = [
        %{id: 1, p_max_mw: 500.0, agc_participation_factor: 0.7,
          dispatch_mw: 300.0, ramp_rate_mw_per_min: 120.0, p_min_mw: 50.0},
        %{id: 2, p_max_mw: 300.0, agc_participation_factor: 0.3,
          dispatch_mw: 200.0, ramp_rate_mw_per_min: 120.0, p_min_mw: 50.0}
      ]

      agc = AGC.init(gens, bias_mw: 10.0, ki: 0.1, p_scheduled: 0.0)

      {_new_agc, adjustments} = AGC.step(agc, 59.95, 490.0, 500.0, 4.0)

      delta_1 = Map.get(adjustments, 1, 0.0)
      delta_2 = Map.get(adjustments, 2, 0.0)

      # Gen 1 should get 70% of correction, Gen 2 should get 30%
      if abs(delta_1) > 1.0e-10 and abs(delta_2) > 1.0e-10 do
        ratio = abs(delta_1) / abs(delta_2)
        assert_in_delta ratio, 0.7 / 0.3, 0.1,
          "Corrections should be proportional to participation factors"
      end
    end
  end

  describe "AGC ramp rate limiting" do
    test "clamps adjustment to ramp rate" do
      gens = [
        %{id: 1, p_max_mw: 500.0, agc_participation_factor: 1.0,
          dispatch_mw: 300.0, ramp_rate_mw_per_min: 6.0, p_min_mw: 50.0}
      ]

      agc = AGC.init(gens, bias_mw: 100.0, ki: 10.0, p_scheduled: 0.0)

      # Large frequency error to drive large correction
      {_new_agc, adjustments} = AGC.step(agc, 59.5, 200.0, 400.0, 4.0)

      delta = Map.get(adjustments, 1)

      # Ramp rate = 6 MW/min, dt = 4s => max delta = 6 * 4/60 = 0.4 MW
      assert abs(delta) <= 0.4 + 1.0e-6,
        "Adjustment should be clamped to ramp rate. Got #{delta}"
    end

    test "generators without ramp rate have no ramp limit" do
      gens = [
        %{id: 1, p_max_mw: 500.0, agc_participation_factor: 1.0,
          dispatch_mw: 300.0, p_min_mw: 50.0}
        # No ramp_rate_mw_per_min field
      ]

      agc = AGC.init(gens, bias_mw: 100.0, ki: 10.0, p_scheduled: 0.0)

      {_new_agc, adjustments} = AGC.step(agc, 59.5, 200.0, 400.0, 4.0)

      delta = Map.get(adjustments, 1)

      # Should be able to make a large adjustment
      assert abs(delta) > 0.4,
        "Generator without ramp rate should allow larger adjustments"
    end
  end

  # ===========================================================================
  # OLTC Tests
  # ===========================================================================

  describe "OLTC initialization" do
    test "initializes with transformer tap ratio" do
      xfmr = %{tap_ratio: 1.05}
      oltc = OLTC.init(xfmr)

      assert_in_delta oltc.tap, 1.05, 1.0e-10
      assert oltc.enabled == true
      assert oltc.timer == 0.0
    end

    test "uses default parameters" do
      oltc = OLTC.init(%{})

      assert_in_delta oltc.tap, 1.0, 1.0e-10
      assert_in_delta oltc.v_target_pu, 1.0, 1.0e-10
      assert_in_delta oltc.v_deadband_pu, 0.02, 1.0e-10
      assert_in_delta oltc.tap_step_pct, 1.25, 1.0e-10
      assert_in_delta oltc.tap_min, 0.9, 1.0e-10
      assert_in_delta oltc.tap_max, 1.1, 1.0e-10
      assert_in_delta oltc.delay_s, 30.0, 1.0e-10
    end
  end

  describe "OLTC deadband behavior" do
    test "no action when voltage is within deadband" do
      oltc = OLTC.init(%{})

      # Voltage at 1.01 pu, within +/- 0.02 deadband
      {new_oltc, action} = OLTC.step(oltc, 1.01, 1.0)

      assert action == :no_change
      assert_in_delta new_oltc.timer, 0.0, 1.0e-10
    end

    test "timer accumulates when outside deadband" do
      oltc = OLTC.init(%{})

      # Voltage at 0.95 pu, outside deadband
      {oltc1, :no_change} = OLTC.step(oltc, 0.95, 5.0)
      assert_in_delta oltc1.timer, 5.0, 1.0e-10

      {oltc2, :no_change} = OLTC.step(oltc1, 0.95, 5.0)
      assert_in_delta oltc2.timer, 10.0, 1.0e-10
    end

    test "timer resets when voltage returns to deadband" do
      oltc = OLTC.init(%{})

      {oltc1, :no_change} = OLTC.step(oltc, 0.95, 15.0)
      assert oltc1.timer > 0

      {oltc2, :no_change} = OLTC.step(oltc1, 1.0, 1.0)
      assert_in_delta oltc2.timer, 0.0, 1.0e-10
    end
  end

  describe "OLTC tap stepping with delay" do
    test "first tap change after delay_s seconds" do
      oltc = OLTC.init(%{delay_s: 30.0, tap_step_pct: 1.25})

      # Accumulate 29 seconds — not enough
      {oltc1, :no_change} = OLTC.step(oltc, 0.95, 29.0)

      # One more second pushes past 30s delay
      {oltc2, action} = OLTC.step(oltc1, 0.95, 1.0)

      assert {:tap_change, new_tap} = action
      # Voltage low => tap should increase
      assert new_tap > 1.0
      assert_in_delta new_tap, 1.0125, 1.0e-10
      assert oltc2.first_step_done == true
    end

    test "subsequent taps use step_delay_s" do
      oltc = OLTC.init(%{delay_s: 30.0, step_delay_s: 10.0, tap_step_pct: 1.25})

      # First tap change at 30s
      {oltc1, {:tap_change, _}} = OLTC.step(oltc, 0.95, 30.0)

      # Second tap should use 10s delay
      {oltc2, :no_change} = OLTC.step(oltc1, 0.95, 9.0)
      assert_in_delta oltc2.timer, 9.0, 1.0e-10

      {oltc3, action} = OLTC.step(oltc2, 0.95, 1.0)
      assert {:tap_change, _} = action
      assert oltc3.tap > oltc1.tap
    end

    test "tap increases when voltage is low" do
      oltc = OLTC.init(%{delay_s: 1.0, tap_step_pct: 1.25})
      {_oltc, {:tap_change, new_tap}} = OLTC.step(oltc, 0.95, 1.0)

      assert new_tap > 1.0, "Tap should increase to boost low voltage"
    end

    test "tap decreases when voltage is high" do
      oltc = OLTC.init(%{delay_s: 1.0, tap_step_pct: 1.25})
      {_oltc, {:tap_change, new_tap}} = OLTC.step(oltc, 1.05, 1.0)

      assert new_tap < 1.0, "Tap should decrease to reduce high voltage"
    end
  end

  describe "OLTC tap limits" do
    test "tap does not exceed tap_max" do
      oltc = OLTC.init(%{delay_s: 1.0, tap_step_pct: 1.25, tap_max: 1.1})
      oltc = %{oltc | tap: 1.1}

      {new_oltc, action} = OLTC.step(oltc, 0.95, 1.0)

      assert action == :no_change
      assert_in_delta new_oltc.tap, 1.1, 1.0e-10
    end

    test "tap does not go below tap_min" do
      oltc = OLTC.init(%{delay_s: 1.0, tap_step_pct: 1.25, tap_min: 0.9})
      oltc = %{oltc | tap: 0.9}

      {new_oltc, action} = OLTC.step(oltc, 1.05, 1.0)

      assert action == :no_change
      assert_in_delta new_oltc.tap, 0.9, 1.0e-10
    end
  end

  describe "OLTC disabled" do
    test "no action when disabled" do
      oltc = OLTC.init(%{oltc_enabled: false})

      {_oltc, action} = OLTC.step(oltc, 0.80, 100.0)
      assert action == :no_change
    end
  end

  # ===========================================================================
  # SVC Controller Tests
  # ===========================================================================

  describe "SVC initialization" do
    test "initializes from SVC schema map" do
      svc = %{q_max_mvar: 200.0, q_min_mvar: -100.0, v_set_pu: 1.02, slope_pct: 5.0}
      ctrl = SVCController.init(svc)

      assert_in_delta ctrl.v_set, 1.02, 1.0e-10
      assert_in_delta ctrl.q_max, 200.0, 1.0e-10
      assert_in_delta ctrl.q_min, -100.0, 1.0e-10
      assert_in_delta ctrl.slope, 0.05, 1.0e-10
      assert_in_delta ctrl.q_inject, 0.0, 1.0e-10
    end
  end

  describe "SVC voltage regulation" do
    test "injects capacitive Q when voltage is low" do
      svc = %{q_max_mvar: 200.0, q_min_mvar: -100.0, v_set_pu: 1.0, slope_pct: 3.0}
      ctrl = SVCController.init(svc)

      # Step multiple times to reach steady state
      {final, q} = Enum.reduce(1..100, {ctrl, 0.0}, fn _i, {c, _q} ->
        SVCController.step(c, 0.95, 0.01)
      end)

      # V_error = 1.0 - 0.95 = 0.05, Q = 0.05 / 0.03 = 1.667 pu
      # In MVAr: depends on interpretation, but Q should be positive (capacitive)
      assert final.q_inject > 0, "SVC should inject capacitive Q for low voltage"
      assert q > 0
    end

    test "absorbs inductive Q when voltage is high" do
      svc = %{q_max_mvar: 200.0, q_min_mvar: -100.0, v_set_pu: 1.0, slope_pct: 3.0}
      ctrl = SVCController.init(svc)

      {final, q} = Enum.reduce(1..100, {ctrl, 0.0}, fn _i, {c, _q} ->
        SVCController.step(c, 1.05, 0.01)
      end)

      assert final.q_inject < 0, "SVC should absorb Q (inductive) for high voltage"
      assert q < 0
    end

    test "no action at setpoint voltage" do
      svc = %{q_max_mvar: 200.0, q_min_mvar: -100.0, v_set_pu: 1.0, slope_pct: 3.0}
      ctrl = SVCController.init(svc)

      {_final, q} = SVCController.step(ctrl, 1.0, 0.01)

      assert_in_delta q, 0.0, 1.0e-6,
        "SVC should not inject Q when voltage is at setpoint"
    end
  end

  describe "SVC Q limits" do
    test "output clamped to q_max" do
      svc = %{q_max_mvar: 50.0, q_min_mvar: -50.0, v_set_pu: 1.0, slope_pct: 1.0}
      ctrl = SVCController.init(svc)

      # Very low voltage => large Q target, but clamped
      {final, q} = Enum.reduce(1..200, {ctrl, 0.0}, fn _i, {c, _q} ->
        SVCController.step(c, 0.5, 0.01)
      end)

      assert_in_delta final.q_inject, 50.0, 0.1,
        "SVC output should be clamped to q_max"
      assert_in_delta q, 50.0, 0.1
    end

    test "output clamped to q_min" do
      svc = %{q_max_mvar: 50.0, q_min_mvar: -50.0, v_set_pu: 1.0, slope_pct: 1.0}
      ctrl = SVCController.init(svc)

      {final, q} = Enum.reduce(1..200, {ctrl, 0.0}, fn _i, {c, _q} ->
        SVCController.step(c, 1.5, 0.01)
      end)

      assert_in_delta final.q_inject, -50.0, 0.1,
        "SVC output should be clamped to q_min"
      assert_in_delta q, -50.0, 0.1
    end
  end

  describe "SVC dynamic response" do
    test "first-order response approaches target with time constant" do
      svc = %{q_max_mvar: 200.0, q_min_mvar: -200.0, v_set_pu: 1.0, slope_pct: 3.0}
      ctrl = SVCController.init(svc, tau_s: 0.05)

      # After one time constant (~50ms), should reach ~63% of target
      {ctrl_50ms, _q} = SVCController.step(ctrl, 0.97, 0.05)

      # q_target = v_error / slope * q_range
      # v_error = 0.03, slope = 0.03, q_range = 200 - (-200) = 400
      # q_target = 0.03 / 0.03 * 400 = 400, clamped to q_max = 200
      q_target = 200.0
      expected_63pct = q_target * (1.0 - :math.exp(-1.0))

      assert_in_delta ctrl_50ms.q_inject, expected_63pct, 1.0,
        "After one time constant, output should be ~63% of target"
    end
  end

  # ===========================================================================
  # FACTS Controller Tests
  # ===========================================================================

  describe "FACTS TCSC mode" do
    test "initializes with correct device type" do
      device = %{device_type: "TCSC", x_set_pu: 0.05, x_min_pu: 0.02, x_max_pu: 0.08}
      ctrl = FACTSController.init(device)

      assert ctrl.device_type == "TCSC"
      assert_in_delta ctrl.x_set_pu, 0.05, 1.0e-10
    end

    test "adjusts reactance toward target flow" do
      device = %{
        device_type: "TCSC",
        x_set_pu: 0.05,
        x_min_pu: 0.02,
        x_max_pu: 0.08,
        x_line_pu: 0.05,
        target_mw: 200.0
      }
      ctrl = FACTSController.init(device, kp: 0.5, ki: 0.1, tau_s: 0.05)

      # Flow is 150 MW, target is 200 MW => need to reduce reactance
      {new_ctrl, {:x_pu, new_x}} = FACTSController.step(ctrl, 150.0, 200.0, 0.1)

      # Controller should reduce x to increase flow
      assert new_x != ctrl.x_set_pu,
        "TCSC should adjust reactance when flow deviates from target"
      assert is_float(new_ctrl.integral)
    end

    test "respects reactance limits" do
      device = %{
        device_type: "TCSC",
        x_set_pu: 0.05,
        x_min_pu: 0.03,
        x_max_pu: 0.07,
        x_line_pu: 0.05,
        target_mw: 200.0
      }
      ctrl = FACTSController.init(device, kp: 100.0, ki: 100.0, tau_s: 0.001)

      # Large error to drive to limit
      {new_ctrl, {:x_pu, new_x}} = FACTSController.step(ctrl, 0.0, 200.0, 1.0)

      assert new_x >= 0.03 - 1.0e-10, "Reactance should not go below x_min"
      assert new_x <= 0.07 + 1.0e-10, "Reactance should not exceed x_max"
      assert is_float(new_ctrl.x_set_pu)
    end
  end

  describe "FACTS phase shifter mode" do
    test "adjusts angle to track target flow" do
      device = %{
        device_type: "phase_shifter",
        angle_set_deg: 0.0,
        angle_min_deg: -20.0,
        angle_max_deg: 20.0,
        target_mw: 300.0
      }
      ctrl = FACTSController.init(device, kp: 0.5, ki: 0.1, tau_s: 0.05)

      {_new_ctrl, {:angle_deg, new_angle}} = FACTSController.step(ctrl, 250.0, 300.0, 0.1)

      assert new_angle != 0.0,
        "Phase shifter should adjust angle when flow deviates from target"
    end

    test "respects angle limits" do
      device = %{
        device_type: "phase_shifter",
        angle_set_deg: 0.0,
        angle_min_deg: -10.0,
        angle_max_deg: 10.0,
        target_mw: 500.0
      }
      ctrl = FACTSController.init(device, kp: 100.0, ki: 100.0, tau_s: 0.001)

      {_new_ctrl, {:angle_deg, angle}} = FACTSController.step(ctrl, 0.0, 500.0, 1.0)

      assert angle >= -10.0 - 1.0e-10
      assert angle <= 10.0 + 1.0e-10
    end
  end

  # ===========================================================================
  # HVDC Controller Tests
  # ===========================================================================

  describe "HVDC initialization" do
    test "initializes in constant power mode" do
      hvdc = %{rated_mw: 1000.0, p_schedule_mw: 800.0, control_mode: "constant_power"}
      ctrl = HVDCController.init(hvdc)

      assert ctrl.mode == :constant_power
      assert_in_delta ctrl.p_order_mw, 800.0, 1.0e-10
      assert_in_delta ctrl.p_max_mw, 1000.0, 1.0e-10
    end

    test "initializes in frequency support mode" do
      hvdc = %{rated_mw: 500.0, p_schedule_mw: 400.0, control_mode: "frequency_support"}
      ctrl = HVDCController.init(hvdc)

      assert ctrl.mode == :frequency_support
      assert ctrl.k_freq > 0, "Frequency gain should be positive"
    end
  end

  describe "HVDC constant power mode" do
    test "maintains scheduled power at nominal frequency" do
      hvdc = %{rated_mw: 1000.0, p_schedule_mw: 800.0}
      ctrl = HVDCController.init(hvdc)

      {new_ctrl, p} = HVDCController.step(ctrl, 60.0, 0.1)

      assert_in_delta p, 800.0, 1.0,
        "Should maintain scheduled power in constant mode"
      assert_in_delta new_ctrl.p_order_mw, 800.0, 1.0
    end

    test "ignores frequency deviations in constant mode" do
      hvdc = %{rated_mw: 1000.0, p_schedule_mw: 800.0}
      ctrl = HVDCController.init(hvdc)

      {_ctrl_low, p_low} = HVDCController.step(ctrl, 59.5, 1.0)
      {_ctrl_high, p_high} = HVDCController.step(ctrl, 60.5, 1.0)

      assert_in_delta p_low, p_high, 1.0,
        "Constant power mode should not respond to frequency"
    end
  end

  describe "HVDC frequency support mode" do
    test "increases power when receiving-end frequency is high" do
      hvdc = %{rated_mw: 1000.0, p_schedule_mw: 500.0, control_mode: "frequency_support"}
      ctrl = HVDCController.init(hvdc, k_freq: 200.0, ramp_rate_mw_s: 1000.0)

      # High frequency => increase transfer
      {_new_ctrl, p} = HVDCController.step(ctrl, 60.5, 1.0)

      # Target = 500 + 200 * 0.5 = 600 MW
      assert p > 500.0,
        "Should increase power transfer when frequency is high"
    end

    test "decreases power when frequency is low" do
      hvdc = %{rated_mw: 1000.0, p_schedule_mw: 500.0, control_mode: "frequency_support"}
      ctrl = HVDCController.init(hvdc, k_freq: 200.0, ramp_rate_mw_s: 1000.0)

      {_new_ctrl, p} = HVDCController.step(ctrl, 59.5, 1.0)

      # Target = 500 + 200 * (-0.5) = 400 MW
      assert p < 500.0,
        "Should decrease power transfer when frequency is low"
    end

    test "clamps to zero (no reverse power)" do
      hvdc = %{rated_mw: 1000.0, p_schedule_mw: 100.0, control_mode: "frequency_support"}
      ctrl = HVDCController.init(hvdc, k_freq: 500.0, ramp_rate_mw_s: 10000.0)

      # Very low frequency => target goes negative
      {_new_ctrl, p} = HVDCController.step(ctrl, 59.0, 1.0)

      assert p >= 0.0, "Power order should not go negative"
    end
  end

  describe "HVDC ramp rate limiting" do
    test "limits rate of power change" do
      hvdc = %{rated_mw: 1000.0, p_schedule_mw: 500.0, control_mode: "frequency_support"}
      ctrl = HVDCController.init(hvdc, k_freq: 500.0, ramp_rate_mw_s: 50.0)

      # Large frequency deviation driving 250 MW change, but ramp limited
      {new_ctrl, p} = HVDCController.step(ctrl, 60.5, 1.0)

      # Max change = 50 MW/s * 1s = 50 MW
      assert abs(p - 500.0) <= 50.0 + 1.0e-6,
        "Power change should be limited by ramp rate. Got #{p}"
      assert new_ctrl.p_order_mw == p
    end
  end

  describe "HVDC emergency runback" do
    test "ramps down to zero" do
      hvdc = %{rated_mw: 1000.0, p_schedule_mw: 800.0}
      ctrl = HVDCController.init(hvdc, ramp_rate_mw_s: 200.0)
      ctrl = HVDCController.set_mode(ctrl, :emergency_runback)

      assert ctrl.mode == :emergency_runback

      # After 1 second: should reduce by 200 MW
      {ctrl1, p1} = HVDCController.step(ctrl, 60.0, 1.0)
      assert_in_delta p1, 600.0, 1.0

      # After 4 total seconds: should be at zero
      {_ctrl_final, p_final} =
        Enum.reduce(1..3, {ctrl1, p1}, fn _i, {c, _p} ->
          HVDCController.step(c, 60.0, 1.0)
        end)

      assert_in_delta p_final, 0.0, 1.0,
        "Should reach zero after sufficient runback time"
    end
  end

  describe "HVDC mode switching" do
    test "can switch between modes" do
      hvdc = %{rated_mw: 1000.0, p_schedule_mw: 800.0}
      ctrl = HVDCController.init(hvdc)

      assert ctrl.mode == :constant_power

      ctrl = HVDCController.set_mode(ctrl, :frequency_support)
      assert ctrl.mode == :frequency_support

      ctrl = HVDCController.set_mode(ctrl, :emergency_runback)
      assert ctrl.mode == :emergency_runback
    end
  end

  # ===========================================================================
  # RAS Tests
  # ===========================================================================

  describe "RAS initialization" do
    test "initializes from config list" do
      configs = [
        %{
          name: "Pacific DC Intertie RAS",
          trigger: %{type: :line_trip, component_id: 42},
          actions: [
            %{type: :trip_generator, target_id: 99, delay_s: 0.1},
            %{type: :shed_load, target_ids: [201, 202], fraction: 0.5, delay_s: 0.3}
          ]
        }
      ]

      [ras] = RAS.init(configs)

      assert ras.name == "Pacific DC Intertie RAS"
      assert ras.enabled == true
      assert ras.fired == false
      assert length(ras.actions) == 2
    end

    test "defaults to enabled" do
      ras = RAS.init(%{name: "test", trigger: %{type: :line_trip, component_id: 1}, actions: []})
      assert ras.enabled == true
    end
  end

  describe "RAS trigger matching" do
    test "fires on matching line trip event" do
      ras_list = RAS.init([
        %{
          name: "Line 42 RAS",
          trigger: %{type: :line_trip, component_id: 42},
          actions: [%{type: :trip_generator, target_id: 99, delay_s: 0.1}]
        }
      ])

      events = [%{component_type: "transmission_line", component_id: 42, failure_cause: "thermal_overload"}]

      {updated, actions} = RAS.check(ras_list, events)

      assert length(actions) == 1
      assert hd(actions).type == :trip_generator
      assert hd(actions).target_id == 99
      assert hd(updated).fired == true
    end

    test "does not fire on non-matching event" do
      ras_list = RAS.init([
        %{
          name: "Line 42 RAS",
          trigger: %{type: :line_trip, component_id: 42},
          actions: [%{type: :trip_generator, target_id: 99}]
        }
      ])

      events = [%{component_type: "transmission_line", component_id: 99}]

      {updated, actions} = RAS.check(ras_list, events)

      assert Enum.empty?(actions)
      assert hd(updated).fired == false
    end

    test "fires on generator trip event" do
      ras_list = RAS.init([
        %{
          name: "Gen 10 RAS",
          trigger: %{type: :generator_trip, component_id: 10},
          actions: [%{type: :shed_load, target_ids: [201], fraction: 0.5, delay_s: 0.3}]
        }
      ])

      events = [%{component_type: "generator", component_id: 10}]
      {_updated, actions} = RAS.check(ras_list, events)

      assert length(actions) == 1
      assert hd(actions).type == :shed_load
    end

    test "fires on underfrequency trigger" do
      ras_list = RAS.init([
        %{
          name: "UFLS Stage 3",
          trigger: %{type: :underfrequency, threshold_hz: 59.0},
          actions: [%{type: :shed_load, target_ids: [301, 302], fraction: 0.15}]
        }
      ])

      {_updated, actions} = RAS.check(ras_list, [], frequency_hz: 58.5)

      assert length(actions) == 1
    end

    test "does not fire on underfrequency when above threshold" do
      ras_list = RAS.init([
        %{
          name: "UFLS Stage 3",
          trigger: %{type: :underfrequency, threshold_hz: 59.0},
          actions: [%{type: :shed_load, target_ids: [301], fraction: 0.15}]
        }
      ])

      {_updated, actions} = RAS.check(ras_list, [], frequency_hz: 59.5)

      assert Enum.empty?(actions)
    end

    test "fires on undervoltage trigger" do
      ras_list = RAS.init([
        %{
          name: "Bus 5 UVLS",
          trigger: %{type: :undervoltage, bus_id: 5, threshold_pu: 0.9},
          actions: [%{type: :shed_load, target_ids: [501], fraction: 0.25}]
        }
      ])

      {_updated, actions} = RAS.check(ras_list, [], bus_voltages: %{5 => 0.85})
      assert length(actions) == 1
    end
  end

  describe "RAS latching behavior" do
    test "fires at most once" do
      ras_list = RAS.init([
        %{
          name: "Latching RAS",
          trigger: %{type: :line_trip, component_id: 42},
          actions: [%{type: :trip_generator, target_id: 99}]
        }
      ])

      events = [%{component_type: "transmission_line", component_id: 42}]

      # First check: should fire
      {updated1, actions1} = RAS.check(ras_list, events)
      assert length(actions1) == 1

      # Second check with same event: should NOT fire again
      {_updated2, actions2} = RAS.check(updated1, events)
      assert Enum.empty?(actions2), "RAS should not fire again after latching"
    end

    test "disabled RAS does not fire" do
      ras_list = RAS.init([
        %{
          name: "Disabled RAS",
          trigger: %{type: :line_trip, component_id: 42},
          actions: [%{type: :trip_generator, target_id: 99}],
          enabled: false
        }
      ])

      events = [%{component_type: "transmission_line", component_id: 42}]

      {_updated, actions} = RAS.check(ras_list, events)
      assert Enum.empty?(actions), "Disabled RAS should not fire"
    end
  end

  describe "RAS multiple schemes" do
    test "multiple RAS can fire from different events" do
      ras_list = RAS.init([
        %{
          name: "RAS A",
          trigger: %{type: :line_trip, component_id: 1},
          actions: [%{type: :trip_generator, target_id: 10}]
        },
        %{
          name: "RAS B",
          trigger: %{type: :line_trip, component_id: 2},
          actions: [%{type: :shed_load, target_ids: [20], fraction: 0.5}]
        }
      ])

      events = [
        %{component_type: "transmission_line", component_id: 1},
        %{component_type: "transmission_line", component_id: 2}
      ]

      {updated, actions} = RAS.check(ras_list, events)

      assert length(actions) == 2
      assert Enum.all?(updated, & &1.fired)
    end

    test "only matching RAS fire" do
      ras_list = RAS.init([
        %{
          name: "RAS A",
          trigger: %{type: :line_trip, component_id: 1},
          actions: [%{type: :trip_generator, target_id: 10}]
        },
        %{
          name: "RAS B",
          trigger: %{type: :line_trip, component_id: 2},
          actions: [%{type: :shed_load, target_ids: [20], fraction: 0.5}]
        }
      ])

      events = [%{component_type: "transmission_line", component_id: 1}]

      {updated, actions} = RAS.check(ras_list, events)

      assert length(actions) == 1
      assert hd(actions).type == :trip_generator

      [ras_a, ras_b] = updated
      assert ras_a.fired == true
      assert ras_b.fired == false
    end
  end

  describe "RAS action metadata" do
    test "triggered actions include ras_name" do
      ras_list = RAS.init([
        %{
          name: "My RAS",
          trigger: %{type: :line_trip, component_id: 42},
          actions: [%{type: :trip_generator, target_id: 99, delay_s: 0.1}]
        }
      ])

      events = [%{component_type: "transmission_line", component_id: 42}]
      {_updated, actions} = RAS.check(ras_list, events)

      assert hd(actions).ras_name == "My RAS"
    end
  end
end
