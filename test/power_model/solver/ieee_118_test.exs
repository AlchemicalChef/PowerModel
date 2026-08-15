defmodule PowerModel.Solver.IEEE118Test do
  @moduledoc """
  Rung two of the solver validation ladder (ROADMAP Phase 0 item 4): the DC and
  AC solvers against the IEEE 118-bus case, loaded from MATPOWER `.m` source
  rather than transcribed by hand.

  Where `PowerModel.Solver.IEEE14BusTest` checks against textbook figures typed
  into the test, this case is checked against
  `test/fixtures/matpower/case118_reference.json` — a committed solution
  produced by pandapower (a maintained MATPOWER/PYPOWER fork) via
  `scripts/generate_references.py`. Nothing here is pinned to output from the
  solvers under test.

  The reference is corroborated externally: released from its Q limits it gives
  132.86 MW of losses, the figure MATPOWER's own `runpf case118` is documented
  to produce.

  Reference angles are in degrees and shifted so the slack bus sits at 0, which
  is where these solvers pin it.
  """

  use ExUnit.Case, async: true

  alias PowerModel.Solver.{DCPowerFlow, NewtonRaphson, Solution}
  alias PowerModel.Test.MATPOWER

  @moduletag :ieee

  @case_path "test/fixtures/matpower/case118.m"
  @reference_path "test/fixtures/matpower/case118_reference.json"

  # Contract tolerances, matching IEEE14BusTest: AC magnitudes to 0.5%, losses
  # to 1%. Actual agreement with the reference is far tighter (worst bus
  # 5.0e-5%, losses 0.0002%), so `@vm_regression_pct` below guards the margin
  # that the contract tolerance alone would let slip away.
  @vm_tolerance_pct 0.5
  @loss_tolerance_pct 1.0
  @vm_regression_pct 0.05

  # DC angles agree with the reference to ~9e-9 rad. 1e-5 rad is three orders
  # above the reference JSON's own rounding quantum (1.7e-8 rad) and five
  # orders above the measured error, so it catches any real modeling change
  # without tracking float noise.
  @dc_angle_tolerance_rad 1.0e-5
  @ac_angle_tolerance_rad 1.0e-4

  setup_all do
    snapshot = MATPOWER.load!(@case_path)
    reference = @reference_path |> File.read!() |> Jason.decode!()

    {:ok, snapshot: snapshot, reference: reference}
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp solver_opts(snapshot), do: [base_mva: snapshot.base_mva]

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0

  # Pair each solved bus with its reference value and return the single worst
  # offender, so a failure names the bus instead of just the magnitude.
  defp worst_deviation(solution, values, reference_buses, extract) do
    solution.bus_ids
    |> Enum.zip(values)
    |> Enum.map(fn {bus_id, actual} ->
      expected = extract.(Map.fetch!(reference_buses, Integer.to_string(bus_id)))
      {bus_id, actual, expected, abs(actual - expected)}
    end)
    |> Enum.max_by(fn {_id, _a, _e, dev} -> dev end)
  end

  defp worst_vm_pct_error(solution, reference_buses) do
    solution.bus_ids
    |> Enum.zip(solution.vm_pu)
    |> Enum.map(fn {bus_id, actual} ->
      expected = Map.fetch!(reference_buses, Integer.to_string(bus_id))["vm_pu"]
      {bus_id, actual, expected, abs(actual - expected) / expected * 100.0}
    end)
    |> Enum.max_by(fn {_id, _a, _e, pct} -> pct end)
  end

  # ── Parser contract ───────────────────────────────────────────────────

  describe "MATPOWER parse of case118" do
    test "produces the case's stated topology", %{snapshot: snap, reference: ref} do
      assert snap.case_name == "case118"
      assert snap.base_mva == 100.0
      assert length(snap.buses) == ref["n_buses"]
      assert length(snap.generators) == ref["n_generators"]
      assert length(snap.lines) + length(snap.transformers) == ref["n_branches"]

      # 9 of the 186 branches carry an off-nominal tap.
      assert length(snap.transformers) == 9
      assert length(snap.lines) == 177
    end

    test "the case is free of the features the snapshot cannot represent", %{snapshot: snap} do
      # A skipped phase shifter would mean the solver is running a different
      # network than the reference, invalidating every comparison below.
      assert snap.skipped_phase_shifters == 0
      assert snap.transformers_with_dropped_charging == 0
      assert snap.isolated_buses == 0
      assert snap.pq_buses_with_generators == 0
      assert snap.demoted_pv_buses == 0
    end

    test "bus 69 is the slack and holds its generator's setpoint", %{
      snapshot: snap,
      reference: ref
    } do
      assert ref["slack_bus"] == 69
      slack = Enum.find(snap.buses, &(&1.id == 69))
      assert slack.bus_type == 3
      assert_in_delta slack.vm_pu, 1.035, 1.0e-9
    end

    test "shunt capacitor banks land on the buses that carry them", %{snapshot: snap} do
      shunt_buses = Enum.filter(snap.buses, &(&1.bs_mvar != 0.0))

      # case118 has 14 shunt buses totalling 88 MVAr and no resistive shunts.
      assert length(shunt_buses) == 14
      assert_in_delta Enum.sum(Enum.map(shunt_buses, & &1.bs_mvar)), 88.0, 1.0e-9
      assert Enum.all?(snap.buses, &(&1.gs_mw == 0.0))
    end

    test "load totals match the case", %{snapshot: snap} do
      assert length(snap.loads) == 99
      assert_in_delta Enum.sum(Enum.map(snap.loads, & &1.p_mw)), 4242.0, 1.0e-6
    end

    test "generators carry dispatched Pg, not the OPF Pmax limit", %{
      snapshot: snap,
      reference: ref
    } do
      dispatched =
        Enum.sum(Enum.map(snap.generators, &(&1.p_max_mw * &1.capacity_factor)))

      # Scheduled generation covers load plus losses; the slack absorbs the rest.
      assert_in_delta dispatched, 4377.4, 1.0e-6
      assert dispatched < ref["ac"]["total_gen_mw"] + 100.0
      assert Enum.all?(snap.generators, &(&1.capacity_factor == 1.0))
    end
  end

  # ── DC power flow ─────────────────────────────────────────────────────

  describe "DC power flow on IEEE 118-bus" do
    setup %{snapshot: snap} do
      %{solution: DCPowerFlow.solve(snap, solver_opts(snap))}
    end

    test "returns a Solution covering every bus", %{solution: sol, snapshot: snap} do
      assert %Solution{} = sol
      assert length(sol.bus_ids) == length(snap.buses)
      assert Enum.sort(sol.bus_ids) == Enum.sort(Enum.map(snap.buses, & &1.id))
    end

    test "slack bus 69 holds zero angle", %{solution: sol} do
      idx = Enum.find_index(sol.bus_ids, &(&1 == 69))
      assert Enum.at(sol.va_rad, idx) == 0.0
    end

    test "voltage angles match the reference DC solution", %{solution: sol, reference: ref} do
      {bus_id, actual, expected, dev} =
        worst_deviation(sol, sol.va_rad, ref["dc"]["buses"], &deg_to_rad(&1["va_deg"]))

      assert dev < @dc_angle_tolerance_rad,
             "worst DC angle deviation at bus #{bus_id}: got #{actual} rad, " <>
               "reference #{expected} rad (#{dev} rad off, tolerance #{@dc_angle_tolerance_rad})"
    end

    test "no NaN angles or flows", %{solution: sol} do
      for {bus_id, va} <- Enum.zip(sol.bus_ids, sol.va_rad) do
        assert va == va, "NaN angle at bus #{bus_id}"
      end

      for {key, flow} <- sol.line_flows do
        assert flow.p_flow_mw == flow.p_flow_mw, "NaN flow for #{inspect(key)}"
      end
    end

    test "a flow is reported for every in-service branch", %{solution: sol, snapshot: snap} do
      assert map_size(sol.line_flows) == length(snap.lines) + length(snap.transformers)
    end

    test "DC totals satisfy the lossless identities", %{solution: sol} do
      assert_in_delta sol.total_load_mw, 4242.0, 1.0e-6
      assert_in_delta sol.total_gen_mw, sol.total_load_mw, 1.0e-6
      assert sol.total_loss_mw == 0.0
      assert sol.slack_bus_id == 69
      assert Solution.energy_balance(sol).ok
    end
  end

  # ── AC power flow ─────────────────────────────────────────────────────

  describe "AC power flow on IEEE 118-bus" do
    @describetag :slow

    setup %{snapshot: snap} do
      {:ok, solution} = NewtonRaphson.solve(snap, solver_opts(snap))
      %{solution: solution}
    end

    test "converges", %{solution: sol} do
      assert sol.converged,
             "Newton-Raphson did not converge after #{sol.iterations} iterations " <>
               "(max mismatch #{inspect(sol.max_mismatch)})"

      assert sol.iterations <= 20, "took #{sol.iterations} iterations"
      assert sol.max_mismatch < 1.0e-6
    end

    test "voltage magnitudes are within #{@vm_tolerance_pct}% of the reference", %{
      solution: sol,
      reference: ref
    } do
      {bus_id, actual, expected, pct} = worst_vm_pct_error(sol, ref["ac"]["buses"])

      assert pct < @vm_tolerance_pct,
             "worst Vm error at bus #{bus_id}: got #{Float.round(actual, 5)} pu, " <>
               "reference #{expected} pu (#{Float.round(pct, 4)}%, " <>
               "tolerance #{@vm_tolerance_pct}%)"
    end

    test "voltage magnitudes hold the much tighter agreement actually measured", %{
      solution: sol,
      reference: ref
    } do
      # Regression guard, not a published-accuracy claim. The contract
      # tolerance above is loose enough that losing a whole modeling class
      # (the bus shunts, say) could still slip under it; this one would not.
      {bus_id, actual, expected, pct} = worst_vm_pct_error(sol, ref["ac"]["buses"])

      assert pct < @vm_regression_pct,
             "Vm agreement regressed at bus #{bus_id}: got #{Float.round(actual, 6)} pu, " <>
               "reference #{expected} pu (#{Float.round(pct, 5)}%). This case previously " <>
               "matched to 5.0e-5%; investigate before relaxing."
    end

    test "voltage angles match the reference AC solution", %{solution: sol, reference: ref} do
      {bus_id, actual, expected, dev} =
        worst_deviation(sol, sol.va_rad, ref["ac"]["buses"], &deg_to_rad(&1["va_deg"]))

      assert dev < @ac_angle_tolerance_rad,
             "worst AC angle deviation at bus #{bus_id}: got #{actual} rad, " <>
               "reference #{expected} rad (#{dev} rad off, " <>
               "tolerance #{@ac_angle_tolerance_rad})"
    end

    test "the same generators hit their Q limits as in the reference", %{
      solution: sol,
      snapshot: snap,
      reference: ref
    } do
      # A generator bus sits at its setpoint while its Q limits are slack and
      # leaves it once one binds, so "off setpoint" identifies exactly the set
      # of buses the outer Q-limit loop switched to PQ. Both tools must pick
      # the same set: 6 of the 54 generator buses here.
      #
      # This is the mechanism that diverges at scale — see
      # `PowerModel.Solver.ACTIVSg2000Test`, where the reference switches 195 of
      # 392 generator buses and this solver does not keep up. Guarding it at 118
      # buses keeps the small case honest about a real failure mode.
      setpoints = Map.new(snap.buses, &{&1.id, &1.vm_pu})
      generator_buses = MapSet.new(snap.generators, & &1.bus_id)

      off_setpoint = fn vm, bus_id -> abs(vm - Map.fetch!(setpoints, bus_id)) > 1.0e-4 end

      disagreements =
        sol.bus_ids
        |> Enum.zip(sol.vm_pu)
        |> Enum.filter(fn {bus_id, _vm} -> MapSet.member?(generator_buses, bus_id) end)
        |> Enum.reject(fn {bus_id, vm} ->
          reference_vm = Map.fetch!(ref["ac"]["buses"], Integer.to_string(bus_id))["vm_pu"]
          off_setpoint.(vm, bus_id) == off_setpoint.(reference_vm, bus_id)
        end)
        |> Enum.map(fn {bus_id, vm} ->
          {bus_id, Float.round(vm, 4), Map.fetch!(setpoints, bus_id)}
        end)

      assert disagreements == [],
             "#{length(disagreements)} generator buses disagree with the reference on " <>
               "whether a Q limit bound, as {bus, solved Vm, setpoint}: " <>
               inspect(Enum.take(disagreements, 5))

      bound =
        sol.bus_ids
        |> Enum.zip(sol.vm_pu)
        |> Enum.count(fn {bus_id, vm} ->
          MapSet.member?(generator_buses, bus_id) and off_setpoint.(vm, bus_id)
        end)

      assert bound == 6, "expected 6 generator buses on a Q limit, got #{bound}"
    end

    test "real losses are within #{@loss_tolerance_pct}% of the reference", %{
      solution: sol,
      reference: ref
    } do
      expected = ref["ac"]["total_loss_mw"]
      pct = abs(sol.total_loss_mw - expected) / expected * 100.0

      assert pct < @loss_tolerance_pct,
             "total losses #{Float.round(sol.total_loss_mw, 3)} MW vs reference " <>
               "#{expected} MW (#{Float.round(pct, 4)}%, tolerance #{@loss_tolerance_pct}%)"
    end

    test "generation and load totals match the reference", %{solution: sol, reference: ref} do
      assert_in_delta sol.total_load_mw, ref["ac"]["total_load_mw"], 0.5
      assert_in_delta sol.total_gen_mw, ref["ac"]["total_gen_mw"], 0.5
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
        assert flow.p_flow_mw == flow.p_flow_mw, "NaN P for #{inspect(key)}"
        assert flow.q_flow_mvar == flow.q_flow_mvar, "NaN Q for #{inspect(key)}"
        assert flow.s_flow_mva == flow.s_flow_mva, "NaN S for #{inspect(key)}"
      end
    end

    test "branch flows are physically consistent", %{solution: sol} do
      for {key, flow} <- sol.line_flows do
        assert flow.s_flow_mva >= 0.0, "negative apparent power for #{inspect(key)}"
        assert flow.loading_pct >= 0.0, "negative loading for #{inspect(key)}"
      end
    end

    test "case118 carries no branch ratings, so nothing reports as overloaded", %{solution: sol} do
      # Every rateA in case118 is 0, which the parser renders as an unrated
      # branch rather than a zero-capacity one.
      assert Enum.all?(sol.line_flows, fn {_key, flow} -> is_nil(flow.rating_mva) end)
      assert Solution.overloaded_lines(sol) == %{}
    end
  end

  # ── DC vs AC ──────────────────────────────────────────────────────────

  describe "DC vs AC cross-validation on IEEE 118-bus" do
    @describetag :slow

    setup %{snapshot: snap} do
      {:ok, ac} = NewtonRaphson.solve(snap, solver_opts(snap))
      %{dc: DCPowerFlow.solve(snap, solver_opts(snap)), ac: ac}
    end

    test "both solutions order buses identically", %{dc: dc, ac: ac} do
      assert dc.bus_ids == ac.bus_ids
    end

    test "DC angles track AC angles across the network", %{dc: dc, ac: ac} do
      {bus_id, dc_angle, ac_angle, dev} =
        dc.bus_ids
        |> Enum.zip(Enum.zip(dc.va_rad, ac.va_rad))
        |> Enum.map(fn {id, {d, a}} -> {id, d, a, abs(d - a)} end)
        |> Enum.max_by(fn {_id, _d, _a, dev} -> dev end)

      assert dev < 0.1,
             "DC and AC angles diverge most at bus #{bus_id}: " <>
               "DC #{Float.round(dc_angle, 4)} rad, AC #{Float.round(ac_angle, 4)} rad " <>
               "(#{Float.round(dev, 4)} rad apart)"
    end
  end
end
