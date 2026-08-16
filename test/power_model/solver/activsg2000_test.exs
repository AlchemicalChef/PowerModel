defmodule PowerModel.Solver.ACTIVSg2000Test do
  @moduledoc """
  Rung three of the solver validation ladder (ROADMAP Phase 0 item 4): the
  synthetic 2000-bus Texas case, ACTIVSg2000.

  This is the first case in the ladder large enough to be about *scale* rather
  than *correctness of the equations* — IEEE-14 and IEEE-118 already establish
  the latter. It sits at roughly three times the ~600–800 bus practical ceiling
  the ROADMAP measured for the dense Newton-Raphson path.

  ## What runs, and what does not

  **DC runs.** A full DC solve takes ~0.4 s and is asserted against the
  committed reference.

  **AC runs on FDPF** (ROADMAP Phase 4 item 19) in ~200 ms, where the dense
  Newton-Raphson path took a measured 334.7 s and ~2.9 GB — the history of why
  it was skipped in the dense era is in git.

  It runs under `q_limit_policy: :matpower`, and that choice is load-bearing:
  the pandapower reference implements MATPOWER-style `enforce_q_lims`, which
  never back-switches a limit-pinned bus. Traced on this case (2026-08-15),
  the reference's fixed point violates complementarity at 48 of its 195
  off-setpoint generator buses — e.g. bus 1070 is pinned at q_max = 34.19 MVAr
  with its voltage floating to 1.0707 pu, ABOVE its 1.040 setpoint, which is a
  switching artifact rather than a physical solution. Our default
  `:complementary` policy (release when the voltage says the limit should not
  bind, with a latch bounding type changes) satisfies complementarity at all
  392 generator buses and lands on a DIFFERENT, defensible fixed point —
  losses 0.335% off the reference and bus 1070 at its setpoint. Under
  `:matpower` we reproduce the reference's release rule: 191 of 195 switched
  buses agree bus-for-bus, losses land at 0.0151% and angles at 3.3e-3 rad,
  inside the IEEE-14/118 contract values, unrelaxed.

  The Vm contract of 0.5% cannot hold, for a second, narrower rule difference
  (traced 2026-08-15): MATPOWER and PYPOWER enforce reactive limits PER
  GENERATOR and then demote the whole bus, so a plant with nine units of very
  different sizes stops regulating the moment its smallest unit saturates —
  at bus 4192 that leaves 640.5 MVAr of reactive capability idle while the
  bus sits 1.06% below its setpoint. This solver enforces the aggregate
  station limit, which is what an actual plant controller does. The
  consequence is local and measured: 34 of 2000 buses exceed 0.5%, worst
  1.0707% at bus 4126 (a load bus two hops from 4192), mean 0.0602%, decaying
  monotonically with distance from the seven multi-generator buses where the
  rules differ. The Vm test below asserts that shape rather than a blanket
  tolerance; `fdpf_test.exs` asserts the complementarity property the
  reference itself would fail, plus the structural direction of the
  disagreement (reference-only switches are all multi-generator buses).

  Reference: `test/fixtures/matpower/case_ACTIVSg2000_reference.json`, generated
  by pandapower via `scripts/generate_references.py`. See the fixtures README
  for provenance, the CC BY 4.0 license, and the required citation.
  """

  use ExUnit.Case, async: true

  alias PowerModel.Solver.{DCPowerFlow, FDPF, Solution, YBus}
  alias PowerModel.Test.MATPOWER

  @moduletag :ieee

  @case_path "test/fixtures/matpower/case_ACTIVSg2000.m"
  @reference_path "test/fixtures/matpower/case_ACTIVSg2000_reference.json"

  # DC angles agree with the reference to the last digit the reference prints.
  #
  # This case used to deviate by 1.9e-3 rad (0.108 deg worst bus, 0.033 deg
  # mean), and `YBus.effective_reactance/1`'s 1.0e-3 pu floor was the sole
  # cause: three branches here carry a true x of 7.0e-4, 7.3e-4 and 8.8e-4 pu,
  # and the floor inflated all three. With the floor at 1.0e-5 the whole
  # deviation is gone — MEASURED worst 8.7e-9 rad, mean 4.4e-9 rad, and the
  # reference stores `va_deg` to six decimals, so ±5e-7 deg (±8.7e-9 rad) IS
  # its quantization. There is nothing left to attribute.
  #
  # The tolerances are therefore round-off gates, roughly 11x the reference's
  # own printed resolution, well inside the IEEE-118 contract value of
  # 1.0e-5 rad. A modeling change that reintroduces any physical deviation
  # will fail them immediately.
  @dc_angle_tolerance_rad 1.0e-7
  @dc_angle_mean_tolerance_rad 5.0e-8

  # Contract tolerances for the skipped AC block, matching IEEE-14 and IEEE-118.
  @vm_tolerance_pct 0.5
  @loss_tolerance_pct 1.0
  @ac_angle_tolerance_rad 5.0e-3

  setup_all do
    snapshot = MATPOWER.load!(@case_path)
    reference = @reference_path |> File.read!() |> Jason.decode!()

    # Solved once for the whole module rather than per test: at this size the
    # DC solve is ~0.4 s, and a per-test setup multiplied that across the eight
    # assertions below. The solution is immutable, so sharing it across async
    # tests is safe.
    dc_solution = DCPowerFlow.solve(snapshot, base_mva: snapshot.base_mva)

    {:ok, snapshot: snapshot, reference: reference, dc_solution: dc_solution}
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp solver_opts(snapshot), do: [base_mva: snapshot.base_mva]

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0

  # Every bus paired with its reference value and the deviation between them.
  defp deviations(solution, values, reference_buses, extract) do
    solution.bus_ids
    |> Enum.zip(values)
    |> Enum.map(fn {bus_id, actual} ->
      expected = extract.(Map.fetch!(reference_buses, Integer.to_string(bus_id)))
      {bus_id, actual, expected, abs(actual - expected)}
    end)
  end

  defp worst(deviations), do: Enum.max_by(deviations, fn {_id, _a, _e, dev} -> dev end)

  defp mean_deviation(deviations) do
    Enum.reduce(deviations, 0.0, fn {_id, _a, _e, dev}, acc -> acc + dev end) /
      length(deviations)
  end

  # ── Parser contract ───────────────────────────────────────────────────

  describe "MATPOWER parse of case_ACTIVSg2000" do
    test "produces the case's stated topology", %{snapshot: snap, reference: ref} do
      assert snap.case_name == "case_ACTIVSg2000"
      assert snap.base_mva == 100.0
      assert length(snap.buses) == 2000
      assert length(snap.buses) == ref["n_buses"]
      assert length(snap.lines) + length(snap.transformers) == ref["n_branches"]

      # PowerWorld wrote tap = 1.0 on every branch, including the transformers,
      # so none is distinguishable as one. Harmless: at tap 1 with no shift the
      # transformer and line models are electrically identical, and the line
      # model is the one that keeps the charging susceptance.
      assert length(snap.transformers) == 0
      assert length(snap.lines) == 3206
    end

    test "drops the 112 out-of-service generators", %{snapshot: snap, reference: ref} do
      assert length(snap.generators) == 432
      assert length(snap.generators) == ref["n_generators"]
    end

    test "demotes PV buses that have no in-service generator", %{snapshot: snap} do
      # MATPOWER's bustypes/2 solves a type-2 bus with no live generator as PQ.
      # NewtonRaphson.classify_buses/3 would call it PV on the bus type alone,
      # so the parser retypes them; 93 buses here depend on it.
      assert snap.demoted_pv_buses == 93

      gen_bus_ids = MapSet.new(snap.generators, & &1.bus_id)
      pv_buses = Enum.filter(snap.buses, &(&1.bus_type == 2))

      orphans = Enum.reject(pv_buses, &MapSet.member?(gen_bus_ids, &1.id))

      assert orphans == [],
             "#{length(orphans)} PV buses have no in-service generator, e.g. " <>
               inspect(Enum.take(orphans, 3))

      assert length(pv_buses) == 391
      assert Enum.count(snap.buses, &(&1.bus_type == 3)) == 1
    end

    test "the case is free of the features the snapshot cannot represent", %{snapshot: snap} do
      assert snap.skipped_phase_shifters == 0
      assert snap.transformers_with_dropped_charging == 0
      assert snap.isolated_buses == 0
      assert snap.pq_buses_with_generators == 0
    end

    test "handles non-contiguous bus ids", %{snapshot: snap} do
      # Bus numbers run 1001..8160 with gaps, so anything that assumed 1..n
      # would silently mis-index.
      ids = Enum.map(snap.buses, & &1.id)
      assert Enum.min(ids) == 1001
      assert Enum.max(ids) == 8160
      assert length(Enum.uniq(ids)) == 2000

      bus_ids = MapSet.new(ids)

      for line <- snap.lines do
        assert MapSet.member?(bus_ids, line.from_bus_id)
        assert MapSet.member?(bus_ids, line.to_bus_id)
      end
    end

    test "load and shunt totals match the case", %{snapshot: snap} do
      assert length(snap.loads) == 1125
      assert_in_delta Enum.sum(Enum.map(snap.loads, & &1.p_mw)), 67_109.21, 1.0e-4

      shunts = Enum.filter(snap.buses, &(&1.bs_mvar != 0.0))
      assert length(shunts) == 149
      assert_in_delta Enum.sum(Enum.map(shunts, & &1.bs_mvar)), 18_308.84, 1.0e-4
    end

    test "branch ratings survive the parse", %{snapshot: snap} do
      # Unlike case118, every branch here carries a rateA, so overload
      # reporting is exercised.
      assert Enum.all?(snap.lines, &(is_number(&1.rating_a_mva) and &1.rating_a_mva > 0))
    end
  end

  # ── DC power flow ─────────────────────────────────────────────────────

  describe "DC power flow on ACTIVSg2000" do
    @describetag :slow

    setup %{dc_solution: solution}, do: %{solution: solution}

    test "returns a Solution covering every bus", %{solution: sol} do
      assert %Solution{} = sol
      assert length(sol.bus_ids) == 2000
      assert length(sol.va_rad) == 2000
    end

    test "slack bus 7098 holds zero angle", %{solution: sol, reference: ref} do
      assert ref["slack_bus"] == 7098
      assert sol.slack_bus_id == 7098
      idx = Enum.find_index(sol.bus_ids, &(&1 == 7098))
      assert Enum.at(sol.va_rad, idx) == 0.0
    end

    test "voltage angles match the reference DC solution", %{solution: sol, reference: ref} do
      devs = deviations(sol, sol.va_rad, ref["dc"]["buses"], &deg_to_rad(&1["va_deg"]))
      {bus_id, actual, expected, dev} = worst(devs)

      assert dev < @dc_angle_tolerance_rad,
             "worst DC angle deviation at bus #{bus_id}: got #{actual} rad, " <>
               "reference #{expected} rad (#{dev} rad off, " <>
               "tolerance #{@dc_angle_tolerance_rad}). With the reactance floor " <>
               "at 1.0e-5 pu this case has no modeling residual left — the only " <>
               "admissible deviation is the reference's own 8.7e-9 rad rounding."
    end

    test "no reactance-floor residual survives on the three sub-milli-pu branches", %{
      solution: sol,
      reference: ref,
      snapshot: snap
    } do
      # The floor used to inflate exactly three branches (x = 7.0e-4, 7.3e-4,
      # 8.8e-4 pu) and that showed up as a mean deviation of 5.8e-4 rad against
      # a 1.9e-3 rad worst bus — concentrated, but network-wide in the mean.
      # Both are now at round-off, which is the direct evidence that the floor
      # was the sole contributor. Asserting the MEAN as well as the worst bus
      # is what distinguishes "one bus got lucky" from "the residual is gone".
      devs = deviations(sol, sol.va_rad, ref["dc"]["buses"], &deg_to_rad(&1["va_deg"]))
      mean = mean_deviation(devs)
      {bus_id, _actual, _expected, worst_dev} = worst(devs)

      assert mean < @dc_angle_mean_tolerance_rad,
             "mean DC angle deviation #{mean} rad exceeds " <>
               "#{@dc_angle_mean_tolerance_rad} rad (worst bus #{bus_id} at " <>
               "#{worst_dev} rad) — a modeling residual has reappeared"

      # Pin the premise: exactly three branches sit below the old 1.0e-3 floor
      # and none below the current one. If the case ever gains a branch under
      # the live floor, this test stops being evidence about the floor and
      # should be re-derived rather than re-tuned.
      reactances = Enum.map(snap.lines, &abs(&1.x_pu))

      assert Enum.count(reactances, &(&1 < 1.0e-3)) == 3
      assert Enum.count(reactances, &(&1 < YBus.x_floor())) == 0
      assert_in_delta Enum.min(reactances), 7.0e-4, 1.0e-12
    end

    test "no NaN angles or flows", %{solution: sol} do
      for {bus_id, va} <- Enum.zip(sol.bus_ids, sol.va_rad) do
        assert va == va, "NaN angle at bus #{bus_id}"
      end

      for {key, flow} <- sol.line_flows do
        assert flow.p_flow_mw == flow.p_flow_mw, "NaN flow for #{inspect(key)}"
      end
    end

    test "a flow is reported for every branch", %{solution: sol} do
      assert map_size(sol.line_flows) == 3206
    end

    test "DC totals satisfy the lossless identities", %{solution: sol} do
      assert_in_delta sol.total_load_mw, 67_109.21, 1.0e-3
      assert_in_delta sol.total_gen_mw, sol.total_load_mw, 1.0e-6
      assert sol.total_loss_mw == 0.0
      assert Solution.energy_balance(sol).ok
    end

    test "the network is a single connected island", %{snapshot: snap} do
      # DCPowerFlow.solve/2 assumes one island; a fragmented case would make
      # every angle comparison above meaningless.
      {islands, dead} = PowerModel.Solver.Partition.split(snap)

      assert length(islands) == 1,
             "expected one island, got #{length(islands)} (plus #{length(dead)} dead)"

      assert dead == []
    end
  end

  # ── AC power flow (live since ROADMAP Phase 4 item 19: FDPF) ──────────

  describe "AC power flow on ACTIVSg2000" do
    # :matpower matches the reference's own Q-limit rule — see the moduledoc
    # for why the default :complementary policy legitimately lands elsewhere.
    setup %{snapshot: snap} do
      {:ok, solution} =
        FDPF.solve(snap, Keyword.put(solver_opts(snap), :q_limit_policy, :matpower))

      %{solution: solution}
    end

    test "converges", %{solution: sol} do
      assert sol.converged,
             "FDPF did not converge after #{sol.iterations} iterations " <>
               "(max mismatch #{inspect(sol.max_mismatch)})"

      assert sol.max_mismatch < 1.0e-6
    end

    test "voltage magnitudes match the reference to the per-generator-rule shape", %{
      solution: sol,
      reference: ref
    } do
      # The blanket @vm_tolerance_pct contract cannot hold here — see the
      # moduledoc. Asserting the SHAPE of the known rule-difference residual
      # (worst / mean / count over #{@vm_tolerance_pct}%) regresses harder than
      # one tolerance: a Y-bus or injection bug moves the mean, a switching
      # regression moves the count. Measured 2026-08-15: worst 1.0707% at bus
      # 4126, mean 0.0602%, 34 of 2000 over 0.5%. The structural direction
      # assertions (reference-only switches are all multi-generator buses)
      # live in fdpf_test.exs.
      pcts =
        sol.bus_ids
        |> Enum.zip(sol.vm_pu)
        |> Enum.map(fn {bus_id, actual} ->
          expected = Map.fetch!(ref["ac"]["buses"], Integer.to_string(bus_id))["vm_pu"]
          abs(actual - expected) / expected * 100.0
        end)

      worst = Enum.max(pcts)
      mean = Enum.sum(pcts) / length(pcts)
      over_contract = Enum.count(pcts, &(&1 > @vm_tolerance_pct))

      assert worst < 1.1, "worst Vm error #{Float.round(worst, 4)}%, expected < 1.1%"
      assert mean < 0.07, "mean Vm error #{Float.round(mean, 4)}%, expected < 0.07%"

      assert over_contract <= 34,
             "#{over_contract} buses exceed #{@vm_tolerance_pct}%, expected <= 34"
    end

    test "voltage angles match the reference AC solution", %{solution: sol, reference: ref} do
      {bus_id, actual, expected, dev} =
        worst(deviations(sol, sol.va_rad, ref["ac"]["buses"], &deg_to_rad(&1["va_deg"])))

      assert dev < @ac_angle_tolerance_rad,
             "worst AC angle deviation at bus #{bus_id}: got #{actual} rad, " <>
               "reference #{expected} rad (#{dev} rad off, " <>
               "tolerance #{@ac_angle_tolerance_rad})"
    end

    test "real losses are within #{@loss_tolerance_pct}% of the reference", %{
      solution: sol,
      reference: ref
    } do
      expected = ref["ac"]["total_loss_mw"]
      pct = abs(sol.total_loss_mw - expected) / expected * 100.0

      assert pct < @loss_tolerance_pct,
             "total losses #{Float.round(sol.total_loss_mw, 2)} MW vs reference " <>
               "#{expected} MW (#{Float.round(pct, 4)}%, tolerance #{@loss_tolerance_pct}%)"
    end

    test "generation and load totals match the reference", %{solution: sol, reference: ref} do
      # Loads are constant power, so served load should land on the reference
      # exactly. Generation is load plus losses, so its tolerance is derived
      # from the loss tolerance rather than picked independently — a fixed MW
      # delta here would silently be far stricter than the 1% loss contract.
      assert_in_delta sol.total_load_mw, ref["ac"]["total_load_mw"], 1.0

      gen_slack = @loss_tolerance_pct / 100.0 * ref["ac"]["total_loss_mw"]

      assert_in_delta sol.total_gen_mw, ref["ac"]["total_gen_mw"], gen_slack
      assert Solution.energy_balance(sol).ok
    end

    test "no NaN values anywhere in the solution", %{solution: sol} do
      for {bus_id, vm} <- Enum.zip(sol.bus_ids, sol.vm_pu) do
        assert vm == vm, "NaN Vm at bus #{bus_id}"
      end

      for {bus_id, va} <- Enum.zip(sol.bus_ids, sol.va_rad) do
        assert va == va, "NaN Va at bus #{bus_id}"
      end

      for {key, flow} <- sol.line_flows do
        assert flow.s_flow_mva == flow.s_flow_mva, "NaN S for #{inspect(key)}"
      end
    end
  end
end
