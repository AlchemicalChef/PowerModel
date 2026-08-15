defmodule PowerModel.Failure.CascadeDcTieTest do
  @moduledoc """
  ROADMAP item 13 inside the cascade: a DC-tie import serves load in the
  island power balance, contributes no inertia, and never appears in the
  consumption conservation identity.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Failure.Cascade

  defp bus(id, type \\ 1), do: %{id: id, bus_type: type, base_kv: 345.0}

  defp line(id, from, to) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      voltage_kv: 345.0,
      r_pu: 0.0,
      x_pu: 0.1,
      b_pu: 0.0,
      rating_a_mva: 5000.0
    }
  end

  defp gen(id, bus_id, mw) do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: mw,
      p_nameplate_mw: mw,
      capacity_factor: 1.0,
      fuel_type: "natural_gas",
      prime_mover: "CT",
      q_max_mvar: 9999.0,
      q_min_mvar: -9999.0
    }
  end

  defp tie(id, from, to, schedule) do
    %{
      id: id,
      name: "tie-#{id}",
      from_bus_id: from,
      to_bus_id: to,
      schedule_mw: schedule,
      status: "in_service"
    }
  end

  # 60 MW of local generation against 100 MW of load: 40 MW short unless a
  # tie makes up the difference.
  defp deficient_island(dc_ties) do
    %{
      buses: [bus(1, 3), bus(2)],
      lines: [line(1, 1, 2)],
      transformers: [],
      generators: [gen(1, 1, 60.0)],
      loads: [%{id: 1, bus_id: 2, p_mw: 100.0, q_mvar: 0.0}],
      dc_ties: dc_ties
    }
  end

  defp run(snapshot) do
    state = Cascade.init(snapshot, 100.0)
    {final, _steps} = Cascade.run_cascade(state)
    {final, Cascade.balance(final)}
  end

  describe "a tie import closes an island's generation deficit" do
    test "without the tie, the island sheds load" do
      {_final, balance} = run(deficient_island([]))

      assert balance.shed_load_mw > 0.0
      assert balance.served_load_mw < 100.0
    end

    test "with a 40 MW import the island is balanced and sheds nothing" do
      {_final, balance} = run(deficient_island([tie(1, 2, nil, 40.0)]))

      assert balance.shed_load_mw == 0.0
      assert_in_delta balance.served_load_mw, 100.0, 1.0e-6
    end

    test "a tie EXPORT deepens the deficit rather than relieving it" do
      shed_with_export =
        deficient_island([tie(1, 2, nil, -20.0)]) |> run() |> elem(1) |> Map.fetch!(:shed_load_mw)

      shed_without =
        deficient_island([]) |> run() |> elem(1) |> Map.fetch!(:shed_load_mw)

      assert shed_with_export > shed_without
    end
  end

  describe "conservation" do
    test "served + shed + blackout still equals the original load, with ties present" do
      for ties <- [[], [tie(1, 2, nil, 40.0)], [tie(1, 2, nil, -20.0)]] do
        {_final, b} = run(deficient_island(ties))

        assert_in_delta b.served_load_mw + b.shed_load_mw + b.blackout_load_mw,
                        b.original_load_mw,
                        1.0e-6
      end
    end

    test "a tie adds nothing to served load: an imported MW shows up as the load it serves" do
      {_final, with_tie} = run(deficient_island([tie(1, 2, nil, 40.0)]))

      assert_in_delta with_tie.served_load_mw, 100.0, 1.0e-6
      assert_in_delta with_tie.original_load_mw, 100.0, 1.0e-6
    end
  end

  describe "a tie on a blacked-out island contributes nothing" do
    test "an island with no generation stays dead however large the import" do
      # A converter cannot run without an AC source to commutate against, so a
      # generation-less island blacks out and its tie moves nothing.
      snapshot = %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2)],
        transformers: [],
        generators: [],
        loads: [%{id: 1, bus_id: 2, p_mw: 100.0, q_mvar: 0.0}],
        dc_ties: [tie(1, 2, nil, 5000.0)]
      }

      {_final, balance} = run(snapshot)

      assert_in_delta balance.blackout_load_mw, 100.0, 1.0e-6
      assert balance.served_load_mw == 0.0
    end
  end

  describe "cross-island ties" do
    test "a tie between two islands does not merge them, and each sees its own end" do
      snapshot = %{
        buses: [bus(1, 3), bus(2), bus(3, 3), bus(4)],
        lines: [line(1, 1, 2), line(2, 3, 4)],
        transformers: [],
        generators: [gen(1, 1, 60.0), gen(2, 3, 200.0)],
        loads: [
          %{id: 1, bus_id: 2, p_mw: 100.0, q_mvar: 0.0},
          %{id: 2, bus_id: 4, p_mw: 100.0, q_mvar: 0.0}
        ],
        # Island A (buses 1-2) is 40 MW short; island B (buses 3-4) has
        # headroom and sends it 40 MW over the tie.
        dc_ties: [tie(1, 2, 4, 40.0)]
      }

      {_final, balance} = run(snapshot)

      # The short island is made whole and neither island sheds.
      assert balance.shed_load_mw == 0.0
      assert_in_delta balance.served_load_mw, 200.0, 1.0e-6
    end
  end
end
