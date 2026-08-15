use rustler::{Atom, Encoder, Env, NifResult, ResourceArc, Term};
use sprs::{CsMat, TriMat};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        singular_matrix,
        factorization_failed,
        not_finite
    }
}

// ---------------------------------------------------------------------------
// Shared factorization policy
//
// Everything that factorizes an LDL^T goes through `factorize`, so the
// one-shot and cached paths cannot drift apart on ordering, symmetry checking
// or the scalar special case.
// ---------------------------------------------------------------------------

enum Factorization {
    Ldl(sprs_ldl::LdlNumeric<f64, usize>),
    /// sprs-ldl asserts n > 1 (a capacity assertion in `sprs::stack`), so a
    /// 1x1 system carries its single coefficient instead of a factorization.
    /// Two-bus islands reduce to exactly this after slack elimination.
    Scalar(f64),
}

fn factorize(csc: &CsMat<f64>) -> Option<Factorization> {
    if csc.rows() == 1 {
        // `TriMat` has already summed duplicates, so there is at most one
        // stored entry; summing is simply robust to there being none.
        let a: f64 = csc
            .outer_iterator()
            .next()
            .map(|col| col.iter().map(|(_, &v)| v).sum())
            .unwrap_or(0.0);

        return if a.abs() > 1e-15 && a.is_finite() {
            Some(Factorization::Scalar(a))
        } else {
            None
        };
    }

    // `DontCheckSymmetry` is deliberate. sprs-ldl's symmetry test compares
    // values with `==`, and `TriMat` accumulates duplicate positions in
    // whatever order its unstable sort leaves them, so two parallel branches
    // between the same pair of buses can make A[i][j] and A[j][i] differ in
    // the last bit and abort an otherwise healthy factorization. Nothing is
    // taken on trust: genuine asymmetry shows up in the residual check that
    // every solve against these factors performs.
    //
    // Reverse Cuthill-McKee is the builder's default fill-reducing ordering.
    // `LdlNumeric::new` factorizes under the identity permutation instead,
    // which on a grid-sized B' means dramatically more fill-in in L.
    sprs_ldl::Ldl::new()
        .check_symmetry(sprs::SymmetryCheck::DontCheckSymmetry)
        .numeric(csc.view())
        .ok()
        .map(Factorization::Ldl)
}

impl Factorization {
    /// Back-substitute, rejecting any non-finite result before it can reach a
    /// BEAM term (the VM has no representation for NaN or infinity).
    fn solve(&self, rhs: &[f64]) -> Option<Vec<f64>> {
        let x = match self {
            Self::Scalar(a) => vec![rhs[0] / a],
            Self::Ldl(ldl) => ldl.solve(rhs),
        };

        if x.iter().all(|v| v.is_finite()) {
            Some(x)
        } else {
            None
        }
    }
}

// ---------------------------------------------------------------------------
// Residual verification
//
// `‖b - Ax‖∞ / max(1, ‖b‖∞)`. This is what makes it safe to factorize a matrix
// whose positive definiteness is not guaranteed: sprs-ldl does not pivot and
// only rejects an exactly-zero pivot, so an indefinite matrix factorizes
// "successfully" and can return a numerically worthless answer.
// ---------------------------------------------------------------------------

fn relative_residual(resid: &[f64], rhs: &[f64]) -> Option<f64> {
    let resid_inf = resid.iter().fold(0.0f64, |m, v| m.max(v.abs()));
    let rhs_inf = rhs.iter().fold(0.0f64, |m, v| m.max(v.abs()));
    let relative = resid_inf / rhs_inf.max(1.0);

    if relative.is_finite() {
        Some(relative)
    } else {
        None
    }
}

/// r = b - Ax accumulated straight from the caller's COO triplets. Stronger
/// than working from the assembled matrix: it also covers the CSC conversion.
fn triplet_residual(
    rows: &[usize],
    cols: &[usize],
    vals: &[f64],
    x: &[f64],
    rhs: &[f64],
) -> Vec<f64> {
    let mut resid = rhs.to_vec();
    for i in 0..rows.len() {
        resid[rows[i]] -= vals[i] * x[cols[i]];
    }
    resid
}

