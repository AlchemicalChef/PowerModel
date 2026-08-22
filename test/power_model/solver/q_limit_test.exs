defmodule PowerModel.Solver.QLimitTest do
  use ExUnit.Case, async: true

  alias PowerModel.Solver.{NewtonRaphson, Solution}

  @base_mva 100.0
  @pv_setpoint 1.02
  @q_load_mvar 30.0

  defp snapshot(q_max_mvar) do
    %{
      # Analytic case: the assertion is that the PV bus's own reactive LOAD is
      # counted against q_max, so that load has to arrive at the solver exactly
      # as written. Distribution compensation would net part of it away and
      # this would be testing a different number.
      load_compensation: 0.0,
      buses: [
        %{id: 1, bus_type: 3, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0},
        %{id: 2, bus_type: 2, base_kv: 138.0, vm_pu: @pv_setpoint, va_rad: 0.0}
      ],
      lines: [
        %{
          id: 1,
          from_bus_id: 1,
          to_bus_id: 2,
          voltage_kv: 138.0,
          r_pu: 0.0,
          x_pu: 0.1,
          b_pu: 0.0,
          rating_a_mva: 200.0
        }
      ],
      transformers: [],
      generators: [
        %{
          id: 1,
          bus_id: 1,
          p_max_mw: 0.0,
          capacity_factor: 1.0,
          q_max_mvar: 999.0,
          q_min_mvar: -999.0
        },
        %{
          id: 2,
          bus_id: 2,
          p_max_mw: 0.0,
          capacity_factor: 1.0,
          q_max_mvar: q_max_mvar,
          q_min_mvar: -100.0
        }
      ],
      loads: [
        %{id: 1, bus_id: 2, p_mw: 0.0, q_mvar: @q_load_mvar}
      ]
    }
  end

  defp pv_generator_q_mvar(solution) do
    [slack_vm, pv_vm] = solution.vm_pu
    [slack_angle, pv_angle] = solution.va_rad
    x_pu = 0.1

    q_calc_pu =
      pv_vm * pv_vm / x_pu -
        slack_vm * pv_vm * :math.cos(pv_angle - slack_angle) / x_pu

    q_calc_pu * @base_mva + @q_load_mvar
  end

  test "PV reactive load is included when enforcing the generator Q maximum" do
    q_max_mvar = 40.0

    {:ok, solution} =
      NewtonRaphson.solve(snapshot(q_max_mvar),
        base_mva: @base_mva,
        tolerance: 1.0e-10
      )

    assert solution.converged
    assert solution.max_mismatch < 1.0e-10
    assert_in_delta pv_generator_q_mvar(solution), q_max_mvar, 1.0e-5

    pv_voltage = Solution.bus_voltage(solution, 2).vm_pu
    assert pv_voltage < @pv_setpoint
    refute_in_delta pv_voltage, @pv_setpoint, 1.0e-4
  end

  test "a stressed warm start with a generous limit finishes as PV at its setpoint" do
    warm_start = %Solution{
      bus_ids: [1, 2],
      vm_pu: [0.7, 0.6],
      va_rad: [0.0, 0.45]
    }

    {:ok, solution} =
      NewtonRaphson.solve(snapshot(100.0),
        base_mva: @base_mva,
        tolerance: 1.0e-10,
        warm_start: warm_start
      )

    assert solution.converged
    assert solution.max_mismatch < 1.0e-10
    assert_in_delta Solution.bus_voltage(solution, 2).vm_pu, @pv_setpoint, 1.0e-12
    assert pv_generator_q_mvar(solution) < 100.0
  end
end
