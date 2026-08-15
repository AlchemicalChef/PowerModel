defmodule PowerModel.Solver.OptionalKeysTest do
  @moduledoc """
  SOL-5 regression tests.

  Solver inputs arrive both as Ecto structs and as plain maps (tests, cascade
  fixtures). Optional keys — q limits, ratings, tap ratio, capacity factor —
  must be read with `Map.get`, so a plain map without them solves instead of
  raising KeyError.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Solver.{DCPowerFlow, NewtonRaphson}

  defp bus(id, opts \\ []) do
    %{
      id: id,
      bus_type: Keyword.get(opts, :bus_type, 1),
      base_kv: 138.0,
      vm_pu: 1.0,
      va_rad: 0.0
    }
  end

  test "DC solve accepts branch/generator maps without optional keys" do
    snapshot = %{
      buses: [bus(1, bus_type: 3), bus(2), bus(3)],
      # no rating_a_mva on the line; no tap_ratio / rated_mva on the transformer
      lines: [%{id: 1, from_bus_id: 1, to_bus_id: 2, x_pu: 0.1}],
      transformers: [%{id: 1, from_bus_id: 2, to_bus_id: 3, x_pu: 0.05}],
      # no capacity_factor / q limits on the generator
      generators: [%{id: 1, bus_id: 1, p_max_mw: 100.0}],
      loads: [
        %{id: 1, bus_id: 2, p_mw: 30.0},
        %{id: 2, bus_id: 3, p_mw: 20.0}
      ]
    }

    solution = DCPowerFlow.solve(snapshot)

    assert_in_delta solution.total_load_mw, 50.0, 1.0e-6

    line_flow = solution.line_flows[{:line, 1}]
    assert_in_delta line_flow.p_flow_mw, 50.0, 1.0e-6
    assert line_flow.rating_mva == nil
    refute line_flow.overloaded

    xfmr_flow = solution.line_flows[{:transformer, 1}]
    assert_in_delta xfmr_flow.p_flow_mw, 20.0, 1.0e-6
    assert xfmr_flow.rating_mva == nil
    refute xfmr_flow.overloaded
  end

  test "AC solve accepts a limit-less generator map and rating-less branches" do
    # Lines/transformers keep the keys YBus itself requires (r_pu, x_pu, b_pu,
    # tap_ratio) but omit ratings; generators omit q limits and capacity factor.
    snapshot = %{
      buses: [bus(1, bus_type: 3), bus(2), bus(3)],
      lines: [
        %{id: 1, from_bus_id: 1, to_bus_id: 2, r_pu: 0.01, x_pu: 0.1, b_pu: 0.0}
      ],
      transformers: [
        %{id: 1, from_bus_id: 2, to_bus_id: 3, r_pu: 0.005, x_pu: 0.05, tap_ratio: nil}
      ],
      generators: [%{id: 1, bus_id: 1, p_max_mw: 50.0}],
      loads: [
        %{id: 1, bus_id: 2, p_mw: 20.0, q_mvar: 5.0},
        %{id: 2, bus_id: 3, p_mw: 10.0, q_mvar: 2.0}
      ]
    }

    assert {:ok, solution} = NewtonRaphson.solve(snapshot)
    assert solution.converged

    line_flow = solution.line_flows[{:line, 1}]
    assert line_flow.rating_mva == nil
    refute line_flow.overloaded

    xfmr_flow = solution.line_flows[{:transformer, 1}]
    assert xfmr_flow.rating_mva == nil
    refute xfmr_flow.overloaded
    assert_in_delta xfmr_flow.p_flow_mw, 10.0, 1.0
  end
end