/// r = b - Ax from an assembled CSC matrix. Used by the cached path, which
/// keeps the factored matrix rather than the triplets it was built from.
fn csc_residual(mat: &CsMat<f64>, x: &[f64], rhs: &[f64]) -> Vec<f64> {
    let mut resid = rhs.to_vec();
    for (col, column) in mat.outer_iterator().enumerate() {
        let x_col = x[col];
        if x_col != 0.0 {
            for (row, &v) in column.iter() {
                resid[row] -= v * x_col;
            }
        }
    }
    resid
}

// ---------------------------------------------------------------------------
// Cached LDL^T factorization resource
// ---------------------------------------------------------------------------

/// A factorization held across NIF calls, so a caller that solves the same
/// matrix against many right-hand sides pays for the factorization once.
/// Fast-decoupled AC power flow (B' and B'' are constant while the topology
/// is) and PTDF/LODF screening (one B', one RHS per outage) are the two
/// callers this exists for.
///
/// The matrix that was factored is retained so every cached solve can be
/// residual-verified, exactly as the one-shot path is.
///
/// Immutable after construction: `LdlNumeric::solve` takes `&self` and
/// allocates its own working vector rather than touching the factorization's
/// stored workspaces, so concurrent solves from several BEAM schedulers are
/// safe. Rustler's `Resource` trait requires `Send + Sync`, and both are
/// derived rather than asserted — every field is `Vec`-backed.
struct LdlResource {
    factorization: Factorization,
    matrix: CsMat<f64>,
    n: usize,
}

#[rustler::resource_impl]
impl rustler::Resource for LdlResource {}

impl LdlResource {
    /// `Ok((x, relative_residual))`, or `Err(())` when the solution or its
    /// residual is non-finite.
    fn solve_verified(&self, rhs: &[f64]) -> Result<(Vec<f64>, f64), ()> {
        let x = self.factorization.solve(rhs).ok_or(())?;
        let resid = csc_residual(&self.matrix, &x, rhs);
        let relative = relative_residual(&resid, rhs).ok_or(())?;
        Ok((x, relative))
    }
}

/// Validate COO inputs and assemble them into a CSC matrix.
///
/// `TriMat` sums duplicate entries, which is what makes it correct to emit
/// four independent triplets per branch during B'/Y-bus assembly instead of
/// consolidating on the Elixir side.
fn build_csc(
    rows: &[usize],
    cols: &[usize],
    vals: &[f64],
    rhs: &[f64],
    n: usize,
) -> Result<CsMat<f64>, &'static str> {
    let nnz = rows.len();
    if cols.len() != nnz || vals.len() != nnz {
        return Err("triplet arrays (rows, cols, vals) must have equal length");
    }
    if rhs.len() != n {
        return Err("rhs length must equal matrix dimension n");
    }
    if n == 0 {
        return Err("matrix dimension n must be greater than zero");
    }

    // Validate index bounds before building the matrix to avoid panics
    // inside sprs::TriMat::add_triplet.
    for i in 0..nnz {
        if rows[i] >= n || cols[i] >= n {
            return Err("triplet index out of bounds for matrix dimension n");
        }
    }

    let mut tri: TriMat<f64> = TriMat::new((n, n));
    tri.reserve(nnz);
    for i in 0..nnz {
        tri.add_triplet(rows[i], cols[i], vals[i]);
    }

    Ok(tri.to_csc::<usize>())
}

