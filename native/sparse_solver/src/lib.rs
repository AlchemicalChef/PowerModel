use rustler::{Atom, Env, NifResult, ResourceArc, Term};
use sprs::TriMat;
use std::f64::consts::PI;

use faer::linalg::solvers::Solve;
use faer::sparse::linalg::solvers::{Lu, SymbolicLu};
use faer::sparse::{SparseColMat, Triplet};

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

// ---------------------------------------------------------------------------
// Cached LDL^T factorization resource
// ---------------------------------------------------------------------------

/// Holds a pre-computed LDL^T factorization that can be reused across NIF calls
/// via Rustler's ResourceArc. The factorization is immutable after creation,
/// so concurrent solves from multiple BEAM schedulers are safe.
struct LdlResource {
    ldl: sprs_ldl::LdlNumeric<f64, usize>,
    n: usize,
}

// sprs_ldl::LdlNumeric stores Vec<f64>, Vec<usize>, and a CsMat (also Vecs).
// These are all Send + Sync, but the struct itself does not derive them.
// We only hand out &self references for solving (no mutation), so this is safe.
unsafe impl Send for LdlResource {}
unsafe impl Sync for LdlResource {}

fn load(env: Env, _info: Term) -> bool {
    // The rustler::resource! macro generates a non-local impl and an unused Result;
    // both warnings originate inside the macro and are not actionable here.
    #[allow(non_local_definitions, unused_must_use)]
    {
        rustler::resource!(LdlResource, env);
    }
    true
}

// ---------------------------------------------------------------------------
// Shared COO validation and CSC construction
// ---------------------------------------------------------------------------

/// Validate COO triplet arrays and build a CSC matrix from them.
///
/// Returns the CSC matrix on success, or a descriptive NifResult error.
fn validate_and_build_csc(
    rows: &[usize],
    cols: &[usize],
    vals: &[f64],
    n: usize,
) -> NifResult<sprs::CsMat<f64>> {
    let nnz = rows.len();
    if cols.len() != nnz || vals.len() != nnz {
        return Err(rustler::Error::Term(Box::new(
            "triplet arrays (rows, cols, vals) must have equal length",
        )));
    }
    if n == 0 {
        return Err(rustler::Error::Term(Box::new(
            "matrix dimension n must be greater than zero",
        )));
    }

    for i in 0..nnz {
        if rows[i] >= n || cols[i] >= n {
            return Err(rustler::Error::Term(Box::new(
                "triplet index out of bounds for matrix dimension n",
            )));
        }
    }

    let mut tri: TriMat<f64> = TriMat::new((n, n));
    tri.reserve(nnz);
    for i in 0..nnz {
        tri.add_triplet(rows[i], cols[i], vals[i]);
    }
    Ok(tri.to_csc::<usize>())
}

/// Factor a CSC matrix via LDL^T, returning the numeric factorization.
fn factor_ldlt(
    csc: sprs::CsMatView<f64>,
) -> NifResult<sprs_ldl::LdlNumeric<f64, usize>> {
    sprs_ldl::LdlNumeric::new(csc).map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "sparse LDL factorization failed: {e}"
        )))
    })
}

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

#[rustler::nif(schedule = "DirtyCpu")]
fn lu_factorize(
    matrix: Vec<Vec<f64>>,
    n: usize,
) -> NifResult<(Atom, Vec<Vec<f64>>, Vec<Vec<f64>>, Vec<usize>)> {
    let mut a: Vec<Vec<f64>> = matrix;
    let mut l = vec![vec![0.0; n]; n];
    let mut u = vec![vec![0.0; n]; n];
    let mut perm: Vec<usize> = (0..n).collect();

    for k in 0..n {
        let mut max_val = a[k][k].abs();
        let mut max_row = k;
        for i in (k + 1)..n {
            if a[i][k].abs() > max_val {
                max_val = a[i][k].abs();
                max_row = i;
            }
        }

        if max_row != k {
            a.swap(k, max_row);
            perm.swap(k, max_row);
        }

        l[k][k] = 1.0;
        for j in k..n {
            u[k][j] = a[k][j];
        }

        if u[k][k].abs() > 1e-15 {
            for i in (k + 1)..n {
                l[i][k] = a[i][k] / u[k][k];
                for j in (k + 1)..n {
                    a[i][j] -= l[i][k] * u[k][j];
                }
            }
        }
    }

    Ok((atoms::ok(), l, u, perm))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn lu_solve(
    l: Vec<Vec<f64>>,
    u: Vec<Vec<f64>>,
    perm: Vec<usize>,
    rhs: Vec<f64>,
) -> NifResult<(Atom, Vec<f64>)> {
    let n = rhs.len();

    let mut pb = vec![0.0; n];
    for i in 0..n {
        pb[i] = rhs[perm[i]];
    }

    let mut y = vec![0.0; n];
    for i in 0..n {
        y[i] = pb[i];
        for j in 0..i {
            y[i] -= l[i][j] * y[j];
        }
    }

    let mut x = vec![0.0; n];
    for i in (0..n).rev() {
        x[i] = y[i];
        for j in (i + 1)..n {
            x[i] -= u[i][j] * x[j];
        }
        if u[i][i].abs() > 1e-15 {
            x[i] /= u[i][i];
        }
    }

    Ok((atoms::ok(), x))
}

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

    new_rows.push(from);
    new_cols.push(from);
    new_reals.push(y_series_re + y_shunt_re);
    new_imags.push(y_series_im + y_shunt_im);

    new_rows.push(to);
    new_cols.push(to);
    new_reals.push(y_series_re + y_shunt_re);
    new_imags.push(y_series_im + y_shunt_im);

    new_rows.push(from);
    new_cols.push(to);
    new_reals.push(-y_series_re);
    new_imags.push(-y_series_im);

    new_rows.push(to);
    new_cols.push(from);
    new_reals.push(-y_series_re);
    new_imags.push(-y_series_im);

    Ok((atoms::ok(), new_rows, new_cols, new_reals, new_imags))
}

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

