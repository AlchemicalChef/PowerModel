defmodule PowerModel.Solver.Harmonics.Sources do
  @moduledoc """
  Harmonic current injection models for nonlinear devices.

  Nonlinear loads and power electronic converters inject currents at harmonic
  frequencies into the power system. This module provides spectral models for
  the most common harmonic source types:

  ## Source Types

  - **6-pulse converter**: Classic thyristor bridge (HVDC terminals, large VFDs).
    Injects characteristic harmonics at h = 6k +/- 1 (5, 7, 11, 13, 17, 19, ...).
  - **12-pulse converter**: Two 6-pulse bridges with 30-degree phase shift.
    Cancels 5th and 7th, injects at h = 12k +/- 1 (11, 13, 23, 25, ...).
  - **PWM inverter**: Modern IBR (solar, wind, battery). Low-order harmonics are
    small due to PWM switching; significant content near the switching frequency.
  - **Arc furnace**: Broadband harmonic source with heavy low-order content and
    interharmonics. Highly variable and stochastic in nature.
  - **Saturated transformer**: GIC-driven or overexcited transformer core
    saturation produces even harmonics (2nd, 4th) plus 3rd harmonic.

  ## Units

  All injection magnitudes are returned in per-unit on the device's own MVA base.
  Angles are in radians. The caller is responsible for converting to the system
  per-unit base when aggregating injections.

  ## References

  - IEEE Std 519-2022, Table 2 (current distortion limits).
  - Arrillaga & Watson, "Power System Harmonics", 2nd ed., Ch. 3-5.
  - CIGRE WG 36.05, "Harmonics, characteristic parameters, methods of study,
    estimates of existing values in the network", Electra No. 77, 1981.
  """

  @doc """
  Harmonic current spectrum for a 6-pulse thyristor converter.

  A 6-pulse bridge produces characteristic harmonics at orders h = 6k +/- 1
  for k = 1, 2, 3, ... The theoretical (ideal) magnitudes follow I_h = I_1/h,
  but practical converters have higher amplitudes due to commutation overlap
  and control asymmetry, modeled as I_h = I_1 / h^alpha where alpha < 1.

  Returns a list of `{harmonic_order, magnitude_pu, angle_rad}` tuples.

  ## Options

    * `:max_harmonic` — highest harmonic to include (default 25)
    * `:alpha` — decay exponent; 1.0 = ideal, 0.8 = practical (default 0.8)

  ## Examples

      iex> Sources.six_pulse_spectrum(1.0)
      [{5, 0.1380..., ...}, {7, 0.1040..., ...}, {11, 0.0709..., ...}, ...]
  """
  def six_pulse_spectrum(i_fundamental_pu, opts \\ []) do
    max_h = Keyword.get(opts, :max_harmonic, 25)
    alpha = Keyword.get(opts, :alpha, 0.8)

    # Characteristic harmonics: h = 6k +/- 1 for k = 1, 2, 3, ...
    # Phase angles alternate: negative-sequence (5th, 11th, 17th, ...)
    #                         positive-sequence (7th, 13th, 19th, ...)
    1..div(max_h, 6)
    |> Enum.flat_map(fn k ->
      h_minus = 6 * k - 1  # 5, 11, 17, ...
      h_plus = 6 * k + 1   # 7, 13, 19, ...

      entries = []
      entries = if h_minus <= max_h do
        # Negative-sequence harmonics: phase angle ~= -pi/2 * (k-1) (simplified)
        mag = i_fundamental_pu / :math.pow(h_minus, alpha)
        angle = -:math.pi() / 2.0 * (k - 1)
        [{h_minus, mag, angle} | entries]
      else
        entries
      end

      if h_plus <= max_h do
        mag = i_fundamental_pu / :math.pow(h_plus, alpha)
        angle = :math.pi() / 2.0 * (k - 1)
        [{h_plus, mag, angle} | entries]
      else
        entries
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Harmonic current spectrum for a 12-pulse thyristor converter.

  A 12-pulse converter uses two 6-pulse bridges with a 30-degree phase shift
  (typically achieved via delta-wye and delta-delta transformer connections).
  This cancels the 5th, 7th, 17th, 19th, ... harmonics, leaving only
  h = 12k +/- 1 (11, 13, 23, 25, 35, 37, ...).

  In practice, some residual 5th and 7th content remains due to imperfect
  cancellation (~10-15% of the 6-pulse level), but this model assumes
  ideal cancellation.

  Returns a list of `{harmonic_order, magnitude_pu, angle_rad}` tuples.

  ## Options

    * `:max_harmonic` — highest harmonic to include (default 50)
    * `:alpha` — decay exponent (default 0.8)
  """
  def twelve_pulse_spectrum(i_fundamental_pu, opts \\ []) do
    max_h = Keyword.get(opts, :max_harmonic, 50)
    alpha = Keyword.get(opts, :alpha, 0.8)

    # Characteristic harmonics: h = 12k +/- 1 for k = 1, 2, 3, ...
    1..div(max_h, 12)
    |> Enum.flat_map(fn k ->
      h_minus = 12 * k - 1  # 11, 23, 35, ...
      h_plus = 12 * k + 1   # 13, 25, 37, ...

      entries = []
      entries = if h_minus <= max_h do
        mag = i_fundamental_pu / :math.pow(h_minus, alpha)
        angle = -:math.pi() / 3.0 * (k - 1)
        [{h_minus, mag, angle} | entries]
      else
        entries
      end

      if h_plus <= max_h do
        mag = i_fundamental_pu / :math.pow(h_plus, alpha)
        angle = :math.pi() / 3.0 * (k - 1)
        [{h_plus, mag, angle} | entries]
      else
        entries
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Harmonic current spectrum for a PWM inverter (IBR: solar, wind, battery).

  Modern grid-connected inverters use pulse-width modulation (PWM) with
  switching frequencies typically in the 2-20 kHz range. Low-order harmonics
  are small due to the modulation scheme, with the dominant content appearing
  near the switching frequency and its sidebands.

  This model uses typical measured values from IEEE and EPRI field studies
  of utility-scale PV and wind inverters. The current injection magnitude
  is computed from the real power output and terminal voltage:
    I_fundamental ~= P / V  (for unity power factor operation)

  Returns a list of `{harmonic_order, magnitude_pu, angle_rad}` tuples.

  ## Options

    * `:max_harmonic` — highest harmonic to include (default 25)
    * `:spectrum` — custom spectrum map `%{h => pct_of_fundamental}` (optional)
    * `:switching_freq_hz` — PWM switching frequency in Hz (default 5000)
    * `:system_freq_hz` — system frequency in Hz (default 60)
  """
  def pwm_inverter_spectrum(p_mw, v_pu, opts \\ []) do
    max_h = Keyword.get(opts, :max_harmonic, 25)
    base_mva = Keyword.get(opts, :base_mva, 100.0)

    # Fundamental current magnitude (pu on system base, assuming unity PF)
    i_fund = abs(p_mw) / base_mva / max(abs(v_pu), 0.01)

    # Default spectrum based on EPRI/IEEE field measurements of utility-scale inverters
    # Values are percentage of fundamental current
    default_spectrum = %{
      2 => 0.5,    # small even harmonic from asymmetry
      3 => 2.0,    # triplen (reduced by 3-phase cancellation in balanced systems)
      5 => 4.0,    # dominant low-order odd harmonic
      7 => 3.0,    # second characteristic harmonic
      9 => 1.0,    # triplen
      11 => 2.0,   # third characteristic
      13 => 1.5,   # fourth characteristic
      15 => 0.5,   # triplen
      17 => 1.0,   # near switching frequency sidebands
      19 => 0.8,
      23 => 0.5,
      25 => 0.3
    }

    spectrum = Keyword.get(opts, :spectrum, default_spectrum)

    spectrum
    |> Enum.filter(fn {h, _pct} -> h <= max_h and h >= 2 end)
    |> Enum.map(fn {h, pct} ->
      mag = i_fund * pct / 100.0
      # Phase angles for PWM harmonics are essentially random;
      # use zero as a simplification (conservative for THD calculation)
      {h, mag, 0.0}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Harmonic current spectrum for an electric arc furnace (EAF).

  Arc furnaces are among the most severe harmonic sources on the power system.
  The arc is inherently nonlinear and time-varying, producing a broadband
  spectrum with significant content at both odd and even harmonics. The
  spectrum varies with the melting phase (boring, melting, refining), but
  typical worst-case values are used here.

  The fundamental current is estimated from the furnace power rating:
    I_fund ~= P / V

  Returns a list of `{harmonic_order, magnitude_pu, angle_rad}` tuples.

  ## Options

    * `:max_harmonic` — highest harmonic to include (default 25)
    * `:phase` — `:melting` (default, worst case) or `:refining` (lower harmonics)
  """
  def arc_furnace_spectrum(p_mw, opts \\ []) do
    max_h = Keyword.get(opts, :max_harmonic, 25)
    phase = Keyword.get(opts, :phase, :melting)

    # Typical EAF harmonic current as % of fundamental (IEEE Std 519, Table E.1)
    # Melting phase has higher harmonics than refining phase
    {even_scale, odd_scale} = case phase do
      :refining -> {0.5, 0.6}
      _melting -> {1.0, 1.0}
    end

    # Base spectrum (% of fundamental) — from field measurements
    base_spectrum = %{
      2 => 7.7 * even_scale,    # even harmonics are significant in EAF
      3 => 5.8 * odd_scale,
      4 => 2.5 * even_scale,
      5 => 4.5 * odd_scale,
      6 => 1.0 * even_scale,
      7 => 3.0 * odd_scale,
      8 => 0.5 * even_scale,
      9 => 1.5 * odd_scale,
      11 => 2.0 * odd_scale,
      13 => 1.5 * odd_scale,
      17 => 0.8 * odd_scale,
      19 => 0.6 * odd_scale,
      23 => 0.4 * odd_scale,
      25 => 0.3 * odd_scale
    }

    # I_fund in per-unit of furnace MVA (assume V ~= 1.0 pu)
    i_fund = abs(p_mw)

    base_spectrum
    |> Enum.filter(fn {h, _pct} -> h <= max_h and h >= 2 end)
    |> Enum.map(fn {h, pct} ->
      mag = i_fund * pct / 100.0
      # Arc furnace harmonics have random phase; use zero (conservative)
      {h, mag, 0.0}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Harmonic current spectrum for a saturated transformer.

  When a transformer core is driven into saturation (e.g., by geomagnetically
  induced currents / GIC, or by overvoltage), the magnetizing current becomes
  highly nonlinear and rich in harmonics. The dominant harmonics from
  half-cycle saturation (typical of GIC) are the even harmonics (2nd, 4th)
  and 3rd harmonic.

  The magnetizing current `i_magnetizing_pu` is the peak magnetizing current
  drawn by the saturated transformer, in per-unit of rated current.

  Returns a list of `{harmonic_order, magnitude_pu, angle_rad}` tuples.

  ## Options

    * `:max_harmonic` — highest harmonic to include (default 25)
    * `:saturation_type` — `:gic` (half-cycle, default) or `:overexcitation` (symmetric)
  """
  def saturated_transformer_spectrum(i_magnetizing_pu, opts \\ []) do
    max_h = Keyword.get(opts, :max_harmonic, 25)
    sat_type = Keyword.get(opts, :saturation_type, :gic)

    # Spectrum depends on saturation mechanism
    # GIC: half-cycle saturation produces strong even harmonics
    # Overexcitation: symmetric saturation produces only odd harmonics
    spectrum = case sat_type do
      :gic ->
        %{
          2 => 63.0,    # dominant component in GIC-driven saturation
          3 => 26.0,
          4 => 19.0,
          5 => 8.5,
          6 => 7.2,
          7 => 3.5,
          8 => 3.0,
          9 => 1.5,
          10 => 1.2,
          11 => 0.8,
          13 => 0.5,
          15 => 0.3
        }

      :overexcitation ->
        # Symmetric saturation: only odd harmonics
        %{
          3 => 42.0,
          5 => 13.0,
          7 => 6.0,
          9 => 3.5,
          11 => 2.0,
          13 => 1.2,
          15 => 0.8,
          17 => 0.5,
          19 => 0.3
        }
    end

    spectrum
    |> Enum.filter(fn {h, _pct} -> h <= max_h and h >= 2 end)
    |> Enum.map(fn {h, pct} ->
      mag = i_magnetizing_pu * pct / 100.0
      # Saturation harmonics are approximately in phase with the magnetizing current
      # Use zero phase as simplification
      {h, mag, 0.0}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Aggregate all harmonic current injections at a given bus for harmonic order h.

  Takes a list of device descriptors at a bus and returns the total complex
  current injection `{i_real, i_imag}` in per-unit at harmonic `h`.

  Each device is a map with:
    * `:type` — `:six_pulse`, `:twelve_pulse`, `:pwm_inverter`, `:arc_furnace`,
                `:saturated_transformer`
    * `:i_fundamental_pu` — fundamental current (for converter types)
    * `:p_mw` — real power (for inverter and arc furnace types)
    * `:v_pu` — terminal voltage (for inverter type)
    * `:i_magnetizing_pu` — magnetizing current (for saturated transformer)
    * `:opts` — additional options passed to the spectrum function

  Returns `{i_real_total, i_imag_total}` at harmonic h.
  """
  def aggregate_bus_injections(devices_at_bus, h) when is_integer(h) and h >= 2 do
    Enum.reduce(devices_at_bus, {0.0, 0.0}, fn device, {acc_re, acc_im} ->
      spectrum = get_device_spectrum(device)

      case Enum.find(spectrum, fn {order, _mag, _angle} -> order == h end) do
        {_h, mag, angle} ->
          # Convert polar to rectangular: I = mag * (cos(angle) + j*sin(angle))
          i_re = mag * :math.cos(angle)
          i_im = mag * :math.sin(angle)
          {acc_re + i_re, acc_im + i_im}

        nil ->
          {acc_re, acc_im}
      end
    end)
  end

  def aggregate_bus_injections(_devices, _h), do: {0.0, 0.0}

  # ---------------------------------------------------------------------------
  # Private: dispatch to the appropriate spectrum function
  # ---------------------------------------------------------------------------

  defp get_device_spectrum(device) do
    opts = Map.get(device, :opts, [])

    case device.type do
      :six_pulse ->
        six_pulse_spectrum(device.i_fundamental_pu, opts)

      :twelve_pulse ->
        twelve_pulse_spectrum(device.i_fundamental_pu, opts)

      :pwm_inverter ->
        pwm_inverter_spectrum(device.p_mw, Map.get(device, :v_pu, 1.0), opts)

      :arc_furnace ->
        arc_furnace_spectrum(device.p_mw, opts)

      :saturated_transformer ->
        saturated_transformer_spectrum(device.i_magnetizing_pu, opts)

      _ ->
        []
    end
  end
end
