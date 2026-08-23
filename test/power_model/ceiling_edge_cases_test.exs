defmodule PowerModel.CeilingEdgeCasesTest do
  @moduledoc """
  The voltage/size ceiling tables all answer a lookup with `Enum.find/2` over a
  descending band list. Two edge cases bit in review 2026-08-23:

    * `nil >= 500.0` is TRUE in Elixir — atoms sort above numbers — so a bus
      with no voltage got the MOST permissive ceiling and became the single
      most attractive load and datacenter target in the network;
    * a value below every band made `Enum.find/2` return nil, so a documented
      public function raised an opaque `MatchError` instead of answering.

  Both now answer conservatively. These tests exist because the failure is
  silent in the first case and unhelpful in the second, and because
  `ParameterEstimator.cap_class_ceiling/1` already got this right — the bug was
  two implementations of one idea disagreeing.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Ingestion.{DatacenterPlacement, LoadEstimator, ParameterEstimator}

  test "the term-ordering trap is real, so the guards are load-bearing" do
    # Through a variable, or the compiler folds the comparison and warns.
    missing = Enum.random([nil])
    assert missing >= 500.0, "if this ever becomes false, these guards can be simplified"
  end

  describe "LoadEstimator.class_ceiling/1" do
    test "a voltage-less bus gets the LOWEST ceiling, not the highest" do
      lowest = LoadEstimator.class_ceiling(1.0)
      assert LoadEstimator.class_ceiling(nil) == lowest
      refute LoadEstimator.class_ceiling(nil) == LoadEstimator.class_ceiling(765.0)
    end

    test "non-positive and non-numeric input answers rather than raising" do
      lowest = LoadEstimator.class_ceiling(1.0)
      assert LoadEstimator.class_ceiling(0.0) == lowest
      assert LoadEstimator.class_ceiling(-5.0) == lowest
      assert LoadEstimator.class_ceiling(:unknown) == lowest
    end

    test "real voltages still rise with class" do
      assert LoadEstimator.class_ceiling(69.0) < LoadEstimator.class_ceiling(138.0)
      assert LoadEstimator.class_ceiling(138.0) < LoadEstimator.class_ceiling(345.0)
      assert LoadEstimator.class_ceiling(345.0) < LoadEstimator.class_ceiling(500.0)
    end

    test "agrees with its sibling on the no-voltage case" do
      # cap_class_ceiling is MVAr and class_ceiling is MW, so the values differ;
      # what must agree is the DIRECTION of the fallback.
      assert ParameterEstimator.cap_class_ceiling(nil) ==
               ParameterEstimator.cap_class_ceilings() |> Map.values() |> Enum.min()

      assert LoadEstimator.class_ceiling(nil) == LoadEstimator.class_ceiling(1.0)
    end
  end

  describe "DatacenterPlacement.interconnection_floor_kv/1" do
    test "a zero-MW campus answers rather than raising" do
      assert is_number(DatacenterPlacement.interconnection_floor_kv(0.0))
      assert is_number(DatacenterPlacement.interconnection_floor_kv(-1.0))
    end

    test "the floor rises with campus size" do
      assert DatacenterPlacement.interconnection_floor_kv(10.0) <=
               DatacenterPlacement.interconnection_floor_kv(500.0)
    end
  end
end
