defmodule PowerModel.Solver.LODFTest do
  @moduledoc """
  Covers ROADMAP item 21's engine half: line outage distribution factors on the
  cached LDL^T factorization.

  The claim being tested is a strong one — that an LODF flow update is not an
  approximation of a DC re-solve but *the same answer* — so the tests are built
  to fail if it is off by anything above floating-point noise:

    * a three-bus ring whose LODFs are exactly 1 and -1 by symmetry, so the
      arithmetic is checked against a number derived by hand rather than
      against the code's own output;
    * meshed networks where every single-branch outage is compared against
      `DCPowerFlow.solve/2` on the snapshot with that branch actually deleted,
      and the same for simultaneous pairs (N-2), which is where a sequential
      compounding implementation would visibly drift;
    * bridges, where no flow update exists at all and the honest answer is a
      refusal carrying the size of the split;
    * the convention guard, which is the thing standing between this module and
      the failure mode that motivated it — a B' assembled a little differently
      from the DC solver's, producing screening results that quietly disagree
      with solved flows.
  """

  use ExUnit.Case, async: true

  alias PowerModel.Solver.{DCPowerFlow, LODF}

  @base_mva 100.0

  defp bus(id, type \\ 1), do: %{id: id, bus_type: type, base_kv: 230.0}

  defp line(id, from, to, x_pu, rating \\ 1_000.0) do
    %{id: id, from_bus_id: from, to_bus_id: to, x_pu: x_pu, rating_a_mva: rating}
  end

  defp gen(id, bus_id, p_max_mw),
    do: %{id: id, bus_id: bus_id, p_max_mw: p_max_mw, capacity_factor: 1.0}

  defp load(id, bus_id, p_mw), do: %{id: id, bus_id: bus_id, p_mw: p_mw}

  defp snapshot(buses, lines, gens, loads, xfmrs \\ []) do
    %{
      buses: buses,
      lines: lines,
      transformers: xfmrs,
      generators: gens,
      loads: loads,
      dc_ties: []
    }
  end

  defp init!(snap) do
    solution = DCPowerFlow.solve(snap, base_mva: @base_mva)
    {:ok, lodf} = LODF.init(snap, solution, base_mva: @base_mva)
    {lodf, solution}
  end

  defp flow(flows, key), do: Map.fetch!(flows, key).p_flow_mw

  # Re-solve with `keys` genuinely removed from the snapshot: the reference
  # every LODF result is measured against.
  defp resolve_without(snap, keys) do
    dropped = MapSet.new(keys)

    %{
      snap
      | lines: Enum.reject(snap.lines, &MapSet.member?(dropped, {:line, &1.id})),
        transformers:
          Enum.reject(snap.transformers, &MapSet.member?(dropped, {:transformer, &1.id}))
    }
    |> DCPowerFlow.solve(base_mva: @base_mva)
  end

  # ---------------------------------------------------------------------------
  # A ring of three identical lines
  #
  #        1 (slack, 30 MW gen)
  #       / \
  #   0.1/   \0.1
  #     /     \
  #    2 ------ 3
  #  (30 MW)  0.1
  #
  # With every reactance equal, opening 1-2 forces all of its flow around
  # 1-3-2, so LODF[1-3, 1-2] = +1 and LODF[2-3, 1-2] = -1 exactly, and
  # 1 - PTDF[1-2, 1-2] = 1/3. Nothing here depends on the implementation.
  # ---------------------------------------------------------------------------

  defp ring_three do
    snapshot(
      [bus(1, 3), bus(2), bus(3)],
      [line(1, 1, 2, 0.1), line(2, 1, 3, 0.1), line(3, 2, 3, 0.1)],
      [gen(1, 1, 30.0)],
      [load(1, 2, 30.0)]
    )
  end

  describe "hand-computed three-bus ring" do
    test "base flows are the ones the network geometry demands" do
      {_lodf, solution} = init!(ring_three())

      assert_in_delta flow(solution.line_flows, {:line, 1}), 20.0, 1.0e-9
      assert_in_delta flow(solution.line_flows, {:line, 2}), 10.0, 1.0e-9
      assert_in_delta flow(solution.line_flows, {:line, 3}), -10.0, 1.0e-9
    end

    test "the outage denominator is 1 - PTDF_self = 1/3" do
      {lodf, _} = init!(ring_three())
      {:ok, [{_pos, _x, denom}]} = LODF.sensitivity_batch(lodf, [0])

      assert_in_delta denom, 1.0 / 3.0, 1.0e-12
      refute LODF.island_split_denominator?(denom)
    end

    test "tripping 1-2 pushes its whole 20 MW around the other two lines" do
      {lodf, _} = init!(ring_three())
      {:ok, _lodf, flows} = LODF.trip_line(lodf, {:line, 1})

      # LODF of +1 and -1 against a 20 MW base flow.
      assert_in_delta flow(flows, {:line, 2}), 30.0, 1.0e-9
      assert_in_delta flow(flows, {:line, 3}), -30.0, 1.0e-9
    end

    test "the tripped branch leaves the flow map, as a re-solve would" do
      {lodf, _} = init!(ring_three())
      {:ok, _lodf, flows} = LODF.trip_line(lodf, {:line, 1})

      refute Map.has_key?(flows, {:line, 1})
      assert map_size(flows) == 2
    end

    test "flows carry the full Solution.line_flows shape" do
      {lodf, _} = init!(ring_three())
      {:ok, _lodf, flows} = LODF.trip_line(lodf, {:line, 1})
      entry = Map.fetch!(flows, {:line, 2})

      for key <- [
            :from_bus_id,
            :to_bus_id,
            :p_flow_mw,
            :rating_mva,
            :rating_b_mva,
            :rating_c_mva,
            :loading_pct,
            :emergency_loading_pct,
            :trip_loading_pct,
            :overloaded
          ] do
        assert Map.has_key?(entry, key), "missing #{key}"
      end

      assert_in_delta entry.loading_pct, 3.0, 1.0e-9
      refute entry.overloaded
    end
  end

  # ---------------------------------------------------------------------------
  # Equivalence against a real re-solve
  # ---------------------------------------------------------------------------

  # A ring with chords: meshed enough that no single branch is a bridge and
  # every outage genuinely redistributes. Reactances vary by an order of
  # magnitude so no symmetry can hide an indexing error.
  defp meshed(n) do
    buses = [bus(1, 3) | Enum.map(2..n, &bus/1)]

    ring =
      Enum.map(1..n, fn i ->
        to = if i == n, do: 1, else: i + 1
        line(i, i, to, 0.02 + rem(i * 7, 13) * 0.01)
      end)

    chords =
      Enum.map(1..div(n, 3), fn i ->
        from = i
        to = rem(i + div(n, 2), n) + 1
        line(1000 + i, from, to, 0.05 + rem(i * 5, 11) * 0.02)
      end)

    chords = Enum.reject(chords, &(&1.from_bus_id == &1.to_bus_id))

    loads = Enum.map(2..n, fn i -> load(i, i, 10.0 + rem(i * 11, 17) * 3.0) end)
    total_load = Enum.reduce(loads, 0.0, &(&2 + &1.p_mw))

    gens = [
      gen(1, 1, total_load * 0.4),
      gen(2, div(n, 2), total_load * 0.35),
      gen(3, n, total_load * 0.25)
    ]

    snapshot(buses, ring ++ chords, gens, loads)
  end

  describe "equivalence with a full DC re-solve" do
    test "every single-branch outage on a 12-bus mesh matches to numerical noise" do
      snap = meshed(12)
      {lodf, _} = init!(snap)

      for key <- LODF.branch_keys(lodf) do
        case LODF.outage_flows(lodf, [key]) do
          {:ok, flows} ->
            reference = resolve_without(snap, [key])

            worst =
              Enum.reduce(flows, 0.0, fn {k, f}, acc ->
                ref = flow(reference.line_flows, k)
                max(acc, abs(f.p_flow_mw - ref) / max(abs(ref), 1.0))
              end)

            assert worst < 1.0e-9,
                   "outage of #{inspect(key)} drifted #{worst} relative from the re-solve"

          {:island_split, _info} ->
            flunk("#{inspect(key)} should not be a bridge in a meshed ring")
        end
      end
    end

    test "a 40-bus mesh matches too, including transformers with off-nominal taps" do
      base = meshed(40)

      # Convert three ring branches into transformers with real taps: the tap
      # model is the convention most likely to drift between B' assemblies.
      {converted, remaining} = Enum.split(base.lines, 3)

      xfmrs =
        converted
        |> Enum.with_index()
        |> Enum.map(fn {l, i} ->
          %{
            id: l.id,
            from_bus_id: l.from_bus_id,
            to_bus_id: l.to_bus_id,
            x_pu: l.x_pu,
            tap_ratio: 0.95 + i * 0.05,
            rated_mva: 800.0
          }
        end)

      snap = %{base | lines: remaining, transformers: xfmrs}
      {lodf, _} = init!(snap)

      worst =
        Enum.reduce(LODF.branch_keys(lodf), 0.0, fn key, acc ->
          {:ok, flows} = LODF.outage_flows(lodf, [key])
          reference = resolve_without(snap, [key])

          Enum.reduce(flows, acc, fn {k, f}, a ->
            ref = flow(reference.line_flows, k)
            max(a, abs(f.p_flow_mw - ref) / max(abs(ref), 1.0))
          end)
        end)

      assert worst < 1.0e-9, "worst relative flow error across all N-1 outages: #{worst}"
    end

    test "simultaneous pairs are exact, not a sequential approximation" do
      snap = meshed(16)
      {lodf, _} = init!(snap)
      keys = LODF.branch_keys(lodf)

      pairs =
        for a <- Enum.take(keys, 6), b <- Enum.take(keys, 6), a < b, do: [a, b]

      worst =
        Enum.reduce(pairs, 0.0, fn pair, acc ->
          case LODF.outage_flows(lodf, pair) do
            {:ok, flows} ->
              reference = resolve_without(snap, pair)

              Enum.reduce(flows, acc, fn {k, f}, a ->
                ref = flow(reference.line_flows, k)
                max(a, abs(f.p_flow_mw - ref) / max(abs(ref), 1.0))
              end)

            {:island_split, _} ->
              acc
          end
        end)

      assert worst < 1.0e-9, "worst relative flow error across N-2 pairs: #{worst}"
    end

    test "cumulative trips stay exact and do not compound error" do
      snap = meshed(20)
      {lodf, _} = init!(snap)
      sequence = lodf |> LODF.branch_keys() |> Enum.take(5)

      {final, tripped} =
        Enum.reduce(sequence, {lodf, []}, fn key, {state, so_far} ->
          case LODF.trip_line(state, key) do
            {:ok, next, _flows} -> {next, [key | so_far]}
            {:island_split, state, _} -> {state, so_far}
          end
        end)

      {:ok, flows} = LODF.outage_flows(final, tripped)
      reference = resolve_without(snap, tripped)

      worst =
        Enum.reduce(flows, 0.0, fn {k, f}, acc ->
          ref = flow(reference.line_flows, k)
          max(acc, abs(f.p_flow_mw - ref) / max(abs(ref), 1.0))
        end)

      assert length(tripped) == 5
      assert worst < 1.0e-9, "after 5 cumulative trips the error was #{worst}"
    end
  end

  # ---------------------------------------------------------------------------
  # Bridges
  # ---------------------------------------------------------------------------

  # Two triangles joined by a single line. Opening that line splits the network;
  # opening anything else does not.
  #
  #   1 - 2        4 - 5
  #    \ /          \ /
  #     3 ---------- 6
  defp dumbbell do
    snapshot(
      Enum.map(1..6, fn i -> bus(i, if(i == 1, do: 3, else: 1)) end),
      [
        line(1, 1, 2, 0.1),
        line(2, 2, 3, 0.1),
        line(3, 1, 3, 0.1),
        line(4, 4, 5, 0.1),
        line(5, 5, 6, 0.1),
        line(6, 4, 6, 0.1),
        line(7, 3, 6, 0.1)
      ],
      [gen(1, 1, 100.0), gen(2, 4, 20.0)],
      [load(1, 2, 40.0), load(2, 5, 60.0)]
    )
  end

  describe "bridge detection" do
    test "the joining line is the only bridge, and it reports what separates" do
      {lodf, _} = init!(dumbbell())
      bridges = LODF.bridges(lodf)

      assert map_size(bridges) == 1

      {:island_split, _lodf, info} = LODF.trip_line(lodf, {:line, 7})

      assert info.branch == {:line, 7}
      assert info.reason == :bridge
      assert info.islanded_bus_count == 3
      # The separated triangle is buses 4/5/6: 60 MW of load, 20 MW of gen.
      assert_in_delta info.islanded_load_mw, 60.0, 1.0e-9
      assert_in_delta info.islanded_gen_mw, 20.0, 1.0e-9
      # 40 MW short on that side; the other side has 100 MW gen for 40 MW load.
      assert_in_delta info.mw_at_risk, 40.0, 1.0e-9
    end

    test "the reported island is the side that loses the slack, not the side the search left from" do
      # Same network, slack moved to bus 5 — the far side of the tie from the
      # search's starting point. The island reported must flip with it: buses
      # 1/2/3 now have to balance alone (40 MW load against 100 MW gen, so
      # 60 MW of generation to curtail), and reporting the DFS subtree instead
      # would still name buses 4/5/6.
      snap = dumbbell()

      snap = %{
        snap
        | buses: Enum.map(snap.buses, fn b -> %{b | bus_type: if(b.id == 5, do: 3, else: 1)} end)
      }

      {lodf, _} = init!(snap)
      {:island_split, _lodf, info} = LODF.trip_line(lodf, {:line, 7})

      assert info.islanded_bus_count == 3
      assert_in_delta info.islanded_load_mw, 40.0, 1.0e-9
      assert_in_delta info.islanded_gen_mw, 100.0, 1.0e-9
      assert_in_delta info.mw_at_risk, 60.0, 1.0e-9
    end

    test "the split the bridge search finds is a split the partitioner finds" do
      snap = dumbbell()
      {lodf, _} = init!(snap)

      for key <- LODF.branch_keys(lodf) do
        remaining = Enum.reject(snap.lines, &(&1.id == elem(key, 1)))

        islands =
          PowerModel.Simulation.Cascading.IslandDetector.detect(
            Enum.map(snap.buses, & &1.id),
            remaining,
            []
          )

        graph_splits? = length(islands) > 1
        lodf_splits? = match?({:island_split, _, _}, LODF.trip_line(lodf, key))

        assert graph_splits? == lodf_splits?,
               "#{inspect(key)}: partitioner says split=#{graph_splits?}, LODF says #{lodf_splits?}"
      end
    end

    test "parallel circuits between the same buses are not a bridge" do
      snap = dumbbell()
      # Double-circuit the tie: neither circuit alone disconnects anything.
      snap = %{snap | lines: snap.lines ++ [line(8, 3, 6, 0.1)]}
      {lodf, _} = init!(snap)

      assert LODF.bridges(lodf) == %{}
      assert {:ok, _lodf, _flows} = LODF.trip_line(lodf, {:line, 7})
    end

    test "an outage set that splits only in combination is caught numerically" do
      snap = dumbbell()
      snap = %{snap | lines: snap.lines ++ [line(8, 3, 6, 0.1)]}
      {lodf, _} = init!(snap)

      # Neither tie circuit is a bridge, but taking both is a split, and the
      # intact-graph bridge set cannot know that. The singular (I - Psi) test
      # is what has to catch it.
      assert LODF.bridges(lodf) == %{}

      assert {:island_split, info} = LODF.outage_flows(lodf, [{:line, 7}, {:line, 8}])
      assert info.reason == :singular_outage_set
    end
  end

  # ---------------------------------------------------------------------------
  # Guards
  # ---------------------------------------------------------------------------

  describe "validity horizon" do
    test "refuses past the cumulative-trip limit rather than degrading" do
      snap = meshed(20)
      solution = DCPowerFlow.solve(snap, base_mva: @base_mva)
      {:ok, lodf} = LODF.init(snap, solution, base_mva: @base_mva, max_outages: 2)
      [a, b, c | _] = LODF.branch_keys(lodf)

      {:ok, lodf, _} = LODF.trip_line(lodf, a)
      {:ok, lodf, _} = LODF.trip_line(lodf, b)

      assert LODF.needs_refactorize?(lodf)
      assert {:error, ^lodf, {:validity_horizon_exceeded, 3, 2}} = LODF.trip_line(lodf, c)
    end

    test "re-tripping an already-tripped branch is not counted twice" do
      snap = meshed(20)
      solution = DCPowerFlow.solve(snap, base_mva: @base_mva)
      {:ok, lodf} = LODF.init(snap, solution, base_mva: @base_mva, max_outages: 1)
      [a | _] = LODF.branch_keys(lodf)

      {:ok, lodf, flows} = LODF.trip_line(lodf, a)
      assert {:ok, lodf2, flows2} = LODF.trip_line(lodf, a)
      assert LODF.tripped_keys(lodf2) == [a]
      assert map_size(flows2) == map_size(flows)
    end

    test "reset returns to the base case" do
      snap = meshed(12)
      {lodf, solution} = init!(snap)
      [a | _] = LODF.branch_keys(lodf)
      {:ok, tripped, _} = LODF.trip_line(lodf, a)

      base = tripped |> LODF.reset() |> LODF.flows()

      assert LODF.tripped_keys(LODF.reset(tripped)) == []

      worst =
        Enum.reduce(base, 0.0, fn {k, f}, acc ->
          ref = flow(solution.line_flows, k)
          max(acc, abs(f.p_flow_mw - ref))
        end)

      assert worst < 1.0e-9
    end
  end

  # ---------------------------------------------------------------------------
  # The (I - Psi) solve
  #
  # Exercised directly because its partial-pivoting branch only runs when a
  # later row holds the larger pivot. Small well-conditioned outage pairs never
  # produce that, so the swap shipped broken and only surfaced on a 51k-bus
  # Eastern N-2 sweep. These matrices force it.
  # ---------------------------------------------------------------------------

  describe "small dense solve" do
    test "solves a system whose first pivot is zero, which needs a row swap" do
      assert {:ok, x} = LODF.dense_solve([[0.0, 1.0], [1.0, 0.0]], [1.0, 2.0])
      assert_in_delta Enum.at(x, 0), 2.0, 1.0e-12
      assert_in_delta Enum.at(x, 1), 1.0, 1.0e-12
    end

    test "solves a 3x3 needing swaps in more than one column" do
      m = [[0.0, 2.0, 1.0], [1.0, 0.0, 3.0], [0.0, 0.0, 4.0]]
      b = [8.0, 14.0, 8.0]

      assert {:ok, x} = LODF.dense_solve(m, b)

      # Residual, not hand-solved values: the check that matters is that the
      # returned vector satisfies the system.
      for {row, rhs} <- Enum.zip(m, b) do
        lhs = row |> Enum.zip(x) |> Enum.reduce(0.0, fn {a, xi}, acc -> acc + a * xi end)
        assert_in_delta lhs, rhs, 1.0e-9
      end
    end

    test "reports a singular system rather than dividing by a zero pivot" do
      assert {:error, :singular} = LODF.dense_solve([[1.0, 2.0], [2.0, 4.0]], [1.0, 2.0])
      assert {:error, :singular} = LODF.dense_solve([[0.0]], [1.0])
    end
  end

  describe "init guards" do
    test "refuses a snapshot that is not one island" do
      snap = dumbbell()
      snap = %{snap | lines: Enum.reject(snap.lines, &(&1.id == 7))}
      solution = DCPowerFlow.solve_islands(snap, base_mva: @base_mva)

      assert {:error, {:disconnected, 2}} = LODF.init(snap, solution, base_mva: @base_mva)
    end

    test "refuses a base solution whose flows disagree with this module's B'" do
      snap = ring_three()
      solution = DCPowerFlow.solve(snap, base_mva: @base_mva)

      corrupted =
        update_in(solution.line_flows[{:line, 2}].p_flow_mw, fn mw -> mw * 1.02 end)

      assert {:error, {:flow_convention_mismatch, {:line, 2}, _reported, _computed}} =
               LODF.init(snap, corrupted, base_mva: @base_mva)
    end

    test "refuses an unknown branch key rather than silently ignoring it" do
      {lodf, _} = init!(ring_three())
      assert {:error, ^lodf, {:unknown_branch, {:line, 999}}} = LODF.trip_line(lodf, {:line, 999})
    end

    test "refuses a snapshot too small to have a B' at all" do
      snap = snapshot([bus(1, 3)], [], [gen(1, 1, 10.0)], [])
      solution = DCPowerFlow.solve(snap, base_mva: @base_mva)

      assert {:error, {:too_small, 1}} = LODF.init(snap, solution, base_mva: @base_mva)
    end
  end
end
