defmodule PowerModel.Solver.Harmonics.Solver do
  @moduledoc """
  Harmonic power flow solver.

  For each harmonic order h, builds the bus admittance matrix Y_h at frequency
  h*f_0 and solves the linear system:

      V_h = Y_h^{-1} * I_h

  where I_h is the vector of harmonic current injections at order h.

  ## Methodology

  The fundamental frequency (h=1) solution comes from the regular Newton-Raphson
  or DC power flow solver. Higher harmonics (h = 2, 3, ..., max_h) are solved
  independently as linear network problems because **superposition applies** at
  each harmonic frequency: the network is linear (constant impedance) at each
  frequency, and only the harmonic sources are nonlinear.

  The complex solve Y_h * V_h = I_h is converted to a real 2n x 2n system:

      [G  -B] [V_re]   [I_re]
      [B   G] [V_im] = [I_im]

  This avoids needing complex number support in the Rust NIF sparse solver.

  ## IEEE 519 Compliance

  The solver includes IEEE 519-2022 compliance checking, which defines voltage
  distortion limits based on system voltage level:

  | System Voltage     | Individual Harmonic | THD_v |
  |--------------------|--------------------:|------:|
  | V <= 1.0 kV        |               5.0% |  8.0% |
  | 1 kV < V <= 69 kV  |               3.0% |  5.0% |
  | 69 kV < V <= 161 kV|               1.5% |  2.5% |
  | V > 161 kV          |               1.0% |  1.5% |

  ## References

  - IEEE Std 519-2022, "Harmonic Control in Electric Power Systems".
  - Arrillaga & Watson, "Power System Harmonics", 2nd ed., Wiley, 2003, Ch. 7.
  - Xu, W., "Component Modeling Issues for Power Quality Assessment",
    IEEE Power Engineering Review, 2001.
  """

  alias PowerModel.Solver.Harmonics.Impedance
  alias PowerModel.Solver.Sparse

  @default_max_harmonic 25
  @default_base_mva 100.0

  @doc """
  Solve for harmonic voltages at all buses.

  Builds the Y-bus at each harmonic frequency h = 2..max_h, assembles the
  harmonic current injection vector from the provided sources, and solves
  the linear system to find voltage harmonics.

  ## Parameters

    * `snapshot` — grid snapshot map with `:buses`, `:lines`, `:transformers`,
      `:generators` keys
    * `fundamental_solution` — a map with `:vm_pu` (list of voltage magnitudes)
      and `:va_rad` (list of voltage angles) from the fundamental power flow.
      Also needs `:bus_ids` to map indices back to bus IDs.
    * `harmonic_sources` — map of `%{bus_id => [device_spec, ...]}` where each
      device_spec is a map suitable for `Sources.aggregate_bus_injections/2`
    * `opts` — keyword options

  ## Options

    * `:max_harmonic` — highest harmonic order to solve (default 25)
    * `:base_mva` — system base MVA (default 100.0)
    * `:harmonics` — explicit list of harmonic orders to solve (overrides max_harmonic)

  ## Returns

    `{:ok, %{h => %{bus_id => {v_mag, v_angle}}}}` for each harmonic h,
    or `{:error, reason}`.
  """
  def solve(snapshot, fundamental_solution, harmonic_sources, opts \\ []) do
    max_h = Keyword.get(opts, :max_harmonic, @default_max_harmonic)
    base_mva = Keyword.get(opts, :base_mva, @default_base_mva)

    harmonics = Keyword.get(opts, :harmonics, Enum.to_list(2..max_h))

    buses = snapshot.buses
    lines = snapshot.lines
    transformers = snapshot.transformers
    generators = snapshot.generators

    n = length(buses)
    if n == 0, do: throw({:error, :empty_grid})

    bus_ids = Enum.map(buses, & &1.id)
    bus_index = buses |> Enum.with_index() |> Map.new(fn {b, i} -> {b.id, i} end)

    # Solve each harmonic independently
    results =
      Enum.reduce(harmonics, %{}, fn h, acc ->
        case solve_single_harmonic(buses, lines, transformers, generators,
                                    bus_ids, bus_index, n, h, harmonic_sources, base_mva) do
          {:ok, voltage_map} ->
            Map.put(acc, h, voltage_map)

          {:error, _reason} ->
            # Skip harmonics that fail to solve (singular Y matrix, etc.)
            acc
        end
      end)

    # Add fundamental frequency voltages for completeness
    fundamental_map = build_fundamental_map(fundamental_solution)
    results = Map.put(results, 1, fundamental_map)

    {:ok, results}
  end

  @doc """
  Compute Total Harmonic Distortion (THD) of voltage at each bus.

  THD_v is defined as:

      THD_v = sqrt(sum(V_h^2 for h = 2..N)) / V_1 * 100%

  where V_h is the RMS voltage magnitude at harmonic h and V_1 is the
  fundamental frequency voltage magnitude.

  ## Parameters

    * `harmonic_voltages` — the result map from `solve/4`, i.e.
      `%{h => %{bus_id => {v_mag, v_angle}}}`

  ## Returns

    `%{bus_id => thd_pct}` — THD in percent for each bus.
  """
  def compute_thd(harmonic_voltages) do
    fundamental = Map.get(harmonic_voltages, 1, %{})
    higher_harmonics = Map.drop(harmonic_voltages, [1])

    # Get all bus IDs from the fundamental solution
    bus_ids = Map.keys(fundamental)

    Map.new(bus_ids, fn bus_id ->
      {v1_mag, _v1_angle} = Map.get(fundamental, bus_id, {1.0, 0.0})

      # Sum of squared harmonic voltage magnitudes
      v_h_sq_sum =
        higher_harmonics
        |> Enum.reduce(0.0, fn {_h, bus_voltages}, sum ->
          case Map.get(bus_voltages, bus_id) do
            {v_h_mag, _angle} -> sum + v_h_mag * v_h_mag
            nil -> sum
          end
        end)

      # THD = sqrt(sum(V_h^2)) / V_1 * 100%
      thd_pct = if v1_mag > 1.0e-6 do
        :math.sqrt(v_h_sq_sum) / v1_mag * 100.0
      else
        0.0
      end

      {bus_id, thd_pct}
    end)
  end

  @doc """
  Check IEEE 519-2022 voltage distortion compliance at each bus.

  IEEE 519 defines voltage distortion limits based on the system voltage level.
  This function evaluates each bus against the applicable limits.

  ## Parameters

    * `harmonic_voltages` — result map from `solve/4`
    * `buses` — list of bus maps (must have `:id` and `:base_kv`)

  ## Returns

    A list of compliance result maps:
    ```
    [%{
      bus_id: integer,
      base_kv: float,
      thd_pct: float,
      max_individual_pct: float,
      max_individual_harmonic: integer,
      thd_limit_pct: float,
      individual_limit_pct: float,
      compliant: boolean,
      violations: [%{type: :thd | :individual, harmonic: integer, value: float, limit: float}]
    }]
    ```
  """
  def check_ieee_519(harmonic_voltages, buses) do
    fundamental = Map.get(harmonic_voltages, 1, %{})
    higher_harmonics = Map.drop(harmonic_voltages, [1])

    Enum.map(buses, fn bus ->
      bus_id = bus.id
      base_kv = bus.base_kv || 0.0

      {v1_mag, _} = Map.get(fundamental, bus_id, {1.0, 0.0})

      # IEEE 519-2022 voltage distortion limits (Table 1)
      {thd_limit, individual_limit} = ieee_519_voltage_limits(base_kv)

      # Compute individual harmonic distortion for each h
      {individual_results, v_h_sq_sum} =
        Enum.reduce(higher_harmonics, {[], 0.0}, fn {h, bus_voltages}, {results, sq_sum} ->
          case Map.get(bus_voltages, bus_id) do
            {v_h_mag, _angle} ->
              pct = if v1_mag > 1.0e-6, do: v_h_mag / v1_mag * 100.0, else: 0.0
              {[{h, pct} | results], sq_sum + v_h_mag * v_h_mag}

            nil ->
              {results, sq_sum}
          end
        end)

      # THD
      thd_pct = if v1_mag > 1.0e-6 do
        :math.sqrt(v_h_sq_sum) / v1_mag * 100.0
      else
        0.0
      end

      # Find worst individual harmonic
      {max_ind_h, max_ind_pct} =
        case Enum.max_by(individual_results, fn {_h, pct} -> pct end, fn -> {0, 0.0} end) do
          {h, pct} -> {h, pct}
        end

      # Check for violations
      violations = []
      violations = if thd_pct > thd_limit do
        [%{type: :thd, harmonic: 0, value: thd_pct, limit: thd_limit} | violations]
      else
        violations
      end

      violations =
        Enum.reduce(individual_results, violations, fn {h, pct}, acc ->
          if pct > individual_limit do
            [%{type: :individual, harmonic: h, value: pct, limit: individual_limit} | acc]
          else
            acc
          end
        end)

      compliant = Enum.empty?(violations)

      %{
        bus_id: bus_id,
        base_kv: base_kv,
        thd_pct: thd_pct,
        max_individual_pct: max_ind_pct,
        max_individual_harmonic: max_ind_h,
        thd_limit_pct: thd_limit,
        individual_limit_pct: individual_limit,
        compliant: compliant,
        violations: violations
      }
    end)
  end

  @doc """
  Compute driving-point impedance frequency scan at a specified bus.

  Injects a 1.0 pu current at the target bus at each harmonic frequency
  and measures the resulting voltage. The ratio V/I gives the driving-point
  impedance Z(h). Peaks in |Z(h)| indicate resonance conditions where
  harmonic voltages can be amplified.

  This is the standard tool for identifying parallel resonance frequencies
  prior to harmonic filter design.

  ## Parameters

    * `snapshot` — grid snapshot map
    * `bus_id` — the bus at which to compute the impedance scan
    * `opts` — keyword options

  ## Options

    * `:freq_range` — range of harmonic orders (default 1..50)
    * `:freq_step` — step size for the scan (default 1); fractional steps
      allow interharmonic scanning
    * `:base_mva` — system base MVA (default 100.0)

  ## Returns

    A list of `{harmonic_order, z_magnitude, z_angle_rad}` tuples.
    Peaks in z_magnitude correspond to resonance frequencies.
  """
  def impedance_scan(snapshot, bus_id, opts \\ []) do
    freq_range = Keyword.get(opts, :freq_range, 1..50)
    freq_step = Keyword.get(opts, :freq_step, 1)
    base_mva = Keyword.get(opts, :base_mva, @default_base_mva)

    buses = snapshot.buses
    lines = snapshot.lines
    transformers = snapshot.transformers
    generators = snapshot.generators

    n = length(buses)
    if n == 0, do: throw({:error, :empty_grid})

    bus_index = buses |> Enum.with_index() |> Map.new(fn {b, i} -> {b.id, i} end)
    target_idx = Map.fetch!(bus_index, bus_id)

    # Generate frequency points
    freq_points = if freq_step == 1 do
      Enum.to_list(freq_range)
    else
      Stream.iterate(freq_range.first, &(&1 + freq_step))
      |> Enum.take_while(&(&1 <= freq_range.last))
    end

    Enum.map(freq_points, fn h ->
      # Build Y-bus at this harmonic frequency
      ybus = Impedance.build_ybus_at_harmonic(buses, lines, transformers, generators, h, base_mva)

      # Inject 1.0 + j0.0 pu current at target bus, solve for voltage
      # I = [0, 0, ..., 1+j0, ..., 0]  (1.0 at target_idx)
      i_real = List.duplicate(0.0, n) |> List.replace_at(target_idx, 1.0)
      i_imag = List.duplicate(0.0, n)

      case solve_complex_system(ybus, n, i_real, i_imag) do
        {:ok, v_real, v_imag} ->
          # Driving-point impedance = V at target bus / I at target bus
          # Since I = 1.0 + j0.0, Z = V_target
          vr = Enum.at(v_real, target_idx)
          vi = Enum.at(v_imag, target_idx)
          z_mag = :math.sqrt(vr * vr + vi * vi)
          z_angle = :math.atan2(vi, vr)
          {h, z_mag, z_angle}

        {:error, _reason} ->
          # Singular matrix at this frequency (exact resonance)
          {h, :infinity, 0.0}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private: solve a single harmonic
  # ---------------------------------------------------------------------------

  defp solve_single_harmonic(buses, lines, transformers, generators,
                              bus_ids, bus_index, n, h, harmonic_sources, base_mva) do
    # Build Y-bus at harmonic h
    ybus = Impedance.build_ybus_at_harmonic(buses, lines, transformers, generators, h, base_mva)

    # Build harmonic current injection vector
    {i_real, i_imag} = build_injection_vector(bus_ids, bus_index, n, h, harmonic_sources)

    # Check if there are any injections at this harmonic
    has_injection = Enum.any?(i_real, &(abs(&1) > 1.0e-15)) or
                    Enum.any?(i_imag, &(abs(&1) > 1.0e-15))

    if not has_injection do
      # No sources at this harmonic — all voltages are zero
      voltage_map = Map.new(bus_ids, fn id -> {id, {0.0, 0.0}} end)
      {:ok, voltage_map}
    else
      case solve_complex_system(ybus, n, i_real, i_imag) do
        {:ok, v_real, v_imag} ->
          # Convert to bus_id => {magnitude, angle} map
          voltage_map =
            bus_ids
            |> Enum.with_index()
            |> Map.new(fn {id, idx} ->
              vr = Enum.at(v_real, idx)
              vi = Enum.at(v_imag, idx)
              mag = :math.sqrt(vr * vr + vi * vi)
              angle = :math.atan2(vi, vr)
              {id, {mag, angle}}
            end)

          {:ok, voltage_map}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private: build injection vector from harmonic sources
  # ---------------------------------------------------------------------------

  defp build_injection_vector(_bus_ids, bus_index, n, h, harmonic_sources) do
    # Start with zero injection at all buses
    i_real = :array.new(n, default: 0.0)
    i_imag = :array.new(n, default: 0.0)

    {i_real, i_imag} =
      Enum.reduce(harmonic_sources, {i_real, i_imag}, fn {bus_id, devices}, {ir, ii} ->
        case Map.get(bus_index, bus_id) do
          nil -> {ir, ii}
          idx ->
            {inj_re, inj_im} =
              PowerModel.Solver.Harmonics.Sources.aggregate_bus_injections(devices, h)

            ir = :array.set(idx, :array.get(idx, ir) + inj_re, ir)
            ii = :array.set(idx, :array.get(idx, ii) + inj_im, ii)
            {ir, ii}
        end
      end)

    {Enum.map(0..(n - 1), &:array.get(&1, i_real)),
     Enum.map(0..(n - 1), &:array.get(&1, i_imag))}
  end

  # ---------------------------------------------------------------------------
  # Private: solve complex linear system Y * V = I using 2n x 2n real form
  # ---------------------------------------------------------------------------

  # Converts the complex system:
  #   (G + jB) * (V_re + jV_im) = (I_re + jI_im)
  #
  # Into the real 2n x 2n system:
  #   [G  -B] [V_re]   [I_re]
  #   [B   G] [V_im] = [I_im]
  #
  # This is the standard "interleaved real" form that avoids complex arithmetic
  # in the solver. The resulting matrix is real and asymmetric, suitable for
  # the faer sparse LU solver.
  defp solve_complex_system(ybus, n, i_real, i_imag) do
    dim = 2 * n

    # Extract G and B from Y-bus triplets: Y = G + jB
    # Build the 2n x 2n real system triplets
    {rows, cols, vals} = build_real_2n_triplets(ybus.triplets, n)

    # Build the 2n RHS vector: [I_re; I_im]
    rhs = i_real ++ i_imag

    # Try sparse LU solve first (handles asymmetric matrices)
    result = try do
      case Sparse.sparse_lu_solve(rows, cols, vals, rhs, dim) do
        {:ok, solution} -> {:ok, solution}
        {:error, reason} -> {:error, reason}
      end
    rescue
      _e ->
        # NIF not available — fall back to dense solve
        solve_dense_2n(rows, cols, vals, rhs, dim)
    end

    case result do
      {:ok, solution} ->
        # Split solution into real and imaginary parts
        {v_real, v_imag} = Enum.split(solution, n)
        {:ok, v_real, v_imag}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Build real 2n x 2n COO triplets from complex n x n triplets
  #
  # Layout:
  #   Row [0..n-1], Col [0..n-1]     -> G  (real part of Y)
  #   Row [0..n-1], Col [n..2n-1]    -> -B (negative imaginary part of Y)
  #   Row [n..2n-1], Col [0..n-1]    -> B  (imaginary part of Y)
  #   Row [n..2n-1], Col [n..2n-1]   -> G  (real part of Y)
  defp build_real_2n_triplets(complex_triplets, n) do
    {rows, cols, vals} =
      Enum.reduce(complex_triplets, {[], [], []}, fn {r, c, {g, b}}, {rs, cs, vs} ->
        # Top-left: G(r, c)
        # Top-right: -B(r, c+n)
        # Bottom-left: B(r+n, c)
        # Bottom-right: G(r+n, c+n)
        new_rs = [r, r, r + n, r + n | rs]
        new_cs = [c, c + n, c, c + n | cs]
        new_vs = [g, -b, b, g | vs]
        {new_rs, new_cs, new_vs}
      end)

    {Enum.reverse(rows), Enum.reverse(cols), Enum.reverse(vals)}
  end

  # Dense fallback using Nx when the NIF is unavailable
  defp solve_dense_2n(rows, cols, vals, rhs, dim) do
    try do
      # Build dense matrix from COO triplets
      matrix = List.duplicate(0.0, dim * dim) |> :array.from_list()

      matrix =
        Enum.zip([rows, cols, vals])
        |> Enum.reduce(matrix, fn {r, c, v}, arr ->
          idx = r * dim + c
          old = :array.get(idx, arr)
          :array.set(idx, old + v, arr)
        end)

      flat_matrix = Enum.map(0..(dim * dim - 1), &:array.get(&1, matrix))

      # Try the dense NIF first
      case Sparse.dense_solve_flat(flat_matrix, rhs, dim) do
        {:ok, solution} -> {:ok, solution}
        error -> error
      end
    rescue
      _e ->
        # Final fallback: Nx dense solve
        try do
          solution = Sparse.solve_dense(
            Enum.chunk_every(
              Enum.map(0..(dim * dim - 1), fn idx ->
                r = div(idx, dim)
                c = rem(idx, dim)
                # Rebuild from triplets
                Enum.reduce(Enum.zip([rows, cols, vals]), 0.0, fn {ri, ci, vi}, acc ->
                  if ri == r and ci == c, do: acc + vi, else: acc
                end)
              end),
              dim
            ),
            rhs
          )
          {:ok, solution}
        rescue
          _e2 -> {:error, :solve_failed}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private: fundamental solution map
  # ---------------------------------------------------------------------------

  defp build_fundamental_map(fundamental_solution) do
    bus_ids = Map.get(fundamental_solution, :bus_ids, [])
    vm = Map.get(fundamental_solution, :vm_pu, [])
    va = Map.get(fundamental_solution, :va_rad, [])

    bus_ids
    |> Enum.with_index()
    |> Map.new(fn {id, idx} ->
      v_mag = Enum.at(vm, idx, 1.0)
      v_angle = Enum.at(va, idx, 0.0)
      {id, {v_mag, v_angle}}
    end)
  end

  # ---------------------------------------------------------------------------
  # Private: IEEE 519 voltage limits
  # ---------------------------------------------------------------------------

  # IEEE 519-2022, Table 1: Voltage Distortion Limits
  # Returns {thd_limit_pct, individual_harmonic_limit_pct}
  defp ieee_519_voltage_limits(base_kv) do
    cond do
      base_kv <= 1.0 ->
        # Low voltage (residential/commercial)
        {8.0, 5.0}

      base_kv <= 69.0 ->
        # Medium voltage (distribution)
        {5.0, 3.0}

      base_kv <= 161.0 ->
        # High voltage (sub-transmission)
        {2.5, 1.5}

      true ->
        # Extra-high voltage (transmission)
        {1.5, 1.0}
    end
  end
end
