defmodule PowerModel.Solver.SolverGuardsTest do
  @moduledoc """
  SOL-4 / SOL-10 / SOL-11 / SOL-15 / SOL-19 regression tests.

  Both pure-Elixir Gaussian fallbacks are capped so neither can grind for
  hours inside a GenServer call; the Newton-Raphson Gaussian fallback errors
  on a singular Jacobian instead of fabricating a step; every solver rejects
  snapshots with duplicate bus ids instead of silently corrupting matrix
  sizing; and none of them raises on a plain-map bus that omits an optional
  key.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Solver.{DCPowerFlow, FDPF, NewtonRaphson}

  defp bus(id, opts \\ []) do
    %{
      id: id,
      bus_type: Keyword.get(opts, :bus_type, 1),
      base_kv: 138.0,
      vm_pu: 1.0,
      va_rad: 0.0
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

  describe "SOL-4: Gaussian fallback size cap" do
    test "refuses oversize systems immediately instead of running O(n^3)" do
      assert catch_throw(DCPowerFlow.gaussian_solve([], [], 501)) ==
               {:error, {:gaussian_fallback_too_large, 501}}
    end

    test "still solves systems within the cap" do
      assert [x] = DCPowerFlow.gaussian_solve([[2.0]], [4.0], 1)
      assert_in_delta x, 2.0, 1.0e-12

      assert [x1, x2] = DCPowerFlow.gaussian_solve([[2.0, 0.0], [0.0, 4.0]], [2.0, 8.0], 2)
      assert_in_delta x1, 1.0, 1.0e-12
      assert_in_delta x2, 2.0, 1.0e-12
    end
  end

  describe "SOL-10: singular Jacobian" do
    test "NR errors on a singular Jacobian instead of zeroing free variables" do
      # Bus 2 has load but no branch at all: its Jacobian rows are all zero.
      # The old fallback silently zeroed the free variables and iterated to
      # a garbage non-converged result.
      snapshot = %{
        buses: [bus(1, bus_type: 3), bus(2)],
        lines: [],
        transformers: [],
        generators: [gen(1, 1, 100.0)],
        loads: [%{id: 1, bus_id: 2, p_mw: 10.0, q_mvar: 3.0}]
      }

      assert catch_throw(NewtonRaphson.solve(snapshot)) == {:error, :singular_matrix}
    end
  end

  describe "SOL-11: duplicate bus ids" do
    defp duplicate_snapshot do
      %{
        buses: [bus(1, bus_type: 3), bus(1), bus(2)],
        lines: [
          %{
            id: 1,
            from_bus_id: 1,
            to_bus_id: 2,
            voltage_kv: 138.0,
            r_pu: 0.01,
            x_pu: 0.1,
            b_pu: 0.0,
            rating_a_mva: 100.0
          }
        ],
        transformers: [],
        generators: [gen(1, 1, 100.0)],
        loads: [%{id: 1, bus_id: 2, p_mw: 10.0, q_mvar: 0.0}]
      }
    end

    test "DC solve raises on duplicate bus ids" do
      assert_raise ArgumentError, ~r/duplicate bus ids/, fn ->
        DCPowerFlow.solve(duplicate_snapshot())
      end
    end

    test "NR solve raises on duplicate bus ids" do
      assert_raise ArgumentError, ~r/duplicate bus ids/, fn ->
        NewtonRaphson.solve(duplicate_snapshot())
      end
    end
  end

  describe "SOL-15: Newton-Raphson Gaussian fallback size cap" do
    test "refuses oversize systems with the same error shape as SOL-4" do
      assert catch_throw(NewtonRaphson.solve_jacobian_gauss([], [], 501)) ==
               {:error, {:gaussian_fallback_too_large, 501}}
    end

    test "still solves systems within the cap" do
      x = NewtonRaphson.solve_jacobian_gauss([[2.0, 0.0], [0.0, 4.0]], [2.0, 8.0], 2)

      assert_in_delta :array.get(0, x), 1.0, 1.0e-12
      assert_in_delta :array.get(1, x), 2.0, 1.0e-12
    end
  end

  describe "SOL-19: buses that arrive as plain maps without the optional keys" do
    # Production buses are `Grid.Bus` structs and always carry `bus_type` and
    # `vm_pu`. Tests and cascade fixtures build plain maps, and a dot access on
    # a plain map without the key raises KeyError rather than defaulting. The
    # documented defaults are bus_type 1 (PQ) and vm_pu 1.0.
    defp keyless_snapshot do
      %{
        buses: [
          %{id: 1, base_kv: 138.0},
          %{id: 2, base_kv: 138.0}
        ],
        lines: [
          %{
            id: 1,
            from_bus_id: 1,
            to_bus_id: 2,
            voltage_kv: 138.0,
            r_pu: 0.01,
            x_pu: 0.1,
            b_pu: 0.0,
            rating_a_mva: 100.0
          }
        ],
        transformers: [],
        generators: [gen(1, 1, 100.0)],
        loads: [%{id: 1, bus_id: 2, p_mw: 10.0, q_mvar: 3.0}]
      }
    end

    test "NR solves a snapshot whose buses lack :bus_type and :vm_pu" do
      assert {:ok, sol} = NewtonRaphson.solve(keyless_snapshot())
      assert sol.converged
      # No bus_type=3 anywhere, so the slack came from the generator tiebreak.
      assert sol.slack_bus_id == 1
      assert_in_delta Enum.at(sol.vm_pu, 0), 1.0, 1.0e-9
    end

    test "FDPF solves the same snapshot on its own path" do
      assert {:ok, sol} = FDPF.solve(keyless_snapshot(), dense_nr_max_buses: 0)
      assert sol.converged
      assert sol.slack_bus_id == 1
    end
  end
end
