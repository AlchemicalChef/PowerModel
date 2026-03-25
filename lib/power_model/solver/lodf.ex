defmodule PowerModel.Solver.LODF do
  @moduledoc """
  Line Outage Distribution Factors for fast cascade flow updates.

  After the base DC power flow solve, tripping a line updates all other
  line flows via:

      f_l_new = f_l_base + LODF[l,k] * f_k_base

  where LODF[l,k] is computed from two columns of B'^{-1} (the columns
  at the tripped line's endpoints). This replaces a full DC re-solve
  (~300ms at 70k buses) with two sparse back-substitutions (~5ms each)
  plus an O(branches) flow update.

  ## Usage

      lodf = LODF.init(snapshot, base_solution, base_mva: 100.0)
      {:ok, lodf, updated_flows} = LODF.trip_line(lodf, {:line, line_id})
      # or
      {:island_split, lodf} = LODF.trip_line(lodf, {:line, line_id})
  """

  require Logger
  alias PowerModel.Solver.Sparse

  defstruct [
    :n,                  # total bus count
    :n_reduced,          # non-slack bus count (n - 1)
    :slack_idx,          # slack bus index in original ordering
    :remap,              # %{original_idx => reduced_idx}
    :inv_remap,          # %{reduced_idx => original_idx}
    :bus_index,          # %{bus_id => original_idx}
    :base_mva,
    :b_coo_rows,         # B' matrix COO (reduced coordinates)
    :b_coo_cols,
    :b_coo_vals,
    :branches,           # [%{key, from_idx, to_idx, b_susceptance, rating}]
    :base_flows,         # %{branch_key => flow_mw}
    :base_loading,       # %{branch_key => loading_pct}
    :cumulative_trips,   # MapSet of tripped branch keys
    :factor_handle,      # ResourceArc for cached LDL^T (nil if not available)
    :ptdf_cache          # %{reduced_idx => solution_vector} cache of B'^{-1} columns
  ]

  @island_split_threshold 1.0e-8

  @doc """
  Initialize LODF state from a base DC power flow solution.
  """
  def init(snapshot, base_solution, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)

    buses = snapshot.buses
    lines = Map.get(snapshot, :lines, [])
    transformers = Map.get(snapshot, :transformers, [])

    n = length(buses)
    bus_index = buses |> Enum.with_index() |> Map.new(fn {b, i} -> {b.id, i} end)

    # Find slack bus (same logic as DCPowerFlow)
    slack_idx = find_slack(buses, snapshot.generators, bus_index)

    # Build remap (skip slack)
    {remap, inv_remap} = build_remap(n, slack_idx)
    n_reduced = n - 1

    # Build B' COO in reduced coordinates
    {b_rows, b_cols, b_vals} = build_b_prime_coo(lines, transformers, bus_index, slack_idx, remap)

    # Build branch list with reduced indices
    branches = build_branch_list(lines, transformers, bus_index, slack_idx, remap, base_mva)

    # Extract base flows from solution
    base_flows = Map.new(base_solution.line_flows, fn {key, flow} ->
      {key, flow.p_flow_mw}
    end)

    base_loading = Map.new(base_solution.line_flows, fn {key, flow} ->
      {key, flow.loading_pct}
    end)

    # Try to cache the factorization
    factor_handle = try_cache_factor(b_rows, b_cols, b_vals, n_reduced)

    %__MODULE__{
      n: n,
      n_reduced: n_reduced,
      slack_idx: slack_idx,
      remap: remap,
      inv_remap: inv_remap,
      bus_index: bus_index,
      base_mva: base_mva,
      b_coo_rows: b_rows,
      b_coo_cols: b_cols,
      b_coo_vals: b_vals,
      branches: branches,
      base_flows: base_flows,
      base_loading: base_loading,
      cumulative_trips: MapSet.new(),
      factor_handle: factor_handle,
      ptdf_cache: %{}
    }
  end

  @doc """
  Update flows after tripping a line using LODF.

  Returns `{:ok, updated_lodf, updated_flow_map}` where `updated_flow_map`
  has the same format as `solution.line_flows` (with p_flow_mw, loading_pct, overloaded).

  Returns `{:island_split, updated_lodf}` if the tripped line is a bridge
  (the network would split into islands).
  """
  def trip_line(%__MODULE__{} = state, branch_key) do
    if MapSet.member?(state.cumulative_trips, branch_key) do
      # Already tripped — return current flows
      {:ok, state, rebuild_flow_map(state)}
    else
      # Find the branch
      branch = Enum.find(state.branches, fn b -> b.key == branch_key end)

      if branch == nil do
        # Branch not in our list (transformer, or not in active set)
        {:ok, state, rebuild_flow_map(state)}
      else
        # Compute sensitivity vector: x = B'^{-1} * (e_from - e_to)
        # This gives the angle change at each bus when 1 pu is injected at from
        # and withdrawn at to (i.e., the tripped line's endpoints)
        sensitivity = compute_sensitivity(state, branch.from_reduced, branch.to_reduced)

        if sensitivity == nil do
          {:error, state}
        else
          # PTDF[k,k] = b_k * (x[from_k] - x[to_k]) = self-sensitivity of tripped line
          x_from = Enum.at(sensitivity, branch.from_reduced || 0, 0.0)
          x_to = Enum.at(sensitivity, branch.to_reduced || 0, 0.0)
          # For slack bus endpoints, the angle is fixed at 0
          x_from = if branch.from_reduced == nil, do: 0.0, else: x_from
          x_to = if branch.to_reduced == nil, do: 0.0, else: x_to

          ptdf_self = branch.b_susceptance * (x_from - x_to)
          denom = 1.0 - ptdf_self

          if abs(denom) < @island_split_threshold do
            state = %{state | cumulative_trips: MapSet.put(state.cumulative_trips, branch_key)}
            {:island_split, state}
          else
            f_k = Map.get(state.base_flows, branch_key, 0.0)

            # Update all branch flows: f_l_new = f_l + LODF[l,k] * f_k
            # LODF[l,k] = b_l * (x[from_l] - x[to_l]) / denom
            # Convert sensitivity list to array for O(1) access
            sens_arr = :array.from_list(sensitivity)

            branch_map = Map.new(state.branches, fn b -> {b.key, b} end)

            updated_flows = Map.new(state.base_flows, fn {bkey, f_l} ->
              if bkey == branch_key or MapSet.member?(state.cumulative_trips, bkey) do
                {bkey, f_l}
              else
                case Map.get(branch_map, bkey) do
                  nil -> {bkey, f_l}
                  br ->
                    xa = if br.from_reduced == nil, do: 0.0, else: :array.get(br.from_reduced, sens_arr)
                    xb = if br.to_reduced == nil, do: 0.0, else: :array.get(br.to_reduced, sens_arr)
                    ptdf_lk = br.b_susceptance * (xa - xb)
                    lodf_lk = ptdf_lk / denom
                    {bkey, f_l + lodf_lk * f_k}
                end
              end
            end)

            updated_flows = Map.delete(updated_flows, branch_key)

            state = %{state |
              base_flows: updated_flows,
              base_loading: compute_loading_from_flows(updated_flows, state.branches, state.base_mva),
              cumulative_trips: MapSet.put(state.cumulative_trips, branch_key)
            }

            {:ok, state, rebuild_flow_map(state)}
          end
        end
      end
    end
  end

  @doc """
  Check if using LODF is still valid or if a full re-solve is needed.
  """
  def needs_refactorize?(%__MODULE__{} = state, opts \\ []) do
    max_trips = Keyword.get(opts, :max_cumulative_trips, 10)
    MapSet.size(state.cumulative_trips) > max_trips
  end

  # --- Private functions ---

  defp find_slack(buses, generators, bus_index) do
    case Enum.find(buses, &(&1.bus_type == 3)) do
      nil ->
        gen_by_bus = Enum.group_by(generators, & &1.bus_id)
        {max_bus_id, _} = Enum.max_by(gen_by_bus, fn {_id, gens} ->
          Enum.sum_by(gens, & &1.p_max_mw)
        end, fn -> {hd(buses).id, []} end)
        Map.fetch!(bus_index, max_bus_id)
      slack ->
        Map.fetch!(bus_index, slack.id)
    end
  end

  defp build_remap(n, slack_idx) do
    {remap, inv, _} = Enum.reduce(0..(n - 1), {%{}, %{}, 0}, fn i, {m, inv, ri} ->
      if i == slack_idx do
        {m, inv, ri}
      else
        {Map.put(m, i, ri), Map.put(inv, ri, i), ri + 1}
      end
    end)
    {remap, inv}
  end

  defp build_b_prime_coo(lines, transformers, bus_index, slack_idx, remap) do
    triplets = %{}

    triplets = Enum.reduce(lines, triplets, fn line, bt ->
      i = Map.fetch!(bus_index, line.from_bus_id)
      j = Map.fetch!(bus_index, line.to_bus_id)
      x = line.x_pu || 0.001
      b = 1.0 / x

      bt
      |> maybe_add_triplet(i, i, b, slack_idx, remap)
      |> maybe_add_triplet(j, j, b, slack_idx, remap)
      |> maybe_add_triplet(i, j, -b, slack_idx, remap)
      |> maybe_add_triplet(j, i, -b, slack_idx, remap)
    end)

    triplets = Enum.reduce(transformers, triplets, fn xfmr, bt ->
      i = Map.fetch!(bus_index, xfmr.from_bus_id)
      j = Map.fetch!(bus_index, xfmr.to_bus_id)
      x = xfmr.x_pu
      t = xfmr.tap_ratio || 1.0
      y = 1.0 / x

      bt
      |> maybe_add_triplet(i, i, y / (t * t), slack_idx, remap)
      |> maybe_add_triplet(j, j, y, slack_idx, remap)
      |> maybe_add_triplet(i, j, -y / t, slack_idx, remap)
      |> maybe_add_triplet(j, i, -y / t, slack_idx, remap)
    end)

    Enum.reduce(triplets, {[], [], []}, fn {{r, c}, v}, {rs, cs, vs} ->
      if abs(v) > 1.0e-15 do
        {[r | rs], [c | cs], [v | vs]}
      else
        {rs, cs, vs}
      end
    end)
  end

  defp maybe_add_triplet(bt, r, c, val, slack_idx, remap) do
    if r == slack_idx or c == slack_idx do
      bt
    else
      ri = Map.fetch!(remap, r)
      ci = Map.fetch!(remap, c)
      Map.update(bt, {ri, ci}, val, &(&1 + val))
    end
  end

  defp build_branch_list(lines, transformers, bus_index, slack_idx, remap, _base_mva) do
    line_branches = Enum.map(lines, fn line ->
      i = Map.fetch!(bus_index, line.from_bus_id)
      j = Map.fetch!(bus_index, line.to_bus_id)
      b = 1.0 / (line.x_pu || 0.001)

      %{
        key: {:line, line.id},
        from_idx: i,
        to_idx: j,
        from_reduced: Map.get(remap, i),
        to_reduced: Map.get(remap, j),
        b_susceptance: b,
        rating: line.rating_a_mva || 0.0,
        is_slack_connected: i == slack_idx or j == slack_idx
      }
    end)

    xfmr_branches = Enum.map(transformers, fn xfmr ->
      i = Map.fetch!(bus_index, xfmr.from_bus_id)
      j = Map.fetch!(bus_index, xfmr.to_bus_id)
      t = xfmr.tap_ratio || 1.0
      b = 1.0 / (xfmr.x_pu * t)

      %{
        key: {:transformer, xfmr.id},
        from_idx: i,
        to_idx: j,
        from_reduced: Map.get(remap, i),
        to_reduced: Map.get(remap, j),
        b_susceptance: b,
        rating: xfmr.rated_mva || 0.0,
        is_slack_connected: i == slack_idx or j == slack_idx
      }
    end)

    line_branches ++ xfmr_branches
  end

  # Compute sensitivity vector: x = B'^{-1} * (e_from - e_to)
  # This gives the angle change at each bus for a unit injection at from, withdrawal at to.
  defp compute_sensitivity(state, from_reduced, to_reduced) do
    rhs = List.duplicate(0.0, state.n_reduced)

    rhs = if from_reduced != nil do
      List.replace_at(rhs, from_reduced, 1.0)
    else
      rhs
    end

    rhs = if to_reduced != nil do
      List.replace_at(rhs, to_reduced, -1.0)
    else
      rhs
    end

    solve_with_cache(state, rhs)
  end

  defp solve_with_cache(%{factor_handle: handle} = _state, rhs) when handle != nil do
    try do
      case Sparse.sparse_cached_solve(handle, rhs) do
        {:ok, x} -> x
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  defp solve_with_cache(state, rhs) do
    try do
      case Sparse.sparse_solve(state.b_coo_rows, state.b_coo_cols, state.b_coo_vals, rhs, state.n_reduced) do
        {:ok, x} -> x
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  defp ptdf_at(_ptdf_col, nil), do: 0.0
  defp ptdf_at(ptdf_col, idx), do: Enum.at(ptdf_col, idx, 0.0)

  defp update_all_flows(state, tripped_branch, ptdf_from, ptdf_to, f_k, denom) do
    Map.new(state.base_flows, fn {branch_key, f_l} ->
      if MapSet.member?(state.cumulative_trips, branch_key) do
        {branch_key, f_l}
      else
        branch = Enum.find(state.branches, fn b -> b.key == branch_key end)

        if branch == nil do
          {branch_key, f_l}
        else
          # LODF[l,k] = b_l * (ptdf[from_l, from_k] - ptdf[from_l, to_k]
          #                    - ptdf[to_l, from_k] + ptdf[to_l, to_k]) / denom
          # Simplified using PTDF columns at tripped line endpoints:
          lodf = compute_lodf_entry(branch, tripped_branch, ptdf_from, ptdf_to, denom)

          {branch_key, f_l + lodf * f_k}
        end
      end
    end)
  end

  defp compute_lodf_entry(branch_l, _tripped, ptdf_from, ptdf_to, denom) do
    # PTDF[l, from_k] - PTDF[l, to_k] gives the sensitivity of line l's flow
    # to injection at from_k withdrawn at to_k.
    # For line l with endpoints (a, b) and susceptance b_l:
    # flow_l = b_l * (theta_a - theta_b)
    # delta_flow_l = b_l * (delta_theta_a - delta_theta_b)
    # where delta_theta = B'^{-1} * (e_from - e_to) scaled by f_k

    ptdf_a_from = ptdf_at(ptdf_from, branch_l.from_reduced)
    ptdf_a_to = ptdf_at(ptdf_to, branch_l.from_reduced)
    ptdf_b_from = ptdf_at(ptdf_from, branch_l.to_reduced)
    ptdf_b_to = ptdf_at(ptdf_to, branch_l.to_reduced)

    # Sensitivity of line l to injection at tripped line endpoints
    sensitivity = branch_l.b_susceptance * ((ptdf_a_from - ptdf_a_to) - (ptdf_b_from - ptdf_b_to))

    sensitivity / denom
  end

  defp compute_loading_from_flows(flows, branches, _base_mva) do
    branch_ratings = Map.new(branches, fn b -> {b.key, b.rating} end)

    Map.new(flows, fn {key, flow_mw} ->
      rating = Map.get(branch_ratings, key, 0.0)
      loading = if rating > 0.0, do: abs(flow_mw) / rating * 100.0, else: 0.0
      {key, loading}
    end)
  end

  defp rebuild_flow_map(state) do
    branch_map = Map.new(state.branches, fn b -> {b.key, b} end)

    Map.new(state.base_flows, fn {key, flow_mw} ->
      branch = Map.get(branch_map, key)
      rating = if branch, do: branch.rating, else: 0.0
      loading = if rating > 0.0, do: abs(flow_mw) / rating * 100.0, else: 0.0

      {key, %{
        p_flow_mw: flow_mw,
        loading_pct: loading,
        overloaded: rating > 0.0 and abs(flow_mw) > rating
      }}
    end)
  end

  defp try_cache_factor(rows, cols, vals, n) do
    try do
      case Sparse.sparse_factor(rows, cols, vals, n) do
        {:ok, handle} -> handle
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end
end
