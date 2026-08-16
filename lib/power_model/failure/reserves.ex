defmodule PowerModel.Failure.Reserves do
  @moduledoc """
  Ramp-limited reserve tiers on the cascade clock (ROADMAP item 16).

  A megawatt of nameplate headroom is not a megawatt of reserve. What a fleet
  can actually put on the system depends on HOW LONG it has had, and the
  three tiers below are the three timescales real operators run:

  | tier | timescale | who answers | what bounds it |
  |------|-----------|-------------|----------------|
  | primary | seconds | governors on spinning, governor-duty units | `Frequency.primary_response_capability_mw/1` (delivery rate x the 10 s nadir window, capped by headroom) |
  | secondary | 30 s - 10 min | AGC on spinning units | `Frequency.secondary_ramp_mw_per_min/1` x elapsed — or, closed-loop, what AGC actually dispatched (see `allocate/4`) |
  | tertiary | 10 min+ | supplemental/non-spinning units and the rest of the spinning headroom | the same ramp over the elapsed time past the start-up delay |

  `allocate/3` is pure: it takes the island's units, the sustained deficit it
  has to close, and how long the deficit has been open on the cascade clock,
  and returns the MW each tier can deliver plus the per-unit allocation.

  ## Open-loop tiers, and the closed loop that replaces one of them

  These tiers are OPEN-LOOP: the secondary number is what the fleet could have
  ramped in the time available, delivered against an arithmetic deficit
  whether or not the frequency still needs it, and stopping when the deficit
  is covered rather than when the frequency is back at 60 Hz. That is a good
  model of how much reserve a clock allows and a poor model of secondary
  CONTROL, which is a closed loop on Area Control Error.

  `PowerModel.Controls.AGC` is that loop, and `allocate/4` accepts its output
  in place of the secondary tier's clock ramp — `secondary: {:agc, deltas}`.
  The two are alternatives, never addends; see `allocate/4` for the contract
  and for why summing them would let a fleet deliver reserve it does not
  carry.

  ## Primary arrests, secondary replaces

  Primary response is TRANSIENT. It is what governors deploy to arrest the
  frequency in the first seconds, and it is released again as the slower tiers
  take the load over — which is why `allocate/3` fills secondary and tertiary
  FIRST and offers primary only what they could not reach in time.

  That ordering is also what keeps the frequency model and the power-flow
  model from double-counting the same megawatts. `PowerModel.Failure.Cascade`
  adds the secondary and tertiary MW to the island's SUSTAINED operating point
  — the generation the swing equation is told about — while the primary MW is
  carried separately (`Cascade`'s `primary_reserve` map) and handed only to
  the DC power flow, because the swing model produces that response itself
  from droop, duty and delivery rate. Telling the swing model about it as
  dispatched generation as well would deliver it twice.

  ## The regime this exists for

  A deficit that reserves cannot close IN TIME goes to under-frequency load
  shedding even when nameplate headroom is abundant. A coal-and-biomass island
  has plenty of megawatts and a primary delivery rate of 0.1-0.2%/s: at the
  instant of a trip it can offer a couple of percent of nameplate and nothing
  more for minutes. A hydro/gas island of the same size offers ten to fifteen
  percent within the same window. Same headroom, different outcome — that is
  the regime that kills real grids, and it only appears in a model whose
  reserves are bounded by a clock.

  ## Elapsed time, and the one case where it is infinite

  `elapsed_s` is measured from the moment the island's sustained deficit
  opened. `:infinity` means "this is not an event": the initial operating
  point had all the time in the world to reach itself, so every megawatt of
  headroom is available. `PowerModel.Failure.Cascade` uses that only when it
  balances the snapshot's dispatch at `init/3`; every deficit that opens
  during a cascade is timed from the clock.
  """

  alias PowerModel.Solver.Frequency

  # Secondary reserve is defined over a 10-minute horizon; ramp beyond that is
  # tertiary by definition, so the secondary tier stops crediting elapsed time
  # here and the tertiary tier picks the same ramp up from the same instant.
  @secondary_horizon_s 600.0

  # A unit that is not already spinning has to be started before it can ramp.
  # Ten minutes is the conventional non-spinning / supplemental reserve
  # response time and matches the secondary horizon, so the two tiers meet
  # without a gap.
  @tertiary_start_delay_s 600.0

  @doc """
  Allocate `deficit_mw` across the ramp-limited tiers.

  `units` are generator maps carrying at least `:id`, `:fuel_type`, the
  SUSTAINED operating point as `:p_dispatch_mw` and the machine rating as
  `:p_nameplate_mw` (`PowerModel.Solver.Frequency`'s convention — see
  `Cascade.apply_dispatch/2`).

  Returns

      %{
        secondary_mw: float(),        # MW the tier delivered
        tertiary_mw: float(),
        primary_mw: float(),
        remaining_mw: float(),        # deficit no tier could reach in time
        sustained_by_unit: %{id => mw},  # secondary + tertiary, per unit
        secondary_by_unit: %{id => mw},  # the same, split by tier, for the
        tertiary_by_unit: %{id => mw},   # caller's ramp ledger (`:delivered`)
        primary_by_unit: %{id => mw},
        secondary_capability_mw: float(), # what each tier COULD have delivered
        tertiary_capability_mw: float(),
        primary_capability_mw: float(),
        secondary_source: :clock | :agc  # which secondary tier answered
      }

  The capability figures are reported whether or not the tier was used, so a
  caller can say "the headroom was there and the clock was not" — which is the
  whole point of the item.

  ## Options

    * `:secondary` — where the secondary tier's capability comes from.

      `:clock` (default) is the open-loop tier described above:
      `ramp × elapsed`, capped by headroom.

      `{:agc, %{id => mw}}` is CLOSED-LOOP secondary control. The map is the
      per-unit setpoint INCREMENT `PowerModel.Controls.AGC.step/3` just
      issued, and it becomes this tier's per-unit capability (still capped by
      the unit's physical headroom, which is the one bound AGC's own limits
      and this module must agree on). The clock plays no part: what the tier
      delivers is what the frequency error called for.

  ### Why the two can never be summed

  Both tiers dispatch the SAME megawatts out of the same headroom — the
  open-loop one because the clock says they could have ramped, the closed-loop
  one because ACE says they were needed. Running both would raise a unit twice
  for one deficit and, since the cascade recomputes each step's deficit from
  the raised dispatch, would show a fleet delivering more reserve than it
  physically carries. `:secondary` therefore SELECTS a tier; it does not add
  one. Tertiary stays on the clock in both modes (it answers a different,
  slower question), and the primary tier still rides on whatever the sustained
  tiers left.

  The AGC map must be the per-step increment, never the cumulative position:
  the cascade adds the allocation to its dispatch, and the next step's deficit
  already reflects it.

    * `:delivered` — the caller's ramp ledger, `%{id => %{secondary: mw,
      tertiary: mw}}`: what each unit has ALREADY put on the system under the
      same `elapsed_s` clock. Each clock-ramped tier's bound becomes
      `ramp(elapsed) - delivered`, so repeated allocations against one clock
      hand out ONE ramp between them rather than one each.

  ### Why a stateless ramp bound is not enough

  `allocate/4` is pure, and one call in isolation is correct: a unit that has
  had 60 s of a 20 MW/min ramp can deliver 20 MW. But a caller that allocates
  more than once against the SAME clock — `PowerModel.Failure.Cascade` makes up
  to three allocations per island per step — gets 20 MW each time, because the
  raised operating point moves the HEADROOM bound and nothing moves the ramp
  bound. Measured at 60 MW from a 20 MW/min unit past 600 s, which is a fleet
  answering a deficit faster than it physically can and UFLS under-firing as a
  result (REVIEW CAS-22).

  The ledger is per TIER because the two clock-ramped tiers cover disjoint
  windows of the same ramp — secondary the first `#{@secondary_horizon_s} s`,
  tertiary everything past `#{@tertiary_start_delay_s} s` — so their sum is
  `ramp(elapsed)` exactly once. Folding them into one figure would let a unit
  that spent its secondary window deny itself the tertiary one.

  The ledger belongs to the caller because only the caller knows when the clock
  it is measured against restarts: a ledger that outlives its `elapsed_s`
  origin is a ramp budget charged against a clock that no longer exists.
  """
  @spec allocate(list(map()), float(), float() | :infinity, keyword()) :: map()
  def allocate(units, deficit_mw, elapsed_s, opts \\ []) do
    deficit_mw = max(deficit_mw * 1.0, 0.0)
    secondary = Keyword.get(opts, :secondary, :clock)
    delivered = Keyword.get(opts, :delivered) || %{}

    secondary_caps =
      Enum.map(units, fn u ->
        {u,
         secondary_capability_mw(u, elapsed_s, secondary, delivered_mw(delivered, u, :secondary))}
      end)

    secondary_capability = sum_caps(secondary_caps)

    {secondary_alloc, secondary_mw} = fill_pro_rata(secondary_caps, deficit_mw)

    # Tertiary is only reached once secondary has SATURATED: an operator does
    # not start a peaker while spinning reserve still has room to answer.
    remaining = deficit_mw - secondary_mw
    secondary_saturated? = secondary_mw >= secondary_capability - 1.0e-9

    tertiary_caps =
      Enum.map(units, fn u ->
        {u,
         tertiary_capability_mw(
           u,
           elapsed_s,
           Map.get(secondary_alloc, u.id, 0.0),
           delivered_mw(delivered, u, :tertiary)
         )}
      end)

    tertiary_capability = sum_caps(tertiary_caps)

    {tertiary_alloc, tertiary_mw} =
      if secondary_saturated? and remaining > 0.0 do
        fill_pro_rata(tertiary_caps, remaining)
      else
        {%{}, 0.0}
      end

    sustained_by_unit = Map.merge(secondary_alloc, tertiary_alloc, fn _id, a, b -> a + b end)

    # Primary rides on what the sustained tiers left: a unit raised by AGC has
    # that much less governor headroom, and `primary_response_capability_mw/1`
    # reads the operating point, so the units are re-shaped before it is asked.
    primary_caps =
      Enum.map(units, fn u ->
        raised = raise_unit(u, Map.get(sustained_by_unit, u.id, 0.0))
        {u, primary_capability_mw(raised)}
      end)

    primary_capability = sum_caps(primary_caps)

    {primary_alloc, primary_mw} =
      fill_pro_rata(primary_caps, max(deficit_mw - secondary_mw - tertiary_mw, 0.0))

    %{
      secondary_mw: secondary_mw,
      tertiary_mw: tertiary_mw,
      primary_mw: primary_mw,
      remaining_mw: max(deficit_mw - secondary_mw - tertiary_mw - primary_mw, 0.0),
      sustained_by_unit: sustained_by_unit,
      secondary_by_unit: secondary_alloc,
      tertiary_by_unit: tertiary_alloc,
      primary_by_unit: primary_alloc,
      secondary_capability_mw: secondary_capability,
      tertiary_capability_mw: tertiary_capability,
      primary_capability_mw: primary_capability,
      secondary_source: secondary_source(secondary)
    }
  end

  defp secondary_source({:agc, _deltas}), do: :agc
  defp secondary_source(_), do: :clock

  @doc """
  Spinning secondary reserve one unit can deliver after `elapsed_s`.

  Only units that are already generating count: secondary reserve is carried
  on synchronised machines under AGC. The bound is the technology ramp over
  the elapsed time, capped at the unit's remaining headroom and at the
  ten-minute secondary horizon.

  With `source` = `{:agc, %{id => mw}}` the ramp-and-clock bound is replaced by
  the MW closed-loop AGC actually dispatched to this unit — still capped by
  its headroom. See `allocate/4`.

  `delivered_mw` is what this unit has already delivered from THIS tier under
  the same clock; it is subtracted from the ramp bound so a second call cannot
  re-grant the first call's megawatts. It has no effect on the AGC form, whose
  bound is a closed-loop command rather than an elapsed-time budget.
  """
  @spec secondary_capability_mw(map(), float() | :infinity, :clock | {:agc, map()}, float()) ::
          float()
  def secondary_capability_mw(unit, elapsed_s, source \\ :clock, delivered_mw \\ 0.0)

  def secondary_capability_mw(unit, _elapsed_s, {:agc, deltas}, _delivered_mw) do
    if spinning?(unit) do
      dispatched = Map.get(deltas, Map.get(unit, :id), 0.0)
      min(max(dispatched, 0.0), headroom_mw(unit))
    else
      0.0
    end
  end

  def secondary_capability_mw(unit, elapsed_s, _clock, delivered_mw) do
    if spinning?(unit) do
      bounded_by(
        headroom_mw(unit),
        ramp_remaining(unit, credited_seconds(elapsed_s, @secondary_horizon_s), delivered_mw)
      )
    else
      0.0
    end
  end

  @doc """
  Tertiary (supplemental) reserve one unit can deliver after `elapsed_s`,
  given `already_mw` of secondary already taken from it.

  Spinning units contribute the headroom secondary could not reach inside its
  horizon; non-spinning units contribute only after the start-up delay, and
  then ramp like any other machine of their technology.

  The two "already" figures answer different questions and both bind.
  `already_mw` is secondary taken from this unit's HEADROOM in the same
  allocation; `delivered_mw` is tertiary this unit has already delivered under
  the same CLOCK, and comes off the ramp bound (see `allocate/4`'s
  `:delivered`).
  """
  @spec tertiary_capability_mw(map(), float() | :infinity, float(), float()) :: float()
  def tertiary_capability_mw(unit, elapsed_s, already_mw \\ 0.0, delivered_mw \\ 0.0) do
    past_delay = seconds_past(elapsed_s, @tertiary_start_delay_s)
    ramp_bound = ramp_remaining(unit, past_delay, delivered_mw)

    if spinning?(unit) do
      bounded_by(max(headroom_mw(unit) - already_mw, 0.0), ramp_bound)
    else
      bounded_by(headroom_mw(unit), ramp_bound)
    end
  end

  @doc """
  Primary (governor) response one unit can deliver, in MW.

  Delegates to `PowerModel.Solver.Frequency.primary_response_capability_mw/1`
  — delivery rate over the nadir window, capped by headroom and zero for a
  unit with no governor duty — and additionally requires the unit to be
  spinning: a governor on a machine that is not synchronised moves nothing.
  """
  @spec primary_capability_mw(map()) :: float()
  def primary_capability_mw(unit) do
    if spinning?(unit), do: Frequency.primary_response_capability_mw(unit), else: 0.0
  end

  @doc """
  Total primary-capable spinning reserve across `units`, in MW.

  This is the quantity a contingency-reserve requirement is written against
  (REVIEW ENE-19) — NOT `p_max_mw - p_dispatch_mw`, which credits a nuclear
  unit's headroom as frequency response it will never provide.
  """
  @spec primary_capability_mw_total(list(map())) :: float()
  def primary_capability_mw_total(units) do
    units |> Enum.map(&primary_capability_mw/1) |> Enum.sum()
  end

  @doc """
  The secondary horizon and tertiary start delay, in seconds — exported so
  tests and callers read the same constants the tiers do.
  """
  def horizons,
    do: %{secondary_s: @secondary_horizon_s, tertiary_delay_s: @tertiary_start_delay_s}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # The unit as it stands after the sustained tiers have raised it: the same
  # map with its operating point moved, so every capability question below is
  # asked of the post-AGC machine.
  defp raise_unit(unit, added_mw) when added_mw <= 0.0, do: unit

  defp raise_unit(unit, added_mw) do
    raised = dispatch_mw(unit) + added_mw

    unit
    |> Map.put(:p_dispatch_mw, raised)
    |> Map.put(:p_nameplate_mw, nameplate_mw(unit))
    |> Map.put(:p_max_mw, raised)
    |> Map.put(:capacity_factor, 1.0)
  end

  defp spinning?(unit), do: dispatch_mw(unit) > 0.0

  defp dispatch_mw(unit) do
    Map.get(unit, :p_dispatch_mw) ||
      (Map.get(unit, :p_max_mw) || 0.0) * (Map.get(unit, :capacity_factor) || 1.0)
  end

  defp nameplate_mw(unit), do: Map.get(unit, :p_nameplate_mw) || Map.get(unit, :p_max_mw) || 0.0

  defp headroom_mw(unit), do: max(nameplate_mw(unit) - dispatch_mw(unit), 0.0)

  defp ramp_mw(_unit, :infinity), do: :infinity
  defp ramp_mw(unit, seconds), do: Frequency.secondary_ramp_mw_per_min(unit) * seconds / 60.0

  # The ramp this tier still allows, net of what the unit already delivered
  # from it under the same clock. An unbounded ramp stays unbounded: the
  # `:infinity` clock is the "not an event" case, where there is no budget to
  # spend down.
  defp ramp_remaining(_unit, :infinity, _delivered_mw), do: :infinity

  defp ramp_remaining(unit, seconds, delivered_mw),
    do: max(ramp_mw(unit, seconds) - max(delivered_mw, 0.0), 0.0)

  # One unit's entry in the caller's ramp ledger. A ledger with no entry for a
  # unit is a unit that has delivered nothing, which is also what an absent
  # ledger means — the pure single-call case, unchanged.
  defp delivered_mw(delivered, unit, tier) do
    delivered
    |> Map.get(Map.get(unit, :id), %{})
    |> Map.get(tier, 0.0)
  end

  defp credited_seconds(:infinity, _horizon), do: :infinity
  defp credited_seconds(elapsed_s, horizon), do: min(max(elapsed_s, 0.0), horizon)

  defp seconds_past(:infinity, _delay), do: :infinity
  defp seconds_past(elapsed_s, delay), do: max(elapsed_s - delay, 0.0)

  # An unbounded ramp (`:infinity`, the "not an event" case) never binds.
  defp bounded_by(mw, :infinity), do: mw
  defp bounded_by(mw, bound), do: min(mw, bound)

  defp sum_caps(caps), do: caps |> Enum.map(fn {_u, mw} -> mw end) |> Enum.sum()

  # Fill `wanted` MW from the capabilities, in proportion to each unit's own
  # capability, so no unit is asked for more than it has and the shape of the
  # answer follows the shape of the fleet.
  defp fill_pro_rata(_caps, wanted) when wanted <= 0.0, do: {%{}, 0.0}

  defp fill_pro_rata(caps, wanted) do
    total = sum_caps(caps)

    if total <= 0.0 do
      {%{}, 0.0}
    else
      taken = min(wanted, total)
      fraction = taken / total

      alloc =
        Enum.reduce(caps, %{}, fn {unit, cap}, acc ->
          mw = cap * fraction
          if mw > 0.0, do: Map.put(acc, unit.id, mw), else: acc
        end)

      {alloc, taken}
    end
  end
end