#[rustler::nif(schedule = "DirtyCpu")]
fn sparse_solve(
    rows: Vec<usize>,
    cols: Vec<usize>,
    vals: Vec<f64>,
    rhs: Vec<f64>,
    n: usize,
) -> NifResult<(Atom, Vec<f64>)> {
    if rhs.len() != n {
        return Err(rustler::Error::Term(Box::new(
            "rhs length must equal matrix dimension n",
        )));
    }

    let csc = validate_and_build_csc(&rows, &cols, &vals, n)?;
    let ldlt = factor_ldlt(csc.view())?;
    let solution = ldlt.solve(&rhs);

    Ok((atoms::ok(), solution))
}

/// Solve a sparse symmetric system for multiple right-hand sides with a single
/// LDL^T factorization.
///
/// Takes COO triplets (rows, cols, vals) defining the sparse matrix A, a list
/// of RHS vectors, and the matrix dimension n. Factors once via LDL^T, then
/// performs forward/back substitution for each RHS vector.
///
/// This is more efficient than calling `sparse_solve` repeatedly when the
/// matrix is the same but the RHS vectors differ (e.g., PTDF column computation).
///
/// Returns `{:ok, [solution_1, solution_2, ...]}` on success.
#[rustler::nif(schedule = "DirtyCpu")]
fn sparse_solve_multi_rhs(
    rows: Vec<usize>,
    cols: Vec<usize>,
    vals: Vec<f64>,
    rhs_list: Vec<Vec<f64>>,
    n: usize,
) -> NifResult<(Atom, Vec<Vec<f64>>)> {
    let csc = validate_and_build_csc(&rows, &cols, &vals, n)?;

    for (idx, rhs) in rhs_list.iter().enumerate() {
        if rhs.len() != n {
            return Err(rustler::Error::Term(Box::new(format!(
                "rhs_list[{idx}] length {} does not equal matrix dimension {n}",
                rhs.len()
            ))));
        }
    }

    let ldlt = factor_ldlt(csc.view())?;

    let solutions: Vec<Vec<f64>> = rhs_list
        .iter()
        .map(|rhs| ldlt.solve(rhs))
        .collect();

    Ok((atoms::ok(), solutions))
}

/// Factor a sparse symmetric matrix via LDL^T and return an opaque handle.
///
/// The returned `ResourceArc<LdlResource>` can be passed to `sparse_cached_solve`
/// or `sparse_cached_solve_multi` for repeated solves without re-factoring.
/// The resource is reference-counted by the BEAM VM and freed when no longer
/// referenced by any Erlang/Elixir term.
///
/// Scheduled on DirtyCpu because factorization is O(nnz * fill-in) and can
/// take hundreds of milliseconds for large matrices (70k+ dimension).
#[rustler::nif(schedule = "DirtyCpu")]
fn sparse_factor(
    rows: Vec<usize>,
    cols: Vec<usize>,
    vals: Vec<f64>,
    n: usize,
) -> NifResult<(Atom, ResourceArc<LdlResource>)> {
    let csc = validate_and_build_csc(&rows, &cols, &vals, n)?;
    let ldl = factor_ldlt(csc.view())?;
    let resource = ResourceArc::new(LdlResource { ldl, n });
    Ok((atoms::ok(), resource))
}

/// Solve Ax = b using a pre-factored LDL^T handle.
///
/// Only performs forward/back substitution (~O(nnz)), no factorization.
/// Typically completes in under 5ms even for 70k-dimension systems, so this
/// runs on a normal scheduler rather than DirtyCpu.
#[rustler::nif]
fn sparse_cached_solve(
    handle: ResourceArc<LdlResource>,
    rhs: Vec<f64>,
) -> NifResult<(Atom, Vec<f64>)> {
    if rhs.len() != handle.n {
        return Err(rustler::Error::Term(Box::new(format!(
            "rhs length {} does not equal factored matrix dimension {}",
            rhs.len(),
            handle.n
        ))));
    }

    let solution = handle.ldl.solve(&rhs);
    Ok((atoms::ok(), solution))
}

