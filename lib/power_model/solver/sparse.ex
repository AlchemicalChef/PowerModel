defmodule PowerModel.Solver.Sparse do
  @moduledoc """
  Wraps the Rust NIF for sparse matrix operations.
  Falls back to pure Elixir/Nx implementation when NIF is not available.

  When the Rust NIF shared library fails to load, each function raises
  via `:erlang.nif_error/1`. Callers must wrap calls in `try/rescue` and
  fall back to `solve_dense/2` or other pure-Elixir implementations.
  """

  use Rustler,
    otp_app: :power_model,
    crate: "sparse_solver"

  @doc "Create CSR matrix from triplet (COO) format"
  def csr_from_triplets(_rows, _cols, _reals, _imags, _n),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "LU factorization with partial pivoting (dense)"
  def lu_factorize(_matrix, _n), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Solve Ax=b using pre-computed LU factors (L, U, permutation)"
  def lu_solve(_l, _u, _perm, _rhs), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Add a branch (4 element updates) to triplet arrays"
  def csr_add_branch(_rows, _cols, _reals, _imags, _from, _to,
                     _y_series_re, _y_series_im, _y_shunt_re, _y_shunt_im, _n),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Remove a branch (negate contributions) from triplet arrays"
  def csr_remove_branch(_rows, _cols, _reals, _imags, _from, _to,
                        _y_series_re, _y_series_im, _y_shunt_re, _y_shunt_im, _n),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Solve a sparse symmetric positive definite system Ax = b via LDL^T factorization.

  Takes COO triplets (rows, cols, vals) defining the sparse matrix A, a
  right-hand side vector, and the matrix dimension n. Uses sparse LDL^T
  decomposition in Rust, which is suitable for the DC power flow B' matrix
  and scales to 45k+ bus grids.

  Returns `{:ok, solution_vector}` on success, or `{:error, reason}` on failure.
  Raises `:nif_not_loaded` when the Rust NIF is unavailable.
  """
  def sparse_solve(_rows, _cols, _vals, _rhs, _n), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Solve a sparse symmetric system for multiple right-hand sides with a single
  LDL^T factorization.

  Takes COO triplets (rows, cols, vals) defining the sparse matrix A, a list
  of RHS vectors, and the matrix dimension n. Factors once via LDL^T, then
  performs forward/back substitution for each RHS vector.

  This is more efficient than calling `sparse_solve/5` repeatedly when the
  matrix is the same but the RHS vectors differ (e.g., PTDF column computation).

  Returns `{:ok, [solution_1, solution_2, ...]}` on success.
  Raises `:nif_not_loaded` when the Rust NIF is unavailable.
  """
  def sparse_solve_multi_rhs(_rows, _cols, _vals, _rhs_list, _n),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Factor a sparse symmetric matrix via LDL^T and return an opaque handle.

  The returned handle (a NIF resource reference) can be passed to
  `sparse_cached_solve/2` or `sparse_cached_solve_multi/2` for repeated
  solves without re-factoring. The handle is reference-counted by the BEAM
  and freed when garbage collected.

  Returns `{:ok, handle}` on success.
  Raises `:nif_not_loaded` when the Rust NIF is unavailable.
  """
  def sparse_factor(_rows, _cols, _vals, _n), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Solve Ax = b using a pre-factored LDL^T handle from `sparse_factor/4`.

  Only performs forward/back substitution (no factorization), typically
  completing in under 5ms even for 70k-dimension systems.

  Returns `{:ok, solution_vector}` on success.
  Raises `:nif_not_loaded` when the Rust NIF is unavailable.
  """
  def sparse_cached_solve(_handle, _rhs), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Solve Ax = b for multiple RHS vectors using a pre-factored LDL^T handle.

  Combines cached factorization with batch solving. Each solve is independent
  forward/back substitution against the same factors.

  Returns `{:ok, [solution_1, solution_2, ...]}` on success.
  Raises `:nif_not_loaded` when the Rust NIF is unavailable.
  """
  def sparse_cached_solve_multi(_handle, _rhs_list), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Solve a sparse general (asymmetric) linear system Ax = b via sparse LU.

  Takes COO triplets (rows, cols, vals) defining the sparse matrix A, a
  right-hand side vector, and the matrix dimension n. Uses sparse LU
  factorization with partial pivoting via the `faer` Rust crate, which handles
  asymmetric matrices such as the Newton-Raphson Jacobian.

  For a 4500x4500 Jacobian with ~5-10 non-zeros per row, this typically
  completes in under 100ms (vs 30-60s for the dense O(n^3) solver).

  Returns `{:ok, solution_vector}` on success.
  Raises `:nif_not_loaded` when the Rust NIF is unavailable.
  """
  def sparse_lu_solve(_rows, _cols, _vals, _rhs, _n), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Solve a dense linear system Ax = b in a single NIF call.

  Takes a flat row-major matrix (n*n float64 values), a right-hand side
  vector (n float64 values), and the matrix dimension n. Performs LU
  factorization with partial pivoting and forward/back substitution entirely
  in Rust, returning only the solution vector.

  This is faster than separate `lu_factorize` + `lu_solve` calls because it
  avoids marshaling the L, U, and permutation arrays across the NIF boundary.

  Returns `{:ok, solution_vector}` on success.
  Raises `:nif_not_loaded` when the Rust NIF is unavailable.
  """
  def dense_solve_flat(_matrix_flat, _rhs, _n), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Kron-reduce a complex admittance matrix to retain only generator buses.

  Given the full Y-bus as COO triplets with separate real (G) and imaginary (B)
  parts, the total bus count `n`, and a list of generator bus indices to keep,
  eliminates all non-generator buses via Kron reduction:

      Y_red = Y_gg - Y_gn * Y_nn^{-1} * Y_ng

  Uses faer sparse LU factorization for the Y_nn solve. The returned COO indices
  are in the reduced 0..n_gen space (not original bus indices).

  Returns `{:ok, rows, cols, reals, imags}` on success.
  Raises `:nif_not_loaded` when the Rust NIF is unavailable.
  """
  def kron_reduce(_rows, _cols, _reals, _imags, _n, _gen_bus_indices),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Classical machine model transient stability simulation.

  Integrates the swing equations for `n_gen` generators connected through a
  Kron-reduced admittance matrix Y_red, using implicit trapezoidal integration
  (predict with forward Euler, correct with trapezoidal rule, 2 corrector iterations).

  ## Parameters

    * `n_gen` — number of generators
    * `delta_init` — initial rotor angles in radians [n_gen]
    * `omega_init` — initial rotor speeds in pu [n_gen] (1.0 = synchronous)
    * `p_mech` — mechanical power in pu [n_gen]
    * `e_prime` — internal voltage magnitude in pu [n_gen]
    * `h` — inertia constants in seconds [n_gen]
    * `d` — damping coefficients [n_gen]
    * `y_red_rows`, `y_red_cols`, `y_red_g`, `y_red_b` — Y_reduced as COO triplets
    * `dt` — timestep in seconds (e.g. 0.005)
    * `n_steps` — number of timesteps
    * `event_times`, `event_gen_indices`, `event_p_mech_new` — discrete events
    * `output_every` — output decimation factor (e.g. 10 records every 10th step)

  Returns `{:ok, trajectory}` where each row is `[time, delta_0..n-1, omega_0..n-1]`.
  Raises `:nif_not_loaded` when the Rust NIF is unavailable.
  """
  def transient_classical_simulate(
        _n_gen, _delta_init, _omega_init, _p_mech, _e_prime, _h, _d,
        _y_red_rows, _y_red_cols, _y_red_g, _y_red_b,
        _dt, _n_steps, _event_times, _event_gen_indices, _event_p_mech_new,
        _output_every),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Pure Elixir fallback: solve dense system using Nx.
  Used when Rust NIF is unavailable or for small test cases.
  """
  def solve_dense(a_matrix, b_vector) do
    a = Nx.tensor(a_matrix, type: :f64)
    b = Nx.tensor(b_vector, type: :f64)
    Nx.LinAlg.solve(a, b) |> Nx.to_list()
  end
end
