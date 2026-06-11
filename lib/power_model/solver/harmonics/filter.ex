defmodule PowerModel.Solver.Harmonics.Filter do
  @moduledoc """
  Passive harmonic filter design tools.

  Provides design equations for the two most common passive filter topologies
  used in power systems:

  ## Single-Tuned Filter

  A series RLC circuit tuned to resonate at the target harmonic frequency.
  At resonance, the filter presents a very low impedance path, shunting
  harmonic current away from the system. The filter is tuned slightly below
  the target harmonic (typically 3-5% detuning) to account for component
  tolerances and to ensure the filter remains effective even with aging.

  The design equations are:

      X_C = kV^2 / Q_mvar                  (capacitive reactance at fundamental)
      C   = 1 / (2*pi*f_0*X_C)             (capacitance in Farads)
      X_L = X_C / h_t^2                    (inductive reactance at fundamental)
      L   = X_L / (2*pi*f_0)               (inductance in Henries)
      R   = X_L * h_t / Q_factor           (resistance for desired quality factor)

  where h_t is the tuned harmonic order, Q_mvar is the reactive power
  compensation at fundamental frequency, and Q_factor controls the
  filter bandwidth (typical: 30-60 for transmission, 10-20 for distribution).

  ## High-Pass (Damped) Filter

  A first-order high-pass filter using a resistor in parallel with the
  inductor, providing broadband harmonic attenuation above the cutoff
  frequency. Less sharp than a tuned filter but effective across a wide
  frequency range. Used to attenuate higher-order harmonics where tuned
  filters are impractical.

  ## References

  - IEEE Std 1531-2003, "Guide for Application and Specification of
    Harmonic Filters".
  - Arrillaga & Watson, "Power System Harmonics", Ch. 10.
  - Das, J.C., "Power System Harmonics and Passive Filter Designs", 2015.
  """

  alias PowerModel.Solver.Harmonics.Solver

  @system_freq_hz 60.0
  @omega_0 2.0 * :math.pi() * @system_freq_hz

  @doc """
  Design a single-tuned passive harmonic filter.

  The filter is a series RLC circuit that resonates at the target harmonic
  frequency, providing a low-impedance shunt path for harmonic currents.

  ## Parameters

    * `target_harmonic` — the harmonic order to filter (e.g., 5 for 5th harmonic)
    * `bus_kv` — bus voltage in kV (used to compute impedance base)
    * `q_mvar_desired` — reactive power compensation at fundamental frequency (MVAr).
      This determines the capacitor size and also provides power factor correction.

  ## Options

    * `:q_factor` — quality factor controlling filter bandwidth (default 40).
      Higher Q = sharper tuning, narrower bandwidth. Typical values:
        - 30-60 for transmission (69 kV+)
        - 10-20 for industrial/distribution
    * `:detune_pct` — percent detuning below target harmonic (default 4.0).
      A 4% detune on 5th harmonic tunes the filter to h = 4.8 instead of 5.0,
      ensuring the filter remains effective with component aging.

  ## Returns

    ```
    %{
      target_harmonic: integer,
      tuned_harmonic: float,        # actual tuned frequency after detuning
      c_uf: float,                  # capacitance in microfarads
      l_mh: float,                  # inductance in millihenries
      r_ohm: float,                 # resistance in ohms
      q_factor: float,              # achieved quality factor
      x_c_ohm: float,              # capacitive reactance at fundamental (ohms)
      x_l_ohm: float,              # inductive reactance at fundamental (ohms)
      q_mvar_actual: float,         # actual reactive compensation (MVAr)
      bandwidth_hz: float           # 3-dB bandwidth around resonance (Hz)
    }
    ```
  """
  def design_single_tuned(target_harmonic, bus_kv, q_mvar_desired, opts \\ []) do
    q_factor = Keyword.get(opts, :q_factor, 40.0)
    detune_pct = Keyword.get(opts, :detune_pct, 4.0)

    # Apply detuning: tune slightly below the target harmonic
    # This accounts for component tolerance and ensures the filter stays
    # on the capacitive side (avoids accidental series resonance above target)
    h_tuned = target_harmonic * (1.0 - detune_pct / 100.0)

    # Capacitive reactance at fundamental frequency
    # X_C = V^2 / Q_mvar  (where V is in kV and Q is in MVAr)
    # This gives X_C in ohms
    x_c_ohm = bus_kv * bus_kv / max(q_mvar_desired, 0.001)

    # Capacitance: C = 1 / (omega_0 * X_C)
    c_farads = 1.0 / (@omega_0 * x_c_ohm)
    c_uf = c_farads * 1.0e6

    # At resonance: omega_r = h_tuned * omega_0 = 1 / sqrt(L*C)
    # Therefore: X_L(f_0) = omega_0 * L = X_C / h_tuned^2
    x_l_ohm = x_c_ohm / (h_tuned * h_tuned)

    # Inductance: L = X_L / omega_0
    l_henries = x_l_ohm / @omega_0
    l_mh = l_henries * 1.0e3

    # Resistance for desired quality factor
    # Q = X_L(resonance) / R = h_tuned * X_L(f_0) / R
    # Therefore: R = h_tuned * X_L(f_0) / Q
    r_ohm = h_tuned * x_l_ohm / q_factor

    # Actual reactive compensation at fundamental:
    # Q_actual = V^2 * (1/X_C - 1/X_L) / ... but for h_tuned >> 1,
    # the net reactive power is approximately the capacitor contribution
    # minus the small inductor contribution
    # Q_net = V^2 / X_C - V^2 / X_L = Q_mvar * (1 - 1/h_tuned^2)
    q_mvar_actual = q_mvar_desired * (1.0 - 1.0 / (h_tuned * h_tuned))

    # 3-dB bandwidth around resonance
    # BW = f_resonance / Q = (h_tuned * f_0) / Q_factor
    bandwidth_hz = h_tuned * @system_freq_hz / q_factor

    %{
      target_harmonic: target_harmonic,
      tuned_harmonic: h_tuned,
      c_uf: c_uf,
      l_mh: l_mh,
      r_ohm: r_ohm,
      q_factor: q_factor,
      x_c_ohm: x_c_ohm,
      x_l_ohm: x_l_ohm,
      q_mvar_actual: q_mvar_actual,
      bandwidth_hz: bandwidth_hz
    }
  end

  @doc """
  Design a first-order high-pass (damped) harmonic filter.

  A high-pass filter attenuates all harmonics above the cutoff frequency.
  It consists of a capacitor in series with a parallel combination of
  an inductor and a resistor. The resistor provides damping and prevents
  the sharp resonance peak of a tuned filter.

  ## Parameters

    * `cutoff_harmonic` — harmonic order for the -3dB cutoff frequency
    * `bus_kv` — bus voltage in kV
    * `q_mvar_desired` — reactive power compensation at fundamental (MVAr)

  ## Options

    * `:q_factor` — damping quality factor (default 1.0).
      Lower Q = more damping (flatter response). Typical: 0.5-2.0 for high-pass.
      Q < 1 gives overdamped response (broader attenuation).

  ## Returns

    ```
    %{
      cutoff_harmonic: float,
      c_uf: float,                  # series capacitance in microfarads
      l_mh: float,                  # shunt inductance in millihenries
      r_ohm: float,                 # parallel damping resistance in ohms
      q_factor: float,
      x_c_ohm: float,
      q_mvar_actual: float
    }
    ```
  """
  def design_high_pass(cutoff_harmonic, bus_kv, q_mvar_desired, opts \\ []) do
    q_factor = Keyword.get(opts, :q_factor, 1.0)

    # Series capacitor: same sizing as single-tuned
    x_c_ohm = bus_kv * bus_kv / max(q_mvar_desired, 0.001)
    c_farads = 1.0 / (@omega_0 * x_c_ohm)
    c_uf = c_farads * 1.0e6

    # Inductor tuned for cutoff frequency
    # At cutoff: omega_c = cutoff_harmonic * omega_0
    # L*C = 1/omega_c^2 => X_L = X_C / cutoff_harmonic^2
    x_l_ohm = x_c_ohm / (cutoff_harmonic * cutoff_harmonic)
    l_henries = x_l_ohm / @omega_0
    l_mh = l_henries * 1.0e3

    # Parallel damping resistor
    # R = Q * X_L(cutoff) = Q * cutoff_harmonic * X_L(fundamental)
    # For a high-pass filter, the resistor is in parallel with L
    r_ohm = q_factor * cutoff_harmonic * x_l_ohm

    # Net reactive compensation
    q_mvar_actual = q_mvar_desired * (1.0 - 1.0 / (cutoff_harmonic * cutoff_harmonic))

    %{
      cutoff_harmonic: cutoff_harmonic,
      c_uf: c_uf,
      l_mh: l_mh,
      r_ohm: r_ohm,
      q_factor: q_factor,
      x_c_ohm: x_c_ohm,
      q_mvar_actual: q_mvar_actual
    }
  end

  @doc """
  Evaluate the effectiveness of a proposed filter by computing THD reduction.

  Installs the filter at the specified bus (modifying the bus shunt admittance)
  and re-solves the harmonic power flow to determine the THD improvement.

  ## Parameters

    * `snapshot` — grid snapshot map
    * `bus_id` — bus where the filter will be installed
    * `filter_spec` — filter design map from `design_single_tuned/4` or
      `design_high_pass/4`
    * `harmonic_sources` — map of `%{bus_id => [device_spec, ...]}`

  ## Options

    * `:max_harmonic` — highest harmonic to analyze (default 25)
    * `:base_mva` — system base MVA (default 100.0)

  ## Returns

    ```
    %{
      thd_before: %{bus_id => thd_pct},
      thd_after: %{bus_id => thd_pct},
      thd_reduction_pct: %{bus_id => reduction_pct},
      filter_bus_thd_before: float,
      filter_bus_thd_after: float
    }
    ```
  """
  def evaluate_filter(snapshot, bus_id, filter_spec, harmonic_sources, opts \\ []) do
    max_h = Keyword.get(opts, :max_harmonic, 25)
    base_mva = Keyword.get(opts, :base_mva, 100.0)

    # Create a dummy fundamental solution (flat start: V=1.0, angle=0)
    bus_ids = Enum.map(snapshot.buses, & &1.id)
    n = length(bus_ids)

    fundamental = %{
      bus_ids: bus_ids,
      vm_pu: List.duplicate(1.0, n),
      va_rad: List.duplicate(0.0, n)
    }

    # Solve without filter
    {:ok, voltages_before} =
      Solver.solve(snapshot, fundamental, harmonic_sources,
        max_harmonic: max_h,
        base_mva: base_mva
      )

    thd_before = Solver.compute_thd(voltages_before)

    # Modify snapshot to include filter as additional shunt admittance at bus
    modified_snapshot = add_filter_to_snapshot(snapshot, bus_id, filter_spec, base_mva)

    # Solve with filter
    {:ok, voltages_after} =
      Solver.solve(modified_snapshot, fundamental, harmonic_sources,
        max_harmonic: max_h,
        base_mva: base_mva
      )

    thd_after = Solver.compute_thd(voltages_after)

    # Compute reduction
    thd_reduction =
      Map.new(bus_ids, fn id ->
        before = Map.get(thd_before, id, 0.0)
        after_val = Map.get(thd_after, id, 0.0)
        reduction = if before > 0.0, do: (before - after_val) / before * 100.0, else: 0.0
        {id, reduction}
      end)

    %{
      thd_before: thd_before,
      thd_after: thd_after,
      thd_reduction_pct: thd_reduction,
      filter_bus_thd_before: Map.get(thd_before, bus_id, 0.0),
      filter_bus_thd_after: Map.get(thd_after, bus_id, 0.0)
    }
  end

  # ---------------------------------------------------------------------------
  # Private: Add filter shunt admittance to the snapshot
  # ---------------------------------------------------------------------------

  # A single-tuned filter is a series RLC circuit connected from bus to ground.
  # Its admittance at harmonic h is:
  #   Y_filter(h) = 1 / (R + j*(h*X_L - X_C/h))
  #
  # We store the filter's physical parameters (R, L, C) on the snapshot so that
  # the harmonic Y-bus builder can compute the correct frequency-dependent
  # admittance at each harmonic order. The filter is represented as a per-harmonic
  # shunt admittance added to the target bus.
  #
  # For the fundamental frequency, the net reactive compensation is also added
  # to b_shunt_mvar for the base power flow.
  defp add_filter_to_snapshot(snapshot, bus_id, filter_spec, base_mva) do
    # Extract filter physical parameters
    x_c_ohm = Map.get(filter_spec, :x_c_ohm, 0.0)
    x_l_ohm = Map.get(filter_spec, :x_l_ohm, 0.0)
    r_ohm = Map.get(filter_spec, :r_ohm, 0.0)

    # Compute L and C from reactances at fundamental
    c_farads = if x_c_ohm > 0.0, do: 1.0 / (@omega_0 * x_c_ohm), else: 0.0
    l_henries = x_l_ohm / @omega_0

    # Find bus kV for impedance-to-pu conversion
    bus_kv =
      Enum.find_value(snapshot.buses, 1.0, fn bus ->
        if bus.id == bus_id, do: Map.get(bus, :base_kv) || 1.0
      end)

    # Store filter data on snapshot for the harmonic solver
    filter_data = %{
      bus_id: bus_id,
      r_ohm: r_ohm,
      l_henries: l_henries,
      c_farads: c_farads,
      bus_kv: bus_kv
    }

    # Add per-harmonic filter shunt admittances to the bus data.
    # For each harmonic h, the filter impedance is:
    #   Z_filter(h) = R + j*(h*omega_0*L - 1/(h*omega_0*C))
    # The admittance Y_filter(h) = 1/Z_filter(h) is added to the bus shunt.
    #
    # We pre-compute the filter admittance in MVAr-equivalent for each harmonic
    # and attach it to the bus as :harmonic_filter_shunts => %{h => {g_pu, b_pu}}.
    z_base = bus_kv * bus_kv / base_mva

    max_h = 25

    harmonic_shunts =
      Map.new(1..max_h, fn h ->
        omega_h = @omega_0 * h
        x_l_h = omega_h * l_henries
        x_c_h = if c_farads > 0.0, do: 1.0 / (omega_h * c_farads), else: 0.0
        z_im = x_l_h - x_c_h
        z_mag_sq = r_ohm * r_ohm + z_im * z_im

        if z_mag_sq > 1.0e-12 do
          # Y = (R - jX) / |Z|^2 in ohms^-1, then convert to pu
          g_ohm = r_ohm / z_mag_sq
          b_ohm = -z_im / z_mag_sq
          {h, {g_ohm * z_base, b_ohm * z_base}}
        else
          {h, {0.0, 0.0}}
        end
      end)

    modified_buses =
      Enum.map(snapshot.buses, fn bus ->
        if bus.id == bus_id do
          # Add fundamental reactive compensation to b_shunt_mvar
          {_g1, b1} = Map.get(harmonic_shunts, 1, {0.0, 0.0})
          existing_b = Map.get(bus, :b_shunt_mvar) || 0.0
          b_filter_mvar = b1 * base_mva

          bus
          |> Map.put(:b_shunt_mvar, existing_b + b_filter_mvar)
          |> Map.put(:harmonic_filter_shunts, harmonic_shunts)
        else
          bus
        end
      end)

    snapshot
    |> Map.put(:buses, modified_buses)
    |> Map.put(:harmonic_filters, [filter_data | Map.get(snapshot, :harmonic_filters, [])])
  end
end