/// Solve Ax = b for multiple RHS vectors using a pre-factored LDL^T handle.
///
/// Combines the benefits of cached factorization with batch solving. Each
/// solve is independent forward/back substitution against the same factors.
#[rustler::nif]
fn sparse_cached_solve_multi(
    handle: ResourceArc<LdlResource>,
    rhs_list: Vec<Vec<f64>>,
) -> NifResult<(Atom, Vec<Vec<f64>>)> {
    for (idx, rhs) in rhs_list.iter().enumerate() {
        if rhs.len() != handle.n {
            return Err(rustler::Error::Term(Box::new(format!(
                "rhs_list[{idx}] length {} does not equal factored matrix dimension {}",
                rhs.len(),
                handle.n
            ))));
        }
    }

    let solutions: Vec<Vec<f64>> = rhs_list
        .iter()
        .map(|rhs| handle.ldl.solve(rhs))
        .collect();

    Ok((atoms::ok(), solutions))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn dense_solve_flat(
    matrix_flat: Vec<f64>,
    rhs: Vec<f64>,
    n: usize,
) -> NifResult<(Atom, Vec<f64>)> {
    if matrix_flat.len() != n * n {
        return Err(rustler::Error::Term(Box::new(
            "matrix_flat length must equal n*n",
        )));
    }
    if rhs.len() != n {
        return Err(rustler::Error::Term(Box::new(
            "rhs length must equal n",
        )));
    }
    if n == 0 {
        return Err(rustler::Error::Term(Box::new(
            "matrix dimension n must be greater than zero",
        )));
    }

    let mut a: Vec<Vec<f64>> = (0..n)
        .map(|i| matrix_flat[i * n..(i + 1) * n].to_vec())
        .collect();

    let mut perm: Vec<usize> = (0..n).collect();

    for k in 0..n {
        let mut max_val = a[k][k].abs();
        let mut max_row = k;
        for i in (k + 1)..n {
            let v = a[i][k].abs();
            if v > max_val {
                max_val = v;
                max_row = i;
            }
        }

        if max_val < 1e-15 {
            continue;
        }

        if max_row != k {
            a.swap(k, max_row);
            perm.swap(k, max_row);
        }

        let pivot = a[k][k];
        for i in (k + 1)..n {
            a[i][k] /= pivot;
            let factor = a[i][k];
            for j in (k + 1)..n {
                a[i][j] -= factor * a[k][j];
            }
        }
    }

    let mut pb = vec![0.0; n];
    for i in 0..n {
        pb[i] = rhs[perm[i]];
    }

    let mut y = vec![0.0; n];
    for i in 0..n {
        y[i] = pb[i];
        for j in 0..i {
            y[i] -= a[i][j] * y[j];
        }
    }

    let mut x = vec![0.0; n];
    for i in (0..n).rev() {
        x[i] = y[i];
        for j in (i + 1)..n {
            x[i] -= a[i][j] * x[j];
        }
        if a[i][i].abs() > 1e-15 {
            x[i] /= a[i][i];
        }
    }

    Ok((atoms::ok(), x))
}

/// Sparse LU solve for general (asymmetric) matrices.
///
/// Takes COO triplets (rows, cols, vals) defining a sparse n-by-n matrix A,
/// a right-hand-side vector b, and the matrix dimension n. Performs sparse LU
/// factorization with partial pivoting via `faer`, suitable for solving the
/// Newton-Raphson Jacobian system (asymmetric, ~5-10 nnz per row).
///
/// Returns `{:ok, solution_vector}` on success.
#[rustler::nif(schedule = "DirtyCpu")]
fn sparse_lu_solve(
    rows: Vec<usize>,
    cols: Vec<usize>,
    vals: Vec<f64>,
    rhs: Vec<f64>,
    n: usize,
) -> NifResult<(Atom, Vec<f64>)> {
    let nnz = rows.len();
    if cols.len() != nnz || vals.len() != nnz {
        return Err(rustler::Error::Term(Box::new(
            "triplet arrays (rows, cols, vals) must have equal length",
        )));
    }
    if rhs.len() != n {
        return Err(rustler::Error::Term(Box::new(
            "rhs length must equal matrix dimension n",
        )));
    }
    if n == 0 {
        return Err(rustler::Error::Term(Box::new(
            "matrix dimension n must be greater than zero",
        )));
    }

    for i in 0..nnz {
        if rows[i] >= n || cols[i] >= n {
            return Err(rustler::Error::Term(Box::new(
                "triplet index out of bounds for matrix dimension n",
            )));
        }
    }

    let triplets: Vec<Triplet<usize, usize, f64>> = (0..nnz)
        .map(|i| Triplet::new(rows[i], cols[i], vals[i]))
        .collect();

    let mat = SparseColMat::<usize, f64>::try_new_from_triplets(n, n, &triplets).map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "failed to build sparse matrix from triplets: {e:?}"
        )))
    })?;

    let symbolic = SymbolicLu::try_new(mat.symbolic()).map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "sparse LU symbolic factorization failed: {e:?}"
        )))
    })?;

    let lu = Lu::try_new_with_symbolic(symbolic, mat.as_ref()).map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "sparse LU numeric factorization failed: {e:?}"
        )))
    })?;

    let b = faer::col::Col::<f64>::from_fn(n, |i| rhs[i]);
    let x = lu.solve(&b);

    let solution: Vec<f64> = (0..n).map(|i| x[i]).collect();

    Ok((atoms::ok(), solution))
}

// ---------------------------------------------------------------------------
// Kron reduction: Y_red = Y_gg - Y_gn * Y_nn^{-1} * Y_ng
// ---------------------------------------------------------------------------

