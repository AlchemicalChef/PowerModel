use rustler::{Atom, NifResult};
use sprs::TriMat;

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
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

    let mut tri: TriMat<f64> = TriMat::new((n, n));
    tri.reserve(nnz);
    for i in 0..nnz {
        tri.add_triplet(rows[i], cols[i], vals[i]);
    }
    let csc = tri.to_csc::<usize>();

    let ldlt = sprs_ldl::LdlNumeric::new(csc.view()).map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "sparse LDL factorization failed: {e}"
        )))
    })?;

    let solution = ldlt.solve(&rhs);

    Ok((atoms::ok(), solution))
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

rustler::init!("Elixir.PowerModel.Solver.Sparse");
