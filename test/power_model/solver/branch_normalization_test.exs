defmodule PowerModel.Solver.BranchNormalizationTest do
  use ExUnit.Case, async: true

  alias PowerModel.Grid.Transformer
  alias PowerModel.Solver.{DCPowerFlow, NewtonRaphson, Solution, YBus}

  @base_mva 100.0

  defp bus(id, bus_type) do
    %{id: id, bus_type: bus_type, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0}
  end

  defp transformer_snapshot(tap_ratio) do
    %{
      buses: [bus(1, 3), bus(2, 1)],
      lines: [],
      transformers: [
        %{
          id: 1,
          from_bus_id: 1,
          to_bus_id: 2,
          r_pu: 0.0,
          x_pu: 0.1,
          tap_ratio: tap_ratio,
          rated_mva: 100.0
        }
      ],
      generators: [
        %{
          id: 1,
          bus_id: 1,
          p_max_mw: 50.0,
          capacity_factor: 1.0,
          q_max_mvar: 100.0,
          q_min_mvar: -100.0
        }
      ],
      loads: [%{id: 1, bus_id: 2, p_mw: 50.0, q_mvar: 0.0}]
    }
  end

  test "a zero transformer tap in a DC snapshot behaves as a nominal tap" do
    zero_tap = DCPowerFlow.solve(transformer_snapshot(0.0), base_mva: @base_mva)
    nominal_tap = DCPowerFlow.solve(transformer_snapshot(1.0), base_mva: @base_mva)

    zero_flow = Solution.line_flow(zero_tap, :transformer, 1)
    nominal_flow = Solution.line_flow(nominal_tap, :transformer, 1)

    assert_in_delta Enum.at(zero_tap.va_rad, 1), Enum.at(nominal_tap.va_rad, 1), 1.0e-12
    assert_in_delta zero_flow.p_flow_mw, nominal_flow.p_flow_mw, 1.0e-9
    assert_in_delta zero_flow.p_flow_mw, 50.0, 1.0e-9
  end

  test "transformer changesets reject a present non-positive tap ratio" do
    changeset =
      Transformer.changeset(%Transformer{}, %{
        rated_mva: 100.0,
        x_pu: 0.1,
        tap_ratio: 0.0,
        from_bus_id: 1,
        to_bus_id: 2
      })

    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :tap_ratio)
  end

  test "the shared reactance floor preserves zero and negative branch semantics" do
    assert YBus.effective_reactance(0.0) == 1.0e-3
    assert YBus.effective_reactance(-1.0e-9) == -1.0e-3
    assert YBus.effective_reactance(-0.2) == -0.2
  end

  test "AC zero-reactance flow reporting matches the floored Y-bus model" do
    snapshot = %{
      buses: [bus(1, 3), bus(2, 1)],
      lines: [
        %{
          id: 1,
          from_bus_id: 1,
          to_bus_id: 2,
          voltage_kv: 138.0,
          r_pu: 0.0,
          x_pu: 0.0,
          b_pu: 0.0,
          rating_a_mva: 100.0
        }
      ],
      transformers: [],
      generators: [
        %{
          id: 1,
          bus_id: 1,
          p_max_mw: 10.0,
          capacity_factor: 1.0,
          q_max_mvar: 100.0,
          q_min_mvar: -100.0
        }
      ],
      loads: [%{id: 1, bus_id: 2, p_mw: 10.0, q_mvar: 5.0}]
    }

    {:ok, solution} =
      NewtonRaphson.solve(snapshot, base_mva: @base_mva, tolerance: 1.0e-10)

    assert solution.converged
    assert solution.max_mismatch < 1.0e-10

    flow = Solution.line_flow(solution, :line, 1)
    [from_vm, to_vm] = solution.vm_pu
    [from_angle, to_angle] = solution.va_rad
    theta = from_angle - to_angle
    x_pu = YBus.effective_reactance(0.0)
    susceptance = -1.0 / x_pu

    expected_p_pu =
      -from_vm * to_vm * susceptance * :math.sin(theta)

    expected_q_pu =
      -from_vm * from_vm * susceptance +
        from_vm * to_vm * susceptance * :math.cos(theta)

    for value <- [flow.p_flow_mw, flow.q_flow_mvar, flow.s_flow_mva] do
      assert is_float(value)
      assert value == value
      assert abs(value) < 1.0e100
    end

    assert_in_delta flow.p_flow_mw, expected_p_pu * @base_mva, 1.0e-8
    assert_in_delta flow.q_flow_mvar, expected_q_pu * @base_mva, 1.0e-8
  end
end