/// Create a CSR matrix from triplet (COO) format.
/// Returns flattened CSR storage arrays for Elixir.
#[rustler::nif]
fn csr_from_triplets(
    rows: Vec<usize>,
    cols: Vec<usize>,
    reals: Vec<f64>,
    imags: Vec<f64>,
    n: usize,
) -> NifResult<(Atom, Vec<usize>, Vec<usize>, Vec<f64>, Vec<f64>, usize)> {
    let nnz = rows.len();

    let mut tri_real: TriMat<f64> = TriMat::new((n, n));
    let mut tri_imag: TriMat<f64> = TriMat::new((n, n));

    for i in 0..nnz {
        if reals[i].abs() > 1e-15 {
            tri_real.add_triplet(rows[i], cols[i], reals[i]);
        }
        if imags[i].abs() > 1e-15 {
            tri_imag.add_triplet(rows[i], cols[i], imags[i]);
        }
    }

    let csr_real = tri_real.to_csr::<usize>();
    let csr_imag = tri_imag.to_csr::<usize>();

    let (indptr, indices, data) = csr_real.into_raw_storage();
    let (_, _, data_imag) = csr_imag.into_raw_storage();

    Ok((atoms::ok(), indptr, indices, data, data_imag, n))
}

/// LU factorization with partial pivoting (dense, for moderate sizes)
#[rustler::nif(schedule = "DirtyCpu")]
fn lu_factorize<'a>(env: Env<'a>, matrix: Vec<Vec<f64>>, n: usize) -> NifResult<Term<'a>> {
    let mut a: Vec<Vec<f64>> = matrix;
    let mut l = vec![vec![0.0; n]; n];
    let mut u = vec![vec![0.0; n]; n];
    let mut perm: Vec<usize> = (0..n).collect();

    for k in 0..n {
        // Partial pivoting
        let mut max_val = a[k][k].abs();
        let mut max_row = k;
        for i in (k + 1)..n {
            if a[i][k].abs() > max_val {
                max_val = a[i][k].abs();
                max_row = i;
            }
        }

        if max_val <= 1e-15 {
            return Ok((atoms::error(), atoms::singular_matrix()).encode(env));
        }

        if max_row != k {
            a.swap(k, max_row);
            l.swap(k, max_row);
            perm.swap(k, max_row);
        }

        l[k][k] = 1.0;
        for j in k..n {
            u[k][j] = a[k][j];
        }

        for i in (k + 1)..n {
            l[i][k] = a[i][k] / u[k][k];
            for j in (k + 1)..n {
                a[i][j] -= l[i][k] * u[k][j];
            }
        }
    }

    Ok((atoms::ok(), l, u, perm).encode(env))
}

/// Solve using LU factors: L*U*x = P*b
#[rustler::nif(schedule = "DirtyCpu")]
fn lu_solve<'a>(
    env: Env<'a>,
    l: Vec<Vec<f64>>,
    u: Vec<Vec<f64>>,
    perm: Vec<usize>,
    rhs: Vec<f64>,
) -> NifResult<Term<'a>> {
    let n = rhs.len();

    // Apply permutation
    let mut pb = vec![0.0; n];
    for i in 0..n {
        pb[i] = rhs[perm[i]];
    }

    // Forward substitution: L*y = P*b
    let mut y = vec![0.0; n];
    for i in 0..n {
        y[i] = pb[i];
        for j in 0..i {
            y[i] -= l[i][j] * y[j];
        }
    }

    // Back substitution: U*x = y
    let mut x = vec![0.0; n];
    for i in (0..n).rev() {
        x[i] = y[i];
        for j in (i + 1)..n {
            x[i] -= u[i][j] * x[j];
        }
        if u[i][i].abs() <= 1e-15 {
            return Ok((atoms::error(), atoms::singular_matrix()).encode(env));
        }
        x[i] /= u[i][i];
    }

    Ok((atoms::ok(), x).encode(env))
}

