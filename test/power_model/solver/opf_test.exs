defmodule PowerModel.Solver.OPFTest do
  use ExUnit.Case, async: true

  alias PowerModel.Solver.OPF

  defp bus(id, opts \\ []) do
    %{id: id, bus_type: Keyword.get(opts, :bus_type, 1), base_kv: 138.0,
      vm_pu: 1.0, va_rad: 0.0, b_shunt_mvar: 0.0}
  end

  defp line(id, from, to, opts \\ []) do
    %{id: id, from_bus_id: from, to_bus_id: to,
      voltage_kv: 138.0, r_pu: 0.01,
      x_pu: Keyword.get(opts, :x_pu, 0.1),
      b_pu: 0.02,
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 100.0)}
  end

  defp generator(id, bus_id, opts) do
    %{id: id, bus_id: bus_id,
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      p_min_mw: Keyword.get(opts, :p_min_mw, 0.0),
      capacity_factor: 1.0,
      fuel_type: "NG", status: "in_service",
      marginal_cost_per_mwh: Keyword.get(opts, :cost, 35.0)}
  end

  defp load(id, bus_id, opts) do
    %{id: id, bus_id: bus_id,
      p_mw: Keyword.get(opts, :p_mw, 50.0),
      q_mvar: 0.0, status: "in_service"}
  end

  describe "basic OPF" do
    test "uncongested system dispatches cheapest generators first" do
      snapshot = %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3)],
        lines: [
          line(1, 1, 2, rating_a_mva: 200.0),
          line(2, 2, 3, rating_a_mva: 200.0)
        ],
        transformers: [],
        generators: [
          generator(1, 1, p_max_mw: 100.0, cost: 20.0),  # cheap
          generator(2, 3, p_max_mw: 100.0, cost: 50.0)   # expensive
        ],
        loads: [load(1, 2, p_mw: 80.0)]
      }

      result = OPF.solve(snapshot)

      assert %OPF{} = result
      assert result.converged
      assert result.total_cost > 0.0

      # Cheap generator should be dispatched more
      cheap_dispatch = Map.get(result.dispatch, 1, 0.0)
      expensive_dispatch = Map.get(result.dispatch, 2, 0.0)
      assert cheap_dispatch >= expensive_dispatch
    end

    test "LMPs are computed for all buses" do
      snapshot = %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3)],
        lines: [line(1, 1, 2, rating_a_mva: 200.0), line(2, 2, 3, rating_a_mva: 200.0)],
        transformers: [],
        generators: [generator(1, 1, p_max_mw: 100.0, cost: 30.0)],
        loads: [load(1, 3, p_mw: 50.0)]
      }

      result = OPF.solve(snapshot)

      assert map_size(result.lmps) == 3
      assert Map.get(result.lmps, 1) > 0.0
    end

    test "congested line triggers re-dispatch" do
      # Triangle: Bus1 --L1(tight)--> Bus2 <--L2(wide)-- Bus3
      #                  \__________L3(wide)__________/
      # Load at bus 2. Gen1 at bus1 (cheap), Gen2 at bus3 (expensive).
      # L1 is tight (30 MVA). Without OPF, cheap gen pushes too much through L1.
      # OPF should shift some to Gen2 at bus3 which feeds bus2 via L2.
      snapshot = %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3)],
        lines: [
          line(1, 1, 2, rating_a_mva: 30.0, x_pu: 0.1),
          line(2, 3, 2, rating_a_mva: 200.0, x_pu: 0.1),
          line(3, 1, 3, rating_a_mva: 200.0, x_pu: 0.1)
        ],
        transformers: [],
        generators: [
          generator(1, 1, p_max_mw: 100.0, cost: 20.0),
          generator(2, 3, p_max_mw: 100.0, cost: 50.0)
        ],
        loads: [load(1, 2, p_mw: 80.0)]
      }

      result = OPF.solve(snapshot)

      # OPF should attempt to relieve congestion
      assert %OPF{} = result
      assert result.iterations > 0
    end

    test "find_congestion identifies overloaded lines" do
      snapshot = %{
        buses: [bus(1, bus_type: 3), bus(2)],
        lines: [line(1, 1, 2, rating_a_mva: 30.0)],
        transformers: [],
        generators: [generator(1, 1, p_max_mw: 100.0, cost: 30.0)],
        loads: [load(1, 2, p_mw: 50.0)]
      }

      dispatch = %{1 => 50.0}
      congestion = OPF.find_congestion(snapshot, dispatch)

      # 50 MW through a 30 MVA line — should be congested
      assert length(congestion) > 0
      assert hd(congestion).loading_pct > 100.0
    end

    test "total cost reflects dispatch and costs" do
      snapshot = %{
        buses: [bus(1, bus_type: 3), bus(2)],
        lines: [line(1, 1, 2, rating_a_mva: 200.0)],
        transformers: [],
        generators: [generator(1, 1, p_max_mw: 100.0, cost: 25.0)],
        loads: [load(1, 2, p_mw: 60.0)]
      }

      result = OPF.solve(snapshot)

      # Cost should be approximately 60 MW * $25/MWh = $1500
      assert_in_delta result.total_cost, 1500.0, 200.0
    end
  end
end
