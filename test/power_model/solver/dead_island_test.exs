defmodule PowerModel.Solver.DeadIslandTest do
  @moduledoc """
  SOL-1 / SOL-2 / SOL-3 regression tests.

  A total blackout must never report `converged: true`; load in dead
  (generation-less) islands must surface on the merged solution instead of
  vanishing; and single-bus islands with generation are trivially solvable
  and must be solved, not discarded.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Solver.{DCPowerFlow, Partition, Solution}

  defp bus(id, opts \\ []) do
    %{
      id: id,
      bus_type: Keyword.get(opts, :bus_type, 1),
      base_kv: 138.0,
      vm_pu: 1.0,
      va_rad: 0.0
    }
  end

  defp line(id, from, to) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      voltage_kv: 138.0,
      r_pu: 0.01,
      x_pu: 0.1,
      b_pu: 0.02,
      rating_a_mva: 500.0
    }
  end

  defp gen(id, bus_id, p) do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: p,
      capacity_factor: 1.0,
      q_max_mvar: 50.0,
      q_min_mvar: -50.0
    }
  end

  defp load(id, bus_id, p), do: %{id: id, bus_id: bus_id, p_mw: p, q_mvar: 0.0}

  describe "SOL-1: total blackout" do
    test "all-dead snapshot is not a converged solve and carries the dead load" do
      snapshot = %{
        buses: [bus(1), bus(2), bus(3)],
        lines: [line(1, 1, 2), line(2, 2, 3)],
        transformers: [],
        generators: [],
        loads: [load(1, 2, 60.0), load(2, 3, 40.0)]
      }

      solution = DCPowerFlow.solve_islands(snapshot)

      refute solution.converged
      assert solution.n_islands_solved == 0
      assert solution.total_load_mw == 0.0
      assert_in_delta solution.dead_load_mw, 100.0, 1.0e-9
      assert solution.dead_bus_count == 3
    end

    test "merge_solutions of zero islands yields converged: false" do
      merged = Partition.merge_solutions([], 100.0)

      refute merged.converged
      assert merged.n_islands_solved == 0
    end
  end

  describe "SOL-1/SOL-2: mixed live and dead islands" do
    defp mixed_snapshot do
      %{
        buses: [bus(1, bus_type: 3), bus(2), bus(10), bus(11)],
        lines: [line(1, 1, 2), line(2, 10, 11)],
        transformers: [],
        generators: [gen(1, 1, 100.0)],
        loads: [load(1, 2, 60.0), load(2, 11, 40.0)]
      }
    end

    test "dead-island load surfaces instead of vanishing from the totals" do
      solution = DCPowerFlow.solve_islands(mixed_snapshot())

      assert solution.converged
      assert solution.n_islands_solved == 1
      assert_in_delta solution.total_load_mw, 60.0, 1.0e-6
      assert_in_delta solution.dead_load_mw, 40.0, 1.0e-6
      assert solution.dead_bus_count == 2
    end

    test "energy_balance vs snapshot demand passes only when dead load is accounted" do
      solution = DCPowerFlow.solve_islands(mixed_snapshot())

      # served (60 MW) + dead (40 MW) accounts for the snapshot's 100 MW demand
      assert %{ok: true, load_residual_mw: residual} =
               Solution.energy_balance(solution, 1.0, 100.0)

      assert_in_delta residual, 0.0, 1.0e-6

      # a solution whose dead load vanished (the old behavior) must fail
      vanished = %{solution | dead_load_mw: 0.0}
      assert %{ok: false} = Solution.energy_balance(vanished, 1.0, 100.0)
    end

    test "energy_balance without expected load keeps its original contract" do
      solution = DCPowerFlow.solve_islands(mixed_snapshot())

      assert %{ok: true, residual_mw: residual} = Solution.energy_balance(solution)
      assert_in_delta residual, 0.0, 1.0e-6
    end
  end

  describe "SOL-3: single-bus islands with generation" do
    test "a one-bus island with gen and load is solved, not discarded" do
      snapshot = %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3)],
        lines: [line(1, 1, 2)],
        transformers: [],
        generators: [gen(1, 1, 100.0), gen(2, 3, 50.0)],
        loads: [load(1, 2, 60.0), load(2, 3, 20.0)]
      }

      solution = DCPowerFlow.solve_islands(snapshot)

      assert solution.converged
      assert solution.n_islands_solved == 2
      # the isolated bus 3 (gen 50 / load 20) is part of the solve
      assert 3 in solution.bus_ids
      assert_in_delta solution.total_load_mw, 80.0, 1.0e-6
      assert solution.dead_bus_count == 0
      assert solution.dead_load_mw == 0.0
    end
  end
end
