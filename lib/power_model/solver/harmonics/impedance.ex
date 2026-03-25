defmodule PowerModel.Solver.Harmonics.Impedance do
  @moduledoc """
  Frequency-dependent impedance models for harmonic analysis.

  At the fundamental frequency (h=1), component impedances are as stored in
  the database. At harmonic order h, skin effect, proximity effect, and
  frequency-dependent reactance modify the impedance according to standard
  power systems models.

  ## Physical Basis

  - **Transmission lines**: Resistance increases as sqrt(h) due to skin effect
    (current crowds toward the conductor surface at higher frequencies). Inductive
    reactance X_L = omega*L scales linearly with h. Capacitive susceptance
    B_C = omega*C also scales linearly with h.

  - **Transformers**: Leakage reactance is predominantly inductive, so X scales
    with h. Winding resistance increases with sqrt(h) due to skin and proximity
    effects in the copper conductors.

  - **Generators**: Subtransient reactance X"d is the effective impedance seen
    by harmonic currents because the rotor circuits are effectively shorted at
    frequencies well above fundamental. For h > 1, generator impedance is
    approximately constant at X"d, independent of harmonic order.

  ## References

  - Arrillaga, Watson, "Power System Harmonics", 2nd ed., Wiley, 2003.
  - IEEE Std 519-2022, "Harmonic Control in Electric Power Systems".
  - Task Force on Harmonics Modeling, IEEE PES, "Tutorial on Harmonics Modeling
    and Simulation", 1998.
  """

  alias PowerModel.Solver.YBus

  @doc """
  Compute transmission line impedance at harmonic order h.

  Returns `{r_h, x_h, b_h}` in per-unit, where:
    - R_h = R_1 * sqrt(h)   — skin effect increases AC resistance
    - X_h = X_1 * h         — inductive reactance scales with frequency
    - B_h = B_1 * h         — capacitive susceptance scales with frequency

  The line charging susceptance B_h increases with frequency, which means
  long transmission lines become more capacitive at higher harmonics. This
  is a key driver of parallel resonance in transmission networks.
  """
  def line_impedance_at_harmonic(line, h) when is_number(h) and h >= 1 do
    r1 = line.r_pu || 0.0
    x1 = line.x_pu || 0.001
    b1 = line.b_pu || 0.0

    r_h = r1 * :math.sqrt(h)
    x_h = x1 * h
    b_h = b1 * h

    {r_h, x_h, b_h}
  end

  @doc """
  Compute transformer impedance at harmonic order h.

  Returns `{r_h, x_h}` in per-unit, where:
    - R_h = R_1 * sqrt(h)   — winding skin/proximity effect
    - X_h = X_1 * h         — leakage reactance is inductive

  Transformer magnetizing impedance (very large, typically ignored in
  short-circuit and harmonic studies) is not modeled. Only the series
  leakage branch is frequency-scaled.
  """
  def transformer_impedance_at_harmonic(xfmr, h) when is_number(h) and h >= 1 do
    r1 = xfmr.r_pu || 0.0
    x1 = xfmr.x_pu || 0.001

    r_h = r1 * :math.sqrt(h)
    x_h = x1 * h

    {r_h, x_h}
  end

  @doc """
  Compute generator impedance at harmonic order h.

  Returns `{r_h, x_h}` in per-unit.

  For h = 1, returns the generator's normal impedance (x_d_pu or a default).
  For h > 1, the effective impedance is the subtransient reactance X"d,
  which is the impedance presented by the machine to rapidly-varying
  currents. The subtransient reactance is approximately constant for all
  harmonic orders h >= 2.

  If X"d (x_d_prime_pu in our schema) is not available, we estimate it as:
    X"d ~= X'd * 0.7    (if X'd is available)
    X"d ~= 0.2 pu       (fallback default for a typical synchronous machine)

  Generator resistance at harmonics is typically small and is estimated as
  R_h ~= 0.1 * X"d (a rough approximation from IEEE harmonic task force
  recommendations, representing both armature resistance and damper winding
  losses).
  """
  def generator_impedance_at_harmonic(gen, h) when is_number(h) and h >= 1 do
    # Determine subtransient reactance
    x_subtransient = determine_x_subtransient(gen)

    if h <= 1 do
      # At fundamental, use the full synchronous reactance
      x1 = Map.get(gen, :x_d_pu) || x_subtransient
      r1 = Map.get(gen, :ra_pu) || 0.003
      {r1, x1}
    else
      # At harmonics h > 1, generator reactance scales with frequency:
      # X_h = h * X"d (inductive reactance increases linearly with frequency)
      # Resistance increases with sqrt(h) due to skin effect in rotor bars
      r_h = 0.1 * x_subtransient * :math.sqrt(h)
      x_h = h * x_subtransient
      {r_h, x_h}
    end
  end

  @doc """
  Build the bus admittance matrix (Y-bus) at harmonic order h.

  Same structure as `YBus.build/4` but with frequency-scaled impedances.
  Returns a `%YBus{}` struct with triplets in `{row, col, {re, im}}` format.

  At h=1 this produces the same result as the standard Y-bus builder.
  At h>1, all impedances are scaled according to the frequency-dependent
  models in this module, and generator shunt admittances are added to
  represent the subtransient impedance grounding each generator bus.

  ## Parameters

    * `buses` — list of bus maps (must have `:id`, `:base_kv`, `:b_shunt_mvar`)
    * `lines` — list of transmission line maps
    * `transformers` — list of transformer maps
    * `generators` — list of generator maps (must have `:bus_id`)
    * `h` — harmonic order (integer >= 1)
    * `base_mva` — system base MVA (default 100.0)
  """
  def build_ybus_at_harmonic(buses, lines, transformers, generators, h, base_mva \\ 100.0) do
    bus_index_map =
      buses
      |> Enum.with_index()
      |> Map.new(fn {bus, idx} -> {bus.id, idx} end)

    n = map_size(bus_index_map)

    # Accumulate Y-bus entries using a map for O(1) per-entry updates
    ybus_map =
      lines
      |> Enum.reduce(%{}, fn line, acc ->
        add_harmonic_line(acc, line, bus_index_map, h)
      end)
      |> then(fn acc ->
        Enum.reduce(transformers, acc, fn xfmr, acc2 ->
          add_harmonic_transformer(acc2, xfmr, bus_index_map, h)
        end)
      end)
      |> then(fn acc ->
        # Add generator subtransient admittances as shunts at generator buses
        # This represents the generator's impedance to harmonic currents
        add_generator_shunts(acc, generators, bus_index_map, h)
      end)
      |> then(fn acc ->
        # Add bus shunt susceptance (capacitor banks, etc.) — scales with h
        # Also add per-harmonic filter shunt admittances if present
        Enum.reduce(buses, acc, fn bus, acc2 ->
          idx = Map.fetch!(bus_index_map, bus.id)

          # Standard shunt susceptance (capacitor banks): scales linearly with h
          acc2 = case Map.get(bus, :b_shunt_mvar) || 0.0 do
            bs when bs != 0.0 ->
              bs_pu = bs / base_mva * h
              add_to_ybus_map(acc2, idx, idx, 0.0, bs_pu)
            _ -> acc2
          end

          # Per-harmonic filter shunts: pre-computed (g_pu, b_pu) for each h
          # These are set by the filter module when a passive filter is installed
          case Map.get(bus, :harmonic_filter_shunts) do
            %{} = shunts ->
              case Map.get(shunts, h) do
                {g_pu, b_pu} when abs(g_pu) > 1.0e-15 or abs(b_pu) > 1.0e-15 ->
                  add_to_ybus_map(acc2, idx, idx, g_pu, b_pu)
                _ -> acc2
              end
            _ -> acc2
          end
        end)
      end)

    # Convert map to sorted triplet list
    triplets =
      ybus_map
      |> Enum.reject(fn {_key, {re, im}} -> abs(re) < 1.0e-15 and abs(im) < 1.0e-15 end)
      |> Enum.map(fn {{r, c}, {re, im}} -> {r, c, {re, im}} end)

    %YBus{
      n: n,
      triplets: triplets,
      bus_index_map: bus_index_map,
      base_mva: base_mva
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp determine_x_subtransient(gen) do
    cond do
      # Use explicit X"d if available (stored as x_d_prime_pu in our schema)
      is_number(Map.get(gen, :x_d_prime_pu)) and Map.get(gen, :x_d_prime_pu) > 0 ->
        gen.x_d_prime_pu

      # Estimate from X'd if available: X"d ~= X'd * 0.7
      is_number(Map.get(gen, :x_q_prime_pu)) and Map.get(gen, :x_q_prime_pu) > 0 ->
        gen.x_q_prime_pu * 0.7

      # Estimate from X_d if available: X"d ~= X_d * 0.3
      is_number(Map.get(gen, :x_d_pu)) and Map.get(gen, :x_d_pu) > 0 ->
        gen.x_d_pu * 0.3

      # Fallback: typical subtransient reactance for a synchronous machine
      true ->
        0.2
    end
  end

  defp add_to_ybus_map(map, r, c, re, im) do
    Map.update(map, {r, c}, {re, im}, fn {re_old, im_old} -> {re_old + re, im_old + im} end)
  end

  # Add a transmission line to the Y-bus map with frequency-scaled impedance
  defp add_harmonic_line(map, line, bus_index_map, h) do
    from_id = line.from_bus_id
    to_id = line.to_bus_id

    # Skip lines whose buses aren't in the index (shouldn't happen in a clean snapshot)
    case {Map.get(bus_index_map, from_id), Map.get(bus_index_map, to_id)} do
      {nil, _} -> map
      {_, nil} -> map
      {i, j} ->
        {r_h, x_h, b_h} = line_impedance_at_harmonic(line, h)

        # Series admittance: y_series = 1 / (r_h + j*x_h) = (r_h - j*x_h) / (r_h^2 + x_h^2)
        denom = r_h * r_h + x_h * x_h
        g_series = r_h / max(denom, 1.0e-12)
        b_series = -x_h / max(denom, 1.0e-12)

        # Shunt admittance (line charging): j*b_h/2 per end
        b_shunt = b_h / 2.0

        map
        |> add_to_ybus_map(i, i, g_series, b_series + b_shunt)
        |> add_to_ybus_map(j, j, g_series, b_series + b_shunt)
        |> add_to_ybus_map(i, j, -g_series, -b_series)
        |> add_to_ybus_map(j, i, -g_series, -b_series)
    end
  end

  # Add a transformer to the Y-bus map with frequency-scaled impedance
  defp add_harmonic_transformer(map, xfmr, bus_index_map, h) do
    from_id = xfmr.from_bus_id
    to_id = xfmr.to_bus_id

    case {Map.get(bus_index_map, from_id), Map.get(bus_index_map, to_id)} do
      {nil, _} -> map
      {_, nil} -> map
      {i, j} ->
        {r_h, x_h} = transformer_impedance_at_harmonic(xfmr, h)
        a = xfmr.tap_ratio || 1.0
        shift_deg = Map.get(xfmr, :phase_shift_deg) || 0.0
        shift_rad = shift_deg * :math.pi() / 180.0

        denom = r_h * r_h + x_h * x_h
        gs = r_h / max(denom, 1.0e-12)
        bs = -x_h / max(denom, 1.0e-12)

        if shift_rad == 0.0 do
          map
          |> add_to_ybus_map(i, i, gs / (a * a), bs / (a * a))
          |> add_to_ybus_map(j, j, gs, bs)
          |> add_to_ybus_map(i, j, -gs / a, -bs / a)
          |> add_to_ybus_map(j, i, -gs / a, -bs / a)
        else
          cos_s = :math.cos(shift_rad)
          sin_s = :math.sin(shift_rad)

          yft_re = (-gs * cos_s + bs * sin_s) / a
          yft_im = (-bs * cos_s - gs * sin_s) / a
          ytf_re = (-gs * cos_s - bs * sin_s) / a
          ytf_im = (-bs * cos_s + gs * sin_s) / a

          map
          |> add_to_ybus_map(i, i, gs / (a * a), bs / (a * a))
          |> add_to_ybus_map(j, j, gs, bs)
          |> add_to_ybus_map(i, j, yft_re, yft_im)
          |> add_to_ybus_map(j, i, ytf_re, ytf_im)
        end
    end
  end

  # Add generator subtransient admittances as diagonal shunts
  # Each generator contributes y_gen = 1 / (r_h + j*x"d) to its bus diagonal
  defp add_generator_shunts(map, generators, bus_index_map, h) do
    Enum.reduce(generators, map, fn gen, acc ->
      bus_id = gen.bus_id

      case Map.get(bus_index_map, bus_id) do
        nil -> acc
        idx ->
          {r_h, x_h} = generator_impedance_at_harmonic(gen, h)
          denom = r_h * r_h + x_h * x_h
          g_gen = r_h / max(denom, 1.0e-12)
          b_gen = -x_h / max(denom, 1.0e-12)
          add_to_ybus_map(acc, idx, idx, g_gen, b_gen)
      end
    end)
  end
end
