defmodule PowerModel.Solver.FDPF do
  @moduledoc """
  Fast-decoupled AC power flow (Stott–Alsac), the AC solver that scales.

  The dense Newton-Raphson path rebuilds a (2n)x(2n) Jacobian every iteration.
  At 2,000 buses that is 13 million entries per iteration and a 335-second
  solve; at 50,000 it is not a solve at all. Fast decoupling replaces it with
  two *constant* real symmetric matrices, so the factorization happens once per
  topology and each iteration costs two back-substitutions:

      P–θ half:  B'  Δθ  = ΔP / |V|      (rows: every non-slack bus)
      Q–V half:  B'' Δ|V| = ΔQ / |V|      (rows: PQ buses only)

  Both are symmetric — the schema carries no phase shifters, the one branch
  model that would break that — so the existing sparse LDL^T NIF is the whole
  linear-algebra story. No new factorization backend is needed, and none was
  added.

  ## Variant: XB

  `B'` is the DC solver's B' exactly: series reactance only (`1/(t·x)`, taps
  folded in per this project's DC convention), no shunts, no line charging.
  `B''` is `-Im(Y_bus)` restricted to PQ rows and columns, carrying series
  resistance, off-nominal taps, line charging and bus shunts — it is read
  straight off the same Y-bus the mismatch evaluation uses, so the two cannot
  drift apart. That is the XB variant of van Amerongen's classification.

  The choice is a *convergence-rate* decision, not an accuracy one. B' and B''
  appear only in the step direction; the iteration terminates on the true AC
  mismatch computed from the full Y-bus, so a poor B'/B'' costs iterations and
  can cost convergence, but a converged FDPF solution is a converged AC
  solution to the same tolerance the Newton path uses. (If high-R/X islands
  ever refuse to converge, BX — resistance in B', not in B'' — is the standard
  next thing to try, and it changes only the two assembly functions here.)

  ## Q-limit switching (REVIEW SOL-13)

  Switching PV to PQ changes B'''s dimension but leaves B' untouched, so a
  switching round refactorizes B'' alone and reuses the B' handle and the
  converged voltage state. All violators in a round switch together.

  The switching *rule* lives in `NewtonRaphson.pv_pq_switching/1` and is shared
  with the dense path, so both solvers reach the same PV/PQ split. Its
  `:q_limit_policy` option is what SOL-13 turns on: the default releases a
  generator when its voltage says the limit stopped binding, which is the state
  the complementarity conditions actually admit; `:matpower` never releases,
  which is what the committed references were generated with. See that
  function's docs for the measurement separating the two.

  ## Soundness

  `sparse_factor/4` succeeding promises nothing: LDL^T here is unpivoted and
  factors an indefinite matrix without complaint. Every cached solve is
  therefore residual-checked against the same tolerance the DC solver uses, and
  a rejected solve aborts the FDPF attempt rather than feeding a garbage step
  into the iteration. Note that this guard is strongest early, when the
  right-hand side is O(1); near convergence the mismatch is tiny and the
  residual test is loose. The real guarantee at that end is the convergence
  test itself, which is evaluated on the full AC mismatch and cannot be
  satisfied by a bad linear solve.

  A cached handle carries no memory of the topology it came from. Every entry
  point here builds its own handles and drops them when the solve returns;
  nothing is cached across calls.

  ## Two cutoffs, two different questions (REVIEW SOL-14)

  `@dense_nr_max_buses` (25) is the PRIMARY handoff: at or below it, `solve/2`
  never runs FDPF at all and dense Newton-Raphson is authoritative. Its
  justification is that at that size the choice is free — both solvers are far
  under a millisecond — so the more robust one wins, and the many tiny
  fragments a cascade produces are exactly where the decoupling assumption is
  least reliable.

  `@dense_nr_fallback_max_buses` (300) is a DIFFERENT question with a
  different answer: how large an island can we afford to *retry* densely after
  FDPF has already failed on it. That retry is not free, and the cost is not
  the converged cost — a fallback fires precisely on the islands that are hard,
  so what gets paid is a full iteration budget on a dense (2n)x(2n) Jacobian
  that usually ends in `converged: false`, the same answer refusing outright
  would have given. It is O(n^3) and it was measured, on real ERCOT
  sub-islands: 5.2 s at 306 buses, 120.4 s at 933, 340.8 s at 1,318 with a
  1.4 GB peak, extrapolating to about an hour at the 3,000 this cutoff used to
  sit at. The cascade engine's trip timeout is 120 s, so anything past a few
  hundred buses spends the whole budget and then reports failure anyway.

  300 keeps the affordable retry (a few seconds, worth it for the chance of a
  converged answer) and refuses the rest in a quarter-second. Islands above it
  get an unconverged `Solution` and a warning, not a stall. The two cutoffs are
  independently settable — `:dense_nr_max_buses` per call, and the fallback
  bound via `dense_nr_fallback_max_buses/0` — because they answer to different
  evidence.

  One consequence to be aware of: the same bound governs `hard_failure`, so an
  island between 300 and 3,000 buses whose LINEAR SOLVE is rejected now throws
  where it used to be retried densely. That is the intended reading and not
  merely a side effect — above roughly 250 buses the Jacobian exceeds
  `NewtonRaphson`'s own Gaussian cap (REVIEW SOL-15), so on precisely the
  ill-conditioned islands that reach `hard_failure` the dense retry would burn
  an LU attempt and then refuse anyway.

  Whichever path ran is recorded on the `Solution`'s `:solver` field, so a
  fallback is visible rather than inferred from a suspicious iteration count.

  Failures are logged once per island, never once per bus: the OTP logger drops
  most of a warning burst under load.
  """

  alias PowerModel.Solver.{NewtonRaphson, Partition, Solution, Sparse, YBus}

  require Logger

  @tolerance 1.0e-6

  # FDPF converges linearly, so it needs many more iterations than Newton's 50 —
  # but each is two back-substitutions instead of a Jacobian rebuild. Measured:
  # a comfortable operating point takes ~30-50, one near the network's
  # loadability limit 75-100 (iteration count climbing is how the nose
  # announces itself). The stall detector below, not this cap, is what ends a
  # hopeless solve, so the cap can afford to be generous.
  @max_iterations 100

  # Enough rounds for the latched switching rule to settle: a bus can change
  # type at most three times, and rounds switch every violator at once.
  @max_qlim_rounds 10

  # Same tolerance the DC solver applies to its sparse solves.
  @residual_tolerance 1.0e-6

  # Stall detection: give up after this many iterations without a new best
  # mismatch, where "better" means at least this much smaller. Converging FDPF
  # sets a new best essentially every iteration, so the window only has to be
  # long enough to ride out the damped early steps.
  @stall_window 15
  @stall_improvement 0.999

  # Where dense Newton-Raphson keeps the work. Measured on meshed synthetic
  # cases, FDPF is faster at *every* size tried — 2x at 10 buses, 11x at 50,
  # 32x at 100, 96x at 200, 2,708x at 2,000 — so this is not a performance
  # crossover; there isn't one. It is the size below which choosing the more
  # robust solver costs nothing measurable (both are far under a millisecond),
  # and the many tiny fragments a cascade produces are exactly where the
  # decoupling assumption is least reliable and where the sparse path would
  # otherwise spend its time in the NIF's degenerate 1x1 and 2x2 cases.
  @dense_nr_max_buses 25

  # Above this a failed FDPF is REPORTED, not retried densely. See the
  # moduledoc: this is not the same question @dense_nr_max_buses answers, and
  # it does not have the same answer. A fallback pays a full dense iteration
  # budget on an island already known to be hard, so the measured cost is the
  # FAILED-solve cost, not the converged one — seconds at 300 buses, minutes
  # at 900, hours at the 3,000 this used to be. LIN-13 makes non-convergence
  # the normal case on real fragments, and the cascade engine's trip timeout
  # is 120 s, so a retry that cannot finish inside a few seconds buys nothing
  # the immediate refusal does not.
  @dense_nr_fallback_max_buses 300

  @max_dtheta 0.5
  @max_dv 0.1
  @vm_floor 0.5
  @vm_ceiling 1.5

  @doc """
  Solve every electrically separate island in a snapshot and merge the results.

  Mirrors `DCPowerFlow.solve_islands/2`: islands are solved independently,
  dead (generatorless) islands are excluded from the solve but surfaced as
  `dead_load_mw` / `dead_bus_count`, and a snapshot with nothing solvable
  yields `converged: false`.
  """
  def solve_islands(snapshot, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    {subs, dead} = Partition.split(snapshot)

    dead_buses = Enum.reduce(dead, MapSet.new(), &MapSet.union(&2, &1))

    dead_load_mw =
      snapshot.loads
      |> Enum.filter(&MapSet.member?(dead_buses, &1.bus_id))
      |> Enum.reduce(0.0, fn load, acc -> acc + (load.p_mw || 0.0) end)

    solutions =
      Enum.map(subs, fn sub ->
        {:ok, solution} = solve(sub, opts)
        solution
      end)

    merged = Partition.merge_solutions(solutions, base_mva)

    %{
      merged
      | dead_load_mw: dead_load_mw,
        dead_bus_count: MapSet.size(dead_buses),
        solver: Solution.merged_solver(solutions)
    }
  end

  @doc """
  Solve one connected island.

  Returns `{:ok, %Solution{}}`; `converged` is false when neither FDPF nor the
  dense fallback reached tolerance. Throws `{:error, reason}` when the island
  cannot be solved at all — an empty snapshot, or a linear system that fails
  its residual check at a size too large to fall back from.

  Options: `:base_mva`, `:tolerance`, `:max_iterations`, `:warm_start`, plus
  `:dense_nr_max_buses` to move (or, at 0, disable) the dense-NR cutoff.
  """
  def solve(snapshot, opts \\ []) do
    n = length(snapshot.buses)
    cutoff = Keyword.get(opts, :dense_nr_max_buses, @dense_nr_max_buses)

    if n <= cutoff do
      NewtonRaphson.solve(snapshot, opts)
    else
      fast_decoupled_solve(snapshot, opts)
    end
  end

  defp fast_decoupled_solve(snapshot, opts) do
    tol = Keyword.get(opts, :tolerance, @tolerance)
    max_iter = Keyword.get(opts, :max_iterations, @max_iterations)

    prep = NewtonRaphson.prepare(snapshot, opts)
    {vm, va} = NewtonRaphson.initial_voltages(prep, Keyword.get(opts, :warm_start))

    non_slack = Enum.sort(prep.pq_indices ++ prep.pv_indices)

    if non_slack == [] do
      # A single-bus island: the slack holds everything and there is nothing
      # to solve. Report it converged with a zero mismatch, as the DC path does.
      {:ok, stamp(NewtonRaphson.build_solution(prep, vm, va, true, 0, 0.0, nil))}
    else
      case factor_b_prime(prep) do
        {:ok, bp} ->
          run_outer(prep, vm, va, bp, non_slack, tol, max_iter, snapshot, opts)

        {:error, reason} ->
          hard_failure(snapshot, opts, {:b_prime, reason})
      end
    end
  end

  defp run_outer(prep, vm, va, bp, non_slack, tol, max_iter, snapshot, opts) do
    state = %{
      switched: %{},
      released: MapSet.new(),
      latched: MapSet.new(),
      back_switch: NewtonRaphson.back_switch?(opts)
    }

    case outer_solve(prep, vm, va, bp, non_slack, state, tol, max_iter, 0, 0) do
      {:ok, vm, va, converged, iters, max_mis, p_calc} ->
        solution =
          stamp(NewtonRaphson.build_solution(prep, vm, va, converged, iters, max_mis, p_calc))

        if converged do
          {:ok, solution}
        else
          diverged_fallback(snapshot, opts, solution, iters, max_mis)
        end

      {:error, reason} ->
        hard_failure(snapshot, opts, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Q-limit outer loop
  #
  # One round = converge with a FIXED PV/PQ split, then test generator Q limits
  # at that converged operating point. B' is a function of the topology alone
  # and survives every round; only B'' is rebuilt, and only because its row set
  # is the PQ set.
  # ---------------------------------------------------------------------------

  defp outer_solve(prep, vm, va, bp, non_slack, state, tol, max_iter, round, iters_so_far) do
    pv_eff = prep.pv_indices |> Enum.reject(&Map.has_key?(state.switched, &1)) |> Enum.sort()
    pq_eff = Enum.sort(prep.pq_indices ++ Map.keys(state.switched))

    # A bus handed back to PV holds its setpoint again from this round on.
    vm =
      Enum.reduce(pv_eff, vm, fn idx, acc ->
        :array.set(idx, :array.get(idx, prep.v_sched), acc)
      end)

    with {:ok, bpp} <- factor_b_double_prime(prep, pq_eff),
         {:ok, result} <-
           iterate(prep, vm, va, bp, bpp, non_slack, pq_eff, state.switched, tol, max_iter, 0) do
      %{vm: vm, va: va, converged: converged, iters: iters, max_mismatch: max_mis} = result
      total_iters = iters_so_far + iters

      if converged do
        {switched, released, latched} =
          NewtonRaphson.pv_pq_switching(%{
            pv_indices: pv_eff,
            switched: state.switched,
            released: state.released,
            latched: state.latched,
            back_switch: state.back_switch,
            q_calc: result.q_calc,
            q_sched_pre: result.q_sched_pre,
            q_limits: prep.q_limits,
            vm: vm,
            v_sched: prep.v_sched
          })

        cond do
          switched == state.switched ->
            {:ok, vm, va, true, total_iters, max_mis, result.p_calc}

          round < @max_qlim_rounds ->
            outer_solve(
              prep,
              vm,
              va,
              bp,
              non_slack,
              %{state | switched: switched, released: released, latched: latched},
              tol,
              max_iter,
              round + 1,
              total_iters
            )

          true ->
            Logger.warning(
              "FDPF reached the Q-limit switching round cap (#{@max_qlim_rounds}) " <>
                "while the PV/PQ switching set was still changing " <>
                "(#{map_size(switched)} buses held at a limit)"
            )

            {:ok, vm, va, true, total_iters, max_mis, result.p_calc}
        end
      else
        {:ok, vm, va, false, total_iters, max_mis, nil}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The alternating iteration
  #
  # Each pass is: evaluate the full AC mismatch, take the P–θ half-step,
  # re-evaluate, take the Q–V half-step. Convergence is tested after every
  # half-step against the true mismatch, never against the decoupled model's
  # own residual.
  # ---------------------------------------------------------------------------

  defp iterate(prep, vm, va, bp, bpp, non_slack, pq, switched, tol, max_iter, iter) do
    iterate(prep, vm, va, bp, bpp, non_slack, pq, switched, tol, max_iter, iter, :infinity, 0)
  end

  defp iterate(_p, vm, va, _bp, _bpp, _ns, _pq, _sw, _tol, max_iter, iter, best, _stalled)
       when iter >= max_iter do
    {:ok, unconverged(vm, va, iter, best)}
  end

  # A solve that has stopped improving is not going to start again: FDPF's
  # convergence is geometric, so a window this long with no new best mismatch
  # means the operating point is past the network's loadability limit (or the
  # decoupling assumption has broken down). Stopping here turns a minute of
  # futile iteration on an unsolvable island into a few seconds.
  defp iterate(_p, vm, va, _bp, _bpp, _ns, _pq, _sw, _tol, _mi, iter, best, stalled)
       when stalled >= @stall_window do
    {:ok, unconverged(vm, va, iter, best)}
  end

  defp iterate(prep, vm, va, bp, bpp, non_slack, pq, switched, tol, max_iter, iter, best, stalled) do
    # The scheduled injections are a function of |V| alone (the ZIP load model
    # and the generator Q clamps), and the P half-step moves only angles, so
    # one evaluation serves both mismatch evaluations in an iteration.
    sched = scheduled(prep, vm, switched)
    mis = mismatch(prep, sched, vm, va, non_slack, pq)

    cond do
      converged?(mis, tol) ->
        {:ok, done(vm, va, iter + 1, mis)}

      diverged?(mis) ->
        {:ok, unconverged(vm, va, iter + 1, max_norm(mis))}

      true ->
        with {:ok, va} <- p_half_step(bp, mis, vm, va, non_slack) do
          mid = mismatch(prep, sched, vm, va, non_slack, pq)

          if converged?(mid, tol) do
            {:ok, done(vm, va, iter + 1, mid)}
          else
            with {:ok, vm} <- q_half_step(bpp, mid, vm, pq) do
              trace(iter, mis, mid)
              {best, stalled} = progress(best, stalled, max_norm(mid))

              iterate(
                prep,
                vm,
                va,
                bp,
                bpp,
                non_slack,
                pq,
                switched,
                tol,
                max_iter,
                iter + 1,
                best,
                stalled
              )
            end
          end
        end
    end
  end

  defp progress(:infinity, _stalled, current), do: {current, 0}

  defp progress(best, stalled, current) do
    if current < best * @stall_improvement do
      {current, 0}
    else
      {min(best, current), stalled + 1}
    end
  end

  defp unconverged(vm, va, iters, max_mismatch) do
    %{
      vm: vm,
      va: va,
      converged: false,
      iters: iters,
      max_mismatch: max_mismatch,
      p_calc: nil,
      q_calc: nil,
      q_sched_pre: nil
    }
  end

  # Per-iteration convergence trace. Lazy, so it costs nothing unless the
  # Logger is at :debug — which is the only sane way to watch a 60-iteration
  # solve on a 50,000-bus island decide whether it is converging or stalling.
  defp trace(iter, mis, mid) do
    Logger.debug(fn ->
      "FDPF iter #{iter}: max|dP| #{fmt(mis.dp)} max|dQ| #{fmt(mis.dq)} " <>
        "-> after P step max|dP| #{fmt(mid.dp)} max|dQ| #{fmt(mid.dq)}"
    end)
  end

  defp fmt(values) do
    values
    |> Enum.map(&abs/1)
    |> Enum.max(fn -> 0.0 end)
    |> then(&:erlang.float_to_binary(&1, [{:decimals, 8}]))
  end

  defp done(vm, va, iters, mis) do
    %{
      vm: vm,
      va: va,
      converged: true,
      iters: iters,
      max_mismatch: max_norm(mis),
      p_calc: mis.p_calc,
      q_calc: mis.q_calc,
      q_sched_pre: mis.q_sched_pre
    }
  end

  # Scheduled injections at the current |V|: generation minus ZIP-effective
  # load, with any generator held at a reactive limit clamped there.
  defp scheduled(prep, vm, switched) do
    {p_sched, q_sched_pre} = NewtonRaphson.scheduled_injections(prep, vm)
    {p_sched, NewtonRaphson.apply_q_clamps(q_sched_pre, switched), q_sched_pre}
  end

  # Mismatch for every non-slack bus (P) and every PQ bus (Q) at the current
  # voltage state, from the full Y-bus. This is the same quantity the Newton
  # path converges on, so `max_mismatch` means the same thing in both solutions.
  defp mismatch(prep, {p_sched, q_sched, q_sched_pre}, vm, va, non_slack, pq) do
    {p_calc, q_calc} = NewtonRaphson.power_injections(prep.y_sparse, vm, va)

    dp = Enum.map(non_slack, fn i -> :array.get(i, p_sched) - :array.get(i, p_calc) end)
    dq = Enum.map(pq, fn i -> :array.get(i, q_sched) - :array.get(i, q_calc) end)

    %{dp: dp, dq: dq, p_calc: p_calc, q_calc: q_calc, q_sched_pre: q_sched_pre}
  end

  defp max_norm(%{dp: dp, dq: dq}) do
    (dp ++ dq) |> Enum.map(&abs/1) |> Enum.max(fn -> 0.0 end)
  end

  defp converged?(mis, tol), do: max_norm(mis) < tol

  # `value != value` catches NaN, which passes both ordering comparisons.
  defp diverged?(mis) do
    m = max_norm(mis)
    not is_number(m) or m != m or m > 1.0e10
  end

  defp p_half_step(bp, mis, vm, va, non_slack) do
    rhs =
      [non_slack, mis.dp]
      |> Enum.zip()
      |> Enum.map(fn {i, dp} -> dp / :array.get(i, vm) end)

    case cached_solve(bp, rhs, :b_prime) do
      {:ok, dtheta} ->
        dtheta = damp(dtheta, @max_dtheta)

        va =
          [non_slack, dtheta]
          |> Enum.zip()
          |> Enum.reduce(va, fn {i, d}, acc -> :array.set(i, :array.get(i, acc) + d, acc) end)

        {:ok, va}

      error ->
        error
    end
  end

  # No PQ buses (every bus is a generator bus) leaves no Q equation to solve.
  defp q_half_step(nil, _mis, vm, _pq), do: {:ok, vm}

  defp q_half_step(bpp, mis, vm, pq) do
    rhs =
      [pq, mis.dq]
      |> Enum.zip()
      |> Enum.map(fn {i, dq} -> dq / :array.get(i, vm) end)

    case cached_solve(bpp, rhs, :b_double_prime) do
      {:ok, dv} ->
        dv = damp(dv, @max_dv)

        vm =
          [pq, dv]
          |> Enum.zip()
          |> Enum.reduce(vm, fn {i, d}, acc ->
            v = :array.get(i, acc) + d
            :array.set(i, min(max(v, @vm_floor), @vm_ceiling), acc)
          end)

        {:ok, vm}

      error ->
        error
    end
  end

  # Uniform scaling, not per-element clipping: shortening the step preserves
  # its direction, where clipping one component alone would not.
  defp damp(values, limit) do
    worst = values |> Enum.map(&abs/1) |> Enum.max(fn -> 0.0 end)

    if worst > limit do
      scale = limit / worst
      Enum.map(values, &(&1 * scale))
    else
      values
    end
  end

  # ---------------------------------------------------------------------------
  # B' and B'' assembly
  #
  # Both are emitted as COO triplets with the excluded rows and columns dropped
  # at emission rather than sliced out afterwards, and duplicate positions are
  # summed natively by the solver — the same contract the DC assembly relies on.
  # ---------------------------------------------------------------------------

  # B' rows and columns are every bus but the slack, so the slack is eliminated
  # by index shifting exactly as in the DC solver. A self-loop lands all four
  # entries on one diagonal position where +b, +b, -b, -b cancel, which is
  # right: a branch from a bus to itself carries no flow.
  defp factor_b_prime(prep) do
    slack = prep.slack_idx

    acc =
      Enum.reduce(prep.lines, {[], [], [], 0}, fn line, acc ->
        i = Map.fetch!(prep.bus_index, line.from_bus_id)
        j = Map.fetch!(prep.bus_index, line.to_bus_id)
        b_ij = 1.0 / YBus.effective_reactance(line.x_pu)
        add_branch_triplets(acc, i, j, b_ij, slack)
      end)

    {rows, cols, vals, negative} =
      Enum.reduce(prep.transformers, acc, fn xfmr, acc ->
        i = Map.fetch!(prep.bus_index, xfmr.from_bus_id)
        j = Map.fetch!(prep.bus_index, xfmr.to_bus_id)
        t = effective_tap_ratio(Map.get(xfmr, :tap_ratio))
        b_ij = 1.0 / (t * YBus.effective_reactance(xfmr.x_pu))
        add_branch_triplets(acc, i, j, b_ij, slack)
      end)

    factor(rows, cols, vals, prep.n - 1, %{matrix: :b_prime, negative_branches: negative})
  end

  defp add_branch_triplets({rows, cols, vals, negative}, i, j, b_ij, slack_idx) do
    negative = if b_ij < 0.0, do: negative + 1, else: negative

    case {i == slack_idx, j == slack_idx} do
      {true, true} ->
        {rows, cols, vals, negative}

      {true, false} ->
        rj = shift_past_slack(j, slack_idx)
        {[rj | rows], [rj | cols], [b_ij | vals], negative}

      {false, true} ->
        ri = shift_past_slack(i, slack_idx)
        {[ri | rows], [ri | cols], [b_ij | vals], negative}

      {false, false} ->
        ri = shift_past_slack(i, slack_idx)
        rj = shift_past_slack(j, slack_idx)

        {[ri, rj, ri, rj | rows], [ri, rj, rj, ri | cols], [b_ij, b_ij, -b_ij, -b_ij | vals],
         negative}
    end
  end

  defp shift_past_slack(i, slack_idx) when i < slack_idx, do: i
  defp shift_past_slack(i, _slack_idx), do: i - 1

  # B'' is -Im(Y_bus) over the PQ rows and columns, read off the assembled
  # Y-bus rather than re-derived from branch data: line charging, bus shunts
  # and off-nominal taps are already in those entries, and reading them here
  # is what keeps B'' and the mismatch evaluation describing one network.
  defp factor_b_double_prime(_prep, []), do: {:ok, nil}

  defp factor_b_double_prime(prep, pq_indices) do
    %{bd: bd, nbrs: nbrs} = prep.y_sparse
    pos = pq_indices |> Enum.with_index() |> Map.new()

    {rows, cols, vals} =
      Enum.reduce(pq_indices, {[], [], []}, fn i, acc ->
        ri = Map.fetch!(pos, i)
        {r, c, v} = acc
        acc = {[ri | r], [ri | c], [-elem(bd, i) | v]}

        Enum.reduce(elem(nbrs, i), acc, fn {j, _g, b}, {r, c, v} = unchanged ->
          case Map.get(pos, j) do
            nil -> unchanged
            rj -> {[ri | r], [rj | c], [-b | v]}
          end
        end)
      end)

    factor(rows, cols, vals, length(pq_indices), %{matrix: :b_double_prime})
  end

  defp factor(rows, cols, vals, size, context) do
    case Sparse.sparse_factor(rows, cols, vals, size) do
      {:ok, handle} -> {:ok, %{handle: handle, size: size, context: context}}
      {:error, reason} -> {:error, Map.put(context, :reason, reason)}
    end
  rescue
    # NIF unavailable, or native input validation raised.
    error -> {:error, Map.put(context, :reason, {:nif_unavailable, Exception.message(error)})}
  end

  # The soundness guard. A handle is not a promise: unpivoted LDL^T factors an
  # indefinite matrix happily, so every solve is checked against the residual
  # the NIF recomputes from the caller's own triplets.
  defp cached_solve(%{handle: handle}, rhs, label) do
    case Sparse.sparse_cached_solve(handle, rhs) do
      {:ok, x, residual} when residual <= @residual_tolerance ->
        {:ok, x}

      {:ok, _x, residual} ->
        {:error, %{matrix: label, reason: {:residual_too_large, residual}}}

      {:error, reason} ->
        {:error, %{matrix: label, reason: reason}}
    end
  rescue
    error -> {:error, %{matrix: label, reason: {:nif_unavailable, Exception.message(error)}}}
  end

  # ---------------------------------------------------------------------------
  # Failure handling — one summary line per island, never one per bus (DAT-20).
  # ---------------------------------------------------------------------------

  defp diverged_fallback(snapshot, opts, solution, iters, max_mis) do
    n = length(snapshot.buses)

    if n <= @dense_nr_fallback_max_buses do
      Logger.warning(
        "FDPF did not converge on a #{n}-bus island after #{iters} iterations " <>
          "(max mismatch #{inspect(max_mis)} pu); falling back to dense Newton-Raphson"
      )

      NewtonRaphson.solve(snapshot, dense_fallback_opts(opts))
    else
      Logger.warning(
        "FDPF did not converge on a #{n}-bus island after #{iters} iterations " <>
          "(max mismatch #{inspect(max_mis)} pu), which is too large for the dense " <>
          "Newton-Raphson fallback (max #{@dense_nr_fallback_max_buses} buses). " <>
          "Reporting an unconverged solution."
      )

      {:ok, solution}
    end
  end

  defp hard_failure(snapshot, opts, reason) do
    n = length(snapshot.buses)

    if n <= @dense_nr_fallback_max_buses do
      Logger.warning(
        "FDPF linear solve rejected on a #{n}-bus island (#{inspect(reason)}); " <>
          "falling back to dense Newton-Raphson"
      )

      NewtonRaphson.solve(snapshot, dense_fallback_opts(opts))
    else
      Logger.warning(
        "FDPF FAILED on a #{n}-bus island: linear solve rejected (#{inspect(reason)}), " <>
          "too large for the dense Newton-Raphson fallback " <>
          "(max #{@dense_nr_fallback_max_buses} buses). No voltages produced."
      )

      throw({:error, {:fdpf_linear_solve_failed, reason}})
    end
  end

  # The dense path gets a fresh iteration budget. `:max_iterations` here bounds
  # the fast-decoupled loop, and falling back precisely because that bound was
  # reached only to hand the same bound to a solver with different convergence
  # behaviour would make the fallback pointless. Newton-Raphson's own default
  # still caps it.
  defp dense_fallback_opts(opts), do: Keyword.delete(opts, :max_iterations)

  # `build_solution` is NewtonRaphson's and stamps the dense path by default,
  # so every solution this module assembles itself is re-stamped. Solutions
  # that came back FROM a fallback are deliberately left alone: `:dense_nr` on
  # an island above `@dense_nr_max_buses` is the record that FDPF failed there.
  defp stamp(solution), do: %{solution | solver: :fdpf}

  defp effective_tap_ratio(t) when is_number(t) and t > 0.0, do: t
  defp effective_tap_ratio(_), do: 1.0

  @doc "Island size at or below which `solve/2` hands off to dense Newton-Raphson."
  def dense_nr_max_buses, do: @dense_nr_max_buses

  @doc "Island size above which a failed FDPF has no dense fallback to retry with."
  def dense_nr_fallback_max_buses, do: @dense_nr_fallback_max_buses
end
