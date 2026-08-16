defmodule PowerModel.Analysis.ContingencyScreeningTest do
  @moduledoc """
  Covers ROADMAP item 21's sweep half — the number REVIEW UI-M15 says the UI
  has been faking.

  Two things are load-bearing and get most of the attention here.

  **The metrics have to survive a grid that is already broken.** 4,366 of
  64,664 Eastern branches (6.8%) are over their rating before anything trips,
  so any metric that counts overloads absolutely reports the same ~4,400 for
  every contingency and ranks nothing. Every count here is incremental, and the
  tests below pin all three directions: a pre-existing overload never counts as
  new; a contingency that pushes it further counts only the increase; and a
  contingency that *relieves* it counts as clean.

  **The census has to match a real re-solve.** The last test screens a meshed
  network and then re-solves every one of its contingencies with the branch
  genuinely removed, comparing the overload counts and megawatt figures
  branch-by-branch. Screening that ranks confidently and disagrees with the
  authoritative solve would be worse than the stub it replaces.
  """

  use ExUnit.Case, async: true

  alias PowerModel.Analysis.ContingencyScreening
  alias PowerModel.Solver.DCPowerFlow

  @base_mva 100.0

  defp bus(id, type \\ 1), do: %{id: id, bus_type: type, base_kv: 230.0}

  defp line(id, from, to, x_pu, rating),
    do: %{id: id, from_bus_id: from, to_bus_id: to, x_pu: x_pu, rating_a_mva: rating}

  defp gen(id, bus_id, p_max_mw),
    do: %{id: id, bus_id: bus_id, p_max_mw: p_max_mw, capacity_factor: 1.0}

  defp load(id, bus_id, p_mw), do: %{id: id, bus_id: bus_id, p_mw: p_mw}

  defp snapshot(buses, lines, gens, loads) do
    %{
      buses: buses,
      lines: lines,
      transformers: [],
      generators: gens,
      loads: loads,
      dc_ties: []
    }
  end

  defp entry(result, key), do: Enum.find(result.ranked, &(&1.branch == key))

  # ---------------------------------------------------------------------------
  # The three-bus ring again, this time with ratings chosen so that one branch
  # is ALREADY overloaded on the base case.
  #
  # Base flows: 1-2 carries 20 MW, 1-3 carries 10 MW, 2-3 carries -10 MW.
  # Ratings: 1-2 unlimited for practical purposes, 1-3 at 25 MVA (40% loaded),
  # 2-3 at 5 MVA — 200% loaded before anything happens.
  # ---------------------------------------------------------------------------

  defp ring_with_pre_existing_overload do
    snapshot(
      [bus(1, 3), bus(2), bus(3)],
      [line(1, 1, 2, 0.1, 1_000.0), line(2, 1, 3, 0.1, 25.0), line(3, 2, 3, 0.1, 5.0)],
      [gen(1, 1, 30.0)],
      [load(1, 2, 30.0)]
    )
  end

  describe "accounting on a base case that is already overloaded" do
    setup do
      {:ok, result} =
        ContingencyScreening.run(ring_with_pre_existing_overload(),
          base_mva: @base_mva,
          limit: 100
        )

      %{result: result}
    end

    test "the base case is reported, not silently folded into the results", %{result: result} do
      assert result.base.overloaded == 1
      assert result.base.monitored == 3
      assert_in_delta result.base.max_loading_pct, 200.0, 1.0e-9
      assert result.summary.base_overloaded == 1
    end

    test "a pre-existing overload pushed further counts as worsened, by the increase only",
         %{result: result} do
      # Tripping 1-2 sends its 20 MW around 1-3-2: 1-3 goes 10 -> 30 MW
      # (past its 25 MVA rating, a NEW overload of 5 MW) and 2-3 goes
      # -10 -> -30 MW, deepening an overload that was already 5 MW over by a
      # further 20 MW.
      e = entry(result, {:line, 1})

      assert e.category == :thermal
      assert e.new_overloads == 1
      assert_in_delta e.new_overload_mw, 5.0, 1.0e-9
      assert e.worsened_overloads == 1
      assert_in_delta e.worsened_overload_mw, 20.0, 1.0e-9
      assert_in_delta e.mw_at_risk, 25.0, 1.0e-9
      assert_in_delta e.max_loading_pct, 600.0, 1.0e-9
    end

    test "a contingency that relieves the existing overload is clean, not thermal",
         %{result: result} do
      # Tripping 1-3 leaves bus 3 radial: 2-3 falls to zero flow, so the branch
      # that was 200% loaded is no longer overloaded at all. Counting overloads
      # absolutely would still report one; counting them incrementally reports
      # nothing, which is the honest answer.
      e = entry(result, {:line, 2})

      assert e.category == :clean
      assert e.new_overloads == 0
      assert e.worsened_overloads == 0
      assert_in_delta e.mw_at_risk, 0.0, 1.0e-9
      assert e.max_loading_pct < 100.0
    end

    test "the outaged branch is not counted in its own contingency", %{result: result} do
      # 2-3 is the 200%-loaded branch. Screening ITS outage must not report the
      # branch it just removed as the worst loading in the system.
      e = entry(result, {:line, 3})

      assert e.category == :clean
      assert_in_delta e.max_loading_pct, 3.0, 1.0e-9
    end

    test "ranking is worst-first by megawatts at risk", %{result: result} do
      keys = Enum.map(result.ranked, & &1.branch)
      assert hd(keys) == {:line, 1}

      risks = Enum.map(result.ranked, & &1.mw_at_risk)
      assert risks == Enum.sort(risks, :desc)
    end
  end

  # ---------------------------------------------------------------------------
  # Island splits
  # ---------------------------------------------------------------------------

  defp dumbbell do
    snapshot(
      Enum.map(1..6, fn i -> bus(i, if(i == 1, do: 3, else: 1)) end),
      [
        line(1, 1, 2, 0.1, 500.0),
        line(2, 2, 3, 0.1, 500.0),
        line(3, 1, 3, 0.1, 500.0),
        line(4, 4, 5, 0.1, 500.0),
        line(5, 5, 6, 0.1, 500.0),
        line(6, 4, 6, 0.1, 500.0),
        line(7, 3, 6, 0.1, 500.0)
      ],
      [gen(1, 1, 100.0), gen(2, 4, 20.0)],
      [load(1, 2, 40.0), load(2, 5, 60.0)]
    )
  end

  describe "island splits" do
    test "a bridge outage is categorized as a split and ranked by the shortfall it creates" do
      {:ok, result} = ContingencyScreening.run(dumbbell(), base_mva: @base_mva, limit: 100)

      e = entry(result, {:line, 7})

      assert e.category == :island_split
      assert e.islanded_bus_count == 3
      assert_in_delta e.islanded_load_mw, 60.0, 1.0e-9
      assert_in_delta e.islanded_gen_mw, 20.0, 1.0e-9
      assert_in_delta e.mw_at_risk, 40.0, 1.0e-9
      # There is no post-outage flow solution, so there is no loading to quote.
      assert e.max_loading_pct == nil

      assert result.summary.island_splits == 1
      assert result.summary.screened == 7
    end
  end

  # ---------------------------------------------------------------------------
  # Full-sweep bookkeeping and the census check
  # ---------------------------------------------------------------------------

  defp meshed(n) do
    buses = [bus(1, 3) | Enum.map(2..n, &bus/1)]

    ring =
      Enum.map(1..n, fn i ->
        to = if i == n, do: 1, else: i + 1
        line(i, i, to, 0.02 + rem(i * 7, 13) * 0.01, 1.0)
      end)

    chords =
      1..div(n, 3)
      |> Enum.map(fn i ->
        line(1000 + i, i, rem(i + div(n, 2), n) + 1, 0.05 + rem(i * 5, 11) * 0.02, 1.0)
      end)
      |> Enum.reject(&(&1.from_bus_id == &1.to_bus_id))

    loads = Enum.map(2..n, fn i -> load(i, i, 10.0 + rem(i * 11, 17) * 3.0) end)
    total = Enum.reduce(loads, 0.0, &(&2 + &1.p_mw))

    gens = [
      gen(1, 1, total * 0.4),
      gen(2, div(n, 2), total * 0.35),
      gen(3, n, total * 0.25)
    ]

    snapshot(buses, ring ++ chords, gens, loads)
  end

  # Ratings assigned from the network's own base flows: comfortable headroom
  # nearly everywhere, so outages have room to create genuinely NEW overloads,
  # and two branches deliberately started over their rating so the incremental
  # accounting is exercised on real data rather than only on the hand case.
  defp meshed_with_ratings(n, pre_overloaded \\ 2) do
    snap = meshed(n)
    solution = DCPowerFlow.solve(snap, base_mva: @base_mva)

    ordered =
      snap.lines
      |> Enum.sort_by(&abs(solution.line_flows[{:line, &1.id}].p_flow_mw), :desc)
      |> Enum.with_index()

    lines =
      Enum.map(ordered, fn {l, idx} ->
        f = abs(solution.line_flows[{:line, l.id}].p_flow_mw)
        factor = if idx < pre_overloaded, do: 0.8, else: 1.3
        %{l | rating_a_mva: max(f * factor, 5.0)}
      end)

    %{snap | lines: Enum.sort_by(lines, & &1.id)}
  end

  describe "sweep bookkeeping" do
    test "every branch is screened exactly once and every entry has a category" do
      snap = meshed_with_ratings(14)
      {:ok, result} = ContingencyScreening.run(snap, base_mva: @base_mva, limit: 1_000)

      assert result.summary.screened == length(snap.lines)
      assert length(result.ranked) == result.summary.screened

      counts = result.summary

      assert counts.island_splits + counts.thermal + counts.clean + counts.negligible ==
               counts.screened

      assert Enum.all?(result.ranked, &(&1.category in [:island_split, :thermal, :clean]))
    end

    test "unrated branches are excluded from loading metrics but counted" do
      snap = meshed_with_ratings(14)
      [first | rest] = snap.lines
      snap = %{snap | lines: [%{first | rating_a_mva: nil} | rest]}

      {:ok, result} = ContingencyScreening.run(snap, base_mva: @base_mva, limit: 1_000)

      assert result.summary.unrated_branches == 1
      assert result.summary.monitored_branches == length(snap.lines) - 1
      assert result.summary.total_branches == length(snap.lines)
    end

    test ":branches screens only what was asked for" do
      snap = meshed_with_ratings(14)
      keys = [{:line, 1}, {:line, 2}, {:line, 3}]

      {:ok, result} =
        ContingencyScreening.run(snap, base_mva: @base_mva, branches: keys, limit: 100)

      assert result.summary.screened == 3
      assert Enum.map(result.ranked, & &1.branch) |> Enum.sort() == Enum.sort(keys)
    end

    test ":limit caps the ranked list without distorting the summary" do
      snap = meshed_with_ratings(14)
      {:ok, full} = ContingencyScreening.run(snap, base_mva: @base_mva, limit: 1_000)
      {:ok, capped} = ContingencyScreening.run(snap, base_mva: @base_mva, limit: 3)

      assert length(capped.ranked) == 3
      assert capped.summary.screened == full.summary.screened
      assert capped.summary.thermal == full.summary.thermal

      assert Enum.map(capped.ranked, & &1.branch) ==
               full.ranked |> Enum.take(3) |> Enum.map(& &1.branch)
    end

    test "concurrency does not change the answer" do
      snap = meshed_with_ratings(20)

      {:ok, serial} =
        ContingencyScreening.run(snap,
          base_mva: @base_mva,
          limit: 1_000,
          max_concurrency: 1,
          batch_size: 1
        )

      {:ok, parallel} =
        ContingencyScreening.run(snap,
          base_mva: @base_mva,
          limit: 1_000,
          max_concurrency: 8,
          batch_size: 4
        )

      assert Enum.map(serial.ranked, & &1.branch) == Enum.map(parallel.ranked, & &1.branch)
      assert serial.summary.thermal == parallel.summary.thermal
    end
  end

  describe "N-2 pair screening" do
    test "pairs are solved as one rank-2 update, matching a re-solve with both branches gone" do
      snap = meshed_with_ratings(16)
      base = DCPowerFlow.solve(snap, base_mva: @base_mva)
      {:ok, lodf} = PowerModel.Solver.LODF.init(snap, base, base_mva: @base_mva)

      seeds = snap.lines |> Enum.take(6) |> Enum.map(&{:line, &1.id})

      {:ok, result} =
        ContingencyScreening.screen_n2(lodf, seeds: seeds, limit: 1_000, base_mva: @base_mva)

      assert result.summary.seeds == 6
      assert result.summary.pairs == 15
      assert result.summary.screened == 15

      rating = Map.new(snap.lines, &{{:line, &1.id}, &1.rating_a_mva})

      base_over =
        Map.new(base.line_flows, fn {k, f} ->
          {k, max(abs(f.p_flow_mw) - Map.fetch!(rating, k), 0.0)}
        end)

      thermal = Enum.reject(result.ranked, &(&1.category == :island_split))
      assert Enum.count(thermal, &(&1.category == :thermal)) > 0

      for e <- thermal do
        dropped = MapSet.new(e.branches)

        reference =
          %{snap | lines: Enum.reject(snap.lines, &MapSet.member?(dropped, {:line, &1.id}))}
          |> DCPowerFlow.solve(base_mva: @base_mva)

        {new_count, new_mw, worse_count, max_pct} =
          Enum.reduce(reference.line_flows, {0, 0.0, 0, 0.0}, fn {k, f}, {nc, nmw, wc, mx} ->
            r = Map.fetch!(rating, k)
            af = abs(f.p_flow_mw)
            mx = max(mx, af / r * 100.0)
            was = Map.fetch!(base_over, k)

            cond do
              af <= r -> {nc, nmw, wc, mx}
              was > 0.0 and af - r > was + 1.0e-3 -> {nc, nmw, wc + 1, mx}
              was > 0.0 -> {nc, nmw, wc, mx}
              true -> {nc + 1, nmw + (af - r), wc, mx}
            end
          end)

        assert e.new_overloads == new_count, "new overloads for #{inspect(e.branches)}"
        assert e.worsened_overloads == worse_count, "worsened for #{inspect(e.branches)}"
        assert_in_delta e.new_overload_mw, new_mw, 1.0e-6
        assert_in_delta e.max_loading_pct, max_pct, 1.0e-6
      end
    end

    test "a pair containing a bridge is an island split, not a flow update" do
      base = DCPowerFlow.solve(dumbbell(), base_mva: @base_mva)
      {:ok, lodf} = PowerModel.Solver.LODF.init(dumbbell(), base, base_mva: @base_mva)

      {:ok, result} =
        ContingencyScreening.screen_n2(lodf,
          seeds: [{:line, 1}, {:line, 7}],
          limit: 10
        )

      assert [e] = result.ranked
      assert e.branches == [{:line, 1}, {:line, 7}]
      assert e.category == :island_split
      assert_in_delta e.mw_at_risk, 40.0, 1.0e-9
    end

    test "SOL-16: a crashed pair worker aborts the run instead of raising" do
      # `sweep/3` has always had this clause and `screen_n2` did not, so a dead
      # worker took a CaseClauseError out through the reduce rather than
      # reaching the caller as an error. The clause is reached when the caller
      # traps exits — which is the case that matters, because screening runs
      # inside a supervised process, not a bare test process.
      #
      # The crash is forced by emptying the position-indexed base-flow tuple,
      # which is read only inside the worker: `n2_seeds`, `seed_columns`,
      # `scan_list/1` and `bridges/1` all read other fields, so the
      # caller-side setup still succeeds and the failure lands where intended.
      snap = meshed_with_ratings(14)
      base = DCPowerFlow.solve(snap, base_mva: @base_mva)
      {:ok, lodf} = PowerModel.Solver.LODF.init(snap, base, base_mva: @base_mva)

      seeds = snap.lines |> Enum.take(4) |> Enum.map(&{:line, &1.id})
      broken = %{lodf | base_flow_mw: {}}

      Process.flag(:trap_exit, true)

      assert {:error, {:worker_exit, _reason}} =
               ContingencyScreening.screen_n2(broken, seeds: seeds, base_mva: @base_mva)
    end

    test "SOL-16: an island-split pair is an answer, not an abort" do
      # The other half of the contract. Aborting is for questions that could
      # not be evaluated; a pair that genuinely disconnects the network HAS
      # been evaluated and must stay in the ranked list.
      base = DCPowerFlow.solve(dumbbell(), base_mva: @base_mva)
      {:ok, lodf} = PowerModel.Solver.LODF.init(dumbbell(), base, base_mva: @base_mva)

      assert {:ok, result} =
               ContingencyScreening.screen_n2(lodf, seeds: [{:line, 1}, {:line, 7}], limit: 10)

      assert length(result.ranked) == 1
    end
  end

  describe "census agreement with full DC re-solves" do
    test "counts and megawatts match a re-solve for every contingency" do
      snap = meshed_with_ratings(16)
      base = DCPowerFlow.solve(snap, base_mva: @base_mva)
      {:ok, result} = ContingencyScreening.run(snap, base, base_mva: @base_mva, limit: 10_000)

      rating = Map.new(snap.lines, &{{:line, &1.id}, &1.rating_a_mva})

      base_over =
        Map.new(base.line_flows, fn {k, f} ->
          {k, max(abs(f.p_flow_mw) - Map.fetch!(rating, k), 0.0)}
        end)

      thermal = Enum.reject(result.ranked, &(&1.category == :island_split))
      assert length(thermal) > 0
      # The fixture has to actually produce overloads or this proves nothing.
      assert Enum.count(thermal, &(&1.category == :thermal)) > 0

      for e <- thermal do
        reference =
          %{snap | lines: Enum.reject(snap.lines, &({:line, &1.id} == e.branch))}
          |> DCPowerFlow.solve(base_mva: @base_mva)

        {new_count, new_mw, worse_count, worse_mw, max_pct} =
          Enum.reduce(reference.line_flows, {0, 0.0, 0, 0.0, 0.0}, fn {k, f},
                                                                      {nc, nmw, wc, wmw, mx} ->
            r = Map.fetch!(rating, k)
            af = abs(f.p_flow_mw)
            mx = max(mx, af / r * 100.0)
            was = Map.fetch!(base_over, k)

            cond do
              af <= r -> {nc, nmw, wc, wmw, mx}
              was > 0.0 and af - r > was + 1.0e-3 -> {nc, nmw, wc + 1, wmw + (af - r - was), mx}
              was > 0.0 -> {nc, nmw, wc, wmw, mx}
              true -> {nc + 1, nmw + (af - r), wc, wmw, mx}
            end
          end)

        assert e.new_overloads == new_count, "new overload count for #{inspect(e.branch)}"
        assert e.worsened_overloads == worse_count, "worsened count for #{inspect(e.branch)}"
        assert_in_delta e.new_overload_mw, new_mw, 1.0e-6
        assert_in_delta e.worsened_overload_mw, worse_mw, 1.0e-6
        assert_in_delta e.max_loading_pct, max_pct, 1.0e-6
      end
    end
  end
end
