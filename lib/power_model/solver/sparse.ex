defmodule PowerModel.Solver.Sparse do
  @moduledoc """
  Wraps the Rust NIF for sparse matrix operations.
  Falls back to pure Elixir/Nx implementation when NIF is not available.

  When the Rust NIF shared library fails to load, each function returns
  `{:error, :nif_not_loaded}` instead of crashing the calling process.
  Callers can pattern-match on this and fall back to `solve_dense/2` or
  other pure-Elixir implementations.
  """

  use Rustler,
    otp_app: :power_model,
    crate: "sparse_solver"

  @doc "Create CSR matrix from triplet (COO) format"
  def csr_from_triplets(_rows, _cols, _reals, _imags, _n),
    do: {:error, :nif_not_loaded}

  @doc "LU factorization with partial pivoting (dense)"
  def lu_factorize(_matrix, _n), do: {:error, :nif_not_loaded}

  @doc "Solve Ax=b using pre-computed LU factors (L, U, permutation)"
  def lu_solve(_l, _u, _perm, _rhs), do: {:error, :nif_not_loaded}

  @doc "Add a branch (4 element updates) to triplet arrays"
  def csr_add_branch(_rows, _cols, _reals, _imags, _from, _to,
                     _y_series_re, _y_series_im, _y_shunt_re, _y_shunt_im, _n),
    do: {:error, :nif_not_loaded}

  @doc "Remove a branch (negate contributions) from triplet arrays"
  def csr_remove_branch(_rows, _cols, _reals, _imags, _from, _to,
                        _y_series_re, _y_series_im, _y_shunt_re, _y_shunt_im, _n),
    do: {:error, :nif_not_loaded}

  @doc """
  Solve a sparse symmetric positive definite system Ax = b via LDL^T factorization.

  Takes COO triplets (rows, cols, vals) defining the sparse matrix A, a
  right-hand side vector, and the matrix dimension n. Uses sparse LDL^T
  decomposition in Rust, which is suitable for the DC power flow B' matrix
  and scales to 45k+ bus grids.

  Returns `{:ok, solution_vector}` on success, or `{:error, reason}` on failure.
  Falls back to `{:error, :nif_not_loaded}` when the Rust NIF is unavailable.
  """
  def sparse_solve(_rows, _cols, _vals, _rhs, _n), do: {:error, :nif_not_loaded}

  @doc """
  Solve a dense linear system Ax = b in a single NIF call.

  Takes a flat row-major matrix (n*n float64 values), a right-hand side
  vector (n float64 values), and the matrix dimension n. Performs LU
  factorization with partial pivoting and forward/back substitution entirely
  in Rust, returning only the solution vector.

  This is faster than separate `lu_factorize` + `lu_solve` calls because it
  avoids marshaling the L, U, and permutation arrays across the NIF boundary.

  Returns `{:ok, solution_vector}` on success.
  Falls back to `{:error, :nif_not_loaded}` when the Rust NIF is unavailable.
  """
  def dense_solve_flat(_matrix_flat, _rhs, _n), do: {:error, :nif_not_loaded}

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
