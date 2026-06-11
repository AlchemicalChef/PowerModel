defmodule PowerModel.Solver.DCPowerFlow do
  @moduledoc """
  DC Power Flow approximation.
  Assumes V=1.0 pu, lossless lines. Solves P = B' * theta.
  Uses sparse COO construction throughout — O(nnz) not O(n²).
  """

  alias PowerModel.Solver.{Sparse, Solution}

  defstruct [:bus_ids, :bus_index_map, :b_prime, :slack_idx, :p_inject, :base_mva]

  @doc """
  Solve DC power flow for given grid snapshot.
  Returns %Solution{} with voltage angles and line flows.
  """
  def solve(snapshot, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)

    %{
      buses: buses,
      lines: lines,
      transformers: transformers,
      generators: generators,
      loads: loads
    } = snapshot

    n = length(buses)
    if n == 0, do: throw({:error, :empty_grid})

    bus_index = buses |> Enum.with_index() |> Map.new(fn {b, i} -> {b.id, i} end)
    bus_ids = Enum.map(buses, & &1.id)

    slack_idx = find_slack_index(buses, generators, bus_index)

    {coo_rows, coo_cols, coo_vals, p_inject} =
      build_sparse_system(
        lines,
        transformers,
        generators,
        loads,
        bus_index,
        slack_idx,
        n,
        base_mva
      )

    non_slack_size = n - 1

    if non_slack_size == 0 do
      Solution.new(bus_ids, List.duplicate(1.0, n), List.duplicate(0.0, n), %{}, base_mva)
    else
      theta =
        if non_slack_size == 1 do
          # Single non-slack bus: trivial 1x1 solve (avoids sprs n>1 assertion)
          b_diag =
            Enum.find_value(Enum.zip([coo_rows, coo_cols, coo_vals]), 0.0, fn {r, c, v} ->
              if r == 0 and c == 0, do: v
            end)

          p = hd(p_inject)
          [if(abs(b_diag) > 1.0e-15, do: p / b_diag, else: 0.0)]
        else
          solve_sparse_system(coo_rows, coo_cols, coo_vals, p_inject, non_slack_size)
        end

      theta_full = List.insert_at(theta, slack_idx, 0.0)

      theta_arr = :array.from_list(theta_full)

      line_flows = compute_line_flows(lines, transformers, theta_arr, bus_index, base_mva)

      vm = List.duplicate(1.0, n)
      Solution.new(bus_ids, vm, theta_full, line_flows, base_mva)
    end
  end

  defp find_slack_index(buses, generators, bus_index) do
    case Enum.find(buses, &(&1.bus_type == 3)) do
      nil ->
        gen_by_bus = Enum.group_by(generators, & &1.bus_id)

        {max_bus_id, _} =
          Enum.max_by(
            gen_by_bus,
            fn {_id, gens} ->
              Enum.sum_by(gens, & &1.p_max_mw)
            end,
            fn -> {hd(buses).id, []} end
          )

        Map.fetch!(bus_index, max_bus_id)

      slack ->
        Map.fetch!(bus_index, slack.id)
    end
  end

  # Build the reduced B' matrix directly as COO triplets and the P injection vector.
  # Eliminates the slack bus row/column during construction — no dense matrix ever created.
  defp build_sparse_system(
         lines,
         transformers,
         generators,
         loads,
         bus_index,
         slack_idx,
         n,
         base_mva
       ) do
    # Build index remapping: original index -> reduced index (skipping slack)
    remap = build_remap(n, slack_idx)

    # Build B' triplets in reduced coordinates
    b_triplets = %{}

    b_triplets =
      Enum.reduce(lines, b_triplets, fn line, bt ->
        i = Map.fetch!(bus_index, line.from_bus_id)
        j = Map.fetch!(bus_index, line.to_bus_id)
        raw_x = line.x_pu || 0.001
        # Clamp susceptance: |b| <= 1000 (i.e. |x| >= 0.001)
        x = if(abs(raw_x) < 0.001, do: sign(raw_x) * 0.001, else: raw_x)
        b_ij = 1.0 / x

        add_branch_triplets(bt, i, j, b_ij, b_ij, -b_ij, -b_ij, slack_idx, remap)
      end)

    b_triplets =
      Enum.reduce(transformers, b_triplets, fn xfmr, bt ->
        i = Map.fetch!(bus_index, xfmr.from_bus_id)
        j = Map.fetch!(bus_index, xfmr.to_bus_id)
        raw_x = xfmr.x_pu
        # Clamp susceptance: |b| <= 1000 (i.e. |x| >= 0.001), preserving sign
        x = if(abs(raw_x) < 0.001, do: sign(raw_x) * 0.001, else: raw_x)
        t = xfmr.tap_ratio || 1.0
        y_series = 1.0 / x

        add_branch_triplets(
          bt,
          i,
          j,
          y_series / (t * t),
          y_series,
          -y_series / t,
          -y_series / t,
          slack_idx,
          remap
        )
      end)

    # Build P injection vector (reduced, slack removed)
    p_full = :array.new(n, default: 0.0)

    # Phase-shifting transformer injections
    p_full =
      Enum.reduce(transformers, p_full, fn xfmr, p ->
        shift_deg = Map.get(xfmr, :phase_shift_deg) || 0.0

        if shift_deg != 0.0 do
          i = Map.fetch!(bus_index, xfmr.from_bus_id)
          j = Map.fetch!(bus_index, xfmr.to_bus_id)
          x = xfmr.x_pu
          t = xfmr.tap_ratio || 1.0
          shift_rad = shift_deg * :math.pi() / 180.0
          p_shift = shift_rad / (x * t)

          p |> array_add(i, p_shift) |> array_add(j, -p_shift)
        else
          p
        end
      end)

    p_full =
      Enum.reduce(generators, p_full, fn gen, p ->
        idx = Map.fetch!(bus_index, gen.bus_id)
        p_pu = gen.p_max_mw * (gen.capacity_factor || 1.0) / base_mva
        array_add(p, idx, p_pu)
      end)

    p_full =
      Enum.reduce(loads, p_full, fn load, p ->
        idx = Map.fetch!(bus_index, load.bus_id)
        p_pu = load.p_mw / base_mva
        array_add(p, idx, -p_pu)
      end)

    # Extract reduced P injection (skip slack bus)
    p_inject = for i <- 0..(n - 1), i != slack_idx, do: :array.get(i, p_full)

    # Extract COO arrays from triplet map
    {rows, cols, vals} =
      Enum.reduce(b_triplets, {[], [], []}, fn {{r, c}, v}, {rs, cs, vs} ->
        if abs(v) > 1.0e-15 do
          {[r | rs], [c | cs], [v | vs]}
        else
          {rs, cs, vs}
        end
      end)

    {rows, cols, vals, p_inject}
  end

  # Build remap: original bus index -> reduced index (skipping slack)
  defp build_remap(n, slack_idx) do
    {remap, _} =
      Enum.reduce(0..(n - 1), {%{}, 0}, fn i, {m, ri} ->
        if i == slack_idx do
          {m, ri}
        else
          {Map.put(m, i, ri), ri + 1}
        end
      end)

    remap
  end

  # Add a branch's 4 B' matrix entries, skipping slack bus rows/columns
  defp add_branch_triplets(bt, i, j, b_ii, b_jj, b_ij, b_ji, slack_idx, remap) do
    bt
    |> maybe_add(i, i, b_ii, slack_idx, remap)
    |> maybe_add(j, j, b_jj, slack_idx, remap)
    |> maybe_add(i, j, b_ij, slack_idx, remap)
    |> maybe_add(j, i, b_ji, slack_idx, remap)
  end

  defp maybe_add(bt, r, c, val, slack_idx, remap) do
    if r == slack_idx or c == slack_idx do
      bt
    else
      ri = Map.fetch!(remap, r)
      ci = Map.fetch!(remap, c)
      Map.update(bt, {ri, ci}, val, &(&1 + val))
    end
  end

  # Solve using sparse NIF, with dense fallback
  defp solve_sparse_system(rows, cols, vals, p_inject, size) do
    try do
      case Sparse.sparse_solve(rows, cols, vals, p_inject, size) do
        {:ok, x} -> x
        _ -> dense_fallback(rows, cols, vals, p_inject, size)
      end
    rescue
      _ -> dense_fallback(rows, cols, vals, p_inject, size)
    end
  end

  defp dense_fallback(rows, cols, vals, p_inject, size) do
    # Build dense flat matrix from COO for dense NIF solvers
    flat = List.duplicate(0.0, size * size) |> :array.from_list()

    flat =
      Enum.zip([rows, cols, vals])
      |> Enum.reduce(flat, fn {r, c, v}, arr ->
        idx = r * size + c
        :array.set(idx, :array.get(idx, arr) + v, arr)
      end)

    flat_list = :array.to_list(flat)

    try do
      case Sparse.dense_solve_flat(flat_list, p_inject, size) do
        {:ok, x} -> x
        _ -> gaussian_solve_from_coo(rows, cols, vals, p_inject, size)
      end
    rescue
      _ -> gaussian_solve_from_coo(rows, cols, vals, p_inject, size)
    end
  end

  defp gaussian_solve_from_coo(rows, cols, vals, p_inject, size) do
    # Build dense matrix from COO
    matrix =
      for r <- 0..(size - 1) do
        row = List.duplicate(0.0, size) |> :array.from_list()

        row =
          Enum.zip([rows, cols, vals])
          |> Enum.reduce(row, fn {ri, ci, v}, arr ->
            if ri == r, do: :array.set(ci, :array.get(ci, arr) + v, arr), else: arr
          end)

        :array.to_list(row)
      end

    gaussian_solve(matrix, p_inject, size)
  end

  defp gaussian_solve(a, b, n) do
    aug =
      a
      |> Enum.zip(b)
      |> Enum.map(fn {row, bi} -> :array.from_list(row ++ [bi]) end)
      |> :array.from_list()

    aug =
      Enum.reduce(0..(n - 2), aug, fn k, aug ->
        {max_val, max_row} =
          Enum.reduce(k..(n - 1), {abs(arr_get(aug, k, k)), k}, fn i, {mv, mr} ->
            v = abs(arr_get(aug, i, k))
            if v > mv, do: {v, i}, else: {mv, mr}
          end)

        if max_val < 1.0e-12, do: throw({:error, :singular_matrix})

        aug =
          if max_row != k do
            row_k = :array.get(k, aug)
            row_m = :array.get(max_row, aug)
            aug |> :array.set(k, row_m) |> :array.set(max_row, row_k)
          else
            aug
          end

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

    x = :array.new(n, default: 0.0)

    Enum.reduce((n - 1)..0//-1, x, fn i, x ->
      row = :array.get(i, aug)

      sum =
        Enum.reduce((i + 1)..(n - 1)//1, 0.0, fn j, acc ->
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
    line_flows = Enum.map(lines, &compute_line_flow(&1, theta_arr, bus_index, base_mva))
    xfmr_flows = Enum.map(transformers, &compute_xfmr_flow(&1, theta_arr, bus_index, base_mva))

    Map.new(line_flows ++ xfmr_flows)
  end

  defp compute_line_flow(line, theta_arr, bus_index, base_mva) do
    i = Map.fetch!(bus_index, line.from_bus_id)
    j = Map.fetch!(bus_index, line.to_bus_id)
    raw_x = line.x_pu || 0.001
    x = if(abs(raw_x) < 0.001, do: sign(raw_x) * 0.001, else: raw_x)
    theta_i = :array.get(i, theta_arr)
    theta_j = :array.get(j, theta_arr)
    flow_pu = (theta_i - theta_j) / x
    flow_mw = flow_pu * base_mva

    {{:line, line.id},
     %{
       from_bus_id: line.from_bus_id,
       to_bus_id: line.to_bus_id,
       p_flow_mw: flow_mw,
       loading_pct:
         if(line.rating_a_mva && line.rating_a_mva > 0,
           do: abs(flow_mw) / line.rating_a_mva * 100.0,
           else: 0.0
         ),
       overloaded: line.rating_a_mva != nil and abs(flow_mw) > (line.rating_a_mva || 999_999)
     }}
  end

  defp compute_xfmr_flow(xfmr, theta_arr, bus_index, base_mva) do
    i = Map.fetch!(bus_index, xfmr.from_bus_id)
    j = Map.fetch!(bus_index, xfmr.to_bus_id)
    raw_x = xfmr.x_pu
    x = if(abs(raw_x) < 0.001, do: sign(raw_x) * 0.001, else: raw_x)
    t = xfmr.tap_ratio || 1.0
    shift_rad = (Map.get(xfmr, :phase_shift_deg) || 0.0) * :math.pi() / 180.0
    theta_i = :array.get(i, theta_arr)
    theta_j = :array.get(j, theta_arr)
    # Standard DC transformer flow: P = (theta_i - theta_j - shift) / (x * t)
    # The mutual admittance (off-diagonal of B') is 1/(x*t), which is the
    # flow sensitivity to angle difference.
    flow_pu = (theta_i - theta_j - shift_rad) / (x * t)
    flow_mw = flow_pu * base_mva

    {{:transformer, xfmr.id},
     %{
       from_bus_id: xfmr.from_bus_id,
       to_bus_id: xfmr.to_bus_id,
       p_flow_mw: flow_mw,
       loading_pct:
         if(xfmr.rated_mva > 0,
           do: abs(flow_mw) / xfmr.rated_mva * 100.0,
           else: 0.0
         ),
       overloaded: abs(flow_mw) > xfmr.rated_mva
     }}
  end

  # Sign function: returns 1.0 for positive, -1.0 for negative, 1.0 for zero
  defp sign(x) when x >= 0, do: 1.0
  defp sign(_x), do: -1.0

  defp array_add(arr, idx, val) do
    :array.set(idx, :array.get(idx, arr) + val, arr)
  end
end
