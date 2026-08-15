defmodule PowerModel.Solver.DCPowerFlow do
  @moduledoc """
  DC Power Flow approximation.
  Assumes V=1.0 pu, lossless lines. Solves P = B' * theta.
  Target: <50ms per interconnection.

  ## Scale

  B' is assembled directly as COO triplets and factorized by sparse LDL^T in
  the Rust NIF; it is never built as a dense matrix. That is what makes the
  Eastern interconnection solvable at all — a dense (n-1)x(n-1) B' there is
  2.7e9 entries, hundreds of gigabytes as an Elixir term, where the triplet
  form is ~259k entries.

  Dense LU survives only as a fallback for systems small enough to materialize,
  and it exists because LDL^T assumes B' is positive definite. A
  series-compensated branch keeps its negative reactance through
  `YBus.effective_reactance/1` and can cost B' that property, so every sparse
  solve is residual-verified natively and an unverified result is never
  returned as a `Solution`.

  ## DC ties

  A snapshot may carry `:dc_ties` (`PowerModel.Grid.DcTie`). These are NOT
  branches: an HVDC link's flow is set by its converter controls, not by a
  series impedance, so it never enters B'. Each tie contributes a fixed
  injection at whichever of its terminals is in this snapshot — `+schedule_mw`
  at `from_bus`, `-schedule_mw` at `to_bus` — and a terminal outside the
  snapshot simply contributes nothing. A tie with both terminals inside one
  island moves power between two of its buses and changes the island's total
  by zero.

  Tie power is a TRANSFER, not generation or load: `total_gen_mw` is the power
  injected into the AC network (generators plus net tie imports) and stays
  equal to `total_load_mw`, so the lossless-DC conservation identity holds
  unchanged. `scheduled_gen_mw` remains pure generator scheduling, and
  `mismatch_mw` is the gap the slack bus has to cover after both generators
  and ties are counted.
  """

  alias PowerModel.Grid.{DcTie, Ratings}
  alias PowerModel.Solver.{Partition, Solution, Sparse, YBus}

  require Logger

  defstruct [:bus_ids, :bus_index_map, :b_prime, :slack_idx, :p_inject, :base_mva]

  @doc """
  Solve a snapshot that may contain several electrically separate islands
  (e.g. the Eastern, Western, and ERCOT interconnections).

  Each island is solved independently — flows and slack balancing never
  couple across asynchronous boundaries — and the per-island solutions are
  merged into one `Solution`. Islands without generation are dead
  (blacked out): their buses and load are excluded from the solve but
  surfaced on the merged solution as `dead_load_mw` / `dead_bus_count` so
  unserved load never silently vanishes from the totals. A snapshot with no
  solvable island at all yields `converged: false`.
  """
  def solve_islands(snapshot, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    {subs, dead} = Partition.split(snapshot)

    dead_buses = Enum.reduce(dead, MapSet.new(), &MapSet.union(&2, &1))

    dead_load_mw =
      snapshot.loads
      |> Enum.filter(&MapSet.member?(dead_buses, &1.bus_id))
      |> Enum.reduce(0.0, fn load, acc -> acc + (load.p_mw || 0.0) end)

    merged =
      subs
      |> Enum.map(&solve(&1, opts))
      |> Partition.merge_solutions(base_mva)

    %{merged | dead_load_mw: dead_load_mw, dead_bus_count: MapSet.size(dead_buses)}
  end

  @doc """
  Solve DC power flow for given grid snapshot.
  Returns %Solution{} with voltage angles and line flows.
  """
  def solve(snapshot, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    buses = snapshot.buses
    lines = snapshot.lines
    transformers = snapshot.transformers
    generators = snapshot.generators
    loads = snapshot.loads
    dc_ties = Map.get(snapshot, :dc_ties, [])

    n = length(buses)
    if n == 0, do: throw({:error, :empty_grid})

    bus_index = buses |> Enum.with_index() |> Map.new(fn {b, i} -> {b.id, i} end)

    # Duplicate bus ids silently shrink the index map relative to the bus
    # list, corrupting matrix sizing and injections. Fail loudly instead.
    if map_size(bus_index) != n do
      raise ArgumentError,
            "snapshot contains duplicate bus ids: #{n} buses but only " <>
              "#{map_size(bus_index)} distinct ids"
    end

    bus_ids = Enum.map(buses, & &1.id)

    # Find slack bus (type 3, or largest generator)
    slack_idx = find_slack_index(buses, generators, bus_index)

    totals = compute_totals(generators, loads, dc_ties, bus_index, slack_idx, bus_ids)

    # Solve: theta = B'^-1 * P (excluding slack row/col)
    non_slack_size = n - 1

    if non_slack_size == 0 do
      Solution.new(bus_ids, List.duplicate(1.0, n), List.duplicate(0.0, n), %{}, base_mva, totals)
    else
      # Build B' in triplet form (n-1 x n-1, slack row/col dropped at emission)
      system =
        assemble_system(
          lines,
          transformers,
          generators,
          loads,
          dc_ties,
          bus_index,
          slack_idx,
          n,
          base_mva
        )

      theta = solve_system(system)

      # Insert slack angle (0.0) back
      theta_full = insert_at(theta, slack_idx, 0.0)

      # Convert to array for O(1) access in line flow computation
      theta_arr = :array.from_list(theta_full)

      # Compute line flows
      line_flows = compute_line_flows(lines, transformers, theta_arr, bus_index, base_mva)

      audit_slack_flows(line_flows, totals, bus_ids, slack_idx)

      vm = List.duplicate(1.0, n)
      Solution.new(bus_ids, vm, theta_full, line_flows, base_mva, totals)
    end
  end

  # DC identities: the network is lossless, so power injected into the island
  # equals served load, with the slack bus producing whatever the scheduled
  # (non-slack) generation and the DC ties do not cover. The gap between those
  # scheduled sources and load is reported as mismatch_mw so silent slack
  # pickup is visible to monitoring.
  #
  # DC-tie power is a transfer: it is neither generation nor load, so it is
  # folded into total_gen_mw (power injected into the AC network) but kept out
  # of scheduled_gen_mw (what the generator fleet was told to produce).
  defp compute_totals(generators, loads, dc_ties, bus_index, slack_idx, bus_ids) do
    slack_bus_id = Enum.at(bus_ids, slack_idx)
    {net_tie_mw, tie_at_slack_mw} = tie_totals(dc_ties, bus_index, slack_bus_id)

    {scheduled_gen_mw, gen_at_slack_mw} =
      Enum.reduce(generators, {0.0, 0.0}, fn gen, {total, at_slack} ->
        p = gen.p_max_mw * (Map.get(gen, :capacity_factor) || 1.0)

        at_slack =
          if Map.fetch!(bus_index, gen.bus_id) == slack_idx, do: at_slack + p, else: at_slack

        {total + p, at_slack}
      end)

    {total_load_mw, load_at_slack_mw} =
      Enum.reduce(loads, {0.0, 0.0}, fn load, {total, at_slack} ->
        at_slack =
          if Map.fetch!(bus_index, load.bus_id) == slack_idx,
            do: at_slack + load.p_mw,
            else: at_slack

        {total + load.p_mw, at_slack}
      end)

    slack_gen_mw = total_load_mw - net_tie_mw - (scheduled_gen_mw - gen_at_slack_mw)

    [
      total_gen_mw: total_load_mw,
      total_load_mw: total_load_mw,
      total_loss_mw: 0.0,
      scheduled_gen_mw: scheduled_gen_mw,
      slack_bus_id: slack_bus_id,
      slack_injection_mw: slack_gen_mw + tie_at_slack_mw - load_at_slack_mw,
      mismatch_mw: total_load_mw - net_tie_mw - scheduled_gen_mw
    ]
  end

  # `{net injection into this snapshot, injection at the slack bus}`, in MW.
  # The overwhelmingly common case is no ties at all, which must not pay for
  # building a bus-id set on every solve.
  defp tie_totals([], _bus_index, _slack_bus_id), do: {0.0, 0.0}

  defp tie_totals(dc_ties, bus_index, slack_bus_id) do
    in_snapshot = MapSet.new(Map.keys(bus_index))

    tie_at_slack_mw =
      Enum.reduce(dc_ties, 0.0, fn tie, acc -> acc + DcTie.injection_at(tie, slack_bus_id) end)

    {DcTie.net_injection_mw(dc_ties, in_snapshot), tie_at_slack_mw}
  end

  # Invariant: net flow leaving the slack bus must equal its net injection.
  # A violation means the linear solve returned garbage (singular/ill-conditioned
  # system) that would otherwise pass silently.
  defp audit_slack_flows(line_flows, totals, bus_ids, slack_idx) do
    slack_bus_id = Enum.at(bus_ids, slack_idx)
    slack_injection_mw = Keyword.fetch!(totals, :slack_injection_mw)
    total_load_mw = Keyword.fetch!(totals, :total_load_mw)

    net_flow =
      Enum.reduce(line_flows, 0.0, fn {_key, flow}, acc ->
        cond do
          flow.from_bus_id == slack_bus_id -> acc + flow.p_flow_mw
          flow.to_bus_id == slack_bus_id -> acc - flow.p_flow_mw
          true -> acc
        end
      end)

    tolerance = max(1.0, 1.0e-4 * abs(total_load_mw))

    if abs(net_flow - slack_injection_mw) > tolerance do
      Logger.warning(
        "DC solve failed slack-balance audit: slack bus #{slack_bus_id} " <>
          "injection #{Float.round(slack_injection_mw, 2)} MW vs " <>
          "net outgoing flow #{Float.round(net_flow, 2)} MW"
      )
    end

    :ok
  end

  defp find_slack_index(buses, generators, bus_index) do
    # Look for explicit slack bus
    case Enum.find(buses, &(&1.bus_type == 3)) do
      nil ->
        # Use bus with largest generator
        gen_by_bus = Enum.group_by(generators, & &1.bus_id)

        {max_bus_id, _} =
          Enum.max_by(
            gen_by_bus,
            fn {_id, gens} ->
              Enum.sum(Enum.map(gens, & &1.p_max_mw))
            end,
            fn -> {hd(buses).id, []} end
          )

        Map.fetch!(bus_index, max_bus_id)

      slack ->
        Map.fetch!(bus_index, slack.id)
    end
  end

  # ---------------------------------------------------------------------------
  # B' assembly
  #
  # B' is built as COO triplets and is never materialized densely. Each branch
  # contributes exactly four entries, so assembly is O(branches) rather than the
  # O(buses^2) a dense (n-1)x(n-1) array costs. On the Eastern interconnection
  # (51.7k buses, 64.7k branches) that is ~259k triplets against 2.7e9 dense
  # entries, which is why Eastern could not previously be solved at all.
  #
  # Duplicate (row, col) pairs are summed when the solver builds its CSC matrix,
  # so parallel branches need no consolidation pass here. They do mean the two
  # off-diagonal positions of a bus pair accumulate independently and can end up
  # a bit apart, which is why the native side does not demand bit-exact symmetry
  # — see `Sparse.sparse_solve_checked/5`.
  #
  # The slack row and column are dropped at emission time: a bus index past the
  # slack shifts down by one, and any entry touching the slack is simply not
  # emitted. That is the same B' the dense path produced by slicing.
  # ---------------------------------------------------------------------------

  defp assemble_system(
         lines,
         transformers,
         generators,
         loads,
         dc_ties,
         bus_index,
         slack_idx,
         n,
         base_mva
       ) do
    {rows, cols, vals, negative_branches} =
      b_prime_triplets(lines, transformers, bus_index, slack_idx)

    %{
      rows: rows,
      cols: cols,
      vals: vals,
      p: injection_vector(generators, loads, dc_ties, bus_index, slack_idx, n, base_mva),
      size: n - 1,
      negative_branches: negative_branches
    }
  end

  defp b_prime_triplets(lines, transformers, bus_index, slack_idx) do
    acc =
      Enum.reduce(lines, {[], [], [], 0}, fn line, acc ->
        i = Map.fetch!(bus_index, line.from_bus_id)
        j = Map.fetch!(bus_index, line.to_bus_id)
        b_ij = 1.0 / YBus.effective_reactance(line.x_pu)
        add_branch_triplets(acc, i, j, b_ij, slack_idx)
      end)

    Enum.reduce(transformers, acc, fn xfmr, acc ->
      i = Map.fetch!(bus_index, xfmr.from_bus_id)
      j = Map.fetch!(bus_index, xfmr.to_bus_id)
      t = effective_tap_ratio(Map.get(xfmr, :tap_ratio))
      b_ij = 1.0 / (t * YBus.effective_reactance(xfmr.x_pu))
      add_branch_triplets(acc, i, j, b_ij, slack_idx)
    end)
  end

  # The four entries a branch of susceptance b between buses i and j puts into
  # B': +b on both diagonals, -b on both off-diagonals. Anything in the slack
  # row or column is dropped rather than emitted, which is how the slack is
  # eliminated without ever slicing a matrix.
  #
  # A self-loop at a non-slack bus lands all four entries on one diagonal
  # position, where +b, +b, -b, -b cancel — a branch from a bus to itself
  # carries no flow and must not stiffen the diagonal. The dense accumulation
  # did the same thing.
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

  defp injection_vector(generators, loads, dc_ties, bus_index, slack_idx, n, base_mva) do
    # Power injection vector (P_gen - P_load) in per unit
    p_full = :array.new(n, default: 0.0)

    p_full =
      Enum.reduce(generators, p_full, fn gen, p ->
        idx = Map.fetch!(bus_index, gen.bus_id)
        p_pu = gen.p_max_mw * (Map.get(gen, :capacity_factor) || 1.0) / base_mva
        array_add(p, idx, p_pu)
      end)

    p_full =
      Enum.reduce(loads, p_full, fn load, p ->
        idx = Map.fetch!(bus_index, load.bus_id)
        p_pu = load.p_mw / base_mva
        array_add(p, idx, -p_pu)
      end)

    # DC ties are scheduled injections, never branches: +schedule at from_bus,
    # -schedule at to_bus. A terminal outside this snapshot is skipped rather
    # than raising, which is what makes a tie into an unmodeled system (or into
    # a different island) behave as a one-sided import or export.
    p_full =
      Enum.reduce(dc_ties, p_full, fn tie, p ->
        schedule_pu = DcTie.scheduled_mw(tie) / base_mva

        p
        |> add_at_bus(bus_index, Map.get(tie, :from_bus_id), schedule_pu)
        |> add_at_bus(bus_index, Map.get(tie, :to_bus_id), -schedule_pu)
      end)

    # Drop the slack entry to form P'
    for i <- 0..(n - 1), i != slack_idx, do: :array.get(i, p_full)
  end

  # ---------------------------------------------------------------------------
  # Solving
  #
  # Sparse LDL^T is the only assembly-fed path. Dense LU survives strictly as a
  # fallback for systems small enough to materialize, because B' is only
  # symmetric *positive definite* when every branch susceptance is positive.
  # A series-compensated branch keeps its negative reactance through
  # `YBus.effective_reactance/1`, and `sprs-ldl` does not pivot: an indefinite
  # B' factorizes without complaint and can return numerical garbage. Every
  # sparse solve is therefore residual-verified natively (see
  # `Sparse.sparse_solve_checked/5`) and an unverified result is never returned.
  # ---------------------------------------------------------------------------

  # Above this the dense fallback is itself an O(size^2) blowup and refusing is
  # the honest answer. 500x500 is ~2 MB and solves in milliseconds.
  @dense_fallback_max 500

  # A healthy DC solve lands near 1.0e-12 relative; 1.0e-6 leaves room for
  # badly-scaled but genuinely-solved systems without admitting garbage.
  @residual_tolerance 1.0e-6

  defp solve_system(%{negative_branches: negative, size: size} = system)
       when negative > 0 and size <= @dense_fallback_max do
    # Known-indefinite and small enough to solve properly: skip LDL^T entirely
    # and use dense LU with partial pivoting, which is the right factorization
    # for an indefinite system.
    Logger.warning(
      "DC solve: #{negative} branch(es) with negative susceptance make B' " <>
        "non-SPD; using dense LU fallback for #{size}x#{size} system"
    )

    solve_dense_system(system)
  end

  defp solve_system(system) do
    case verified_sparse_solve(system) do
      {:ok, theta} -> theta
      {:error, reason} -> sparse_fallback(system, reason)
    end
  end

  defp verified_sparse_solve(%{rows: rows, cols: cols, vals: vals, p: p, size: size}) do
    case Sparse.sparse_solve_checked(rows, cols, vals, p, size) do
      {:ok, theta, residual} when residual <= @residual_tolerance -> {:ok, theta}
      {:ok, _theta, residual} -> {:error, {:residual_too_large, residual}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # NIF unavailable, or the native input validation raised.
    error -> {:error, {:nif_unavailable, Exception.message(error)}}
  end

  # One summary line, never one per branch: the OTP logger drops most of a
  # warning burst under load, so the count has to be carried in a single
  # message (DAT-20).
  defp sparse_fallback(%{size: size, negative_branches: negative} = system, reason)
       when size <= @dense_fallback_max do
    Logger.warning(
      "DC solve: sparse LDL^T rejected (#{inspect(reason)}) on #{size}x#{size} " <>
        "system with #{negative} negative-susceptance branch(es); " <>
        "falling back to dense LU"
    )

    solve_dense_system(system)
  end

  defp sparse_fallback(%{size: size, negative_branches: negative}, reason) do
    Logger.warning(
      "DC solve FAILED: sparse LDL^T rejected (#{inspect(reason)}) on " <>
        "#{size}x#{size} system with #{negative} negative-susceptance " <>
        "branch(es), which is too large for the dense fallback " <>
        "(max #{@dense_fallback_max}). No angles produced."
    )

    if negative > 0 do
      throw({:error, :not_spd})
    else
      throw({:error, :singular_matrix})
    end
  end

  # The only place a dense B' is ever materialized, and only at sizes where
  # size^2 is harmless.
  defp densify(%{rows: rows, cols: cols, vals: vals, size: size}) do
    flat =
      [rows, cols, vals]
      |> Enum.zip()
      |> Enum.reduce(:array.new(size * size, default: 0.0), fn {r, c, v}, acc ->
        array_add(acc, r * size + c, v)
      end)

    for r <- 0..(size - 1) do
      for c <- 0..(size - 1), do: :array.get(r * size + c, flat)
    end
  end

  defp solve_dense_system(%{p: p_inject, size: size} = system) do
    b_matrix = densify(system)

    try do
      case Sparse.lu_factorize(b_matrix, size) do
        {:ok, l, u, perm} ->
          case Sparse.lu_solve(l, u, perm, p_inject) do
            {:ok, x} -> x
            _ -> nx_or_gaussian_solve(b_matrix, p_inject, size)
          end

        _ ->
          nx_or_gaussian_solve(b_matrix, p_inject, size)
      end
    rescue
      _ -> nx_or_gaussian_solve(b_matrix, p_inject, size)
    end
  end

  defp nx_or_gaussian_solve(b_matrix, p_inject, size) do
    try do
      Sparse.solve_dense(b_matrix, p_inject)
    rescue
      _ -> gaussian_solve(b_matrix, p_inject, size)
    end
  end

  # Last-resort pure-Elixir O(n^3) elimination. Unbounded it takes ~21 s at
  # 300 buses and hours at grid scale inside a GenServer call, so it is capped:
  # beyond @gaussian_fallback_max the solve errors out and the caller's
  # fallback chain surfaces the failure instead of hanging the system.
  @gaussian_fallback_max 500

  @doc false
  def gaussian_solve(_a, _b, n) when n > @gaussian_fallback_max do
    throw({:error, {:gaussian_fallback_too_large, n}})
  end

  def gaussian_solve(a, b, 1) do
    # Single-equation system: the elimination ranges below assume n >= 2
    [[a11]] = a
    [b1] = b
    if abs(a11) < 1.0e-12, do: throw({:error, :singular_matrix})
    [b1 / a11]
  end

  def gaussian_solve(a, b, n) do
    # Augmented matrix — each row stored as an :array for O(1) access
    aug =
      a
      |> Enum.zip(b)
      |> Enum.map(fn {row, bi} -> :array.from_list(row ++ [bi]) end)
      |> :array.from_list()

    # Forward elimination with partial pivoting
    aug =
      Enum.reduce(0..(n - 2), aug, fn k, aug ->
        # Find pivot
        {max_val, max_row} =
          Enum.reduce(k..(n - 1), {abs(arr_get(aug, k, k)), k}, fn i, {mv, mr} ->
            v = abs(arr_get(aug, i, k))
            if v > mv, do: {v, i}, else: {mv, mr}
          end)

        if max_val < 1.0e-12, do: throw({:error, :singular_matrix})

        # Swap rows
        aug =
          if max_row != k do
            row_k = :array.get(k, aug)
            row_m = :array.get(max_row, aug)
            aug |> :array.set(k, row_m) |> :array.set(max_row, row_k)
          else
            aug
          end

        # Eliminate
        Enum.reduce((k + 1)..(n - 1), aug, fn i, aug ->
          factor = arr_get(aug, i, k) / arr_get(aug, k, k)
          row_i = :array.get(i, aug)
          row_k = :array.get(k, aug)

          new_row =
            :array.from_list(
              for col <- 0..n do
                :array.get(col, row_i) - factor * :array.get(col, row_k)
              end
            )

          :array.set(i, new_row, aug)
        end)
      end)

    # Back substitution
    x = :array.new(n, default: 0.0)

    Enum.reduce((n - 1)..0//-1, x, fn i, x ->
      row = :array.get(i, aug)

      sum =
        Enum.reduce((i + 1)..(n - 1)//1, 0.0, fn j, acc ->
          acc + :array.get(j, row) * :array.get(j, x)
        end)

      diag = :array.get(i, row)
      if abs(diag) < 1.0e-12, do: throw({:error, :singular_matrix})

      val = (:array.get(n, row) - sum) / diag
      :array.set(i, val, x)
    end)
    |> :array.to_list()
  end

  defp arr_get(aug, row, col) do
    :array.get(col, :array.get(row, aug))
  end

  defp compute_line_flows(lines, transformers, theta_arr, bus_index, base_mva) do
    line_flows =
      Enum.map(lines, fn line ->
        i = Map.fetch!(bus_index, line.from_bus_id)
        j = Map.fetch!(bus_index, line.to_bus_id)
        x = YBus.effective_reactance(line.x_pu)
        theta_i = :array.get(i, theta_arr)
        theta_j = :array.get(j, theta_arr)
        flow_pu = (theta_i - theta_j) / x
        flow_mw = flow_pu * base_mva

        {rate_a, rate_b, rate_c} = Ratings.branch_ratings(line)

        {{:line, line.id},
         %{
           from_bus_id: line.from_bus_id,
           to_bus_id: line.to_bus_id,
           p_flow_mw: flow_mw,
           rating_mva: rate_a,
           rating_b_mva: rate_b,
           rating_c_mva: rate_c,
           loading_pct: Ratings.loading_pct(flow_mw, rate_a),
           emergency_loading_pct: Ratings.loading_pct(flow_mw, rate_b),
           trip_loading_pct: Ratings.loading_pct(flow_mw, rate_c),
           overloaded: is_number(rate_a) and abs(flow_mw) > rate_a
         }}
      end)

    xfmr_flows =
      Enum.map(transformers, fn xfmr ->
        i = Map.fetch!(bus_index, xfmr.from_bus_id)
        j = Map.fetch!(bus_index, xfmr.to_bus_id)

        x =
          effective_tap_ratio(Map.get(xfmr, :tap_ratio)) *
            YBus.effective_reactance(xfmr.x_pu)

        theta_i = :array.get(i, theta_arr)
        theta_j = :array.get(j, theta_arr)
        flow_pu = (theta_i - theta_j) / x
        flow_mw = flow_pu * base_mva

        {rate_a, rate_b, rate_c} = Ratings.branch_ratings(xfmr)

        {{:transformer, xfmr.id},
         %{
           from_bus_id: xfmr.from_bus_id,
           to_bus_id: xfmr.to_bus_id,
           p_flow_mw: flow_mw,
           rating_mva: rate_a,
           rating_b_mva: rate_b,
           rating_c_mva: rate_c,
           loading_pct: Ratings.loading_pct(flow_mw, rate_a),
           emergency_loading_pct: Ratings.loading_pct(flow_mw, rate_b),
           trip_loading_pct: Ratings.loading_pct(flow_mw, rate_c),
           overloaded: is_number(rate_a) and abs(flow_mw) > rate_a
         }}
      end)

    Map.new(line_flows ++ xfmr_flows)
  end

  defp insert_at(list, idx, val) do
    {before, after_} = Enum.split(list, idx)
    before ++ [val] ++ after_
  end

  defp effective_tap_ratio(t) when is_number(t) and t > 0.0, do: t
  defp effective_tap_ratio(_), do: 1.0

  defp array_add(arr, idx, val) do
    :array.set(idx, :array.get(idx, arr) + val, arr)
  end

  # Add an injection at a bus that may be absent from this snapshot (or nil).
  defp add_at_bus(arr, _bus_index, nil, _val), do: arr

  defp add_at_bus(arr, bus_index, bus_id, val) do
    case Map.get(bus_index, bus_id) do
      nil -> arr
      idx -> array_add(arr, idx, val)
    end
  end
end
