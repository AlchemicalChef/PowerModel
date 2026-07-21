use rustler::{Atom, Encoder, Env, NifResult, Term};
use sprs::TriMat;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        singular_matrix
    }
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

/// Solve a sparse linear system Ax = b using sparse LDL^T factorization.
///
/// Accepts COO triplets defining a symmetric positive definite matrix A and a
/// right-hand side vector b. Builds a CSC matrix from the triplets, performs
/// sparse LDL^T factorization via `sprs-ldl`, and returns the solution vector x.
///
/// This is designed for the DC power flow B' matrix which is symmetric positive
/// definite, making LDL^T the natural factorization choice. For 45k+ bus grids
/// this is orders of magnitude faster and more memory-efficient than dense LU.
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
/// Returns a `{:error, reason}` tuple if:
/// - Input dimensions are inconsistent (rows/cols/vals length mismatch)
/// - RHS vector length does not match matrix dimension
/// - Matrix dimension is zero
/// - Any triplet index is out of bounds
/// - LDL^T factorization fails (matrix may not be symmetric positive definite)
#[rustler::nif(schedule = "DirtyCpu")]
fn sparse_solve(
    rows: Vec<usize>,
    cols: Vec<usize>,
    vals: Vec<f64>,
    rhs: Vec<f64>,
    n: usize,
) -> NifResult<(Atom, Vec<f64>)> {
    // --- Input validation ---
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

    // Validate index bounds before building the matrix to avoid panics
    // inside sprs::TriMat::add_triplet.
    for i in 0..nnz {
        if rows[i] >= n || cols[i] >= n {
            return Err(rustler::Error::Term(Box::new(
                "triplet index out of bounds for matrix dimension n",
            )));
        }
    }

    // --- Build sparse CSC matrix from COO triplets ---
    // sprs-ldl operates on CSC matrices. TriMat handles duplicate entries
    // by summing them, which is correct for Y-bus assembly where multiple
    // branches contribute to the same matrix position.
    let mut tri: TriMat<f64> = TriMat::new((n, n));
    tri.reserve(nnz);
    for i in 0..nnz {
        tri.add_triplet(rows[i], cols[i], vals[i]);
    }
    let csc = tri.to_csc::<usize>();

    // --- Sparse LDL^T factorization and solve ---
    // LdlNumeric computes: L * D * L^T = P^T * A * P
    // where P is a fill-reducing permutation.
    // The matrix must be symmetric positive definite.
    let ldlt = sprs_ldl::LdlNumeric::new(csc.view()).map_err(|e| {
        rustler::Error::Term(Box::new(format!("sparse LDL factorization failed: {e}")))
    })?;

    let solution = ldlt.solve(&rhs);

    Ok((atoms::ok(), solution))
}

rustler::init!("Elixir.PowerModel.Solver.Sparse");
