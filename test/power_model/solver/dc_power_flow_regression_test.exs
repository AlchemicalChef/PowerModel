defmodule PowerModel.Solver.DCPowerFlowRegressionTest do
  use ExUnit.Case, async: true

  alias PowerModel.Solver.{DCPowerFlow, Solution}

  defp bus(id, bus_type) do
    %{id: id, bus_type: bus_type, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0}
  end

  defp line(id, from_bus_id, to_bus_id, x_pu) do
    %{
      id: id,
      from_bus_id: from_bus_id,
      to_bus_id: to_bus_id,
      x_pu: x_pu,
      rating_a_mva: 1_000.0
    }
  end

  test "singularity in the final Gaussian pivot throws the documented error" do
    snapshot = %{
      buses: [bus(1, 3), bus(2, 1), bus(3, 1)],
      lines: [
        line(1, 1, 2, 1.0),
        line(2, 1, 2, -1.0),
        line(3, 2, 3, 1.0)
      ],
      transformers: [],
      generators: [%{id: 1, bus_id: 1, p_max_mw: 100.0, capacity_factor: 1.0}],
      loads: [%{id: 1, bus_id: 3, p_mw: 100.0}]
    }

    assert catch_throw(DCPowerFlow.solve(snapshot)) == {:error, :singular_matrix}
  end

  test "off-nominal transformer tap scales DC stiffness and flow denominator" do
    base_mva = 100.0
    reactance = 0.1
    tap_ratio = 1.05

    snapshot = %{
      buses: [bus(1, 3), bus(2, 1)],
      lines: [],
      transformers: [
        %{
          id: 1,
          from_bus_id: 1,
          to_bus_id: 2,
          x_pu: reactance,
          tap_ratio: tap_ratio,
          rated_mva: 100.0
        }
      ],
      generators: [%{id: 1, bus_id: 1, p_max_mw: 50.0, capacity_factor: 1.0}],
      loads: [%{id: 1, bus_id: 2, p_mw: 50.0}]
    }

    solution = DCPowerFlow.solve(snapshot, base_mva: base_mva)
    flow = Solution.line_flow(solution, :transformer, 1)
    [theta_from, theta_to] = solution.va_rad
    angle_difference = theta_from - theta_to
    tapless_flow_at_same_angles = angle_difference / reactance * base_mva

    assert_in_delta angle_difference, tap_ratio * reactance * 0.5, 1.0e-12

    assert_in_delta flow.p_flow_mw,
                    angle_difference / (tap_ratio * reactance) * base_mva,
                    1.0e-9

    assert_in_delta tapless_flow_at_same_angles, flow.p_flow_mw * tap_ratio, 1.0e-9
  end
end
