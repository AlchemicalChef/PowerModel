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
  - Synthesizes the bus shunt plant the network was missing entirely — EHV
    line-end reactors and substation capacitor banks (`synthesize_bus_shunts/1`)

  ## Which rows this pass owns

  Estimation is versioned (`params_version/0`, ROADMAP item 8): a row stamped
  below the current version is RECOMPUTED, not skipped. The previous
  "fill NULLs only" predicate meant a corrected parameter table could never
  reach a row that already had values, so improvements shipped in code never
  appeared in the network being simulated.

  Rows authored outside this estimator (`@externally_authored_sources`) are
  never touched. Those arrive with parameters from their own source — the
  SyntheticUSA MATPOWER component carries internally consistent impedances, the
  international ties carry hand-curated ones, and the `connectivity_repair`
  joints carry the measured joint distance `BusMapper` welded them at — and
  none has the geometry this estimator would need to re-derive them.
  Recomputing them would replace real data with a class-table guess against a
  default length.

  That exclusion is load-bearing, not cosmetic: the predicate below matches on
  `params_version < @params_version`, and 4,485 of the 10,113
  `connectivity_repair` rows still sit at version 0, so the predicate matches
  every one of them. Drop the source from the list and the next estimator run
  replaces those measured joint impedances with a class-table guess against a
  default length. (The other 5,628 have since been stamped at the current
  version and would survive on the version test alone — which is exactly why
  the list, not the version, is what this rests on.)

  What the exclusion is NOT protecting against any more is the write-time
  clamp. When this was first written the repair rows were the ones sitting
  below it; today none is — the smallest reactance among them is 1.2e-5 pu,
  above the 1.0e-5 clamp, so a recompute would not be *clamped*, it would
  simply be wrong about the length (REVIEW SOL-18).

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
  require Logger
  alias PowerModel.Repo
  alias PowerModel.Grid.{TransmissionLine, Generator, Bus, Load, Ratings}

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

  # Smallest reactance this estimator will WRITE. It must equal
  # `PowerModel.Solver.YBus.x_floor/0` — whichever of the two is larger is the
  # one the network actually feels, so a write-time clamp above the solver's
  # floor silently becomes the binding floor and no amount of lowering the
  # solver's does anything (SOL12-SCALE). At the old 1.0e-4 the clamp inflated
  # the reactance of every very short EHV jumper it wrote by up to 8x (line
  # 39444, 500 kV: recipe 1.2e-5, stored 1.0e-4).
  #
  # Not shared as a compile-time reference to YBus: ingestion should not
  # trigger a recompile of the whole solver tree. The two are pinned equal by
  # test/power_model/solver/branch_normalization_test.exs instead.
  @x_write_floor 1.0e-5

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

  # Low-voltage (sub-transmission) rating class, ROADMAP item 8 re-scope.
  #
  # The class table bottoms out at 69 kV and `lookup_line_params/1` picks the
  # CLOSEST class, so every line below it -- 1,957 in-service rows spanning
  # 3 to 49 kV -- inherited the 69 kV thermal rating. A 33 kV line therefore
  # read as good for 116 MVA, and a genuine 60 MW overload on it was invisible
  # to every overload screen in the simulator (ROADMAP8-NOOP).
  #
  # A rating is an ampacity, not a per-unit quantity: at a fixed conductor and
  # a fixed thermal limit, MVA = sqrt(3) x kV x I scales LINEARLY with voltage.
  # The 69 kV class's 130 MVA implies ~1,090 A, so the same construction is
  # good for 65 MVA at 34.5 kV and 26 MVA at 13.8 kV. Scaling as kV^2 (the
  # per-unit impedance base) would be the wrong physics.
  #
  # Only the RATING scales. Per-km ohms are a property of the construction,
  # not the voltage, so the impedance stays on the 69 kV class row and no
  # stored `x_pu` moves because of this: the large per-unit reactances these
  # lines carry come from the small z_base (kV^2/100) and are correct.
  @lv_rating_reference_kv 69.0

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
  #   3 = write-time reactance clamp aligned to the solver floor
  #       (@x_write_floor), sub-transmission ratings scaled by voltage
  #       (@lv_rating_reference_kv)
  #
  # Version 2 changes what rate A MEANS, so rows a version-1 estimator already
  # stamped have to be revisited — without the bump they would read as current
  # and keep an uncapped, underated rating forever, which is the exact failure
  # mode (REVIEW DAT-18) that versioning exists to prevent. Version 3 changes
  # both a written reactance and a written rating, so the same argument applies.
  @params_version 3

  # Sources whose parameters are authored somewhere other than this estimator.
  # See the moduledoc.
  #
  # `connectivity_repair` is on this list for a reason worth keeping: those
  # rows are written by `Ingestion.BusMapper` with the real (very short) joint
  # distance, and 4,485 of the 10,113 are still stamped params_version 0, so
  # the recompute predicate below matches every one of them. Without the
  # exclusion a single estimator run would silently replace those measured
  # impedances with a class-table guess against a default length.
  @externally_authored_sources ~w(matpower international connectivity_repair)

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
    # After the line pass: the reactors are sized from the b_pu it just wrote.
    # Capacitor banks are sized from the loads table, which on a fresh ingest is
    # still empty here — `synthesize_bus_shunts/1` recomputes BOTH components
    # from scratch every time, so the later pipeline stage that runs after
    # `estimate_loads` fills them in without disturbing the reactors.
    synthesize_bus_shunts()
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
            (is_nil(tl.source) or tl.source not in @externally_authored_sources),
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
      x_pu: max(x_per_km * length_km / (z_base * n_circuits), @x_write_floor),
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

  Below #{trunc(@lv_rating_reference_kv)} kV the class thermal rating is scaled
  linearly by voltage (`low_voltage_thermal_mva/2`) so sub-transmission stops
  inheriting the 69 kV class's ampacity-times-69-kV rating.
  """
  def rating_a_mva(voltage_kv, length_km, ambient_temp \\ @default_ambient_temp_c) do
    {_r, _x, _b, thermal_mva, _circuits} = lookup_line_params(voltage_kv)

    thermal =
      low_voltage_thermal_mva(thermal_mva, voltage_kv) * ambient_rating_derate(ambient_temp)

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
  The class thermal rating scaled down for a sub-transmission voltage.

  Constant-ampacity scaling: `thermal x kV / #{trunc(@lv_rating_reference_kv)}`
  below the lowest class in the table, and the class value unchanged at or
  above it. See `@lv_rating_reference_kv` for why this is linear and why it
  touches only the rating.
  """
  def low_voltage_thermal_mva(thermal_mva, voltage_kv)
      when is_number(voltage_kv) and voltage_kv > 0.0 and voltage_kv < @lv_rating_reference_kv,
      do: thermal_mva * voltage_kv / @lv_rating_reference_kv

  def low_voltage_thermal_mva(thermal_mva, _voltage_kv), do: thermal_mva

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

  # ---------------------------------------------------------------------------
  # Line-end shunt reactors (LIN13-C)
  # ---------------------------------------------------------------------------

  # Reactors are synthesized at or above this voltage. Below it, line charging
  # is small enough that utilities compensate at the substation (if at all),
  # not with dedicated line-end reactors.
  @reactor_min_kv 230.0

  # Fraction of a line's total charging absorbed by its two end reactors, by
  # voltage class (closest class wins, as everywhere else here). WECC EHV
  # practice is roughly half to two thirds of charging on 500 kV, tapering off
  # toward 230 kV where compensation is the exception rather than the rule.
  @reactor_compensation %{
    230 => 0.4,
    345 => 0.5,
    500 => 0.6,
    765 => 0.6
  }

  # Cases that ship their own shunt data. Synthesizing on top of them would
  # double-count. `international` and `connectivity_repair` rows are excluded
  # by the `b_pu > 0` predicate already (NULL and 0.0 respectively), so this
  # list only has to name the imported cases.
  @reactor_excluded_sources ~w(matpower)

  @doc """
  Reactor MVAr for ONE terminal of a line, given its voltage and total
  charging susceptance in per unit.

  Negative by construction (a reactor absorbs). `b_pu x 100` is the line's
  total charging at 1.0 pu and half of it sits at each end, so `-K/2 x b_pu x
  100` absorbs the fraction `K` of what this terminal injects.
  """
  def line_end_reactor_mvar(voltage_kv, b_pu, compensation \\ @reactor_compensation)

  def line_end_reactor_mvar(voltage_kv, b_pu, compensation) when is_number(b_pu) do
    -terminal_compensation(voltage_kv, compensation) / 2.0 * b_pu * @base_mva
  end

  def line_end_reactor_mvar(_voltage_kv, _b_pu, _compensation), do: 0.0

  @doc """
  Compensation fraction `K` for a voltage, from the closest class in the
  reactor table.
  """
  def terminal_compensation(voltage_kv, compensation \\ @reactor_compensation)

  def terminal_compensation(voltage_kv, compensation) when is_number(voltage_kv) do
    closest = compensation |> Map.keys() |> Enum.min_by(&abs(&1 - voltage_kv))
    Map.fetch!(compensation, closest)
  end

  def terminal_compensation(_, _), do: 0.0

  @doc "Default per-class reactor compensation fractions."
  def reactor_compensation, do: @reactor_compensation

  @doc """
  Per-bus line-end reactor MVAr, as a `%{bus_id => negative mvar}` map.

  Pure computation — the write lives in `synthesize_bus_shunts/1`, because
  reactors and capacitor banks share one column and neither may be written
  without the other (see that function's OWNERSHIP note).
  """
  def line_end_reactor_targets(opts \\ []) do
    compensation = Keyword.get(opts, :compensation, @reactor_compensation)

    lines =
      from(tl in TransmissionLine,
        where:
          tl.status == "in_service" and tl.voltage_kv >= @reactor_min_kv and
            not is_nil(tl.b_pu) and tl.b_pu > 0.0 and
            not is_nil(tl.from_bus_id) and not is_nil(tl.to_bus_id) and
            (is_nil(tl.line_type) or tl.line_type != "dc") and
            (is_nil(tl.source) or tl.source not in @reactor_excluded_sources),
        # Deterministic order: the per-bus value is a float SUM, and float
        # addition is not associative, so an unordered scan can land on a
        # different last bit run to run and defeat the idempotency check in
        # `write_bus_shunts/2` (`IS DISTINCT FROM`).
        order_by: [asc: tl.id],
        select: {tl.voltage_kv, tl.b_pu, tl.from_bus_id, tl.to_bus_id}
      )
      |> Repo.all()

    per_bus =
      Enum.reduce(lines, %{}, fn {voltage_kv, b_pu, from_id, to_id}, acc ->
        mvar = line_end_reactor_mvar(voltage_kv, b_pu, compensation)

        acc
        |> Map.update(from_id, mvar, &(&1 + mvar))
        |> Map.update(to_id, mvar, &(&1 + mvar))
      end)

    {per_bus, length(lines)}
  end

  # ---------------------------------------------------------------------------
  # Shunt capacitor banks (VC-COMP)
  # ---------------------------------------------------------------------------

  # Fraction of a bus's own load Q supplied by a synthesized LOAD-BUS capacitor
  # bank. The rule is 1.00 — compensate the transmission-to-distribution
  # interface to unity power factor, which is what distribution and transmission
  # banks do in practice. **The shipped value is 0.0, i.e. this component is
  # off, and the measurement below is why.**
  #
  # `bs_mvar` is a FIXED shunt. A real substation installation is SWITCHED: a
  # small permanently-connected block plus steps that are out of service at
  # light load. Modelling a load-sized installation as permanently connected
  # puts peak-load compensation on a network the simulator only ever solves at a
  # fraction of peak, and the result is not marginal.
  #
  # MEASURED 2026-08-18, one snapshot per island, FDPF, alpha bisected to 0.01,
  # capacitors applied on top of the same reactor set (control = reactors only):
  #
  #   island   control   + load banks @ peak   + load banks @ MINIMUM load
  #   Western   0.175    no solution at 0.05   no solution at 0.10
  #                      (Vm to 1.5 pu,         (126 buses > 1.1 pu)
  #                       343 buses > 1.1 pu)
  #   ERCOT     0.5938   no solution at 0.10   0.6375, but 113 buses > 1.1 pu
  #                      (2,094 buses > 1.1)    at alpha 0.45
  #
  # Minimum-load sizing is the smallest defensible fixed block (it is how the
  # permanently-connected portion of a switched installation is sized), and it
  # still fails on Western and buys ERCOT nothing over the generator-support
  # banks alone (0.6375 either way) while degrading its voltage profile.
  #
  # The physical reason is in the reactive balance, not in the arithmetic:
  # Western already runs a reactive SURPLUS at every operating point where a
  # solution exists — 44.5 GVAr of line charging against 27.2 GVAr of load Q at
  # the reference hour, with its generators NET-ABSORBING 14.6 GVAr at the
  # ceiling. Adding capacitors to a system that is absorbing is backwards; that
  # is what the line-end REACTOR pass is for.
  #
  # The vc-diagnose `caps100` lever that showed +19% on Western is not this: it
  # sized banks against the ALREADY-alpha-scaled load, so at the ceiling it
  # placed ~6 GVAr where a fixed peak-sized bank places ~51 GVAr. A lever that
  # tracks load is a switched bank, and no `bs_mvar` value reproduces it.
  #
  # Interface compensation that DOES scale with load belongs in the loads'
  # power factor (`Ingestion.LoadEstimator`), where distribution capacitors
  # physically sit — behind the load bus. Set this to 1.0 to reproduce the
  # measurement above.
  @load_compensation 0.0

  # WHICH load Q the 100% is a fraction OF.
  #
  # `loads.q_mvar` as stored is a per-BA ALLOCATION BASIS, not an operating
  # point: every snapshot passes it through `Demand.scale_loads/3`, which
  # multiplies it by `demand_mw(ba, hour) / (summed stored p_mw of that BA)`.
  # MEASURED 2026-08-18 at `Demand.latest_demand_hour/0`: that factor is 0.352
  # on Western, 0.379 on Eastern, 0.509 on ERCOT — and across all 4,420 ingested
  # EIA-930 hours national demand spans 0.12x to 1.73x that hour, so the stored
  # baseline is never reached at any hour in the record. Sizing a bank at 100%
  # of it would over-compensate its bus at EVERY hour the simulator can be run
  # at, by ~2.6x at the reference hour.
  #
  # So the bank is sized to the load Q at the BA's PEAK ingested demand hour,
  # which is the operating point a planner compensates:
  #
  #     bank = q_mvar_stored x max_over_hours(demand_mw(ba, h)) / baseline_mw(ba)
  #
  # exactly the scaler's own factor evaluated at the peak hour instead of the
  # simulated one. At any lighter hour the bank over-supplies and at the peak it
  # lands on unity, which is what fixed plant does.
  #
  # Clamped to the same sanity range `Demand` applies to its own factors, so a
  # BA whose demand rows disagree with its geolocated baseline cannot produce an
  # absurd bank. A BA with no demand data falls back to 1.0 — the stored
  # baseline is then the best available estimate of its peak.
  @peak_factor_range {0.05, 2.0}
  @default_peak_factor 1.0

  # A capacitor bank is a discrete piece of plant. North American shunt banks
  # are built from ~1.2 MVAr capacitor groups, so nothing smaller than one group
  # is installed; a bus wanting less than this gets no bank rather than a
  # fictitious fractional one. This also keeps the pass from writing tens of
  # thousands of rows whose physical effect rounds to nothing.
  @min_bank_mvar 1.2

  # Plausibility ceiling on the TOTAL synthesized shunt capacitance at one bus,
  # by voltage class (closest class wins, as everywhere else in this module).
  #
  # The model carries one bus per (substation, voltage level), so the value
  # below is a whole station's capacitor installation, not a single bank. It is
  # (largest bank normally built at that class) x (number of switching steps a
  # station normally carries), rounded:
  #
  #   class      max bank    steps   ceiling
  #   <=34.5 kV   3.6 MVAr     ~6      25
  #   69 kV        25 MVAr      4     100
  #   115-161 kV   60 MVAr      4     250
  #   230 kV      150 MVAr      3     450
  #   345 kV      250 MVAr      3     750
  #   >=500 kV    300 MVAr      3     900
  #
  # Bank ratings and the multi-step construction follow IEEE Std 1036, "IEEE
  # Guide for the Application of Shunt Power Capacitors": a station splits its
  # compensation into steps because each energization step has to satisfy the
  # ~2-3% bus voltage-step criterion (dV/V ~ Q_step / S_sc), so a single
  # 500 MVAr block at a 69 kV yard is not a thing that gets built.
  #
  # This is a GUARD, not a sizing rule. It exists so that a load-allocation
  # outlier — the 208.7 MW sitting on one 69 kV bus in Mesa AZ, the 405.4 MW on
  # a 130.5 kV bus near Madison GA — cannot turn into a capacitor bank nobody
  # would ever build.
  @cap_class_ceiling_mvar %{
    34.5 => 25.0,
    69.0 => 100.0,
    115.0 => 250.0,
    138.0 => 250.0,
    161.0 => 250.0,
    230.0 => 450.0,
    345.0 => 750.0,
    500.0 => 900.0,
    765.0 => 900.0
  }

  # Generator-support banks are a PLANNING STUDY RESULT, not a rule the
  # ingestion can evaluate: which generator buses run out of vars is a property
  # of the solved network, so it takes a power flow to find them. The study is
  # therefore carried as data, keyed on `(source, source_id)` — stable across a
  # re-ingest in a way row ids are not — and the file records the operating
  # point it was measured at. See `generator_support_targets/1`.
  @generator_support_study "reactive_support_banks.json"

  @doc """
  Per-bus capacitor bank MVAr, as a `%{bus_id => positive mvar}` map.

  Two components, summed per bus and then held to the per-class ceiling:

    * **generator-support banks** — substation compensation at the generator
      buses a power flow shows running out of reactive production
      (`generator_support_targets/2`). This is the component that ships on.
    * **load-bus banks** — `@load_compensation` x the bus's own in-service load
      Q at its balancing authority's peak ingested demand hour
      (`ba_peak_factors/0`). OFF by default: a fixed shunt cannot represent a
      switched installation, and installing one anyway measurably destroys the
      solve. The measurement is on `@load_compensation`; read it before turning
      this on.

  SIZING BASIS: `loads.q_mvar` as stored is an allocation basis, not an
  operating point — see `@peak_factor_range` for the measurement. A load-bus
  bank is sized to that column times the BA's peak-hour scale factor, so it
  would land on unity power factor at system peak and over-supply at lighter
  hours. The bank does not follow load hour by hour, exactly as real plant
  does not.

  A capacitor's output falls as V^2, so this compensation FADES as the bus sags
  — which is the real voltage-collapse mechanism and the reason banks are
  modelled here rather than by lowering the loads' power factor.

  Options:
  - `:load_compensation` — fraction of load Q to compensate (default #{@load_compensation})
  - `:peak_factors` — `%{ba_id => factor}` overriding `ba_peak_factors/0`
  - `:generator_support` — `%{bus_id => mvar}`, or `false` to skip the study
  """
  def capacitor_bank_targets(opts \\ []) do
    frac = Keyword.get(opts, :load_compensation, @load_compensation)

    load_q =
      if frac == 0.0 do
        # Load-bus banks are off (the shipped default — see @load_compensation).
        # Skipping the scan rather than computing a map of zeros: every value
        # would be 0.0 and every one would then be dropped, and the two full
        # table scans behind it are not free at 71k load buses.
        %{}
      else
        peak = Keyword.get_lazy(opts, :peak_factors, &ba_peak_factors/0)

        from(l in Load,
          join: b in Bus,
          on: l.bus_id == b.id,
          where: l.status == "in_service" and not is_nil(l.q_mvar) and l.q_mvar > 0.0,
          group_by: [l.bus_id, b.balancing_authority_id],
          select: {l.bus_id, b.balancing_authority_id, sum(l.q_mvar)}
        )
        |> Repo.all()
        |> Map.new(fn {bus_id, ba_id, q} ->
          {bus_id, frac * Map.get(peak, ba_id, @default_peak_factor) * q}
        end)
      end

    support =
      case Keyword.get(opts, :generator_support, :study) do
        :study -> generator_support_targets(load_q, opts)
        false -> %{}
        map when is_map(map) -> map
      end

    raw = Map.merge(load_q, support, fn _id, a, b -> a + b end)

    # The ceiling is a per-BUS plausibility limit, so it is applied to the sum
    # of both components, not to each one separately.
    # `= ANY($1)` rather than `in ^ids`: this list runs to tens of thousands of
    # buses and an expanded IN clause would exceed the 65,535 bind-parameter
    # limit outright.
    kv_by_bus =
      from(b in Bus,
        where:
          fragment("? = ANY(?)", b.id, ^Map.keys(raw)) and
            (is_nil(b.source) or b.source not in @reactor_excluded_sources),
        select: {b.id, b.base_kv}
      )
      |> Repo.all()
      |> Map.new()

    per_bus =
      kv_by_bus
      |> Enum.reduce(%{}, fn {bus_id, base_kv}, acc ->
        mvar = bank_target_mvar(Map.fetch!(raw, bus_id), base_kv)
        if mvar > 0.0, do: Map.put(acc, bus_id, mvar), else: acc
      end)

    {per_bus, map_size(load_q), map_size(support)}
  end

  @doc """
  Peak-hour load scale factor per balancing authority, `%{ba_id => factor}`.

  This is `Demand`'s own scale factor — `demand_mw(ba, hour) / baseline_mw(ba)`
  — evaluated at the BA's HIGHEST ingested demand hour instead of a simulated
  one, so a bank sized against it compensates its bus to unity at system peak.
  `baseline_mw` is the summed stored `p_mw` of that BA's geolocated in-service
  non-datacenter loads, matching `Demand.universe_baselines/1`; datacenters are
  excluded from the denominator there because they run flat and are not shaped
  by the hourly curve.

  Clamped to #{inspect(@peak_factor_range)}. BAs absent from the result fall
  back to `#{@default_peak_factor}`.
  """
  def ba_peak_factors do
    {lo, hi} = @peak_factor_range

    baselines =
      from(l in Load,
        join: b in Bus,
        on: l.bus_id == b.id,
        where:
          l.status == "in_service" and not is_nil(b.coordinates) and
            not is_nil(b.balancing_authority_id) and
            (is_nil(l.load_type) or l.load_type != "datacenter"),
        group_by: b.balancing_authority_id,
        select: {b.balancing_authority_id, sum(l.p_mw)}
      )
      |> Repo.all()
      |> Map.new(fn {ba_id, mw} -> {ba_id, (mw || 0.0) * 1.0} end)

    from(d in "ba_demand_hourly",
      where: not is_nil(d.demand_mw),
      group_by: d.balancing_authority_id,
      select: {d.balancing_authority_id, max(d.demand_mw)}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {ba_id, peak_mw} ->
      case Map.get(baselines, ba_id) do
        base when is_number(base) and base > 0.0 ->
          [{ba_id, peak_mw |> Kernel./(base) |> min(hi) |> max(lo)}]

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  @doc """
  The bank actually installed for a raw requirement of `raw_mvar` at a bus of
  `base_kv`: nothing below one standard capacitor group
  (#{@min_bank_mvar} MVAr), and never more than the class ceiling.
  """
  def bank_target_mvar(raw_mvar, base_kv) when is_number(raw_mvar) do
    cond do
      raw_mvar < @min_bank_mvar -> 0.0
      true -> min(raw_mvar, cap_class_ceiling(base_kv))
    end
  end

  def bank_target_mvar(_raw_mvar, _base_kv), do: 0.0

  @doc """
  Largest total shunt capacitance this pass will place at one bus of the given
  voltage, from the closest class in `@cap_class_ceiling_mvar`.
  """
  def cap_class_ceiling(base_kv) when is_number(base_kv) and base_kv > 0.0 do
    closest = @cap_class_ceiling_mvar |> Map.keys() |> Enum.min_by(&abs(&1 - base_kv))
    Map.fetch!(@cap_class_ceiling_mvar, closest)
  end

  # No usable voltage means no class, and therefore no defensible ceiling. The
  # lowest one is the conservative choice.
  def cap_class_ceiling(_), do: @cap_class_ceiling_mvar |> Map.values() |> Enum.min()

  @doc "Per-class capacitor bank ceilings, for tests and reporting."
  def cap_class_ceilings, do: @cap_class_ceiling_mvar

  @doc "Path of the generator reactive support study this pass reads by default."
  def generator_support_study_path do
    Application.app_dir(:power_model, ["priv", "reactive_planning", @generator_support_study])
  end

  @doc """
  Generator-support bank MVAr by bus id, read from the reactive planning study.

  WHY THIS IS DATA AND NOT A RULE: 22% of Western's generator buses, 41% of
  ERCOT's and 35% of Eastern's sit pinned at `q_max` at their island's AC
  loadability ceiling, while every one of those islands is a reactive SURPLUS
  in aggregate (Western's machines net-ABSORB 14.6 GVAr at the same instant).
  The deficit is local and the surplus is global, so no aggregate quantity
  identifies the buses — only a power flow does. Inflating unit `q_max` would
  "fix" it by giving machines capability they do not have; the physical answer
  is substation compensation next to the machines that are pinned.

  SIZING RULE: each bus's bank is the part of its measured reactive shortfall
  that the load-bus bank at the same substation does not already deliver,

      support = max(0, shortfall - load_bus_bank x Vm^2)

  The `Vm^2` is there because that is what a capacitor rated at 1.0 pu actually
  produces at the bus voltage the study measured, so both terms are quantities
  at the same operating point. The subtraction is what keeps this from
  double-compensating: measured 2026-08-18, the load-bus banks alone already
  deliver 290% of the pinned-bus shortfall on Western and 146% on Eastern, so
  the residual is 14% and 33% of the raw shortfall there. Only ERCOT — where
  48% of pinned generator buses serve no load at all — carries a large residual
  (81%).

  The shortfall itself is `q_free - q_max`: the reactive output the same bus
  produces when its limit is lifted (the `qmax10` lever), minus what it is
  allowed. It is not a multiple of `q_max`; a bus whose machines are pinned but
  which the network does not actually want more vars from gets no bank.

  The study file stores only the two MEASURED quantities, `shortfall_mvar` and
  `vm_pu`. The subtraction happens here against `load_banks`, the load-bus bank
  map this same run computed — so a later reallocation of load changes the
  support bank without anyone having to re-run the power flow that found the
  bus. With load-bus banks off (the shipped default) `load_banks` is empty and
  the support bank is the whole measured shortfall, which is the self-consistent
  pairing: nothing else is supplying those vars.

  MEASURED effect of this component alone (2026-08-18, control = reactors only,
  same snapshot, alpha bisected to 0.01): Western 0.175 -> 0.20 (+14.3%),
  ERCOT 0.5938 -> 0.6375 (+7.4%). 13.1 GVAr placed across 2,061 buses.

  Returns `%{}` when the study file is absent, so a checkout without it still
  ingests.
  """
  def generator_support_targets(load_banks \\ %{}, opts \\ []) do
    path = Keyword.get(opts, :study_path, generator_support_study_path())

    with {:ok, body} <- File.read(path),
         {:ok, %{"banks" => banks} = study} <- Jason.decode(body) do
      warn_stale(study, path)
      keys = Enum.map(banks, &{&1["source"], &1["source_id"]})
      sources = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      source_ids = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

      # The unique constraint is on the PAIR, so filtering on each half
      # separately can over-select; the exact pair lookup is the Map.get below.
      id_by_key =
        from(b in Bus,
          where: b.source in ^sources and b.source_id in ^source_ids,
          select: {{b.source, b.source_id}, b.id}
        )
        |> Repo.all()
        |> Map.new()

      {targets, unresolved} =
        Enum.reduce(banks, {%{}, []}, fn bank, {acc, missing} ->
          case Map.get(id_by_key, {bank["source"], bank["source_id"]}) do
            nil ->
              {acc, [bank["source_id"] | missing]}

            id ->
              vm = bank["vm_pu"] || 1.0
              delivered = Map.get(load_banks, id, 0.0) * vm * vm
              residual = max((bank["shortfall_mvar"] || 0.0) - delivered, 0.0)

              acc =
                if residual > 0.0,
                  do: Map.update(acc, id, residual, &(&1 + residual)),
                  else: acc

              {acc, missing}
          end
        end)

      warn_unresolved(unresolved, length(banks))
      targets
    else
      _ -> %{}
    end
  end

  # A study entry whose bus no longer exists is DROPPED, and dropping it
  # silently is the defect this guards.
  #
  # The key is `(source, source_id)`, chosen because it survives a re-ingest
  # where row ids do not. It does NOT survive a VOLTAGE correction: `BusMapper`
  # writes `source_id` as "<substation id>_<kv>kV", so restamping a yard renames
  # its bus. MEASURED 2026-08-19, after the OSM voltage backfill: 60 of 1,627
  # entries stopped resolving, every one of them a `..._138.0kV` id — the blind-
  # yard default that the backfill exists to correct, moved to 60/69/230 kV.
  #
  # Deliberately NOT repaired by fuzzy-matching the substation prefix: a yard
  # has buses at several voltages, so a near-match would attach a measured
  # shortfall to the wrong one, and a bank on the wrong bus is worse than no
  # bank. The right response is to re-derive the study after any change to
  # voltage data, which is what the warning tells the operator to do.
  # The study is measured against a solved network, so it is only valid for the
  # network it was measured on. The 2026-08-19 study was applied to a network
  # the OSM voltage backfill had restamped underneath it, and the only reason
  # anyone noticed was that 60 bank keys stopped resolving — a symptom that
  # happens to be loud, and that would have been SILENT had the ids survived a
  # change to impedance or dispatch. `Grid.network_signature/0` closes that
  # gap: it moves whenever any table a power flow reads moves.
  #
  # This warns rather than raises because the estimator runs inside the ingest
  # pipeline, where a hard stop on a slightly-stale study would be worse than
  # slightly-stale banks. The hard gate lives in `Ingestion.Validation`, which
  # is what CI runs.
  defp warn_stale(study, path) do
    case PowerModel.Grid.network_signature_drift(study["inputs"]) do
      [] ->
        :ok

      [:unstamped] ->
        Logger.warning(
          "reactive support study #{Path.basename(path)} carries no `inputs` signature, so " <>
            "whether it matches this network is UNKNOWN -- not the same as fresh. " <>
            "Re-derive with `mix power_model.reactive_study`."
        )

      drift ->
        Logger.warning(
          "reactive support study #{Path.basename(path)} was measured against a DIFFERENT " <>
            "network than the one it is being applied to; its shortfalls are not this " <>
            "network's. Re-derive with `mix power_model.reactive_study`. Drift: " <>
            Enum.join(Enum.take(drift, 5), "; ")
        )
    end
  end

  defp warn_unresolved([], _total), do: :ok

  defp warn_unresolved(missing, total) do
    Logger.warning(
      "reactive support study: #{length(missing)} of #{total} banks did not resolve to a bus " <>
        "and were dropped. `source_id` embeds the bus voltage, so a voltage restamp renames it " <>
        "-- re-derive the study against the current network. Examples: " <>
        (missing |> Enum.take(5) |> Enum.join(", "))
    )
  end

  @doc """
  Synthesize both bus shunt components and write their NET to `buses.bs_mvar`.

  OWNERSHIP: `bs_mvar` is one column carrying two synthesized devices — the
  EHV line-end reactors (negative) and the substation capacitor banks
  (positive). Neither pass may write it alone. 3,798 load-serving buses also
  terminate an EHV line (measured 2026-08-18: 34.8 GVAr of load Q and
  -21.8 GVAr of reactor sit on the same rows), so a reactor pass that wrote its
  own absolute value would erase the capacitor at every one of them, and vice
  versa. The reactor pass therefore owns the negative COMPONENT, the capacitor
  pass owns the positive COMPONENT, and this function recomputes both from
  scratch and stores their sum.

  Full recompute, never `+=`, so the pass is idempotent: running it twice — or
  running it at a point in the pipeline where the loads table is still empty
  and again after it is filled — converges on the same stored value, and a bus
  that no longer qualifies for either device is cleared.

  Externally authored shunts are protected by source (`@reactor_excluded_sources`),
  including in the stale-device cleanup. If measured shunt data is ever
  ingested from elsewhere, add its source to that list rather than letting this
  pass overwrite it.

  Options are passed through to `line_end_reactor_targets/1` and
  `capacitor_bank_targets/1`.
  """
  def synthesize_bus_shunts(opts \\ []) do
    {reactors, line_count} = line_end_reactor_targets(opts)
    {caps, load_buses, support_buses} = capacitor_bank_targets(opts)

    excluded_buses =
      from(b in Bus, where: b.source in @reactor_excluded_sources, select: b.id)
      |> Repo.all()
      |> MapSet.new()

    net =
      reactors
      |> Map.merge(caps, fn _id, r, c -> r + c end)
      |> Map.reject(fn {bus_id, _} -> MapSet.member?(excluded_buses, bus_id) end)
      # Round to 0.1 kVAr. Physically meaningless precision, but it makes the
      # written value reproducible bit-for-bit across runs, which is what the
      # `IS DISTINCT FROM` idempotency guard below rests on.
      |> Map.new(fn {bus_id, mvar} -> {bus_id, Float.round(mvar, 4)} end)

    {bus_ids, mvars} = Enum.unzip(Map.to_list(net))

    summary = %{
      lines: line_count,
      reactor_buses: map_size(reactors),
      cap_buses: map_size(caps),
      load_banks: load_buses,
      support_banks: support_buses,
      buses: map_size(net),
      reactor_mvar: reactors |> Map.values() |> Enum.sum(),
      cap_mvar: caps |> Map.values() |> Enum.sum(),
      mvar: Enum.sum(mvars)
    }

    if bus_ids == [] do
      # Nothing qualifies for either device (an empty database, or one with no
      # EHV lines and no loads). Returning early rather than running the
      # statements below matters: the stale-device cleanup is "every
      # synthesized shunt NOT in this set", which with an empty set would clear
      # every shunt in the table.
      Map.merge(summary, %{written: 0, cleared: 0})
    else
      Map.merge(summary, write_bus_shunts(bus_ids, mvars))
    end
  end

  defp write_bus_shunts(bus_ids, mvars) do
    # One statement, not one per bus: this touches thousands of rows and the
    # per-row changeset path made the pass the slowest thing in the ingest.
    %{num_rows: written} =
      Repo.query!(
        """
        UPDATE buses AS b SET bs_mvar = v.bs, updated_at = now()
        FROM (SELECT unnest($1::bigint[]) AS id, unnest($2::float8[]) AS bs) AS v
        WHERE b.id = v.id AND b.bs_mvar IS DISTINCT FROM v.bs
        """,
        [bus_ids, mvars]
      )

    # Buses carrying a synthesized shunt that no longer qualifies for one —
    # otherwise a re-ingest that drops a line, or a reallocation that moves a
    # load off a bus, leaves the device behind forever. Both signs, because
    # both signs are synthesized here; externally authored shunts are held out
    # by source.
    %{num_rows: cleared} =
      Repo.query!(
        """
        UPDATE buses SET bs_mvar = 0.0, updated_at = now()
        WHERE bs_mvar <> 0.0
          AND NOT (id = ANY($1::bigint[]))
          AND (source IS NULL OR NOT (source = ANY($2::text[])))
        """,
        [bus_ids, @reactor_excluded_sources]
      )

    %{written: written, cleared: cleared}
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
