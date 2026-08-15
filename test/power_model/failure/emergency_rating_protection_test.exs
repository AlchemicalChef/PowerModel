defmodule PowerModel.Failure.EmergencyRatingProtectionTest do
  @moduledoc """
  ROADMAP item 9: protection picks up on the short-time emergency rating
  (rate C), not the normal rating (rate A).
  """
  use ExUnit.Case, async: true

  alias PowerModel.Failure.Cascade
  alias PowerModel.Grid.Ratings
  alias PowerModel.Solver.DCPowerFlow

  defp bus(id, bus_type) do
    %{id: id, bus_type: bus_type, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0}
  end

  # A two-bus system where the single line must carry `flow_mw` from the
  # generator at bus 1 to the load at bus 2, against a rate A of `rating_a`.
  defp snapshot(flow_mw, rating_a) do
    %{
      buses: [bus(1, 3), bus(2, 1)],
      lines: [
        %{
          id: 1,
          from_bus_id: 1,
          to_bus_id: 2,
          voltage_kv: 138.0,
          r_pu: 0.0,
          x_pu: 0.1,
          b_pu: 0.0,
          rating_a_mva: rating_a
        }
      ],
      transformers: [],
      generators: [
        %{
          id: 1,
          bus_id: 1,
          p_max_mw: flow_mw,
          capacity_factor: 1.0,
          q_max_mvar: 500.0,
          q_min_mvar: -500.0
        }
      ],
      loads: [%{id: 1, bus_id: 2, p_mw: flow_mw, q_mvar: 0.0}]
    }
  end

  describe "trip_loading_pct/1" do
    test "uses the solver's rate-C loading when the flow map carries it" do
      assert Cascade.trip_loading_pct(%{trip_loading_pct: 142.0, loading_pct: 191.7}) == 142.0
    end

    test "converts exactly from rate-A loading for a flow map without the tiers" do
      # Rate C is a fixed multiple of rate A, so the fallback is exact rather
      # than approximate: 135% of rate A is exactly 100% of rate C.
      pct = 100.0 * Ratings.rate_c_factor()

      assert_in_delta Cascade.trip_loading_pct(%{loading_pct: pct}), 100.0, 1.0e-9
    end

    test "treats a flow map with no loading information as unloaded" do
      assert Cascade.trip_loading_pct(%{}) == 0.0
    end
  end

  describe "solver flow maps" do
    test "carry all three rating tiers and the loading against each" do
      solution = DCPowerFlow.solve(snapshot(100.0, 100.0), base_mva: 100.0)
      flow = solution.line_flows[{:line, 1}]

      assert_in_delta flow.rating_mva, 100.0, 1.0e-9
      assert_in_delta flow.rating_b_mva, 100.0 * Ratings.rate_b_factor(), 1.0e-9
      assert_in_delta flow.rating_c_mva, 100.0 * Ratings.rate_c_factor(), 1.0e-9

      assert_in_delta flow.loading_pct, 100.0, 1.0e-6
      assert_in_delta flow.emergency_loading_pct, 100.0 / Ratings.rate_b_factor(), 1.0e-6
      assert_in_delta flow.trip_loading_pct, 100.0 / Ratings.rate_c_factor(), 1.0e-6
    end

    test "an unrated branch still reports zero loading rather than crashing" do
      solution = DCPowerFlow.solve(snapshot(100.0, nil), base_mva: 100.0)
      flow = solution.line_flows[{:line, 1}]

      assert flow.rating_mva == nil
      assert flow.loading_pct == 0.0
      assert flow.trip_loading_pct == 0.0
      refute flow.overloaded
    end
  end

  describe "base_overloaded is built on the relay pickup basis" do
    test "a branch over rate A but under rate C stays eligible to trip" do
      # 120% of rate A is only ~89% of rate C: a dispatch condition, not a
      # breaker operation. Masking it here would make the branch permanently
      # immune to cascade tripping, which is exactly the defect this fixes.
      state = Cascade.init(snapshot(120.0, 100.0), 100.0)

      assert Cascade.trip_loading_pct(state.base_line_loading |> loading_of()) < 100.0
      refute MapSet.member?(state.base_overloaded, {:line, 1})
    end

    test "a branch already past rate C before anything happens is masked" do
      # 200% of rate A is ~148% of rate C: this branch would trip at t=0 on
      # model error alone, so it is excluded from cascade trip consideration.
      state = Cascade.init(snapshot(200.0, 100.0), 100.0)

      assert MapSet.member?(state.base_overloaded, {:line, 1})
    end

    test "the display loading stays on rate A" do
      state = Cascade.init(snapshot(120.0, 100.0), 100.0)

      assert_in_delta Map.fetch!(state.base_line_loading, {:line, 1}), 120.0, 1.0e-6
    end
  end

  # base_line_loading is keyed on rate A; rebuild the shape trip_loading_pct/1
  # consumes so the fallback path is exercised against a real solve.
  defp loading_of(base_line_loading) do
    %{loading_pct: Map.fetch!(base_line_loading, {:line, 1})}
  end
end
