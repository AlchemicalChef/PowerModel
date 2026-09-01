defmodule PowerModel.Failure.Cascade do
  @moduledoc """
  Cascading failure simulation engine.

  Implements two realism improvements over a naive simultaneous-trip model:

  1. **Timed cascade** -- Uses inverse-time overcurrent curves to determine
     which overloaded component trips first.  Only that single component is
     removed per step; the power flow is re-solved and remaining overloads
     are re-evaluated (the redistribution may relieve them).

  2. **Generator redispatch** -- After a generator or line trips, the lost
     power is redistributed proportionally among remaining online generators
     based on their available headroom (`p_max_mw - current_dispatch`).
     Only the residual numerical mismatch is left for the DC slack bus.
     When total headroom is insufficient the deficit triggers UFLS.

  ## Initial operating point

  `init/3` prefers the MEASURED unit commitment: given `hour:`, it asks
  `PowerModel.Dispatch` to place each BA's actual EIA-930 per-fuel MW on that
  BA's units. Units the measurement did not need get an explicit `0.0` and are
  OFFLINE for the whole run — `apply_dispatch/2` turns that into
  `p_max_mw = 0.0, capacity_factor = 1.0`, which
  `PowerModel.Solver.Frequency.simulate/5` filters out of its online set, so
  an offline unit contributes zero inertia and zero governor response. The
  explicit zero matters: a generator merely MISSING from the dispatch map
  falls back to `p_max_mw * capacity_factor` here and would come back online
  with full inertia and droop.

  `state.dispatch_source` records which rule produced the operating point
  (`:eia_fuel` or `:proportional`) and `state.dispatch_coverage` carries the
  dispatch coverage report for the measured case.

  ## Behind-the-meter solar (IEEE 1547, ROADMAP item 31)

  The snapshot's `:btm_solar` entries are rooftop PV that is INVISIBLE in the
  operating point: EIA-930 demand is metered net of it, so no generator was
  ever materialized for it (see `PowerModel.Grid.BtmSolar`). The consequence
  for this module is the whole point of the layer — **tripping rooftop is a
  LOAD INCREASE, not a generation loss**. Legacy (IEEE 1547-2003) inverters
  must trip at 59.3 Hz / 0.88 pu, and what they leave behind is the gross
  demand that was always there behind the meter.

  That trip is evaluated per island in the SAME step as UFLS and strictly
  BEFORE it — the vicious pairing item 31 names: the first UFLS stage arms
  below 59.3 Hz while the legacy rooftop fleet is already gone at 59.3 Hz, so
  UFLS opens on a deficit that the trip itself deepened. Modern (1547-2018)
  inverters ride through and are never touched.

  Once tripped, a bus's rooftop stays tripped for the rest of the run: 1547
  mandates a delayed, permissive reconnection that no cascade timescale
  reaches (restoration is ROADMAP item 28). The tripped set is keyed by BUS so
  it survives islands splitting and re-forming underneath it.

  `state.btm_tripped_mw` is an explicit bucket in `balance/1` because this MW
  was never in `original_load_mw` — see that function for the extended
  conservation identity.

  ## The step ordering (ROADMAP items 15 and 20)

  Everything an island does inside one step happens in this order, and the
  order is the model:

  1. **Voltage protection** — the island's AC solution from the END of the
     previous segment is read by the grid-following derate, the IEEE 1547
     rooftop voltage elements and PRC-024 generator ride-through. Rooftop that
     trips is new LOAD, machines that trip are lost GENERATION, and both land
     in this step's deficit before anything else looks at it.
  2. **Reserves** — the ramp-limited tiers (`PowerModel.Failure.Reserves`)
     raise the island's generation as far as the clock allows, with the
     secondary tier fed by the island's own AGC controller.
  3. **Trajectory evaluation** — ONE swing-equation segment, resumed from the
     island's persistent frequency state, for the deficit the reserves left.
  4. **Frequency protection reads that trajectory** — behind-the-meter
     inverters (IEEE 1547) and generator frequency protection (PRC-024) are
     evaluated against the SAME trajectory, so they cannot disagree about what
     the island's frequency did.
  5. **Recompute** — tripped rooftop is new load, tripped generators are lost
     generation; both land in the same step's deficit.
  6. **Residual shed** — UVLS first (its stage timers have already elapsed
     against the voltage measurement), then UFLS (authoritative, re-simulated
     on the changed gap), then the force-shed tier for whatever is left.
  7. **Solve** — DC power flow on the post-shed island feeding thermal and
     conductor protection, plus a QSS-AC attempt whose solution is this
     segment's distance-relay measurement and the NEXT segment's voltage layer.

  Steps 1 and 4 are the positive feedback loop real blackouts run on: an island
  that dips or sags far enough loses generators, which deepens the same step's
  deficit, which sheds more customers. Islands can therefore LOSE generation
  they did not start losing.

  ## The voltage layer (ROADMAP item 20)

  An island gets a voltage layer for a segment only if `PowerModel.Solver.FDPF`
  converged on it at the end of the previous one. There is exactly one writer
  of that field, and it takes a converged AC solution as its argument, so no
  voltage-sensitive protection can be reading the DC solve's flat 1.0 pu —
  which would make the whole layer silently inert and put every DC angle inside
  the PRC-023 blinder wedge.

  **`nil` is the common case at real demand.** REVIEW LIN-13 measured that no
  interconnection has an AC solution there: wherever DC needs more than 90°
  across a branch, no AC solution exists to find. An island without one runs
  exactly as it did before this wave — DC plus the frequency chain — and is
  counted in `voltage_layer` and in one summary log line per cascade.

  ### Why the measurement is a segment old

  A segment's own duration is not known until its trajectory settles, and a
  protection cannot read a solution that has not been produced yet. So each
  segment's voltage timers integrate the time that has ALREADY passed
  (`now - evaluated_at_s`, which is the previous segment's clock advance)
  against the voltage measured at its end. What the island holds now is what it
  held then, until something in this step changes it — and everything that does
  change it is downstream of the reading.

  ## Persistent island frequency state (ROADMAP item 15)

  Each island carries a `PowerModel.Solver.Frequency` state across steps, so a
  second disturbance starts from the depressed frequency, the governor output
  already deployed, and the UFLS stages already spent — instead of restarting
  at 60.0 Hz with fresh reserves. Two trips two steps apart reach a strictly
  worse nadir than either would alone.

  ### Island identity across re-splits

  Islands are not stable objects: a trip splits one into two, a re-close would
  merge them back. A new island **inherits the state of the prior island that
  contributed the plurality of its LOAD**, with bus count as the tiebreak; a
  new island that overlaps NO prior island starts fresh at 60.0 Hz.

  Load is the weight because the frequency state is largely a statement about
  the load base it was integrated against — damping, the UFLS stages already
  spent, the megawatts already shed — so following the load keeps that
  statement true for the largest part of it.

  When one island becomes two, BOTH halves inherit: they were synchronised an
  instant earlier, so they share the frequency, the governor output already
  deployed and the UFLS stages already spent. The cumulative quantities are
  apportioned by load share so a small fragment does not carry the whole
  parent's shed megawatts into its damping base.

  The rule's limits, stated rather than hidden. A split of a fleet mid-swing
  is modelled as two islands each continuing the parent's trajectory, which
  ignores the transient the separation itself causes (the two halves would in
  reality diverge through a period of angular acceleration before settling to
  their own frequencies). And a MERGE — two live islands reconnecting — keeps
  only the winner's state; nothing here re-synchronises islands, so that path
  is unreachable until restoration (ROADMAP item 28) exists.

  ## The clock (REVIEW CAS-16)

  A step advances `simulated_time` by the longer of the two processes that ran
  in it: the relay wall-clock chosen by `advance_relay_timers/2` (unchanged),
  and the frequency-trajectory duration any island actually simulated. That
  duration is the 30 s window, or the trajectory's SETTLING time when it
  settles sooner — in which case the island's own frequency clock is rewound
  to the settling point too, so the two clocks never diverge. Steps whose only
  trips are frequency-driven no longer advance 0 s, which is what makes the
  ramp-limited reserve tiers mean anything.

  The consequence of truncating at the settling point, stated rather than
  hidden: an island that SETTLES at a depressed frequency stops accumulating
  time there, so the generator-protection envelope's long allowances (three
  minutes below 59.4 Hz) can only be exhausted by an excursion that is still
  moving. An island parked at 59.35 Hz will not eventually trip its fleet the
  way PRC-024 says it should. Closing that means a notion of time passing with
  nothing happening, which this cascade does not have.

  ## What a step result carries

  Each element of the list `run_cascade/2` returns (and each value handed to
  its callback) is a map with `step`, `simulated_time`, `islands`, `trips`,
  `water_facility_ids`, `datacenter_ids`, `solution`, `balance` and
  `voltage_layer`, plus four keys describing the state the step left the
  system in:

    * `frequency` — `%{f_hz:, nadir_hz:}`. `f_hz` is the island frequencies
      weighted by the load each island is actually carrying; `nadir_hz` is the
      worst frequency any island reached in this cascade event. Reporting the
      nadir as the current frequency is a specific and tempting bug: a settled
      cascade IS back at 60.00 Hz, and the dip is what it shed on the way.
    * `agc` — one `PowerModel.Controls.AGC.summary/1` per island that has a
      secondary controller, each tagged with `island_id` (the island's lowest
      bus id). Islands without a controller are omitted.
    * `voltage_overlay` — the AC voltage products of the islands whose FDPF
      solve CONVERGED, and nothing about the islands whose did not. This
      channel is structurally partial (`nil` is the common case at real
      demand — see "The voltage layer") and must never be merged into a
      whole-grid metric or averaged with DC results.
    * `termination` — `nil` while the cascade is still running, and on the
      final step the reason it stopped. See `termination/1`.

  `termination` says only why the loop stopped iterating. What it LEFT is a
  separate question with a separate answer, `outcome/1`, read from the final
  state rather than from a step — a cascade that sheds an interconnection to
  nothing and then finds nothing further to trip is `{:settled, :collapsed}`.
  """

  require Logger

  alias PowerModel.Controls.AGC
  alias PowerModel.Dispatch
  alias PowerModel.Grid.{BtmSolar, DcTie, Ratings}
  alias PowerModel.Solver.VoltageControl
  alias PowerModel.Solver.{DCPowerFlow, FDPF, Frequency}
  alias PowerModel.Failure.{Protection, LoadShedding, Reserves}
  alias PowerModel.Simulation.Cascading.IslandDetector

  @max_steps 50

  # How much of an island's frequency response one cascade step integrates.
  # Matches `PowerModel.Solver.Frequency`'s own default window, which is the
  # window its primary-response ceilings are written against.
  @frequency_window_s 30.0

  # A trajectory has SETTLED once every later sample sits within this of the
  # final frequency and no further load has been shed. The step's clock
  # advance is truncated there (see the moduledoc's "The clock").
  @settle_tolerance_hz 1.0e-3

  # How much frequency history an island keeps for generator protection. The
  # deepest PRC-024 allowance is 180 s below 59.4 Hz, so anything older than
  # that can no longer change a verdict.
  @exposure_window_s 180.0

  # Imbalances smaller than this are not worth integrating a swing equation
  # for; they are numerical residue from the reserve arithmetic.
  @imbalance_epsilon_mw 1.0e-6

  # An island is "in an excursion" — and therefore keeps being simulated even
  # with no new imbalance — while its frequency is this far off nominal.
  @excursion_epsilon_hz 1.0e-4

  # IEEE 1547-2003 must-trip frequency for the legacy behind-the-meter fleet.
  # 1547-2018 units are required to ride through it, which is why only the
  # legacy SHARE of each bus's rooftop output is ever at stake here.
  #
  # The 0.88 pu VOLTAGE half of the same standard is NOT evaluated here: it
  # belongs to `PowerModel.Grid.BtmSolar.voltage_trips/5`, which carries the
  # real definite-time elements and the legacy/modern vintage split, and which
  # the QSS-AC layer below feeds with measured bus voltages. Keeping a second,
  # instantaneous 0.88 pu test on this path would trip the same megawatts
  # twice — see `voltage_btm_trip/4` for the guard that keeps the two halves
  # disjoint.
  @btm_trip_frequency_hz 59.3

  # Nominal frequency, used when an island carries no deficit and therefore no
  # under-frequency excursion to evaluate. Matches `Frequency`'s f0.
  @nominal_frequency_hz 60.0

  # Bank sizing basis for the voltage-control layer when `voltage_control:
  # true`: peak-to-reference-hour demand ratio, the same default the
  # loadability census uses (see `Mix.Tasks.Grid.Census.Loadability`).
  @default_peak_multiplier 1.75

  # An island's AC solve is not retried while nothing about the island has
  # changed enough to change the answer. Bus count and branch count are exact;
  # load is compared relatively, because shedding a fraction of a percent does
  # not move a case from infeasible to feasible.
  @ac_retry_load_fraction 0.05

  # Buses outside this band are counted into the island's one voltage-violation
  # summary event. Matches `Protection.check_voltage_violations/3`'s defaults,
  # which this supersedes on AC-solved islands.
  @voltage_alarm_low_pu 0.85
  @voltage_alarm_high_pu 1.15

  # The band the OVERLAY reports a bus as violating in, which is the operator
  # display band and deliberately tighter than the alarm band above: the alarm
  # exists to raise one event per island when things are badly wrong, the
  # overlay exists to colour every bus a converged island has a voltage for.
  @overlay_undervoltage_pu 0.9
  @overlay_overvoltage_pu 1.1

  # Thresholds for `outcome/1` — what the cascade LEFT, as distinct from why it
  # stopped. Documented in full on that function.
  @outcome_collapsed_served_fraction 0.5
  @outcome_degraded_mw 1.0
  @outcome_degraded_fraction 0.001

  defstruct [
    :buses,
    :lines,
    :transformers,
    :generators,
    :loads,
    :dc_ties,
    :water_facilities,
    :datacenters,
    :base_mva,
    :tripped_lines,
    :tripped_generators,
    :tripped_transformers,
    :affected_water_facilities,
    :affected_datacenters,
    :base_overloaded,
    :base_line_categories,
    :base_line_loading,
    :events,
    :step,
    :stable,
    :solution,
    :simulated_time,
    :dispatch,
    :dispatch_source,
    :dispatch_coverage,
    :bus_ba,
    :original_load_mw,
    :shed_load_mw,
    :blackout_load_mw,
    :btm_by_bus,
    :btm_tripped_buses,
    :btm_tripped_mw,
    # Why this cascade STOPPED, machine-readable, and `nil` while it is still
    # running: `:settled` (nothing left to trip), `:budget_exhausted` (the
    # @max_steps clause — a TRUNCATED run, never a settled equilibrium) or
    # `:solve_failed` (an island's numerical solve failed and the run is
    # terminal). Callers presenting a final state must distinguish these:
    # `stable: false` alone cannot tell a collapse from a truncation.
    :termination,
    # Worst instantaneous frequency any island has reached in THIS cascade
    # event, in Hz. Rebased at each manual trip to where the system already
    # sits (see `begin_cascade_event/1`), so it can never read above the
    # current frequency.
    frequency_nadir_hz: @nominal_frequency_hz,
    relay_duty: %{},
    # One record per island of the CURRENT topology — see `island_record/0`.
    island_states: [],
    # Transient governor MW inside `dispatch`, per generator (ROADMAP item 16).
    # `dispatch[id] - primary_reserve[id]` is the unit's SUSTAINED output, and
    # that is what the swing model is told about.
    primary_reserve: %{},
    # `%{bus_id => %{legacy_mw:, modern_mw:}}` — the rooftop fleet split by
    # inverter vintage, which is what the 1547 VOLTAGE protection needs.
    # `btm_by_bus` above is the legacy-only view the 59.3 Hz frequency
    # must-trip reads; the two are gated against each other, never summed.
    btm_fleet_by_bus: %{},
    # Cause-tagged refinement of `btm_tripped_mw`: `%{frequency_mw:,
    # voltage_mw:, total_mw:}`, with `total_mw` equal to `btm_tripped_mw`.
    # Strictly additive — the conservation identity's SHAPE is unchanged.
    btm_trip_breakdown: %{frequency_mw: 0.0, voltage_mw: 0.0, total_mw: 0.0},
    # Per-branch conductor temperature, `%{{type, id} => thermal state}`, and
    # the cascade-clock time it was last advanced to. This is the SLOW
    # timescale of ROADMAP item 20; the IEC 60255-151 duty integral is the
    # fast one and they never feed each other.
    conductor_state: %{},
    conductor_at_s: 0.0,
    # What the QSS-AC pass managed, cumulatively over the cascade:
    # `%{islands_ac:, islands_dc_only:, ac_solves:, ac_diverged:, ac_skipped:}`.
    # Reported once per cascade in the log and surfaced in every step result.
    voltage_layer: %{
      islands_ac: 0,
      islands_dc_only: 0,
      ac_solves: 0,
      ac_diverged: 0,
      ac_skipped: 0
    },
    # Controllable reactive plant (REVIEW CAS-29). Off by default: the AC pass
    # then solves with the stamped, fixed plant exactly as before. When on,
    # `voltage_devices` is the device list `PowerModel.Solver.VoltageControl`
    # derived from the BASE snapshot at init — sized once, so a bank does not
    # shrink as the cascade sheds load — and every island's AC solve runs
    # through the control loop, resuming the positions its previous segment
    # settled at (`record.ac_voltage.control_state`).
    voltage_control: false,
    voltage_devices: []
  ]

  @doc """
  Initialize cascade state from a grid snapshot.

  ## Options

    * `:hour` — the UTC hour being simulated. When EIA-930 per-fuel generation
      exists for it, the initial operating point is the MEASURED dispatch
      (`PowerModel.Dispatch`): every unit sits where its BA's fuel mix actually
      put it that hour, and units the measurement did not need are OFFLINE.
      Without an hour, or without fuel data for it, dispatch falls back to the
      per-island load-following rule below and says so in the log.
    * `:fuel_totals` — `%{ba_id => %{fuel => mw}}` passed straight through to
      `PowerModel.Dispatch`, which then reads nothing from the database.

  The fallback `dispatch` map is seeded per island from each generator's share
  of island capacity, capped so the slack bus keeps a little headroom.

  ## The operating point is balanced here, not in the cascade

  Whatever rule produced `dispatch`, it does not in general match the
  snapshot's load island by island: the fuel-anchored dispatch places absolute
  measured MW, and the load-following fallback leaves the slack bus a margin.
  `init/3` closes that gap once, with UNBOUNDED reserves, because it is not an
  event — the operating point had all the time in the world to reach itself.

  That matters for ROADMAP item 16: every deficit that opens AFTER this point
  is timed from the cascade clock and can only be covered as fast as the fleet
  ramps. Leaving the initial gap to the cascade loop would have charged the
  base operating point's own incompleteness to a contingency's ramp budget.
  Any gap that survives here (an island whose nameplate cannot cover its load)
  is left standing, and its deficit clock starts at zero.
  """
  def init(snapshot, base_mva \\ 100.0, opts \\ []) do
    # A cascade is a FREQUENCY-domain simulation, and every threshold in it —
    # UFLS, PRC-024 ride-through, IEEE 1547 inverter trips — is North American
    # and compiled for 60 Hz. A healthy 50 Hz system sits below all four UFLS
    # stages, so a European network run through this would shed load before any
    # contingency. Refuse rather than produce that number. Snapshots with no
    # stated frequency (every DB-backed one) are unaffected.
    PowerModel.Grid.SystemStandard.compatible!(snapshot, opts)

    # Dispatch is balanced PER ISLAND: snapshots may contain several
    # electrically separate systems (Eastern/Western/ERCOT), and generation
    # in one never serves load in another.
    islands =
      IslandDetector.detect(
        Enum.map(snapshot.buses, & &1.id),
        snapshot.lines,
        Map.get(snapshot, :transformers, [])
      )

    bus_ba = Map.new(snapshot.buses, &{&1.id, Map.get(&1, :balancing_authority_id)})

    {dispatch, dispatch_source, dispatch_coverage} =
      initial_dispatch(snapshot, islands, bus_ba, opts)

    # Close the base operating point's own gap before anything is an event
    # (see the docstring), and record where each island starts.
    {dispatch, island_states} = balance_operating_point(dispatch, islands, snapshot)

    # Solve base case to identify lines already overloaded due to model limitations.
    # These are excluded from cascade trip consideration since they represent
    # impedance estimation errors, not actual overloads.
    {base_overloaded, base_line_categories, base_line_loading} =
      compute_base_overloads(snapshot, dispatch, base_mva)

    voltage_control = Keyword.get(opts, :voltage_control, false) == true

    voltage_devices =
      if voltage_control,
        do:
          VoltageControl.devices(snapshot,
            peak_multiplier: Keyword.get(opts, :peak_multiplier, @default_peak_multiplier)
          ),
        else: []

    %__MODULE__{
      buses: snapshot.buses,
      lines: snapshot.lines,
      transformers: Map.get(snapshot, :transformers, []),
      generators: snapshot.generators,
      loads: snapshot.loads,
      dc_ties: Map.get(snapshot, :dc_ties, []),
      water_facilities: Map.get(snapshot, :water_facilities, []),
      datacenters: Map.get(snapshot, :datacenters, []),
      base_mva: base_mva,
      tripped_lines: MapSet.new(),
      tripped_generators: MapSet.new(),
      tripped_transformers: MapSet.new(),
      affected_water_facilities: MapSet.new(),
      affected_datacenters: MapSet.new(),
      base_overloaded: base_overloaded,
      base_line_categories: base_line_categories,
      base_line_loading: base_line_loading,
      events: [],
      step: 0,
      stable: false,
      solution: nil,
      simulated_time: 0.0,
      relay_duty: %{},
      dispatch: dispatch,
      dispatch_source: dispatch_source,
      dispatch_coverage: dispatch_coverage,
      bus_ba: bus_ba,
      original_load_mw: Enum.sum(Enum.map(snapshot.loads, & &1.p_mw)),
      shed_load_mw: 0.0,
      blackout_load_mw: 0.0,
      btm_by_bus: aggregate_btm_solar(Map.get(snapshot, :btm_solar) || []),
      btm_fleet_by_bus: BtmSolar.fleet_by_bus(Map.get(snapshot, :btm_solar) || []),
      btm_tripped_buses: MapSet.new(),
      btm_tripped_mw: 0.0,
      btm_trip_breakdown: BtmSolar.fresh_trip_breakdown(),
      island_states: island_states,
      primary_reserve: %{},
      conductor_state: %{},
      conductor_at_s: 0.0,
      voltage_layer: fresh_voltage_layer(),
      voltage_control: voltage_control,
      voltage_devices: voltage_devices,
      termination: nil,
      frequency_nadir_hz: @nominal_frequency_hz
    }
  end

  defp fresh_voltage_layer do
    %{islands_ac: 0, islands_dc_only: 0, ac_solves: 0, ac_diverged: 0, ac_skipped: 0}
  end

  # ---------------------------------------------------------------------------
  # Island frequency records
  # ---------------------------------------------------------------------------

  # One per island of the current topology:
  #
  #   :buses            the island's bus set when the record was written
  #   :frequency_state  `PowerModel.Solver.Frequency` state, or nil at nominal
  #   :exposure         the island's recent frequency trajectory, trimmed to
  #                     @exposure_window_s, which generator protection reads
  #   :deficit_since_s  cascade-clock time the island's SUSTAINED deficit
  #                     opened, or nil while it has none. The reserve tiers
  #                     ramp on `simulated_time - deficit_since_s`.
  #
  # The voltage half (ROADMAP item 20). Every one of these is written ONLY
  # from a converged FDPF solution — see `record_ac_layer/3` — which is what
  # makes it structurally impossible for a voltage-sensitive protection to be
  # reading the DC solve's flat 1.0 pu:
  #
  #   :ac_voltage       `nil`, or `%{vm_by_bus:, at_s:, warm_start:,
  #                     control_state:}` from the END of the previous segment
  #                     (`control_state` is the voltage-control loop's device
  #                     positions, nil unless `voltage_control: true`). `nil`
  #                     IS the common case
  #                     at real demand (REVIEW LIN-13) and every consumer
  #                     below treats it as "no voltage layer this segment".
  #   :ac_failed        the island fingerprint an AC attempt last failed on,
  #                     so a provably infeasible island is not re-solved every
  #                     step until something about it moves
  #   :gen_voltage_state  PRC-024 ride-through timers, keyed by GENERATOR
  #   :btm_voltage_state  IEEE 1547 rooftop timers, keyed by BUS
  #   :uvls_state         UVLS stage timers, keyed by BUS
  #
  # All three timer states are INTENSIVE and split by plain key filter (see
  # `inherit_record/4`); only the frequency state's cumulative megawatts are
  # apportioned by load share.
  #
  #   :reserve_delivered  per-unit ramp ledger, `%{id => %{secondary: mw,
  #                     tertiary: mw}}` — what each machine has already put on
  #                     the system under the CURRENT deficit clock. It is
  #                     cleared with that clock (`update_deficit_clock/3`) and
  #                     rebased with it (`begin_cascade_event/1`), because a
  #                     ramp budget outliving its clock is charged against an
  #                     origin that no longer exists. See `Reserves.allocate/4`.
  #
  #   :agc              `PowerModel.Controls.AGC` state — the island's
  #                     closed-loop secondary controller
  #   :mean_frequency_hz  the mean frequency of the LAST segment, which is
  #                     what AGC measures (endpoint sampling over-commands)
  #   :voltage_alarm    high-water mark `{undervoltage_buses, overvoltage_buses}`
  #                     already reported, so a level alarm cannot re-fire every
  #                     segment (see `voltage_alarm_event/3`)
  #   :evaluated_at_s   cascade-clock time this island was last evaluated.
  #                     Every "how long has this been true" question in the
  #                     step — voltage timers, the AGC cycle — is answered by
  #                     `now - evaluated_at_s`, which is exactly the previous
  #                     segment's advance.
  defp fresh_island_record(buses, deficit_since_s \\ nil) do
    %{
      buses: buses,
      frequency_state: nil,
      exposure: [],
      deficit_since_s: deficit_since_s,
      reserve_delivered: %{},
      ac_voltage: nil,
      ac_failed: nil,
      gen_voltage_state: Protection.fresh_voltage_state(),
      btm_voltage_state: BtmSolar.fresh_voltage_state(),
      uvls_state: LoadShedding.fresh_uvls_state(),
      agc: nil,
      mean_frequency_hz: nil,
      evaluated_at_s: nil,
      voltage_alarm: nil
    }
  end

  # Balance each island's dispatch against its load with unbounded reserves
  # (see `init/3`). Returns the closed dispatch and one record per island,
  # with the deficit clock started only where a gap survives.
  defp balance_operating_point(dispatch, islands, snapshot) do
    loads = snapshot.loads
    generators = snapshot.generators
    dc_ties = Map.get(snapshot, :dc_ties, [])

    Enum.reduce(islands, {dispatch, []}, fn island, {dispatch, records} ->
      gens = Enum.filter(generators, &MapSet.member?(island, &1.bus_id))
      load_mw = loads |> Enum.filter(&MapSet.member?(island, &1.bus_id)) |> sum_mw(& &1.p_mw)

      tie_mw =
        dc_ties |> Enum.filter(&DcTie.touches?(&1, island)) |> DcTie.net_injection_mw(island)

      gen_mw = sum_mw(gens, &Map.get(dispatch, &1.id, 0.0))

      deficit = load_mw - gen_mw - tie_mw

      # Deficits only. A SURPLUS is left exactly as the dispatch rule wrote it:
      # the fuel-anchored rule places absolute measured MW so that a BA's
      # generation minus its load reproduces its real interchange (ROADMAP
      # item 6), and curtailing that here would replace a measured export with
      # a fiction. The surplus lands on the slack bus, as it always has.
      dispatch =
        if deficit > 0.5 do
          units = Enum.map(gens, &sustained_unit(&1, Map.get(dispatch, &1.id, 0.0), 0.0))
          alloc = Reserves.allocate(units, deficit, :infinity)

          Enum.reduce(units, dispatch, fn unit, d ->
            added = Map.get(alloc.sustained_by_unit, unit.id, 0.0)
            Map.update(d, unit.id, added, &(&1 + added))
          end)
        else
          dispatch
        end

      residual = load_mw - sum_mw(gens, &Map.get(dispatch, &1.id, 0.0)) - tie_mw
      record = fresh_island_record(island, if(residual > 0.5, do: 0.0, else: nil))

      {dispatch, [record | records]}
    end)
    |> then(fn {dispatch, records} -> {dispatch, Enum.reverse(records)} end)
  end

  # A generator map shaped at its SUSTAINED operating point: what the swing
  # model and the reserve tiers reason about, with the transient primary MW
  # taken back out (ROADMAP item 16).
  defp sustained_unit(generator, dispatch_mw, primary_mw) do
    sustained = dispatch_mw - primary_mw
    nameplate = Map.get(generator, :p_nameplate_mw) || generator.p_max_mw

    %{generator | p_max_mw: sustained, capacity_factor: 1.0}
    |> Map.put(:p_dispatch_mw, sustained)
    |> Map.put(:p_nameplate_mw, nameplate)
  end

  defp sum_mw(list, fun), do: list |> Enum.map(fun) |> Enum.sum()

  # A new island inherits the frequency state of the prior island that
  # contributed the plurality of its LOAD (bus count breaks ties; no overlap
  # at all means a fresh 60.0 Hz start). See the moduledoc for the rule and
  # its limits.
  #
  # `generators` is needed for the two per-GENERATOR states (PRC-024 voltage
  # timers, AGC): the frequency rule follows load, but a generator's ride-
  # through timer follows the machine, so the split needs to know which units
  # landed where.
  defp inherit_island_states(prior_records, islands, loads, generators) do
    load_by_bus =
      Enum.reduce(loads, %{}, fn l, acc -> Map.update(acc, l.bus_id, l.p_mw, &(&1 + l.p_mw)) end)

    gens_by_bus = Enum.group_by(generators, & &1.bus_id, & &1.id)

    owner =
      prior_records
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {record, index}, acc ->
        Enum.reduce(record.buses, acc, &Map.put(&2, &1, index))
      end)

    by_index = prior_records |> Enum.with_index() |> Map.new(fn {r, i} -> {i, r} end)

    prior_load =
      Map.new(by_index, fn {index, record} ->
        {index, record.buses |> Enum.map(&Map.get(load_by_bus, &1, 0.0)) |> Enum.sum()}
      end)

    Enum.map(islands, fn island ->
      votes =
        Enum.reduce(island, %{}, fn bus_id, acc ->
          case Map.get(owner, bus_id) do
            nil ->
              acc

            index ->
              mw = Map.get(load_by_bus, bus_id, 0.0)
              Map.update(acc, index, {mw, 1}, fn {m, c} -> {m + mw, c + 1} end)
          end
        end)

      case Enum.max_by(votes, fn {_index, {mw, count}} -> {mw, count} end, fn -> nil end) do
        nil ->
          fresh_island_record(island)

        {index, {mw, _count}} ->
          prior = Map.fetch!(by_index, index)
          share = mw / max(Map.get(prior_load, index, 0.0), 1.0e-9)

          inherit_record(prior, island, share, %{
            load_by_bus: load_by_bus,
            gens_by_bus: gens_by_bus
          })
      end
    end)
  end

  # One island's inheritance from one prior record.
  #
  # An island whose bus set is UNCHANGED keeps every piece of state exactly as
  # it was. That is not only the fast path, it is the correct one for AGC: the
  # controller's integrator is a property of an AREA, and `AGC.apportion/2`
  # rightly zeroes it because a split makes a new area. Re-apportioning an
  # unchanged island every step would zero the integrator every step and leave
  # the loop with proportional action only.
  defp inherit_record(prior, island, share, ctx) do
    if MapSet.equal?(prior.buses, island) do
      prior
    else
      gen_ids =
        Enum.flat_map(island, fn bus_id -> Map.get(ctx.gens_by_bus, bus_id, []) end)

      island_load_mw =
        island |> Enum.map(&Map.get(ctx.load_by_bus, &1, 0.0)) |> Enum.sum()

      prior
      |> Map.put(:buses, island)
      |> apportion_state(share)
      |> Map.put(
        :gen_voltage_state,
        Protection.split_voltage_state(prior.gen_voltage_state, gen_ids)
      )
      |> Map.put(
        :btm_voltage_state,
        BtmSolar.split_voltage_state(prior.btm_voltage_state, island)
      )
      |> Map.put(:uvls_state, LoadShedding.split_uvls_state(prior.uvls_state, island))
      |> Map.put(:agc, split_agc(prior.agc, gen_ids, island_load_mw))
      # The AC layer is a solution referenced to a slack bus that may have
      # left with the other half, so it does not survive a re-partition. The
      # TIMERS above do — they are per-bus and per-machine facts, and losing
      # them would hand every relay back the exposure it had already spent.
      |> Map.put(:ac_voltage, nil)
      # The alarm high-water mark goes with it, and for the same reason: it is
      # an absolute BUS COUNT over the island it was measured on. Inherited by
      # a smaller fragment it is a threshold that fragment can never reach —
      # four undervoltage buses carried into a three-bus island silence the
      # alarm permanently, however far the voltage falls (REVIEW CAS-24).
      |> Map.put(:voltage_alarm, nil)
    end
  end

  defp split_agc(nil, _gen_ids, _load_mw), do: nil

  defp split_agc(agc, gen_ids, load_mw) do
    # The cascade knows the island's REAL load, so AGC never has to fall back
    # to estimating it from its own base-dispatch share.
    agc
    |> AGC.apportion([%{unit_ids: gen_ids, load_mw: load_mw}])
    |> hd()
  end

  # When one island becomes two, both halves keep the frequency they were at
  # and the governors they had deployed — they were synchronised an instant
  # ago — but the CUMULATIVE quantities are shared out by load share, so a
  # small fragment does not carry the whole parent's shed megawatts into its
  # damping base. `Frequency`'s `gov_state` needs no help here: it is keyed by
  # generator, so each half automatically keeps the units it still owns.
  defp apportion_state(%{frequency_state: nil} = record, _share), do: record

  defp apportion_state(record, share) when share >= 1.0, do: record

  defp apportion_state(record, share) do
    state = record.frequency_state

    %{
      record
      | frequency_state: %{
          state
          | cumulative_shed_mw: Map.get(state, :cumulative_shed_mw, 0.0) * share,
            lost_mw: Map.get(state, :lost_mw, 0.0) * share
        }
    }
  end

  # Fold the snapshot's `{bus_id, sector}` rows into ONE legacy-MW figure per
  # bus. A bus appears once per sector (up to three rows), so anything that
  # walks the raw entries applies the same bus three times.
  #
  # Only the legacy share is stored, because only it can ever trip: the
  # 1547-2018 remainder must ride through. The share is uniform and
  # config-driven (`PowerModel.Grid.BtmSolar.legacy_fraction/0`), so it is
  # multiplied through here rather than inspected per entry.
  #
  # Entries with nothing to lose are dropped rather than stored as zero —
  # night hours, a BA with no fuel row for the hour, an all-1547-2018 fleet.
  # Those are COMMON, correct states, and a bus absent from this map costs the
  # cascade nothing at all: no candidate, no frequency probe, no event.
  defp aggregate_btm_solar(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      bus_id = Map.get(entry, :bus_id)
      output_mw = Map.get(entry, :output_mw) || 0.0
      fraction = Map.get(entry, :legacy_fraction) || BtmSolar.legacy_fraction()
      legacy_mw = output_mw * fraction

      if is_nil(bus_id) or legacy_mw <= 0.0 do
        acc
      else
        Map.update(acc, bus_id, legacy_mw, &(&1 + legacy_mw))
      end
    end)
  end

  @doc """
  Consumption accounting for the current cascade state.

  Conservation invariant:

      served + shed + blackout == original + btm_tripped

  within rounding, so the UI can always present a balance that adds up.

  ## Why there is a `btm_tripped_mw` term

  `original_load_mw` is the sum of the snapshot's loads, and those are EIA-930
  demand — metered NET of behind-the-meter solar. When legacy inverters trip
  (IEEE 1547, see the moduledoc), the gross demand they were hiding appears at
  the bus as load that was never counted in `original_load_mw`. It is not
  shed, not blacked out, and not served-from-somewhere-else: it is new demand
  entering the accounting mid-run, so it needs its own source term rather than
  a fudge in one of the sinks.

  With no BTM layer, or before anything trips, `btm_tripped_mw` is `0.0` and
  the identity reduces to the original `served + shed + blackout == original`.
  Every MW in this bucket is downstream-accountable exactly like any other:
  once it is standing at the bus, UFLS can shed it and an island blackout can
  take it, and it moves into those buckets normally when that happens.

  DC ties are absent from this by construction. A tie is a TRANSFER between
  two converter buses, neither demand nor generation, so counting its MW as
  either would break the invariant while describing nothing real: an imported
  megawatt still shows up here as the load it serves. Its effect on the
  island's power balance is applied where it belongs — in the deficit
  arithmetic of `solve_islands_timed/10` and in the solver's injection vector.
  """
  def balance(%__MODULE__{} = state) do
    active_gens = Enum.reject(state.generators, &MapSet.member?(state.tripped_generators, &1.id))

    %{
      original_load_mw: state.original_load_mw,
      served_load_mw: Enum.sum(Enum.map(state.loads, & &1.p_mw)),
      shed_load_mw: state.shed_load_mw,
      blackout_load_mw: state.blackout_load_mw,
      btm_tripped_mw: state.btm_tripped_mw || 0.0,
      dispatched_gen_mw: Enum.sum(Enum.map(active_gens, &Map.get(state.dispatch, &1.id, 0.0))),
      online_capacity_mw: Enum.sum(Enum.map(active_gens, & &1.p_max_mw))
    }
  end

  @doc """
  What the cascade LEFT STANDING, as an atom. Orthogonal to `termination/1`,
  which says only why the loop stopped iterating.

  The two answer different questions and every combination of them occurs. A
  cascade that sheds an interconnection down to nothing and then has nothing
  further to trip is `{:settled, :collapsed}` — the loop reached a fixed point,
  and the fixed point is a blackout. Presenting that as "stable" because the
  termination said `:settled` is the specific misreading this exists to stop.

    * `:collapsed` — less than #{trunc(@outcome_collapsed_served_fraction * 100)}%
      of standing demand is still served. Because the conservation identity in
      `balance/1` holds, this is exactly equivalent to shed plus blackout
      exceeding the other #{trunc((1.0 - @outcome_collapsed_served_fraction) * 100)}%,
      so the two framings can never disagree.
    * `:degraded` — customers were lost, but most are still served. The floor
      is deliberately two-sided so it means the same thing at both ends of the
      four orders of magnitude this engine runs over: more than
      `#{@outcome_degraded_mw}` MW lost in absolute terms (which catches a real
      shed on a national snapshot, where any relative floor would be enormous),
      OR more than #{@outcome_degraded_fraction * 100}% of standing demand
      (which catches a real shed on a small test island, where any absolute
      floor would be enormous). What falls through both is float residue from
      the reserve and rooftop arithmetic — fractions of a megawatt — and that
      is the only thing this is filtering.
    * `:intact` — everything still standing is served.
    * `:unknown` — the run ended in a failed solve and there is no trustworthy
      balance to classify. Occurs EXACTLY when `termination/1` is
      `:solve_failed`, and never otherwise.

  ## The one place this reads `termination/1`, and why

  Everything above is computed from `balance/1` alone. The single exception is
  `:solve_failed`, where the classification is suppressed rather than computed.

  `termination/1` documents `:solve_failed` as "nothing downstream of the
  failed solve is trustworthy", and a balance is precisely downstream: an
  island's power flow died partway, so `state.loads` may still hold load that
  was never actually served and `shed_load_mw` may hold a partial tally that
  stopped mid-step. Classifying that would return a confident verdict computed
  from numbers this module has already disowned — reporting `:intact` for a
  solve that died before it could shed anything, or `:collapsed` for one that
  died after a partial shed, either of which claims we know what the grid did
  when what we know is that we stopped being able to compute.

  `balance/1` itself stays honest and unsuppressed: it is bookkeeping of what
  the state RECORDS, and that record is accurate. It is the interpretation of
  those numbers as a verdict on the grid that inherits the untrustworthiness.

  Suppressing here rather than at each consumer is deliberate. A consumer that
  forgets the precedence renders a reassuring green outcome beside a failure,
  and the next consumer will forget it again.

  ## Standing demand, not original demand

  The denominator is `original_load_mw + btm_tripped_mw`: the identity's own
  right-hand side, and the demand actually standing at the buses by the end.
  Tripped rooftop is load that was never in `original_load_mw` (EIA-930 demand
  is metered net of it — see `balance/1`), so dividing by `original_load_mw`
  alone would let a heavy rooftop trip report more than 100% served. With no
  behind-the-meter layer the two are identical, which is the common case.

  Non-`nil` for any state `termination/1` accepts, including one that has
  never run a cascade.
  """
  @spec outcome(%__MODULE__{}) :: :collapsed | :degraded | :intact | :unknown
  def outcome(%__MODULE__{termination: :solve_failed}), do: :unknown

  def outcome(%__MODULE__{} = state) do
    balance = balance(state)
    standing_mw = balance.original_load_mw + balance.btm_tripped_mw
    lost_mw = balance.shed_load_mw + balance.blackout_load_mw

    cond do
      # A snapshot with no load at all has nothing to lose. Also the guard that
      # keeps the fractions below from dividing by zero.
      standing_mw <= 0.0 ->
        :intact

      balance.served_load_mw / standing_mw < @outcome_collapsed_served_fraction ->
        :collapsed

      lost_mw > @outcome_degraded_mw ->
        :degraded

      lost_mw / standing_mw > @outcome_degraded_fraction ->
        :degraded

      true ->
        :intact
    end
  end

  defp compute_base_overloads(snapshot, dispatch, base_mva) do
    dispatched_gens =
      Enum.map(snapshot.generators, fn g ->
        d = Map.get(dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))
        %{g | p_max_mw: d, capacity_factor: 1.0}
      end)

    base_snapshot = %{
      buses: snapshot.buses,
      lines: snapshot.lines,
      transformers: Map.get(snapshot, :transformers, []),
      generators: dispatched_gens,
      loads: snapshot.loads,
      dc_ties: Map.get(snapshot, :dc_ties, [])
    }

    try do
      solution = DCPowerFlow.solve_islands(base_snapshot, base_mva: base_mva)

      # Trip-immune set, on the SAME basis the relays use (rate C). A branch
      # over its continuous rating in the base case is a dispatch artifact and
      # must not be masked from tripping — only one already past relay pickup
      # before anything has happened is, since it would trip at t=0 on model
      # error alone.
      overloaded =
        solution.line_flows
        |> Enum.filter(fn {_key, flow} -> trip_loading_pct(flow) > 100.0 end)
        |> Enum.map(fn {{type, id}, _flow} -> {type, id} end)
        |> MapSet.new()

      # Category map for ALL lines with significant loading
      # Used to filter frontend payloads so only WORSENED lines are shown
      # 3=overloaded(>100%), 2=stressed(75-100%), 1=rerouted(30-75%)
      categories =
        solution.line_flows
        |> Enum.filter(fn {_key, flow} -> flow.loading_pct >= 30.0 end)
        |> Map.new(fn {key, flow} ->
          cat =
            cond do
              flow.loading_pct > 100.0 -> 3
              flow.loading_pct >= 75.0 -> 2
              true -> 1
            end

          {key, cat}
        end)

      # Per-branch base loading so post-failure payloads can surface flow
      # redistribution (delta vs base), not just category jumps.
      loading = Map.new(solution.line_flows, fn {key, flow} -> {key, flow.loading_pct} end)

      {overloaded, categories, loading}
    rescue
      e ->
        Logger.warning("base-case solve raised #{Exception.message(e)}; no base filtering")
        {MapSet.new(), %{}, %{}}
    catch
      thrown ->
        Logger.warning("base-case solve threw #{inspect(thrown)}; no base filtering")
        {MapSet.new(), %{}, %{}}
    end
  end

  # Measured EIA-930 dispatch when the hour has per-fuel data, otherwise the
  # load-following fallback. Returns `{dispatch, source, coverage}`.
  defp initial_dispatch(snapshot, islands, bus_ba, opts) do
    hour = Keyword.get(opts, :hour)

    result =
      if match?(%DateTime{}, hour) do
        dispatch_opts =
          [bus_ba: bus_ba, islands: islands, loads: snapshot.loads]
          |> then(fn o ->
            case Keyword.fetch(opts, :fuel_totals) do
              {:ok, totals} -> Keyword.put(o, :fuel_totals, totals)
              :error -> o
            end
          end)

        Dispatch.for_hour(snapshot.generators, hour, dispatch_opts)
      else
        {:error, :no_hour}
      end

    case result do
      {:ok, %{dispatch: dispatch, coverage: coverage}} ->
        {dispatch, :eia_fuel, coverage}

      {:error, reason} ->
        Logger.info(
          "Cascade: using load-following dispatch (#{fallback_reason(reason, hour)}) -- " <>
            "unit commitment is proportional to capacity, not measured generation"
        )

        {balance_dispatch_per_island(islands, snapshot.generators, snapshot.loads), :proportional,
         nil}
    end
  end

  defp fallback_reason(:no_hour, _hour), do: "no simulation hour supplied"

  defp fallback_reason(:no_fuel_data, hour),
    do: "no EIA-930 per-fuel generation ingested for #{DateTime.to_iso8601(hour)}"

  # Balance dispatch independently within each electrical island and merge.
  defp balance_dispatch_per_island(islands, generators, loads) do
    Enum.reduce(islands, %{}, fn island, dispatch ->
      island_gens = Enum.filter(generators, &MapSet.member?(island, &1.bus_id))
      island_loads = Enum.filter(loads, &MapSet.member?(island, &1.bus_id))
      Map.merge(dispatch, balance_dispatch(island_gens, island_loads))
    end)
  end

  # Scale generator dispatch to match total load within p_max limits.
  # Capacity factor is used for ordering (baseload units dispatch first)
  # but all generators can run up to p_max if needed.
  defp balance_dispatch(generators, loads) do
    total_load = Enum.sum(Enum.map(loads, & &1.p_mw))
    total_capacity = Enum.sum(Enum.map(generators, & &1.p_max_mw))

    if total_capacity <= 0 or total_load <= 0 do
      Map.new(generators, fn g -> {g.id, 0.0} end)
    else
      # Dispatch ratio: what fraction of max capacity do we need?
      # Cap at 0.95 to leave some headroom for the slack bus
      ratio = min(total_load / total_capacity, 0.95)

      Map.new(generators, fn g ->
        # Each generator dispatches proportionally to its capacity
        {g.id, g.p_max_mw * ratio}
      end)
    end
  end

  @doc """
  Trip a transmission line and run cascade.
  Returns {final_state, all_step_results} for streaming.

  Re-tripping an already-tripped line is a no-op (returns `{state, []}`).
  Each accepted manual trip starts a NEW cascade event: the per-cascade step
  budget, simulated relay clock, and relay duty accumulators are reset.
  """
  def trip_line(%__MODULE__{} = state, line_id) do
    if MapSet.member?(state.tripped_lines, line_id) do
      Logger.info("trip_line: line #{line_id} is already tripped; ignoring re-trip")
      {state, []}
    else
      state = begin_cascade_event(state)

      state = %{
        state
        | tripped_lines: MapSet.put(state.tripped_lines, line_id),
          events: [
            %{
              step: 0,
              component_type: "transmission_line",
              component_id: line_id,
              failure_cause: "manual_trip",
              details: %{}
            }
            | state.events
          ]
      }

      # The trip may have split islands: raise reserves in deficit halves and
      # curtail surplus halves BEFORE the cascade loop, so no island carries a
      # phantom slack injection into the first re-solve.
      state = maybe_redispatch_after_trip(state)

      run_cascade(state)
    end
  end

  @doc """
  Trip a transformer and run cascade.
  Returns {final_state, all_step_results} for streaming.

  Re-tripping an already-tripped transformer is a no-op (returns
  `{state, []}`). Each accepted manual trip starts a NEW cascade event (step
  budget, simulated relay clock, and relay duty accumulators reset).
  """
  def trip_transformer(%__MODULE__{} = state, xfmr_id) do
    if MapSet.member?(state.tripped_transformers, xfmr_id) do
      Logger.info("trip_transformer: transformer #{xfmr_id} is already tripped; ignoring re-trip")

      {state, []}
    else
      state = begin_cascade_event(state)

      state = %{
        state
        | tripped_transformers: MapSet.put(state.tripped_transformers, xfmr_id),
          events: [
            %{
              step: 0,
              component_type: "transformer",
              component_id: xfmr_id,
              failure_cause: "manual_trip",
              details: %{}
            }
            | state.events
          ]
      }

      state = maybe_redispatch_after_trip(state)

      run_cascade(state)
    end
  end

  @doc """
  Trip a generator and run cascade.
  Performs redispatch to cover the lost generation before running the cascade loop.

  Re-tripping an already-tripped generator is a no-op (returns `{state, []}`).
  Each accepted manual trip starts a NEW cascade event (step budget, simulated
  relay clock, and relay duty accumulators reset).
  """
  def trip_generator(%__MODULE__{} = state, gen_id) do
    if MapSet.member?(state.tripped_generators, gen_id) do
      Logger.info("trip_generator: generator #{gen_id} is already tripped; ignoring re-trip")
      {state, []}
    else
      # MW lost from this generator. Its dispatch entry is zeroed immediately
      # so any later read cannot double-count the loss.
      lost_mw = Map.get(state.dispatch, gen_id, 0.0)
      gen = Enum.find(state.generators, &(&1.id == gen_id))

      state = begin_cascade_event(state)

      state = %{
        state
        | tripped_generators: MapSet.put(state.tripped_generators, gen_id),
          dispatch: Map.put(state.dispatch, gen_id, 0.0),
          primary_reserve: Map.delete(state.primary_reserve, gen_id),
          events: [
            %{
              step: 0,
              component_type: "generator",
              component_id: gen_id,
              failure_cause: "manual_trip",
              details: %{}
            }
            | state.events
          ]
      }

      # Redispatch within the tripped generator's OWN island only -- and within
      # that island, the unit's own balancing authority responds first (its
      # contingency reserves), with the rest of the island as emergency backup.
      state =
        case gen && island_containing(state, gen.bus_id) do
          nil ->
            state

          island ->
            origin_ba = Map.get(state.bus_ba || %{}, gen.bus_id)
            redispatch(state, lost_mw, island, origin_ba)
        end

      run_cascade(state)
    end
  end

  # Every accepted manual trip starts a NEW cascade event: the step budget,
  # the simulated wall-clock, and the relay duty accumulators are per-cascade
  # quantities, never per-session. Session-cumulative state (tripped sets,
  # events, load accounting, island frequency state) is deliberately retained.
  #
  # The per-island deficit clocks are rebased rather than cleared: an island
  # still holding a deficit keeps holding it, but it has been holding it since
  # the start of THIS cascade event, because that is where the clock now is.
  # The ramp ledger is measured against that clock, so it restarts with it —
  # the two halves of one accounting cannot have different origins.
  defp begin_cascade_event(state) do
    records =
      Enum.map(state.island_states, fn record ->
        case record.deficit_since_s do
          nil -> %{record | reserve_delivered: %{}}
          _ -> %{record | deficit_since_s: 0.0, reserve_delivered: %{}}
        end
      end)

    %{
      state
      | step: 0,
        simulated_time: 0.0,
        relay_duty: %{},
        stable: false,
        termination: nil,
        frequency_nadir_hz: current_frequency_floor_hz(records),
        island_states: records
    }
  end

  # The nadir is a per-cascade-event quantity, but the islands' frequency state
  # is NOT: an island already sitting at 59.5 Hz keeps sitting there across a
  # new manual trip. Rebasing to where the system already is (rather than to
  # 60.0) keeps the reported nadir from ever reading ABOVE the frequency the
  # same payload reports as current.
  defp current_frequency_floor_hz(records) do
    records
    |> Enum.map(&island_frequency_hz/1)
    |> Enum.min(fn -> @nominal_frequency_hz end)
    |> min(@nominal_frequency_hz)
  end

  @doc """
  Run cascade loop until stable or max steps reached.
  Yields each step result for streaming via callback.

  ## The returned list is authoritative; the callback stream is not

  `callback` is invoked once per step AS THAT STEP COMPLETES, which means it
  cannot see anything decided after the last step ran. Exactly one thing is:
  `:budget_exhausted` fires INSTEAD of a step, so it is stamped onto the last
  step result on the way out (see `termination/1`) and the consumer that
  already received that frame never learns of it. A callback consumer watching
  a truncated run therefore sees a final frame saying `termination: nil` —
  "still running" — and no further frames, which is indistinguishable from a
  run still in flight.

  The returned `{state, step_results}` carries the stamp, so a consumer that
  needs the termination reason MUST read it from there. That is what
  `PowerModel.Engine.SimulationServer` does: it broadcasts the returned list,
  not the callback stream, and its `cascade_done` payload reads
  `termination/1` off the final state.

  No synthetic terminal frame is emitted to close the gap, deliberately: the
  step results are counted and indexed by consumers (the UI scrubs by step
  index), and a frame that corresponds to no step would put the stream's own
  numbering at odds with the list's.
  """
  def run_cascade(state, callback \\ nil) do
    {state, step_results} = do_cascade(state, [], callback)
    log_voltage_layer(state)
    {state, step_results}
  end

  @doc """
  Why the cascade stopped, as an atom. Always non-`nil` on a state returned by
  `run_cascade/2` (and therefore by `trip_line/2`, `trip_transformer/2` and
  `trip_generator/2` whenever they accepted the trip).

    * `:settled` — a step produced no trips of any kind. This is the only
      value that means the final state is an equilibrium.
    * `:budget_exhausted` — the per-cascade `@max_steps` budget ran out with
      trips still pending. The run is TRUNCATED: whatever it was doing, it was
      still doing it. Presenting this as a settled collapse is the false-10x
      hazard the step budget's kill-switch note warns about.
    * `:solve_failed` — an island's power flow failed numerically and the run
      is terminal. Nothing downstream of the failed solve is trustworthy.

  `stable` alone cannot distinguish the last two: both leave it `false`. And
  none of the three says anything about how much load survived — that is
  `outcome/1`, which is orthogonal to this and must be read alongside it. The
  one point where the two are coupled is `:solve_failed`, which suppresses
  `outcome/1` to `:unknown` for the reason stated here: nothing downstream of
  the failed solve is trustworthy, and a balance is downstream.

  The same value is on the last element of the step-result LIST (each earlier
  step carries `nil`, meaning "still running"), so a consumer holding only the
  list can read it there.

  It is NOT on the last frame a `run_cascade/2` callback receives when the
  cause is `:budget_exhausted`. That clause fires instead of a step, so there
  is no step left to invoke the callback with, and the stamp lands only on the
  already-delivered list element. A streaming consumer that must distinguish a
  truncated run from one still in flight has to read the returned list — see
  `run_cascade/2` for why no synthetic terminal frame is emitted instead.
  """
  @spec termination(%__MODULE__{}) :: :settled | :budget_exhausted | :solve_failed | nil
  def termination(%__MODULE__{termination: cause}), do: cause

  # ONE line per cascade, never one per island per step. A national snapshot
  # runs thousands of island-solves in a single cascade and OTP's logger
  # overload protection silently drops most of a burst that size (REVIEW
  # DAT-20), so the count is tallied and reported once — which also makes
  # "the voltage layer did nothing at all" a visible fact rather than an
  # absence of log lines.
  defp log_voltage_layer(%__MODULE__{voltage_layer: layer}) do
    total = layer.islands_ac + layer.islands_dc_only

    cond do
      total == 0 ->
        :ok

      layer.islands_ac == 0 ->
        Logger.info(
          "QSS-AC: no island reached an AC solution in #{total} island-solves " <>
            "(#{layer.ac_diverged} attempted and diverged, #{layer.ac_skipped} skipped as " <>
            "unchanged since a prior failure) -- the voltage layer was inert this cascade " <>
            "and every island ran DC plus the frequency chain (REVIEW LIN-13)"
        )

      true ->
        Logger.info(
          "QSS-AC: #{layer.islands_ac}/#{total} island-solves carried a voltage layer " <>
            "(#{layer.ac_solves} AC solves, #{layer.ac_diverged} diverged, " <>
            "#{layer.ac_skipped} skipped as unchanged since a prior failure)"
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Redispatch
  # ---------------------------------------------------------------------------

  @doc """
  Raise SUSTAINED reserves to cover `deficit_mw` (positive = need more
  generation) among online generators in `island_bus_set`, in the order
  reserves are actually activated:

  1. **Origin BA** -- when `origin_ba` is known, the balancing authority that
     lost the generation restores its own ACE first (secondary control is a
     BA-level function).
  2. **Emergency assistance** -- any remaining deficit is covered from the
     rest of the SAME island. Never beyond it: an asynchronous neighbor
     interconnection cannot supply this power.

  Both tiers are ramp-limited on the cascade clock
  (`PowerModel.Failure.Reserves`): a balancing authority with 10 GW of idle
  headroom and thirty seconds of notice delivers thirty seconds' worth of
  ramp, not 10 GW.

  PRIMARY (governor) response is deliberately NOT allocated here. It is not a
  balancing-authority function — every governor in the synchronous island
  answers a frequency deviation regardless of who lost the unit — so it is
  allocated island-wide inside the step's own island evaluation, where the
  swing model that produces it also lives.

  Anything these tiers cannot reach in time is left standing: the step's
  island evaluation closes it with UFLS and the force-shed tier, on the
  frequency the island actually reached. Returns the updated state.
  """
  def redispatch(state, deficit_mw, island_bus_set, origin_ba \\ nil)

  def redispatch(%__MODULE__{} = state, deficit_mw, _island_bus_set, _origin_ba)
      when deficit_mw <= 0.0 do
    state
  end

  def redispatch(%__MODULE__{} = state, deficit_mw, island_bus_set, origin_ba) do
    elapsed_s = elapsed_since_deficit(state, island_bus_set)
    island_gens = online_island_gens(state, island_bus_set)

    {ba_gens, other_gens} =
      if origin_ba do
        Enum.split_with(island_gens, fn g ->
          Map.get(state.bus_ba || %{}, g.bus_id) == origin_ba
        end)
      else
        {[], island_gens}
      end

    {state, remaining} =
      apply_sustained_reserves(state, deficit_mw, ba_gens, elapsed_s, island_bus_set)

    {state, _remaining} =
      apply_sustained_reserves(state, remaining, other_gens, elapsed_s, island_bus_set)

    state
  end

  # Raise `gens` by as much sustained (secondary + tertiary) reserve as the
  # clock allows. Returns `{state, remaining_deficit}`.
  defp apply_sustained_reserves(state, deficit_mw, gens, elapsed_s, island_bus_set)

  defp apply_sustained_reserves(state, deficit_mw, [], _elapsed_s, _island),
    do: {state, deficit_mw}

  defp apply_sustained_reserves(state, deficit_mw, _gens, _elapsed_s, _island)
       when deficit_mw <= 0.5,
       do: {state, deficit_mw}

  defp apply_sustained_reserves(state, deficit_mw, gens, elapsed_s, island_bus_set) do
    units = Enum.map(gens, &sustained_unit_of(state, &1))

    # TERTIARY ONLY. AGC owns the secondary tier island-wide, inside the step's
    # own island evaluation where the frequency it regulates against lives, so
    # this path must not draw secondary reserve as well: both tiers raise the
    # SAME machines out of the SAME headroom, and the cascade re-derives each
    # step's deficit from the raised dispatch, so running both would show a
    # fleet delivering reserve it does not carry.
    #
    # An empty AGC increment map is how `Reserves.allocate/4` is told that:
    # every unit's secondary capability is the MW AGC dispatched to it, which
    # is zero, so the tier is saturated at zero and tertiary is reached
    # immediately. The clock still bounds tertiary — net of what the island's
    # ledger says these machines already ramped under the same clock, which is
    # what stops the step's three allocations handing out three ramps.
    ledger = island_reserve_ledger(state, island_bus_set)

    alloc =
      Reserves.allocate(units, deficit_mw, elapsed_s,
        secondary: {:agc, %{}},
        delivered: ledger
      )

    dispatch =
      Enum.reduce(units, state.dispatch, fn unit, d ->
        case Map.get(alloc.sustained_by_unit, unit.id, 0.0) do
          mw when mw > 0.0 -> Map.update(d, unit.id, mw, &(&1 + mw))
          _ -> d
        end
      end)

    state =
      %{state | dispatch: dispatch}
      |> update_island_records(island_bus_set, &record_reserve_delivery(&1, alloc))

    {state, deficit_mw - alloc.secondary_mw - alloc.tertiary_mw}
  end

  # The ramp ledger of the island containing these buses (empty when the island
  # has no record — an island the cascade has never evaluated has no clock to
  # measure a ledger against either; see `elapsed_since_deficit/2`).
  defp island_reserve_ledger(state, island_bus_set) do
    case island_record_for(state, island_bus_set) do
      %{reserve_delivered: delivered} -> delivered
      _ -> %{}
    end
  end

  defp update_island_records(state, island_bus_set, fun) do
    records =
      Enum.map(state.island_states, fn record ->
        if MapSet.disjoint?(record.buses, island_bus_set), do: record, else: fun.(record)
      end)

    %{state | island_states: records}
  end

  # Add one allocation's per-tier megawatts to the island's ramp ledger. The
  # two tiers are kept apart because they draw on DISJOINT windows of the same
  # ramp (`Reserves.allocate/4`): folding them together would let a unit that
  # spent its secondary window deny itself its tertiary one.
  defp record_reserve_delivery(record, alloc) do
    delivered =
      [{:secondary, alloc.secondary_by_unit}, {:tertiary, alloc.tertiary_by_unit}]
      |> Enum.reduce(record.reserve_delivered, fn {tier, by_unit}, ledger ->
        Enum.reduce(by_unit, ledger, fn {id, mw}, ledger ->
          Map.update(ledger, id, %{tier => mw}, &Map.update(&1, tier, mw, fn m -> m + mw end))
        end)
      end)

    %{record | reserve_delivered: delivered}
  end

  # One generator at its sustained operating point, read from the state's
  # dispatch and primary-reserve maps.
  defp sustained_unit_of(state, generator) do
    dispatched =
      Map.get(
        state.dispatch,
        generator.id,
        generator.p_max_mw * (generator.capacity_factor || 1.0)
      )

    sustained_unit(generator, dispatched, Map.get(state.primary_reserve, generator.id, 0.0))
  end

  # How long this island's sustained deficit has been open, on the cascade
  # clock. An island with no record at all has never been seen by the cascade,
  # which means whatever gap it has is not an event — see `init/3`.
  defp elapsed_since_deficit(state, island_bus_set) do
    case island_record_for(state, island_bus_set) do
      %{deficit_since_s: opened_at} when is_number(opened_at) ->
        max(state.simulated_time - opened_at, 0.0)

      %{} ->
        0.0

      nil ->
        :infinity
    end
  end

  defp island_record_for(state, island_bus_set) do
    Enum.find(state.island_states, fn record ->
      not MapSet.disjoint?(record.buses, island_bus_set)
    end)
  end

  defp online_island_gens(state, island_bus_set) do
    state.generators
    |> Enum.reject(&MapSet.member?(state.tripped_generators, &1.id))
    |> Enum.filter(&MapSet.member?(island_bus_set, &1.bus_id))
  end

  # The active-topology island containing a bus (nil when the bus is unknown).
  defp island_containing(state, bus_id) do
    state
    |> active_topology_islands()
    |> Enum.find(&MapSet.member?(&1, bus_id))
  end

  defp active_topology_islands(state) do
    active_lines = Enum.reject(state.lines, &MapSet.member?(state.tripped_lines, &1.id))

    active_xfmrs =
      Enum.reject(state.transformers, &MapSet.member?(state.tripped_transformers, &1.id))

    IslandDetector.detect(Enum.map(state.buses, & &1.id), active_lines, active_xfmrs)
  end

  # ---------------------------------------------------------------------------
  # Timed cascade loop
  # ---------------------------------------------------------------------------

  defp do_cascade(%{step: step} = state, step_results, _callback) when step >= @max_steps do
    # The per-cascade step budget ran out with trips still pending. This is a
    # truncated, NOT settled, cascade: mark it loudly so callers never present
    # the final state as a stable equilibrium.
    Logger.warning(
      "cascade step budget exhausted at step #{state.step} (max #{@max_steps}); " <>
        "terminating cascade as unstable"
    )

    exhausted_event = %{
      step: state.step,
      component_type: "cascade",
      component_id: 0,
      failure_cause: "max_steps_exhausted",
      details: %{max_steps: @max_steps, simulated_time: state.simulated_time}
    }

    # The budget clause emits no step of its own — it fires INSTEAD of a step —
    # so the run's last step is stamped with the reason on the way out. Without
    # this the returned stream ends on a step still saying `termination: nil`
    # and a consumer watching only the stream could never tell a truncated run
    # from one still in flight.
    {%{
       state
       | stable: false,
         termination: :budget_exhausted,
         events: [exhausted_event | state.events]
     }, step_results |> stamp_termination(:budget_exhausted) |> Enum.reverse()}
  end

  defp do_cascade(state, step_results, callback) do
    state = %{state | step: state.step + 1}

    # Get active topology (exclude tripped components)
    active_lines = Enum.reject(state.lines, &MapSet.member?(state.tripped_lines, &1.id))

    active_xfmrs =
      Enum.reject(state.transformers, &MapSet.member?(state.tripped_transformers, &1.id))

    active_gens = Enum.reject(state.generators, &MapSet.member?(state.tripped_generators, &1.id))

    # Detect islands and carry each one's frequency state across whatever the
    # last trip did to the topology (see the moduledoc's inheritance rule).
    bus_ids = Enum.map(state.buses, & &1.id)
    islands = IslandDetector.detect(bus_ids, active_lines, active_xfmrs)
    records = inherit_island_states(state.island_states, islands, state.loads, active_gens)

    # Solve each island and collect ALL overloaded components with trip times
    island_step = solve_islands_timed(state, islands, records, active_lines, active_xfmrs)

    %{
      trips: non_thermal_trips,
      results: island_results,
      loads: updated_loads,
      overloads: timed_overloads,
      shed_mw: step_shed_mw,
      blackout_mw: step_blackout_mw,
      btm: btm
    } = island_step

    state = %{
      state
      | dispatch: island_step.dispatch,
        primary_reserve: island_step.primary_reserve,
        island_states: island_step.records,
        btm_tripped_buses: btm.tripped,
        btm_tripped_mw: state.btm_tripped_mw + btm.tripped_mw,
        btm_trip_breakdown: btm.breakdown,
        conductor_state: island_step.conductor,
        conductor_at_s: state.simulated_time,
        voltage_layer: island_step.voltage_layer,
        frequency_nadir_hz: min(state.frequency_nadir_hz, island_step.nadir_hz)
    }

    # Facilities on dead-island buses lose power (water + datacenters)
    dead_bus_ids = dead_island_buses(islands, active_gens)

    {water_trips, newly_affected} =
      check_facility_power_loss(
        state.water_facilities,
        state.affected_water_facilities,
        dead_bus_ids,
        "water_facility",
        &water_facility_details/1
      )

    {datacenter_trips, newly_affected_dcs} =
      check_facility_power_loss(
        state.datacenters,
        state.affected_datacenters,
        dead_bus_ids,
        "datacenter",
        &datacenter_details/1
      )

    facility_trips =
      Enum.map(water_trips ++ datacenter_trips, &Map.put(&1, :step, state.step))

    state = %{state | events: facility_trips ++ state.events}

    if Enum.empty?(non_thermal_trips) and Enum.empty?(timed_overloads) do
      # Stable -- no trips of any kind
      state = %{
        state
        | stable: true,
          simulated_time: state.simulated_time + island_step.frequency_advance_s,
          loads: updated_loads,
          shed_load_mw: state.shed_load_mw + step_shed_mw,
          blackout_load_mw: state.blackout_load_mw + step_blackout_mw,
          relay_duty: %{},
          affected_water_facilities:
            MapSet.union(state.affected_water_facilities, newly_affected),
          affected_datacenters: MapSet.union(state.affected_datacenters, newly_affected_dcs)
      }

      state = %{state | termination: :settled}

      step_result =
        %{
          step: state.step,
          simulated_time: state.simulated_time,
          islands: length(islands),
          trips: facility_trips,
          water_facility_ids: MapSet.to_list(state.affected_water_facilities),
          datacenter_ids: MapSet.to_list(state.affected_datacenters),
          solution: island_results,
          balance: balance(state),
          voltage_layer: state.voltage_layer
        }
        |> Map.merge(step_contract(state))

      if callback, do: callback.(step_result)

      {state, Enum.reverse([step_result | step_results])}
    else
      # Process non-thermal trips immediately (blackouts, UFLS)
      state = apply_trips(state, non_thermal_trips)

      state = %{
        state
        | loads: updated_loads,
          shed_load_mw: state.shed_load_mw + step_shed_mw,
          blackout_load_mw: state.blackout_load_mw + step_blackout_mw
      }

      island_solve_failed? =
        Enum.any?(non_thermal_trips, &(&1.failure_cause == "island_solve_failed"))

      # Non-thermal trips (island blackouts, UFLS sheds, voltage trips) change
      # the generation-load balance of the surviving islands: rebalance them
      # NOW, before this step's balance is emitted, so dispatched generation
      # tracks served load (e.g. a blacked-out single-bus island must have its
      # still-online generator curtailed). A failed island solve is terminal
      # for this run and its incomplete state is never redispatched from.
      state =
        if non_thermal_trips != [] and not island_solve_failed? do
          maybe_redispatch_after_trip(state)
        else
          state
        end

      # For thermal/zone3 overloads: trip ONLY the first relay to finish timing.
      # Every asserted relay integrates its own fraction of operating progress
      # over the common wall-clock advance.
      {tripped_component, time_advance_s, relay_duty} =
        if island_solve_failed? do
          # A failed numerical solve is terminal for this run; do not advance
          # protection from the incomplete set of island solutions.
          {nil, 0.0, %{}}
        else
          advance_relay_timers(timed_overloads, reset_thermal_duty(state.relay_duty))
        end

      state = %{state | relay_duty: relay_duty}

      # The step's wall clock advances by the LONGER of the two processes that
      # ran in it (REVIEW CAS-16): the relay that finished timing, and the
      # frequency window any island actually integrated. They are concurrent —
      # an island swinging while a relay times is one 30 s stretch of real
      # time, not two — and thermal duty still accrues over its own advance
      # alone, so relay timing is unchanged by the frequency clock.
      relay_advance_s = if tripped_component, do: time_advance_s, else: 0.0
      step_advance_s = max(relay_advance_s, island_step.frequency_advance_s)
      state = %{state | simulated_time: state.simulated_time + step_advance_s}

      thermal_trips = if tripped_component, do: [tripped_component], else: []

      all_trips_this_step = non_thermal_trips ++ thermal_trips ++ facility_trips

      state = %{
        state
        | affected_water_facilities:
            MapSet.union(state.affected_water_facilities, newly_affected),
          affected_datacenters: MapSet.union(state.affected_datacenters, newly_affected_dcs)
      }

      # Why this step is or is not the last one, decided BEFORE the payload is
      # built so the step result can carry it. `nil` means the loop continues.
      termination =
        cond do
          island_solve_failed? -> :solve_failed
          Enum.empty?(thermal_trips) and Enum.empty?(non_thermal_trips) -> :settled
          true -> nil
        end

      state = %{state | termination: termination}

      step_result =
        %{
          step: state.step,
          simulated_time: state.simulated_time,
          islands: length(islands),
          trips: all_trips_this_step,
          water_facility_ids: MapSet.to_list(state.affected_water_facilities),
          datacenter_ids: MapSet.to_list(state.affected_datacenters),
          solution: island_results,
          balance: balance(state),
          voltage_layer: state.voltage_layer
        }
        |> Map.merge(step_contract(state))

      if callback, do: callback.(step_result)
      step_results = [step_result | step_results]

      case termination do
        :solve_failed ->
          {%{state | stable: false}, Enum.reverse(step_results)}

        :settled ->
          {%{state | stable: true}, Enum.reverse(step_results)}

        nil ->
          # Apply thermal trip
          state = apply_trips(state, thermal_trips)

          # Redispatch after trip (cover any generation/load imbalance)
          state = maybe_redispatch_after_trip(state)

          do_cascade(state, step_results, callback)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The step-result payload contract
  # ---------------------------------------------------------------------------
  #
  # Four quantities the engine already computes per step and used to drop on
  # the floor. All four are ADDITIVE keys — nothing already in a step result
  # changed shape or meaning:
  #
  #   :frequency        `%{f_hz:, nadir_hz:}`. Both are needed, and reporting
  #                     one as the other is the bug this closes: a settled
  #                     cascade is back at 60.00 Hz, and the dip on the way
  #                     there is the entire story of what it shed.
  #   :agc              one `PowerModel.Controls.AGC.summary/1` per island that
  #                     HAS a secondary controller, tagged with the island id.
  #                     Islands without one are omitted rather than reported as
  #                     zeros, which would be indistinguishable from a
  #                     controller that has run out of reserve.
  #   :voltage_overlay  the AC voltage products of the islands that CONVERGED.
  #                     Explicitly PARTIAL — `record.ac_voltage` is written
  #                     only from a converged FDPF solution (`record_ac_layer/3`
  #                     is its sole writer), and `nil` is the common case at
  #                     real demand — so this channel covers the islands AC
  #                     reached and says nothing whatever about the rest. It
  #                     must never be merged into a whole-grid metric.
  #   :termination      `state.termination`; see the struct field.
  defp step_contract(state) do
    %{
      frequency: frequency_summary(state),
      agc: agc_summary(state),
      voltage_overlay: voltage_overlay(state),
      termination: state.termination
    }
  end

  # Stamp the reason onto the most recent step of the REVERSED accumulator.
  # Only the budget clause needs this: it fires instead of a step rather than
  # inside one, so it has no step result of its own to write the reason into.
  defp stamp_termination([], _cause), do: []

  defp stamp_termination([latest | rest], cause),
    do: [Map.put(latest, :termination, cause) | rest]

  # Load-weighted, because an island's frequency is a statement about the load
  # base its swing equation was integrated against: a dead three-bus fragment
  # at 57 Hz must not drag the reported system frequency down beside an intact
  # interconnection carrying 40 GW.
  defp frequency_summary(state) do
    load_by_bus =
      Enum.reduce(state.loads, %{}, fn load, acc ->
        Map.update(acc, load.bus_id, load.p_mw, &(&1 + load.p_mw))
      end)

    {weighted, total_mw} =
      Enum.reduce(state.island_states, {0.0, 0.0}, fn record, {weighted, total_mw} ->
        mw = island_load_mw(record, load_by_bus)
        {weighted + mw * island_frequency_hz(record), total_mw + mw}
      end)

    f_hz = if total_mw > 0.0, do: weighted / total_mw, else: @nominal_frequency_hz

    %{f_hz: f_hz, nadir_hz: state.frequency_nadir_hz}
  end

  defp island_load_mw(record, load_by_bus) do
    Enum.reduce(record.buses, 0.0, fn bus_id, acc -> acc + Map.get(load_by_bus, bus_id, 0.0) end)
  end

  defp island_frequency_hz(%{frequency_state: %{frequency: hz}}) when is_number(hz), do: hz
  defp island_frequency_hz(_record), do: @nominal_frequency_hz

  defp agc_summary(state) do
    for record <- state.island_states, record.agc != nil do
      Map.put(AGC.summary(record.agc), :island_id, island_id(record))
    end
  end

  defp voltage_overlay(state) do
    islands =
      state.island_states
      |> Enum.map(&overlay_island/1)
      |> Enum.reject(&is_nil/1)

    %{
      islands: islands,
      covered_bus_count: Enum.sum(Enum.map(islands, & &1.bus_count)),
      undervoltage_bus_ids: Enum.flat_map(islands, & &1.undervoltage_bus_ids),
      overvoltage_bus_ids: Enum.flat_map(islands, & &1.overvoltage_bus_ids)
    }
  end

  # The `:warm_start` half of `ac_voltage` is deliberately NOT carried: it is a
  # whole FDPF solution kept for the next solve, not a product for a consumer.
  defp overlay_island(%{ac_voltage: %{vm_by_bus: vm, at_s: at}} = record) when map_size(vm) > 0 do
    {under, over} =
      Enum.reduce(vm, {[], []}, fn {bus_id, vm_pu}, {under, over} ->
        cond do
          vm_pu < @overlay_undervoltage_pu -> {[bus_id | under], over}
          vm_pu > @overlay_overvoltage_pu -> {under, [bus_id | over]}
          true -> {under, over}
        end
      end)

    %{
      island_id: island_id(record),
      at_s: at,
      bus_count: map_size(vm),
      vm_by_bus: vm,
      undervoltage_bus_ids: under,
      overvoltage_bus_ids: over
    }
  end

  defp overlay_island(_record), do: nil

  # An island's stable identifier is its lowest bus id — the same rule
  # `island_solve_failure_event/3` and `voltage_alarm_event/3` already report.
  defp island_id(record), do: Enum.min(record.buses, fn -> nil end)

  # After a line/component trips, recompute generation-load balance PER ISLAND
  # and rebalance within each: deficits raise ramp-limited reserves, SURPLUSES
  # curtail generation. An island split leaves the exporting half
  # over-dispatched -- without curtailment that surplus becomes a phantom sink
  # at the slack bus, creating fictitious flows that trip healthy lines.
  # Islands without online generation are skipped -- their loads are accounted
  # as blackouts by the island solver, not as UFLS shedding.
  #
  # Deficits are measured against the island's SUSTAINED generation, so a gap
  # currently held up by governor response still reads as a deficit and the
  # slower tiers keep working to replace it (ROADMAP item 16: primary arrests,
  # secondary replaces). Nothing here sheds load: a deficit the tiers cannot
  # reach in time is left for the step's island evaluation, which is the one
  # place that owns the frequency trajectory and everything that reads it.
  defp maybe_redispatch_after_trip(state) do
    {state, islands} = refresh_island_states(state)

    Enum.reduce(islands, state, fn island, st ->
      island_gens = online_island_gens(st, island)

      if island_gens == [] do
        st
      else
        sustained_mw = sum_mw(island_gens, &sustained_mw_of(st, &1))
        primary_mw = sum_mw(island_gens, &Map.get(st.primary_reserve, &1.id, 0.0))

        island_load =
          st.loads
          |> Enum.filter(&MapSet.member?(island, &1.bus_id))
          |> sum_mw(& &1.p_mw)

        tie_mw =
          st.dc_ties
          |> Enum.filter(&DcTie.touches?(&1, island))
          |> DcTie.net_injection_mw(island)

        sustained_deficit = island_load - sustained_mw - tie_mw
        output_surplus = sustained_mw + primary_mw + tie_mw - island_load

        st = mark_deficit_clock(st, island, sustained_deficit)

        cond do
          sustained_deficit > 0.5 -> redispatch(st, sustained_deficit, island)
          output_surplus > 0.5 -> curtail_island(st, island_gens, island_load - tie_mw)
          true -> st
        end
      end
    end)
  end

  # Re-detect islands and carry each one's frequency record across whatever
  # splitting the last trip did (see the moduledoc's inheritance rule).
  defp refresh_island_states(state) do
    islands = active_topology_islands(state)

    active_gens = Enum.reject(state.generators, &MapSet.member?(state.tripped_generators, &1.id))
    records = inherit_island_states(state.island_states, islands, state.loads, active_gens)

    {%{state | island_states: records}, islands}
  end

  # Start the island's deficit clock when a sustained gap opens, stop it when
  # the gap closes. The reserve tiers ramp on the elapsed time this records.
  defp mark_deficit_clock(state, island_bus_set, sustained_deficit) do
    now = state.simulated_time

    update_island_records(
      state,
      island_bus_set,
      &update_deficit_clock(&1, sustained_deficit, now)
    )
  end

  defp update_deficit_clock(record, sustained_deficit, now) when sustained_deficit > 0.5 do
    %{record | deficit_since_s: record.deficit_since_s || now}
  end

  # The gap closed, so the clock stops — and the ramp ledger measured against
  # it goes with it. Keeping the ledger would charge the NEXT deficit for
  # megawatts a machine ramped answering a different one.
  defp update_deficit_clock(record, _sustained_deficit, _now) do
    %{record | deficit_since_s: nil, reserve_delivered: %{}}
  end

  defp sustained_mw_of(state, generator) do
    dispatched =
      Map.get(
        state.dispatch,
        generator.id,
        generator.p_max_mw * (generator.capacity_factor || 1.0)
      )

    dispatched - Map.get(state.primary_reserve, generator.id, 0.0)
  end

  # Scale an island's generation down to match `target_mw` of net demand.
  # Transient governor MW is released first — a governor that is holding a gap
  # the island no longer has has nothing to hold — and only then is the
  # sustained operating point scaled back.
  defp curtail_island(state, island_gens, target_mw) do
    primary_released =
      Enum.reduce(island_gens, state.dispatch, fn g, d ->
        case Map.get(state.primary_reserve, g.id, 0.0) do
          mw when mw > 0.0 -> Map.update(d, g.id, 0.0, &max(&1 - mw, 0.0))
          _ -> d
        end
      end)

    primary_reserve =
      Enum.reduce(island_gens, state.primary_reserve, &Map.delete(&2, &1.id))

    sustained_mw = sum_mw(island_gens, &Map.get(primary_released, &1.id, 0.0))

    dispatch =
      if sustained_mw > 0.0 and sustained_mw > target_mw do
        factor = max(target_mw, 0.0) / sustained_mw

        Enum.reduce(island_gens, primary_released, fn g, d ->
          Map.update(d, g.id, 0.0, &(&1 * factor))
        end)
      else
        primary_released
      end

    %{state | dispatch: dispatch, primary_reserve: primary_reserve}
  end

  # ---------------------------------------------------------------------------
  # Island solving (timed variant)
  #
  # One step's work for every island, in the order the moduledoc documents:
  # reserves, trajectory, protection, recompute, residual shed, solve. Thermal
  # and zone-3 overloads are returned WITH their inverse-time trip times rather
  # than tripped here, so the caller can pick the single fastest relay.
  # ---------------------------------------------------------------------------

  defp solve_islands_timed(state, islands, records, lines, transformers) do
    ctx = %{
      buses: state.buses,
      lines: lines,
      transformers: transformers,
      dc_ties: state.dc_ties,
      base_mva: state.base_mva,
      base_overloaded: state.base_overloaded,
      base_line_loading: state.base_line_loading || %{},
      now: state.simulated_time,
      voltage_control: state.voltage_control,
      voltage_devices: state.voltage_devices,
      # Seconds since the conductor temperatures were last advanced — the
      # PREVIOUS step's clock advance, which is the only interval whose
      # duration is known when this step starts.
      conductor_dt_s: max(state.simulated_time - (state.conductor_at_s || 0.0), 0.0)
    }

    active_gens = Enum.reject(state.generators, &MapSet.member?(state.tripped_generators, &1.id))

    acc = %{
      trips: [],
      results: [],
      loads: state.loads,
      overloads: [],
      shed_mw: 0.0,
      blackout_mw: 0.0,
      dispatch: state.dispatch,
      primary_reserve: state.primary_reserve,
      btm: btm_context(state),
      records: [],
      frequency_advance_s: 0.0,
      nadir_hz: @nominal_frequency_hz,
      conductor: state.conductor_state || %{},
      voltage_layer: state.voltage_layer || fresh_voltage_layer()
    }

    islands
    |> Enum.zip(records)
    |> Enum.reduce(acc, fn {island, record}, acc ->
      solve_one_island(island, record, active_gens, acc, ctx)
    end)
  end

  defp solve_one_island(island, record, active_gens, acc, ctx) do
    island_buses = Enum.filter(ctx.buses, &MapSet.member?(island, &1.id))

    island_lines =
      Enum.filter(ctx.lines, fn l ->
        MapSet.member?(island, l.from_bus_id) and MapSet.member?(island, l.to_bus_id)
      end)

    island_xfmrs =
      Enum.filter(ctx.transformers, fn t ->
        MapSet.member?(island, t.from_bus_id) and MapSet.member?(island, t.to_bus_id)
      end)

    gens = Enum.filter(active_gens, &MapSet.member?(island, &1.bus_id))
    island_loads = Enum.filter(acc.loads, &MapSet.member?(island, &1.bus_id))

    # DC ties with a converter in this island. A tie whose far terminal is in
    # a different island contributes only its near-end injection here, which
    # is exactly how an HVDC link behaves: it transfers power without
    # synchronizing the two systems. A tie touching NO surviving island (both
    # converters on blacked-out buses) is simply never assembled, so it moves
    # nothing — a converter cannot run without an AC source to commutate
    # against.
    island_ties = Enum.filter(ctx.dc_ties, &DcTie.touches?(&1, island))
    tie_mw = DcTie.net_injection_mw(island_ties, island)

    if island_dead?(island_buses, gens) do
      acc
      |> black_out_island(island_loads)
      |> put_record(fresh_island_record(island))
      |> note_nadir(island_frequency_hz(record))
    else
      live_island(
        %{
          island: island,
          buses: island_buses,
          lines: island_lines,
          transformers: island_xfmrs,
          gens: gens,
          loads: island_loads,
          ties: island_ties,
          tie_mw: tie_mw
        },
        record,
        acc,
        ctx
      )
    end
  end

  # Every load in a generation-less island loses power. Only loads still
  # carrying demand black out (already-zeroed loads were accounted in an
  # earlier step); their p_mw is zeroed so redispatch and the frequency
  # simulation no longer see phantom demand.
  defp black_out_island(acc, island_loads) do
    lost_loads = Enum.filter(island_loads, &(&1.p_mw > 0.0))

    trips =
      Enum.map(lost_loads, fn load ->
        %{
          component_type: "load",
          component_id: load.id,
          failure_cause: "island_blackout",
          details: %{lost_mw: load.p_mw}
        }
      end)

    lost_mw = sum_mw(lost_loads, & &1.p_mw)
    lost_ids = MapSet.new(lost_loads, & &1.id)

    loads =
      Enum.map(acc.loads, fn l ->
        if MapSet.member?(lost_ids, l.id), do: %{l | p_mw: 0.0, q_mvar: 0.0}, else: l
      end)

    %{acc | trips: acc.trips ++ trips, loads: loads, blackout_mw: acc.blackout_mw + lost_mw}
  end

  defp put_record(acc, record), do: %{acc | records: [record | acc.records]}

  # The worst frequency any island touched during THIS step, folded in where
  # the trajectory that produced it is still in hand.
  #
  # Reading it back off the records afterwards cannot work, and for two
  # independent reasons. An island that DIES is replaced by a fresh record, so
  # the trajectory that killed it — the only place a collapse's real nadir
  # exists — is gone before anything could read it, and a total blackout
  # rendered 60.00 Hz (REVIEW CAS-20). And `record.exposure` is the 180 s
  # PRC-024 window, so the first step of the NEXT cascade event would re-read
  # the previous event's dip as its own (REVIEW CAS-21), defeating the rebase
  # `begin_cascade_event/1` performs precisely to stop that.
  defp note_nadir(acc, nil), do: acc
  defp note_nadir(acc, hz), do: %{acc | nadir_hz: min(acc.nadir_hz, hz)}

  # One live island, start to finish. `env` carries the island's slice of the
  # network; `record` its persistent frequency and voltage state.
  defp live_island(env, record, acc, ctx) do
    # --- 0. The voltage layer, if this island has one ------------------------
    # `nil` means the island ran DC-only last segment — the COMMON case at real
    # demand (REVIEW LIN-13) — and every voltage-driven mechanism below is
    # skipped rather than fed a flat 1.0 pu.
    voltage = voltage_layer(record, ctx.now)

    # --- 1. Voltage protection acts, ahead of anything frequency-driven ------
    # The measurement is the AC solution from the END of the previous segment,
    # integrated over the time that segment took. That ordering is forced: a
    # segment's own duration is not known until its trajectory settles, and a
    # protection cannot read a solution that has not been produced. What the
    # island holds now IS what it held then, until something below changes it.
    {env, acc, record, voltage_events, gfl} = voltage_protection(env, acc, record, ctx, voltage)

    if island_dead?(env.buses, env.gens) do
      # PRC-024 voltage protection took the last machine. Nothing to shed
      # against and nothing to solve; the island is a blackout.
      acc
      |> black_out_island(env.loads)
      |> add_trips(voltage_events)
      |> put_record(fresh_island_record(env.island))
      |> note_nadir(island_frequency_hz(record))
    else
      live_island_frequency(env, record, acc, ctx, voltage, gfl, voltage_events)
    end
  end

  # --- 2. Reserves onwards: the frequency chain, unchanged in shape ---------
  defp live_island_frequency(env, record, acc, ctx, voltage, gfl, voltage_events) do
    load_mw = sum_mw(env.loads, & &1.p_mw)

    units =
      Enum.map(env.gens, fn g ->
        sustained_unit(g, dispatch_of(acc, g), Map.get(acc.primary_reserve, g.id, 0.0))
      end)

    sustained_mw = sum_mw(deliverable(units, gfl), & &1.p_dispatch_mw)
    deficit_mw = load_mw - sustained_mw - env.tie_mw

    record = update_deficit_clock(record, deficit_mw, ctx.now)
    elapsed_s = record_elapsed(record, ctx.now)

    # Closed-loop secondary control. AGC owns the secondary tier island-wide;
    # `redispatch/4` keeps only the tertiary one, so the same headroom is never
    # drawn against twice (see `apply_sustained_reserves/4`).
    {record, agc_deltas} = step_agc(record, units, load_mw, ctx)

    alloc =
      Reserves.allocate(units, max(deficit_mw, 0.0), elapsed_s,
        secondary: {:agc, agc_deltas},
        delivered: record.reserve_delivered
      )

    record = record_reserve_delivery(record, alloc)

    raised =
      Enum.map(units, fn unit ->
        sustained = unit.p_dispatch_mw + Map.get(alloc.sustained_by_unit, unit.id, 0.0)
        {unit, sustained, Map.get(alloc.primary_by_unit, unit.id, 0.0)}
      end)

    sustained_gens =
      raised |> Enum.map(fn {unit, sustained, _p} -> shape_at(unit, sustained) end)

    available_sustained =
      sum_mw(deliverable(sustained_gens, gfl), & &1.p_dispatch_mw) + env.tie_mw

    acc = %{
      acc
      | dispatch: put_dispatch(acc.dispatch, raised),
        primary_reserve: put_primary(acc.primary_reserve, raised)
    }

    # --- 3. Trajectory evaluation -------------------------------------------
    # ONE segment of this island's frequency, resumed from where the last
    # disturbance left it. Everything below reads THIS trajectory, so the
    # rooftop inverters and the generator relays cannot disagree about what
    # the frequency did.
    {trajectory, eval_state} =
      simulate_island(
        record,
        deliverable(sustained_gens, gfl),
        env.loads,
        load_mw - available_sustained
      )

    nadir = if trajectory, do: Frequency.nadir(trajectory), else: @nominal_frequency_hz

    # --- 4. Frequency protection reads it -----------------------------------
    # IEEE 1547 legacy inverters trip on the frequency the island reached with
    # its rooftop still on, and what they leave behind is LOAD — the vicious
    # pairing of item 31: the fleet is gone at 59.3 Hz while the first UFLS
    # stage only arms BELOW 59.3 Hz.
    prior_tripped = acc.btm.tripped

    {loads, island_loads, load_mw, btm, btm_events} =
      evaluate_btm_trip(acc.btm, env.buses, env.loads, acc.loads, load_mw, nadir)

    # The other half of the Blue Cut double-count guard: a bus whose legacy
    # fleet just went at 59.3 Hz must not be tripped again by the 1547 VOLTAGE
    # elements a segment later, so the frequency trip is written into the
    # voltage timers it knows nothing about.
    record =
      mark_frequency_trips(record, btm_events, MapSet.difference(btm.tripped, prior_tripped))

    acc = %{acc | loads: loads, btm: btm}
    env = %{env | loads: island_loads}

    exposure = accumulate_exposure(record.exposure, trajectory)

    gen_trips =
      if trajectory, do: Protection.generator_frequency_trips(exposure, sustained_gens), else: []

    # --- 5. Recompute --------------------------------------------------------
    tripped_ids = MapSet.new(gen_trips, & &1.component_id)

    {survivors, acc} =
      if MapSet.size(tripped_ids) > 0 do
        {Enum.reject(raised, fn {unit, _s, _p} -> MapSet.member?(tripped_ids, unit.id) end),
         %{
           acc
           | dispatch: Enum.reduce(tripped_ids, acc.dispatch, &Map.put(&2, &1, 0.0)),
             primary_reserve: Enum.reduce(tripped_ids, acc.primary_reserve, &Map.delete(&2, &1))
         }}
      else
        {raised, acc}
      end

    tripped_mw =
      raised
      |> Enum.filter(fn {unit, _s, _p} -> MapSet.member?(tripped_ids, unit.id) end)
      |> sum_mw(fn {_unit, sustained, primary} -> sustained + primary end)

    gen_events =
      if gen_trips == [],
        do: [],
        else: gen_trips ++ [island_gen_trip_event(env, gen_trips, tripped_mw)]

    events = voltage_events ++ btm_events ++ gen_events

    surviving_gens = Enum.map(survivors, fn {unit, _s, _p} -> unit end)

    if island_dead?(env.buses, surviving_gens) do
      # The island lost every machine it had — the frequency feedback loop
      # closing on itself. What is left is a blackout, not a deficit: there is
      # nothing to shed against and nothing to solve. The segment it died in
      # still happened, so it still moves the clock — and it is the ONLY place
      # the collapse's frequency exists, so its nadir is folded in before the
      # record carrying it is thrown away.
      {advance_s, _state, _exposure, _mean, segment_nadir_hz} =
        settle_segment(trajectory, eval_state, [])

      acc
      |> black_out_island(env.loads)
      |> add_trips(events)
      |> put_record(fresh_island_record(env.island))
      |> Map.update!(:frequency_advance_s, &max(&1, advance_s))
      |> note_nadir(segment_nadir_hz)
    else
      settle_island(env, record, acc, ctx, %{
        survivors: survivors,
        events: events,
        trajectory: trajectory,
        eval_state: eval_state,
        recompute?: MapSet.size(tripped_ids) > 0 or btm_events != [],
        load_mw: load_mw,
        voltage: voltage,
        gfl: gfl
      })
    end
  end

  # --- 6. Residual shed, and 7. solve ---------------------------------------
  defp settle_island(env, record, acc, ctx, step) do
    sustained_gens = Enum.map(step.survivors, fn {u, s, _p} -> shape_at(u, s) end)
    deliverable_gens = deliverable(sustained_gens, step.gfl)
    available_sustained = sum_mw(deliverable_gens, & &1.p_dispatch_mw) + env.tie_mw

    available_output = deliverable_output_mw(step.survivors, step.gfl) + env.tie_mw

    # UVLS runs FIRST of the two shedding programs, and only on an island that
    # has an AC solution: voltage is not observable otherwise, and a stage
    # armed against a flat 1.0 pu would never fire anyway. Its stage timers
    # have already elapsed against the measurement, so what it sheds is not a
    # response to this segment's deficit — it is the segment before's voltage
    # finally running a definite-time relay out.
    {uvls_loads, uvls_events, uvls_state} =
      apply_uvls_layer(env.loads, record, step.voltage)

    record = %{record | uvls_state: uvls_state}
    uvls_shed_mw = sum_mw(uvls_events, &Map.get(&1.details, :shed_mw, 0.0))

    env = %{env | loads: uvls_loads}
    load_mw = step.load_mw - uvls_shed_mw

    imbalance_mw = load_mw - available_sustained

    # The authoritative trajectory: when the rooftop or a generator left, or
    # UVLS took a block off, the island is answering a DIFFERENT gap than the
    # evaluation saw, so the segment is re-integrated from the same starting
    # state rather than patched.
    {trajectory, eval_state} =
      if step.recompute? or uvls_shed_mw > 0.0 do
        simulate_island(record, deliverable_gens, env.loads, imbalance_mw)
      else
        {step.trajectory, step.eval_state}
      end

    lost_mw = frequency_lost_mw(record.frequency_state, imbalance_mw)

    {shed_loads, ufls_events, frequency_state} =
      if lost_mw > 0.5 do
        LoadShedding.apply_ufls_with_state(
          env.loads,
          deliverable_gens,
          load_mw - lost_mw,
          load_mw,
          frequency_state: record.frequency_state,
          duration_seconds: @frequency_window_s
        )
      else
        {env.loads, [], eval_state}
      end

    ufls_shed_mw = sum_mw(ufls_events, &Map.get(&1.details, :shed_mw, 0.0))

    step = %{step | load_mw: load_mw}

    # Residual force-shed. UFLS under-sheds when the frequency nadir stays
    # above the first stage (small deficits) or when the deficit exceeds the
    # ~30% cumulative schedule cap. The remaining PHYSICAL gap — measured
    # against the island's actual output, primary response included — must
    # still be closed, otherwise the island is silently unbalanced and the DC
    # slack absorbs unserved load that no event accounts for.
    remaining_mw = step.load_mw - available_output - ufls_shed_mw
    current_total = step.load_mw - ufls_shed_mw

    {shed_loads, force_events} =
      if remaining_mw > 0.5 and current_total > 0.0 do
        fraction = min(remaining_mw / current_total, 1.0)

        # gen/load args express exactly the remaining gap so the internal cap
        # cannot re-shed what round 1 already removed
        LoadShedding.apply_proportional_shedding(
          shed_loads,
          fraction,
          current_total - remaining_mw,
          current_total
        )
      else
        {shed_loads, []}
      end

    # Two shed totals, and the difference between them is load-bearing.
    #
    # `frequency_shed_mw` is what the SWING MODEL must be credited with. UVLS
    # is deliberately not in it: its blocks came off before `imbalance_mw` was
    # computed, so the simulator was already told about them once, and
    # crediting them again would leave `lost_mw - cumulative_shed_mw` claiming
    # an imbalance the island does not have — the exact breakage
    # `credit_shed/3` exists to prevent.
    #
    # `shed_mw` is what the ACCOUNTING must record: UVLS and UFLS open real
    # breakers on real feeders, and the conservation identity
    # `served + shed + blackout == original + btm_tripped` has to see every one
    # of those megawatts exactly once.
    shed_events = uvls_events ++ ufls_events ++ force_events
    force_shed_mw = sum_mw(force_events, &Map.get(&1.details, :shed_mw, 0.0))
    frequency_shed_mw = ufls_shed_mw + force_shed_mw
    shed_mw = uvls_shed_mw + frequency_shed_mw
    served_mw = step.load_mw - frequency_shed_mw

    shed_map = Map.new(shed_loads, &{&1.id, &1})
    loads = Enum.map(acc.loads, fn l -> Map.get(shed_map, l.id, l) end)
    island_loads = Enum.map(env.loads, fn l -> Map.get(shed_map, l.id, l) end)

    # UFLS opens breakers on FREQUENCY, so a program stage can take more load
    # off than the physical gap needed. Release the transient governor MW and
    # curtail back to what the island is actually serving, so the DC solve
    # never sees a surplus this step's own shedding created.
    #
    # Only a surplus THIS STEP created is curtailed. An island that was
    # already generating more than it serves is exporting — the fuel-anchored
    # dispatch's absolute measured MW say so — and that surplus is left where
    # it was, on the slack bus, exactly as it was before this step ran.
    {dispatch, primary_reserve} =
      if shed_mw > 0.0 and available_output > served_mw + 0.5 do
        curtail_dispatch(
          acc.dispatch,
          acc.primary_reserve,
          sustained_gens,
          served_mw - env.tie_mw
        )
      else
        {acc.dispatch, acc.primary_reserve}
      end

    solver_gens =
      step.survivors
      |> Enum.map(fn {unit, _s, _p} -> shape_at(unit, Map.get(dispatch, unit.id, 0.0)) end)
      |> deliverable(step.gfl)

    frequency_state = credit_shed(frequency_state, record.frequency_state, frequency_shed_mw)

    {advance_s, frequency_state, exposure, mean_hz, segment_nadir_hz} =
      settle_segment(trajectory, frequency_state, record.exposure)

    record =
      %{
        record
        | frequency_state: frequency_state,
          exposure: exposure,
          mean_frequency_hz: mean_hz || record.mean_frequency_hz,
          evaluated_at_s: ctx.now
      }
      |> update_deficit_clock(served_mw - available_sustained, ctx.now)

    acc =
      %{
        acc
        | loads: loads,
          dispatch: dispatch,
          primary_reserve: primary_reserve,
          shed_mw: acc.shed_mw + shed_mw,
          frequency_advance_s: max(acc.frequency_advance_s, advance_s)
      }
      |> add_trips(step.events ++ shed_events)
      |> note_nadir(segment_nadir_hz)

    solve_island_flows(%{env | loads: island_loads}, solver_gens, record, acc, ctx)
  end

  # --- 7. Power flow, and the protection that reads it ----------------------
  #
  # The DC solve is authoritative for FLOWS and always runs. The QSS-AC pass
  # (ROADMAP item 20) then attempts the same island in AC, and where it
  # converges the island gains a voltage layer for the NEXT segment plus a
  # deterministic distance-relay evaluation for this one.
  defp solve_island_flows(env, solver_gens, record, acc, ctx) do
    snapshot = %{
      buses: env.buses,
      lines: env.lines,
      transformers: env.transformers,
      generators: solver_gens,
      loads: env.loads,
      dc_ties: env.ties
    }

    try do
      solution = DCPowerFlow.solve(snapshot, base_mva: ctx.base_mva)

      # Trip times for each overloaded branch (inverse-time curve), excluding
      # lines already overloaded in the base case (model artifacts).
      timed = compute_timed_overloads(solution.line_flows, ctx.base_overloaded)

      # The SLOW timescale. Conductor temperature integrates the same rate-A
      # loading the operator display reports — NOT `trip_loading_pct/1`, whose
      # rate-C basis would understate the temperature rise by 1.35².
      {conductor, thermal_timed} =
        advance_conductors(acc.conductor, solution.line_flows, ctx)

      {ac, acc, record} = attempt_ac(snapshot, env, record, %{acc | conductor: conductor}, ctx)

      {trips, distance_timed, record} =
        voltage_dependent_protection(ac, solution, env, record, ctx)

      acc
      |> put_record(record)
      |> add_trips(trips)
      |> Map.put(:results, [solution | acc.results])
      |> Map.put(:overloads, acc.overloads ++ timed ++ thermal_timed ++ distance_timed)
    rescue
      e ->
        error = Exception.message(e)
        Logger.error("island solve raised #{error}; island dropped from this step")
        acc |> put_record(record) |> island_solve_failed(env, error)
    catch
      thrown ->
        error = inspect(thrown)
        Logger.error("island solve threw #{error}; island dropped from this step")
        acc |> put_record(record) |> island_solve_failed(env, error)
    end
  end

  # Which set of branch protections gets to run, and on what.
  #
  # > #### The heuristic and the characteristic never both fire {: .warning}
  # >
  # > `Protection.check_zone3_encroachment/6` is a PROBABILISTIC screen that
  # > needs no impedance; `Protection.distance_relay_trips/2` is the real mho
  # > characteristic and needs one. On an AC-solved island the deterministic
  # > path runs and the heuristic is skipped, because two models of the same
  # > relay would double the zone-3 trip rate on exactly the branches the
  # > phase exists to get right. A DC-only island keeps the heuristic: it is
  # > the honest degradation, not a second opinion.
  defp voltage_dependent_protection(nil, dc_solution, env, record, _ctx) do
    bus_index = dc_solution.bus_ids |> Enum.with_index() |> Map.new()

    zone3_timed =
      dc_solution.line_flows
      |> Protection.check_zone3_encroachment(
        env.lines ++ env.transformers,
        env.buses,
        dc_solution.vm_pu,
        dc_solution.va_rad,
        bus_index
      )
      # Zone 3 trips integrate duty while continuously asserted using their
      # own fixed 0.5 s timer. The cause-specific relay key keeps this duty
      # completely separate from thermal exposure on the same branch.
      |> Enum.map(&Map.put(&1, :trip_time_s, 0.5))

    {[], zone3_timed, record}
  end

  defp voltage_dependent_protection(ac, _dc_solution, env, record, ctx) do
    vm_by_bus = Map.new(Enum.zip(ac.bus_ids, ac.vm_pu))

    distance_timed =
      ac.line_flows
      |> distance_relay_inputs(env, vm_by_bus, ctx)
      |> Protection.distance_relay_trips(base_mva: ctx.base_mva)
      |> Enum.map(fn trip -> Map.put(trip, :trip_time_s, trip.details.delay_s) end)

    {alarm, record} = voltage_alarm_event(env, vm_by_bus, record)

    {List.wrap(alarm), distance_timed, record_ac_layer(record, ac, ctx)}
  end

  # The ONLY writer of `record.ac_voltage`, and it takes a converged AC
  # solution as its argument. That is what makes it structurally impossible
  # for the voltage protections in `voltage_protection/5` to be reading a DC
  # solve's flat 1.0 pu: there is no other path into the field.
  defp record_ac_layer(record, ac, ctx) do
    %{
      record
      | ac_voltage: %{
          vm_by_bus: Map.new(Enum.zip(ac.bus_ids, ac.vm_pu)),
          at_s: ctx.now,
          warm_start: ac,
          # Device positions the control loop settled at (nil when the AC
          # pass ran without controls), resumed by the next segment's solve.
          control_state: ac.voltage_control && ac.voltage_control.state
        },
        ac_failed: nil
    }
  end

  # ONE event per island for buses outside the alarm band, on a HIGH-WATER
  # MARK: it fires the first time a count is reached and stays quiet until the
  # island gets worse still.
  #
  # Two reasons, and the second is the load-bearing one:
  #
  #   * One per bus per step would bury every other cause in a national
  #     snapshot's timeline, and OTP's logger and the UI both suffer for it
  #     (the DAT-20 counter pattern).
  #   * Every entry in `acc.trips` makes `non_thermal_trips` non-empty, and a
  #     step with any non-thermal trip is by definition not settled. A level
  #     alarm re-emitted each segment therefore makes an island parked below
  #     0.85 pu run until the step budget stops it — measured at 1,050 steps
  #     before this was edge-triggered. An alarm must not be able to keep a
  #     cascade alive.
  #
  # This supersedes `Protection.check_voltage_violations/3` on the cascade
  # path, which was reading the DC solve's flat 1.0 pu and could never fire.
  defp voltage_alarm_event(env, vm_by_bus, record) do
    {low, high, worst} =
      Enum.reduce(vm_by_bus, {0, 0, 1.0}, fn {_id, vm}, {low, high, worst} ->
        cond do
          vm < @voltage_alarm_low_pu -> {low + 1, high, min(worst, vm)}
          vm > @voltage_alarm_high_pu -> {low, high + 1, worst}
          true -> {low, high, worst}
        end
      end)

    {seen_low, seen_high} = record.voltage_alarm || {0, 0}

    if low <= seen_low and high <= seen_high do
      {nil, record}
    else
      event = %{
        component_type: "island",
        component_id: env.buses |> Enum.map(& &1.id) |> Enum.min(),
        failure_cause: "voltage_violation",
        details: %{
          undervoltage_buses: low,
          overvoltage_buses: high,
          vm_pu_min: worst,
          bus_count: map_size(vm_by_bus)
        }
      }

      {event, %{record | voltage_alarm: {max(low, seen_low), max(high, seen_high)}}}
    end
  end

  # A numerical failure is not evidence that a live island lost load, so its
  # loads remain served. The explicit event plus error log is the honesty
  # mechanism, while consumption conservation is unchanged.
  defp island_solve_failed(acc, env, error) do
    add_trips(acc, [island_solve_failure_event(env.buses, env.loads, error)])
  end

  defp add_trips(acc, []), do: acc
  defp add_trips(acc, trips), do: %{acc | trips: acc.trips ++ trips}

  defp dispatch_of(acc, generator) do
    Map.get(acc.dispatch, generator.id, generator.p_max_mw * (generator.capacity_factor || 1.0))
  end

  # A unit's whole output — sustained plus whatever primary response it is
  # holding — is what the network sees; the split is what the swing model and
  # the slower reserve tiers need (ROADMAP item 16).
  defp put_dispatch(dispatch, raised) do
    Enum.reduce(raised, dispatch, fn {unit, sustained, primary}, d ->
      Map.put(d, unit.id, sustained + primary)
    end)
  end

  defp put_primary(primary_reserve, raised) do
    Enum.reduce(raised, primary_reserve, fn {unit, _sustained, primary}, p ->
      if primary > 0.0, do: Map.put(p, unit.id, primary), else: Map.delete(p, unit.id)
    end)
  end

  defp shape_at(unit, mw) do
    %{unit | p_max_mw: mw, capacity_factor: 1.0} |> Map.put(:p_dispatch_mw, mw)
  end

  defp record_elapsed(%{deficit_since_s: nil}, _now), do: :infinity
  defp record_elapsed(%{deficit_since_s: opened_at}, now), do: max(now - opened_at, 0.0)

  # Curtail an island's generation back to `target_mw`, releasing transient
  # governor MW first. Pure: takes and returns the dispatch maps.
  defp curtail_dispatch(dispatch, primary_reserve, gens, target_mw) do
    released =
      Enum.reduce(gens, dispatch, fn g, d ->
        case Map.get(primary_reserve, g.id, 0.0) do
          mw when mw > 0.0 -> Map.update(d, g.id, 0.0, &max(&1 - mw, 0.0))
          _ -> d
        end
      end)

    primary_reserve = Enum.reduce(gens, primary_reserve, &Map.delete(&2, &1.id))
    sustained_mw = sum_mw(gens, &Map.get(released, &1.id, 0.0))

    dispatch =
      if sustained_mw > 0.0 and sustained_mw > target_mw do
        factor = max(target_mw, 0.0) / sustained_mw
        Enum.reduce(gens, released, fn g, d -> Map.update(d, g.id, 0.0, &(&1 * factor)) end)
      else
        released
      end

    {dispatch, primary_reserve}
  end

  # ---------------------------------------------------------------------------
  # Island frequency: one segment, and what the cascade reads off it
  # ---------------------------------------------------------------------------

  # Integrate one window of this island's frequency, resuming from its state.
  # Returns `{trajectory | nil, state}`; nil means nothing happened and there
  # was nothing to integrate — an island at nominal with no new imbalance
  # costs nothing at all, which is the overwhelmingly common case.
  defp simulate_island(record, gens, loads, imbalance_mw) do
    lost_mw = frequency_lost_mw(record.frequency_state, imbalance_mw)

    if abs(lost_mw) > @imbalance_epsilon_mw or in_excursion?(record.frequency_state) do
      Frequency.simulate_with_state(gens, loads, lost_mw,
        initial_state: record.frequency_state,
        duration_seconds: @frequency_window_s
      )
    else
      {nil, record.frequency_state}
    end
  end

  # The NEW imbalance to hand the swing model, given what it has already been
  # told (ROADMAP item 15).
  #
  # `Frequency`'s balance is `-lost_mw + governor + its own UFLS shed`, so the
  # imbalance it believes in is `lost_mw - cumulative_shed_mw`. The cascade
  # sheds outside the simulator too (the force-shed tier), raises reserves
  # between segments, and loses generators mid-step; every one of those moves
  # the physical imbalance without the simulator knowing. So each segment is
  # told the DIFFERENCE between the imbalance the island actually has and the
  # one the state implies — which is negative when the cascade closed part of
  # the gap, and that is exactly how secondary reserve replacing primary
  # response reaches the frequency model.
  #
  # A SURPLUS is floored at zero rather than handed over as an over-frequency
  # excursion. An island generating more than it serves is exporting — that is
  # what the fuel-anchored dispatch's absolute measured MW mean — and the model
  # has no representation for the export beyond the slack bus. Handing the
  # swing model a negative imbalance would turn every net-exporting balancing
  # authority into a 61.8 Hz over-frequency trip. The cost, stated plainly: the
  # over-frequency half of the PRC-024 envelope cannot fire from a dispatch
  # surplus, only from an over-shed inside a single trajectory.
  defp frequency_lost_mw(nil, imbalance_mw), do: max(imbalance_mw, 0.0)

  defp frequency_lost_mw(state, imbalance_mw) do
    max(imbalance_mw, 0.0) + Map.get(state, :cumulative_shed_mw, 0.0) -
      Map.get(state, :lost_mw, 0.0)
  end

  # Credit the frequency state with the megawatts the cascade ACTUALLY shed,
  # which is not the same number the simulator shed internally.
  #
  # The simulator's UFLS stages fire on frequency and take a fixed share of
  # connected load; `LoadShedding.apply_proportional_shedding/5` then caps the
  # applied shed at the deficit, and the force-shed tier adds whatever the
  # program left uncovered. Leaving the simulator believing its own figure
  # breaks the invariant every resumed segment depends on —
  # `lost_mw - cumulative_shed_mw` must equal the island's PHYSICAL imbalance
  # — and the breakage compounds: an over-shedding stage would make the next
  # segment believe in an imbalance that does not exist, shed for it, and do
  # it again on the step after that.
  #
  # Both rounds count. UFLS and the force-shed tier open real breakers, and
  # the load behind them is gone either way.
  defp credit_shed(nil, _prior, _applied_mw), do: nil

  defp credit_shed(state, prior, applied_mw) do
    prior_shed = if prior, do: Map.get(prior, :cumulative_shed_mw, 0.0), else: 0.0
    %{state | cumulative_shed_mw: prior_shed + applied_mw}
  end

  defp in_excursion?(nil), do: false

  defp in_excursion?(state) do
    abs(Map.get(state, :frequency, @nominal_frequency_hz) - @nominal_frequency_hz) >
      @excursion_epsilon_hz
  end

  # Generator protection reads the island's recent history, not just this
  # segment: the PRC-024 envelope's allowances run to 180 s, which no single
  # 30 s window can exhaust. Older samples are dropped because they can no
  # longer change a verdict.
  defp accumulate_exposure(exposure, nil), do: exposure

  defp accumulate_exposure(exposure, trajectory) do
    combined = exposure ++ trajectory
    cutoff = List.last(combined).time - @exposure_window_s

    Enum.filter(combined, &(&1.time >= cutoff))
  end

  # How much simulated time this segment actually took, and the state and
  # exposure truncated to match (REVIEW CAS-16, see the moduledoc's clock
  # section). A trajectory that settles after 4 s of a 30 s window advances
  # the clock 4 s, and the island's own frequency clock is rewound with it so
  # the two never drift apart.
  # Returns `{advance_s, state, exposure, mean_hz, nadir_hz}`. The mean is the
  # segment's own average frequency over the interval it actually took, which
  # is what the island's AGC measures on the next segment — BAL-003's "value B"
  # reading, for the same reason: one sample of an oscillating trajectory is
  # not the frequency the controller is answering.
  #
  # The nadir is over the SAME trimmed interval, for the same reason the clock
  # is: a dip in the part of the window the segment never reached did not
  # happen. It is returned here rather than recovered from `exposure` because
  # this is the last point at which the segment is distinguishable from the
  # 180 s of history the exposure window carries (REVIEW CAS-21).
  defp settle_segment(nil, state, exposure), do: {0.0, state, exposure, nil, nil}

  defp settle_segment(trajectory, state, exposure) do
    started_at = hd(trajectory).time
    settled_at = settle_time(trajectory)

    trimmed = Enum.filter(trajectory, &(&1.time <= settled_at))
    mean_hz = Frequency.mean_frequency(trimmed, started_at, settled_at)

    {settled_at - started_at, %{state | time: settled_at}, accumulate_exposure(exposure, trimmed),
     mean_hz, Frequency.nadir(trimmed)}
  end

  # The earliest time from which the trajectory never moves again: every later
  # sample within @settle_tolerance_hz of the final frequency, with no further
  # load shed.
  defp settle_time(trajectory) do
    last = List.last(trajectory)

    trajectory
    |> Enum.reverse()
    |> Enum.reduce_while(last.time, fn record, earliest ->
      if abs(record.frequency - last.frequency) <= @settle_tolerance_hz and
           record.load_shed_mw == last.load_shed_mw do
        {:cont, record.time}
      else
        {:halt, earliest}
      end
    end)
  end

  # One aggregated event per island per step, beside the individual generator
  # trips: a national snapshot can lose thousands of machines in one step and
  # the timeline needs a single line that says so.
  defp island_gen_trip_event(env, gen_trips, tripped_mw) do
    %{details: details, failure_cause: cause} = hd(gen_trips)

    %{
      component_type: "island",
      component_id: env.buses |> Enum.map(& &1.id) |> Enum.min(),
      failure_cause: "generator_frequency_trips",
      details: %{
        unit_count: length(gen_trips),
        tripped_mw: tripped_mw,
        trip_cause: cause,
        band_hz: Map.get(details, :band_hz),
        frequency_hz: Map.get(details, :frequency_hz)
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Behind-the-meter solar: IEEE 1547 inverter tripping (ROADMAP item 31)
  # ---------------------------------------------------------------------------

  # The per-step BTM working set. `by_bus` is fixed for the run; `tripped`
  # carries forward across steps (and across island re-splits, since it is
  # keyed by bus); `tripped_mw` accumulates only what THIS pass tripped, so the
  # caller adds it to the state's running total exactly once.
  defp btm_context(%__MODULE__{} = state) do
    %{
      by_bus: state.btm_by_bus || %{},
      # The vintage-split view the 1547 VOLTAGE elements read. `by_bus` above
      # is the legacy-only view the 59.3 Hz frequency must-trip reads; the two
      # are gated against each other in `island_btm_fleet/2`, never summed.
      fleet: state.btm_fleet_by_bus || %{},
      tripped: state.btm_tripped_buses || MapSet.new(),
      tripped_mw: 0.0,
      breakdown: state.btm_trip_breakdown || BtmSolar.fresh_trip_breakdown()
    }
  end

  # Evaluate the legacy behind-the-meter fleet of ONE island against the
  # frequency it reaches and the voltage its buses hold.
  #
  # Returns `{all_loads, island_loads, island_load_mw, btm, events}` — the load
  # lists are grossed up in place so both the deficit arithmetic that follows
  # and the DC solve see the new demand within this same step.
  #
  # `nadir` is the low point of the island's OWN frequency trajectory for this
  # step — the same trajectory the generator relays and (a moment later) UFLS
  # read, so no two mechanisms can hold different opinions about what the
  # frequency did. An island with no excursion to evaluate is handed nominal.
  defp evaluate_btm_trip(btm, island_buses, island_loads, all_loads, island_load_mw, nadir) do
    case btm_candidates(btm, island_buses) do
      [] ->
        # No rooftop left to lose in this island. The overwhelmingly common
        # case (no layer, night, already tripped), and it costs nothing.
        {all_loads, island_loads, island_load_mw, btm, []}

      candidates ->
        tripping =
          Enum.filter(candidates, fn {_bus_id, _legacy_mw} -> nadir <= @btm_trip_frequency_hz end)

        apply_btm_trip(btm, tripping, island_loads, all_loads, island_load_mw, nadir)
    end
  end

  # Buses in this island that still have legacy rooftop to lose to FREQUENCY.
  #
  # > #### Voltage is not evaluated here {: .info}
  # >
  # > This path used to carry the 1547-2003 0.88 pu term as well, reading
  # > `bus.vm_pu` — a snapshot field the DC solve never writes back, so it sat
  # > at a flat 1.0 pu and could not fire. Now that the QSS-AC pass produces
  # > real magnitudes the voltage half belongs to
  # > `PowerModel.Grid.BtmSolar.voltage_trips/5`, which carries the real
  # > definite-time elements and the legacy/modern vintage split. Keeping an
  # > instantaneous second copy here would trip the same megawatts twice.
  defp btm_candidates(btm, island_buses) do
    Enum.reduce(island_buses, [], fn bus, acc ->
      legacy_mw = Map.get(btm.by_bus, bus.id, 0.0)

      if legacy_mw > 0.0 and not MapSet.member?(btm.tripped, bus.id) do
        [{bus.id, legacy_mw} | acc]
      else
        acc
      end
    end)
  end

  defp apply_btm_trip(btm, [], island_loads, all_loads, island_load_mw, _nadir) do
    {all_loads, island_loads, island_load_mw, btm, []}
  end

  defp apply_btm_trip(btm, tripping, island_loads, all_loads, island_load_mw, nadir) do
    loads_by_bus = Enum.group_by(island_loads, & &1.bus_id)

    {additions, tripped_mw, tripped_bus_ids} =
      Enum.reduce(tripping, {%{}, 0.0, []}, fn {bus_id, legacy_mw},
                                               {additions, tripped_mw, bus_ids} ->
        bus_loads = Map.get(loads_by_bus, bus_id, [])
        bus_load_mw = Enum.sum(Enum.map(bus_loads, & &1.p_mw))

        if bus_load_mw <= 0.0 do
          # Nothing energized at this bus to hand the demand back to: the load
          # is already dark (blacked out, or fully shed), and rooftop behind a
          # de-energized feeder is disconnected with it. Left untripped rather
          # than tripped-for-zero, so it is re-evaluated if it ever comes back.
          {additions, tripped_mw, bus_ids}
        else
          additions =
            Enum.reduce(bus_loads, additions, fn load, acc ->
              share = legacy_mw * load.p_mw / bus_load_mw
              Map.update(acc, load.id, share, &(&1 + share))
            end)

          {additions, tripped_mw + legacy_mw, [bus_id | bus_ids]}
        end
      end)

    if tripped_mw <= 0.0 do
      {all_loads, island_loads, island_load_mw, btm, []}
    else
      # ONE event for the whole island's trip, never one per bus: a national
      # snapshot has tens of thousands of BTM buses and per-bus events would
      # bury every other cause in the timeline (the DAT-20 counter pattern).
      # `component_id` is the island's lowest bus id, matching how island-level
      # events already identify themselves.
      event = %{
        component_type: "btm_solar",
        component_id: Enum.min(tripped_bus_ids),
        failure_cause: "btm_trip",
        details: %{
          tripped_mw: tripped_mw,
          bus_count: length(tripped_bus_ids),
          nadir: nadir
        }
      }

      btm = %{
        btm
        | tripped: MapSet.union(btm.tripped, MapSet.new(tripped_bus_ids)),
          tripped_mw: btm.tripped_mw + tripped_mw,
          breakdown: BtmSolar.record_trip(btm.breakdown, :frequency, tripped_mw)
      }

      {gross_up_loads(all_loads, additions), gross_up_loads(island_loads, additions),
       island_load_mw + tripped_mw, btm, [event]}
    end
  end

  # Hand the tripped rooftop MW back to the loads at its own bus, split by each
  # load's share of that bus's remaining demand.
  #
  # `q_mvar` is deliberately untouched: 1547 inverters run at or near unity
  # power factor, so losing them releases real power and essentially no
  # reactive power. The reactive side of distributed PV is Q-V territory.
  defp gross_up_loads(loads, additions) do
    Enum.map(loads, fn load ->
      case Map.get(additions, load.id) do
        nil -> load
        added_mw -> %{load | p_mw: load.p_mw + added_mw}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # The voltage chain (ROADMAP item 20)
  #
  # Everything below reads ONE quantity: `record.ac_voltage`, written only by
  # `record_ac_layer/3` from a converged FDPF solution. There is no other way
  # into that field, which is how the hard rule — no voltage-sensitive
  # protection ever reads a DC solve — is enforced structurally rather than by
  # remembering to.
  # ---------------------------------------------------------------------------

  # The island's voltage measurement and how long it has been standing, or
  # `nil` when the island has none. `nil` is the COMMON case at real demand:
  # REVIEW LIN-13 measured that no interconnection has an AC solution there,
  # so the whole chain below is a no-op until the Phase 2 network work lands.
  defp voltage_layer(%{ac_voltage: %{vm_by_bus: vm, at_s: at}}, now) when map_size(vm) > 0 do
    %{vm: vm, dt_s: max(now - at, 0.0)}
  end

  defp voltage_layer(_record, _now), do: nil

  # Everything the voltage layer does to an island, before the frequency chain
  # sees the island at all. Returns the island with its rooftop grossed up and
  # its voltage-tripped machines removed, plus the GFL availability ceiling the
  # rest of the step reasons about.
  defp voltage_protection(env, acc, record, _ctx, nil), do: {env, acc, record, [], %{}}

  defp voltage_protection(env, acc, record, _ctx, voltage) do
    dispatched = apply_dispatch(env.gens, acc.dispatch)

    # Grid-following inverters are current sources behind a ceiling: below the
    # knee they cannot hold their dispatched P and the deliverable power
    # follows the terminal voltage down. This is a quasi-steady AVAILABILITY
    # ceiling, never written into `dispatch` — a schedule the derate had
    # rewritten downward could not recover when the voltage did, and the next
    # segment would recompute the derate against the already-derated number.
    #
    # Which pool: every inverter-coupled unit in the island, utility-scale or
    # onsite. `PowerModel.Dispatch` places onsite solar and wind outside the
    # EIA-930 fuel-anchored pool, so derating those changes the island's
    # generation without changing any measured fuel target — physically right
    # and invisible to fuel-mix TV distance. A cascade is not a TV measurement.
    gfl = gfl_availability(dispatched, voltage.vm)

    {env, acc, record, btm_events} = voltage_btm_trip(env, acc, record, voltage)

    {env, acc, record, gen_events} =
      voltage_gen_trips(env, acc, record, dispatched, voltage)

    {env, acc, record, btm_events ++ gen_events, gfl}
  end

  @doc false
  # The grid-following availability ceiling for a dispatched fleet, as
  # `%{generator_id => fraction}`.
  #
  # `Protection.gfl_derate/3` takes ONE `:p_set_pu` for the whole list, and its
  # default is 1.0 — every inverter flat out. That default is wrong for almost
  # every unit the cascade actually holds: the ceiling is `min(P_set, V·Imax)`
  # in per-unit of RATING, so a 100 MW farm dispatched at 20 MW sits at 0.20 pu
  # and its 1.2 pu current limit does not bind until the terminal voltage falls
  # below 0.167 pu. Charging it the flat-out derate at 0.60 pu took 5.6 MW of
  # the 20 MW away — generation that never existed to lose, landing in the
  # deficit and driving UFLS (REVIEW CAS-19). So each unit is asked with its
  # OWN set point, which `apply_dispatch/2` has already put on the map.
  def gfl_availability(dispatched, vm_by_bus) do
    Enum.reduce(dispatched, %{}, fn gen, acc ->
      Map.merge(acc, Protection.gfl_derate([gen], vm_by_bus, p_set_pu: gfl_set_point_pu(gen)))
    end)
  end

  # The unit's operating point as a fraction of its rating. A unit with no
  # rating to divide by falls back to the flat-out assumption, which is the
  # conservative reading of a missing nameplate.
  defp gfl_set_point_pu(gen) do
    nameplate = Map.get(gen, :p_nameplate_mw) || Map.get(gen, :p_max_mw) || 0.0
    dispatched = Map.get(gen, :p_dispatch_mw) || Map.get(gen, :p_max_mw) || 0.0

    if nameplate > 0.0, do: max(dispatched, 0.0) / nameplate, else: 1.0
  end

  # IEEE 1547 voltage trips on the behind-the-meter fleet — the actual Blue Cut
  # mechanism, and a LOAD INCREASE exactly like the 59.3 Hz frequency trip.
  defp voltage_btm_trip(env, acc, record, voltage) do
    case island_btm_fleet(acc, env) do
      fleet when map_size(fleet) == 0 ->
        {env, acc, record, []}

      fleet ->
        {trips_by_bus, state} =
          BtmSolar.voltage_trips(fleet, voltage.vm, record.btm_voltage_state, voltage.dt_s)

        record = %{record | btm_voltage_state: state}

        case BtmSolar.tripped_mw_by_bus(trips_by_bus) do
          mw_by_bus when map_size(mw_by_bus) == 0 ->
            {env, acc, record, []}

          mw_by_bus ->
            {all_loads, island_loads, tripped_mw} =
              gross_up_by_bus(acc.loads, env.loads, mw_by_bus)

            # Only a bus that lost LEGACY megawatts joins `btm_tripped_buses`:
            # that set gates the 59.3 Hz frequency must-trip, which can only
            # ever take legacy. A bus that lost only its modern (1547-2018)
            # share still has legacy rooftop for the frequency side to find.
            legacy_buses =
              for {bus_id, detail} <- trips_by_bus,
                  detail.by_vintage.legacy > 0.0,
                  do: bus_id

            btm = %{
              acc.btm
              | tripped: MapSet.union(acc.btm.tripped, MapSet.new(legacy_buses)),
                tripped_mw: acc.btm.tripped_mw + tripped_mw,
                breakdown: BtmSolar.record_trip(acc.btm.breakdown, :voltage, tripped_mw)
            }

            {%{env | loads: island_loads}, %{acc | loads: all_loads, btm: btm}, record,
             [BtmSolar.voltage_trip_event(trips_by_bus)]}
        end
    end
  end

  # The rooftop fleet this island still has to lose to VOLTAGE, gated three
  # ways so the two Blue Cut halves can never trip the same megawatts:
  #
  #   * a bus whose legacy fleet already went at 59.3 Hz contributes only its
  #     modern share (`btm_tripped_buses`, the cascade's own set);
  #   * a vintage the voltage timers already tripped is skipped inside
  #     `BtmSolar.voltage_trips/5` itself;
  #   * a bus with no energized load is omitted entirely rather than tripped
  #     for zero — rooftop behind a de-energized feeder is already
  #     disconnected, and omitting it HOLDS its timers instead of resetting
  #     them, which is the same rule a missing measurement gets.
  defp island_btm_fleet(acc, env) do
    load_by_bus =
      Enum.reduce(env.loads, %{}, fn l, m -> Map.update(m, l.bus_id, l.p_mw, &(&1 + l.p_mw)) end)

    Enum.reduce(env.buses, %{}, fn bus, fleet ->
      mw = Map.get(acc.btm.fleet, bus.id)

      cond do
        is_nil(mw) ->
          fleet

        Map.get(load_by_bus, bus.id, 0.0) <= 0.0 ->
          fleet

        true ->
          mw =
            if MapSet.member?(acc.btm.tripped, bus.id),
              do: %{mw | legacy_mw: 0.0},
              else: mw

          if mw.legacy_mw > 0.0 or mw.modern_mw > 0.0, do: Map.put(fleet, bus.id, mw), else: fleet
      end
    end)
  end

  # Hand `mw_by_bus` back to the loads at each bus, split by each load's share
  # of that bus's demand. Returns `{all_loads, island_loads, added_mw}`.
  defp gross_up_by_bus(all_loads, island_loads, mw_by_bus) do
    loads_by_bus = Enum.group_by(island_loads, & &1.bus_id)

    {additions, added_mw} =
      Enum.reduce(mw_by_bus, {%{}, 0.0}, fn {bus_id, mw}, {additions, total} ->
        bus_loads = Map.get(loads_by_bus, bus_id, [])
        bus_load_mw = sum_mw(bus_loads, & &1.p_mw)

        if bus_load_mw <= 0.0 or mw <= 0.0 do
          {additions, total}
        else
          additions =
            Enum.reduce(bus_loads, additions, fn load, acc ->
              Map.update(
                acc,
                load.id,
                mw * load.p_mw / bus_load_mw,
                &(&1 + mw * load.p_mw / bus_load_mw)
              )
            end)

          {additions, total + mw}
        end
      end)

    {gross_up_loads(all_loads, additions), gross_up_loads(island_loads, additions), added_mw}
  end

  # PRC-024 generator voltage ride-through. Cumulative band timers, so a
  # machine that dips in and out of a band still exhausts its allowance —
  # the opposite convention from UVLS's definite-time elements, and both are
  # right for what they model.
  defp voltage_gen_trips(env, acc, record, dispatched, voltage) do
    {trips, state} =
      Protection.generator_voltage_trips(
        dispatched,
        voltage.vm,
        record.gen_voltage_state,
        voltage.dt_s
      )

    record = %{record | gen_voltage_state: state}

    if trips == [] do
      {env, acc, record, []}
    else
      ids = MapSet.new(trips, & &1.component_id)
      lost_mw = sum_mw(Enum.filter(dispatched, &MapSet.member?(ids, &1.id)), & &1.p_max_mw)

      env = %{env | gens: Enum.reject(env.gens, &MapSet.member?(ids, &1.id))}

      acc = %{
        acc
        | dispatch: Enum.reduce(ids, acc.dispatch, &Map.put(&2, &1, 0.0)),
          primary_reserve: Enum.reduce(ids, acc.primary_reserve, &Map.delete(&2, &1))
      }

      {env, acc, record, trips ++ [island_voltage_trip_event(env, trips, lost_mw)]}
    end
  end

  # One aggregated event per island per step beside the individual generator
  # trips, for the same reason the frequency side has one: a national snapshot
  # can lose thousands of machines in a segment and the timeline needs a single
  # line that says so.
  defp island_voltage_trip_event(env, trips, lost_mw) do
    %{details: details, failure_cause: cause} = hd(trips)

    %{
      component_type: "island",
      component_id: env.buses |> Enum.map(& &1.id) |> Enum.min(),
      failure_cause: "generator_voltage_trips",
      details: %{
        unit_count: length(trips),
        tripped_mw: lost_mw,
        trip_cause: cause,
        band_pu: Map.get(details, :band_pu),
        vm_pu: Map.get(details, :vm_pu)
      }
    }
  end

  # The 59.3 Hz frequency must-trip written into the 1547 VOLTAGE timers it
  # knows nothing about, so the voltage side cannot take the same legacy
  # megawatts a segment later. The complementary gate — legacy zeroed for
  # already-tripped buses — is in `island_btm_fleet/2`.
  defp mark_frequency_trips(record, [], _newly), do: record

  defp mark_frequency_trips(record, _events, newly) do
    state =
      Enum.reduce(newly, record.btm_voltage_state, fn bus_id, state ->
        BtmSolar.mark_tripped(state, bus_id, [:legacy])
      end)

    %{record | btm_voltage_state: state}
  end

  # UVLS runs ONLY where there is a voltage to run it on. An island without an
  # AC solution has no observable voltage, and shedding against an assumed one
  # would be inventing the collapse rather than finding it.
  defp apply_uvls_layer(loads, record, nil), do: {loads, [], record.uvls_state}

  defp apply_uvls_layer(loads, record, voltage) do
    LoadShedding.apply_uvls_with_state(loads, voltage.vm, voltage.dt_s,
      uvls_state: record.uvls_state
    )
  end

  # A unit's deliverable output under the GFL current ceiling. Applied at every
  # point the island's DELIVERABLE generation is read — the balance, the swing
  # model, the shed arithmetic, the solver injections — and nowhere else, so
  # the dispatch schedule the derate is computed against never moves.
  defp deliverable(gens, gfl) when map_size(gfl) == 0, do: gens

  defp deliverable(gens, gfl) do
    Enum.map(gens, fn g ->
      case Map.get(gfl, g.id) do
        nil -> g
        fraction when fraction >= 1.0 -> g
        fraction -> shape_at(g, (Map.get(g, :p_dispatch_mw) || g.p_max_mw) * fraction)
      end
    end)
  end

  # Total output the survivors can actually deliver, governor response
  # included. Same ceiling, applied to the `{unit, sustained, primary}` shape
  # the reserve tiers work in.
  defp deliverable_output_mw(survivors, gfl) do
    Enum.reduce(survivors, 0.0, fn {unit, sustained, primary}, total ->
      total + (sustained + primary) * min(Map.get(gfl, unit.id, 1.0), 1.0)
    end)
  end

  # ---------------------------------------------------------------------------
  # Closed-loop secondary control (AGC)
  # ---------------------------------------------------------------------------

  # One AGC cycle for this island: it measures the MEAN frequency of the
  # previous segment over the time that segment took, and returns the setpoint
  # INCREMENT for this one.
  #
  # The mean, not the endpoint: sampling the trajectory's last value
  # over-commands, because the endpoint of an arrested excursion is its
  # deepest sustained point rather than its average error.
  #
  # The increment, never the cumulative position: the cascade adds the
  # allocation to its dispatch and re-derives the next step's deficit from the
  # raised dispatch, so a cumulative figure would be re-credited every step.
  #
  # `dt` is the CASCADE clock's advance, not the island's frequency-segment
  # advance, and those differ whenever a slow relay decides the step — a
  # branch a hair over pickup can carry a 990-second inverse-time curve while
  # the swing model integrates 30 seconds and stops. The cascade clock is the
  # right one: 990 seconds of wall time really did pass, and a controller that
  # only ever credited the 30 seconds the swing model bothered to simulate
  # would systematically under-deliver secondary control on exactly the steps
  # where there was most time to deliver it. The integral is bounded either
  # way — AGC back-calculates it to the command the fleet actually achieved.
  defp step_agc(record, units, load_mw, ctx) do
    agc = record.agc || AGC.init(units, load_mw: load_mw)
    dt = max(ctx.now - (record.evaluated_at_s || ctx.now), 0.0)

    if dt <= 0.0 do
      {%{record | agc: agc}, %{}}
    else
      telemetry = %{frequency_hz: record.mean_frequency_hz || @nominal_frequency_hz}
      {agc, deltas} = AGC.step(agc, telemetry, dt)
      {%{record | agc: agc}, deltas}
    end
  end

  # ---------------------------------------------------------------------------
  # QSS-AC: the per-island FDPF attempt
  # ---------------------------------------------------------------------------

  # Attempt AC on this island, warm-started from the previous segment where the
  # topology allows it. Returns `{solution | nil, acc, record}`; `nil` means the
  # island runs exactly as it did before this wave — DC plus the frequency
  # chain, with the voltage layer skipped.
  defp attempt_ac(snapshot, env, record, acc, ctx) do
    if ac_retry?(record.ac_failed, env) do
      case run_fdpf(snapshot, record, ctx) do
        {:ok, solution} ->
          {solution, count_voltage(acc, :islands_ac, :ac_solves), record}

        :error ->
          {nil, count_voltage(acc, :islands_dc_only, :ac_diverged),
           %{record | ac_failed: ac_fingerprint(env), ac_voltage: nil}}
      end
    else
      # Nothing about this island has moved since AC last failed on it, so
      # nothing about the answer would either. REVIEW LIN-13 makes this the
      # steady state at real demand, and re-solving a provably infeasible
      # 50,000-bus island every step for fifty steps is the difference between
      # a cascade that runs and one that does not.
      {nil, count_voltage(acc, :islands_dc_only, :ac_skipped), record}
    end
  end

  defp ac_retry?(nil, _env), do: true

  defp ac_retry?(%{buses: buses, branches: branches, load_mw: load_mw}, env) do
    buses != length(env.buses) or branches != length(env.lines) + length(env.transformers) or
      abs(sum_mw(env.loads, & &1.p_mw) - load_mw) > @ac_retry_load_fraction * max(load_mw, 1.0)
  end

  defp ac_fingerprint(env) do
    %{
      buses: length(env.buses),
      branches: length(env.lines) + length(env.transformers),
      load_mw: sum_mw(env.loads, & &1.p_mw)
    }
  end

  defp run_fdpf(snapshot, record, ctx) do
    opts = [base_mva: ctx.base_mva]

    opts =
      case record.ac_voltage do
        %{warm_start: %{} = warm} -> Keyword.put(opts, :warm_start, warm)
        _ -> opts
      end

    result =
      if Map.get(ctx, :voltage_control, false) do
        # The island's share of the base snapshot's devices, resuming the
        # positions its previous segment settled at. Positions are keyed by
        # device id, so they survive an island splitting or merging.
        devices = island_devices(Map.get(ctx, :voltage_devices, []), snapshot)

        opts =
          case record.ac_voltage do
            %{control_state: %{} = st} -> Keyword.put(opts, :control_state, st)
            _ -> opts
          end

        VoltageControl.solve(snapshot, Keyword.put(opts, :devices, devices))
      else
        FDPF.solve(snapshot, opts)
      end

    case result do
      {:ok, %{converged: true} = solution} -> {:ok, solution}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _kind, _payload -> :error
  end

  defp island_devices(devices, snapshot) do
    buses = MapSet.new(snapshot.buses, & &1.id)
    xfmrs = MapSet.new(Map.get(snapshot, :transformers, []), & &1.id)

    Enum.filter(devices, fn
      %{type: :ltc, transformer_id: id} -> MapSet.member?(xfmrs, id)
      %{type: :switched_shunt, bus_id: id} -> MapSet.member?(buses, id)
      _ -> false
    end)
  end

  defp count_voltage(acc, island_key, attempt_key) do
    layer =
      acc.voltage_layer
      |> Map.update!(island_key, &(&1 + 1))
      |> Map.update!(attempt_key, &(&1 + 1))

    %{acc | voltage_layer: layer}
  end

  # Per-branch inputs for the mho characteristic, from the AC solution.
  #
  # `z_adjacent` is the LONGEST line leaving each branch's remote bus, which is
  # what makes zone 3 a SETTING rather than a screen: without it the reach
  # defaults to the protected line itself, which is not a remote-backup zone at
  # all. `rating_mva` is the highest tier the branch carries (rate C where it
  # has one), because PRC-023 states its blinder against the highest seasonal
  # facility rating.
  #
  # Branches already past relay pickup in the base case are excluded, exactly
  # as they are for overcurrent: their loading is a data defect, and the
  # blinder that would otherwise hold them is computed from the same suspect
  # ratings.
  defp distance_relay_inputs(line_flows, env, vm_by_bus, ctx) do
    branches = Map.new(env.lines, &{{:line, &1.id}, &1})
    branches = Enum.reduce(env.transformers, branches, &Map.put(&2, {:transformer, &1.id}, &1))
    adjacent = longest_adjacent_impedance(env)

    for {{type, id} = key, flow} <- line_flows,
        not MapSet.member?(ctx.base_overloaded, {type, id}),
        branch = Map.get(branches, key),
        branch != nil,
        vm_pu = Map.get(vm_by_bus, flow.from_bus_id),
        vm_pu != nil do
      %{
        component_type: type,
        component_id: id,
        z_line: {Map.get(branch, :r_pu) || 0.0, Map.get(branch, :x_pu) || 0.0},
        vm_pu: vm_pu,
        p_pu: flow.p_flow_mw / ctx.base_mva,
        q_pu: (Map.get(flow, :q_flow_mvar) || 0.0) / ctx.base_mva,
        z_adjacent: Map.get(adjacent, flow.to_bus_id),
        rating_mva: highest_rating_mva(flow)
      }
    end
  end

  # The longest line leaving each bus, as `%{bus_id => {r_pu, x_pu}}`. A relay
  # looking into a branch sees its own line plus this, which is the reach zone 3
  # is set to back up.
  defp longest_adjacent_impedance(env) do
    Enum.reduce(env.lines ++ env.transformers, %{}, fn branch, acc ->
      z = {Map.get(branch, :r_pu) || 0.0, Map.get(branch, :x_pu) || 0.0}
      mag = Protection.impedance_magnitude(z)

      acc
      |> longest_at(branch.from_bus_id, z, mag)
      |> longest_at(branch.to_bus_id, z, mag)
    end)
  end

  defp longest_at(acc, bus_id, z, mag) do
    case Map.get(acc, bus_id) do
      nil ->
        Map.put(acc, bus_id, z)

      current ->
        if mag > Protection.impedance_magnitude(current), do: Map.put(acc, bus_id, z), else: acc
    end
  end

  defp highest_rating_mva(flow) do
    [:rating_c_mva, :rating_b_mva, :rating_mva]
    |> Enum.map(&Map.get(flow, &1))
    |> Enum.filter(&(is_number(&1) and &1 > 0))
    |> Enum.max(fn -> nil end)
  end

  # ---------------------------------------------------------------------------
  # Conductor thermal: the SLOW timescale (ROADMAP item 20)
  # ---------------------------------------------------------------------------

  # Advance every branch's conductor temperature over the cascade clock and
  # emit a trip candidate for any conductor now heading for its emergency
  # limit. The candidate joins the same fastest-relay-wins selection the
  # IEC 60255-151 elements use; the two answer different questions (does a
  # relay operate in seconds / does the conductor anneal in tens of minutes)
  # and neither is ever fed the other's output.
  #
  # `loading_pct` is the RATE A basis, which is the only anchor the curve has:
  # rate A is by definition the current at which the conductor settles at its
  # continuous design temperature. Feeding `trip_loading_pct/1`'s rate-C basis
  # here would understate every temperature by 1.35².
  #
  # The DC solve's loading is P-only, so the model is conservative on
  # reactive-heavy branches. It is used on every island rather than switching
  # to the AC magnitude where one exists, because this state accumulates across
  # steps and an island flipping between the two bases would integrate a
  # discontinuity that is measurement, not physics.
  defp advance_conductors(conductor, line_flows, ctx) do
    Enum.reduce(line_flows, {conductor, []}, fn {{type, id} = key, flow}, {state, candidates} ->
      loading = (Map.get(flow, :loading_pct) || 0.0) / 100.0

      advanced =
        Protection.advance_conductor_temperature(Map.get(state, key), loading, ctx.conductor_dt_s)

      state = Map.put(state, key, advanced)

      candidates =
        with false <- base_case_cooking?(ctx, key),
             trip_time when trip_time != :infinity <-
               Protection.conductor_trip_time_s(advanced, loading) do
          [conductor_candidate(type, id, flow, advanced, trip_time) | candidates]
        else
          _ -> candidates
        end

      {state, candidates}
    end)
  end

  # The thermal model's own trip-immune set, and it is NOT `base_overloaded`.
  #
  # That set is on the rate-C basis: a branch joins it past 100% of rate C,
  # which is 135% of rate A. The conductor curve cooks from about 131% of rate
  # A (where a 35 °C rated rise first exceeds the 60 °C the emergency limit
  # allows), so a branch sitting in the 131–135% band in the BASE case is a
  # model artifact that the overcurrent exclusion lets through and the slow
  # mechanism would then trip at t≈0 on impedance error alone — exactly what
  # the exclusion exists to prevent, one basis lower down.
  #
  # So the test is asked in the thermal model's own terms: would this branch's
  # BASE-CASE loading, held forever, reach the emergency temperature? If it
  # would, the branch was already cooking before anything happened and nothing
  # the cascade does to it is an event.
  defp base_case_cooking?(ctx, key) do
    MapSet.member?(ctx.base_overloaded, key) or
      case Map.get(ctx.base_line_loading, key) do
        pct when is_number(pct) ->
          Protection.conductor_overtemperature?(%{
            temp_c: Protection.conductor_steady_state_temp_c(pct / 100.0)
          })

        _ ->
          false
      end
  end

  defp conductor_candidate(type, id, flow, thermal, trip_time_s) do
    %{
      component_type: component_type_string(type),
      component_id: id,
      failure_cause: "conductor_thermal",
      details: %{
        loading_pct: Map.get(flow, :loading_pct),
        temp_c: thermal.temp_c,
        steady_state_c: thermal.steady_state_c,
        trip_time_s: trip_time_s
      },
      trip_time_s: trip_time_s
    }
  end

  @doc """
  Loading percentage an overcurrent relay picks up on, against the short-time
  emergency rating (rate C) rather than the normal rating.

  Arming protection at 100% of the continuous rating made every branch a hair
  over rate A start an inverse-time timer, which is a dispatch condition and
  not a breaker operation. Relays are set above the short-time emergency
  limit, so pickup is rate C and a branch only begins timing past that.

  Flow maps built before the rating tiers existed (and hand-built test
  fixtures) carry only `loading_pct`, which is against rate A; rate C is a
  fixed multiple of rate A, so the fallback converts exactly.
  """
  def trip_loading_pct(flow) do
    case Map.get(flow, :trip_loading_pct) do
      pct when is_number(pct) -> pct
      _ -> (Map.get(flow, :loading_pct) || 0.0) / Ratings.rate_c_factor()
    end
  end

  # Compute trip time for each branch past relay pickup using
  # Protection.overcurrent_trip_time/1.
  defp compute_timed_overloads(line_flows, base_overloaded) do
    line_flows
    |> Enum.filter(fn {{type, id}, flow} ->
      trip_loading_pct(flow) > 100.0 and not MapSet.member?(base_overloaded, {type, id})
    end)
    |> Enum.map(fn {{type, id}, flow} ->
      # The inverse-time curve integrates against pickup, so it is fed the
      # rate-C loading; `loading_pct` stays in the details as the operator-
      # facing number against the normal rating.
      trip_pct = trip_loading_pct(flow)
      trip_time = Protection.overcurrent_trip_time(trip_pct)

      %{
        component_type: component_type_string(type),
        component_id: id,
        failure_cause: "thermal_overload",
        details: %{
          loading_pct: Map.get(flow, :loading_pct),
          trip_loading_pct: trip_pct,
          p_flow_mw: flow.p_flow_mw,
          trip_time_s: trip_time
        },
        trip_time_s: trip_time
      }
    end)
  end

  defp island_solve_failure_event(island_buses, island_loads, error) do
    %{
      component_type: "island",
      component_id: island_buses |> Enum.map(& &1.id) |> Enum.min(),
      failure_cause: "island_solve_failed",
      details: %{
        bus_count: length(island_buses),
        load_mw: Enum.sum(Enum.map(island_loads, & &1.p_mw)),
        error: error
      }
    }
  end

  # Advance all concurrently asserted relays by the remaining wall-clock time
  # of the first finite relay to finish. Each relay stores operating duty
  # (integral of dt / current curve time), not elapsed seconds. A branch absent
  # from `timed_overloads` is dropped here: thermal overload and Zone 3 both use
  # an instantaneous reset when their respective condition clears.
  #
  # A DISTANCE element is the exception, and carries a map of `zone => duty`
  # rather than one accumulator. A real relay runs its zone timers IN PARALLEL:
  # an apparent impedance walking inward starts the faster zone's timer without
  # stopping the slower ones it is still inside, so a worsening fault can only
  # trip SOONER. Keyed by zone (the cause string) instead, the inward walk lost
  # the duty it had accrued and tripped LATER than standing still would have —
  # zone 3 at 0.9 duty plus a zone 2 restart took 1.75 s where a static zone 3
  # fault took 1.50 s (REVIEW CAS-23).
  @doc false
  def advance_relay_timers(timed_overloads, relay_duty)

  def advance_relay_timers([], _relay_duty), do: {nil, 0.0, %{}}

  def advance_relay_timers(timed_overloads, relay_duty) do
    asserted = Enum.map(timed_overloads, &assert_relay(&1, relay_duty))

    case Enum.reject(asserted, &(&1.remaining == :infinity)) do
      [] ->
        {nil, 0.0, Map.new(asserted, &{&1.key, &1.duty})}

      finite ->
        fastest = Enum.min_by(finite, & &1.remaining)
        time_advance_s = fastest.remaining

        advanced_duty =
          Map.new(asserted, fn relay ->
            {relay.key, accrue_relay_duty(relay.duty, time_advance_s, relay.trip.trip_time_s)}
          end)

        if relay_operated?(Map.fetch!(advanced_duty, fastest.key)) do
          retained_duty = drop_tripped_relay_duty(advanced_duty, fastest.trip)

          trip =
            fastest.trip
            |> Map.delete(:trip_time_s)
            |> note_operating_zone(fastest.zone)

          {trip, time_advance_s, retained_duty}
        else
          {nil, time_advance_s, advanced_duty}
        end
    end
  end

  # One relay's asserted state this step: the duty it carries into the step
  # (a float, or `zone => duty` for a distance element), how much wall clock it
  # still needs, and — where the question means anything — which zone element
  # will get there first.
  defp assert_relay(trip, relay_duty) do
    key = relay_key(trip)
    duty = pick_up(trip, Map.get(relay_duty, key))
    {remaining, zone} = relay_remaining(trip, duty)

    %{trip: trip, key: key, duty: duty, remaining: remaining, zone: zone}
  end

  # Which timers this step's measurement leaves running. A distance pickup at
  # zone N is also inside every LARGER zone, so those keep timing from where
  # they were; the inner zones it has dropped out of reset, which is what a
  # definite-time element does when its condition clears.
  defp pick_up(%{failure_cause: "distance_zone" <> _} = trip, prior) do
    zone = trip.details.zone

    (prior || %{})
    |> Map.filter(fn {z, _duty} -> z >= zone end)
    |> Map.put_new(zone, 0.0)
  end

  defp pick_up(_trip, prior), do: prior || 0.0

  defp relay_remaining(_trip, duty) when is_map(duty) do
    duty
    |> Enum.map(fn {zone, d} -> {remaining_trip_time(zone_delay_s(zone), d), zone} end)
    |> Enum.min()
  end

  defp relay_remaining(trip, duty), do: {remaining_trip_time(trip.trip_time_s, duty), nil}

  defp zone_delay_s(zone), do: Map.get(Protection.distance_settings().delays_s, zone, :infinity)

  defp relay_operated?(duty) when is_map(duty),
    do: Enum.any?(duty, fn {_zone, d} -> relay_operated?(d) end)

  defp relay_operated?(duty), do: duty >= 1.0 - 1.0e-9

  # Which zone element actually operated. It is not always the zone the
  # measurement picked up in: a zone 3 timer started two steps ago can expire
  # while the impedance now sits in zone 2, which is the whole point of running
  # the timers in parallel. `details.zone` keeps its meaning — the zone this
  # step's impedance is inside, which is still true — and the element that
  # finished is named beside it rather than overwriting it.
  defp note_operating_zone(trip, nil), do: trip

  defp note_operating_zone(%{details: details} = trip, zone) do
    if Map.get(details, :zone) == zone,
      do: trip,
      else: %{trip | details: Map.put(details, :operating_zone, zone)}
  end

  @doc false
  # Distance elements share ONE key per branch: their zone timers live in
  # parallel inside the value (see `advance_relay_timers/2`), so keying by zone
  # would make a worsening fault restart from zero. Every other protection keys
  # by cause, which is what keeps thermal and Zone 3 duty on one branch apart.
  def relay_key(%{failure_cause: "distance_zone" <> _} = trip),
    do: {:distance, trip.component_type, trip.component_id}

  def relay_key(trip), do: {trip.failure_cause, trip.component_type, trip.component_id}

  # Conductor thermal carries its progress in the TEMPERATURE, not in the duty
  # accumulator: `conductor_trip_time_s/3` is already the remaining time from
  # the temperature the conductor has reached. Letting duty accumulate across
  # steps on top of that would integrate the same progress twice, so the
  # thermal keys start each step at zero and reach 1.0 exactly when the step's
  # advance equals the remaining time.
  defp reset_thermal_duty(relay_duty) do
    Map.reject(relay_duty, fn {{cause, _type, _id}, _duty} -> cause == "conductor_thermal" end)
  end

  # A distance element's zones each accrue against their OWN definite-time
  # delay, so the trip time the measurement reported (the picked-up zone's) is
  # not what any of them integrates against.
  defp accrue_relay_duty(duty, delta_s, _trip_time_s) when is_map(duty) do
    Map.new(duty, fn {zone, d} -> {zone, accrue_relay_duty(d, delta_s, zone_delay_s(zone))} end)
  end

  defp accrue_relay_duty(duty, _delta_s, :infinity), do: duty

  # A zero trip time is a relay that has ALREADY fully operated, not one that
  # operates infinitely fast: `Protection.conductor_trip_time_s/3` returns 0.0
  # for a conductor that is at or above its emergency temperature, which is the
  # remaining time to a limit it has already reached. Duty is that progress, so
  # it is 1.0 — and the caller's `>= 1.0` branch then trips the branch on this
  # step with a zero clock advance, which is the physical answer.
  #
  # This clause MUST precede the general one below: `delta_s / 0.0` raises
  # ArithmeticError, and an at-limit conductor is reachable at ordinary demand
  # (a 531%-of-rate-A line at the default hour reaches it on the first step).
  defp accrue_relay_duty(_duty, _delta_s, trip_time_s) when trip_time_s <= 0.0, do: 1.0

  defp accrue_relay_duty(duty, delta_s, trip_time_s), do: min(duty + delta_s / trip_time_s, 1.0)

  defp drop_tripped_relay_duty(relay_duty, tripped) do
    Map.reject(relay_duty, fn
      {{_cause, type, id}, _duty} ->
        type == tripped.component_type and id == tripped.component_id
    end)
  end

  defp remaining_trip_time(:infinity, _duty), do: :infinity
  defp remaining_trip_time(trip_time_s, duty), do: max(trip_time_s * (1.0 - duty), 0.0)

  # ---------------------------------------------------------------------------
  # Dispatch helpers
  # ---------------------------------------------------------------------------

  @doc """
  Active (non-tripped) generators with the current dispatch applied, shaped
  for the solvers (p_max_mw = dispatched MW, capacity_factor 1.0).

  Every solve of the cascade's network MUST use these: the pre-failure base
  case is computed from dispatched generation, so solving with raw nameplate
  capacities instead produces nationwide flow differences that masquerade as
  failure impact.
  """
  def dispatched_generators(%__MODULE__{} = state) do
    state.generators
    |> Enum.reject(&MapSet.member?(state.tripped_generators, &1.id))
    |> apply_dispatch(state.dispatch)
  end

  # Override generator maps so the DC solver sees the dispatched MW values.
  # We set capacity_factor to 1.0 and p_max_mw to the dispatched value so
  # the solver's P_inject = dispatch_mw / base_mva. The physical values ride
  # along as :p_dispatch_mw / :p_nameplate_mw so the frequency simulation
  # keeps real governor headroom and the machine-MVA inertia base (reading
  # the solver shape naively would zero both).
  defp apply_dispatch(generators, dispatch) do
    Enum.map(generators, fn g ->
      dispatched_mw = Map.get(dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))

      %{g | p_max_mw: dispatched_mw, capacity_factor: 1.0}
      |> Map.put(:p_dispatch_mw, dispatched_mw)
      |> Map.put(:p_nameplate_mw, g.p_max_mw)
    end)
  end

  # ---------------------------------------------------------------------------
  # Trip application
  # ---------------------------------------------------------------------------

  defp apply_trips(state, trips) do
    Enum.reduce(trips, state, fn trip, st ->
      event = Map.put(trip, :step, st.step)

      case trip.component_type do
        "transmission_line" ->
          %{
            st
            | tripped_lines: MapSet.put(st.tripped_lines, trip.component_id),
              events: [event | st.events]
          }

        "transformer" ->
          %{
            st
            | tripped_transformers: MapSet.put(st.tripped_transformers, trip.component_id),
              events: [event | st.events]
          }

        "generator" ->
          %{
            st
            | tripped_generators: MapSet.put(st.tripped_generators, trip.component_id),
              events: [event | st.events]
          }

        _ ->
          %{st | events: [event | st.events]}
      end
    end)
  end

  defp component_type_string(:line), do: "transmission_line"
  defp component_type_string(:transformer), do: "transformer"
  defp component_type_string(other), do: Atom.to_string(other)

  # ---------------------------------------------------------------------------
  # Facility power-loss detection (water facilities, datacenters)
  # ---------------------------------------------------------------------------

  # All bus IDs in islands the solver treats as dead — everything on these
  # buses is blacked out, including colocated facilities.
  defp dead_island_buses(islands, active_gens) do
    Enum.reduce(islands, MapSet.new(), fn island, acc ->
      island_gens = Enum.filter(active_gens, &MapSet.member?(island, &1.bus_id))

      if island_dead?(island, island_gens) do
        MapSet.union(acc, island)
      else
        acc
      end
    end)
  end

  # REVIEW CAS-15: an island is dead when it has no generation, full stop.
  # SIZE is not a death sentence — a single bus carrying a generator and its
  # load is trivially solvable (theta = 0), which is exactly what SOL-3 fixed
  # in `PowerModel.Solver.Partition` (`min_buses = 1`). This predicate used to
  # declare every one-bus island dead, so the two halves of the codebase
  # disagreed about the same island: the solver would solve it and the cascade
  # would black it out, taking its facilities down with it.
  defp island_dead?(island_buses_or_ids, island_gens) do
    Enum.empty?(island_buses_or_ids) or Enum.empty?(island_gens)
  end

  # Facilities on dead buses that aren't already marked lose power.
  # Returns {new_trip_events, newly_affected_ids_mapset}.
  defp check_facility_power_loss(
         facilities,
         already_affected,
         dead_bus_ids,
         component_type,
         details_fn
       ) do
    facilities
    |> Enum.filter(fn f ->
      f.bus_id != nil and
        MapSet.member?(dead_bus_ids, f.bus_id) and
        not MapSet.member?(already_affected, f.id)
    end)
    |> Enum.reduce({[], MapSet.new()}, fn f, {trips, ids} ->
      trip = %{
        component_type: component_type,
        component_id: f.id,
        failure_cause: "power_loss",
        details: details_fn.(f)
      }

      {[trip | trips], MapSet.put(ids, f.id)}
    end)
  end

  defp water_facility_details(wf) do
    %{name: wf.name, facility_type: wf.facility_type, power_mw: wf.power_consumption_mw}
  end

  defp datacenter_details(dc) do
    %{
      name: dc.name,
      facility_type: dc.facility_type,
      operator: dc.operator,
      power_mw: dc.power_mw
    }
  end
end
