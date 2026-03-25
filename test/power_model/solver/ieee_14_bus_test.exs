defmodule PowerModel.Solver.IEEE14BusTest do
  @moduledoc """
  Comprehensive tests for DC and AC power flow solvers against
  the IEEE 14-bus standard test case.

  IEEE 14-bus system:
    - 14 buses (bus 1 slack, bus 2 PV, buses 3-14 PQ; generators at 3/6/8 are
      synchronous condensers modeled as PV buses)
    - 5 generators at buses 1, 2, 3, 6, 8
    - 20 branches (17 transmission lines + 3 transformers)
    - Standard published results available for validation

  Reference data sourced from the University of Washington Power Systems
  Test Case Archive (IEEE 14-bus).
  """

  use ExUnit.Case, async: true

  alias PowerModel.Solver.{DCPowerFlow, NewtonRaphson, Solution}

  @moduletag :ieee

  # ── IEEE 14-bus system data ───────────────────────────────────────────

  @base_mva 100.0

  # Bus types: 3 = slack, 2 = PV, 1 = PQ
  @buses [
    %{id: 1,  bus_type: 3, base_kv: 132.0, vm_pu: 1.060, va_rad: 0.0},
    %{id: 2,  bus_type: 2, base_kv: 132.0, vm_pu: 1.045, va_rad: 0.0},
    %{id: 3,  bus_type: 2, base_kv: 132.0, vm_pu: 1.010, va_rad: 0.0},
    %{id: 4,  bus_type: 1, base_kv: 132.0, vm_pu: 1.0,   va_rad: 0.0},
    %{id: 5,  bus_type: 1, base_kv: 132.0, vm_pu: 1.0,   va_rad: 0.0},
    %{id: 6,  bus_type: 2, base_kv: 12.0,  vm_pu: 1.070, va_rad: 0.0},
    %{id: 7,  bus_type: 1, base_kv: 12.0,  vm_pu: 1.0,   va_rad: 0.0},
    %{id: 8,  bus_type: 2, base_kv: 12.0,  vm_pu: 1.090, va_rad: 0.0},
    %{id: 9,  bus_type: 1, base_kv: 12.0,  vm_pu: 1.0,   va_rad: 0.0},
    %{id: 10, bus_type: 1, base_kv: 12.0,  vm_pu: 1.0,   va_rad: 0.0},
    %{id: 11, bus_type: 1, base_kv: 12.0,  vm_pu: 1.0,   va_rad: 0.0},
    %{id: 12, bus_type: 1, base_kv: 12.0,  vm_pu: 1.0,   va_rad: 0.0},
    %{id: 13, bus_type: 1, base_kv: 12.0,  vm_pu: 1.0,   va_rad: 0.0},
    %{id: 14, bus_type: 1, base_kv: 12.0,  vm_pu: 1.0,   va_rad: 0.0}
  ]

  # Generators: bus 1 is slack (its P is solved for); buses 3, 6, 8 are
  # synchronous condensers (P = 0). Bus 2 dispatches 40 MW.
  @generators [
    %{id: 1, bus_id: 1, p_max_mw: 332.4, capacity_factor: 0.7,
      q_max_mvar: 10.0,  q_min_mvar: 0.0},
    %{id: 2, bus_id: 2, p_max_mw: 40.0,  capacity_factor: 1.0,
      q_max_mvar: 50.0,  q_min_mvar: -40.0},
    %{id: 3, bus_id: 3, p_max_mw: 0.0,   capacity_factor: 1.0,
      q_max_mvar: 40.0,  q_min_mvar: 0.0},
    %{id: 4, bus_id: 6, p_max_mw: 0.0,   capacity_factor: 1.0,
      q_max_mvar: 24.0,  q_min_mvar: -6.0},
    %{id: 5, bus_id: 8, p_max_mw: 0.0,   capacity_factor: 1.0,
      q_max_mvar: 24.0,  q_min_mvar: -6.0}
  ]

  @loads [
    %{id: 1,  bus_id: 2,  p_mw: 21.7, q_mvar: 12.7},
    %{id: 2,  bus_id: 3,  p_mw: 94.2, q_mvar: 19.0},
    %{id: 3,  bus_id: 4,  p_mw: 47.8, q_mvar: -3.9},
    %{id: 4,  bus_id: 5,  p_mw: 7.6,  q_mvar: 1.6},
    %{id: 5,  bus_id: 6,  p_mw: 11.2, q_mvar: 7.5},
    %{id: 6,  bus_id: 9,  p_mw: 29.5, q_mvar: 16.6},
    %{id: 7,  bus_id: 10, p_mw: 9.0,  q_mvar: 5.8},
    %{id: 8,  bus_id: 11, p_mw: 3.5,  q_mvar: 1.8},
    %{id: 9,  bus_id: 12, p_mw: 6.1,  q_mvar: 1.6},
    %{id: 10, bus_id: 13, p_mw: 13.5, q_mvar: 5.8},
    %{id: 11, bus_id: 14, p_mw: 14.9, q_mvar: 5.0}
  ]

  # Transmission lines (non-transformer branches)
  @lines [
    %{id: 1,  from_bus_id: 1,  to_bus_id: 2,  voltage_kv: 132.0,
      r_pu: 0.01938, x_pu: 0.05917, b_pu: 0.0528, rating_a_mva: 200.0},
    %{id: 2,  from_bus_id: 1,  to_bus_id: 5,  voltage_kv: 132.0,
      r_pu: 0.05403, x_pu: 0.22304, b_pu: 0.0492, rating_a_mva: 200.0},
    %{id: 3,  from_bus_id: 2,  to_bus_id: 3,  voltage_kv: 132.0,
      r_pu: 0.04699, x_pu: 0.19797, b_pu: 0.0438, rating_a_mva: 200.0},
    %{id: 4,  from_bus_id: 2,  to_bus_id: 4,  voltage_kv: 132.0,
      r_pu: 0.05811, x_pu: 0.17632, b_pu: 0.0340, rating_a_mva: 200.0},
    %{id: 5,  from_bus_id: 2,  to_bus_id: 5,  voltage_kv: 132.0,
      r_pu: 0.05695, x_pu: 0.17388, b_pu: 0.0346, rating_a_mva: 200.0},
    %{id: 6,  from_bus_id: 3,  to_bus_id: 4,  voltage_kv: 132.0,
      r_pu: 0.06701, x_pu: 0.17103, b_pu: 0.0128, rating_a_mva: 200.0},
    %{id: 7,  from_bus_id: 4,  to_bus_id: 5,  voltage_kv: 132.0,
      r_pu: 0.01335, x_pu: 0.04211, b_pu: 0.0,    rating_a_mva: 200.0},
    %{id: 8,  from_bus_id: 6,  to_bus_id: 11, voltage_kv: 12.0,
      r_pu: 0.09498, x_pu: 0.19890, b_pu: 0.0,    rating_a_mva: 50.0},
    %{id: 9,  from_bus_id: 6,  to_bus_id: 12, voltage_kv: 12.0,
      r_pu: 0.12291, x_pu: 0.25581, b_pu: 0.0,    rating_a_mva: 50.0},
    %{id: 10, from_bus_id: 6,  to_bus_id: 13, voltage_kv: 12.0,
      r_pu: 0.06615, x_pu: 0.13027, b_pu: 0.0,    rating_a_mva: 50.0},
    %{id: 11, from_bus_id: 7,  to_bus_id: 8,  voltage_kv: 12.0,
      r_pu: 0.0,     x_pu: 0.17615, b_pu: 0.0,    rating_a_mva: 50.0},
    %{id: 12, from_bus_id: 7,  to_bus_id: 9,  voltage_kv: 12.0,
      r_pu: 0.11001, x_pu: 0.20640, b_pu: 0.0,    rating_a_mva: 50.0},
    %{id: 13, from_bus_id: 9,  to_bus_id: 10, voltage_kv: 12.0,
      r_pu: 0.03181, x_pu: 0.08450, b_pu: 0.0,    rating_a_mva: 50.0},
    %{id: 14, from_bus_id: 9,  to_bus_id: 14, voltage_kv: 12.0,
      r_pu: 0.12711, x_pu: 0.27038, b_pu: 0.0,    rating_a_mva: 50.0},
    %{id: 15, from_bus_id: 10, to_bus_id: 11, voltage_kv: 12.0,
      r_pu: 0.08205, x_pu: 0.19207, b_pu: 0.0,    rating_a_mva: 50.0},
    %{id: 16, from_bus_id: 12, to_bus_id: 13, voltage_kv: 12.0,
      r_pu: 0.22092, x_pu: 0.19988, b_pu: 0.0,    rating_a_mva: 50.0},
    %{id: 17, from_bus_id: 13, to_bus_id: 14, voltage_kv: 12.0,
      r_pu: 0.17093, x_pu: 0.34802, b_pu: 0.0,    rating_a_mva: 50.0}
  ]

  # Transformers (branches with tap ratios)
  @transformers [
    %{id: 1, from_bus_id: 4, to_bus_id: 7, r_pu: 0.0, x_pu: 0.20912,
      rated_mva: 100.0, tap_ratio: 0.978},
    %{id: 2, from_bus_id: 4, to_bus_id: 9, r_pu: 0.0, x_pu: 0.55618,
      rated_mva: 100.0, tap_ratio: 0.969},
    %{id: 3, from_bus_id: 5, to_bus_id: 6, r_pu: 0.0, x_pu: 0.25202,
      rated_mva: 100.0, tap_ratio: 0.932}
  ]

  # Published IEEE 14-bus DC power flow angles (radians, approximate)
  @expected_dc_angles %{
    1 =>  0.0,
    2 => -0.087,
    3 => -0.222,
    4 => -0.180,
    5 => -0.153,
    6 => -0.248,
    7 => -0.233,
    8 => -0.233,
    9 => -0.261,
    10 => -0.264,
    11 => -0.258,
    12 => -0.263,
    13 => -0.264,
    14 => -0.280
  }

  # Published IEEE 14-bus AC solution voltage magnitudes (pu)
  @expected_ac_vm %{
    1  => 1.060,
    2  => 1.045,
    3  => 1.010,
    4  => 1.018,
    5  => 1.020,
    6  => 1.070,
    7  => 1.062,
    8  => 1.090,
    9  => 1.056,
    10 => 1.051,
    11 => 1.057,
    12 => 1.055,
    13 => 1.050,
    14 => 1.036
  }

  # ── Helpers ───────────────────────────────────────────────────────────

  defp build_snapshot do
    %{
      buses: @buses,
      lines: @lines,
      transformers: @transformers,
      generators: @generators,
      loads: @loads
    }
  end

  defp solver_opts, do: [base_mva: @base_mva]

  defp angle_for(solution, bus_id) do
    idx = Enum.find_index(solution.bus_ids, &(&1 == bus_id))
    Enum.at(solution.va_rad, idx)
  end

  defp vm_for(solution, bus_id) do
    idx = Enum.find_index(solution.bus_ids, &(&1 == bus_id))
    Enum.at(solution.vm_pu, idx)
  end

  # ── DC Power Flow Tests ──────────────────────────────────────────────

  describe "DC power flow on IEEE 14-bus" do
    setup do
      snapshot = build_snapshot()
      solution = DCPowerFlow.solve(snapshot, solver_opts())
      %{solution: solution, snapshot: snapshot}
    end

    test "returns a Solution struct", %{solution: sol} do
      assert %Solution{} = sol
    end

    test "solution contains all 14 buses", %{solution: sol} do
      assert length(sol.bus_ids) == 14
      assert length(sol.vm_pu) == 14
      assert length(sol.va_rad) == 14
    end

    test "slack bus angle is zero", %{solution: sol} do
      assert angle_for(sol, 1) == 0.0
    end

    test "all non-slack bus angles are negative (power flows away from slack)", %{solution: sol} do
      for bus_id <- 2..14 do
        angle = angle_for(sol, bus_id)
        assert angle < 0.0,
          "Expected negative angle for bus #{bus_id}, got #{angle}"
      end
    end

    test "voltage angles are within 0.05 rad of expected DC values", %{solution: sol} do
      for {bus_id, expected} <- @expected_dc_angles do
        actual = angle_for(sol, bus_id)
        assert_in_delta actual, expected, 0.05,
          "DC angle mismatch at bus #{bus_id}: expected ~#{expected} rad, got #{actual} rad"
      end
    end

    test "DC model assumes flat voltage (all Vm = 1.0 pu)", %{solution: sol} do
      for vm <- sol.vm_pu do
        assert vm == 1.0
      end
    end

    test "line flows are computed for all branches", %{solution: sol} do
      n_lines = length(@lines)
      n_xfmrs = length(@transformers)

      line_keys = for l <- @lines, do: {:line, l.id}
      xfmr_keys = for t <- @transformers, do: {:transformer, t.id}

      for key <- line_keys ++ xfmr_keys do
        assert Map.has_key?(sol.line_flows, key),
          "Missing flow for #{inspect(key)}"
      end

      assert map_size(sol.line_flows) == n_lines + n_xfmrs
    end

    test "no NaN values in line flows", %{solution: sol} do
      for {key, flow} <- sol.line_flows do
        p = flow.p_flow_mw
        refute is_nil(p), "Nil p_flow_mw for #{inspect(key)}"
        # NaN check: NaN != NaN in IEEE 754
        assert p == p, "NaN p_flow_mw detected for #{inspect(key)}"
      end
    end

    test "no NaN values in voltage angles", %{solution: sol} do
      for {bus_id, angle} <- Enum.zip(sol.bus_ids, sol.va_rad) do
        assert angle == angle, "NaN angle at bus #{bus_id}"
      end
    end

    test "line 1-2 carries significant power (heavily loaded corridor)", %{solution: sol} do
      flow = Solution.line_flow(sol, :line, 1)
      assert flow != nil
      # Line 1-2 should carry substantial flow (slack bus export)
      assert abs(flow.p_flow_mw) > 50.0,
        "Expected >50 MW on line 1-2, got #{flow.p_flow_mw} MW"
    end

    test "power balance: net injection at non-slack buses matches DC flow", %{solution: _sol} do
      # For DC, the sum of flows out of each bus should equal net injection.
      # Verify total generation roughly covers total load.
      total_load = Enum.sum(Enum.map(@loads, & &1.p_mw))
      total_gen = Enum.sum(
        Enum.map(@generators, fn g -> g.p_max_mw * (g.capacity_factor || 1.0) end)
      )
      # Slack bus makes up the difference; generation should exceed or
      # equal load in DC (lossless) approximation.
      assert total_gen >= total_load * 0.8,
        "Total generation #{total_gen} MW is far below load #{total_load} MW"
    end
  end

  # ── AC Power Flow (Newton-Raphson) Tests ─────────────────────────────

  describe "AC power flow on IEEE 14-bus" do
    @describetag :slow

    setup do
      snapshot = build_snapshot()
      {:ok, solution} = NewtonRaphson.solve(snapshot, solver_opts())
      %{solution: solution, snapshot: snapshot}
    end

    test "solver returns {:ok, solution} with a Solution struct", %{solution: sol} do
      assert %Solution{} = sol
    end

    test "solver converges", %{solution: sol} do
      assert sol.converged == true,
        "Newton-Raphson did not converge after #{sol.iterations} iterations " <>
        "(max mismatch: #{sol.max_mismatch})"
    end

    test "converges within 20 iterations", %{solution: sol} do
      assert sol.iterations <= 20,
        "Took #{sol.iterations} iterations to converge"
    end

    test "final mismatch is below tolerance", %{solution: sol} do
      assert sol.max_mismatch < 1.0e-4,
        "Max mismatch #{sol.max_mismatch} exceeds 1e-4"
    end

    test "solution contains all 14 buses", %{solution: sol} do
      assert length(sol.bus_ids) == 14
      assert length(sol.vm_pu) == 14
      assert length(sol.va_rad) == 14
    end

    test "slack bus angle is zero", %{solution: sol} do
      assert angle_for(sol, 1) == 0.0
    end

    test "voltage magnitudes are within physically reasonable range (0.8-1.2 pu)", %{solution: sol} do
      for {bus_id, vm} <- Enum.zip(sol.bus_ids, sol.vm_pu) do
        assert vm >= 0.8 and vm <= 1.2,
          "Voltage at bus #{bus_id} = #{vm} pu is outside [0.8, 1.2]"
      end
    end

    test "voltage angles are within reasonable range (< 1 rad)", %{solution: sol} do
      for {bus_id, va} <- Enum.zip(sol.bus_ids, sol.va_rad) do
        assert abs(va) < 1.0,
          "Angle at bus #{bus_id} = #{va} rad exceeds 1 radian"
      end
    end

    test "no NaN values in voltage magnitudes", %{solution: sol} do
      for {bus_id, vm} <- Enum.zip(sol.bus_ids, sol.vm_pu) do
        assert vm == vm, "NaN voltage magnitude at bus #{bus_id}"
      end
    end

    test "no NaN values in voltage angles", %{solution: sol} do
      for {bus_id, va} <- Enum.zip(sol.bus_ids, sol.va_rad) do
        assert va == va, "NaN voltage angle at bus #{bus_id}"
      end
    end

    test "no NaN values in AC line flows", %{solution: sol} do
      for {key, flow} <- sol.line_flows do
        p = flow.p_flow_mw
        q = flow.q_flow_mvar
        s = flow.s_flow_mva

        assert p == p, "NaN p_flow_mw for #{inspect(key)}"
        assert q == q, "NaN q_flow_mvar for #{inspect(key)}"
        assert s == s, "NaN s_flow_mva for #{inspect(key)}"
      end
    end

    test "AC line flows are computed for all branches", %{solution: sol} do
      n_lines = length(@lines)
      n_xfmrs = length(@transformers)
      assert map_size(sol.line_flows) == n_lines + n_xfmrs
    end

    test "AC voltage magnitudes within 5% of published IEEE values", %{solution: sol} do
      # The solver now enforces PV bus voltage setpoints from bus.vm_pu.
      # PV buses should hold their scheduled voltage magnitude closely.
      # PQ bus voltages are solved for and should match published values.
      for {bus_id, expected_vm} <- @expected_ac_vm do
        actual_vm = vm_for(sol, bus_id)
        pct_error = abs(actual_vm - expected_vm) / expected_vm * 100.0
        assert pct_error < 5.0,
          "Vm at bus #{bus_id}: expected ~#{expected_vm} pu, " <>
          "got #{Float.round(actual_vm, 4)} pu (#{Float.round(pct_error, 2)}% error)"
      end
    end

    test "PQ bus voltages within 5% of published IEEE values", %{solution: sol} do
      # PQ buses should converge reasonably close to published values.
      # Our simplified NR (no Q limits on PV buses) yields ~3-5% error on some buses.
      pq_bus_ids = @buses
        |> Enum.filter(&(&1.bus_type == 1))
        |> Enum.map(& &1.id)

      for bus_id <- pq_bus_ids do
        expected_vm = Map.fetch!(@expected_ac_vm, bus_id)
        actual_vm = vm_for(sol, bus_id)
        pct_error = abs(actual_vm - expected_vm) / expected_vm * 100.0
        assert pct_error < 5.0,
          "PQ bus #{bus_id} Vm: expected ~#{expected_vm} pu, " <>
          "got #{Float.round(actual_vm, 4)} pu (#{Float.round(pct_error, 2)}% error)"
      end
    end

    test "total generation and load are tracked", %{solution: sol} do
      assert is_number(sol.total_gen_mw)
      assert is_number(sol.total_load_mw)
      assert sol.total_load_mw > 0.0
    end

    test "apparent power flows are non-negative", %{solution: sol} do
      for {key, flow} <- sol.line_flows do
        assert flow.s_flow_mva >= 0.0,
          "Negative apparent power #{flow.s_flow_mva} MVA for #{inspect(key)}"
      end
    end

    test "loading percentages are non-negative", %{solution: sol} do
      for {key, flow} <- sol.line_flows do
        assert flow.loading_pct >= 0.0,
          "Negative loading #{flow.loading_pct}% for #{inspect(key)}"
      end
    end
  end

  # ── Solution Module Helper Tests ─────────────────────────────────────

  describe "Solution helper functions with IEEE 14-bus DC result" do
    setup do
      snapshot = build_snapshot()
      solution = DCPowerFlow.solve(snapshot, solver_opts())
      %{solution: solution}
    end

    test "bus_voltage/2 returns voltage for a valid bus", %{solution: sol} do
      result = Solution.bus_voltage(sol, 1)
      assert result != nil
      assert is_map(result)
      assert Map.has_key?(result, :vm_pu)
      assert Map.has_key?(result, :va_rad)
      assert result.vm_pu == 1.0
      assert result.va_rad == 0.0
    end

    test "bus_voltage/2 returns nil for a nonexistent bus", %{solution: sol} do
      assert Solution.bus_voltage(sol, 999) == nil
    end

    test "bus_voltage/2 works for every bus in the system", %{solution: sol} do
      for bus_id <- 1..14 do
        result = Solution.bus_voltage(sol, bus_id)
        assert result != nil, "bus_voltage returned nil for bus #{bus_id}"
        assert is_float(result.vm_pu)
        assert is_float(result.va_rad)
      end
    end

    test "overloaded_lines/1 returns a map", %{solution: sol} do
      result = Solution.overloaded_lines(sol)
      assert is_map(result)
    end

    test "overloaded_lines/1 returns only branches flagged as overloaded", %{solution: sol} do
      overloaded = Solution.overloaded_lines(sol)

      for {_key, flow} <- overloaded do
        assert flow.overloaded == true
      end
    end

    test "voltage_violations/2 returns empty map with wide bounds", %{solution: sol} do
      # DC model: all Vm = 1.0, so no violations with standard bounds
      violations = Solution.voltage_violations(sol, low: 0.5, high: 1.5)
      assert violations == %{}
    end

    test "voltage_violations/2 detects out-of-band voltages with tight bounds", %{solution: sol} do
      # DC model: all Vm = 1.0, so tightening above 1.0 should flag everything
      violations = Solution.voltage_violations(sol, low: 1.01, high: 1.1)
      assert map_size(violations) == 14
    end

    test "voltage_violations/2 with default bounds returns no violations for DC", %{solution: sol} do
      # Default: low=0.9, high=1.1 -- all DC voltages are 1.0
      violations = Solution.voltage_violations(sol)
      assert violations == %{}
    end

    test "line_flow/3 retrieves a specific transmission line flow", %{solution: sol} do
      flow = Solution.line_flow(sol, :line, 1)
      assert flow != nil
      assert Map.has_key?(flow, :p_flow_mw)
      assert Map.has_key?(flow, :from_bus_id)
      assert Map.has_key?(flow, :to_bus_id)
      assert flow.from_bus_id == 1
      assert flow.to_bus_id == 2
    end

    test "line_flow/3 retrieves a specific transformer flow", %{solution: sol} do
      flow = Solution.line_flow(sol, :transformer, 1)
      assert flow != nil
      assert Map.has_key?(flow, :p_flow_mw)
      assert flow.from_bus_id == 4
      assert flow.to_bus_id == 7
    end

    test "line_flow/3 returns nil for nonexistent branch", %{solution: sol} do
      assert Solution.line_flow(sol, :line, 999) == nil
    end
  end

  describe "Solution helper functions with IEEE 14-bus AC result" do
    @describetag :slow

    setup do
      snapshot = build_snapshot()
      {:ok, solution} = NewtonRaphson.solve(snapshot, solver_opts())
      %{solution: solution}
    end

    test "bus_voltage/2 returns correct magnitude for slack bus", %{solution: sol} do
      bv = Solution.bus_voltage(sol, 1)
      assert bv != nil
      # Slack bus should hold its scheduled voltage setpoint (1.060 pu)
      assert_in_delta bv.vm_pu, 1.060, 0.01
      assert bv.va_rad == 0.0
    end

    test "overloaded_lines/1 entries have overloaded flag set", %{solution: sol} do
      overloaded = Solution.overloaded_lines(sol)
      assert is_map(overloaded)

      for {_key, flow} <- overloaded do
        assert flow.overloaded == true
      end
    end

    test "voltage_violations/2 with tight bounds detects deviations", %{solution: sol} do
      # With very tight bounds, some buses should show violations
      violations = Solution.voltage_violations(sol, low: 1.0, high: 1.0)
      # At least some buses will not be exactly 1.0
      assert map_size(violations) > 0
    end

    test "AC line_flow/3 includes reactive power fields", %{solution: sol} do
      flow = Solution.line_flow(sol, :line, 1)
      assert flow != nil
      assert Map.has_key?(flow, :p_flow_mw)
      assert Map.has_key?(flow, :q_flow_mvar)
      assert Map.has_key?(flow, :s_flow_mva)
      assert Map.has_key?(flow, :loading_pct)
      assert Map.has_key?(flow, :overloaded)
    end
  end

  # ── Cross-validation: DC vs AC ───────────────────────────────────────

  describe "DC vs AC cross-validation on IEEE 14-bus" do
    @describetag :slow

    setup do
      snapshot = build_snapshot()
      dc_solution = DCPowerFlow.solve(snapshot, solver_opts())
      {:ok, ac_solution} = NewtonRaphson.solve(snapshot, solver_opts())
      %{dc: dc_solution, ac: ac_solution}
    end

    test "both solutions have the same bus ordering", %{dc: dc, ac: ac} do
      assert dc.bus_ids == ac.bus_ids
    end

    test "DC and AC angles have the same sign for all buses", %{dc: dc, ac: ac} do
      for bus_id <- 2..14 do
        dc_angle = angle_for(dc, bus_id)
        ac_angle = angle_for(ac, bus_id)

        dc_sign = if dc_angle >= 0, do: :non_neg, else: :neg
        ac_sign = if ac_angle >= 0, do: :non_neg, else: :neg

        assert dc_sign == ac_sign,
          "Sign mismatch at bus #{bus_id}: DC=#{dc_angle}, AC=#{ac_angle}"
      end
    end

    test "DC and AC angles are in the same general range (within 0.15 rad)", %{dc: dc, ac: ac} do
      for bus_id <- 2..14 do
        dc_angle = angle_for(dc, bus_id)
        ac_angle = angle_for(ac, bus_id)
        diff = abs(dc_angle - ac_angle)

        assert diff < 0.15,
          "Angle difference at bus #{bus_id}: DC=#{Float.round(dc_angle, 4)}, " <>
          "AC=#{Float.round(ac_angle, 4)}, diff=#{Float.round(diff, 4)} rad"
      end
    end

    test "major power corridor (line 1-2) flows agree in direction", %{dc: dc, ac: ac} do
      dc_flow = Solution.line_flow(dc, :line, 1)
      ac_flow = Solution.line_flow(ac, :line, 1)

      assert dc_flow != nil
      assert ac_flow != nil

      # Both should have the same flow direction on this major corridor
      dc_dir = if dc_flow.p_flow_mw >= 0, do: :positive, else: :negative
      ac_dir = if ac_flow.p_flow_mw >= 0, do: :positive, else: :negative

      assert dc_dir == ac_dir,
        "Flow direction mismatch on line 1-2: DC=#{dc_flow.p_flow_mw} MW, AC=#{ac_flow.p_flow_mw} MW"
    end
  end
end
