defmodule PowerModel.Solver.DCTotalsTest do
  @moduledoc """
  Hand-checkable consumption and overflow accounting tests for the DC solver.

  Uses a 3-bus chain: Bus 1 (slack/gen) --line1-- Bus 2 (load) --line2-- Bus 3 (load)
  so every total can be verified by inspection.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Solver.{DCPowerFlow, Solution}

  defp bus(id, opts \\ []) do
    %{
      id: id,
      bus_type: Keyword.get(opts, :bus_type, 1),
      base_kv: 138.0,
      vm_pu: 1.0,
      va_rad: 0.0
    }
  end

  defp line(id, from, to, opts) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      voltage_kv: 138.0,
      r_pu: 0.01,
      x_pu: Keyword.get(opts, :x_pu, 0.1),
      b_pu: 0.02,
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 100.0)
    }
  end

  defp transformer(id, from, to, opts) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      r_pu: 0.005,
      x_pu: Keyword.get(opts, :x_pu, 0.05),
      rated_mva: Keyword.get(opts, :rated_mva, 200.0),
      tap_ratio: 1.0
    }
  end

  defp generator(id, bus_id, opts) do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      capacity_factor: Keyword.get(opts, :capacity_factor, 1.0),
      q_max_mvar: 50.0,
      q_min_mvar: -50.0
    }
  end

  defp load(id, bus_id, p_mw) do
    %{id: id, bus_id: bus_id, p_mw: p_mw, q_mvar: p_mw * 0.3}
  end

  defp three_bus_snapshot(opts \\ []) do
    gen_p_max = Keyword.get(opts, :gen_p_max, 100.0)
    rating = Keyword.get(opts, :rating_a_mva, 100.0)

    %{
      buses: [bus(1, bus_type: 3), bus(2), bus(3)],
      lines: [
        line(1, 1, 2, rating_a_mva: rating),
        line(2, 2, 3, rating_a_mva: rating)
      ],
      transformers: [],
      generators: [generator(1, 1, p_max_mw: gen_p_max)],
      loads: [load(1, 2, 60.0), load(2, 3, 40.0)]
    }
  end

  describe "DC solution totals" do
    test "balanced case: gen == load, zero mismatch, slack carries all load" do
      solution = DCPowerFlow.solve(three_bus_snapshot())

      assert_in_delta solution.total_load_mw, 100.0, 1.0e-6
      assert_in_delta solution.total_gen_mw, 100.0, 1.0e-6
      assert solution.total_loss_mw == 0.0
      assert_in_delta solution.scheduled_gen_mw, 100.0, 1.0e-6
      assert_in_delta solution.mismatch_mw, 0.0, 1.0e-6
      # All generation is at the slack bus, all load elsewhere
      assert solution.slack_bus_id == 1
      assert_in_delta solution.slack_injection_mw, 100.0, 1.0e-6
      assert Solution.energy_balance(solution).ok
    end

    test "under-scheduled case: slack pickup is visible as mismatch" do
      solution = DCPowerFlow.solve(three_bus_snapshot(gen_p_max: 80.0))

      # Load is served regardless (slack absorbs the gap) -- but now we see it
      assert_in_delta solution.total_gen_mw, 100.0, 1.0e-6
      assert_in_delta solution.total_load_mw, 100.0, 1.0e-6
      assert_in_delta solution.scheduled_gen_mw, 80.0, 1.0e-6
      assert_in_delta solution.mismatch_mw, 20.0, 1.0e-6
      assert Solution.energy_balance(solution).ok
    end

    test "line flows carry the physics: 100 MW into bus 2, 40 MW onward to bus 3" do
      solution = DCPowerFlow.solve(three_bus_snapshot())

      flow1 = Solution.line_flow(solution, :line, 1)
      flow2 = Solution.line_flow(solution, :line, 2)

      assert_in_delta flow1.p_flow_mw, 100.0, 1.0e-6
      assert_in_delta flow2.p_flow_mw, 40.0, 1.0e-6
      assert flow1.rating_mva == 100.0
      assert flow2.rating_mva == 100.0
    end
  end

  describe "overload_summary/1" do
    test "overloaded line is counted with severity in MW above rating" do
      # Rating 50: line 1 carries 100 MW (200%), line 2 carries 40 MW (80%)
      solution = DCPowerFlow.solve(three_bus_snapshot(rating_a_mva: 50.0))

      summary = Solution.overload_summary(solution)

      assert summary.overloaded_count == 1
      assert_in_delta summary.max_loading_pct, 200.0, 1.0e-6
      assert_in_delta summary.overload_mw, 50.0, 1.0e-6
      assert summary.monitored_count == 2
      assert summary.unrated_count == 0
    end

    test "unrated line is disclosed, not silently healthy" do
      snapshot = three_bus_snapshot()
      [l1, l2] = snapshot.lines
      snapshot = %{snapshot | lines: [%{l1 | rating_a_mva: nil}, l2]}

      solution = DCPowerFlow.solve(snapshot)
      summary = Solution.overload_summary(solution)

      # Line 1 carries 100 MW with no rating: it must NOT count as monitored
      assert summary.unrated_count == 1
      assert summary.monitored_count == 1
      assert summary.overloaded_count == 0

      flow1 = Solution.line_flow(solution, :line, 1)
      assert flow1.rating_mva == nil
      refute flow1.overloaded
    end

    test "transformer with nil rated_mva does not crash the solve" do
      snapshot = three_bus_snapshot()

      snapshot = %{
        snapshot
        | buses: snapshot.buses ++ [bus(4)],
          transformers: [transformer(1, 3, 4, rated_mva: nil)],
          loads: snapshot.loads ++ [load(3, 4, 10.0)]
      }

      solution = DCPowerFlow.solve(snapshot)

      xf = Solution.line_flow(solution, :transformer, 1)
      assert_in_delta xf.p_flow_mw, 10.0, 1.0e-6
      assert xf.rating_mva == nil
      refute xf.overloaded
      assert xf.loading_pct == 0.0

      assert Solution.overload_summary(solution).unrated_count == 1
    end
  end

  describe "energy_balance/2" do
    test "flags a fabricated imbalance" do
      solution = DCPowerFlow.solve(three_bus_snapshot())
      broken = %{solution | total_gen_mw: solution.total_gen_mw + 10.0}

      assert %{ok: false, residual_mw: residual} = Solution.energy_balance(broken)
      assert_in_delta residual, 10.0, 1.0e-6
    end
  end
end
