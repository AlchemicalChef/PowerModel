defmodule PowerModel.Ingestion.CapacityInferenceTest do
  @moduledoc """
  Parallel circuits inferred from at-rest loading (REVIEW CAS-30): the rule,
  its iteration, its cap, and that a second application is a no-op.
  """

  use ExUnit.Case, async: true

  alias PowerModel.Ingestion.CapacityInference
  alias PowerModel.Solver.DCPowerFlow

  # Slack — line A — bus 2 — line B — bus 3 (load). Line A is rated for a
  # third of what it carries; line B is fine.
  defp radial(load_mw) do
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
          b_pu: 0.02,
          rating_a_mva: 100.0,
          rating_b_mva: 110.0,
          rating_c_mva: 120.0
        },
        %{
          id: 2,
          from_bus_id: 2,
          to_bus_id: 3,
          r_pu: 0.01,
          x_pu: 0.1,
          b_pu: 0.02,
          rating_a_mva: 1000.0,
          rating_b_mva: 1100.0,
          rating_c_mva: 1200.0
        }
      ],
      transformers: [],
      generators: [%{id: 1, bus_id: 1, p_max_mw: 1000.0, capacity_factor: 1.0}],
      loads: [%{id: 1, bus_id: 3, p_mw: load_mw, q_mvar: 0.0}]
    }
  end

  test "a branch over the threshold gets the circuits it needs, folded into its parameters" do
    {snap, report} = CapacityInference.infer(radial(300.0))

    # 300 MW on 100 MVA = 300 %; at a 0.8 threshold that is ceil(3.75) = 4 circuits.
    a = Enum.find(snap.lines, &(&1.id == 1))
    b = Enum.find(snap.lines, &(&1.id == 2))
    assert a.inferred_circuits == 4
    assert_in_delta a.x_pu, 0.025, 1.0e-12
    assert_in_delta a.r_pu, 0.0025, 1.0e-12
    assert_in_delta a.b_pu, 0.08, 1.0e-12
    assert a.rating_a_mva == 400.0 and a.rating_b_mva == 440.0 and a.rating_c_mva == 480.0
    assert b.inferred_circuits == 1 and b.x_pu == 0.1

    assert report.branches == 1
    assert report.extra_circuits == 3
    assert report.circuits == %{{:line, 1} => 4}
    assert report.over_cap == %{}

    # Nothing is over the threshold afterwards.
    flows = DCPowerFlow.solve(snap, base_mva: 100.0).line_flows
    assert flows[{:line, 1}].loading_pct <= 80.0
  end

  test "a second application changes nothing" do
    {once, _} = CapacityInference.infer(radial(300.0))
    {twice, report} = CapacityInference.infer(once)
    assert report.branches == 0

    assert Enum.map(twice.lines, &{&1.x_pu, &1.rating_a_mva}) ==
             Enum.map(once.lines, &{&1.x_pu, &1.rating_a_mva})
  end

  test "a branch that would need more than the cap is left alone and reported" do
    # 1,200 MW on 100 MVA wants ceil(15) = 15 circuits; line B (1,000 MVA) is
    # at 120 % and gets its two. Line A is refused and named.
    {snap, report} = CapacityInference.infer(radial(1200.0), max_circuits: 8)
    a = Enum.find(snap.lines, &(&1.id == 1))
    b = Enum.find(snap.lines, &(&1.id == 2))
    assert a.inferred_circuits == 1
    assert a.x_pu == 0.1
    assert b.inferred_circuits == 2
    assert Map.has_key?(report.over_cap, {:line, 1})
    assert report.branches == 1
  end

  test "the threshold is the criterion: a branch under it is untouched" do
    {snap, report} = CapacityInference.infer(radial(70.0))
    assert Enum.all?(snap.lines, &(&1.inferred_circuits == 1))
    assert report.branches == 0
  end

  test "at_rest_loading summarises the DC flow" do
    r = CapacityInference.at_rest_loading(radial(300.0))
    assert r.rated == 2
    assert r.over[100] == 1 and r.over[200] == 1 and r.over[300] == 0
    assert_in_delta r.overload_mw, 200.0, 1.0e-6
    assert [%{branch: {:line, 1}} | _] = r.worst
    assert r.by_class == %{138.0 => 1}
  end

  test "scaling a transformer multiplies its bank" do
    t = CapacityInference.scale_transformer(%{r_pu: 0.01, x_pu: 0.1, rated_mva: 100.0}, 2)
    assert t.x_pu == 0.05 and t.r_pu == 0.005 and t.rated_mva == 200.0
  end
end
