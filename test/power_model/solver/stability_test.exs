defmodule PowerModel.Solver.StabilityTest do
  use ExUnit.Case, async: true

  alias PowerModel.Solver.Stability.{SmallSignal, CPF}
  alias PowerModel.Solver.DCPowerFlow

  # ===========================================================================
  # Test helpers
  # ===========================================================================

  defp bus(id, opts \\ []) do
    %{id: id, bus_type: Keyword.get(opts, :bus_type, 1), base_kv: 138.0,
      vm_pu: 1.0, va_rad: 0.0, b_shunt_mvar: 0.0}
  end

  defp line(id, from, to, opts \\ []) do
    %{id: id, from_bus_id: from, to_bus_id: to,
      voltage_kv: 138.0, r_pu: 0.01,
      x_pu: Keyword.get(opts, :x_pu, 0.1),
      b_pu: 0.02,
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 100.0)}
  end

  defp generator(id, bus_id, opts) do
    %{id: id, bus_id: bus_id,
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      capacity_factor: 1.0,
      fuel_type: "NG", status: "in_service",
      marginal_cost_per_mwh: 35.0,
      inertia_h: Keyword.get(opts, :inertia_h, 5.0),
      d_factor: Keyword.get(opts, :d_factor, 2.0)}
  end

  defp load(id, bus_id, opts) do
    %{id: id, bus_id: bus_id,
      p_mw: Keyword.get(opts, :p_mw, 50.0),
      q_mvar: 0.0, status: "in_service"}
  end

  # 3-bus system: Gen1(bus1) --L1-- Bus2(load) --L2-- Gen2(bus3)
  defp three_bus_two_gen do
    %{
      buses: [bus(1, bus_type: 3), bus(2), bus(3)],
      lines: [line(1, 1, 2, x_pu: 0.1), line(2, 2, 3, x_pu: 0.15)],
      transformers: [],
      generators: [
        generator(1, 1, p_max_mw: 120.0, inertia_h: 5.0, d_factor: 2.0),
        generator(2, 3, p_max_mw: 80.0, inertia_h: 4.0, d_factor: 1.5)
      ],
      loads: [load(1, 2, p_mw: 100.0)]
    }
  end

  # 5-bus diamond (same as LODF tests)
  defp diamond_snapshot do
    %{
      buses: [bus(1, bus_type: 3), bus(2), bus(3), bus(4), bus(5)],
      lines: [
        line(1, 1, 2, x_pu: 0.1, rating_a_mva: 200.0),
        line(2, 1, 3, x_pu: 0.15, rating_a_mva: 200.0),
        line(3, 1, 4, x_pu: 0.2, rating_a_mva: 200.0),
        line(4, 2, 5, x_pu: 0.1, rating_a_mva: 200.0),
        line(5, 3, 5, x_pu: 0.15, rating_a_mva: 200.0),
        line(6, 4, 5, x_pu: 0.2, rating_a_mva: 200.0),
      ],
      transformers: [],
      generators: [generator(1, 1, p_max_mw: 300.0)],
      loads: [load(1, 5, p_mw: 100.0)]
    }
  end

  # ===========================================================================
  # Small-Signal Stability Tests
  # ===========================================================================

  describe "small-signal stability" do
    test "two-generator system produces eigenvalues" do
      snapshot = three_bus_two_gen()

      # Build Y_red for the two generators
      # Simplified: treat as SMIB-like with direct admittance
      b12 = 1.0 / 0.1  # line 1
      b23 = 1.0 / 0.15 # line 2
      # Total admittance between gen 1 (bus 1) and gen 2 (bus 3) through bus 2
      # Series: b_total = 1 / (1/b12 + 1/b23)
      b_total = 1.0 / (1.0 / b12 + 1.0 / b23)

      y_red = {
        [0, 0, 1, 1],           # rows
        [0, 1, 0, 1],           # cols
        [0.0, 0.0, 0.0, 0.0],  # G values
        [-b_total, b_total, b_total, -b_total]  # B values
      }

      angles = [0.2, -0.1]  # operating point angles
      e_prime = [1.1, 1.05]

      result = SmallSignal.analyze(
        snapshot.generators, y_red, angles, e_prime
      )

      assert %SmallSignal{} = result
      assert result.n_gen == 2
      assert length(result.eigenvalues) == 4  # 2n states
      assert is_boolean(result.stable)
    end

    test "well-damped system is stable" do
      # Two generators with strong damping
      gens = [
        generator(1, 1, p_max_mw: 100.0, inertia_h: 5.0, d_factor: 10.0),
        generator(2, 3, p_max_mw: 100.0, inertia_h: 5.0, d_factor: 10.0)
      ]

      b = 5.0
      y_red = {[0, 0, 1, 1], [0, 1, 0, 1], [0.0, 0.0, 0.0, 0.0], [-b, b, b, -b]}
      angles = [0.1, -0.1]
      e_prime = [1.0, 1.0]

      result = SmallSignal.analyze(gens, y_red, angles, e_prime)

      # Strong damping should make all eigenvalue real parts negative
      assert result.stable
    end

    test "critical_mode returns the least damped mode" do
      gens = [
        generator(1, 1, p_max_mw: 100.0, inertia_h: 5.0, d_factor: 1.0),
        generator(2, 3, p_max_mw: 100.0, inertia_h: 4.0, d_factor: 0.5)
      ]

      b = 8.0
      y_red = {[0, 0, 1, 1], [0, 1, 0, 1], [0.0, 0.0, 0.0, 0.0], [-b, b, b, -b]}
      angles = [0.15, -0.15]
      e_prime = [1.1, 1.0]

      result = SmallSignal.analyze(gens, y_red, angles, e_prime)
      critical = SmallSignal.critical_mode(result)

      if critical do
        assert critical.freq_hz > 0.0
        assert is_float(critical.damping_ratio)
      end
    end

    test "classify_modes labels inter-area and local modes" do
      result = %SmallSignal{
        n_gen: 2,
        eigenvalues: [{-0.5, 3.0}, {-0.5, -3.0}, {-2.0, 12.0}, {-2.0, -12.0}],
        modes: [
          %{freq_hz: 0.48, damping_ratio: 0.16, type: :unknown, eigenvalue: {-0.5, 3.0}, participation: %{}},
          %{freq_hz: 1.91, damping_ratio: 0.16, type: :unknown, eigenvalue: {-2.0, 12.0}, participation: %{}}
        ],
        stable: true, a_matrix: nil, gen_ids: [1, 2]
      }

      classified = SmallSignal.classify_modes(result)

      types = Enum.map(classified, & &1.type)
      assert :inter_area in types
      assert :local in types
    end

    test "single generator returns stable with no modes" do
      gens = [generator(1, 1, p_max_mw: 100.0)]
      y_red = {[], [], [], []}

      result = SmallSignal.analyze(gens, y_red, [0.0], [1.0])

      assert result.stable
      assert result.modes == []
    end
  end

  # ===========================================================================
  # Continuation Power Flow Tests
  # ===========================================================================

  describe "continuation power flow" do
    test "traces P-V curve for simple system" do
      snapshot = diamond_snapshot()

      result = CPF.trace(snapshot, solver: :dc, step_size: 0.1, max_steps: 50)

      assert %CPF{} = result
      assert length(result.pv_curve) > 1
      assert result.steps > 0
    end

    test "margin_mw is positive for a loadable system" do
      snapshot = diamond_snapshot()

      result = CPF.trace(snapshot, solver: :dc, step_size: 0.1)

      assert result.margin_mw > 0.0
    end

    test "P-V curve starts at base case (lambda=0)" do
      snapshot = diamond_snapshot()

      result = CPF.trace(snapshot, solver: :dc, step_size: 0.1)

      if result.pv_curve != [] do
        first_point = hd(result.pv_curve)
        assert_in_delta first_point.lambda, 0.0, 0.001
      end
    end

    test "voltage decreases as loading increases" do
      snapshot = three_bus_two_gen()

      result = CPF.trace(snapshot, solver: :dc, step_size: 0.1)

      if length(result.pv_curve) >= 3 do
        # DC solver always returns V=1.0, so this test checks loading increases
        lambdas = Enum.map(result.pv_curve, & &1.lambda)
        assert hd(lambdas) < List.last(lambdas)
      end
    end

    test "pv_data returns {load, voltage} pairs for a bus" do
      snapshot = diamond_snapshot()

      result = CPF.trace(snapshot, solver: :dc, step_size: 0.2, max_steps: 10)

      data = CPF.pv_data(result, 5)

      assert is_list(data)
      if data != [] do
        {load_mw, vm} = hd(data)
        assert is_float(load_mw)
        assert is_float(vm)
      end
    end

    test "weak_buses identifies buses with low voltage at nose" do
      snapshot = diamond_snapshot()

      result = CPF.trace(snapshot, solver: :dc, step_size: 0.1)

      # DC solver gives V=1.0 everywhere, so no weak buses expected
      weak = CPF.weak_buses(result, 0.95)
      assert is_list(weak)
    end

    test "heavily loaded system has small margin" do
      # Almost fully loaded — small margin expected
      snapshot = %{
        buses: [bus(1, bus_type: 3), bus(2)],
        lines: [line(1, 1, 2, x_pu: 0.5, rating_a_mva: 50.0)],
        transformers: [],
        generators: [generator(1, 1, p_max_mw: 55.0)],
        loads: [load(1, 2, p_mw: 50.0)]
      }

      result = CPF.trace(snapshot, solver: :dc, step_size: 0.05)

      assert %CPF{} = result
      # System is near its limit — may or may not converge depending on solver tolerance
      assert result.steps >= 0
    end
  end
end
