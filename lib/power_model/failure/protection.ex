defmodule PowerModel.Failure.Protection do
  @moduledoc """
  Protection system models for cascade simulation.
  Implements overcurrent, undervoltage, underfrequency, and Zone 3 distance relays.

  ## Generator frequency protection (ROADMAP item 15)

  `generator_frequency_trips/2` is a PURE function: given a frequency
  trajectory (or a flat-excursion summary) and a fleet, it returns the units
  whose frequency protection has operated, with the band and the time-in-band
  that did it. It reads no state and mutates nothing, so it can be evaluated
  inside a cascade step, in a test, or against a recorded trajectory.

  ## Distance protection and conductor thermals (ROADMAP item 20)

  The voltage-driven half of protection, added as pure functions ahead of the
  Q–V/QSS-AC solve that will feed them:

    * `apparent_impedance/3` and friends — what the relay measures.
    * `distance_zone/3`, `mho_reaches/2`, `inside_mho?/2` — mho zones 1/2/3
      and the delay each carries.
    * `loadability_limit_pu/2`, `load_encroachment?/3` — the PRC-023-4 load
      blinder that keeps a heavily-loaded healthy line from being called a
      fault.
    * `advance_conductor_temperature/4` and friends — the SLOW timescale: a
      first-order conductor thermal model, complementing (not replacing) the
      fast inverse-time relay the cascade already runs.

  Everything here takes voltages, flows and impedances as plain numbers, so it
  works the moment an AC solution exists and can be tested without one.
  """

  alias PowerModel.Grid.Ratings

  @doc """
  Check thermal overloads and return components to trip.
  Uses the IEC 60255-151 standard-inverse characteristic for trip timing.
  For simulation, we trip immediately if loading > 100%.

  Loading is computed from apparent power S = sqrt(P^2 + Q^2) when reactive
  power (`q_flow_mvar`) is available in the flow map (AC solutions).  For DC
  solutions where only `p_flow_mw` is present, loading falls back to |P|/rating.

  > #### Not the relay pickup basis {: .warning}
  >
  > This compares against RATE A, the normal/continuous rating. Relay pickup
  > in this model is rate C (ROADMAP item 9) — see
  > `PowerModel.Failure.Cascade.trip_loading_pct/1`, which is what the cascade
  > actually arms its timers on. Nothing calls this function today. A future
  > caller wanting relay behaviour wants the rate-C basis; a caller wanting an
  > operator-facing "over its continuous rating" alarm wants this one. Pick
  > deliberately rather than by whichever was nearest to hand.
  """
  def check_thermal_overloads(line_flows, threshold_pct \\ 100.0) do
    line_flows
    |> Enum.map(fn {key, flow} -> {key, recompute_loading(flow)} end)
    |> Enum.filter(fn {_key, flow} ->
      flow.loading_pct > threshold_pct
    end)
    |> Enum.map(fn {{type, id}, flow} ->
      %{
        component_type: component_type_string(type),
        component_id: id,
        failure_cause: "thermal_overload",
        details: %{
          loading_pct: flow.loading_pct,
          p_flow_mw: flow.p_flow_mw,
          s_flow_mva: Map.get(flow, :s_flow_mva)
        }
      }
    end)
    |> Enum.sort_by(fn trip -> -trip.details.loading_pct end)
  end

  # Recompute loading_pct using apparent power when Q is available.
  # For DC solutions (no q_flow_mvar key), the original loading_pct is kept.
  defp recompute_loading(%{q_flow_mvar: q, p_flow_mw: p} = flow) when is_number(q) do
    s_mva = :math.sqrt(p * p + q * q)
    rating = rating_from_flow(flow)

    if rating > 0 do
      %{flow | loading_pct: s_mva / rating * 100.0, s_flow_mva: s_mva}
    else
      flow
    end
  end

  defp recompute_loading(flow), do: flow

  # Extract the line/transformer rating from the flow map or fall back to
  # back-computing it from the original loading_pct and p_flow_mw.
  defp rating_from_flow(%{rating_mva: r}) when is_number(r) and r > 0, do: r
  defp rating_from_flow(%{rating_a_mva: r}) when is_number(r) and r > 0, do: r
  defp rating_from_flow(%{rated_mva: r}) when is_number(r) and r > 0, do: r

  defp rating_from_flow(%{loading_pct: pct, p_flow_mw: p}) when pct > 0 do
    abs(p) / (pct / 100.0)
  end

  defp rating_from_flow(_), do: 0

  @doc """
  Zone 3 distance relay check for load encroachment.

  In stressed conditions a heavily-loaded line can present an apparent impedance
  that falls inside the Zone 3 relay circle, causing the relay to misoperate
  (trip a healthy but overloaded line).

  Simplified model (usable without full AC state):
    - A line is at Zone 3 risk when loading_pct > 80% AND the voltage at either
      end is below 0.9 pu.
    - Trip probability increases with loading and decreases with voltage.
    - Returns trips with `failure_cause: "zone3_relay"`.

  Parameters
    - `line_flows` — the `solution.line_flows` map
    - `lines`      — retained for API compatibility; endpoint IDs come from each flow
    - `buses`      — list of bus maps (need `id`, `base_kv`)
    - `vm_pu`      — list of per-unit voltage magnitudes (same order as `bus_ids`)
    - `va_rad`     — list of voltage angles in radians (same order as `bus_ids`)
    - `bus_index`  — map of bus_id => positional index into vm_pu / va_rad lists
  """
  def check_zone3_encroachment(line_flows, _lines, _buses, vm_pu, _va_rad, bus_index) do
    line_flows
    |> Enum.filter(fn {{_type, _id}, flow} -> flow.loading_pct > 80.0 end)
    |> Enum.filter(fn {_key, flow} ->
      from_idx = Map.get(bus_index, flow.from_bus_id)
      to_idx = Map.get(bus_index, flow.to_bus_id)

      v_from = if from_idx, do: Enum.at(vm_pu, from_idx, 1.0), else: 1.0
      v_to = if to_idx, do: Enum.at(vm_pu, to_idx, 1.0), else: 1.0

      # Zone 3 encroachment when either end voltage is depressed
      v_from < 0.9 or v_to < 0.9
    end)
    |> Enum.map(fn {{type, id}, flow} ->
      from_idx = Map.get(bus_index, flow.from_bus_id)
      to_idx = Map.get(bus_index, flow.to_bus_id)
      v_from = if from_idx, do: Enum.at(vm_pu, from_idx, 1.0), else: 1.0
      v_to = if to_idx, do: Enum.at(vm_pu, to_idx, 1.0), else: 1.0

      # Trip probability: higher loading + lower voltage => more likely
      v_min = min(v_from, v_to)
      trip_probability = zone3_trip_probability(flow.loading_pct, v_min)

      %{
        component_type: component_type_string(type),
        component_id: id,
        failure_cause: "zone3_relay",
        details: %{
          loading_pct: flow.loading_pct,
          p_flow_mw: flow.p_flow_mw,
          v_from_pu: v_from,
          v_to_pu: v_to,
          trip_probability: trip_probability
        }
      }
    end)
    # Only trip lines where probability exceeds 50%
    |> Enum.filter(fn trip -> trip.details.trip_probability > 0.5 end)
    |> Enum.sort_by(fn trip -> -trip.details.trip_probability end)
  end

  @doc """
  Compute Zone 3 misoperation probability.

  The probability rises with loading percentage (above 80%) and with voltage
  depression (below 0.9 pu).  At 100% loading and 0.8 pu voltage the
  probability is ~0.833; at 120% loading and 0.75 pu it saturates at 1.0.
  If either factor is zero, the probability equals the other factor alone.
  Depressed voltage can therefore produce a probability above 0.5 at 80%
  loading, but `check_zone3_encroachment/6` only evaluates flows above 80%.
  """
  def zone3_trip_probability(loading_pct, v_min_pu) do
    # Loading factor: 0 at 80%, 1.0 at 120%
    loading_factor = min(max((loading_pct - 80.0) / 40.0, 0.0), 1.0)
    # Voltage factor: 0 at 0.9 pu, 1.0 at 0.75 pu
    voltage_factor = min(max((0.9 - v_min_pu) / 0.15, 0.0), 1.0)
    # Union of the independent loading and voltage contributions
    loading_factor + voltage_factor - loading_factor * voltage_factor
  end

  @doc """
  Check voltage violations and return buses with issues.
  Under-voltage relay trips at V < 0.85 pu.
  Over-voltage trips at V > 1.15 pu.
  """
  def check_voltage_violations(bus_ids, vm_pu, opts \\ []) do
    uv_threshold = Keyword.get(opts, :undervoltage, 0.85)
    ov_threshold = Keyword.get(opts, :overvoltage, 1.15)

    Enum.zip(bus_ids, vm_pu)
    |> Enum.filter(fn {_id, v} -> v < uv_threshold or v > ov_threshold end)
    |> Enum.map(fn {bus_id, v} ->
      cause = if v < uv_threshold, do: "undervoltage", else: "overvoltage"

      %{
        component_type: "bus",
        component_id: bus_id,
        failure_cause: cause,
        details: %{vm_pu: v}
      }
    end)
  end

  @doc """
  Under-Frequency Load Shedding (UFLS) scheme.

  Static nadir-based view of the canonical staged program defined in
  `PowerModel.Solver.Frequency.ufls_stages/0`: every stage whose threshold the
  frequency fell below has tripped, and the returned `shed_fraction` is their
  CUMULATIVE total (~30% of load with all stages in).

  Returns `[]` above the first stage, else `[stage: n, shed_fraction: cum]`.
  """
  def ufls_schedule(frequency_hz) do
    tripped =
      PowerModel.Solver.Frequency.ufls_stages()
      |> Enum.filter(fn {threshold_hz, _frac, _delay} -> frequency_hz < threshold_hz end)

    case tripped do
      [] ->
        []

      stages ->
        cumulative = stages |> Enum.map(fn {_t, frac, _d} -> frac end) |> Enum.sum()
        [stage: length(stages), shed_fraction: cumulative]
    end
  end

  @doc """
  Estimate system frequency based on generation-load imbalance.

  When called with generator and load structs, delegates to the swing-equation
  frequency simulator (`PowerModel.Solver.Frequency`) and returns the nadir
  (minimum) frequency.

  The 2/3-arity MW-only form is the STRUCT-LESS FALLBACK for callers that only
  know island totals: the damping-consistent steady state of the swing model
  with no governor response,

      f = f0 * (1 - deficit / (D * load)),   deficit = load - gen

  clamped to the same [55, 65] Hz band the dynamic simulator uses. This is
  the `dfStar` equilibrium of `proofs/Proofs/Swing.lean` with gov = shed = 0,
  so a total generation loss bottoms out at 55 Hz and drives the full UFLS
  schedule (the old 5%-droop estimate could never fall below 57 Hz).
  """
  def estimate_frequency(generators, loads, gen_mw, load_mw)
      when is_list(generators) and is_list(loads) do
    if load_mw <= 0.0 do
      60.0
    else
      lost_mw = load_mw - gen_mw
      trajectory = PowerModel.Solver.Frequency.simulate(generators, loads, lost_mw)
      PowerModel.Solver.Frequency.nadir(trajectory)
    end
  end

  def estimate_frequency(gen_mw, load_mw, base_freq \\ 60.0) do
    if load_mw <= 0.0 do
      base_freq
    else
      d = PowerModel.Solver.Frequency.load_damping()
      deficit = load_mw - gen_mw

      # Steady-state frequency with load damping as the only restoring force
      # (no governor), clamped to the simulator's physical band.
      (base_freq * (1.0 - deficit / (d * load_mw)))
      |> max(55.0)
      |> min(65.0)
    end
  end

  # ---------------------------------------------------------------------------
  # Generator frequency protection — PRC-024-shaped envelopes (ROADMAP item 15)
  # ---------------------------------------------------------------------------

  # Under-frequency envelope: `{band_hz, allowance_seconds}`.
  #
  # A generator must ride through as long as the time it has spent AT OR BELOW
  # a band stays within that band's allowance; the protection operates the
  # moment any band's allowance is exhausted. Read bottom-up: a unit may not
  # sit below 57.0 Hz at all, may sit below 58.0 Hz for half a minute, and may
  # sit below 59.4 Hz for three minutes.
  #
  # Shaped after NERC PRC-024 Attachment 1 (Frequency Protection Settings —
  # the "no trip zone" curve generator owners must set outside of). The exact
  # breakpoints differ by interconnection and standard revision; these are the
  # documented shape this model uses, not a verbatim transcription, and they
  # are the only place the numbers live.
  @underfrequency_envelope [
    {57.0, 0.0},
    {58.0, 30.0},
    {59.4, 180.0}
  ]

  # Over-frequency envelope: `{band_hz, allowance_seconds}`, symmetric in
  # spirit to the under-frequency side — read top-down: no time at all above
  # 61.8 Hz, half a minute above 61.5 Hz, three minutes above 60.6 Hz.
  @overfrequency_envelope [
    {61.8, 0.0},
    {61.5, 30.0},
    {60.6, 180.0}
  ]

  @doc """
  The under-frequency ride-through envelope as `[{band_hz, allowance_s}]`,
  deepest band first. Single source of truth for the bands.
  """
  def underfrequency_envelope, do: @underfrequency_envelope

  @doc """
  The over-frequency ride-through envelope as `[{band_hz, allowance_s}]`,
  highest band first.
  """
  def overfrequency_envelope, do: @overfrequency_envelope

  @doc """
  Generators whose frequency protection has operated over a frequency
  excursion — PRC-024-shaped under- and over-frequency envelopes.

  Pure: no database, no process state, no randomness. The cascade wires this
  into a step (ROADMAP item 15 / wave 2); tests drive it from trajectories
  directly.

  ## Parameters

  - `trajectory_or_summary` — either
    * a `PowerModel.Solver.Frequency` trajectory (list of `%{time:,
      frequency:, ...}` records), from which time-in-band is integrated, or
    * a flat-excursion summary `%{frequency_hz: float, duration_s: float}` —
      "the island held this frequency for this long". `duration_s` defaults
      to `0.0`, in which case only the instantaneous bands (below 57.0 Hz,
      above 61.8 Hz) can operate. This is the shape available to callers that
      only have a nadir, e.g. `estimate_frequency/4`.
  - `generators` — generator maps. Units that are offline contribute no trips:
    a machine that is not synchronised has no breaker left to open. "Online"
    is the same test `PowerModel.Solver.Frequency.simulate/3..6` uses to build
    its inertia and governor sets — `capacity_factor > 0 and p_max_mw > 0` —
    so a unit the dispatch left offline is consistently invisible to both.

  ## Returns

  A list of trip maps in the codebase's usual shape, most severe first:

      %{
        component_type: "generator",
        component_id: term(),
        failure_cause: "underfrequency_trip" | "overfrequency_trip",
        details: %{
          band_hz: float(),        # the envelope band whose allowance ran out
          allowance_s: float(),    # how long that band permits
          time_in_band_s: float(), # how long the excursion actually spent there
          frequency_hz: float()    # worst frequency reached on that side
        }
      }

  Each generator appears at most once, reported against the most severe band
  it violated. A unit can trip on only one side of nominal per evaluation:
  when an excursion crosses both (a deep sag answered by an over-correction),
  the under-frequency side is reported, because it happened first.

  ## Monotonicity

  Deeper or longer is never gentler: time-in-band is non-decreasing in both
  excursion depth and excursion duration for every band, so extending or
  deepening an excursion can only trip the same units or more. The property
  test in `test/power_model/failure/protection_test.exs` pins this.
  """
  @spec generator_frequency_trips(list(map()) | map(), list(map())) :: list(map())
  def generator_frequency_trips(trajectory_or_summary, generators) do
    {under_time, over_time, f_min, f_max} = frequency_exposure(trajectory_or_summary)

    under_violation =
      worst_violation(@underfrequency_envelope, under_time, fn band -> f_min <= band end)

    over_violation =
      worst_violation(@overfrequency_envelope, over_time, fn band -> f_max >= band end)

    violation =
      case {under_violation, over_violation} do
        {nil, nil} -> nil
        {nil, over} -> {"overfrequency_trip", over, f_max}
        {under, _} -> {"underfrequency_trip", under, f_min}
      end

    case violation do
      nil ->
        []

      {cause, {band_hz, allowance_s, time_in_band_s}, worst_hz} ->
        generators
        |> Enum.filter(&online?/1)
        |> Enum.map(fn gen ->
          %{
            component_type: "generator",
            component_id: Map.get(gen, :id),
            failure_cause: cause,
            details: %{
              band_hz: band_hz,
              allowance_s: allowance_s,
              time_in_band_s: time_in_band_s,
              frequency_hz: worst_hz
            }
          }
        end)
    end
  end

  # Time spent at or beyond each envelope band, plus the extremes reached.
  # Trajectory form: integrate the dwell time of each sample interval. The
  # interval a sample represents is the gap to the NEXT sample, so the final
  # record contributes nothing — it is the end of the record, not a duration.
  defp frequency_exposure(trajectory) when is_list(trajectory) do
    frequencies = Enum.map(trajectory, & &1.frequency)
    f_min = Enum.min(frequencies, fn -> 60.0 end)
    f_max = Enum.max(frequencies, fn -> 60.0 end)

    intervals =
      trajectory
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> {a.frequency, max(b.time - a.time, 0.0)} end)

    under =
      Map.new(@underfrequency_envelope, fn {band, _allowance} ->
        {band, dwell(intervals, fn f -> f <= band end)}
      end)

    over =
      Map.new(@overfrequency_envelope, fn {band, _allowance} ->
        {band, dwell(intervals, fn f -> f >= band end)}
      end)

    {under, over, f_min, f_max}
  end

  defp frequency_exposure(%{} = summary) do
    f = Map.get(summary, :frequency_hz) || Map.get(summary, :nadir_hz) || 60.0
    duration = Map.get(summary, :duration_s, 0.0)

    under =
      Map.new(@underfrequency_envelope, fn {band, _} ->
        {band, if(f <= band, do: duration, else: 0.0)}
      end)

    over =
      Map.new(@overfrequency_envelope, fn {band, _} ->
        {band, if(f >= band, do: duration, else: 0.0)}
      end)

    {under, over, min(f, 60.0), max(f, 60.0)}
  end

  defp dwell(intervals, in_band?) do
    Enum.reduce(intervals, 0.0, fn {f, dt}, acc ->
      if in_band?.(f), do: acc + dt, else: acc
    end)
  end

  # The envelopes are listed most severe first, so the first band whose
  # allowance is exhausted is the one to report. Shared by the frequency and
  # the voltage envelopes — same `{band, allowance}` shape, same rule.
  #
  # A zero allowance means "not for an instant": REACHING the band operates
  # the protection, whether or not the excursion dwelt there long enough to
  # register a measurable interval. That is what makes the instantaneous bands
  # meaningful for a flat-excursion summary, which carries a frequency but not
  # necessarily a duration.
  defp worst_violation(envelope, time_in_band, reached?) do
    Enum.find_value(envelope, fn {band, allowance} ->
      t = Map.fetch!(time_in_band, band)

      if (allowance == 0.0 and reached?.(band)) or t > allowance do
        {band, allowance, t}
      end
    end)
  end

  # Same online test as the swing model's, so a unit the dispatch left offline
  # is invisible to inertia, governors and protection alike.
  defp online?(gen) do
    (Map.get(gen, :capacity_factor) || 1.0) > 0.0 and (Map.get(gen, :p_max_mw) || 0.0) > 0.0
  end

  # ===========================================================================
  # Generator voltage protection — PRC-024 Attachment 2 (ROADMAP item 20)
  # ===========================================================================

  # Low-voltage ride-through envelope: `{band_pu, allowance_seconds}`, deepest
  # band first. Transcribed from NERC PRC-024 Attachment 2, "Low Voltage Ride
  # Through Duration":
  #
  #     Voltage (pu)   Time (sec)
  #        <0.45          0.15
  #        <0.65          0.30
  #        <0.75          2.00
  #        <0.90          3.00
  #
  # Unlike the frequency envelope's numbers, these ARE a verbatim transcription
  # — the table is printed in the standard rather than drawn only as a curve.
  # The bands are NESTED, not disjoint: a bus at 0.40 pu is below every one of
  # them at once, so all four timers run and the 0.15 s allowance is what
  # binds. Verified against the Attachment 2 table as printed in PRC-024-1
  # through PRC-024-3 (the voltage curve is unchanged across those revisions).
  @undervoltage_envelope [
    {0.45, 0.15},
    {0.65, 0.30},
    {0.75, 2.00},
    {0.90, 3.00}
  ]

  # High-voltage ride-through envelope, same shape, highest band first. From
  # the same attachment's "High Voltage Ride Through Duration":
  #
  #     Voltage (pu)   Time (sec)
  #       >=1.200    Instantaneous trip
  #       >=1.175         0.20
  #       >=1.15          0.50
  #       >=1.10          1.00
  #
  # "Instantaneous trip" is carried as a ZERO allowance, the same encoding the
  # frequency envelopes use for their must-trip bands: reaching 1.20 pu ends
  # the ride-through obligation outright.
  @overvoltage_envelope [
    {1.200, 0.0},
    {1.175, 0.20},
    {1.150, 0.50},
    {1.100, 1.00}
  ]

  # The continuous-operation band, i.e. the region the curves impose no
  # duration limit on at all. Returning here ENDS the excursion — see
  # `advance_voltage_timers/3` for why that is the only thing that resets a
  # timer.
  @voltage_continuous_low 0.90
  @voltage_continuous_high 1.100

  @doc """
  The low-voltage ride-through envelope as `[{band_pu, allowance_s}]`, deepest
  band first. Single source of truth for the bands (PRC-024 Attachment 2).
  """
  def undervoltage_envelope, do: @undervoltage_envelope

  @doc """
  The high-voltage ride-through envelope as `[{band_pu, allowance_s}]`,
  highest band first (PRC-024 Attachment 2).
  """
  def overvoltage_envelope, do: @overvoltage_envelope

  @doc """
  The continuous-operation voltage band as `{low_pu, high_pu}` — the region
  both envelopes leave unbounded in time, and the only region that resets a
  ride-through timer.
  """
  def continuous_voltage_band, do: {@voltage_continuous_low, @voltage_continuous_high}

  @doc """
  A fresh generator voltage-protection state: nothing has timed, nothing has
  tripped.

  Shape:

      %{
        generators: %{
          generator_id => %{
            lv: %{band_pu => seconds},
            hv: %{band_pu => seconds},
            tripped: boolean(),
            vm_pu: float() | nil
          }
        },
        elapsed_s: float()
      }

  Keyed by GENERATOR id, which is what makes it survive island splits for
  free: see `split_voltage_state/2`.
  """
  @spec fresh_voltage_state() :: map()
  def fresh_voltage_state do
    %{generators: %{}, elapsed_s: 0.0}
  end

  @doc """
  Generators whose PRC-024 voltage protection has operated over one `dt_s`
  segment, and the advanced state.

  The voltage companion to `generator_frequency_trips/2`, and deliberately a
  different shape, because the two protections read different things:

    * Frequency is an ISLAND-WIDE scalar with a trajectory, so the frequency
      function integrates a whole excursion in one pure call and needs no
      state.
    * Voltage is PER BUS and arrives one power-flow solution at a time, so
      the duration has to be accumulated across cascade steps. Hence the
      threaded state and the `dt_s`.

  That difference is also why nothing here trips instantaneously on the low
  side: a bus dipping to 0.70 pu for 100 ms is inside the no-trip zone and
  must not produce an event, however alarming the number looks.

  Pure: no database, no process state, no randomness, no logging.

  ## Parameters

    * `generators` — generator maps with `id` and `bus_id`. Offline units
      contribute no trips, using the same `capacity_factor > 0 and
      p_max_mw > 0` test the swing model and the frequency envelopes use. A
      unit with no `id` cannot be tracked across steps and is skipped.
    * `vm_by_bus` — either a `%{bus_id => vm_pu}` map or a single float
      applied to every generator (the island-wide form, for callers with no
      per-bus solution). A bus MISSING from the map has no measurement: its
      timers are left exactly as they were rather than reset, because a
      missing reading is not a recovered voltage. Same rule
      `PowerModel.Failure.LoadShedding.apply_uvls_with_state/4` uses.
    * `voltage_state` — the state from a previous call, or `nil` to start fresh
    * `dt_s` — simulated seconds this segment advanced

  ## Returns

  `{trips, voltage_state}`. Trips are in the codebase's usual shape, most
  severe first (deepest sag, then highest swell):

      %{
        component_type: "generator",
        component_id: term(),
        failure_cause: "undervoltage_trip" | "overvoltage_trip",
        details: %{
          band_pu: float(),        # the envelope band whose allowance ran out
          allowance_s: float(),    # how long that band permits
          time_in_band_s: float(), # how long the excursion actually spent there
          vm_pu: float()           # the voltage that finished it
        }
      }

  A generator trips at most ONCE: the state records it and later calls skip
  it, so a caller that keeps handing back the same fleet does not re-emit the
  same event every step. When both sides are somehow violated at once, the
  low side is reported — a collapsing voltage is the mechanism that matters.

  ## Timer semantics: cumulative, not continuous

  PRC-024 Attachment 2's "Voltage Ride-Through Curve Clarifications" state
  that the envelope represents the CUMULATIVE voltage duration, and give the
  worked example of a voltage that crosses 1.15 pu, comes back below it, and
  accumulates only the time it was above. So a band's timer is NOT reset by
  the voltage merely climbing out of that band — it holds, and resumes if the
  voltage falls back in.

  What does reset every timer is a return to the continuous-operation band
  (`continuous_voltage_band/0`): at that point the excursion is over and the
  next one starts from zero. This is the opposite convention from the UVLS
  stage timers, which are ordinary definite-time relay elements and drop out
  the moment their threshold clears. Both are right for what they model.
  """
  @spec generator_voltage_trips(list(map()), map() | number(), map() | nil, number()) ::
          {list(map()), map()}
  def generator_voltage_trips(generators, vm_by_bus, voltage_state, dt_s) do
    state = voltage_state || fresh_voltage_state()
    dt = max(dt_s * 1.0, 0.0)

    {gen_states, trips} =
      Enum.reduce(generators, {state.generators, []}, fn gen, {acc, trips} ->
        evaluate_generator_voltage(gen, vm_by_bus, dt, acc, trips)
      end)

    trips = Enum.sort_by(trips, &(-voltage_trip_severity(&1)))

    {trips, %{state | generators: gen_states, elapsed_s: state.elapsed_s + dt}}
  end

  defp evaluate_generator_voltage(gen, vm_by_bus, dt, acc, trips) do
    id = Map.get(gen, :id)
    prior = Map.get(acc, id)

    cond do
      is_nil(id) ->
        {acc, trips}

      prior && prior.tripped ->
        {acc, trips}

      not online?(gen) ->
        {acc, trips}

      true ->
        case bus_voltage(vm_by_bus, Map.get(gen, :bus_id)) do
          nil ->
            # No measurement this segment. Hold the timers untouched.
            {acc, trips}

          vm_pu ->
            advanced = advance_voltage_timers(prior || fresh_voltage_timers(), vm_pu, dt)

            case voltage_violation(advanced, vm_pu) do
              nil ->
                {Map.put(acc, id, advanced), trips}

              {cause, {band_pu, allowance_s, time_in_band_s}} ->
                trip = %{
                  component_type: "generator",
                  component_id: id,
                  failure_cause: cause,
                  details: %{
                    band_pu: band_pu,
                    allowance_s: allowance_s,
                    time_in_band_s: time_in_band_s,
                    vm_pu: vm_pu
                  }
                }

                {Map.put(acc, id, %{advanced | tripped: true}), [trip | trips]}
            end
        end
    end
  end

  defp fresh_voltage_timers do
    %{
      lv: Map.new(@undervoltage_envelope, fn {band, _} -> {band, 0.0} end),
      hv: Map.new(@overvoltage_envelope, fn {band, _} -> {band, 0.0} end),
      tripped: false,
      vm_pu: nil
    }
  end

  # One generator's band timers over one segment.
  #
  # Inside the continuous band the excursion is over and everything resets;
  # outside it, every band the voltage is currently in accumulates `dt` and
  # every band it is not in HOLDS its accumulated total (the cumulative rule).
  defp advance_voltage_timers(timers, vm_pu, dt) do
    if vm_pu >= @voltage_continuous_low and vm_pu < @voltage_continuous_high do
      fresh = fresh_voltage_timers()
      %{timers | lv: fresh.lv, hv: fresh.hv, vm_pu: vm_pu}
    else
      %{
        timers
        | lv: accumulate_bands(timers.lv, @undervoltage_envelope, dt, &(vm_pu < &1)),
          hv: accumulate_bands(timers.hv, @overvoltage_envelope, dt, &(vm_pu >= &1)),
          vm_pu: vm_pu
      }
    end
  end

  defp accumulate_bands(times, envelope, dt, in_band?) do
    Map.new(envelope, fn {band, _allowance} ->
      elapsed = Map.get(times, band, 0.0)
      {band, if(in_band?.(band), do: elapsed + dt, else: elapsed)}
    end)
  end

  defp voltage_violation(timers, vm_pu) do
    under = worst_violation(@undervoltage_envelope, timers.lv, &(vm_pu < &1))
    over = worst_violation(@overvoltage_envelope, timers.hv, &(vm_pu >= &1))

    case {under, over} do
      {nil, nil} -> nil
      {nil, over_violation} -> {"overvoltage_trip", over_violation}
      {under_violation, _} -> {"undervoltage_trip", under_violation}
    end
  end

  # How far from nominal the REPORTED band sits, so the worst sag sorts ahead
  # of the worst swell rather than the two interleaving by insertion order.
  defp voltage_trip_severity(%{failure_cause: "undervoltage_trip", details: %{band_pu: band}}),
    do: 1.0 - band

  defp voltage_trip_severity(%{details: %{band_pu: band}}), do: band - 1.0

  defp bus_voltage(voltages, _bus_id) when is_number(voltages), do: voltages * 1.0
  defp bus_voltage(voltages, bus_id) when is_map(voltages), do: Map.get(voltages, bus_id)
  defp bus_voltage(_voltages, _bus_id), do: nil

  @doc """
  Restrict a voltage state to a set of generator ids — the SPLIT half of
  island-state threading.

  Voltage ride-through timers are keyed by generator and are INTENSIVE: "this
  machine has been below 0.65 pu for 0.2 s" is a property of the machine, not
  a quantity to be shared out. So unlike the frequency state's cumulative
  megawatts (which `PowerModel.Failure.Cascade` apportions by load share when
  an island splits), these need no scaling at all — partitioning by key is the
  whole operation, and every timer is conserved exactly.

  Accepts a list, `MapSet` or map of generator ids.
  """
  @spec split_voltage_state(map() | nil, Enumerable.t()) :: map()
  def split_voltage_state(nil, _generator_ids), do: fresh_voltage_state()

  def split_voltage_state(state, generator_ids) do
    keep = MapSet.new(generator_ids)

    %{
      state
      | generators: Map.filter(state.generators, fn {id, _} -> MapSet.member?(keep, id) end)
    }
  end

  @doc """
  Combine voltage states from islands that have re-joined — the MERGE half.

  Islands partition the generator set, so in normal use no key appears twice.
  A collision is resolved deterministically anyway: a unit recorded as tripped
  stays tripped, and otherwise the entry that has timed the longest wins, so
  merging can never hand a generator BACK ride-through allowance it has
  already spent.

  `elapsed_s` takes the maximum rather than the sum: it is a clock, not a
  tally.
  """
  @spec merge_voltage_states(list(map() | nil)) :: map()
  def merge_voltage_states(states) do
    states
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(fresh_voltage_state(), fn state, acc ->
      %{
        generators: Map.merge(acc.generators, state.generators, &merge_voltage_timers/3),
        elapsed_s: max(acc.elapsed_s, Map.get(state, :elapsed_s, 0.0))
      }
    end)
  end

  defp merge_voltage_timers(_id, a, b) do
    cond do
      a.tripped -> a
      b.tripped -> b
      max_timer(a) >= max_timer(b) -> a
      true -> b
    end
  end

  defp max_timer(timers) do
    (Map.values(timers.lv) ++ Map.values(timers.hv)) |> Enum.max(fn -> 0.0 end)
  end

  # ---------------------------------------------------------------------------
  # Grid-following inverter current limiting (ROADMAP item 20)
  # ---------------------------------------------------------------------------

  # Terminal voltage below which a grid-following inverter can no longer push
  # its dispatched power through its current ceiling.
  # Momentary current ceiling of a grid-following inverter, per unit of its
  # rated current. This is the ONE constant the derate is parameterized on, and
  # the knee falls out of it rather than being set independently.
  #
  # 1.2 pu is this model's documented default, in the same convention as the
  # UVLS stage table: utility inverter designs commonly sit in the 1.1–1.35 pu
  # band for short-duration current, no value is canonical, and the number
  # lives only here. IEEE 2800-2022 sets ride-through and current-injection
  # DUTIES for transmission-connected IBRs without fixing a universal ceiling —
  # the ceiling is a manufacturer design parameter, so there is nothing to
  # transcribe the way PRC-024's curve could be transcribed.
  #
  # Why this rather than the salvaged model's fixed 0.70 pu knee: a 0.70 knee
  # implies a 1/0.70 ≈ 1.43 pu ceiling for a fully-loaded unit, which flatters
  # inverters exactly where the voltage-collapse feedback loop is decided.
  @gfl_current_limit_pu 1.2

  # EIA-860 fuel codes whose plant is inverter-coupled. SUN and WND are the
  # fleet this matters for; MWH/BAT are batteries, which are inverter-coupled
  # in exactly the same way.
  #
  # The salvaged pre-reset model listed `AB` here too. That is agricultural
  # byproduct — a conventional steam plant with a real rotor — and it is
  # deliberately NOT carried over.
  @inverter_fuel_types ~w(SUN WND MWH BAT PV)

  @doc """
  The default grid-following current ceiling, per unit of rated current.
  Single source of truth; `gfl_available_fraction/2` takes `:current_limit_pu`
  as an override.
  """
  def gfl_current_limit_pu, do: @gfl_current_limit_pu

  @doc """
  Terminal voltage (pu) at which the current ceiling starts to bind, for a unit
  loaded at `p_set_pu` of its rating (default: fully loaded).

  Derived, not set: `knee = P_set / I_max`, so the default ceiling of 1.2 pu
  puts a fully-loaded unit's knee at `1 / 1.2 ≈ 0.833` pu. A unit at half
  output does not reach its knee until 0.417 pu, which is the whole point of
  parameterizing on the ceiling — a lightly-loaded inverter really does ride
  much lower voltages before anything binds.
  """
  def gfl_knee_pu(p_set_pu \\ 1.0, opts \\ []) do
    i_max = Keyword.get(opts, :current_limit_pu, @gfl_current_limit_pu)

    if i_max <= 0.0, do: 0.0, else: p_set_pu / i_max
  end

  @doc """
  Is this generator inverter-coupled, by EIA-860 fuel code?

  A generator carrying an explicit `:inverter_based` boolean is believed over
  its fuel code, so a caller with better information (a synchronous-condenser
  conversion, a Type-3 wind machine) can say so.
  """
  def inverter_based?(gen) do
    case Map.get(gen, :inverter_based) do
      nil -> String.upcase(to_string(Map.get(gen, :fuel_type) || "")) in @inverter_fuel_types
      flag -> !!flag
    end
  end

  @doc """
  The fraction of its dispatched active power a grid-following inverter can
  still deliver at terminal voltage `vm_pu`.

  An inverter is a current source behind a ceiling. Holding P as the terminal
  voltage falls means raising current, and once the ceiling binds the
  deliverable power follows the voltage down:

      P_available = min(P_set, V · I_max)

  ## Ceiling form — the default

      fraction = min(1.0, V · I_max / P_set)

  parameterized on the current ceiling (`:current_limit_pu`, default
  `gfl_current_limit_pu/0` = 1.2 pu) and the unit's loading (`:p_set_pu`, a
  fraction of rating, default `1.0`). The knee is DERIVED — `P_set / I_max`,
  so 0.833 pu for a fully-loaded unit — which is why a lightly-loaded inverter
  correctly rides much lower voltages before anything binds, and why a unit
  somehow dispatched above its ceiling is derated even at nominal voltage.
  Continuous at the knee by construction.

  ## Knee form — opt in with `:knee_pu`

  Passing `:knee_pu` selects the salvaged pre-reset model's shape instead:
  `1.0` at or above the knee and `V / knee` below it, with the knee set flat
  rather than derived from loading. `knee_pu: 0.70` reproduces the salvaged
  behaviour exactly. It is kept reachable because it is the shape the prior
  architecture was tuned against, not because it is the better physics: a flat
  0.70 knee implies a 1.43 pu ceiling for every unit whatever its loading.

  `:knee_pu` wins if both it and `:current_limit_pu` are passed — the form is
  chosen by which parameterization the caller names.

  ## This is a quasi-steady approximation

  It is a power-flow-timescale statement about what an inverter can deliver
  at a held terminal voltage. It is NOT a transient model: it says nothing
  about the fault-ride-through current waveform, nothing about reactive-current
  priority (real 1547-2018/PRC-029 units divert active-current headroom to
  dynamic voltage support below roughly 0.9 pu, which this ignores), and
  nothing about recovery ramp rates after the voltage returns. Use it to
  answer "how much P is this island actually getting while the voltage sits
  here", not "what did the inverter do in the first three cycles".

  Returns `1.0` for any voltage at or above the knee, and clamps at `0.0`.
  """
  @spec gfl_available_fraction(number(), keyword()) :: float()
  def gfl_available_fraction(vm_pu, opts \\ []) do
    v = max(vm_pu * 1.0, 0.0)

    case Keyword.get(opts, :knee_pu) do
      nil ->
        i_max = Keyword.get(opts, :current_limit_pu, @gfl_current_limit_pu)
        p_set = Keyword.get(opts, :p_set_pu, 1.0)

        if p_set <= 0.0, do: 1.0, else: min(1.0, v * i_max / p_set)

      knee ->
        if knee <= 0.0 or v >= knee, do: 1.0, else: v / knee
    end
  end

  @doc """
  Available-power fractions for the inverter-based units in a fleet, as
  `%{generator_id => fraction}`.

  Only inverter-coupled units (`inverter_based?/1`) appear; a synchronous
  machine has no current ceiling of this kind and is simply absent, so read
  the result with `Map.get(fractions, id, 1.0)`.

  A generator whose bus is missing from `vm_by_bus` is also absent — no
  measurement, no derate — for the same reason
  `generator_voltage_trips/4` holds its timers.

  ## Landmine for the caller

  This derates DISPATCHED power. `PowerModel.Dispatch` places onsite
  (non-`utility_scale`) solar and wind OUTSIDE the EIA-930 fuel-anchored pool,
  so those units' MW were never measured against a BA target. Derating them
  changes an island's generation without changing any dispatch target, which
  is correct physically but will not show up in any fuel-mix comparison.
  Decide deliberately which pool is being derated; `:only` narrows it.

  ## Options

    * `:only` — a predicate on the generator map, applied on top of
      `inverter_based?/1` (e.g. `& &1.utility_scale`)
    * any option `gfl_available_fraction/2` accepts
  """
  @spec gfl_derate(list(map()), map() | number(), keyword()) :: map()
  def gfl_derate(generators, vm_by_bus, opts \\ []) do
    {only, fraction_opts} = Keyword.pop(opts, :only)

    generators
    |> Enum.filter(fn gen -> inverter_based?(gen) and (is_nil(only) or only.(gen)) end)
    |> Enum.reduce(%{}, fn gen, acc ->
      id = Map.get(gen, :id)

      case {id, bus_voltage(vm_by_bus, Map.get(gen, :bus_id))} do
        {nil, _} -> acc
        {_, nil} -> acc
        {id, vm_pu} -> Map.put(acc, id, gfl_available_fraction(vm_pu, fraction_opts))
      end
    end)
  end

  defp component_type_string(:line), do: "transmission_line"
  defp component_type_string(:transformer), do: "transformer"
  defp component_type_string(other) when is_binary(other), do: other
  defp component_type_string(other), do: Atom.to_string(other)

  @doc """
  IEC 60255-151 standard-inverse overcurrent trip time with TMS = 1 by default.
  Returns the trip time in seconds for a given loading percentage.
  """
  def overcurrent_trip_time(loading_pct, k \\ 0.14) do
    if loading_pct <= 100.0 do
      :infinity
    else
      ratio = loading_pct / 100.0
      k / (:math.pow(ratio, 0.02) - 1.0)
    end
  end

  # ===========================================================================
  # Mho distance relays — zones 1/2/3 + PRC-023 load blinder (ROADMAP item 20)
  # ===========================================================================

  # Zone reaches as a multiple of the protected line's own series impedance.
  #
  # Zone 1 underreaches deliberately: it must never see past the remote bus,
  # because it has no coordinating delay to lose the race with. 80–85% of the
  # line is the usual setting, the margin covering line-parameter and CT/PT
  # error.
  #
  # Zone 2 overreaches to cover the far end of the line that zone 1 gives up,
  # and is delayed so the remote line's own zone 1 clears an adjacent fault
  # first. 120–150% is the usual band.
  @zone1_reach 0.85
  @zone2_reach 1.25

  # Zone 3 is remote backup: the protected line PLUS the longest line leaving
  # the remote bus, with a margin. This is the zone that made 2003 — its reach
  # is long enough that heavy load can look like a fault, which is exactly what
  # the PRC-023 blinder below exists to prevent.
  @zone3_margin 1.2

  # Intentional time delays, seconds. Zone 1 carries no coordination delay at
  # all; its number is physical operate time — roughly one cycle of relay
  # decision plus two of breaker interruption at 60 Hz. Zones 2 and 3 carry
  # real coordination timers.
  @zone_delays %{1 => 0.05, 2 => 0.40, 3 => 1.50}

  # PRC-023-4 R1 criterion 1: a load-responsive phase protection system must
  # not operate at or below 150% of the highest seasonal facility rating, at
  # 0.85 pu voltage and a 30° power-factor angle.
  @blinder_loadability 1.5
  @blinder_voltage_pu 0.85
  @blinder_angle_deg 30.0

  @default_base_mva 100.0

  @doc """
  Zone reach multiples and intentional delays, as
  `%{zone1_reach:, zone2_reach:, zone3_margin:, delays_s: %{1 => .., 2 => .., 3 => ..}}`.

  Single source of truth for the settings; `distance_zone/3` accepts the same
  keys as overrides.
  """
  def distance_settings do
    %{
      zone1_reach: @zone1_reach,
      zone2_reach: @zone2_reach,
      zone3_margin: @zone3_margin,
      delays_s: @zone_delays
    }
  end

  @doc """
  Apparent impedance `{r_pu, x_pu}` seen looking into the line from the FROM
  terminal, computed from the terminal voltage magnitude and the branch flow.

  From `S = V · I*`,

      Z = V / I = |V|² / S*  =  |V|² · (P + jQ) / (P² + Q²)

  so the relay's measurement depends on the voltage MAGNITUDE and the flow
  only — the bus angle cancels, which is why this is usable straight out of a
  power-flow solution without reconstructing phasors.

  ## Units

  `vm_pu` per unit; `p_pu` and `q_pu` per unit on the same base (100 MVA
  system base unless the caller says otherwise — see
  `apparent_impedance_mva/4` for the MW/MVAr form). The result is per unit on
  that base's impedance base, directly comparable to a line's `r_pu`/`x_pu`.

  ## Sign convention

  P and Q flow OUT of the from-bus INTO the branch. A fault ahead of the relay
  draws lagging current, putting Z in the first quadrant near the line angle.
  Reverse flow gives a negative R, which no forward mho circle contains — the
  characteristic is inherently directional and needs no extra test.

  Returns `:infinite` when there is no flow at all: no current means no
  measurable impedance, not a zero one.
  """
  @spec apparent_impedance(number(), number(), number()) :: {float(), float()} | :infinite
  def apparent_impedance(vm_pu, p_pu, q_pu) do
    s_sq = p_pu * p_pu + q_pu * q_pu

    if s_sq <= 0.0 do
      :infinite
    else
      v_sq = vm_pu * vm_pu * 1.0
      {v_sq * p_pu / s_sq, v_sq * q_pu / s_sq}
    end
  end

  @doc """
  `apparent_impedance/3` for callers holding MW/MVAr rather than per unit.

  `base_mva` is the system base the voltage is per-unit on (default 100 MVA).
  """
  @spec apparent_impedance_mva(number(), number(), number(), number()) ::
          {float(), float()} | :infinite
  def apparent_impedance_mva(vm_pu, p_mw, q_mvar, base_mva \\ @default_base_mva) do
    if base_mva <= 0.0 do
      :infinite
    else
      apparent_impedance(vm_pu, p_mw / base_mva, q_mvar / base_mva)
    end
  end

  @doc """
  `Z = V / I` from rectangular phasors `{re, im}`, for callers that already
  have the current (a fault study, or a solver that returns branch currents).

  Both phasors must be per unit on the same base. Returns `:infinite` on zero
  current.
  """
  @spec apparent_impedance_phasor({number(), number()}, {number(), number()}) ::
          {float(), float()} | :infinite
  def apparent_impedance_phasor({v_re, v_im}, {i_re, i_im}) do
    i_sq = i_re * i_re + i_im * i_im

    if i_sq <= 0.0 do
      :infinite
    else
      {(v_re * i_re + v_im * i_im) / i_sq, (v_im * i_re - v_re * i_im) / i_sq}
    end
  end

  @doc "Magnitude of an impedance `{r, x}`."
  def impedance_magnitude({r, x}), do: :math.sqrt(r * r + x * x)

  @doc """
  Angle of an impedance `{r, x}` in degrees, in `(-180, 180]`.

  For an apparent impedance this equals the power-factor angle of the flow,
  which is what the PRC-023 blinder is stated in terms of.
  """
  def impedance_angle_deg({r, x}), do: :math.atan2(x, r) * 180.0 / :math.pi()

  @doc """
  The three mho reach impedances for a line, as `%{1 => z, 2 => z, 3 => z}`.

  Each reach is a complex impedance along the line's own angle — the relay
  characteristic angle of a self-polarized mho element is set to the protected
  line's impedance angle, so a fault anywhere on the line sits on the circle's
  diameter.

  Zone 3's reach is `margin × (|Z_line| + |Z_adjacent|)` in magnitude, still at
  the line angle. Pass `:z_adjacent` as the LONGEST line leaving the remote
  bus; it defaults to the protected line itself, which is what a screening
  pass with no adjacency data can honestly assume.

  ## Options

    * `:z_adjacent` — `{r_pu, x_pu}` of the longest adjacent line
    * `:zone1_reach`, `:zone2_reach`, `:zone3_margin` — override the settings
      in `distance_settings/0`
  """
  @spec mho_reaches({number(), number()}, keyword()) :: map()
  def mho_reaches({r, x} = z_line, opts \\ []) do
    z1 = Keyword.get(opts, :zone1_reach, @zone1_reach)
    z2 = Keyword.get(opts, :zone2_reach, @zone2_reach)
    margin = Keyword.get(opts, :zone3_margin, @zone3_margin)
    z_adjacent = Keyword.get(opts, :z_adjacent) || z_line

    mag = impedance_magnitude(z_line)

    # Zone 3 as a multiple of the line, so the angle is preserved by the same
    # scalar multiplication the other zones use. A degenerate zero-impedance
    # line has no angle to preserve and no reach worth setting.
    zone3_multiple =
      if mag > 0.0 do
        margin * (mag + impedance_magnitude(z_adjacent)) / mag
      else
        0.0
      end

    %{
      1 => {z1 * r, z1 * x},
      2 => {z2 * r, z2 * x},
      3 => {zone3_multiple * r, zone3_multiple * x}
    }
  end

  @doc """
  Is `z` inside the mho circle of reach `z_reach`?

  The self-polarized mho characteristic is the circle with the origin and
  `z_reach` as the ends of a diameter, i.e. centre `z_reach/2` and radius
  `|z_reach|/2`:

      |Z - Z_r/2| <= |Z_r|/2

  A zero reach is a degenerate point at the origin and contains nothing.
  """
  @spec inside_mho?({number(), number()} | :infinite, {number(), number()}) :: boolean()
  def inside_mho?(:infinite, _z_reach), do: false

  def inside_mho?({r, x}, {rr, rx}) do
    radius = impedance_magnitude({rr, rx}) / 2.0

    if radius <= 0.0 do
      false
    else
      dr = r - rr / 2.0
      dx = x - rx / 2.0
      :math.sqrt(dr * dr + dx * dx) <= radius
    end
  end

  @doc """
  The PRC-023-4 loadability impedance magnitude, in per unit.

  NERC PRC-023-4 Requirement R1 criterion 1: a load-responsive phase
  protection system must not operate at or below 150% of the highest seasonal
  facility rating, evaluated at 0.85 pu voltage and a 30° power-factor angle.
  The impedance the relay sees at that operating point is

      |Z| = V² / S = 0.85² / (1.5 · S_rating_pu)

  and the relay must stay clear of everything AT OR BEYOND it on the load
  side. Lighter load means larger apparent impedance, so the standard's point
  is the CLOSEST-IN load condition the relay has to tolerate.

  Returns `:infinity` for an unrated branch — nothing is known to be load, so
  nothing is excluded.

  ## Options

    * `:base_mva` — system base for the per-unit conversion (default 100.0)
    * `:loadability_factor` — default 1.5
    * `:blinder_voltage_pu` — default 0.85
  """
  @spec loadability_limit_pu(number() | nil, keyword()) :: float() | :infinity
  def loadability_limit_pu(rating_mva, opts \\ [])

  def loadability_limit_pu(rating_mva, opts) when is_number(rating_mva) and rating_mva > 0 do
    base_mva = Keyword.get(opts, :base_mva, @default_base_mva)
    factor = Keyword.get(opts, :loadability_factor, @blinder_loadability)
    v = Keyword.get(opts, :blinder_voltage_pu, @blinder_voltage_pu)

    rating_pu = rating_mva / base_mva

    if base_mva > 0.0 and factor > 0.0 do
      v * v / (factor * rating_pu)
    else
      :infinity
    end
  end

  def loadability_limit_pu(_rating_mva, _opts), do: :infinity

  @doc """
  Highest-rating loadability limit for a branch record, using
  `PowerModel.Grid.Ratings.branch_ratings/1`.

  PRC-023 is stated against the HIGHEST seasonal facility rating, so the
  short-time emergency rating (rate C) is the basis here, not the continuous
  rate A the display uses. Falls back through the tiers a branch actually has.
  """
  @spec branch_loadability_limit_pu(map(), keyword()) :: float() | :infinity
  def branch_loadability_limit_pu(branch, opts \\ []) do
    {rate_a, rate_b, rate_c} = Ratings.branch_ratings(branch)

    highest =
      [rate_c, rate_b, rate_a]
      |> Enum.filter(&(is_number(&1) and &1 > 0))
      |> Enum.max(fn -> nil end)

    loadability_limit_pu(highest, opts)
  end

  @doc """
  The exact PRC-023-4 loadability test point as an impedance `{r_pu, x_pu}`:
  the loadability limit magnitude at the 30° blinder angle.

  This is the point the standard says a relay must not trip on. It exists so
  callers and tests can name it rather than re-deriving it.
  """
  @spec prc023_load_point(number() | nil, keyword()) :: {float(), float()} | :infinite
  def prc023_load_point(rating_mva, opts \\ []) do
    case loadability_limit_pu(rating_mva, opts) do
      :infinity ->
        :infinite

      mag ->
        theta = Keyword.get(opts, :blinder_angle_deg, @blinder_angle_deg) * :math.pi() / 180.0
        {mag * :math.cos(theta), mag * :math.sin(theta)}
    end
  end

  @doc """
  Is this apparent impedance LOAD rather than a fault, per the PRC-023-4
  blinder?

  Load is the region at or beyond the loadability limit magnitude and within
  the blinder angle of the resistance axis: heavy real power at a plausible
  power factor. A fault is close in and near the line angle (70–85° for
  transmission), so it satisfies neither condition — the two regions do not
  overlap, which is why the blinder can be applied to every zone without
  blinding the relay to real faults.

  The boundary is inclusive on both tests, so the standard's own 150%/0.85
  pu/30° point is excluded, as PRC-023 requires. Load HEAVIER than that point
  (smaller |Z|) is outside the required loadability envelope and is not
  blocked; the standard sets a floor on loadability, not a licence to ignore
  every load condition.
  """
  @spec load_encroachment?({number(), number()} | :infinite, number() | nil, keyword()) ::
          boolean()
  def load_encroachment?(z, rating_mva, opts \\ [])

  def load_encroachment?(:infinite, _rating_mva, _opts), do: false

  def load_encroachment?(z, rating_mva, opts) do
    case loadability_limit_pu(rating_mva, opts) do
      :infinity ->
        false

      limit ->
        blinder_deg = Keyword.get(opts, :blinder_angle_deg, @blinder_angle_deg)

        impedance_magnitude(z) >= limit and abs(impedance_angle_deg(z)) <= blinder_deg
    end
  end

  @doc """
  Evaluate a mho distance relay: which zone (if any) an apparent impedance
  falls in, and the delay that zone carries.

  Pure. The caller turns `delay_s` into trip timing — the cascade's existing
  relay-duty accumulator integrates `dt / delay_s` the same way it does for
  the inverse-time overcurrent elements.

  ## Parameters

    * `z_apparent` — `{r_pu, x_pu}` from `apparent_impedance/3`, or `:infinite`
    * `z_line` — the protected line's series impedance `{r_pu, x_pu}`
    * `opts` — `:z_adjacent`, `:rating_mva` (enables the blinder), plus any
      key `mho_reaches/2` or `loadability_limit_pu/2` accepts, and
      `:delays_s` to override the zone timers

  ## Returns

      %{
        zone: 1 | 2 | 3 | nil,          # the zone that will trip
        delay_s: float() | :infinity,   # its delay
        zone_reached: 1 | 2 | 3 | nil,  # the zone the characteristic saw
        blocked: boolean(),             # ...but the blinder held it
        block_reason: nil | :prc023_load_blinder,
        z_pu: {float(), float()} | :infinite,
        z_mag_pu: float() | :infinity,
        z_angle_deg: float() | nil,
        reaches: %{1 => {float(), float()}, ...},
        loadability_limit_pu: float() | :infinity
      }

  `zone` is `nil` whenever nothing operates, whether because the impedance is
  outside every circle or because the blinder blocked it; `zone_reached` and
  `blocked` say which of the two happened, which is what makes a load-driven
  near-miss visible in a cascade log instead of silent.

  > #### Supersedes the heuristic {: .info}
  >
  > `check_zone3_encroachment/6` is the loading-and-voltage HEURISTIC the
  > cascade uses today, because there was no AC solution to measure an
  > impedance from. This function is the real characteristic. They are not
  > interchangeable: the heuristic is probabilistic and needs no impedance,
  > this one is deterministic and needs one.
  """
  @spec distance_zone({number(), number()} | :infinite, {number(), number()}, keyword()) :: map()
  def distance_zone(z_apparent, z_line, opts \\ []) do
    reaches = mho_reaches(z_line, opts)
    delays = Keyword.get(opts, :delays_s, @zone_delays)
    rating_mva = Keyword.get(opts, :rating_mva)
    limit = loadability_limit_pu(rating_mva, opts)

    zone_reached =
      Enum.find([1, 2, 3], fn zone -> inside_mho?(z_apparent, Map.fetch!(reaches, zone)) end)

    blocked? = zone_reached != nil and load_encroachment?(z_apparent, rating_mva, opts)
    zone = if blocked?, do: nil, else: zone_reached

    %{
      zone: zone,
      delay_s: if(zone, do: Map.get(delays, zone, :infinity), else: :infinity),
      zone_reached: zone_reached,
      blocked: blocked?,
      block_reason: if(blocked?, do: :prc023_load_blinder),
      z_pu: z_apparent,
      z_mag_pu: magnitude_or_infinity(z_apparent),
      z_angle_deg: angle_or_nil(z_apparent),
      reaches: reaches,
      loadability_limit_pu: limit
    }
  end

  defp magnitude_or_infinity(:infinite), do: :infinity
  defp magnitude_or_infinity(z), do: impedance_magnitude(z)

  defp angle_or_nil(:infinite), do: nil
  defp angle_or_nil(z), do: impedance_angle_deg(z)

  @doc """
  Distance-relay pickups across a set of branches, in the codebase's usual
  trip-map shape. Pure — the caller decides what to do with the timing.

  ## Input

  A list of per-branch maps:

      %{
        component_type: :line | :transformer | String.t(),
        component_id: term(),
        z_line: {r_pu, x_pu},               # required
        z_apparent: {r_pu, x_pu},           # or vm_pu + p_pu + q_pu
        vm_pu: float(), p_pu: float(), q_pu: float(),
        z_adjacent: {r_pu, x_pu} | nil,     # longest line off the remote bus
        rating_mva: float() | nil           # highest rating, arms the blinder
      }

  ## Output

  One map per picked-up branch, fastest zone first:

      %{
        component_type: "transmission_line",
        component_id: id,
        failure_cause: "distance_zone1" | "distance_zone2" | "distance_zone3",
        details: %{zone:, delay_s:, r_pu:, x_pu:, z_mag_pu:, z_angle_deg:,
                   reach_pu:, loadability_limit_pu:}
      }

  Branches the blinder held are NOT returned — a blocked relay does not trip.
  Use `distance_zone/3` directly if the near-misses are wanted.
  """
  @spec distance_relay_trips(list(map()), keyword()) :: list(map())
  def distance_relay_trips(branches, opts \\ []) do
    branches
    |> Enum.map(&evaluate_branch_relay(&1, opts))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.details.delay_s)
  end

  defp evaluate_branch_relay(branch, opts) do
    z_line = Map.get(branch, :z_line)

    with true <- match?({_, _}, z_line),
         z_apparent when z_apparent != :infinite <- branch_apparent_impedance(branch),
         result <-
           distance_zone(z_apparent, z_line, branch_relay_opts(branch, opts)),
         %{zone: zone} when not is_nil(zone) <- result do
      {r, x} = z_apparent

      %{
        component_type: component_type_string(Map.get(branch, :component_type, :line)),
        component_id: Map.get(branch, :component_id),
        failure_cause: "distance_zone#{result.zone}",
        details: %{
          zone: result.zone,
          delay_s: result.delay_s,
          r_pu: r,
          x_pu: x,
          z_mag_pu: result.z_mag_pu,
          z_angle_deg: result.z_angle_deg,
          reach_pu: impedance_magnitude(Map.fetch!(result.reaches, result.zone)),
          loadability_limit_pu: result.loadability_limit_pu
        }
      }
    else
      _ -> nil
    end
  end

  defp branch_relay_opts(branch, opts) do
    opts
    |> Keyword.put_new(:z_adjacent, Map.get(branch, :z_adjacent))
    |> Keyword.put_new(:rating_mva, Map.get(branch, :rating_mva))
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp branch_apparent_impedance(%{z_apparent: z}) when is_tuple(z), do: z

  defp branch_apparent_impedance(%{vm_pu: v, p_pu: p, q_pu: q}),
    do: apparent_impedance(v, p, q)

  defp branch_apparent_impedance(_), do: :infinite

  # ===========================================================================
  # Two-timescale conductor thermal model (ROADMAP item 20)
  # ===========================================================================

  # Simplified IEEE 738 heat balance. The full standard integrates convective,
  # radiative and solar heat transfer against I²R; the simplification here is
  # that, for a fixed ambient and wind, the STEADY-STATE rise above ambient is
  # proportional to I² and the approach to it is first order:
  #
  #     T_ss(m) = T_ambient + ΔT_rated · m²          m = S / rate A
  #     T(t+dt) = T_ss + (T(t) - T_ss) · exp(-dt/τ)
  #
  # The exponential form is the exact solution for constant loading over the
  # step, so it is stable at any dt — the cascade's step sizes vary by orders
  # of magnitude and an Euler update would blow up on the long ones.
  #
  # Design basis: ACSR at a 40 °C ambient, 75 °C continuous (so the conductor
  # sits exactly at its continuous limit at 100% of RATE A — that is what rate
  # A means) and a 100 °C short-time emergency limit. Utility practice varies
  # (75/100 and 100/125 are both common); these are configurable.
  @thermal_ambient_c 40.0
  @thermal_rated_rise_c 35.0
  @thermal_emergency_c 100.0

  # Conductor thermal time constant. ACSR runs roughly 5–20 minutes depending
  # on conductor size and wind speed; 12 minutes is a mid-size transmission
  # conductor in light wind.
  @thermal_tau_s 720.0

  @doc """
  Conductor thermal defaults as a keyword list — `:ambient_c`, `:rated_rise_c`,
  `:emergency_c`, `:tau_s`. Single source of truth; every thermal function
  takes the same keys as overrides.
  """
  def conductor_thermal_defaults do
    [
      ambient_c: @thermal_ambient_c,
      rated_rise_c: @thermal_rated_rise_c,
      emergency_c: @thermal_emergency_c,
      tau_s: @thermal_tau_s
    ]
  end

  @doc """
  A fresh conductor thermal state, sitting at ambient.

  Shape: `%{temp_c:, steady_state_c:, loading_fraction:, elapsed_s:}`. Persist
  it per branch and thread it through `advance_conductor_temperature/4`.
  """
  @spec conductor_thermal_state(keyword()) :: map()
  def conductor_thermal_state(opts \\ []) do
    ambient = Keyword.get(opts, :ambient_c, @thermal_ambient_c)

    %{temp_c: ambient, steady_state_c: ambient, loading_fraction: 0.0, elapsed_s: 0.0}
  end

  @doc """
  Steady-state conductor temperature at a given loading, in °C.

  `loading_fraction` is apparent flow over RATE A — the continuous rating, not
  the rate C relay-pickup basis. Rate A is by definition the current at which
  the conductor settles at its continuous design temperature, which is the
  only anchor this curve has.

  > #### Basis mismatch is the landmine here {: .warning}
  >
  > `PowerModel.Failure.Cascade.trip_loading_pct/1` reports loading on the
  > RATE C basis (rate A ÷ 1.35) because that is where relays pick up. Feeding
  > that number in here understates conductor temperature by the square of
  > 1.35. Convert, or read `loading_pct` (the rate A basis) directly.
  """
  @spec conductor_steady_state_temp_c(number(), keyword()) :: float()
  def conductor_steady_state_temp_c(loading_fraction, opts \\ []) do
    ambient = Keyword.get(opts, :ambient_c, @thermal_ambient_c)
    rise = Keyword.get(opts, :rated_rise_c, @thermal_rated_rise_c)
    m = abs(loading_fraction)

    ambient + rise * m * m
  end

  @doc """
  Advance a conductor's temperature by `dt_s` at a constant `loading_fraction`.

  This is the SLOW timescale of ROADMAP item 20. The cascade's existing
  IEC 60255-151 duty integral is the fast one: it decides, in seconds, whether
  a relay operates on an overload. This decides, in tens of minutes, whether
  the conductor itself reaches an emergency temperature — the sag-and-contact
  mechanism that took out the Ohio lines in 2003 with no relay involvement at
  all. The two mechanisms answer different questions and must both be run;
  neither substitutes for the other.

  Passing `nil` as the state starts from ambient.
  """
  @spec advance_conductor_temperature(map() | nil, number(), number(), keyword()) :: map()
  def advance_conductor_temperature(state, loading_fraction, dt_s, opts \\ []) do
    state = state || conductor_thermal_state(opts)
    tau = Keyword.get(opts, :tau_s, @thermal_tau_s)
    target = conductor_steady_state_temp_c(loading_fraction, opts)
    dt = max(dt_s * 1.0, 0.0)

    temp =
      if tau > 0.0 do
        target + (state.temp_c - target) * :math.exp(-dt / tau)
      else
        target
      end

    %{
      state
      | temp_c: temp,
        steady_state_c: target,
        loading_fraction: loading_fraction * 1.0,
        elapsed_s: state.elapsed_s + dt
    }
  end

  @doc """
  Has the conductor reached its emergency temperature?

  This is the thermal trip predicate: at the emergency limit the utility's
  clearance and annealing basis is exhausted and the line must come out,
  regardless of what any overcurrent relay thinks.
  """
  @spec conductor_overtemperature?(map(), keyword()) :: boolean()
  def conductor_overtemperature?(%{temp_c: temp}, opts \\ []) do
    temp >= Keyword.get(opts, :emergency_c, @thermal_emergency_c)
  end

  @doc """
  Seconds until a conductor at `state` reaches its emergency temperature if
  `loading_fraction` is held, or `:infinity` if it never does.

  Inverting the first-order response,

      t = -τ · ln((T_ss - T_limit) / (T_ss - T_0))

  Returns `0.0` if it is already there. `:infinity` when the steady state sits
  at or below the limit — which is the whole point of a two-timescale model:
  sustained loading below about 131% of rate A (the point where 35 · m² first
  exceeds a 60 °C rise) NEVER cooks the conductor, however long it lasts, so
  the slow mechanism must not be allowed to trip it.

  Usable as a candidate trip time alongside the cascade's inverse-time relay
  times; the fastest mechanism wins.
  """
  @spec conductor_trip_time_s(map(), number(), keyword()) :: float() | :infinity
  def conductor_trip_time_s(%{temp_c: temp}, loading_fraction, opts \\ []) do
    limit = Keyword.get(opts, :emergency_c, @thermal_emergency_c)
    tau = Keyword.get(opts, :tau_s, @thermal_tau_s)
    target = conductor_steady_state_temp_c(loading_fraction, opts)

    cond do
      temp >= limit -> 0.0
      target <= limit -> :infinity
      tau <= 0.0 -> 0.0
      true -> -tau * :math.log((target - limit) / (target - temp))
    end
  end
end
