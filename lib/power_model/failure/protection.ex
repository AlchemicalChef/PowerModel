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
  """

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
  # allowance is exhausted is the one to report.
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

  defp component_type_string(:line), do: "transmission_line"
  defp component_type_string(:transformer), do: "transformer"
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
end