/// Kron-reduce a complex admittance matrix to retain only generator buses.
///
/// Given the full Y-bus as COO triplets with separate real (G) and imaginary (B)
/// parts, and a list of generator bus indices to keep, this function eliminates
/// all non-generator buses via Kron reduction:
///
///   Y_red = Y_gg - Y_gn * Y_nn^{-1} * Y_ng
///
/// The solve Y_nn^{-1} * Y_ng is performed column-by-column using faer sparse LU
/// on the real-valued equivalent system (interleaving real and imaginary parts into
/// a 2n_n x 2n_n real system) to avoid the need for complex number support.
///
/// Returns `{:ok, out_rows, out_cols, out_reals, out_imags}` in COO format, where
/// row/col indices are in the reduced 0..n_gen space.
#[rustler::nif(schedule = "DirtyCpu")]
fn kron_reduce(
    rows: Vec<usize>,
    cols: Vec<usize>,
    reals: Vec<f64>,
    imags: Vec<f64>,
    n: usize,
    gen_bus_indices: Vec<usize>,
) -> NifResult<(Atom, Vec<usize>, Vec<usize>, Vec<f64>, Vec<f64>)> {
    let nnz = rows.len();
    if cols.len() != nnz || reals.len() != nnz || imags.len() != nnz {
        return Err(rustler::Error::Term(Box::new(
            "kron_reduce: triplet arrays must have equal length",
        )));
    }

    let n_gen = gen_bus_indices.len();
    if n_gen == 0 {
        return Ok((atoms::ok(), vec![], vec![], vec![], vec![]));
    }
    if n_gen >= n {
        // Nothing to eliminate — return the original entries re-indexed.
        // Build a mapping from original bus index to reduced index.
        let mut bus_to_gen = vec![usize::MAX; n];
        for (gi, &bus) in gen_bus_indices.iter().enumerate() {
            if bus >= n {
                return Err(rustler::Error::Term(Box::new(
                    "kron_reduce: gen_bus_index out of bounds",
                )));
            }
            bus_to_gen[bus] = gi;
        }
        let mut out_rows = Vec::new();
        let mut out_cols = Vec::new();
        let mut out_reals = Vec::new();
        let mut out_imags = Vec::new();
        for k in 0..nnz {
            let ri = bus_to_gen[rows[k]];
            let ci = bus_to_gen[cols[k]];
            if ri != usize::MAX && ci != usize::MAX {
                out_rows.push(ri);
                out_cols.push(ci);
                out_reals.push(reals[k]);
                out_imags.push(imags[k]);
            }
        }
        return Ok((atoms::ok(), out_rows, out_cols, out_reals, out_imags));
    }

    // Build lookup: is this bus a generator bus? What is its index in reduced space?
    let mut is_gen = vec![false; n];
    let mut bus_to_gen = vec![usize::MAX; n];
    for (gi, &bus) in gen_bus_indices.iter().enumerate() {
        if bus >= n {
            return Err(rustler::Error::Term(Box::new(
                "kron_reduce: gen_bus_index out of bounds",
            )));
        }
        is_gen[bus] = true;
        bus_to_gen[bus] = gi;
    }

    // Non-generator buses, mapped to 0..n_n-1
    let n_n = n - n_gen;
    let mut bus_to_non = vec![usize::MAX; n];
    let mut non_idx = 0;
    for bus in 0..n {
        if !is_gen[bus] {
            bus_to_non[bus] = non_idx;
            non_idx += 1;
        }
    }

    // Accumulate the four sub-matrices as dense arrays.
    // Y_gg: n_gen x n_gen (complex)
    // Y_gn: n_gen x n_n (complex)
    // Y_ng: n_n x n_gen (complex)
    // Y_nn: n_n x n_n (complex) — used for LU factorization
    //
    // We store each as two flat arrays (real, imag) in row-major order.
    let mut ygg_re = vec![0.0f64; n_gen * n_gen];
    let mut ygg_im = vec![0.0f64; n_gen * n_gen];
    let mut ygn_re = vec![0.0f64; n_gen * n_n];
    let mut ygn_im = vec![0.0f64; n_gen * n_n];
    let mut yng_re = vec![0.0f64; n_n * n_gen];
    let mut yng_im = vec![0.0f64; n_n * n_gen];
    let mut ynn_re = vec![0.0f64; n_n * n_n];
    let mut ynn_im = vec![0.0f64; n_n * n_n];

    for k in 0..nnz {
        let r = rows[k];
        let c = cols[k];
        let g = reals[k];
        let b = imags[k];

        let r_is_gen = is_gen[r];
        let c_is_gen = is_gen[c];

        match (r_is_gen, c_is_gen) {
            (true, true) => {
                let ri = bus_to_gen[r];
                let ci = bus_to_gen[c];
                ygg_re[ri * n_gen + ci] += g;
                ygg_im[ri * n_gen + ci] += b;
            }
            (true, false) => {
                let ri = bus_to_gen[r];
                let ci = bus_to_non[c];
                ygn_re[ri * n_n + ci] += g;
                ygn_im[ri * n_n + ci] += b;
            }
            (false, true) => {
                let ri = bus_to_non[r];
                let ci = bus_to_gen[c];
                yng_re[ri * n_gen + ci] += g;
                yng_im[ri * n_gen + ci] += b;
            }
            (false, false) => {
                let ri = bus_to_non[r];
                let ci = bus_to_non[c];
                ynn_re[ri * n_n + ci] += g;
                ynn_im[ri * n_n + ci] += b;
            }
        }
    }

    // We need to solve the complex system Y_nn * X = Y_ng for X (n_n x n_gen complex).
    // Rewrite as a real-valued 2*n_n x 2*n_n block system per column:
    //   [G  -B] [x_re]   [rhs_re]
    //   [B   G] [x_im] = [rhs_im]
    //
    // Build the 2*n_n x 2*n_n matrix in COO and factorize once, then solve for
    // each of the n_gen right-hand sides.

    let dim2 = 2 * n_n;
    let mut triplets_2n: Vec<Triplet<usize, usize, f64>> = Vec::new();

    for i in 0..n_n {
        for j in 0..n_n {
            let g = ynn_re[i * n_n + j];
            let b = ynn_im[i * n_n + j];
            // Only add non-zero entries
            if g.abs() > 1e-20 {
                // Top-left block: G(i,j)
                triplets_2n.push(Triplet::new(i, j, g));
                // Bottom-right block: G(i,j)
                triplets_2n.push(Triplet::new(n_n + i, n_n + j, g));
            }
            if b.abs() > 1e-20 {
                // Top-right block: -B(i,j)
                triplets_2n.push(Triplet::new(i, n_n + j, -b));
                // Bottom-left block: B(i,j)
                triplets_2n.push(Triplet::new(n_n + i, j, b));
            }
        }
    }

    let mat_2n =
        SparseColMat::<usize, f64>::try_new_from_triplets(dim2, dim2, &triplets_2n).map_err(
            |e| {
                rustler::Error::Term(Box::new(format!(
                    "kron_reduce: failed to build Y_nn real block matrix: {e:?}"
                )))
            },
        )?;

    let symbolic_2n = SymbolicLu::try_new(mat_2n.symbolic()).map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "kron_reduce: Y_nn symbolic LU failed: {e:?}"
        )))
    })?;

    let lu_2n = Lu::try_new_with_symbolic(symbolic_2n, mat_2n.as_ref()).map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "kron_reduce: Y_nn numeric LU failed: {e:?}"
        )))
    })?;

    // Solve Y_nn^{-1} * Y_ng column by column. Result X is n_n x n_gen (complex).
    // Store X_re and X_im as flat row-major arrays.
    let mut x_re = vec![0.0f64; n_n * n_gen];
    let mut x_im = vec![0.0f64; n_n * n_gen];

    for g in 0..n_gen {
        // Build the 2*n_n RHS from column g of Y_ng
        let rhs = faer::col::Col::<f64>::from_fn(dim2, |i| {
            if i < n_n {
                yng_re[i * n_gen + g]
            } else {
                yng_im[(i - n_n) * n_gen + g]
            }
        });

        let sol = lu_2n.solve(&rhs);

        for i in 0..n_n {
            x_re[i * n_gen + g] = sol[i];
            x_im[i * n_gen + g] = sol[n_n + i];
        }
    }

    // Compute Y_red = Y_gg - Y_gn * X
    // Y_gn is n_gen x n_n (complex), X is n_n x n_gen (complex)
    // Product is n_gen x n_gen (complex)
    // Complex multiply: (a+jb)(c+jd) = (ac-bd) + j(ad+bc)
    let mut yred_re = ygg_re;
    let mut yred_im = ygg_im;

    for i in 0..n_gen {
        for j in 0..n_gen {
            let mut acc_re = 0.0f64;
            let mut acc_im = 0.0f64;
            for k in 0..n_n {
                let a = ygn_re[i * n_n + k];
                let b = ygn_im[i * n_n + k];
                let c = x_re[k * n_gen + j];
                let d = x_im[k * n_gen + j];
                acc_re += a * c - b * d;
                acc_im += a * d + b * c;
            }
            yred_re[i * n_gen + j] -= acc_re;
            yred_im[i * n_gen + j] -= acc_im;
        }
    }

    // Convert to COO output, filtering out near-zero entries
    let mut out_rows = Vec::new();
    let mut out_cols = Vec::new();
    let mut out_reals = Vec::new();
    let mut out_imags = Vec::new();

    for i in 0..n_gen {
        for j in 0..n_gen {
            let g = yred_re[i * n_gen + j];
            let b = yred_im[i * n_gen + j];
            if g.abs() > 1e-15 || b.abs() > 1e-15 {
                out_rows.push(i);
                out_cols.push(j);
                out_reals.push(g);
                out_imags.push(b);
            }
        }
    }

    Ok((atoms::ok(), out_rows, out_cols, out_reals, out_imags))
}

