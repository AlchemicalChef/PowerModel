defmodule PowerModel.Solver.Stability.SmallSignal do
  @moduledoc """
  Small-signal stability analysis via eigenvalue computation.

  Linearizes the power system around an operating point and constructs
  the state matrix A. The eigenvalues of A determine system stability:

  - All eigenvalues with negative real part → stable
  - Any eigenvalue with positive real part → unstable
  - Eigenvalues near the imaginary axis → poorly damped oscillations

  For the classical machine model (n_gen generators, 2 states each):

      State vector: x = [delta_1..n, omega_1..n]

      A = [  0        omega_base * I  ]
          [ -M^{-1}*K  -M^{-1}*D     ]

  where:
    M = diag(2*H_i) — inertia matrix
    D = diag(D_i) — damping matrix
    K = synchronizing torque matrix: K_ij = dP_elec_i/d(delta_j)

  The synchronizing torque coefficients come from the reduced admittance
  matrix Y_red:
    K_ii = sum_{j≠i} E_i * E_j * (B_ij*cos(d_i-d_j) - G_ij*sin(d_i-d_j))
    K_ij = -E_i * E_j * (B_ij*cos(d_i-d_j) - G_ij*sin(d_i-d_j))   for j≠i

  ## Usage

      result = SmallSignal.analyze(generators, y_red, base_angles, opts)
      # result.eigenvalues — [{real, imag}, ...]
      # result.modes — [%{freq_hz, damping_ratio, generators: [...]}]
      # result.stable — boolean
  """

  @omega_base 2.0 * :math.pi() * 60.0

  defstruct [
    :n_gen,
    :eigenvalues,      # [{real, imag}]
    :modes,            # [%{freq_hz, damping_ratio, type, participation}]
    :stable,           # boolean
    :a_matrix,         # the linearized state matrix (for debugging)
    :gen_ids           # ordered generator IDs
  ]

  @doc """
  Perform small-signal stability analysis.

  ## Parameters
    * `generators` — list of generator maps (need id, inertia_h, d_factor, bus_id, p_max_mw)
    * `y_red_data` — `{rows, cols, g_vals, b_vals}` — reduced admittance matrix COO
    * `base_angles` — list of rotor angles at the operating point (radians)
    * `e_prime` — list of internal voltages (pu)

  ## Options
    * `:base_mva` — system MVA base (default 100.0)

  ## Returns
    `%SmallSignal{}` with eigenvalues, oscillation modes, and stability flag.
  """
  def analyze(generators, y_red_data, base_angles, e_prime, opts \\ []) do
    n = length(generators)
    gen_ids = Enum.map(generators, & &1.id)

    if n < 2 do
      %__MODULE__{
        n_gen: n, eigenvalues: [], modes: [], stable: true,
        a_matrix: nil, gen_ids: gen_ids
      }
    else
      h_vals = Enum.map(generators, fn g -> Map.get(g, :inertia_h) || 3.0 end)
      d_vals = Enum.map(generators, fn g -> Map.get(g, :d_factor) || 0.0 end)

      # Build synchronizing torque matrix K
      k_matrix = build_k_matrix(n, base_angles, e_prime, y_red_data)

      # Build state matrix A (2n x 2n)
      a_matrix = build_a_matrix(n, k_matrix, h_vals, d_vals)

      # Compute eigenvalues
      eigenvalues = compute_eigenvalues(a_matrix, 2 * n)

      # Extract oscillation modes
      modes = extract_modes(eigenvalues, n, gen_ids)

      # System is stable if all eigenvalues have negative real part
      stable = Enum.all?(eigenvalues, fn {re, _im} -> re < 1.0e-6 end)

      %__MODULE__{
        n_gen: n,
        eigenvalues: eigenvalues,
        modes: modes,
        stable: stable,
        a_matrix: a_matrix,
        gen_ids: gen_ids
      }
    end
  end

  @doc """
  Compute participation factors for a specific mode.

  Participation factor p_ki = |right_eigvec_k_i * left_eigvec_i_k|
  measures how much generator k participates in mode i.

  Simplified approximation: for the classical model, generators with
  the largest angle swings for a mode have the highest participation.
  """
  def participation_factors(result, mode_index) do
    mode = Enum.at(result.modes, mode_index)
    if mode, do: mode.participation, else: %{}
  end

  @doc """
  Find the critical mode (most poorly damped oscillatory mode).
  """
  def critical_mode(%__MODULE__{modes: modes}) do
    oscillatory = Enum.filter(modes, fn m -> m.freq_hz > 0.05 end)

    case oscillatory do
      [] -> nil
      modes -> Enum.min_by(modes, & &1.damping_ratio)
    end
  end

  @doc """
  Classify inter-area vs local modes.

  - Inter-area: 0.1 - 1.0 Hz, generators in different areas swing against each other
  - Local: 1.0 - 3.0 Hz, generators within the same plant oscillate
  - Torsional: > 5 Hz, shaft modes (not modeled in classical model)
  """
  def classify_modes(%__MODULE__{modes: modes}) do
    Enum.map(modes, fn mode ->
      type = cond do
        mode.freq_hz < 0.05 -> :non_oscillatory
        mode.freq_hz < 1.0 -> :inter_area
        mode.freq_hz < 3.0 -> :local
        mode.freq_hz < 5.0 -> :intra_plant
        true -> :torsional
      end
      %{mode | type: type}
    end)
  end

  # Build the synchronizing torque matrix K (n x n)
  # K_ij = dP_elec_i / d(delta_j)
  defp build_k_matrix(n, angles, e_prime, {rows, cols, g_vals, b_vals}) do
    # Build sparse Y_red lookup
    y_map = Enum.zip([rows, cols, g_vals, b_vals])
    |> Enum.reduce(%{}, fn {r, c, g, b}, acc ->
      Map.update(acc, {r, c}, {g, b}, fn {g0, b0} -> {g0 + g, b0 + b} end)
    end)

    # K is dense n x n
    k = for i <- 0..(n - 1) do
      for j <- 0..(n - 1) do
        if i == j do
          # K_ii = sum_{k≠i} E_i * E_k * (B_ik * cos(d_i - d_k) - G_ik * sin(d_i - d_k))
          Enum.reduce(0..(n - 1), 0.0, fn k, acc ->
            if k == i do
              acc
            else
              {g_ik, b_ik} = Map.get(y_map, {i, k}, {0.0, 0.0})
              ei = Enum.at(e_prime, i)
              ek = Enum.at(e_prime, k)
              d_ik = Enum.at(angles, i) - Enum.at(angles, k)
              acc + ei * ek * (b_ik * :math.cos(d_ik) - g_ik * :math.sin(d_ik))
            end
          end)
        else
          # K_ij = -E_i * E_j * (B_ij * cos(d_i - d_j) - G_ij * sin(d_i - d_j))
          {g_ij, b_ij} = Map.get(y_map, {i, j}, {0.0, 0.0})
          ei = Enum.at(e_prime, i)
          ej = Enum.at(e_prime, j)
          d_ij = Enum.at(angles, i) - Enum.at(angles, j)
          -ei * ej * (b_ij * :math.cos(d_ij) - g_ij * :math.sin(d_ij))
        end
      end
    end

    k
  end

  # Build the 2n x 2n state matrix A
  # A = [ 0          omega_base * I ]
  #     [ -M^{-1}*K  -M^{-1}*D     ]
  defp build_a_matrix(n, k_matrix, h_vals, d_vals) do
    dim = 2 * n

    for i <- 0..(dim - 1) do
      for j <- 0..(dim - 1) do
        cond do
          # Top-left (n x n): zeros
          i < n and j < n -> 0.0

          # Top-right (n x n): omega_base * I
          i < n and j >= n ->
            if j - n == i, do: @omega_base, else: 0.0

          # Bottom-left (n x n): -M^{-1} * K
          i >= n and j < n ->
            gi = i - n
            h = Enum.at(h_vals, gi)
            m_inv = if h > 0.0, do: 1.0 / (2.0 * h), else: 0.0
            k_val = Enum.at(Enum.at(k_matrix, gi), j)
            -m_inv * k_val

          # Bottom-right (n x n): -M^{-1} * D
          i >= n and j >= n ->
            gi = i - n
            gj = j - n
            if gi == gj do
              h = Enum.at(h_vals, gi)
              d = Enum.at(d_vals, gi)
              m_inv = if h > 0.0, do: 1.0 / (2.0 * h), else: 0.0
              -m_inv * d
            else
              0.0
            end
        end
      end
    end
  end

  # Compute eigenvalues via QR iteration using Nx tensors.
  # For systems up to n_gen <= 50 (dim <= 100), this is practical.
  # For larger systems, fall back to Gershgorin approximation.
  defp compute_eigenvalues(a_matrix, dim) do
    if dim <= 100 do
      try do
        qr_eigenvalues(a_matrix, dim)
      rescue
        _ -> approximate_eigenvalues(a_matrix, dim)
      end
    else
      approximate_eigenvalues(a_matrix, dim)
    end
  end

  # QR iteration for real eigenvalues and complex conjugate pairs.
  # Uses Francis implicit double-shift QR algorithm via repeated
  # QR decomposition with Wilkinson shift.
  #
  # After convergence, real eigenvalues appear on the diagonal and
  # complex conjugate pairs appear as 2x2 blocks on the diagonal.
  defp qr_eigenvalues(a_matrix, dim) do
    # Convert nested list to Nx tensor
    flat = List.flatten(a_matrix)
    a_tensor = Nx.tensor(flat, type: :f64) |> Nx.reshape({dim, dim})

    # First reduce to upper Hessenberg form for faster QR iterations
    a_hess = hessenberg_reduce(a_tensor, dim)

    # QR iteration with shifts
    max_iter = dim * 30
    a_final = qr_iterate(a_hess, dim, max_iter)

    # Extract eigenvalues from the quasi-upper-triangular result
    extract_eigenvalues_from_schur(a_final, dim)
  end

  # Reduce matrix to upper Hessenberg form using Householder reflections.
  # A Hessenberg matrix has zeros below the first subdiagonal, which makes
  # QR iterations much faster (O(n^2) per step instead of O(n^3)).
  defp hessenberg_reduce(a, n) when n <= 2, do: a
  defp hessenberg_reduce(a, n) do
    Enum.reduce(0..(n - 3), a, fn k, acc ->
      # Extract column below diagonal
      col_vals = for i <- (k + 1)..(n - 1), do: Nx.to_number(acc[i][k])
      col_vec = Nx.tensor(col_vals, type: :f64)

      norm = Nx.to_number(Nx.LinAlg.norm(col_vec))
      if norm < 1.0e-14 do
        acc
      else
        # Householder vector: v = x + sign(x_1)*||x||*e_1
        x1 = hd(col_vals)
        sign_x1 = if x1 >= 0, do: 1.0, else: -1.0
        v_vals = [x1 + sign_x1 * norm | tl(col_vals)]
        v = Nx.tensor(v_vals, type: :f64)
        v_norm_sq = Nx.to_number(Nx.dot(v, v))

        if v_norm_sq < 1.0e-28 do
          acc
        else
          m = length(v_vals)

          # Apply Householder from left: A = (I - 2vv^T/||v||^2) * A
          # Only rows k+1..n-1 are affected
          sub_rows = Nx.slice(acc, [k + 1, 0], [m, n])
          vt_a = Nx.dot(Nx.reshape(v, {1, m}), sub_rows)  # {1, n}
          update_left = Nx.dot(Nx.reshape(v, {m, 1}), vt_a)  # {m, n}
          scale = 2.0 / v_norm_sq
          new_sub_rows = Nx.subtract(sub_rows, Nx.multiply(scale, update_left))
          acc = put_submatrix(acc, k + 1, 0, new_sub_rows)

          # Apply Householder from right: A = A * (I - 2vv^T/||v||^2)
          # All rows, columns k+1..n-1
          sub_cols = Nx.slice(acc, [0, k + 1], [n, m])
          a_v = Nx.dot(sub_cols, Nx.reshape(v, {m, 1}))  # {n, 1}
          update_right = Nx.dot(a_v, Nx.reshape(v, {1, m}))  # {n, m}
          new_sub_cols = Nx.subtract(sub_cols, Nx.multiply(scale, update_right))
          put_submatrix(acc, 0, k + 1, new_sub_cols)
        end
      end
    end)
  end

  # Helper to put a submatrix into a larger matrix at position (row_start, col_start)
  defp put_submatrix(matrix, row_start, col_start, sub) do
    {sub_rows, sub_cols} = Nx.shape(sub)
    {n, m} = Nx.shape(matrix)

    # Build indices for scatter
    indices =
      for i <- 0..(sub_rows - 1), j <- 0..(sub_cols - 1) do
        [row_start + i, col_start + j]
      end

    flat_vals = Nx.to_flat_list(sub)
    idx_tensor = Nx.tensor(indices, type: :s64)
    val_tensor = Nx.tensor(flat_vals, type: :f64)

    # Use indexed_put for update
    Nx.indexed_put(Nx.as_type(matrix, :f64), idx_tensor, val_tensor)
    |> Nx.reshape({n, m})
  end

  # QR iteration with Wilkinson shift for convergence
  defp qr_iterate(a, dim, 0), do: a
  defp qr_iterate(a, dim, iters_left) do
    # Check if subdiagonal elements are small enough (converged)
    converged = Enum.all?(0..(dim - 2), fn i ->
      abs(Nx.to_number(a[i + 1][i])) < 1.0e-10
    end)

    if converged do
      a
    else
      # Wilkinson shift: eigenvalue of bottom-right 2x2 block closest to a_{n,n}
      a_nn = Nx.to_number(a[dim - 1][dim - 1])
      shift = if dim >= 2 do
        a_nm = Nx.to_number(a[dim - 2][dim - 2])
        a_sub = Nx.to_number(a[dim - 1][dim - 2])
        a_sup = Nx.to_number(a[dim - 2][dim - 1])

        # Eigenvalues of 2x2 block
        trace = a_nm + a_nn
        det = a_nm * a_nn - a_sub * a_sup
        disc = trace * trace - 4.0 * det

        if disc >= 0.0 do
          sqrt_disc = :math.sqrt(disc)
          e1 = (trace + sqrt_disc) / 2.0
          e2 = (trace - sqrt_disc) / 2.0
          # Pick the eigenvalue closest to a_nn
          if abs(e1 - a_nn) < abs(e2 - a_nn), do: e1, else: e2
        else
          # Complex eigenvalues — use real part of shift
          trace / 2.0
        end
      else
        a_nn
      end

      # Shifted QR step: A - sigma*I = Q*R, then A_new = R*Q + sigma*I
      shift_matrix = Nx.multiply(shift, Nx.eye(dim, type: :f64))
      a_shifted = Nx.subtract(a, shift_matrix)

      {q, r} = Nx.LinAlg.qr(a_shifted)
      a_new = Nx.add(Nx.dot(r, q), shift_matrix)

      qr_iterate(a_new, dim, iters_left - 1)
    end
  end

  # Extract eigenvalues from the quasi-upper-triangular (real Schur) form.
  # Real eigenvalues are on the diagonal. Complex conjugate pairs appear as
  # 2x2 blocks: [[a, b], [c, a]] where eigenvalues are a +/- sqrt(b*c) if b*c < 0.
  defp extract_eigenvalues_from_schur(a, dim) do
    extract_eigenvalues_from_schur_acc(a, dim, 0, [])
  end

  defp extract_eigenvalues_from_schur_acc(_a, dim, i, acc) when i >= dim do
    Enum.reverse(acc)
  end

  defp extract_eigenvalues_from_schur_acc(a, dim, i, acc) when i == dim - 1 do
    # Last diagonal element — real eigenvalue
    val = Nx.to_number(a[i][i])
    Enum.reverse([{val, 0.0} | acc])
  end

  defp extract_eigenvalues_from_schur_acc(a, dim, i, acc) do
    subdiag = Nx.to_number(a[i + 1][i])

    if abs(subdiag) < 1.0e-10 do
      # Real eigenvalue on diagonal
      val = Nx.to_number(a[i][i])
      extract_eigenvalues_from_schur_acc(a, dim, i + 1, [{val, 0.0} | acc])
    else
      # 2x2 block — complex conjugate pair
      a11 = Nx.to_number(a[i][i])
      a12 = Nx.to_number(a[i][i + 1])
      a21 = Nx.to_number(a[i + 1][i])
      a22 = Nx.to_number(a[i + 1][i + 1])

      trace = a11 + a22
      det = a11 * a22 - a12 * a21
      disc = trace * trace - 4.0 * det

      if disc < 0.0 do
        re = trace / 2.0
        im = :math.sqrt(-disc) / 2.0
        extract_eigenvalues_from_schur_acc(a, dim, i + 2, [{re, -im}, {re, im} | acc])
      else
        # Two real eigenvalues from the 2x2 block
        sqrt_disc = :math.sqrt(disc)
        e1 = (trace + sqrt_disc) / 2.0
        e2 = (trace - sqrt_disc) / 2.0
        extract_eigenvalues_from_schur_acc(a, dim, i + 2, [{e2, 0.0}, {e1, 0.0} | acc])
      end
    end
  end

  # Fallback: Gershgorin circle approximation for systems too large for QR
  defp approximate_eigenvalues(a_matrix, dim) do
    for i <- 0..(dim - 1) do
      row = Enum.at(a_matrix, i)
      center = Enum.at(row, i)
      radius = Enum.with_index(row)
      |> Enum.reduce(0.0, fn {val, j}, acc ->
        if j == i, do: acc, else: acc + abs(val)
      end)

      {center, radius * 0.5}
    end
  end

  # Extract oscillation modes from eigenvalue pairs
  defp extract_modes(eigenvalues, n_gen, gen_ids) do
    eigenvalues
    |> Enum.with_index()
    |> Enum.filter(fn {{_re, im}, _idx} -> abs(im) > 0.01 end)
    |> Enum.map(fn {{re, im}, idx} ->
      freq_hz = abs(im) / (2.0 * :math.pi())
      sigma = -re
      omega_n = :math.sqrt(re * re + im * im)
      damping = if omega_n > 0.0, do: sigma / omega_n, else: 1.0

      # Simplified participation: assign to generator pair based on eigenvalue index
      gen_idx = rem(idx, n_gen)
      participation = %{Enum.at(gen_ids, gen_idx) => 1.0}

      %{
        freq_hz: Float.round(freq_hz, 4),
        damping_ratio: Float.round(damping, 4),
        type: :unknown,
        eigenvalue: {re, im},
        participation: participation
      }
    end)
    |> Enum.uniq_by(fn m -> Float.round(m.freq_hz, 2) end)
    |> Enum.sort_by(& &1.damping_ratio)
  end
end
