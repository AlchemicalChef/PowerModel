defmodule PowerModel.Solver.DcTieTest do
  @moduledoc """
  ROADMAP item 13: HVDC links enter the network as scheduled injections, never
  as branches. They shift flows, they never couple islands, and their power is
  a transfer rather than generation or load.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Grid.DcTie
  alias PowerModel.Solver.{DCPowerFlow, Partition, Solution}

  defp bus(id, type \\ 1), do: %{id: id, bus_type: type, base_kv: 500.0}

  defp line(id, from, to) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      voltage_kv: 500.0,
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
      capacity_factor: 1.0,
      q_max_mvar: 9999.0,
      q_min_mvar: -9999.0
    }
  end

  defp load(id, bus_id, mw), do: %{id: id, bus_id: bus_id, p_mw: mw, q_mvar: 0.0}

  defp tie(id, from, to, schedule, opts \\ []) do
    %{
      id: id,
      name: "tie-#{id}",
      from_bus_id: from,
      to_bus_id: to,
      schedule_mw: schedule,
      status: Keyword.get(opts, :status, "in_service")
    }
  end

  # Bus 1 (slack, generator) feeds bus 2 (load) over one line.
  defp two_bus(dc_ties) do
    %{
      buses: [bus(1, 3), bus(2)],
      lines: [line(1, 1, 2)],
      transformers: [],
      generators: [gen(1, 1, 100.0)],
      loads: [load(1, 2, 100.0)],
      dc_ties: dc_ties
    }
  end

  defp line_flow_mw(solution), do: solution.line_flows[{:line, 1}].p_flow_mw

  describe "injection at a single terminal" do
    test "with no ties the line carries the whole load" do
      solution = DCPowerFlow.solve(two_bus([]), base_mva: 100.0)

      assert_in_delta line_flow_mw(solution), 100.0, 1.0e-6
    end

    test "an import at the load bus displaces line flow by exactly the schedule" do
      # 40 MW delivered at bus 2 by a tie whose far end is outside the model:
      # the line only has to carry the remaining 60 MW.
      solution = DCPowerFlow.solve(two_bus([tie(1, 2, nil, 40.0)]), base_mva: 100.0)

      assert_in_delta line_flow_mw(solution), 60.0, 1.0e-6
    end

    test "an export at the load bus adds to line flow by exactly the schedule" do
      solution = DCPowerFlow.solve(two_bus([tie(1, 2, nil, -40.0)]), base_mva: 100.0)

      assert_in_delta line_flow_mw(solution), 140.0, 1.0e-6
    end

    test "the flow shift is linear in the schedule" do
      for schedule <- [0.0, 10.0, 25.0, 75.0, 100.0] do
        solution = DCPowerFlow.solve(two_bus([tie(1, 2, nil, schedule)]), base_mva: 100.0)

        assert_in_delta line_flow_mw(solution), 100.0 - schedule, 1.0e-6
      end
    end

    test "an out-of-service tie moves nothing" do
      solution =
        DCPowerFlow.solve(two_bus([tie(1, 2, nil, 40.0, status: "out_of_service")]),
          base_mva: 100.0
        )

      assert_in_delta line_flow_mw(solution), 100.0, 1.0e-6
    end

    test "a terminal outside the snapshot contributes nothing" do
      # to_bus 99 is not a bus in this snapshot: only the bus-2 end injects.
      solution = DCPowerFlow.solve(two_bus([tie(1, 2, 99, 40.0)]), base_mva: 100.0)

      assert_in_delta line_flow_mw(solution), 60.0, 1.0e-6
    end
  end

  describe "both terminals inside one island" do
    test "a tie between two in-island buses transfers power without changing totals" do
      # Bus 1 sends 40 MW to bus 2 over the tie (negative schedule at bus 1),
      # so the AC line carries 40 MW less.
      solution = DCPowerFlow.solve(two_bus([tie(1, 1, 2, -40.0)]), base_mva: 100.0)

      assert_in_delta line_flow_mw(solution), 60.0, 1.0e-6
      # Net injection into the island is zero, so the slack still covers
      # nothing beyond what the generator already scheduled.
      assert_in_delta solution.mismatch_mw, 0.0, 1.0e-6
    end

    test "a degenerate tie with both terminals on one bus injects nothing" do
      solution = DCPowerFlow.solve(two_bus([tie(1, 2, 2, 40.0)]), base_mva: 100.0)

      assert DcTie.scheduled_mw(tie(1, 2, 2, 40.0)) == 0.0
      assert_in_delta line_flow_mw(solution), 100.0, 1.0e-6
    end
  end

  describe "conservation and totals" do
    test "the lossless-DC energy balance still closes with a tie present" do
      solution = DCPowerFlow.solve(two_bus([tie(1, 2, nil, 40.0)]), base_mva: 100.0)

      assert %{ok: true} = Solution.energy_balance(solution, 1.0e-6)
      assert_in_delta solution.total_gen_mw, solution.total_load_mw, 1.0e-9
    end

    test "the served load is unchanged: a tie is a transfer, not demand" do
      with_tie = DCPowerFlow.solve(two_bus([tie(1, 2, nil, 40.0)]), base_mva: 100.0)
      without = DCPowerFlow.solve(two_bus([]), base_mva: 100.0)

      assert_in_delta with_tie.total_load_mw, without.total_load_mw, 1.0e-9
    end

    test "scheduled generation stays pure: the tie is not counted as a generator" do
      solution = DCPowerFlow.solve(two_bus([tie(1, 2, nil, 40.0)]), base_mva: 100.0)

      assert_in_delta solution.scheduled_gen_mw, 100.0, 1.0e-9
    end

    test "mismatch_mw reports the slack gap after ties are counted" do
      # Load 100, generators 100, tie brings in 40 -> the slack must back off
      # 40 MW, and that is what mismatch reports.
      solution = DCPowerFlow.solve(two_bus([tie(1, 2, nil, 40.0)]), base_mva: 100.0)

      assert_in_delta solution.mismatch_mw, -40.0, 1.0e-6
    end

    test "the slack-balance audit holds: injection equals net outgoing flow" do
      # An import at the SLACK bus is the case most likely to break the audit,
      # since the slack's injection is derived rather than scheduled.
      solution = DCPowerFlow.solve(two_bus([tie(1, 1, nil, 40.0)]), base_mva: 100.0)

      assert_in_delta solution.slack_injection_mw, line_flow_mw(solution), 1.0e-6
      assert_in_delta solution.slack_injection_mw, 100.0, 1.0e-6
    end
  end

  describe "islands" do
    # Two electrically separate systems, each one generator and one load,
    # joined ONLY by a DC tie: 1-2 and 3-4.
    defp two_islands(schedule) do
      %{
        buses: [bus(1, 3), bus(2), bus(3, 3), bus(4)],
        lines: [line(1, 1, 2), line(2, 3, 4)],
        transformers: [],
        generators: [gen(1, 1, 100.0), gen(2, 3, 100.0)],
        loads: [load(1, 2, 100.0), load(2, 4, 100.0)],
        # Island B (bus 4) receives; island A (bus 2) sends.
        dc_ties: [tie(1, 4, 2, schedule)]
      }
    end

    test "a tie never fuses two islands into one" do
      {subs, _dead} = Partition.split(two_islands(30.0))

      assert length(subs) == 2
      assert Enum.map(subs, &length(&1.buses)) == [2, 2]
    end

    test "each island keeps only its own end of a cross-island tie" do
      {subs, _dead} = Partition.split(two_islands(30.0))

      # Both islands carry the tie (they each hold one terminal)...
      assert Enum.all?(subs, &(length(&1.dc_ties) == 1))

      # ...but the net injection each one sees is only its own end.
      nets =
        Enum.map(subs, fn sub ->
          sub.dc_ties |> DcTie.net_injection_mw(MapSet.new(sub.buses, & &1.id)) |> Float.round(6)
        end)

      assert Enum.sort(nets) == [-30.0, 30.0]
    end

    test "a cross-island tie shifts flow in both islands, in opposite directions" do
      solution = DCPowerFlow.solve_islands(two_islands(30.0), base_mva: 100.0)

      # Island A (bus 2) exports 30 MW, so its line carries 130 MW.
      assert_in_delta solution.line_flows[{:line, 1}].p_flow_mw, 130.0, 1.0e-6
      # Island B (bus 4) imports 30 MW, so its line carries only 70 MW.
      assert_in_delta solution.line_flows[{:line, 2}].p_flow_mw, 70.0, 1.0e-6
    end

    test "both islands still solve, and the merged balance closes" do
      solution = DCPowerFlow.solve_islands(two_islands(30.0), base_mva: 100.0)

      assert solution.converged
      assert solution.n_islands_solved == 2
      assert %{ok: true} = Solution.energy_balance(solution, 1.0e-6)
      assert_in_delta solution.total_load_mw, 200.0, 1.0e-9
    end

    test "a tie whose terminals are both outside a snapshot is inert" do
      snapshot = %{two_bus([]) | dc_ties: [tie(1, 77, 88, 500.0)]}
      solution = DCPowerFlow.solve(snapshot, base_mva: 100.0)

      assert_in_delta line_flow_mw(solution), 100.0, 1.0e-6
      assert %{ok: true} = Solution.energy_balance(solution, 1.0e-6)
    end
  end

  describe "snapshots without a :dc_ties key" do
    test "solve and split both work on a tie-less snapshot map" do
      snapshot = Map.delete(two_bus([]), :dc_ties)

      solution = DCPowerFlow.solve(snapshot, base_mva: 100.0)
      assert_in_delta line_flow_mw(solution), 100.0, 1.0e-6

      {subs, _dead} = Partition.split(snapshot)
      assert [%{dc_ties: []}] = subs
    end
  end
end