// ---------------------------------------------------------------------------
// CSR representation for the reduced admittance matrix (internal use)
// ---------------------------------------------------------------------------

/// Compressed Sparse Row storage for the reduced Y matrix.
/// Stores G (conductance) and B (susceptance) values separately.
struct CsrComplex {
    /// Row pointer array. Row i has entries in indices[indptr[i]..indptr[i+1]].
    indptr: Vec<usize>,
    /// Column indices for each non-zero entry.
    col_indices: Vec<usize>,
    /// Conductance (real part) values corresponding to col_indices.
    g_vals: Vec<f64>,
    /// Susceptance (imaginary part) values corresponding to col_indices.
    b_vals: Vec<f64>,
}

impl CsrComplex {
    /// Build CSR from COO triplets. Duplicate entries for the same (i,j) are summed.
    fn from_coo(
        n: usize,
        rows: &[usize],
        cols: &[usize],
        g: &[f64],
        b: &[f64],
    ) -> Self {
        // Count entries per row
        let mut row_count = vec![0usize; n];
        for &r in rows {
            row_count[r] += 1;
        }

        // Build indptr
        let mut indptr = vec![0usize; n + 1];
        for i in 0..n {
            indptr[i + 1] = indptr[i] + row_count[i];
        }
        let total_nnz = indptr[n];

        // Fill col_indices and values using insertion cursors
        let mut col_indices = vec![0usize; total_nnz];
        let mut g_vals = vec![0.0f64; total_nnz];
        let mut b_vals = vec![0.0f64; total_nnz];
        let mut cursor = indptr[..n].to_vec(); // current write position per row

        for k in 0..rows.len() {
            let r = rows[k];
            let pos = cursor[r];
            col_indices[pos] = cols[k];
            g_vals[pos] = g[k];
            b_vals[pos] = b[k];
            cursor[r] += 1;
        }

        // Now merge duplicates within each row: sort by column, sum duplicates.
        // This is important when COO input has multiple entries for the same (i,j).
        let mut csr = CsrComplex {
            indptr,
            col_indices,
            g_vals,
            b_vals,
        };
        csr.sort_and_merge(n);
        csr
    }