/// Add branch contributions to Y-bus triplet arrays
#[rustler::nif]
fn csr_add_branch(
    rows: Vec<usize>,
    cols: Vec<usize>,
    reals: Vec<f64>,
    imags: Vec<f64>,
    from: usize,
    to: usize,
    y_series_re: f64,
    y_series_im: f64,
    y_shunt_re: f64,
    y_shunt_im: f64,
    _n: usize,
) -> NifResult<(Atom, Vec<usize>, Vec<usize>, Vec<f64>, Vec<f64>)> {
    let mut new_rows = rows;
    let mut new_cols = cols;
    let mut new_reals = reals;
    let mut new_imags = imags;

    // Diagonal: from,from += y_series + y_shunt
    new_rows.push(from);
    new_cols.push(from);
    new_reals.push(y_series_re + y_shunt_re);
    new_imags.push(y_series_im + y_shunt_im);

    // Diagonal: to,to += y_series + y_shunt
    new_rows.push(to);
    new_cols.push(to);
    new_reals.push(y_series_re + y_shunt_re);
    new_imags.push(y_series_im + y_shunt_im);

    // Off-diag: from,to -= y_series
    new_rows.push(from);
    new_cols.push(to);
    new_reals.push(-y_series_re);
    new_imags.push(-y_series_im);

    // Off-diag: to,from -= y_series
    new_rows.push(to);
    new_cols.push(from);
    new_reals.push(-y_series_re);
    new_imags.push(-y_series_im);

    Ok((atoms::ok(), new_rows, new_cols, new_reals, new_imags))
}

/// Remove branch (negate contributions)
#[rustler::nif]
fn csr_remove_branch(
    rows: Vec<usize>,
    cols: Vec<usize>,
    reals: Vec<f64>,
    imags: Vec<f64>,
    from: usize,
    to: usize,
    y_series_re: f64,
    y_series_im: f64,
    y_shunt_re: f64,
    y_shunt_im: f64,
    _n: usize,
) -> NifResult<(Atom, Vec<usize>, Vec<usize>, Vec<f64>, Vec<f64>)> {
    let mut new_rows = rows;
    let mut new_cols = cols;
    let mut new_reals = reals;
    let mut new_imags = imags;

    // Negate and add
    new_rows.push(from);
    new_cols.push(from);
    new_reals.push(-(y_series_re + y_shunt_re));
    new_imags.push(-(y_series_im + y_shunt_im));

    new_rows.push(to);
    new_cols.push(to);
    new_reals.push(-(y_series_re + y_shunt_re));
    new_imags.push(-(y_series_im + y_shunt_im));

    new_rows.push(from);
    new_cols.push(to);
    new_reals.push(y_series_re);
    new_imags.push(y_series_im);

    new_rows.push(to);
    new_cols.push(from);
    new_reals.push(y_series_re);
    new_imags.push(y_series_im);

    Ok((atoms::ok(), new_rows, new_cols, new_reals, new_imags))
}

/// Solve a sparse symmetric system Ax = b by LDL^T factorization.
///
/// **Superseded by `sparse_solve_checked/5`**, which is this call plus the
/// residual verification that turns an unpivoted LDL^T into a safe thing to
/// run on a matrix that might not be positive definite. This one returns
/// whatever the factorization produced, with no way for the caller to tell a
/// good answer from a bad one; it is kept only so an existing caller does not
/// break. Prefer `sparse_solve_checked/5` in new code.
///
/// # Arguments
///
/// * `rows` - Row indices of COO triplets
/// * `cols` - Column indices of COO triplets
/// * `vals` - Values of COO triplets
/// * `rhs`  - Right-hand side vector b
/// * `n`    - Matrix dimension (n x n)
///
/// # Errors
///
/// Returns an error term if the triplet arrays disagree in length, the RHS
/// length does not match `n`, `n` is zero, an index is out of bounds, or the
/// factorization fails.
#[rustler::nif(schedule = "DirtyCpu")]
fn sparse_solve(
    rows: Vec<usize>,
    cols: Vec<usize>,
    vals: Vec<f64>,
    rhs: Vec<f64>,
    n: usize,
) -> NifResult<(Atom, Vec<f64>)> {
    let csc = build_csc(&rows, &cols, &vals, &rhs, n)
        .map_err(|msg| rustler::Error::Term(Box::new(msg)))?;

    // Shares `factorize` with every other path rather than calling
    // `LdlNumeric::new` directly: the latter factorizes under the identity
    // permutation and panics on a matrix that is only symmetric to within a
    // rounding error, both of which are fatal on real grid data.
    let factorization = factorize(&csc).ok_or_else(|| {
        rustler::Error::Term(Box::new("sparse LDL factorization failed".to_string()))
    })?;

    let solution = factorization.solve(&rhs).ok_or_else(|| {
        rustler::Error::Term(Box::new(
            "sparse LDL solve produced a non-finite result".to_string(),
        ))
    })?;

    Ok((atoms::ok(), solution))
}

