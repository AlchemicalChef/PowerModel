defmodule PowerModel.Solver.Sparse do
  @moduledoc """
  Wraps the Rust NIF for sparse matrix operations.
  Falls back to pure Elixir/Nx implementation when NIF is not available.

  When the Rust NIF shared library fails to load, each stub raises via
  `:erlang.nif_error/1` (the standard Rustler idiom). Every caller wraps
  these calls in `try/rescue` and falls back to `solve_dense/2` or another
  pure-Elixir implementation, so a missing NIF degrades gracefully.
  """

  use Rustler,
    otp_app: :power_model,
    crate: "sparse_solver"

  # ---------------------------------------------------------------------------
  # NIF stubs
  #
  # When the Rust NIF loads successfully, Rustler replaces each function body
  # with a call into the native code. :erlang.nif_error/1 has bottom type, so
  # the compiler doesn't narrow these functions' return types to the stub
  # value (an error-tuple stub makes every caller's {:ok, ...} clause a
  # "can never match" typing violation).
  # ---------------------------------------------------------------------------

  @doc "Create CSR matrix from triplet (COO) format"
  def csr_from_triplets(_rows, _cols, _reals, _imags, _n),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "LU factorization with partial pivoting (dense)"
  def lu_factorize(_matrix, _n), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Solve Ax=b using pre-computed LU factors (L, U, permutation)"
  def lu_solve(_l, _u, _perm, _rhs), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Add a branch (4 element updates) to triplet arrays"
  def csr_add_branch(
        _rows,
        _cols,
        _reals,
        _imags,
        _from,
        _to,
        _y_series_re,
        _y_series_im,
        _y_shunt_re,
        _y_shunt_im,
        _n
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  @doc "Remove a branch (negate contributions) from triplet arrays"
  def csr_remove_branch(
        _rows,
        _cols,
        _reals,
        _imags,
        _from,
        _to,
        _y_series_re,
        _y_series_im,
        _y_shunt_re,
        _y_shunt_im,
        _n
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Solve a sparse symmetric positive definite system Ax = b via LDL^T factorization.

  Takes COO triplets (rows, cols, vals) defining the sparse matrix A, a
  right-hand side vector, and the matrix dimension n. Uses sparse LDL^T
  decomposition in Rust, which is suitable for the DC power flow B' matrix
  and scales to 45k+ bus grids.

  Returns `{:ok, solution_vector}` on success, or `{:error, reason}` on failure.
  Raises `ErlangError` when the Rust NIF is unavailable.
  """
  def sparse_solve(_rows, _cols, _vals, _rhs, _n), do: :erlang.nif_error(:nif_not_loaded)

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
