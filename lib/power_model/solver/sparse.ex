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
  Solve a sparse symmetric system Ax = b via LDL^T factorization.

  Superseded by `sparse_solve_checked/5`. This returns whatever the
  factorization produced with no way for the caller to tell a good answer from
  a bad one, which is unsafe on any matrix that is not *guaranteed* positive
  definite. Kept so existing callers keep working; prefer the checked call.

  Returns `{:ok, solution_vector}` on success, or `{:error, reason}` on failure.
  Raises `ErlangError` when the Rust NIF is unavailable.
  """
  def sparse_solve(_rows, _cols, _vals, _rhs, _n), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Solve a sparse system via LDL^T and verify the result against the triplets.

  Same factorization as `sparse_solve/5`, but the residual `b - Ax` is
  recomputed natively from the caller's own COO triplets and returned. This is
  the call to use whenever the matrix is not *guaranteed* symmetric positive
  definite: `sprs-ldl` does not pivot and only rejects an exactly-zero pivot,
  so an indefinite matrix factorizes "successfully" and can hand back garbage.
  Checking the residual turns that silent failure into a visible one, and it
  costs O(nnz) in native code — negligible next to the factorization.

  Returns:

    * `{:ok, x, relative_residual}` — `relative_residual` is
      `‖b - Ax‖∞ / max(1, ‖b‖∞)` and is always a finite float. The caller
      picks the tolerance; a healthy DC power-flow solve lands near 1.0e-12.
    * `{:error, :factorization_failed}` — LDL^T hit a zero pivot.
    * `{:error, :not_finite}` — the solution or its residual was NaN/infinite.
    * `{:error, message}` — a binary describing a malformed input (triplet
      arrays of unequal length, an out-of-bounds index, a right-hand side that
      does not match `n`, or `n == 0`).

  Raises `ErlangError` when the Rust NIF is unavailable.
  """
  def sparse_solve_checked(_rows, _cols, _vals, _rhs, _n),
    do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Factor once, solve many
  #
  # `sparse_solve_checked/5` factorizes on every call, which is right when the
  # matrix changes every time (a cascade retopologizes between DC solves). When
  # the matrix is instead held fixed across many right-hand sides, factor once
  # with `sparse_factor/4` and back-substitute with the cached calls. The two
  # callers this exists for:
  #
  #   * fast-decoupled AC power flow — B' and B'' are constant for as long as
  #     the topology is, so one factorization serves every iteration;
  #   * PTDF/LODF screening — one B', one right-hand side per outage.
  #
  # The handle is an opaque reference counted by the BEAM; it is freed when no
  # Elixir term refers to it any more. It must be discarded and rebuilt whenever
  # the matrix changes — nothing detects a stale handle, because the factors
  # carry no memory of the topology they came from.
  # ---------------------------------------------------------------------------

  @doc """
  Factor a sparse symmetric matrix and return a handle for repeated solves.

  Same factorization policy as `sparse_solve_checked/5` (fill-reducing
  ordering, no bit-exact symmetry demand, scalar systems handled directly),
  but the factors are kept alive so back-substitution can be repeated without
  paying for the factorization again.

  Returns `{:ok, handle}`, `{:error, :factorization_failed}` when LDL^T hits a
  zero pivot or the system is a singular 1x1, or `{:error, message}` (a binary)
  for a malformed triplet set.

  A successful factorization is **not** a promise of a usable answer. LDL^T
  here is unpivoted, so an indefinite matrix — a B' carrying a
  series-compensated branch, for instance — factors without complaint. There is
  no right-hand side to verify against at factor time, so that case is caught
  per-solve by the residual returned from `sparse_cached_solve/2`. Callers must
  apply the same tolerance they would to `sparse_solve_checked/5` and fall back
  loudly rather than trusting a handle just because it was produced.

  Raises `ErlangError` when the Rust NIF is unavailable.
  """
  def sparse_factor(_rows, _cols, _vals, _n), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Solve `Ax = b` against a handle from `sparse_factor/4`.

  Back-substitution only — no factorization — plus the same residual
  verification `sparse_solve_checked/5` performs, so a cached factorization
  cannot become a way to skip the SPD guard.

  Returns `{:ok, x, relative_residual}`, `{:error, :not_finite}`, or
  `{:error, message}` (a binary) when the right-hand side length does not match
  the factored dimension.
  """
  def sparse_cached_solve(_handle, _rhs), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Solve a batch of right-hand sides against one handle from `sparse_factor/4`.

  Each solve is independent back-substitution against the same factors.

  Returns `{:ok, [x_1, ..., x_k], worst_relative_residual}` — one residual
  covering the whole batch, since the caller's decision is go/no-go on the set.
  Returns `{:error, :not_finite}` if any solve in the batch produces a
  non-finite result, rather than handing back a partly-good batch, or
  `{:error, message}` (a binary) if any right-hand side is the wrong length.
  """
  def sparse_cached_solve_multi(_handle, _rhs_list), do: :erlang.nif_error(:nif_not_loaded)

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