/// Solve `Ax = b` by sparse LDL^T and verify the answer against the input.
///
/// Same factorization as `sparse_solve/5`, plus the check that makes it safe
/// to use on a matrix whose positive definiteness is not guaranteed. `sprs-ldl`
/// performs no pivoting and only rejects an exactly-zero pivot, so an
/// indefinite matrix — which is what a series-compensated (negative reactance)
/// branch can turn B' into — factorizes "successfully" and returns a solution
/// that may be numerically worthless. The residual is therefore recomputed from
/// the caller's own triplets rather than from the factors, which catches a bad
/// factorization, a bad CSC conversion and an indefinite system alike.
///
/// Returns `{:ok, x, relative_residual}` where `relative_residual` is
/// `‖b − Ax‖∞ / max(1, ‖b‖∞)` and is always finite; the caller decides what
/// tolerance to accept. Returns `{:error, :factorization_failed}` when LDL^T
/// itself fails and `{:error, :not_finite}` when the solution or its residual
/// contains a non-finite value.
#[rustler::nif(schedule = "DirtyCpu")]
fn sparse_solve_checked<'a>(
    env: Env<'a>,
    rows: Vec<usize>,
    cols: Vec<usize>,
    vals: Vec<f64>,
    rhs: Vec<f64>,
    n: usize,
) -> NifResult<Term<'a>> {
    let csc = build_csc(&rows, &cols, &vals, &rhs, n)
        .map_err(|msg| rustler::Error::Term(Box::new(msg)))?;

    let factorization = match factorize(&csc) {
        Some(f) => f,
        None => return Ok((atoms::error(), atoms::factorization_failed()).encode(env)),
    };

    let x = match factorization.solve(&rhs) {
        Some(x) => x,
        None => return Ok((atoms::error(), atoms::not_finite()).encode(env)),
    };

    let resid = triplet_residual(&rows, &cols, &vals, &x, &rhs);

    match relative_residual(&resid, &rhs) {
        Some(relative) => Ok((atoms::ok(), x, relative).encode(env)),
        None => Ok((atoms::error(), atoms::not_finite()).encode(env)),
    }
}

// ---------------------------------------------------------------------------
// Factor once, solve many
// ---------------------------------------------------------------------------

