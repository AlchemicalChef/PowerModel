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

  Rows authored outside this estimator (`@externally_authored_sources`) are
  never touched. Those arrive with parameters from their own source — the
  SyntheticUSA MATPOWER component carries internally consistent impedances, the
  international ties carry hand-curated ones, and the `connectivity_repair`
  joints carry the measured joint distance `BusMapper` welded them at — and
  none has the geometry this estimator would need to re-derive them.
  Recomputing them would replace real data with a class-table guess against a
  default length.

  That exclusion is load-bearing, not cosmetic: the predicate below matches on
  `params_version < @params_version`, and every one of the 5,628
  `connectivity_repair` rows sits at version 0. Drop the source from the list
  and the next estimator run overwrites all of them.

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
  # distance, which puts 5,628 of them below this estimator's own write-time
  # clamp (smallest 2.5e-5 pu). They are stamped params_version 0, so before
  # they were listed here the recompute predicate below matched every one of
  # them and a single estimator run would have silently replaced every repaired
  # impedance with a class-table guess.
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
    synthesize_line_end_reactors()
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
  Synthesize line-end shunt reactors on EHV buses and write them to
  `buses.bs_mvar`.

  Every in-service AC line at or above #{trunc(@reactor_min_kv)} kV gets a
  reactor at each terminal absorbing `K` of the charging that terminal injects:

      bs_mvar(bus) = sum over EHV lines at that bus of  -K/2 x b_pu x 100

  `b_pu x 100` is the line's total charging in MVAr at 1.0 pu, half of it at
  each end in the pi model, so `-K/2 x b_pu x 100` per terminal absorbs exactly
  the fraction `K` of it.

  WHY THIS EXISTS: the network models line charging correctly (per-km values
  match published typicals to three digits) but modeled ZERO compensation
  anywhere — `bs_mvar` was 0.0 on all 89,969 buses. Western alone injects
  44.3 GVAr of charging into a network whose only reactive sinks are generator
  `q_min`, which is why its light-load AC solutions push thousands of buses
  above 1.1 pu (LIN13-C). Real EHV systems absorb roughly half their charging
  in line-end reactors; this pass supplies the missing half.

  OWNERSHIP: this pass owns NEGATIVE `bs_mvar`. It writes the full computed
  value (it does not accumulate), so re-running it — or running it with a
  different `K` — converges on the same answer, and a bus that no longer
  terminates an EHV line has its synthesized reactor cleared. Capacitor banks
  (`bs_mvar > 0`) are never touched. If measured reactor data is ever ingested,
  gate this pass rather than letting it overwrite.

  Options:
  - `:compensation` — `%{class_kv => K}` map overriding `@reactor_compensation`

  Returns a summary map.
  """
  def synthesize_line_end_reactors(opts \\ []) do
    compensation = Keyword.get(opts, :compensation, @reactor_compensation)

    lines =
      from(tl in TransmissionLine,
        where:
          tl.status == "in_service" and tl.voltage_kv >= @reactor_min_kv and
            not is_nil(tl.b_pu) and tl.b_pu > 0.0 and
            not is_nil(tl.from_bus_id) and not is_nil(tl.to_bus_id) and
            (is_nil(tl.line_type) or tl.line_type != "dc") and
            (is_nil(tl.source) or tl.source not in @reactor_excluded_sources),
        select: {tl.voltage_kv, tl.b_pu, tl.from_bus_id, tl.to_bus_id}
      )
      |> Repo.all()

    excluded_buses =
      from(b in Bus, where: b.source in @reactor_excluded_sources, select: b.id)
      |> Repo.all()
      |> MapSet.new()

    per_bus =
      lines
      |> Enum.reduce(%{}, fn {voltage_kv, b_pu, from_id, to_id}, acc ->
        mvar = line_end_reactor_mvar(voltage_kv, b_pu, compensation)

        acc
        |> Map.update(from_id, mvar, &(&1 + mvar))
        |> Map.update(to_id, mvar, &(&1 + mvar))
      end)
      |> Map.reject(fn {bus_id, _} -> MapSet.member?(excluded_buses, bus_id) end)

    {bus_ids, mvars} = Enum.unzip(Map.to_list(per_bus))

    if bus_ids == [] do
      # No qualifying lines at all (an empty or non-EHV database). Returning
      # early rather than running the statements below matters: the stale-
      # reactor cleanup is "every reactor NOT in this set", which with an empty
      # set would clear every reactor in the table.
      %{lines: length(lines), buses: 0, written: 0, cleared: 0, mvar: 0.0}
    else
      write_reactors(lines, per_bus, bus_ids, mvars)
    end
  end

  defp write_reactors(lines, per_bus, bus_ids, mvars) do
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

    # Buses that carry a synthesized reactor but no longer terminate a
    # qualifying line — otherwise a re-ingest that drops or downgrades a line
    # leaves its reactor behind forever.
    %{num_rows: cleared} =
      Repo.query!(
        """
        UPDATE buses SET bs_mvar = 0.0, updated_at = now()
        WHERE bs_mvar < 0.0 AND NOT (id = ANY($1::bigint[]))
        """,
        [bus_ids]
      )

    %{
      lines: length(lines),
      buses: map_size(per_bus),
      written: written,
      cleared: cleared,
      mvar: Enum.sum(mvars)
    }
  end

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
