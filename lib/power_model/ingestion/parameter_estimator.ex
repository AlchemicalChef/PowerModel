defmodule PowerModel.Ingestion.ParameterEstimator do
  @moduledoc """
  Estimates electrical parameters for transmission lines and generators
  using IEEE/EPRI standard per-unit-length values by voltage class.

  Key features:
  - Uses bus-to-bus haversine distance when line geometry is missing
  - Accounts for parallel circuits (500 kV+ lines often double-circuit)
  - Derates ratings for summer ambient temperature
  - Caps EHV ratings at St. Clair loadability (ROADMAP item 10)
  - Derives the emergency rating tiers (rate B / rate C) protection picks up on

  ## Which rows this pass owns

  Estimation is versioned (`params_version/0`, ROADMAP item 8): a row stamped
  below the current version is RECOMPUTED, not skipped. The previous
  "fill NULLs only" predicate meant a corrected parameter table could never
  reach a row that already had values, so improvements shipped in code never
  appeared in the network being simulated.

  Rows from imported cases (`@imported_sources`) are never touched. Those
  arrive with parameters from their own source — the SyntheticUSA MATPOWER
  component carries internally consistent impedances, and the international
  ties carry hand-curated ones — and neither has the geometry this estimator
  would need to re-derive them. Recomputing them would replace real data with
  a class-table guess against a default length.

  ## How a rating is built

  Rate A is `min(thermal ceiling, stability limit)`:

    * the **thermal ceiling** is the flat class rating derated for ambient
      temperature (`ambient_rating_derate/1`);
    * the **stability limit** is `SIL x St. Clair loadability(length)`, applied
      ONLY above #{300} kV.

  Below 300 kV the rating stays flat per class. MEASURED: making sub-300 kV
  ratings length-aware makes the network's overload census worse — line
  lengths at those voltages are dominated by inferred HIFLD geometry, and a
  wrong length turns into a wrong rating with no offsetting gain.

  Rates B and C are fixed multiples of rate A (`PowerModel.Grid.Ratings`).
  Rate A remains the display and "stressed" basis; rate C is the relay pickup.
  """

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.{TransmissionLine, Generator, Bus, Ratings}

  # IEEE/EPRI standard values per voltage class
  # {R (ohm/km), X (ohm/km), B (uS/km), Thermal rating (MVA), typical_circuits}
  # typical_circuits: number of parallel circuits common at this voltage class.
  # NOTE: US EHV (500/765 kV) is overwhelmingly SINGLE-circuit construction --
  # the entire AEP 765 kV network is single circuit. Assuming 2 halves
  # impedance and doubles ratings, systematically understating EHV loading.
  #
  # EHV resistance (345 kV and up) is the AC resistance of the standard bundle
  # at a 50 C conductor temperature. The previous values implied an X/R of 30
  # at 500 kV and 46.7 at 765 kV, which no real overhead line achieves --
  # physical EHV X/R is 12-20. Bundles assumed:
  #   345 kV  2 x 954 kcmil ACSR "Rail"   -> 0.025 ohm/km   X/R = 13.4
  #   500 kV  3 x 1113 kcmil ACSR "Finch" -> 0.020 ohm/km   X/R = 15.0
  #   765 kV  4 x 954 kcmil ACSR "Rail"   -> 0.015 ohm/km   X/R = 18.7
  # (ACSR AC resistance from the Aluminum Association conductor tables, scaled
  # from 25 C to a 50 C operating temperature and divided by the bundle count;
  # reactances unchanged. Cross-checked against the typical EHV line constants
  # in Glover, Sarma & Overbye, "Power System Analysis and Design", App. A.)
  #
  # Only the DC solve reads these today, and DC ignores R entirely -- the
  # correction matters for the AC solver and for anything computing losses.
  @line_params %{
    69 => {0.170, 0.450, 2.7, 130.0, 1},
    115 => {0.100, 0.420, 2.9, 200.0, 1},
    138 => {0.075, 0.400, 3.0, 250.0, 1},
    161 => {0.060, 0.390, 3.1, 300.0, 1},
    230 => {0.040, 0.370, 3.3, 450.0, 1},
    345 => {0.025, 0.335, 3.6, 900.0, 1},
    500 => {0.020, 0.300, 4.0, 1800.0, 1},
    765 => {0.015, 0.280, 4.5, 3200.0, 1}
  }

  @base_mva 100.0

  # ---------------------------------------------------------------------------
  # Loadability (ROADMAP item 10)
  # ---------------------------------------------------------------------------

  # Surge Impedance Loading in MW: SIL = kV^2 / Zc, with Zc the surge impedance
  # of the standard bundle at that class -- 345 kV 2-bundle ~285 ohm, 500 kV
  # 3-bundle ~250 ohm, 765 kV 4-bundle ~257 ohm. Matches the published values
  # in the EPRI Transmission Line Reference Book ("Red Book") and Glover,
  # Sarma & Overbye Table 5.1.
  @sil_mw %{
    345 => 420.0,
    500 => 1000.0,
    765 => 2280.0
  }

  # The loadability cap applies ABOVE this voltage only -- see the moduledoc
  # for why sub-300 kV ratings stay flat.
  @ehv_min_kv 300.0

  # St. Clair curve: line loadability as a multiple of SIL versus length, for a
  # strong terminal system under the classic criteria (5% voltage drop, ~35
  # degree angle across the line, 30% reactive margin). Breakpoints from
  # H. P. St. Clair, "Practical Concepts in Capability and Performance of
  # Transmission Lines" (AIEE Trans. 1953), as extended analytically by
  # R. D. Dunlop, R. Gutman & P. P. Marchenko, "Analytical Development of
  # Loadability Characteristics for EHV and UHV Transmission Lines", IEEE
  # Trans. PAS-98 no. 2 (1979).
  #
  # Held in miles because that is the axis of the published figure, so each
  # breakpoint is checkable against the source.
  @st_clair_curve [
    {50, 3.00},
    {100, 2.00},
    {150, 1.60},
    {200, 1.35},
    {250, 1.20},
    {300, 1.05},
    {350, 0.95},
    {400, 0.85},
    {500, 0.72},
    {600, 0.62}
  ]

  @km_per_mile 1.609344

  # Bumped whenever the line parameter recipe above changes;
  # `estimate_line_parameters/1` recomputes every line stamped lower.
  #
  #   1 = class-table impedance + emergency rating tiers
  #   2 = physical EHV resistance, St. Clair loadability cap above 300 kV,
  #       ambient derate moved from resistance onto the rating (ROADMAP item 10)
  #
  # Version 2 changes what rate A MEANS, so rows a version-1 estimator already
  # stamped have to be revisited — without the bump they would read as current
  # and keep an uncapped, underated rating forever, which is the exact failure
  # mode (REVIEW DAT-18) that versioning exists to prevent.
  @params_version 2

  # Sources whose parameters come from the imported case, not from this
  # estimator. See the moduledoc.
  @imported_sources ~w(matpower international)

  # Default ambient temperature for summer derating (Celsius)
  @default_ambient_temp_c 35.0

  # Ambient derating of the THERMAL rating (ROADMAP item 10). This derate used
  # to be applied to RESISTANCE through the aluminium temperature coefficient
  # (alpha = 0.004/C), which the DC power flow never reads -- so it changed
  # nothing. Protection compares flow against the RATING, so the rating is
  # where an ambient derate belongs.
  #
  # Steady-state conductor heat balance is I^2 R = h (T_conductor - T_ambient),
  # so at a fixed conductor limit ampacity scales as sqrt(T_limit - T_ambient)
  # -- the IEEE 738 convection term, with solar and radiation second order for
  # this purpose. At the 35 C default that is a 10.6% derate, against a class
  # table quoted at a 25 C reference ambient.
  @conductor_limit_c 75.0
  @rating_reference_ambient_c 25.0

  def run do
    estimate_line_parameters()
    estimate_generator_q_limits()
  end

  @doc "Version of the line parameter recipe; rows stamped lower are recomputed."
  def params_version, do: @params_version

  @doc """
  Estimate per-unit parameters and rating tiers for transmission lines.

  Covers every line this estimator owns (see the moduledoc) that is either
  missing impedance or stamped below `params_version/0`. Returns the number of
  lines written.

  Options:
  - `:ambient_temp_c` — ambient temperature for the rating derate (default 35 C)
  """
  def estimate_line_parameters(opts \\ []) do
    ambient_temp = Keyword.get(opts, :ambient_temp_c, @default_ambient_temp_c)

    lines =
      from(tl in TransmissionLine,
        where:
          (is_nil(tl.r_pu) or is_nil(tl.x_pu) or tl.params_version < @params_version) and
            (is_nil(tl.source) or tl.source not in @imported_sources),
        preload: [:from_bus, :to_bus]
      )
      |> Repo.all()

    Enum.reduce(lines, 0, fn line, written ->
      voltage_kv = line.voltage_kv || 0.0

      if voltage_kv > 0 do
        line
        |> Ecto.Changeset.change(line_params(line, ambient_temp))
        |> Repo.update()

        written + 1
      else
        # No usable voltage, so no class to estimate from. Stamp it anyway so
        # the pass does not reconsider it on every run.
        line
        |> Ecto.Changeset.change(%{params_version: @params_version})
        |> Repo.update()

        written
      end
    end)
  end

  @doc """
  The full parameter map for one line — per-unit impedances, ratings A/B/C,
  length, and the version stamp.

  Split out of the update loop so the recipe is directly testable without a
  database. The line may be a schema struct or any map carrying
  `:voltage_kv`, `:length_km`, `:geometry`, `:from_bus` and `:to_bus`.
  """
  def line_params(line, ambient_temp \\ @default_ambient_temp_c) do
    voltage_kv = Map.get(line, :voltage_kv) || 0.0
    {r_per_km, x_per_km, b_per_km, _thermal, typical_circuits} = lookup_line_params(voltage_kv)

    length_km =
      Map.get(line, :length_km) ||
        estimate_length(Map.get(line, :geometry)) ||
        estimate_length_from_buses(Map.get(line, :from_bus), Map.get(line, :to_bus))

    z_base = voltage_kv * voltage_kv / @base_mva

    # Apply parallel circuit factor: impedance halves, rating doubles
    n_circuits = typical_circuits

    # The class table is this estimator's authority for the rating, so a
    # recompute adopts the current table value rather than preserving what an
    # earlier version of the table wrote. Keeping the stored value (the old
    # `line.rating_a_mva || rating`) made the rating permanently uncorrectable,
    # which is the whole defect versioning exists to fix.
    rating_a = rating_a_mva(voltage_kv, length_km, ambient_temp) * n_circuits

    %{
      r_pu: r_per_km * length_km / (z_base * n_circuits),
      x_pu: max(x_per_km * length_km / (z_base * n_circuits), 0.0001),
      b_pu: b_per_km * 1.0e-6 * length_km * z_base * n_circuits,
      rating_a_mva: rating_a,
      rating_b_mva: Ratings.rate_b_from_a(rating_a),
      rating_c_mva: Ratings.rate_c_from_a(rating_a),
      length_km: length_km,
      params_version: @params_version
    }
  end

  @doc """
  Normal (rate A) rating in MVA for a single circuit.

  Below #{trunc(@ehv_min_kv)} kV this is the flat class thermal rating with the
  ambient derate applied. Above it, the rating is additionally capped by
  St. Clair loadability: an EHV line long enough to be angle- or
  voltage-limited cannot deliver its conductors' thermal rating however cool
  the day is, which is why the stability cap is NOT derated for ambient.
  """
  def rating_a_mva(voltage_kv, length_km, ambient_temp \\ @default_ambient_temp_c) do
    {_r, _x, _b, thermal_mva, _circuits} = lookup_line_params(voltage_kv)
    thermal = thermal_mva * ambient_rating_derate(ambient_temp)

    case sil_mw(voltage_kv) do
      nil -> thermal
      sil -> min(thermal, sil * st_clair_loadability(length_km))
    end
  end

  @doc """
  Surge Impedance Loading in MW for a voltage, or `nil` at or below
  #{trunc(@ehv_min_kv)} kV where the loadability cap is deliberately not
  applied.
  """
  def sil_mw(voltage_kv) when is_number(voltage_kv) do
    if voltage_kv > @ehv_min_kv do
      closest = @sil_mw |> Map.keys() |> Enum.min_by(&abs(&1 - voltage_kv))
      Map.fetch!(@sil_mw, closest)
    end
  end

  def sil_mw(_), do: nil

  @doc """
  St. Clair loadability for a line of `length_km`, as a multiple of SIL.

  Linearly interpolated between the published breakpoints. Below 50 miles it
  is clamped to the first breakpoint — short lines are thermally limited, and
  the `min/2` against the thermal ceiling in `rating_a_mva/3` is what expresses
  that — and beyond 600 miles to the last.
  """
  def st_clair_loadability(length_km) when is_number(length_km) and length_km >= 0 do
    interpolate(@st_clair_curve, length_km / @km_per_mile)
  end

  def st_clair_loadability(_), do: @st_clair_curve |> hd() |> elem(1)

  @doc """
  Thermal rating multiplier for an ambient temperature, relative to the
  #{trunc(@rating_reference_ambient_c)} C reference the class table is quoted
  at. Clamped so an absurd input cannot produce a nonsensical rating.
  """
  def ambient_rating_derate(ambient_temp_c) when is_number(ambient_temp_c) do
    headroom = @conductor_limit_c - ambient_temp_c
    reference = @conductor_limit_c - @rating_reference_ambient_c

    (headroom / reference)
    |> max(0.0)
    |> :math.sqrt()
    |> max(0.25)
    |> min(1.25)
  end

  def ambient_rating_derate(_), do: 1.0

  # Piecewise-linear lookup over an ascending {x, y} table, clamped at both ends.
  defp interpolate([{_x0, y0} | _] = curve, value) do
    {last_x, last_y} = List.last(curve)

    cond do
      value <= elem(hd(curve), 0) ->
        y0

      value >= last_x ->
        last_y

      true ->
        curve
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.find_value(fn [{x1, y1}, {x2, y2}] ->
          if value >= x1 and value <= x2 do
            y1 + (y2 - y1) * (value - x1) / (x2 - x1)
          end
        end)
    end
  end

  @doc "Estimate reactive power limits for generators"
  def estimate_generator_q_limits do
    generators =
      from(g in Generator,
        where: is_nil(g.q_max_mvar)
      )
      |> Repo.all()

    Enum.each(generators, fn gen ->
      {q_max, q_min} = estimate_q_limits(gen)

      gen
      |> Ecto.Changeset.change(%{q_max_mvar: q_max, q_min_mvar: q_min})
      |> Repo.update()
    end)
  end

  @doc "Look up standard parameters for a voltage level"
  def lookup_line_params(voltage_kv) do
    # Find closest voltage class
    closest =
      @line_params
      |> Map.keys()
      |> Enum.min_by(&abs(&1 - voltage_kv))

    Map.fetch!(@line_params, closest)
  end

  @doc "Convert physical parameters to per-unit"
  def to_per_unit(
        r_ohm_per_km,
        x_ohm_per_km,
        b_us_per_km,
        length_km,
        base_kv,
        base_mva \\ @base_mva
      ) do
    z_base = base_kv * base_kv / base_mva

    %{
      r_pu: r_ohm_per_km * length_km / z_base,
      x_pu: x_ohm_per_km * length_km / z_base,
      b_pu: b_us_per_km * 1.0e-6 * length_km * z_base
    }
  end

  # Private

  defp estimate_q_limits(gen) do
    p_max = gen.p_max_mw

    case categorize_prime_mover(gen.prime_mover) do
      :synchronous ->
        # Synchronous machines: power factor ~0.85 lagging
        q_max = p_max * 0.6
        q_min = -p_max * 0.3
        {q_max, q_min}

      :inverter ->
        # Inverter-based (solar, wind): limited reactive capability
        q_max = p_max * 0.33
        q_min = -p_max * 0.33
        {q_max, q_min}

      :induction ->
        # Induction generators (some wind): consume reactive
        q_max = 0.0
        q_min = -p_max * 0.3
        {q_max, q_min}
    end
  end

  defp categorize_prime_mover(nil), do: :synchronous

  defp categorize_prime_mover(pm) do
    pm_upper = String.upcase(pm)

    cond do
      pm_upper in ~w(PV BA) -> :inverter
      pm_upper in ~w(WT WS) -> :inverter
      pm_upper in ~w(ST GT IC CA CT CS) -> :synchronous
      pm_upper in ~w(HY PS) -> :synchronous
      pm_upper == "IG" -> :induction
      true -> :synchronous
    end
  end

  @doc """
  Estimate geodesic length (km) from line geometry. Returns nil when geometry
  is missing or degenerate so the caller can fall back to bus-to-bus distance.

  Accepts both 2-tuple `{lon, lat}` and 3-tuple `{lon, lat, z}` coordinates
  (Z is dropped). MultiLineString parts are summed independently -- no
  segment is counted between parts.
  """
  def estimate_length(nil), do: nil

  def estimate_length(%Geo.LineString{coordinates: coords}) do
    case part_length_km(coords) do
      nil -> nil
      km -> max(km, 0.1)
    end
  end

  def estimate_length(%Geo.MultiLineString{coordinates: parts}) when is_list(parts) do
    lengths =
      parts
      |> Enum.map(&part_length_km/1)
      |> Enum.reject(&is_nil/1)

    case lengths do
      [] -> nil
      _ -> max(Enum.sum(lengths), 0.1)
    end
  end

  def estimate_length(_), do: nil

  # Length within a single part; nil when fewer than 2 valid points.
  defp part_length_km(coords) when is_list(coords) do
    points =
      coords
      |> Enum.map(fn
        {lon, lat} -> {lon, lat}
        {lon, lat, _z} -> {lon, lat}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    case points do
      [_, _ | _] ->
        points
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [{lon1, lat1}, {lon2, lat2}] -> haversine_km(lat1, lon1, lat2, lon2) end)
        |> Enum.sum()

      _ ->
        nil
    end
  end

  defp part_length_km(_), do: nil

  # Estimate line length from the coordinates of the from_bus and to_bus.
  # Falls back to a conservative 10.0 km default when coordinates are unavailable.
  defp estimate_length_from_buses(
         %Bus{coordinates: %Geo.Point{coordinates: {lon1, lat1}}},
         %Bus{coordinates: %Geo.Point{coordinates: {lon2, lat2}}}
       ) do
    dist = haversine_km(lat1, lon1, lat2, lon2)
    max(dist, 0.1)
  end

  defp estimate_length_from_buses(
         %{coordinates: %Geo.Point{coordinates: {lon1, lat1}}},
         %{coordinates: %Geo.Point{coordinates: {lon2, lat2}}}
       ) do
    dist = haversine_km(lat1, lon1, lat2, lon2)
    max(dist, 0.1)
  end

  defp estimate_length_from_buses(_, _), do: 10.0

  defp haversine_km(lat1, lon1, lat2, lon2) do
    r = 6371.0
    dlat = (lat2 - lat1) * :math.pi() / 180.0
    dlon = (lon2 - lon1) * :math.pi() / 180.0
    lat1_r = lat1 * :math.pi() / 180.0
    lat2_r = lat2 * :math.pi() / 180.0

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(lat1_r) * :math.cos(lat2_r) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    r * c
  end
end