/// Factor a sparse symmetric matrix and return a reusable handle.
///
/// Same factorization policy as `sparse_solve_checked/5` — fill-reducing
/// ordering, no bit-exact symmetry demand, scalar systems handled directly —
/// but the factors are kept alive in a resource so that back-substitution can
/// be repeated without paying for the factorization again. Reference-counted
/// by the BEAM and freed once no Elixir term refers to it.
///
/// This is the call for fast-decoupled AC power flow, where B' and B'' are
/// constant for as long as the topology is, and for PTDF/LODF screening, where
/// one B' is solved against one right-hand side per outage.
///
/// Returns `{:ok, handle}`, or `{:error, :factorization_failed}` when LDL^T
/// hits a zero pivot or the system is a singular scalar. Note that a
/// *successful* factorization is not a promise of a usable answer: LDL^T is
/// unpivoted, so an indefinite matrix factors without complaint. That is
/// caught per-solve by the residual, not here — there is no right-hand side to
/// verify against at factor time.
///
/// Scheduled on DirtyCpu: factorization is O(nnz * fill-in) and runs into
/// hundreds of milliseconds at grid scale.
#[rustler::nif(schedule = "DirtyCpu")]
fn sparse_factor<'a>(
    env: Env<'a>,
    rows: Vec<usize>,
    cols: Vec<usize>,
    vals: Vec<f64>,
    n: usize,
) -> NifResult<Term<'a>> {
    // `build_csc` validates the RHS length too, so hand it one of the right
    // size; no right-hand side exists at factor time.
    let placeholder = vec![0.0; n];
    let csc = build_csc(&rows, &cols, &vals, &placeholder, n)
        .map_err(|msg| rustler::Error::Term(Box::new(msg)))?;

    match factorize(&csc) {
        Some(factorization) => {
            let resource = ResourceArc::new(LdlResource {
                factorization,
                matrix: csc,
                n,
            });
            Ok((atoms::ok(), resource).encode(env))
        }
        None => Ok((atoms::error(), atoms::factorization_failed()).encode(env)),
    }
}

/// Solve `Ax = b` against a handle from `sparse_factor/4`.
///
/// Back-substitution only, plus the same residual verification the one-shot
/// path performs — a cached factorization must not become a way to skip the
/// SPD guard. Returns `{:ok, x, relative_residual}` or
/// `{:error, :not_finite}`.
///
/// Scheduled on DirtyCpu. Back-substitution at grid scale exceeds the ~1 ms a
/// NIF may occupy a normal scheduler for, and stalling a scheduler thread hurts
/// every other process on the node.
#[rustler::nif(schedule = "DirtyCpu")]
fn sparse_cached_solve<'a>(
    env: Env<'a>,
    handle: ResourceArc<LdlResource>,
    rhs: Vec<f64>,
) -> NifResult<Term<'a>> {
    if rhs.len() != handle.n {
        return Err(rustler::Error::Term(Box::new(format!(
            "rhs length {} does not equal factored matrix dimension {}",
            rhs.len(),
            handle.n
        ))));
    }

    match handle.solve_verified(&rhs) {
        Ok((x, relative)) => Ok((atoms::ok(), x, relative).encode(env)),
        Err(()) => Ok((atoms::error(), atoms::not_finite()).encode(env)),
    }
}

/// Solve a batch of right-hand sides against one handle.
///
/// Each solve is independent back-substitution against the same factors, so
/// this is the shape PTDF/LODF screening wants: one factorization, one
/// right-hand side per outage.
///
/// Returns `{:ok, [x_1, ..., x_k], worst_relative_residual}` — a single
/// residual covering the batch, since a caller's decision is go/no-go on the
/// whole set. Returns `{:error, :not_finite}` if any solve in the batch
/// produces a non-finite result, rather than returning a partly-good batch.
#[rustler::nif(schedule = "DirtyCpu")]
fn sparse_cached_solve_multi<'a>(
    env: Env<'a>,
    handle: ResourceArc<LdlResource>,
    rhs_list: Vec<Vec<f64>>,
) -> NifResult<Term<'a>> {
    for (idx, rhs) in rhs_list.iter().enumerate() {
        if rhs.len() != handle.n {
            return Err(rustler::Error::Term(Box::new(format!(
                "rhs_list[{idx}] length {} does not equal factored matrix dimension {}",
                rhs.len(),
                handle.n
            ))));
        }
    }

    let mut solutions = Vec::with_capacity(rhs_list.len());
    let mut worst = 0.0f64;

    for rhs in &rhs_list {
        match handle.solve_verified(rhs) {
            Ok((x, relative)) => {
                worst = worst.max(relative);
                solutions.push(x);
            }
            Err(()) => return Ok((atoms::error(), atoms::not_finite()).encode(env)),
        }
    }

    Ok((atoms::ok(), solutions, worst).encode(env))
}

rustler::init!("Elixir.PowerModel.Solver.Sparse");
