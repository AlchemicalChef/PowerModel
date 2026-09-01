defmodule PowerModel.Dispatch.RedispatchTest do
  @moduledoc """
  Transmission-constrained re-dispatch (REVIEW EXT-1): generation moves off a
  branch over its rating onto units that relieve it, in balance, and stops at
  the rating.
  """

  use ExUnit.Case, async: true

  alias PowerModel.Dispatch.Redispatch
  alias PowerModel.Solver.DCPowerFlow

  # Load at bus 2, fed by gen A at bus 1 (slack) over a 100 MVA line and by
  # gen B at bus 3 over a 500 MVA line. Dispatch puts 200 MW on A: the small
  # line carries it all.
  defp case3(a_mw, b_mw) do
    %{
      buses: [
        %{id: 1, bus_type: 3, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0},
        %{id: 2, bus_type: 1, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0},
        %{id: 3, bus_type: 1, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0}
      ],
      lines: [
        %{
          id: 1,
          from_bus_id: 1,
          to_bus_id: 2,
          r_pu: 0.01,
          x_pu: 0.1,
          b_pu: 0.0,
          rating_a_mva: 100.0
        },
        %{
          id: 2,
          from_bus_id: 3,
          to_bus_id: 2,
          r_pu: 0.01,
          x_pu: 0.1,
          b_pu: 0.0,
          rating_a_mva: 500.0
        }
      ],
      transformers: [],
      generators: [
        %{id: 1, bus_id: 1, p_max_mw: a_mw, p_nameplate_mw: 400.0, capacity_factor: 1.0},
        %{id: 2, bus_id: 3, p_max_mw: b_mw, p_nameplate_mw: 400.0, capacity_factor: 1.0}
      ],
      loads: [%{id: 1, bus_id: 2, p_mw: a_mw + b_mw, q_mvar: 0.0}]
    }
  end

  test "moves generation off the overloaded line, in balance, to the rating" do
    snap = case3(200.0, 0.0)
    flow0 = DCPowerFlow.solve(snap, base_mva: 100.0).line_flows[{:line, 1}]
    assert abs(flow0.p_flow_mw) > 100.0

    {fixed, report} = Redispatch.relieve(snap)
    assert report.stopped == :clean
    assert report.residual == []
    assert report.shifted_mw > 0.0

    [a, b] = fixed.generators
    assert_in_delta a.p_max_mw + b.p_max_mw, 200.0, 1.0e-6
    assert b.p_max_mw > 90.0

    flow = DCPowerFlow.solve(fixed, base_mva: 100.0).line_flows[{:line, 1}]
    assert abs(flow.p_flow_mw) <= 100.0 + 1.0e-6
    assert [%{branch: {:line, 1}}] = report.relieved
  end

  test "a network with nothing over its rating is untouched" do
    snap = case3(50.0, 50.0)
    {same, report} = Redispatch.relieve(snap)
    assert report.iterations == 0 and report.stopped == :clean
    assert Enum.map(same.generators, & &1.p_max_mw) == [50.0, 50.0]
  end

  test "an overload no unit can relieve is reported as residual" do
    # Both units already at nameplate: no room to shift.
    snap =
      case3(200.0, 0.0)
      |> update_in([:generators], fn [a, b] ->
        [%{a | p_nameplate_mw: 200.0}, %{b | p_nameplate_mw: 0.0}]
      end)

    {_same, report} = Redispatch.relieve(snap)
    assert report.stopped == :ineffective
    assert [%{branch: {:line, 1}}] = report.residual
  end
end
