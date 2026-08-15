defmodule PowerModel.Solver.DCSparseAssemblyTest do
  @moduledoc """
  Covers ROADMAP item 18: B' is assembled as COO triplets and handed straight
  to the sparse LDL^T solver, and is never materialized as a dense
  (n-1) x (n-1) matrix on the way there.

  Three things are pinned down here:

    * the triplets really do encode the B' a person would write out by hand,
      including the slack row/column deletion and its index shift;
    * the assembly is O(branches), proven by solving a network far too large
      for a dense B' to fit in a bounded heap;
    * a branch with negative reactance — which costs B' its positive
      definiteness and so invalidates LDL^T's central assumption — produces a
      loud fallback or a loud failure, never a quiet wrong answer.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PowerModel.Solver.{DCPowerFlow, Solution, Sparse}

  @base_mva 100.0

  defp bus(id, bus_type \\ 1), do: %{id: id, bus_type: bus_type, base_kv: 138.0}

  defp line(id, from, to, x_pu) do
    %{id: id, from_bus_id: from, to_bus_id: to, x_pu: x_pu, rating_a_mva: 10_000.0}
  end

  defp gen(id, bus_id, p_max_mw) do
    %{id: id, bus_id: bus_id, p_max_mw: p_max_mw, capacity_factor: 1.0}
  end

  defp load(id, bus_id, p_mw), do: %{id: id, bus_id: bus_id, p_mw: p_mw}

  defp theta_of(solution, bus_id) do
    solution.bus_ids
    |> Enum.zip(solution.va_rad)
    |> Enum.find_value(fn {id, theta} -> if id == bus_id, do: theta end)
  end

  # ---------------------------------------------------------------------------
  # A four-bus network whose B' is small enough to write down by hand.
  #
  #   1 --0.10-- 2 --0.20-- 3 --0.25-- 4
  #              |                     |
  #              +-------- 0.50 -------+
  #
  # Susceptances b = 1/x: 10, 5, 4 and 2. Injections sum to exactly zero, which
  # makes the angle differences (and therefore every flow) independent of which
  # bus is chosen as the reference.
  # ---------------------------------------------------------------------------

  defp four_bus(slack_bus_id) do
    %{
      buses: Enum.map(1..4, fn id -> bus(id, if(id == slack_bus_id, do: 3, else: 1)) end),
      lines: [
        line(1, 1, 2, 0.10),
        line(2, 2, 3, 0.20),
        line(3, 3, 4, 0.25),
        line(4, 2, 4, 0.50)
      ],
      transformers: [],
      generators: [gen(1, 1, 200.0)],
      loads: [load(1, 2, 50.0), load(2, 3, 80.0), load(3, 4, 70.0)]
    }
  end

  # B with the slack row/column removed, written out by hand for slack = bus 1.
  #   B[2][2] = 10 + 5 + 2 = 17     B[2][3] = -5    B[2][4] = -2
  #   B[3][3] = 5 + 4      =  9     B[3][4] = -4
  #   B[4][4] = 4 + 2      =  6
  @b_prime_by_hand [
    [17.0, -5.0, -2.0],
    [-5.0, 9.0, -4.0],
    [-2.0, -4.0, 6.0]
  ]

  # P' in per unit on a 100 MVA base, slack (bus 1) row removed.
  @p_prime_by_hand [-0.5, -0.8, -0.7]

  describe "triplet assembly reproduces a hand-computed B'" do
    test "solved angles satisfy the hand-written B' theta = P' exactly" do
      solution = DCPowerFlow.solve(four_bus(1), base_mva: @base_mva)

      theta = Enum.map([2, 3, 4], &theta_of(solution, &1))

      # Reference bus really is the reference.
      assert_in_delta theta_of(solution, 1), 0.0, 1.0e-15

      # Multiply the hand-written B' through the solver's angles. This shares no
      # code with the assembly under test, so it fails if a triplet lands in the
      # wrong row, carries the wrong sign, or is dropped.
      residual =
        @b_prime_by_hand
        |> Enum.zip(@p_prime_by_hand)
        |> Enum.map(fn {row, p} ->
          abs(Enum.sum(Enum.zip_with(row, theta, &(&1 * &2))) - p)
        end)
        |> Enum.max()

      assert residual < 1.0e-12,
             "B' theta - P' = #{residual}, so the assembled matrix is not the hand-computed one"
    end

    test "the same triplets fed straight to the NIF give the same angles" do
      solution = DCPowerFlow.solve(four_bus(1), base_mva: @base_mva)

      {rows, cols, vals} =
        for {row, r} <- Enum.with_index(@b_prime_by_hand),
            {v, c} <- Enum.with_index(row),
            v != 0.0,
            reduce: {[], [], []} do
          {rs, cs, vs} -> {[r | rs], [c | cs], [v | vs]}
        end

      assert {:ok, theta, residual} =
               Sparse.sparse_solve_checked(rows, cols, vals, @p_prime_by_hand, 3)

      assert residual < 1.0e-12

      for {bus_id, expected} <- Enum.zip([2, 3, 4], theta) do
        assert_in_delta theta_of(solution, bus_id), expected, 1.0e-12
      end
    end

    test "flows match the hand-computed angle differences over reactance" do
      solution = DCPowerFlow.solve(four_bus(1), base_mva: @base_mva)

      for {branch_id, from, to, x} <- [
            {1, 1, 2, 0.10},
            {2, 2, 3, 0.20},
            {3, 3, 4, 0.25},
            {4, 2, 4, 0.50}
          ] do
        flow = Solution.line_flow(solution, :line, branch_id)
        expected = (theta_of(solution, from) - theta_of(solution, to)) / x * @base_mva
        assert_in_delta flow.p_flow_mw, expected, 1.0e-9
      end

      # The whole 200 MW of load is served across the single line out of bus 1.
      assert_in_delta Solution.line_flow(solution, :line, 1).p_flow_mw, 200.0, 1.0e-9
    end
  end

  describe "slack row/column deletion" do
    test "flows are identical wherever the slack sits in the bus ordering" do
      # Exercises the index shift: slack at index 0 leaves every other index
      # alone, while slack at index 2 shifts indices 3 and 4 down by one. An
      # off-by-one there silently corrupts B' without changing its size.
      first = DCPowerFlow.solve(four_bus(1), base_mva: @base_mva)
      middle = DCPowerFlow.solve(four_bus(3), base_mva: @base_mva)

      assert theta_of(middle, 3) == 0.0

      for branch_id <- 1..4 do
        a = Solution.line_flow(first, :line, branch_id).p_flow_mw
        b = Solution.line_flow(middle, :line, branch_id).p_flow_mw

        assert_in_delta a,
                        b,
                        1.0e-9,
                        "line #{branch_id} flow moved with the slack choice: #{a} vs #{b}"
      end
    end
  end

  describe "duplicate matrix positions" do
    test "parallel branches between one pair of buses sum into one entry" do
      # Two identical lines in parallel halve the angle difference relative to
      # one line. This also pins the case that breaks a bit-exact symmetry
      # test: the two off-diagonal positions accumulate their duplicates
      # independently and can disagree in the last bit.
      snapshot = %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2, 0.10), line(2, 1, 2, 0.10)],
        transformers: [],
        generators: [gen(1, 1, 100.0)],
        loads: [load(1, 2, 100.0)]
      }

      solution = DCPowerFlow.solve(snapshot, base_mva: @base_mva)

      # b_total = 10 + 10 = 20, P = -1.0 pu, so theta_2 = -1.0/20 = -0.05.
      assert_in_delta theta_of(solution, 2), -0.05, 1.0e-12

      for branch_id <- 1..2 do
        assert_in_delta Solution.line_flow(solution, :line, branch_id).p_flow_mw, 50.0, 1.0e-9
      end
    end

    test "a self-loop branch contributes nothing to B'" do
      # +b, +b, -b, -b all land on one diagonal position and must cancel.
      without = %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2, 0.10)],
        transformers: [],
        generators: [gen(1, 1, 100.0)],
        loads: [load(1, 2, 100.0)]
      }

      with_loop = %{without | lines: without.lines ++ [line(2, 2, 2, 0.10)]}

      assert_in_delta theta_of(DCPowerFlow.solve(with_loop, base_mva: @base_mva), 2),
                      theta_of(DCPowerFlow.solve(without, base_mva: @base_mva), 2),
                      1.0e-12
    end
  end

  describe "the dense B' path is gone" do
    @tag timeout: 120_000
    test "a 20k-bus network solves inside a heap far too small for a dense B'" do
      n = 20_000

      # A dense (n-1)^2 B' is 4.0e8 entries here — tens of gigabytes as an
      # Elixir term, and the old assembly built exactly that before extracting
      # triplets from it. Capping the solving process at 512 MiB makes this a
      # deterministic assertion rather than a timing one: the dense path cannot
      # pass, and the triplet path is not close to the ceiling.
      snapshot = %{
        buses: Enum.map(1..n, fn id -> bus(id, if(id == 1, do: 3, else: 1)) end),
        lines: Enum.map(1..(n - 1), fn id -> line(id, id, id + 1, 0.01) end),
        transformers: [],
        generators: [gen(1, 1, 1000.0)],
        loads: Enum.map(2..n, fn id -> load(id, id, 1000.0 / (n - 1)) end)
      }

      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          :erlang.process_flag(:max_heap_size, %{
            size: div(512 * 1024 * 1024, 8),
            kill: true,
            error_logger: false
          })

          solution = DCPowerFlow.solve(snapshot, base_mva: @base_mva)
          send(parent, {:solved, self(), theta_of(solution, n), solution.converged})
        end)

      receive do
        {:solved, ^pid, theta_last, converged} ->
          assert converged

          # Radial chain: bus k carries the load of every bus beyond it, so the
          # angle drop accumulates as a sum of partial loads.
          per_load_pu = 1000.0 / (n - 1) / @base_mva

          expected =
            -Enum.reduce(1..(n - 1), 0.0, fn k, acc -> acc + 0.01 * (n - k) * per_load_pu end)

          assert_in_delta theta_last, expected, 1.0e-6

        {:DOWN, ^ref, :process, ^pid, reason} ->
          flag =
            if reason == :killed,
              do:
                " — the solving process blew the 512 MiB heap cap, which is what a dense B' does",
              else: ""

          flunk("20k-bus DC solve did not complete: #{inspect(reason)}#{flag}")
      after
        90_000 -> flunk("20k-bus DC solve timed out")
      end
    end
  end

  describe "negative-reactance (non-SPD) guard" do
    test "a small indefinite B' falls back to dense LU and still solves correctly" do
      # Line 2-3 is series compensated: x < 0 survives the reactance floor with
      # its sign, so B' is symmetric but no longer positive definite. It is
      # still nonsingular, so there is a right answer to be had.
      snapshot = %{
        buses: [bus(1, 3), bus(2), bus(3)],
        lines: [
          line(1, 1, 2, 0.10),
          line(2, 2, 3, -0.50),
          line(3, 1, 3, 0.20)
        ],
        transformers: [],
        generators: [gen(1, 1, 100.0)],
        loads: [load(1, 2, 60.0), load(2, 3, 40.0)]
      }

      {solution, log} =
        with_log(fn -> DCPowerFlow.solve(snapshot, base_mva: @base_mva) end)

      assert log =~ "negative susceptance"
      assert log =~ "non-SPD"
      assert log =~ "dense LU fallback"

      # One summary line, never one per branch (DAT-20).
      assert length(String.split(String.trim(log), "\n")) == 1

      # b = 10, -2 and 5. B' over buses {2, 3}:
      #   [[10 + (-2), 2], [2, (-2) + 5]] = [[8, 2], [2, 3]]
      # P' = [-0.6, -0.4].
      b_prime = [[8.0, 2.0], [2.0, 3.0]]
      p_prime = [-0.6, -0.4]
      theta = [theta_of(solution, 2), theta_of(solution, 3)]

      residual =
        b_prime
        |> Enum.zip(p_prime)
        |> Enum.map(fn {row, p} ->
          abs(Enum.sum(Enum.zip_with(row, theta, &(&1 * &2))) - p)
        end)
        |> Enum.max()

      assert residual < 1.0e-12,
             "indefinite fallback returned angles that do not solve B' theta = P' (#{residual})"
    end

    test "an indefinite B' too large for the dense fallback fails loudly" do
      # 600 buses in a chain plus a detached pair joined by a negative-reactance
      # line. The detached block is singular, so no factorization can rescue it,
      # and at 601 x 601 the dense fallback is off the table. The one thing that
      # must not happen is a Solution full of quietly wrong angles.
      chain = 600

      snapshot = %{
        buses: Enum.map(1..(chain + 2), fn id -> bus(id, if(id == 1, do: 3, else: 1)) end),
        lines:
          Enum.map(1..(chain - 1), fn id -> line(id, id, id + 1, 0.01) end) ++
            [line(chain, chain + 1, chain + 2, -0.50)],
        transformers: [],
        generators: [gen(1, 1, 600.0)],
        loads: Enum.map(2..chain, fn id -> load(id, id, 1.0) end)
      }

      log =
        capture_log(fn ->
          assert catch_throw(DCPowerFlow.solve(snapshot, base_mva: @base_mva)) ==
                   {:error, :not_spd}
        end)

      assert log =~ "DC solve FAILED"
      assert log =~ "negative-susceptance"
      assert log =~ "No angles produced"
    end

    test "a large SPD system with no negative reactance is never routed to the guard" do
      n = 600

      snapshot = %{
        buses: Enum.map(1..n, fn id -> bus(id, if(id == 1, do: 3, else: 1)) end),
        lines: Enum.map(1..(n - 1), fn id -> line(id, id, id + 1, 0.01) end),
        transformers: [],
        generators: [gen(1, 1, 599.0)],
        loads: Enum.map(2..n, fn id -> load(id, id, 1.0) end)
      }

      {solution, log} =
        with_log(fn -> DCPowerFlow.solve(snapshot, base_mva: @base_mva) end)

      assert log == ""
      assert solution.converged

      # Flow on the first line is the entire 599 MW of downstream load.
      assert_in_delta Solution.line_flow(solution, :line, 1).p_flow_mw, 599.0, 1.0e-6
    end
  end

  describe "residual verification" do
    test "the NIF reports a residual that tracks solution quality" do
      # Well-conditioned SPD system: LDL^T should be essentially exact.
      assert {:ok, x, residual} =
               Sparse.sparse_solve_checked(
                 [0, 0, 1, 1],
                 [0, 1, 0, 1],
                 [4.0, -1.0, -1.0, 4.0],
                 [1.0, 2.0],
                 2
               )

      assert residual < 1.0e-14
      assert_in_delta Enum.at(x, 0), 6.0 / 15.0, 1.0e-12
      assert_in_delta Enum.at(x, 1), 9.0 / 15.0, 1.0e-12
    end

    test "a singular system is rejected rather than answered" do
      assert {:error, :factorization_failed} =
               Sparse.sparse_solve_checked(
                 [0, 0, 1, 1],
                 [0, 1, 0, 1],
                 [1.0, -1.0, -1.0, 1.0],
                 [1.0, 1.0],
                 2
               )
    end

    test "an indefinite but nonsingular system is accepted on its verified residual" do
      # [[1, 2], [2, 1]] has eigenvalues 3 and -1, so it is symmetric but not
      # positive definite. Unpivoted LDL^T still lands on the right answer here,
      # and the residual is what proves it — refusing outright would throw away
      # a correct solve.
      assert {:ok, x, residual} =
               Sparse.sparse_solve_checked(
                 [0, 0, 1, 1],
                 [0, 1, 0, 1],
                 [1.0, 2.0, 2.0, 1.0],
                 [1.0, 1.0],
                 2
               )

      assert residual < 1.0e-12
      assert_in_delta Enum.at(x, 0), 1.0 / 3.0, 1.0e-12
      assert_in_delta Enum.at(x, 1), 1.0 / 3.0, 1.0e-12
    end

    test "a 1x1 system solves instead of panicking the NIF" do
      # Two-bus islands reduce to exactly this, and sprs-ldl asserts n > 1.
      assert {:ok, [x], residual} = Sparse.sparse_solve_checked([0], [0], [10.0], [2.5], 1)
      assert_in_delta x, 0.25, 1.0e-15
      assert residual == 0.0

      assert {:error, :factorization_failed} =
               Sparse.sparse_solve_checked([0], [0], [0.0], [2.5], 1)
    end

    test "a two-bus island solves without falling back" do
      snapshot = %{
        buses: [bus(1, 3), bus(2)],
        lines: [line(1, 1, 2, 0.10)],
        transformers: [],
        generators: [gen(1, 1, 100.0)],
        loads: [load(1, 2, 100.0)]
      }

      {solution, log} =
        with_log(fn -> DCPowerFlow.solve(snapshot, base_mva: @base_mva) end)

      assert log == ""
      assert_in_delta theta_of(solution, 2), -0.10, 1.0e-12
      assert_in_delta Solution.line_flow(solution, :line, 1).p_flow_mw, 100.0, 1.0e-9
    end
  end

  # ---------------------------------------------------------------------------
  # Factor once, solve many. Wave 2 (fast-decoupled AC) and PTDF/LODF screening
  # both hold one matrix fixed across many right-hand sides.
  # ---------------------------------------------------------------------------

  describe "cached factorization" do
    # [[4, -1], [-1, 4]], symmetric positive definite.
    defp spd_2x2, do: {[0, 0, 1, 1], [0, 1, 0, 1], [4.0, -1.0, -1.0, 4.0]}

    test "a cached solve returns exactly what the one-shot call returns" do
      {r, c, v} = spd_2x2()
      rhs = [1.0, 2.0]

      assert {:ok, one_shot, _} = Sparse.sparse_solve_checked(r, c, v, rhs, 2)
      assert {:ok, handle} = Sparse.sparse_factor(r, c, v, 2)
      assert {:ok, cached, residual} = Sparse.sparse_cached_solve(handle, rhs)

      # Same factorization policy on both paths, so this is equality, not
      # approximate agreement. Any drift between the two means they have
      # diverged on ordering or the symmetry setting.
      assert cached == one_shot
      assert residual < 1.0e-14
    end

    test "one handle serves many different right-hand sides" do
      {r, c, v} = spd_2x2()
      assert {:ok, handle} = Sparse.sparse_factor(r, c, v, 2)

      for {rhs, expected} <- [
            {[1.0, 2.0], [0.4, 0.6]},
            {[0.0, 15.0], [1.0, 4.0]},
            {[15.0, 0.0], [4.0, 1.0]}
          ] do
        assert {:ok, x, _} = Sparse.sparse_cached_solve(handle, rhs)

        for {got, want} <- Enum.zip(x, expected) do
          assert_in_delta got, want, 1.0e-12
        end
      end
    end

    test "a batch solve agrees with the same solves done one at a time" do
      {r, c, v} = spd_2x2()
      batch = [[1.0, 2.0], [0.0, 15.0], [15.0, 0.0]]

      assert {:ok, handle} = Sparse.sparse_factor(r, c, v, 2)
      assert {:ok, solutions, worst} = Sparse.sparse_cached_solve_multi(handle, batch)

      assert length(solutions) == 3
      assert worst < 1.0e-14

      individually =
        Enum.map(batch, fn rhs ->
          {:ok, x, _} = Sparse.sparse_cached_solve(handle, rhs)
          x
        end)

      assert solutions == individually
    end

    test "the reported residual is the worst in the batch" do
      {r, c, v} = spd_2x2()
      assert {:ok, handle} = Sparse.sparse_factor(r, c, v, 2)

      residuals =
        for rhs <- [[1.0, 2.0], [0.0, 15.0], [15.0, 0.0]] do
          {:ok, _, residual} = Sparse.sparse_cached_solve(handle, rhs)
          residual
        end

      assert {:ok, _, worst} =
               Sparse.sparse_cached_solve_multi(handle, [[1.0, 2.0], [0.0, 15.0], [15.0, 0.0]])

      assert worst == Enum.max(residuals)
    end

    test "a 1x1 system factors and solves through the cached path too" do
      assert {:ok, handle} = Sparse.sparse_factor([0], [0], [10.0], 1)
      assert {:ok, [x], residual} = Sparse.sparse_cached_solve(handle, [2.5])
      assert_in_delta x, 0.25, 1.0e-15
      assert residual == 0.0
    end

    test "a singular matrix is refused at factor time" do
      # [[1, -1], [-1, 1]] — zero pivot, no handle to hand out.
      assert {:error, :factorization_failed} =
               Sparse.sparse_factor([0, 0, 1, 1], [0, 1, 0, 1], [1.0, -1.0, -1.0, 1.0], 2)

      assert {:error, :factorization_failed} = Sparse.sparse_factor([0], [0], [0.0], 1)
    end

    test "an indefinite matrix factors, and the residual is what vouches for it" do
      # [[1, 2], [2, 1]] is symmetric but indefinite (eigenvalues 3 and -1).
      # Unpivoted LDL^T factors it without complaint, so `sparse_factor/4`
      # succeeding proves nothing about the answer — only the per-solve
      # residual does. This is the contract Wave 2 has to honour.
      assert {:ok, handle} =
               Sparse.sparse_factor([0, 0, 1, 1], [0, 1, 0, 1], [1.0, 2.0, 2.0, 1.0], 2)

      assert {:ok, x, residual} = Sparse.sparse_cached_solve(handle, [1.0, 1.0])
      assert residual < 1.0e-12
      assert_in_delta Enum.at(x, 0), 1.0 / 3.0, 1.0e-12
      assert_in_delta Enum.at(x, 1), 1.0 / 3.0, 1.0e-12
    end

    test "a right-hand side of the wrong length is refused, not padded" do
      # Rustler returns `Error::Term` as an `{:error, message}` value rather
      # than raising, so a caller that only matches `{:ok, ...}` gets a
      # CaseClauseError instead of silently solving a truncated system.
      {r, c, v} = spd_2x2()
      assert {:ok, handle} = Sparse.sparse_factor(r, c, v, 2)

      assert {:error, short} = Sparse.sparse_cached_solve(handle, [1.0])
      assert short =~ "does not equal factored matrix dimension 2"

      assert {:error, long} = Sparse.sparse_cached_solve(handle, [1.0, 2.0, 3.0])
      assert long =~ "does not equal factored matrix dimension 2"

      assert {:error, batch} = Sparse.sparse_cached_solve_multi(handle, [[1.0, 2.0], [1.0]])
      assert batch =~ "rhs_list[1]"
    end

    test "a handle outlives the data it was built from and survives GC" do
      # The factors live in the resource, not in any Elixir term. If the handle
      # only worked while the caller happened to hold the triplets alive, a
      # long-running fast-decoupled solve would break in a way no small test
      # would catch.
      handle =
        (fn ->
           {r, c, v} = spd_2x2()
           {:ok, h} = Sparse.sparse_factor(r, c, v, 2)
           h
         end).()

      :erlang.garbage_collect()

      assert {:ok, x, _} = Sparse.sparse_cached_solve(handle, [1.0, 2.0])
      assert_in_delta Enum.at(x, 0), 0.4, 1.0e-12
    end

    test "one handle is safe to solve against concurrently" do
      # The resource is immutable and `solve` allocates its own working vector,
      # which is what makes it sound to share a handle across schedulers.
      {r, c, v} = spd_2x2()
      assert {:ok, handle} = Sparse.sparse_factor(r, c, v, 2)

      results =
        1..50
        |> Task.async_stream(fn k ->
          rhs = [k * 1.0, k * 2.0]
          {:ok, x, _} = Sparse.sparse_cached_solve(handle, rhs)
          {k, x}
        end)
        |> Enum.map(fn {:ok, result} -> result end)

      for {k, [x1, x2]} <- results do
        assert_in_delta x1, 0.4 * k, 1.0e-12
        assert_in_delta x2, 0.6 * k, 1.0e-12
      end
    end
  end
end
