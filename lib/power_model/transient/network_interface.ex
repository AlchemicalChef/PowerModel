defmodule PowerModel.Transient.NetworkInterface do
  @moduledoc """
  Machine-network coupling for transient stability simulation.

  Handles Kron reduction of the full Y-bus to generator internal buses,
  producing the reduced admittance matrix Y_red used by the classical
  machine model.

  For the classical model (constant E' behind X'd), generators are
  represented as voltage sources behind their transient reactance.
  The network is augmented with generator internal buses, then all
  non-generator-internal buses are eliminated via Kron reduction.
  """

  alias PowerModel.Solver.{YBus, Sparse}

  @doc """
  Build the reduced admittance matrix for the classical machine model.

  Steps:
  1. Build the full Y-bus from grid topology
  2. Augment it with generator internal buses (connected via X'd)
  3. Kron-reduce to eliminate all network buses, keeping only generator
     internal buses

  Returns `{y_red_rows, y_red_cols, y_red_g, y_red_b}` in COO format
  for the n_gen x n_gen reduced admittance matrix.
  """
  def build_y_reduced(buses, lines, transformers, generators, base_mva) do
    n_bus = length(buses)
    bus_index = buses |> Enum.with_index() |> Map.new(fn {b, i} -> {b.id, i} end)

    # Build standard Y-bus as map of {row, col} -> {g, b}
    ybus = YBus.build(buses, lines, transformers, base_mva)

    # Extract triplets from Y-bus
    {ybus_rows, ybus_cols, ybus_reals, ybus_imags} = ybus_to_coo(ybus)

    # Generator internal buses are indexed n_bus..n_bus+n_gen-1
    # Each connects to its terminal bus via admittance 1/jX'd
    gen_triplets =
      generators
      |> Enum.with_index()
      |> Enum.flat_map(fn {gen, gen_idx} ->
        internal_bus = n_bus + gen_idx
        terminal_bus = Map.get(bus_index, gen.bus_id)

        if terminal_bus == nil do
          []
        else
          x_d_prime = Map.get(gen, :x_d_prime_pu) || default_xd_prime(gen)
          # Admittance = 1/(jX'd) => g=0, b=-1/X'd (series branch)
          b_series = -1.0 / max(x_d_prime, 0.001)

          [
            # Diagonal: internal bus
            {internal_bus, internal_bus, 0.0, b_series},
            # Diagonal: terminal bus (additive)
            {terminal_bus, terminal_bus, 0.0, b_series},
            # Off-diagonal
            {internal_bus, terminal_bus, 0.0, -b_series},
            {terminal_bus, internal_bus, 0.0, -b_series}
          ]
        end
      end)

    # Merge generator triplets with Y-bus triplets
    {g_rows, g_cols, g_reals, g_imags} =
      Enum.reduce(gen_triplets, {ybus_rows, ybus_cols, ybus_reals, ybus_imags}, fn {r, c, re, im},
                                                                                   {rs, cs, res,
                                                                                    ims} ->
        {[r | rs], [c | cs], [re | res], [im | ims]}
      end)

    n_total = n_bus + length(generators)
    gen_internal_indices = Enum.to_list(n_bus..(n_total - 1))

    # Kron reduce: keep only generator internal buses
    try do
      case Sparse.kron_reduce(g_rows, g_cols, g_reals, g_imags, n_total, gen_internal_indices) do
        {:ok, red_rows, red_cols, red_g, red_b} ->
          {:ok, red_rows, red_cols, red_g, red_b}

        error ->
          {:error, error}
      end
    rescue
      e -> {:error, e}
    end
  end

  @doc """
  Build Y_reduced using pure Elixir (fallback when NIF unavailable).
  Only feasible for small systems (< 500 buses).
  """
  def build_y_reduced_elixir(buses, lines, transformers, generators, base_mva) do
    n_bus = length(buses)
    n_gen = length(generators)
    bus_index = buses |> Enum.with_index() |> Map.new(fn {b, i} -> {b.id, i} end)

    n_total = n_bus + n_gen

    # Build full augmented Y-bus as dense complex matrix (maps)
    ybus = YBus.build(buses, lines, transformers, base_mva)
    y_map = ybus_to_complex_map(ybus)

    # Add generator internal bus connections
    y_map =
      generators
      |> Enum.with_index()
      |> Enum.reduce(y_map, fn {gen, gen_idx}, acc ->
        internal = n_bus + gen_idx
        terminal = Map.get(bus_index, gen.bus_id)

        if terminal == nil do
          acc
        else
          x_d_prime = Map.get(gen, :x_d_prime_pu) || default_xd_prime(gen)
          b_s = -1.0 / max(x_d_prime, 0.001)

          acc
          |> add_complex(internal, internal, 0.0, b_s)
          |> add_complex(terminal, terminal, 0.0, b_s)
          |> add_complex(internal, terminal, 0.0, -b_s)
          |> add_complex(terminal, internal, 0.0, -b_s)
        end
      end)

    # Kron reduce: eliminate network buses (0..n_bus-1), keep gen buses (n_bus..n_total-1)
    # Y_red = Y_gg - Y_gn * Y_nn^-1 * Y_ng
    # For small systems, do this with dense Gaussian elimination
    gen_indices = Enum.to_list(n_bus..(n_total - 1))
    net_indices = Enum.to_list(0..(n_bus - 1))

    y_red = kron_reduce_dense(y_map, gen_indices, net_indices, n_total)

    # Convert to COO
    {rows, cols, gs, bs} =
      Enum.reduce(y_red, {[], [], [], []}, fn {{r, c}, {g, b}}, {rs, cs, gvals, bvals} ->
        if abs(g) > 1.0e-15 or abs(b) > 1.0e-15 do
          {[r | rs], [c | cs], [g | gvals], [b | bvals]}
        else
          {rs, cs, gvals, bvals}
        end
      end)

    {:ok, rows, cols, gs, bs}
  end

  defp ybus_to_coo(ybus) do
    ybus.triplets
    |> Enum.reduce({[], [], [], []}, fn triplet, {rs, cs, res, ims} ->
      {row, col, real, imag} = normalize_ybus_triplet(triplet)
      {[row | rs], [col | cs], [real | res], [imag | ims]}
    end)
  end

  defp ybus_to_complex_map(ybus) do
    Enum.reduce(ybus.triplets, %{}, fn triplet, acc ->
      {r, c, re, im} = normalize_ybus_triplet(triplet)
      add_complex(acc, r, c, re, im)
    end)
  end

  defp normalize_ybus_triplet({row, col, {real, imag}}), do: {row, col, real, imag}
  defp normalize_ybus_triplet({row, col, real, imag}), do: {row, col, real, imag}

  defp add_complex(map, r, c, g, b) do
    Map.update(map, {r, c}, {g, b}, fn {g0, b0} -> {g0 + g, b0 + b} end)
  end

  defp kron_reduce_dense(y_map, keep_indices, elim_indices, _n) do
    # Sequential Kron reduction: for each bus to eliminate,
    # update all remaining entries
    # Reindex: keep_indices -> 0..n_keep-1
    keep_reindex = keep_indices |> Enum.with_index() |> Map.new()

    # Eliminate buses one at a time (Gaussian elimination on Y-bus)
    y_final =
      Enum.reduce(elim_indices, y_map, fn k, y ->
        {g_kk, b_kk} = Map.get(y, {k, k}, {0.0, 0.0})
        denom_sq = g_kk * g_kk + b_kk * b_kk

        if denom_sq < 1.0e-30 do
          y
        else
          # For each pair (i, j) where i,j != k and Y[i,k] != 0 and Y[k,j] != 0:
          # Y[i,j] -= Y[i,k] * Y[k,j] / Y[k,k]
          # Complex division: (a+jb)/(c+jd) = ((ac+bd) + j(bc-ad)) / (c^2+d^2)

          # Find non-zero entries in row k and column k
          row_k =
            for {{r, c}, {g, b}} <- y, r == k, c != k, abs(g) + abs(b) > 1.0e-15, do: {c, {g, b}}

          col_k =
            for {{r, c}, {g, b}} <- y, c == k, r != k, abs(g) + abs(b) > 1.0e-15, do: {r, {g, b}}

          Enum.reduce(col_k, y, fn {i, {g_ik, b_ik}}, y_acc ->
            Enum.reduce(row_k, y_acc, fn {j, {g_kj, b_kj}}, y_acc2 ->
              # Y[i,k] * Y[k,j] (complex multiply)
              prod_g = g_ik * g_kj - b_ik * b_kj
              prod_b = g_ik * b_kj + b_ik * g_kj
              # / Y[k,k] (complex divide)
              update_g = (prod_g * g_kk + prod_b * b_kk) / denom_sq
              update_b = (prod_b * g_kk - prod_g * b_kk) / denom_sq

              add_complex(y_acc2, i, j, -update_g, -update_b)
            end)
          end)
        end
      end)

    # Extract only the keep x keep submatrix, reindexed to 0..n_keep-1
    for {{r, c}, {g, b}} <- y_final,
        Map.has_key?(keep_reindex, r),
        Map.has_key?(keep_reindex, c),
        into: %{} do
      {{Map.fetch!(keep_reindex, r), Map.fetch!(keep_reindex, c)}, {g, b}}
    end
  end

  defp default_xd_prime(gen) do
    case Map.get(gen, :fuel_type) do
      "NUC" -> 0.20
      "COL" -> 0.25
      ft when ft in ["NG", "OG", "DFO", "RFO", "PET"] -> 0.30
      ft when ft in ["WAT", "WH"] -> 0.35
      _ -> 0.30
    end
  end
end