    /// Sort each row by column index and merge duplicate column entries.
    fn sort_and_merge(&mut self, n: usize) {
        for i in 0..n {
            let start = self.indptr[i];
            let end = self.indptr[i + 1];
            if start == end {
                continue;
            }

            // Gather entries for this row
            let len = end - start;
            let mut entries: Vec<(usize, f64, f64)> = Vec::with_capacity(len);
            for k in start..end {
                entries.push((self.col_indices[k], self.g_vals[k], self.b_vals[k]));
            }

            // Sort by column
            entries.sort_unstable_by_key(|e| e.0);

            // Merge duplicates
            let mut merged: Vec<(usize, f64, f64)> = Vec::with_capacity(len);
            for entry in entries {
                if let Some(last) = merged.last_mut() {
                    if last.0 == entry.0 {
                        last.1 += entry.1;
                        last.2 += entry.2;
                        continue;
                    }
                }
                merged.push(entry);
            }

            // Write back (merged may be shorter than original if duplicates existed)
            for (k, &(col, g, b)) in merged.iter().enumerate() {
                self.col_indices[start + k] = col;
                self.g_vals[start + k] = g;
                self.b_vals[start + k] = b;
            }
            // Zero out any trailing slots from duplicate merging (they won't be accessed
            // since we'll adjust indptr below if we ever need to, but for safety we just
            // leave them — the indptr rebuild below handles it).
            // Actually, we need to compact. Rebuild indptr for this row.
            // We'll do a full rebuild after all rows are processed.
            // For now, store the new end.
            // Use a sentinel: store new count in the g_vals of the first unused slot.
            // Actually, simpler: just rebuild from scratch.
            let new_end = start + merged.len();
            // Fill unused trailing entries with a sentinel column
            for k in new_end..end {
                self.col_indices[k] = usize::MAX;
            }
        }

        // Compact: remove entries where col_indices == usize::MAX
        let mut new_col_indices = Vec::with_capacity(self.col_indices.len());
        let mut new_g_vals = Vec::with_capacity(self.g_vals.len());
        let mut new_b_vals = Vec::with_capacity(self.b_vals.len());
        let mut new_indptr = vec![0usize; n + 1];

        for i in 0..n {
            let start = self.indptr[i];
            let end = self.indptr[i + 1];
            let row_start = new_col_indices.len();
            for k in start..end {
                if self.col_indices[k] != usize::MAX {
                    new_col_indices.push(self.col_indices[k]);
                    new_g_vals.push(self.g_vals[k]);
                    new_b_vals.push(self.b_vals[k]);
                }
            }
            new_indptr[i] = row_start;
        }
        new_indptr[n] = new_col_indices.len();

        self.indptr = new_indptr;
        self.col_indices = new_col_indices;
        self.g_vals = new_g_vals;
        self.b_vals = new_b_vals;
    }
}

// ---------------------------------------------------------------------------
// Transient stability simulation — classical machine model
// ---------------------------------------------------------------------------

/// Compute electrical power output for each generator from the reduced Y matrix.
///
/// P_elec_i = E_i^2 * G_ii + sum_{j!=i} E_i * E_j * (B_ij * sin(d_i - d_j) + G_ij * cos(d_i - d_j))
///
/// Uses CSR storage for efficient iteration over non-zero entries. The E_i * E_j
/// products are pre-computed since E' is constant in the classical model.
fn compute_p_elec(
    n_gen: usize,
    delta: &[f64],
    e_prime: &[f64],
    ee_product: &[Vec<f64>],
    csr: &CsrComplex,
) -> Vec<f64> {
    let mut p_elec = vec![0.0f64; n_gen];

    for i in 0..n_gen {
        let start = csr.indptr[i];
        let end = csr.indptr[i + 1];
        let mut sum = 0.0f64;

        for k in start..end {
            let j = csr.col_indices[k];
            let g_ij = csr.g_vals[k];
            let b_ij = csr.b_vals[k];

            if i == j {
                // Diagonal: P += E_i^2 * G_ii
                sum += e_prime[i] * e_prime[i] * g_ij;
            } else {
                // Off-diagonal: P += E_i*E_j * (B_ij*sin(d_i-d_j) + G_ij*cos(d_i-d_j))
                let d_diff = delta[i] - delta[j];
                let (sin_d, cos_d) = d_diff.sin_cos();
                sum += ee_product[i][j] * (b_ij * sin_d + g_ij * cos_d);
            }
        }

        p_elec[i] = sum;
    }

    p_elec
}

