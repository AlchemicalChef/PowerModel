defmodule PowerModel.Controls.AGC do
  @moduledoc """
  Automatic Generation Control — closed-loop secondary frequency control
  (ROADMAP Phase 4, Wave 3).

  Primary response ARRESTS a frequency excursion; it does not end it. Governor
  droop is proportional control, so it settles at an offset — the island holds
  at 59.9-something Hz with its governors permanently deployed, its primary
  reserve spent, and no capacity left to arrest the next trip. Restoring the
  frequency to 60 Hz and RELEASING the governors back to zero is the job of
  secondary control, and secondary control is a closed loop: it keeps pushing
  until the error is gone, however long that takes and whatever the ramp.

  That is the difference between this module and the open-loop secondary tier
  in `PowerModel.Failure.Reserves`. The tier answers "how many MW could this
  fleet have ramped in the time available"; it delivers them whether or not
  the frequency needed them, and it stops when the arithmetic deficit is
  covered rather than when the frequency is back. AGC answers "how many MW
  does the AREA CONTROL ERROR still call for", which is a measurement of the
  island, not of the clock. When AGC is active it therefore REPLACES the
  clock-ramped secondary tier — see "Integration with Reserves" below, and
  `Reserves.allocate/4`.

  ## Area Control Error, and the sign convention

  NERC's definition (BAL-001, and the tie-line-bias control it standardises):

      ACE = (NI_actual - NI_scheduled) - 10 * B * (F_actual - F_scheduled)

  `B` is the area's **frequency bias setting in MW per 0.1 Hz, and it is
  NEGATIVE by convention** — a falling frequency must raise generation, and
  the standard carries that sign in `B` rather than in the formula. Carrying a
  negative constant through a codebase is a bug farm, so this module stores
  the bias as a positive MAGNITUDE (`bias_mw_per_01hz`) and folds the
  convention's minus sign into the formula once, here:

      ACE = (NI_actual - NI_scheduled) + 10 * |B| * (f - 60.0)

  The two are identical. What matters is the resulting sign, which is the
  standard one:

    * **ACE < 0 — the area is UNDER-generating.** Frequency below 60 Hz,
      and/or exporting less (importing more) than scheduled. AGC raises
      setpoints.
    * **ACE > 0 — the area is OVER-generating.** AGC lowers setpoints.

  The control law is therefore `ΔP = -(Kp * ACE + Ki * ∫ACE dt)`: the minus
  sign appears exactly once more, and nowhere else.

  ### The interchange term in an islanded cascade

  Both terms are supported, but a cascade island that has just separated has
  no tie schedule — the schedules died with the ties — so in practice
  `telemetry` carries only a frequency and ACE reduces to `10 * |B| * Δf`.
  Pass `:net_interchange_mw` (and optionally `:scheduled_interchange_mw`)
  when a DC tie or an intact seam gives the island a real interchange to
  regulate against, and the full two-term ACE is computed.

  ## The bias setting B

  Classical tie-line bias control sets `B` equal to the area's own natural
  frequency response β (Cohn's non-interacting control): with `B = β`, an
  area's ACE responds to its OWN imbalance and stays at zero for a
  disturbance somewhere else in the interconnection. It also makes ACE
  directly readable — at the primary-response settling point,
  `10 * β * |Δf|` is exactly the MW the area is short, so `|ACE|` IS the
  deficit in megawatts, which is why the gains below are dimensionless
  fractions of it.

  `init/2` therefore derives `B` from the island's own composition, using the
  same machine constants the swing model integrates
  (`natural_response_mw_per_01hz/2`): every governor-duty unit's deliverable
  droop response at a 0.1 Hz reference deviation, plus the load-damping term.
  NERC BAL-005's floor — a bias no smaller than 1% of the area's peak demand
  per 0.1 Hz — is then applied. Pass `:bias_mw_per_01hz` to override.

  With no ties, `B` sets only the loop GAIN: the steady state requires
  `ACE = 0`, which requires `Δf = 0` for any positive `B`. A bias 30% off
  changes how fast the island gets back to 60 Hz, not whether it does.

  ## Gains, cycle, and the noise floor

  `Kp = 0.05` and `Ki = 0.02`/s, on a 4 s cycle. With `B ≈ β` the
  proportional term answers 5% of the outstanding deficit immediately and the
  integral adds ≈8% of it per cycle, giving a closed-loop time constant of
  roughly a minute and full recovery in single-digit minutes for a design
  contingency — the timescale NERC BAL-002 contingency-event recovery (15
  minutes) is written against, without pretending to a speed no fleet ramp
  could deliver.

  `step/3` accepts ANY `dt`: ACE is integrated continuously and setpoints are
  issued only on cycle boundaries. Because a PI law is a function of the
  accumulated integral rather than of per-cycle increments, a caller stepping
  in 30-second cascade segments gets the same command it would have got by
  stepping 4-second cycles up to that instant — only the ramp window differs,
  and that is measured from the last command, not from the cycle length.

  The **noise floor is a ±0.002 Hz deadband on the frequency term** (≈±8 MW
  of ACE on ERCOT), an order of magnitude tighter than the ±0.036 Hz governor
  deadband — deliberately so, because answering the excursions governors
  ignore is precisely secondary control's job. Inside the deadband the
  integrator is frozen and no setpoints are issued at all, so an undisturbed
  island at 60.000 Hz produces exactly zero deltas rather than dithering its
  dispatch.

  ## Anti-windup

  Every command is clamped twice — by each unit's ramp over the time since the
  last command, and by the reserve it has left — and the integrator is then
  BACK-CALCULATED to the command that was actually achievable. A controller
  whose integral outran the fleet would keep commanding into a saturated
  reserve and then overshoot violently when the reserve came back; with
  back-calculation the internal state never claims more than the plant did,
  ACE persists honestly while the reserve is exhausted, and recovery is
  monotone.

  ## Integration with Reserves (the no-double-count contract)

  `Reserves.allocate/4` takes `secondary: {:agc, deltas}`, where `deltas` is
  exactly the map `step/3` just returned. In that mode the secondary tier's
  per-unit capability is the MW AGC dispatched THIS step (still capped by the
  unit's physical headroom) instead of `ramp × elapsed`. The tertiary tier
  stays on the clock and the primary tier still rides on whatever the
  sustained tiers left, unchanged.

  The increments are what makes this safe. AGC issues a given megawatt once;
  the cascade adds it to the dispatch once; the next step's deficit is
  recomputed from that raised dispatch. Cumulative AGC output must NOT be fed
  to `allocate/4` — it would be re-credited every step against a deficit that
  already reflects it.

  ## State across island splits

  `apportion/2` splits a state along a new island boundary. Units follow their
  island, participation factors and the bias are recomputed from the surviving
  composition, and **the integrator is reset to zero** in every child. That is
  the physical answer, not a convenience: the integral is the accumulated
  error of an AREA, and a split creates areas that did not exist a moment ago.
  Real AGC on a newly formed island starts its integrator fresh — the
  megawatt-seconds of error accrued by the pre-split area are a statement
  about a system that no longer exists, and carrying them across would command
  a correction for an imbalance that left with the other half.

  What DOES survive is `dispatched_by_unit`: how much each retained unit has
  already been raised. That is a property of the machine, not of the area, and
  it is what bounds further raising (reserve) and any backing-down.

  ## State shape

      %AGC{
        order: [id],                     # stable participating-unit order
        units: %{id => %{...}},          # ramp, reserve, base point, β share
        participation: %{id => float},   # normalised, sums to 1.0
        bias_mw_per_01hz: float(),       # |B|, positive magnitude
        kp: float(), ki: float(),        # PI gains
        cycle_s: float(),                # AGC cycle (4 s)
        deadband_hz: float(),            # noise floor on the frequency term
        integral_mw_s: float(),          # ∫ACE dt, MW·s (back-calculated)
        ace_mw: float(),                 # last ACE computed
        since_cycle_s: float(),          # time accumulated toward the next cycle
        dispatched_by_unit: %{id => mw}, # cumulative MW above the base schedule
        dispatched_mw: float(),          # their sum
        island_load_mw: float(),
        scheduled_interchange_mw: float(),
        cycles: non_neg_integer(),
        saturated?: boolean()            # last command hit a ramp or reserve limit
      }

  ## What this module does NOT do

  It does not lower generation below the operating point it was initialised
  with. Down-regulation is bounded by what AGC itself has added, because the
  cascade's dispatch is measured-anchored (EIA-930 fuel totals) and rewriting
  it downward would replace a measurement with a control fiction — the same
  reason `Cascade` declines to curtail an island's surplus. An over-frequency
  island is therefore still handled by governor droop backing off, not by AGC.
  """

  alias PowerModel.Solver.Frequency

  # A conventional AGC execution cycle. Utility EMS installations run 2-6 s.
  @cycle_s 4.0

  # PI gains. Kp is dimensionless (MW of correction per MW of ACE); Ki is per
  # second. See the moduledoc for the timescale these produce.
  @kp 0.05
  @ki 0.02

  # Noise floor on the frequency term of ACE (Hz). See the moduledoc: much
  # tighter than the governor deadband, on purpose.
  @deadband_hz 0.002

  # NERC BAL-005: the frequency bias setting must be at least 1% of the
  # balancing authority's estimated yearly peak demand, per 0.1 Hz.
  @bias_floor_fraction 0.01

  # Reference deviation at which the natural response β is evaluated, matching
  # the units B is quoted in.
  @beta_reference_hz 0.1

  # Commands smaller than this are not worth writing into a dispatch map.
  @min_command_mw 0.05

  # Cycle-boundary comparison tolerance: `since` accumulates inexact floats.
  @cycle_epsilon 1.0e-9

  # Upper bound on redistribution passes when clipped units hand their
  # shortfall to the units that still have room.
  @max_passes 64

  defstruct order: [],
            units: %{},
            participation: %{},
            bias_mw_per_01hz: 0.0,
            kp: @kp,
            ki: @ki,
            cycle_s: @cycle_s,
            deadband_hz: @deadband_hz,
            integral_mw_s: 0.0,
            ace_mw: 0.0,
            since_cycle_s: 0.0,
            dispatched_by_unit: %{},
            dispatched_mw: 0.0,
            capacity_mw: 0.0,
            island_load_mw: 0.0,
            scheduled_interchange_mw: 0.0,
            cycles: 0,
            saturated?: false

  @type t :: %__MODULE__{}

  # ---------------------------------------------------------------------------
  # Initialisation
  # ---------------------------------------------------------------------------

  @doc """
  Build an AGC state for one island's fleet.

  `generators` are generator maps in the cascade's sustained shape — at least
  `:id`, `:fuel_type`, `:p_dispatch_mw` (the sustained operating point) and
  `:p_nameplate_mw` (the machine rating), the same convention
  `PowerModel.Failure.Reserves` reads.

  Participating units are the ones on governor duty
  (`Frequency.governor_duty?/1`), synchronised, and carrying headroom — which
  is exactly the fleet the ENE-19 contingency hold-back put reserve on. A unit
  at its cap is not on regulation, whatever its ramp; a unit that is not
  spinning is a tertiary resource, not an AGC one.

  Participation factors are proportional to each unit's available secondary
  ramp (`Frequency.secondary_ramp_mw_per_min/1`, or a `:ramp_rate_mw_per_min`
  carried on the generator map when real ramp data is present), normalised to
  sum to 1.0. A fleet with no ramp anywhere falls back to sharing by reserve.

  ## Options

    * `:load_mw` — the island's load, for the bias's load-damping term and the
      NERC 1%-of-peak floor. Defaults to 0.0, which simply drops both.
    * `:bias_mw_per_01hz` — override the derived bias, as a POSITIVE magnitude.
    * `:kp`, `:ki` — PI gains (defaults #{@kp} and #{@ki}/s).
    * `:cycle_s` — AGC cycle (default #{@cycle_s} s).
    * `:deadband_hz` — noise floor on the frequency term (default #{@deadband_hz}).
    * `:scheduled_interchange_mw` — the area's scheduled net interchange, used
      when telemetry carries an actual one. Defaults to 0.0.
  """
  @spec init(list(map()), keyword()) :: t()
  def init(generators, opts \\ []) do
    load_mw = (Keyword.get(opts, :load_mw) || 0.0) * 1.0

    units =
      generators
      |> Enum.filter(&participating?/1)
      |> Enum.map(&descriptor/1)

    order = Enum.map(units, & &1.id)
    unit_map = Map.new(units, &{&1.id, &1})

    %__MODULE__{
      order: order,
      units: unit_map,
      participation: participation_factors(order, unit_map),
      bias_mw_per_01hz:
        Keyword.get(opts, :bias_mw_per_01hz) || bias_from(unit_map, order, load_mw),
      kp: Keyword.get(opts, :kp, @kp),
      ki: Keyword.get(opts, :ki, @ki),
      cycle_s: Keyword.get(opts, :cycle_s, @cycle_s),
      deadband_hz: Keyword.get(opts, :deadband_hz, @deadband_hz),
      dispatched_by_unit: %{},
      dispatched_mw: 0.0,
      capacity_mw: units |> Enum.map(& &1.up_reserve_mw) |> Enum.sum(),
      island_load_mw: load_mw,
      scheduled_interchange_mw: (Keyword.get(opts, :scheduled_interchange_mw) || 0.0) * 1.0
    }
  end

  @doc """
  Whether a generator map is eligible for AGC regulation: on governor duty,
  synchronised, and carrying headroom.
  """
  @spec participating?(map()) :: boolean()
  def participating?(generator) when is_map(generator) do
    Frequency.governor_duty?(generator) and dispatch_mw(generator) > 0.0 and
      headroom_mw(generator) > 0.0
  end

  # One participating unit as AGC needs to see it.
  defp descriptor(generator) do
    %{
      id: Map.get(generator, :id),
      ramp_mw_per_min: ramp_mw_per_min(generator),
      up_reserve_mw: headroom_mw(generator),
      base_mw: dispatch_mw(generator),
      nameplate_mw: nameplate_mw(generator),
      fuel_class: Frequency.fuel_class(generator),
      beta_mw_per_01hz: unit_natural_response_mw_per_01hz(generator)
    }
  end

  # Real ramp data when the map carries it, else the per-fuel table.
  defp ramp_mw_per_min(generator) do
    case Map.get(generator, :ramp_rate_mw_per_min) do
      rate when is_number(rate) and rate > 0.0 -> rate * 1.0
      _ -> Frequency.secondary_ramp_mw_per_min(generator)
    end
  end

  # ---------------------------------------------------------------------------
  # Frequency bias
  # ---------------------------------------------------------------------------

  @doc """
  The island's natural frequency response β, in MW per 0.1 Hz.

  This is the same quantity BAL-003 measures as ΔP/Δf, computed from
  composition rather than from an event: every governor-duty unit's
  DELIVERABLE droop response at a #{@beta_reference_hz} Hz deviation — droop
  demand scaled by the fuel's primary duty share, capped by the delivery-rate
  ceiling and by headroom, and reduced by the governor deadband the units
  genuinely have — plus the load-damping term `D * P_load * Δf/f0`.

  Being a composition estimate it is not identical to the event ratio the
  swing model produces (the deadband bites differently at a different
  excursion depth, and headroom binds unit by unit as the event develops), but
  it is derived from the same table and lands in the same range. As a bias
  setting on an island with no ties it fixes the loop gain, not the answer.
  """
  @spec natural_response_mw_per_01hz(list(map()), float()) :: float()
  def natural_response_mw_per_01hz(generators, load_mw \\ 0.0) do
    governor_part =
      generators
      |> Enum.map(&unit_natural_response_mw_per_01hz/1)
      |> Enum.sum()

    governor_part + load_response_mw_per_01hz(load_mw)
  end

  @doc """
  One unit's deliverable droop response at the #{@beta_reference_hz} Hz
  reference deviation, in MW per 0.1 Hz. Zero for a unit with no governor
  duty, no synchronism, or no headroom.
  """
  @spec unit_natural_response_mw_per_01hz(map()) :: float()
  def unit_natural_response_mw_per_01hz(generator) when is_map(generator) do
    if Frequency.governor_duty?(generator) and dispatch_mw(generator) > 0.0 do
      constants = Frequency.machine_constants(generator)

      # Only the excursion beyond the governor deadband is answered at all.
      df_eff = max(@beta_reference_hz - Frequency.governor_deadband_hz(), 0.0)

      demand =
        df_eff / Frequency.nominal_frequency() / Frequency.droop() *
          nameplate_mw(generator) * constants.primary_duty_fraction

      # Delivery-rate ceiling and headroom, exactly as the swing model applies
      # them. The reference deviation IS 0.1 Hz, so this is already the
      # per-0.1-Hz figure the bias is quoted in.
      min(demand, Frequency.primary_response_capability_mw(generator))
    else
      0.0
    end
  end

  # Load damping's share of the natural response: D * P_load * (0.1 / f0).
  defp load_response_mw_per_01hz(load_mw) do
    Frequency.load_damping() * max(load_mw, 0.0) * @beta_reference_hz /
      Frequency.nominal_frequency()
  end

  # Composition-derived bias with the BAL-005 floor applied.
  defp bias_from(unit_map, order, load_mw) do
    governor_part =
      order
      |> Enum.map(fn id -> Map.fetch!(unit_map, id).beta_mw_per_01hz end)
      |> Enum.sum()

    natural = governor_part + load_response_mw_per_01hz(load_mw)

    max(natural, @bias_floor_fraction * max(load_mw, 0.0))
  end

  # ---------------------------------------------------------------------------
  # The control step
  # ---------------------------------------------------------------------------

  @doc """
  Advance the controller by `dt_s` seconds and, on a cycle boundary, issue
  setpoint changes.

  `telemetry` is a map carrying at least `:frequency_hz`; optionally
  `:net_interchange_mw` (and `:scheduled_interchange_mw`, defaulting to the
  state's) for the interchange term of ACE.

  Returns `{state, setpoint_deltas}` where `setpoint_deltas` is
  `%{generator_id => delta_mw}` — the INCREMENT commanded by this call, signed
  (positive raises). Between cycle boundaries, and inside the deadband, the
  map is empty.

  The increments are what `Reserves.allocate/4` consumes as the AGC-fed
  secondary tier; the cumulative position is in `state.dispatched_by_unit`.
  """
  @spec step(t(), map(), float()) :: {t(), %{optional(any()) => float()}}
  def step(%__MODULE__{} = state, telemetry, dt_s) do
    dt_s = max(dt_s * 1.0, 0.0)
    ace = area_control_error(state, telemetry)
    inside_deadband? = abs(ace) <= deadband_mw(state)

    # Inside the noise floor the integrator is frozen: an undisturbed island
    # must not accumulate a correction out of telemetry jitter.
    ace_eff = if inside_deadband?, do: 0.0, else: ace

    state = %{
      state
      | ace_mw: ace,
        integral_mw_s: clamp_integral(state, state.integral_mw_s + ace_eff * dt_s),
        since_cycle_s: state.since_cycle_s + dt_s
    }

    if state.since_cycle_s + @cycle_epsilon < state.cycle_s do
      {state, %{}}
    else
      command(state, ace_eff)
    end
  end

  @doc """
  Area Control Error in MW for the given telemetry, with this state's bias.

  Negative means the area is under-generating. See the moduledoc for the sign
  convention and its relationship to NERC's negative-`B` form.
  """
  @spec area_control_error(t(), map()) :: float()
  def area_control_error(%__MODULE__{} = state, telemetry) do
    f0 = Frequency.nominal_frequency()
    df = (Map.get(telemetry, :frequency_hz) || f0) - f0

    interchange =
      case Map.get(telemetry, :net_interchange_mw) do
        actual when is_number(actual) ->
          scheduled =
            Map.get(telemetry, :scheduled_interchange_mw) || state.scheduled_interchange_mw

          actual - scheduled

        _ ->
          0.0
      end

    interchange + 10.0 * state.bias_mw_per_01hz * df
  end

  @doc """
  The ACE magnitude below which the controller does nothing, in MW — the
  frequency deadband expressed through the bias.
  """
  @spec deadband_mw(t()) :: float()
  def deadband_mw(%__MODULE__{} = state),
    do: 10.0 * state.bias_mw_per_01hz * state.deadband_hz

  # One AGC cycle: compute the target position, ask the fleet for the gap,
  # take what it can give, and reconcile the integrator with what happened.
  defp command(%__MODULE__{} = state, ace) do
    elapsed_s = state.since_cycle_s

    # PI on ACE. Negative ACE (under-generation) gives a positive target.
    target_mw = -(state.kp * ace + state.ki * state.integral_mw_s)
    requested_mw = target_mw - state.dispatched_mw

    {deltas, achieved_mw, saturated?} =
      if abs(requested_mw) < @min_command_mw do
        {%{}, 0.0, false}
      else
        distribute(state, requested_mw, elapsed_s)
      end

    dispatched_by_unit =
      Enum.reduce(deltas, state.dispatched_by_unit, fn {id, mw}, acc ->
        Map.update(acc, id, mw, &(&1 + mw))
      end)

    dispatched_mw = state.dispatched_mw + achieved_mw

    # Back-calculation anti-windup: the integrator is rewritten so the control
    # law reproduces the position the fleet actually reached. Without this the
    # integral outruns a ramp-limited or reserve-exhausted fleet and unwinds
    # as an overshoot the moment the constraint lifts.
    integral =
      if saturated? and state.ki > 0.0 do
        -(dispatched_mw + state.kp * ace) / state.ki
      else
        state.integral_mw_s
      end

    {%{
       state
       | dispatched_by_unit: dispatched_by_unit,
         dispatched_mw: dispatched_mw,
         integral_mw_s: clamp_integral(state, integral),
         since_cycle_s: 0.0,
         cycles: state.cycles + 1,
         saturated?: saturated?
     }, deltas}
  end

  # Hard bound on the integral so a controller that has been saturated for a
  # long time cannot hold a command the fleet could never deliver.
  #
  # The band is on the integral term's share of the COMMANDED POSITION, not on
  # what is left to command: `-Ki * I` is the cumulative MW above the base
  # schedule, so it may run from zero (the measured operating point, which
  # AGC does not curtail below — see the moduledoc) up to the whole reserve
  # the fleet carries. Bounding it by the reserve REMAINING would be a
  # different and wrong statement: the position would then have to shrink as
  # it grew, and the loop would converge on half the fleet's reserve.
  defp clamp_integral(%__MODULE__{ki: ki}, integral) when ki <= 0.0, do: integral

  defp clamp_integral(%__MODULE__{} = state, integral) do
    integral |> max(-state.capacity_mw / state.ki) |> min(0.0)
  end

  # ---------------------------------------------------------------------------
  # Distribution over the participating fleet
  # ---------------------------------------------------------------------------

  # Split `requested_mw` (signed) over the participating units by participation
  # factor, clipped per unit by ramp over `elapsed_s` and by the reserve left
  # in that direction, with the shortfall from clipped units redistributed to
  # the ones that still have room.
  defp distribute(%__MODULE__{} = state, requested_mw, elapsed_s) do
    sign = if requested_mw >= 0.0, do: 1.0, else: -1.0
    wanted = abs(requested_mw)

    caps =
      Map.new(state.order, fn id ->
        {id, capability_mw(state, id, sign, elapsed_s)}
      end)

    total_cap = caps |> Map.values() |> Enum.sum()

    {magnitudes, taken} = fill(state.order, state.participation, caps, wanted)

    deltas =
      magnitudes
      |> Enum.filter(fn {_id, mw} -> mw > 0.0 end)
      |> Map.new(fn {id, mw} -> {id, sign * mw} end)

    {deltas, sign * taken, taken < wanted - 1.0e-9 or total_cap <= 0.0}
  end

  # How much one unit may move this cycle, as a magnitude in `sign`'s
  # direction: its ramp over the elapsed time, and the reserve it has left.
  defp capability_mw(state, id, sign, elapsed_s) do
    unit = Map.fetch!(state.units, id)
    already = Map.get(state.dispatched_by_unit, id, 0.0)
    ramp_bound = unit.ramp_mw_per_min * elapsed_s / 60.0

    reserve_bound =
      if sign > 0.0 do
        # Up: the headroom it started with, less what AGC has already used.
        max(unit.up_reserve_mw - already, 0.0)
      else
        # Down: only AGC's own additions come back off. See the moduledoc's
        # "What this module does NOT do".
        max(already, 0.0)
      end

    min(max(ramp_bound, 0.0), reserve_bound)
  end

  # Pro-rata fill by participation factor with redistribution: units clipped by
  # their own ramp or reserve hand the remainder to the units that still have
  # room, so the fleet delivers the command whenever it collectively can.
  defp fill(_order, _weights, _caps, wanted) when wanted <= 0.0, do: {%{}, 0.0}

  defp fill(order, weights, caps, wanted) do
    initial = {Map.new(order, &{&1, 0.0}), wanted, order}

    {alloc, remaining, _eligible} =
      Enum.reduce_while(1..@max_passes//1, initial, fn _pass, {alloc, remaining, eligible} ->
        weight_total =
          eligible |> Enum.map(&Map.get(weights, &1, 0.0)) |> Enum.sum()

        if remaining <= 1.0e-9 or eligible == [] or weight_total <= 0.0 do
          {:halt, {alloc, remaining, eligible}}
        else
          {alloc, given} =
            Enum.reduce(eligible, {alloc, 0.0}, fn id, {acc, given} ->
              room = Map.fetch!(caps, id) - Map.fetch!(acc, id)
              share = remaining * Map.get(weights, id, 0.0) / weight_total
              take = min(max(share, 0.0), max(room, 0.0))
              {Map.put(acc, id, Map.fetch!(acc, id) + take), given + take}
            end)

          still_eligible =
            Enum.filter(eligible, fn id ->
              Map.fetch!(caps, id) - Map.fetch!(alloc, id) > 1.0e-9
            end)

          if given <= 1.0e-12 do
            {:halt, {alloc, remaining - given, still_eligible}}
          else
            {:cont, {alloc, remaining - given, still_eligible}}
          end
        end
      end)

    {alloc, wanted - max(remaining, 0.0)}
  end

  # ---------------------------------------------------------------------------
  # Island splits
  # ---------------------------------------------------------------------------

  @doc """
  Apportion this state across new islands.

  `islands` is a list of maps carrying `:unit_ids` (a list or `MapSet` of
  generator ids that landed in that island) and optionally `:load_mw` (the
  island's load, for the new bias). Without `:load_mw` the load is estimated
  from the island's share of the parent's dispatched base — a linear
  apportionment, which is the best a controller can do without being told the
  new topology.

  Returns one state per island, in the order given. Units not named in any
  island are dropped: they left with a part of the system this controller no
  longer regulates.

  Each child keeps its units' accumulated `dispatched_by_unit` (a property of
  the machines) and starts with a ZERO integrator (a property of the area,
  which is new). See the moduledoc for why.
  """
  @spec apportion(t(), list(map())) :: list(t())
  def apportion(%__MODULE__{} = state, islands) do
    base_total = state.order |> Enum.map(&Map.fetch!(state.units, &1).base_mw) |> Enum.sum()

    Enum.map(islands, fn island ->
      ids = island |> Map.get(:unit_ids, []) |> MapSet.new()
      order = Enum.filter(state.order, &MapSet.member?(ids, &1))
      units = Map.take(state.units, order)
      dispatched_by_unit = Map.take(state.dispatched_by_unit, order)

      load_mw =
        case Map.get(island, :load_mw) do
          mw when is_number(mw) ->
            mw * 1.0

          _ ->
            kept = order |> Enum.map(&Map.fetch!(units, &1).base_mw) |> Enum.sum()
            if base_total > 0.0, do: state.island_load_mw * kept / base_total, else: 0.0
        end

      %{
        state
        | order: order,
          units: units,
          participation: participation_factors(order, units),
          bias_mw_per_01hz: bias_from(units, order, load_mw),
          dispatched_by_unit: dispatched_by_unit,
          dispatched_mw: dispatched_by_unit |> Map.values() |> Enum.sum(),
          capacity_mw: order |> Enum.map(&Map.fetch!(units, &1).up_reserve_mw) |> Enum.sum(),
          island_load_mw: load_mw,
          # A new area's ACE is a new signal (see the moduledoc).
          integral_mw_s: 0.0,
          ace_mw: 0.0,
          since_cycle_s: 0.0,
          cycles: 0,
          saturated?: false,
          # Tie schedules do not survive a separation.
          scheduled_interchange_mw: 0.0
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Accessors
  # ---------------------------------------------------------------------------

  @doc "The ids of the units on AGC regulation, in participation order."
  @spec participating_ids(t()) :: list()
  def participating_ids(%__MODULE__{order: order}), do: order

  @doc """
  Total up-reserve the controller has left, in MW: each unit's initial
  headroom less what AGC has already taken from it.
  """
  @spec reserve_remaining_mw(t()) :: float()
  def reserve_remaining_mw(%__MODULE__{} = state) do
    state.order
    |> Enum.map(fn id ->
      max(
        Map.fetch!(state.units, id).up_reserve_mw - Map.get(state.dispatched_by_unit, id, 0.0),
        0.0
      )
    end)
    |> Enum.sum()
  end

  @doc "Total AGC-controllable reserve at initialisation, in MW."
  @spec reserve_capacity_mw(t()) :: float()
  def reserve_capacity_mw(%__MODULE__{capacity_mw: mw}), do: mw

  @doc "Cumulative MW this controller has dispatched above the base schedule."
  @spec dispatched_mw(t()) :: float()
  def dispatched_mw(%__MODULE__{dispatched_mw: mw}), do: mw

  @doc """
  A flat summary of the controller for logging and reporting.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = state) do
    %{
      units: length(state.order),
      bias_mw_per_01hz: state.bias_mw_per_01hz,
      ace_mw: state.ace_mw,
      integral_mw_s: state.integral_mw_s,
      dispatched_mw: state.dispatched_mw,
      reserve_remaining_mw: reserve_remaining_mw(state),
      cycles: state.cycles,
      saturated?: state.saturated?
    }
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Participation proportional to available secondary ramp; a fleet with no
  # ramp data anywhere shares by reserve instead, and one with neither shares
  # equally.
  defp participation_factors([], _units), do: %{}

  defp participation_factors(order, units) do
    weights = Map.new(order, fn id -> {id, Map.fetch!(units, id).ramp_mw_per_min} end)

    weights =
      if Enum.sum(Map.values(weights)) > 0.0 do
        weights
      else
        reserves = Map.new(order, fn id -> {id, Map.fetch!(units, id).up_reserve_mw} end)

        if Enum.sum(Map.values(reserves)) > 0.0,
          do: reserves,
          else: Map.new(order, &{&1, 1.0})
      end

    total = weights |> Map.values() |> Enum.sum()
    Map.new(order, fn id -> {id, Map.fetch!(weights, id) / total} end)
  end

  defp dispatch_mw(generator) do
    Map.get(generator, :p_dispatch_mw) ||
      (Map.get(generator, :p_max_mw) || 0.0) * (Map.get(generator, :capacity_factor) || 1.0)
  end

  defp nameplate_mw(generator),
    do: Map.get(generator, :p_nameplate_mw) || Map.get(generator, :p_max_mw) || 0.0

  defp headroom_mw(generator), do: max(nameplate_mw(generator) - dispatch_mw(generator), 0.0)
end
