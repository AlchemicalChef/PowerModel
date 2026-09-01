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

  test "a reported real limit is never given circuits, and is reported as one (EXT-1)" do
    snap = radial(300.0)
    {same, report} = CapacityInference.infer(snap, exclude: MapSet.new([{:line, 1}]))
    assert Enum.find(same.lines, &(&1.id == 1)).inferred_circuits == 1
    assert report.real_limits == [{:line, 1}]
    assert report.branches == 0
  end

  test "known_binding_elements/2 resolves a vendored record by HIFLD source_id within the snapshot" do
    path = Path.join(System.tmp_dir!(), "known_binding_#{System.unique_integer([:positive])}.csv")

    File.write!(path, """
    iso,label,binding_intervals,branch_id,source_id,kv,inferred_circuits,dc_loading_pct
    ercot,A-B 138kV,480,999999,hifld-77,138.0,3,74
    miso,XF X,10,T42,,345.0,1,36
    ercot,C-D 69kV,5,1,hifld-absent,69.0,1,10
    """)

    snap =
      update_in(radial(100.0), [:lines], fn [a, b] -> [Map.put(a, :source_id, "hifld-77"), b] end)

    keys = CapacityInference.known_binding_elements(snap, [path])
    File.rm!(path)
    assert keys == MapSet.new([{:line, 1}, {:transformer, 42}])
  end

  test "scaling a transformer multiplies its bank" do
    t = CapacityInference.scale_transformer(%{r_pu: 0.01, x_pu: 0.1, rated_mva: 100.0}, 2)
    assert t.x_pu == 0.05 and t.r_pu == 0.005 and t.rated_mva == 200.0
  end
end

defmodule PowerModel.Ingestion.CapacityInferencePocketTest do
  @moduledoc """
  The AC-driven loop (REVIEW CAS-30): a pocket whose feed is too WEAK rather
  than too small — fine on MVA loading, past its P-V nose on reactance — is
  found from the failed AC iterate, its feeding path traced from the DC flow,
  and the path reinforced until the pocket is inside the radial loadability
  criterion.
  """

  use ExUnit.Case, async: true

  alias PowerModel.Ingestion.CapacityInference
  alias PowerModel.Solver.VoltageControl

  # Slack (138 kV) — stiff line — bus 2 — a long weak 33 kV-class chain (three
  # lines at x 0.6 pu, rated well above their flow) — bus 5 with 30 MW. At
  # full load the chain is past its nose; at 40 % it solves.
  defp weak_radial do
    %{
      buses: [
        %{id: 1, bus_type: 3, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0},
        %{id: 2, bus_type: 1, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0},
        %{id: 3, bus_type: 1, base_kv: 33.0, vm_pu: 1.0, va_rad: 0.0},
        %{id: 4, bus_type: 1, base_kv: 33.0, vm_pu: 1.0, va_rad: 0.0},
        %{id: 5, bus_type: 1, base_kv: 33.0, vm_pu: 1.0, va_rad: 0.0}
      ],
      lines: [
        %{
          id: 1,
          from_bus_id: 1,
          to_bus_id: 2,
          r_pu: 0.005,
          x_pu: 0.02,
          b_pu: 0.0,
          rating_a_mva: 500.0
        },
        %{
          id: 3,
          from_bus_id: 3,
          to_bus_id: 4,
          r_pu: 0.2,
          x_pu: 0.6,
          b_pu: 0.0,
          rating_a_mva: 56.0
        },
        %{
          id: 4,
          from_bus_id: 4,
          to_bus_id: 5,
          r_pu: 0.2,
          x_pu: 0.6,
          b_pu: 0.0,
          rating_a_mva: 56.0
        }
      ],
      transformers: [
        %{
          id: 1,
          from_bus_id: 2,
          to_bus_id: 3,
          r_pu: 0.0,
          x_pu: 0.6,
          tap_ratio: 1.0,
          rated_mva: 100.0
        }
      ],
      generators: [
        %{
          id: 1,
          bus_id: 1,
          p_max_mw: 500.0,
          capacity_factor: 1.0,
          q_max_mvar: 400.0,
          q_min_mvar: -400.0
        }
      ],
      loads: [%{id: 1, bus_id: 5, p_mw: 30.0, q_mvar: 6.0}],
      load_compensation: 0.0
    }
  end

  test "the at-rest rule cannot see a weak feed, and the pocket loop can" do
    snap = weak_radial()

    # 30 MW on 56 MVA is 54 %: nothing for the at-rest rule.
    {_same, at_rest} = CapacityInference.infer(snap)
    assert at_rest.branches == 0

    # And the full load has no controlled AC solution.
    {:ok, base} = VoltageControl.solve(snap, base_mva: 100.0, load_compensation: 0.0)
    refute base.converged

    {fixed, report} =
      CapacityInference.raise_ceiling(snap,
        alpha_steps: [0.4, 1.0],
        target: 1.0,
        load_compensation: 0.0,
        dense_nr_max_buses: 25
      )

    assert report.ceiling == 1.0
    assert report.fixes != []
    assert report.unfixable == []

    # The reinforcement landed on the weak chain, not on the stiff 138 kV line.
    assert Enum.all?(report.circuits, fn {key, n} -> key != {:line, 1} and n >= 2 end)
    assert report.circuits != %{}
    assert Enum.find(fixed.lines, &(&1.id == 1)).inferred_circuits == 1

    {:ok, sol} = VoltageControl.solve(fixed, base_mva: 100.0, load_compensation: 0.0)
    assert sol.converged
  end

  test "the cap counts circuits already stored on the row" do
    # The weak chain already carries the maximum inferred count: nothing may
    # be added, and the pocket is refused rather than multiplied past the cap.
    snap =
      weak_radial()
      |> update_in([:lines], fn ls -> Enum.map(ls, &Map.put(&1, :inferred_circuits, 8)) end)
      |> update_in([:transformers], fn ts -> Enum.map(ts, &Map.put(&1, :inferred_circuits, 8)) end)

    {same, report} =
      CapacityInference.raise_ceiling(snap,
        alpha_steps: [1.0],
        target: 1.0,
        load_compensation: 0.0,
        dense_nr_max_buses: 25
      )

    assert report.ceiling == 0.0
    assert report.circuits == %{}
    assert report.unfixable != []
    assert Enum.map(same.lines, & &1.x_pu) == Enum.map(snap.lines, & &1.x_pu)
  end
end