/// Compute the time derivatives of the swing equation.
///
/// d(delta_i)/dt = omega_base * (omega_i - 1.0)
/// d(omega_i)/dt = (p_mech_i - p_elec_i - d_i * (omega_i - 1.0)) / (2 * h_i)
///
/// Returns (ddelta, domega) vectors.
fn swing_derivatives(
    n_gen: usize,
    _delta: &[f64],
    omega: &[f64],
    p_mech: &[f64],
    p_elec: &[f64],
    h: &[f64],
    d: &[f64],
    omega_base: f64,
) -> (Vec<f64>, Vec<f64>) {
    let mut ddelta = vec![0.0f64; n_gen];
    let mut domega = vec![0.0f64; n_gen];

    for i in 0..n_gen {
        let omega_dev = omega[i] - 1.0;
        ddelta[i] = omega_base * omega_dev;

        // Guard against zero inertia: treat as infinite inertia (domega = 0)
        if h[i].abs() < 1e-12 {
            domega[i] = 0.0;
        } else {
            domega[i] = (p_mech[i] - p_elec[i] - d[i] * omega_dev) / (2.0 * h[i]);
        }
    }

    (ddelta, domega)
}

/// Classical machine model transient stability simulation.
///
/// Integrates the swing equations for `n_gen` generators connected through a
/// Kron-reduced admittance matrix Y_red, using implicit trapezoidal integration
/// (predict with forward Euler, correct with trapezoidal rule).
///
/// The simulation supports discrete events (e.g., generator tripping via P_mech
/// changes) at specified times. Output is decimated by `output_every` to control
/// the size of the returned trajectory.
///
/// Returns `{:ok, trajectory}` where each trajectory row is
/// `[time, delta_0..n-1, omega_0..n-1]`.
///
/// Scheduled on DirtyCpu since for large systems (10k+ generators, 10k+ steps)
/// this can run for seconds.
#[rustler::nif(schedule = "DirtyCpu")]
fn transient_classical_simulate(
    n_gen: usize,
    delta_init: Vec<f64>,
    omega_init: Vec<f64>,
    p_mech: Vec<f64>,
    e_prime: Vec<f64>,
    h: Vec<f64>,
    d: Vec<f64>,
    y_red_rows: Vec<usize>,
    y_red_cols: Vec<usize>,
    y_red_g: Vec<f64>,
    y_red_b: Vec<f64>,
    dt: f64,
    n_steps: usize,
    event_times: Vec<f64>,
    event_gen_indices: Vec<usize>,
    event_p_mech_new: Vec<f64>,
    output_every: usize,
) -> NifResult<(Atom, Vec<Vec<f64>>)> {
    // --- Input validation ---
    if n_gen == 0 {
        return Ok((atoms::ok(), vec![]));
    }
    if delta_init.len() != n_gen {
        return Err(rustler::Error::Term(Box::new(
            "transient_sim: delta_init length must equal n_gen",
        )));
    }
    if omega_init.len() != n_gen {
        return Err(rustler::Error::Term(Box::new(
            "transient_sim: omega_init length must equal n_gen",
        )));
    }
    if p_mech.len() != n_gen {
        return Err(rustler::Error::Term(Box::new(
            "transient_sim: p_mech length must equal n_gen",
        )));
    }
    if e_prime.len() != n_gen {
        return Err(rustler::Error::Term(Box::new(
            "transient_sim: e_prime length must equal n_gen",
        )));
    }
    if h.len() != n_gen {
        return Err(rustler::Error::Term(Box::new(
            "transient_sim: h length must equal n_gen",
        )));
    }
    if d.len() != n_gen {
        return Err(rustler::Error::Term(Box::new(
            "transient_sim: d length must equal n_gen",
        )));
    }
    let n_events = event_times.len();
    if event_gen_indices.len() != n_events || event_p_mech_new.len() != n_events {
        return Err(rustler::Error::Term(Box::new(
            "transient_sim: event arrays must have equal length",
        )));
    }
    for &gi in &event_gen_indices {
        if gi >= n_gen {
            return Err(rustler::Error::Term(Box::new(
                "transient_sim: event_gen_index out of bounds",
            )));
        }
    }
    let y_nnz = y_red_rows.len();
    if y_red_cols.len() != y_nnz || y_red_g.len() != y_nnz || y_red_b.len() != y_nnz {
        return Err(rustler::Error::Term(Box::new(
            "transient_sim: Y_red triplet arrays must have equal length",
        )));
    }
    for k in 0..y_nnz {
        if y_red_rows[k] >= n_gen || y_red_cols[k] >= n_gen {
            return Err(rustler::Error::Term(Box::new(
                "transient_sim: Y_red index out of bounds for n_gen",
            )));
        }
    }
    if dt <= 0.0 {
        return Err(rustler::Error::Term(Box::new(
            "transient_sim: dt must be positive",
        )));
    }
    let output_every = if output_every == 0 { 1 } else { output_every };

    // --- Build CSR for Y_red ---
    let csr = CsrComplex::from_coo(n_gen, &y_red_rows, &y_red_cols, &y_red_g, &y_red_b);

    // --- Pre-compute E_i * E_j products (constant in classical model) ---
    // Only need products for pairs (i,j) that have non-zero Y_red entries,
    // but for simplicity and cache-friendliness with moderate n_gen, store
    // as a dense n_gen x n_gen matrix. For very large n_gen (>10k), this
    // uses ~800MB which is too much. In that case, compute on the fly.
    // Threshold: use dense if n_gen <= 8192 (512MB), else compute inline.
    let use_dense_ee = n_gen <= 8192;
    let ee_product: Vec<Vec<f64>> = if use_dense_ee {
        (0..n_gen)
            .map(|i| {
                (0..n_gen)
                    .map(|j| e_prime[i] * e_prime[j])
                    .collect()
            })
            .collect()
    } else {
        // Empty — we'll compute inline in the P_elec function
        vec![]
    };

    // --- Sort events by time for efficient processing ---
    let mut events: Vec<(f64, usize, f64)> = (0..n_events)
        .map(|i| (event_times[i], event_gen_indices[i], event_p_mech_new[i]))
        .collect();
    events.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let mut next_event_idx = 0usize;

    // --- Initialize state ---
    let mut delta = delta_init;
    let mut omega = omega_init;
    let mut pm = p_mech;
    let omega_base = 2.0 * PI * 60.0;

    // --- Allocate trajectory output ---
    let n_output = n_steps / output_every + 1; // +1 for initial state
    let row_len = 1 + 2 * n_gen; // time + deltas + omegas
    let mut trajectory: Vec<Vec<f64>> = Vec::with_capacity(n_output);

    // Record initial state
    {
        let mut row = Vec::with_capacity(row_len);
        row.push(0.0);
        row.extend_from_slice(&delta);
        row.extend_from_slice(&omega);
        trajectory.push(row);
    }

    // --- Temporary buffers for trapezoidal integration ---
    let mut delta_pred = vec![0.0f64; n_gen];
    let mut omega_pred = vec![0.0f64; n_gen];

    // --- Main time-stepping loop ---
    for step in 1..=n_steps {
        let t = step as f64 * dt;

        // Process any events whose time has been crossed
        while next_event_idx < events.len() && events[next_event_idx].0 <= t {
            let (_et, gen_idx, new_pm) = events[next_event_idx];
            pm[gen_idx] = new_pm;
            next_event_idx += 1;
        }

        // Compute P_elec at current state
        let p_elec_0 = if use_dense_ee {
            compute_p_elec(n_gen, &delta, &e_prime, &ee_product, &csr)
        } else {
            compute_p_elec_sparse(n_gen, &delta, &e_prime, &csr)
        };

        // Compute derivatives at current state (f_0)
        let (ddelta_0, domega_0) =
            swing_derivatives(n_gen, &delta, &omega, &pm, &p_elec_0, &h, &d, omega_base);

        // Forward Euler prediction
        for i in 0..n_gen {
            delta_pred[i] = delta[i] + dt * ddelta_0[i];
            omega_pred[i] = omega[i] + dt * domega_0[i];
        }

        // Trapezoidal corrector: 2 iterations for implicit convergence
        for _iter in 0..2 {
            let p_elec_pred = if use_dense_ee {
                compute_p_elec(n_gen, &delta_pred, &e_prime, &ee_product, &csr)
            } else {
                compute_p_elec_sparse(n_gen, &delta_pred, &e_prime, &csr)
            };

            let (ddelta_1, domega_1) = swing_derivatives(
                n_gen,
                &delta_pred,
                &omega_pred,
                &pm,
                &p_elec_pred,
                &h,
                &d,
                omega_base,
            );

            // Trapezoidal rule: x_{n+1} = x_n + dt/2 * (f_0 + f_1)
            for i in 0..n_gen {
                delta_pred[i] = delta[i] + 0.5 * dt * (ddelta_0[i] + ddelta_1[i]);
                omega_pred[i] = omega[i] + 0.5 * dt * (domega_0[i] + domega_1[i]);
            }
        }

        // Accept the corrected values as the new state
        for i in 0..n_gen {
            delta[i] = delta_pred[i];
            omega[i] = omega_pred[i];
        }

        // Record output at decimated intervals
        if step % output_every == 0 {
            let mut row = Vec::with_capacity(row_len);
            row.push(t);
            row.extend_from_slice(&delta);
            row.extend_from_slice(&omega);
            trajectory.push(row);
        }
    }

    // Record final state if not already captured by decimation
    let t_final = n_steps as f64 * dt;
    if n_steps % output_every != 0 {
        let mut row = Vec::with_capacity(row_len);
        row.push(t_final);
        row.extend_from_slice(&delta);
        row.extend_from_slice(&omega);
        trajectory.push(row);
    }

    Ok((atoms::ok(), trajectory))
}

/// Compute P_elec without pre-computed E_i*E_j products (for large n_gen).
/// Computes the products inline from e_prime values.
fn compute_p_elec_sparse(
    n_gen: usize,
    delta: &[f64],
    e_prime: &[f64],
    csr: &CsrComplex,
) -> Vec<f64> {
    let mut p_elec = vec![0.0f64; n_gen];

    for i in 0..n_gen {
        let start = csr.indptr[i];
        let end = csr.indptr[i + 1];
        let mut sum = 0.0f64;
        let e_i = e_prime[i];

        for k in start..end {
            let j = csr.col_indices[k];
            let g_ij = csr.g_vals[k];
            let b_ij = csr.b_vals[k];

            if i == j {
                sum += e_i * e_i * g_ij;
            } else {
                let d_diff = delta[i] - delta[j];
                let (sin_d, cos_d) = d_diff.sin_cos();
                sum += e_i * e_prime[j] * (b_ij * sin_d + g_ij * cos_d);
            }
        }

        p_elec[i] = sum;
    }

    p_elec
}

rustler::init!("Elixir.PowerModel.Solver.Sparse", load = load);
