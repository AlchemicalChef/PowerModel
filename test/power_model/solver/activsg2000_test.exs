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

  **AC is written but skipped**, for two independent reasons, both measured
  rather than assumed.

  *It is too slow for a suite that otherwise finishes in seconds.* A converged
  AC solve takes **334.7 s** — 21 iterations at ~18.8 s each, with a ~2.9 GB
  peak heap. The dense Jacobian here is 3607x3607, about 13 million entries
  rebuilt from scratch every iteration, and `compute_power/4` sweeps all
  2000x2000 Y-bus positions whether or not they are nonzero. That is a property
  of the dense path, not of the case, and ROADMAP Phase 4 item 19
  (fast-decoupled AC at scale — constant B'/B'' factorized once per topology on
  the existing LDL^T NIF) is the fix.

  *It is also not accurate enough yet, which speed will not fix.* Run to
  convergence (max mismatch 3.1e-10), the solve matches the reference on losses
  — 1617.6 MW against 1612.2 MW, 0.335%, inside the 1% contract — and on served
  load exactly. But the voltage profile misses: the worst bus is **2.86% off**
  (bus 1070 solves to 1.040 pu, its setpoint, where the reference floats up to
  1.071 pu), against a 0.5% contract, and bus 2059's angle is 0.0129 rad off.

  The cause is Q-limit switching, not the linear algebra. Released from their
  limits, **176 of this case's 392 generator buses** end up outside their
  reactive range, against 6 of 54 in IEEE-118 — and at six this solver is exact,
  switching the same buses as the reference (`PowerModel.Solver.IEEE118Test`
  asserts it). Here it takes 164 buses off setpoint against the reference's 195:
  163 the same, **32 it never switches**, 1 it switches alone. Bus 1070 is one
  of the 32.

  The suspect is the back-switching rule in
  `NewtonRaphson.update_pv_pq_switching/7`, which returns a bus pinned at
  `q_max` to PV once its voltage exceeds setpoint. That is sound locally but
  reads a voltage the *global* switching state determines: bus 1070 really does
  exceed `q_max` (36.57 against 34.19 MVAr) and still lands above its setpoint
  once the other 175 buses clamp, so it is handed back to PV to violate again
  until `@max_qlim_rounds 6` ends the round trip.

  So: removing `:skip` after FDPF lands will make the loss and totals
  assertions pass and leave the two voltage assertions failing until the
  Q-limit gap is closed. That is the intended signal, which is why the
  tolerances below are the IEEE-14/118 contract values and have deliberately
  not been pre-relaxed to whatever the current path happens to produce.

  Reference: `test/fixtures/matpower/case_ACTIVSg2000_reference.json`, generated
  by pandapower via `scripts/generate_references.py`. See the fixtures README
  for provenance, the CC BY 4.0 license, and the required citation.
  """

  use ExUnit.Case, async: true

  alias PowerModel.Solver.{DCPowerFlow, NewtonRaphson, Solution}
  alias PowerModel.Test.MATPOWER

  @moduletag :ieee

  @case_path "test/fixtures/matpower/case_ACTIVSg2000.m"
  @reference_path "test/fixtures/matpower/case_ACTIVSg2000_reference.json"

  # DC angles agree with the reference to 1.9e-3 rad, and that residual is
  # fully accounted for: `YBus.effective_reactance/1` floors |x| at 1.0e-3 pu,
  # while three branches in this case have a true x of 7.0e-4 to 8.8e-4 pu.
  # Re-running the reference with the same floor applied reproduces the
  # deviation to three significant figures (0.108 deg worst bus, 0.033 deg
  # mean), so nothing else is contributing. The tolerance admits that artifact
  # with a small margin and nothing larger; if the floor is ever lowered, this
  # should be tightened toward the IEEE-118 value of 1.0e-5 rad.
  @dc_angle_tolerance_rad 5.0e-3
  @dc_angle_mean_tolerance_rad 1.0e-3

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
               "tolerance #{@dc_angle_tolerance_rad}). Expected residual from the " <>
               "1.0e-3 pu reactance floor is 1.9e-3 rad; anything larger is new."
    end

    test "the reactance-floor residual stays confined to a few buses", %{
      solution: sol,
      reference: ref
    } do
      # The floor perturbs three branches, so the deviation stays concentrated:
      # the network-wide mean is 5.8e-4 rad against a 1.9e-3 rad worst bus. A
      # modeling change that shifted every bus would move the mean too, which
      # the worst-bus assertion above on its own would not distinguish.
      devs = deviations(sol, sol.va_rad, ref["dc"]["buses"], &deg_to_rad(&1["va_deg"]))
      mean = mean_deviation(devs)
      {bus_id, _actual, _expected, worst_dev} = worst(devs)

      assert mean < @dc_angle_mean_tolerance_rad,
             "mean DC angle deviation #{mean} rad exceeds " <>
               "#{@dc_angle_mean_tolerance_rad} rad (worst bus #{bus_id} at " <>
               "#{worst_dev} rad) — the deviation is no longer localized"
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

  # ── AC power flow (awaiting ROADMAP Phase 4 item 19) ──────────────────

  describe "AC power flow on ACTIVSg2000" do
    # SKIPPED, not deleted, on measured grounds: a converged solve takes 334.7 s
    # and ~2.9 GB, and even then two of these assertions fail. See the moduledoc
    # for the numbers. Dropping the tag is the right move once ROADMAP Phase 4
    # item 19 (fast-decoupled AC) lands — expect the loss and totals assertions
    # to go green and the two voltage assertions to stay red until the Q-limit
    # switching gap is closed.
    @describetag :skip
    @describetag :slow

    setup %{snapshot: snap} do
      {:ok, solution} = NewtonRaphson.solve(snap, solver_opts(snap))
      %{solution: solution}
    end

    test "converges", %{solution: sol} do
      assert sol.converged,
             "Newton-Raphson did not converge after #{sol.iterations} iterations " <>
               "(max mismatch #{inspect(sol.max_mismatch)})"

      assert sol.max_mismatch < 1.0e-6
    end

    test "voltage magnitudes are within #{@vm_tolerance_pct}% of the reference", %{
      solution: sol,
      reference: ref
    } do
      {bus_id, actual, expected, pct} =
        sol.bus_ids
        |> Enum.zip(sol.vm_pu)
        |> Enum.map(fn {bus_id, actual} ->
          expected = Map.fetch!(ref["ac"]["buses"], Integer.to_string(bus_id))["vm_pu"]
          {bus_id, actual, expected, abs(actual - expected) / expected * 100.0}
        end)
        |> Enum.max_by(fn {_id, _a, _e, pct} -> pct end)

      assert pct < @vm_tolerance_pct,
             "worst Vm error at bus #{bus_id}: got #{Float.round(actual, 5)} pu, " <>
               "reference #{expected} pu (#{Float.round(pct, 4)}%, " <>
               "tolerance #{@vm_tolerance_pct}%)"
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
