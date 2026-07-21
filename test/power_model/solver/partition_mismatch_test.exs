defmodule PowerModel.Solver.PartitionMismatchTest do
  use ExUnit.Case, async: true

  alias PowerModel.Solver.{Partition, Solution}

  test "merge preserves signed mismatch and records absolute island exposure" do
    positive = Solution.new([1, 2], [1.0, 1.0], [0.0, -0.1], %{}, 100.0, mismatch_mw: 400.0)
    negative = Solution.new([3, 4], [1.0, 1.0], [0.0, 0.1], %{}, 100.0, mismatch_mw: -400.0)

    merged = Partition.merge_solutions([positive, negative], 100.0)

    assert merged.mismatch_mw == 0.0
    assert merged.mismatch_abs_mw == 800.0
  end
end
