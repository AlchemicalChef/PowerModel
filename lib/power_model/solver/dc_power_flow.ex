defmodule PowerModel.Solver.DCPowerFlow do
  @moduledoc """
  DC Power Flow approximation.
  Assumes V=1.0 pu, lossless lines. Solves P = B' * theta.
  Target: <50ms per interconnection.
  """

  alias PowerModel.Solver.{Sparse, Solution, Partition}

  require Logger

  defstruct [:bus_ids, :bus_index_map, :b_prime, :slack_idx, :p_inject, :base_mva]

  @doc """
  Solve a snapshot that may contain several electrically separate islands
  (e.g. the Eastern, Western, and ERCOT interconnections).

  Each island is solved independently — flows and slack balancing never
  couple across asynchronous boundaries — and the per-island solutions are
  merged into one `Solution`. Islands without generation are skipped (their
  buses appear with no flows; the cascade layer accounts for them as
  blackouts).
  """
  def solve_islands(snapshot, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    {subs, _dead} = Partition.split(snapshot)

    subs
    |> Enum.map(&solve(&1, opts))
    |> Partition.merge_solutions(base_mva)
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

    n = length(buses)
    if n == 0, do: throw({:error, :empty_grid})

    bus_index = buses |> Enum.with_index() |> Map.new(fn {b, i} -> {b.id, i} end)
    bus_ids = Enum.map(buses, & &1.id)

    # Find slack bus (type 3, or largest generator)
    slack_idx = find_slack_index(buses, generators, bus_index)

    # Build B' matrix (n-1 x n-1, excluding slack)
    {b_prime_dense, p_inject} = build_b_prime_and_injection(
      buses, lines, transformers, generators, loads,
      bus_index, slack_idx, n, base_mva
    )

    totals = compute_totals(generators, loads, bus_index, slack_idx, bus_ids)

    # Solve: theta = B'^-1 * P (excluding slack row/col)
    non_slack_size = n - 1
    if non_slack_size == 0 do
      Solution.new(bus_ids, List.duplicate(1.0, n), List.duplicate(0.0, n), %{}, base_mva, totals)
    else
      theta = solve_system(b_prime_dense, p_inject, non_slack_size)

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

  # DC identities: the network is lossless, so actual generation equals served
  # load, with the slack bus producing whatever the scheduled (non-slack)
  # generation does not cover. The gap between scheduled generation and load is
  # reported as mismatch_mw so silent slack pickup is visible to monitoring.
  defp compute_totals(generators, loads, bus_index, slack_idx, bus_ids) do
    {scheduled_gen_mw, gen_at_slack_mw} =
      Enum.reduce(generators, {0.0, 0.0}, fn gen, {total, at_slack} ->
        p = gen.p_max_mw * (gen.capacity_factor || 1.0)
        at_slack = if Map.fetch!(bus_index, gen.bus_id) == slack_idx, do: at_slack + p, else: at_slack
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

    slack_gen_mw = total_load_mw - (scheduled_gen_mw - gen_at_slack_mw)

    [
      total_gen_mw: total_load_mw,
      total_load_mw: total_load_mw,
      total_loss_mw: 0.0,
      scheduled_gen_mw: scheduled_gen_mw,
      slack_bus_id: Enum.at(bus_ids, slack_idx),
      slack_injection_mw: slack_gen_mw - load_at_slack_mw,
      mismatch_mw: total_load_mw - scheduled_gen_mw
    ]
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
        {max_bus_id, _} = Enum.max_by(gen_by_bus, fn {_id, gens} ->
          Enum.sum(Enum.map(gens, & &1.p_max_mw))
        end, fn -> {hd(buses).id, []} end)
        Map.fetch!(bus_index, max_bus_id)
      slack ->
        Map.fetch!(bus_index, slack.id)
    end
  end

  defp build_b_prime_and_injection(_buses, lines, transformers, generators, loads,
                                    bus_index, slack_idx, n, base_mva) do
    # Build full B matrix
    b_full = :array.new(n * n, default: 0.0)

    b_full = Enum.reduce(lines, b_full, fn line, b ->
      i = Map.fetch!(bus_index, line.from_bus_id)
      j = Map.fetch!(bus_index, line.to_bus_id)
      x = line.x_pu || 0.001
      b_ij = 1.0 / x

      b
      |> array_add(i * n + i, b_ij)
      |> array_add(j * n + j, b_ij)
      |> array_add(i * n + j, -b_ij)
      |> array_add(j * n + i, -b_ij)
    end)

    b_full = Enum.reduce(transformers, b_full, fn xfmr, b ->
      i = Map.fetch!(bus_index, xfmr.from_bus_id)
      j = Map.fetch!(bus_index, xfmr.to_bus_id)
      x = xfmr.x_pu
      b_ij = 1.0 / x

      b
      |> array_add(i * n + i, b_ij)
      |> array_add(j * n + j, b_ij)
      |> array_add(i * n + j, -b_ij)
      |> array_add(j * n + i, -b_ij)
    end)

    # Power injection vector (P_gen - P_load) in per unit
    p_full = :array.new(n, default: 0.0)

    p_full = Enum.reduce(generators, p_full, fn gen, p ->
      idx = Map.fetch!(bus_index, gen.bus_id)
      p_pu = (gen.p_max_mw * (gen.capacity_factor || 1.0)) / base_mva
      array_add(p, idx, p_pu)
    end)

    p_full = Enum.reduce(loads, p_full, fn load, p ->
      idx = Map.fetch!(bus_index, load.bus_id)
      p_pu = load.p_mw / base_mva
      array_add(p, idx, -p_pu)
    end)

    # Remove slack row/col to form B' and P'
    non_slack_indices = Enum.reject(0..(n-1), &(&1 == slack_idx))

    b_prime = for i <- non_slack_indices, j <- non_slack_indices do
      :array.get(i * n + j, b_full)
    end

    p_inject = for i <- non_slack_indices do
      :array.get(i, p_full)
    end

    {b_prime, p_inject}
  end

  @sparse_threshold 500

  defp solve_system(b_prime_flat, p_inject, size) do
    if size > @sparse_threshold do
      solve_sparse(b_prime_flat, p_inject, size)
    else
      solve_dense_system(b_prime_flat, p_inject, size)
    end
  end

  defp solve_sparse(b_prime_flat, p_inject, size) do
    # Build COO triplets from the dense flat array (only non-zero entries)
    {rows, cols, vals} =
      b_prime_flat
      |> Enum.with_index()
      |> Enum.reduce({[], [], []}, fn {val, idx}, {rs, cs, vs} ->
        if abs(val) > 1.0e-15 do
          r = div(idx, size)
          c = rem(idx, size)
          {[r | rs], [c | cs], [val | vs]}
        else
          {rs, cs, vs}
        end
      end)

    try do
      case Sparse.sparse_solve(rows, cols, vals, p_inject, size) do
        {:ok, x} -> x
        _ -> solve_dense_system(b_prime_flat, p_inject, size)
      end
    rescue
      _ -> solve_dense_system(b_prime_flat, p_inject, size)
    end
  end

  defp solve_dense_system(b_prime_flat, p_inject, size) do
    b_matrix = Enum.chunk_every(b_prime_flat, size)

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

  defp gaussian_solve(a, b, n) do
    # Augmented matrix — each row stored as an :array for O(1) access
    aug = a
    |> Enum.zip(b)
    |> Enum.map(fn {row, bi} -> :array.from_list(row ++ [bi]) end)
    |> :array.from_list()

    # Forward elimination with partial pivoting
    aug = Enum.reduce(0..(n-2), aug, fn k, aug ->
      # Find pivot
      {max_val, max_row} = Enum.reduce(k..(n-1), {abs(arr_get(aug, k, k)), k}, fn i, {mv, mr} ->
        v = abs(arr_get(aug, i, k))
        if v > mv, do: {v, i}, else: {mv, mr}
      end)

      if max_val < 1.0e-12, do: throw({:error, :singular_matrix})

      # Swap rows
      aug = if max_row != k do
        row_k = :array.get(k, aug)
        row_m = :array.get(max_row, aug)
        aug |> :array.set(k, row_m) |> :array.set(max_row, row_k)
      else
        aug
      end

      # Eliminate
      Enum.reduce((k+1)..(n-1), aug, fn i, aug ->
        factor = arr_get(aug, i, k) / arr_get(aug, k, k)
        row_i = :array.get(i, aug)
        row_k = :array.get(k, aug)
        new_row = :array.from_list(
          for col <- 0..n do
            :array.get(col, row_i) - factor * :array.get(col, row_k)
          end
        )
        :array.set(i, new_row, aug)
      end)
    end)

    # Back substitution
    x = :array.new(n, default: 0.0)
    Enum.reduce((n-1)..0//-1, x, fn i, x ->
      row = :array.get(i, aug)
      sum = Enum.reduce((i+1)..(n-1)//1, 0.0, fn j, acc ->
        acc + :array.get(j, row) * :array.get(j, x)
      end)
      val = (:array.get(n, row) - sum) / :array.get(i, row)
      :array.set(i, val, x)
    end)
    |> :array.to_list()
  end

  defp arr_get(aug, row, col) do
    :array.get(col, :array.get(row, aug))
  end

  defp compute_line_flows(lines, transformers, theta_arr, bus_index, base_mva) do
    line_flows = Enum.map(lines, fn line ->
      i = Map.fetch!(bus_index, line.from_bus_id)
      j = Map.fetch!(bus_index, line.to_bus_id)
      x = line.x_pu || 0.001
      theta_i = :array.get(i, theta_arr)
      theta_j = :array.get(j, theta_arr)
      flow_pu = (theta_i - theta_j) / x
      flow_mw = flow_pu * base_mva

      rating = line.rating_a_mva
      rated? = is_number(rating) and rating > 0

      {{:line, line.id}, %{
        from_bus_id: line.from_bus_id,
        to_bus_id: line.to_bus_id,
        p_flow_mw: flow_mw,
        rating_mva: rating,
        loading_pct: if(rated?, do: abs(flow_mw) / rating * 100.0, else: 0.0),
        overloaded: rated? and abs(flow_mw) > rating
      }}
    end)

    xfmr_flows = Enum.map(transformers, fn xfmr ->
      i = Map.fetch!(bus_index, xfmr.from_bus_id)
      j = Map.fetch!(bus_index, xfmr.to_bus_id)
      x = xfmr.x_pu
      theta_i = :array.get(i, theta_arr)
      theta_j = :array.get(j, theta_arr)
      flow_pu = (theta_i - theta_j) / x
      flow_mw = flow_pu * base_mva

      rating = xfmr.rated_mva
      rated? = is_number(rating) and rating > 0

      {{:transformer, xfmr.id}, %{
        from_bus_id: xfmr.from_bus_id,
        to_bus_id: xfmr.to_bus_id,
        p_flow_mw: flow_mw,
        rating_mva: rating,
        loading_pct: if(rated?, do: abs(flow_mw) / rating * 100.0, else: 0.0),
        overloaded: rated? and abs(flow_mw) > rating
      }}
    end)

    Map.new(line_flows ++ xfmr_flows)
  end

  defp insert_at(list, idx, val) do
    {before, after_} = Enum.split(list, idx)
    before ++ [val] ++ after_
  end

  defp array_add(arr, idx, val) do
    :array.set(idx, :array.get(idx, arr) + val, arr)
  end
end
