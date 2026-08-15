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

  ## The step ordering (ROADMAP item 15)

  Everything an island does inside one step happens in this order, and the
  order is the model:

  1. **Reserves** — the ramp-limited tiers (`PowerModel.Failure.Reserves`)
     raise the island's generation as far as the clock allows.
  2. **Trajectory evaluation** — ONE swing-equation segment, resumed from the
     island's persistent frequency state, for the deficit the reserves left.
  3. **Protection reads that trajectory** — behind-the-meter inverters
     (IEEE 1547) and generator frequency protection (PRC-024) are evaluated
     against the SAME trajectory, so they cannot disagree about what the
     island's frequency did.
  4. **Recompute** — tripped rooftop is new load, tripped generators are lost
     generation; both land in the same step's deficit.
  5. **Residual shed** — UFLS (authoritative, re-simulated on the deepened
     gap) and then the force-shed tier close whatever is left.
  6. **Solve** — DC power flow on the post-shed island, feeding thermal,
     voltage and zone-3 protection.

  Step 3 is the positive feedback loop real blackouts run on: an island that
  dips far enough loses generators, which deepens the same step's deficit,
  which sheds more customers. Islands can therefore LOSE generation they did
  not start losing.

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
  """

  require Logger

  alias PowerModel.Dispatch
  alias PowerModel.Grid.{BtmSolar, DcTie, Ratings}
  alias PowerModel.Solver.{DCPowerFlow, Frequency}
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

  # IEEE 1547-2003 must-trip settings for the legacy behind-the-meter fleet.
  # 1547-2018 units are required to ride through both of these, which is why
  # only the legacy SHARE of each bus's rooftop output is ever at stake.
  @btm_trip_frequency_hz 59.3
  @btm_trip_voltage_pu 0.88

  # Nominal frequency, used when an island carries no deficit and therefore no
  # under-frequency excursion to evaluate. Matches `Frequency`'s f0.
  @nominal_frequency_hz 60.0

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
    relay_duty: %{},
    # One record per island of the CURRENT topology — see `island_record/0`.
    island_states: [],
    # Transient governor MW inside `dispatch`, per generator (ROADMAP item 16).
    # `dispatch[id] - primary_reserve[id]` is the unit's SUSTAINED output, and
    # that is what the swing model is told about.
    primary_reserve: %{}
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
      btm_tripped_buses: MapSet.new(),
      btm_tripped_mw: 0.0,
      island_states: island_states,
      primary_reserve: %{}
    }
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
  defp fresh_island_record(buses, deficit_since_s \\ nil) do
    %{
      buses: buses,
      frequency_state: nil,
      exposure: [],
      deficit_since_s: deficit_since_s
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
  defp inherit_island_states(prior_records, islands, loads) do
    load_by_bus =
      Enum.reduce(loads, %{}, fn l, acc -> Map.update(acc, l.bus_id, l.p_mw, &(&1 + l.p_mw)) end)

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
          by_index
          |> Map.fetch!(index)
          |> Map.put(:buses, island)
          |> apportion_state(mw / max(Map.get(prior_load, index, 0.0), 1.0e-9))
      end
    end)
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
  defp begin_cascade_event(state) do
    records =
      Enum.map(state.island_states, fn record ->
        case record.deficit_since_s do
          nil -> record
          _ -> %{record | deficit_since_s: 0.0}
        end
      end)

    %{
      state
      | step: 0,
        simulated_time: 0.0,
        relay_duty: %{},
        stable: false,
        island_states: records
    }
  end

  @doc """
  Run cascade loop until stable or max steps reached.
  Yields each step result for streaming via callback.
  """
  def run_cascade(state, callback \\ nil) do
    do_cascade(state, [], callback)
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

    {state, remaining} = apply_sustained_reserves(state, deficit_mw, ba_gens, elapsed_s)
    {state, _remaining} = apply_sustained_reserves(state, remaining, other_gens, elapsed_s)

    state
  end

  # Raise `gens` by as much sustained (secondary + tertiary) reserve as the
  # clock allows. Returns `{state, remaining_deficit}`.
  defp apply_sustained_reserves(state, deficit_mw, gens, elapsed_s)

  defp apply_sustained_reserves(state, deficit_mw, [], _elapsed_s), do: {state, deficit_mw}

  defp apply_sustained_reserves(state, deficit_mw, _gens, _elapsed_s) when deficit_mw <= 0.5,
    do: {state, deficit_mw}

  defp apply_sustained_reserves(state, deficit_mw, gens, elapsed_s) do
    units = Enum.map(gens, &sustained_unit_of(state, &1))
    alloc = Reserves.allocate(units, deficit_mw, elapsed_s)

    dispatch =
      Enum.reduce(units, state.dispatch, fn unit, d ->
        case Map.get(alloc.sustained_by_unit, unit.id, 0.0) do
          mw when mw > 0.0 -> Map.update(d, unit.id, mw, &(&1 + mw))
          _ -> d
        end
      end)

    {%{state | dispatch: dispatch}, deficit_mw - alloc.secondary_mw - alloc.tertiary_mw}
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

    {%{state | stable: false, events: [exhausted_event | state.events]},
     Enum.reverse(step_results)}
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
    records = inherit_island_states(state.island_states, islands, state.loads)

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
        btm_tripped_mw: state.btm_tripped_mw + btm.tripped_mw
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

      step_result = %{
        step: state.step,
        simulated_time: state.simulated_time,
        islands: length(islands),
        trips: facility_trips,
        water_facility_ids: MapSet.to_list(state.affected_water_facilities),
        datacenter_ids: MapSet.to_list(state.affected_datacenters),
        solution: island_results,
        balance: balance(state)
      }

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
          advance_relay_timers(timed_overloads, state.relay_duty)
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

      step_result = %{
        step: state.step,
        simulated_time: state.simulated_time,
        islands: length(islands),
        trips: all_trips_this_step,
        water_facility_ids: MapSet.to_list(state.affected_water_facilities),
        datacenter_ids: MapSet.to_list(state.affected_datacenters),
        solution: island_results,
        balance: balance(state)
      }

      if callback, do: callback.(step_result)
      step_results = [step_result | step_results]

      cond do
        island_solve_failed? ->
          {%{state | stable: false}, Enum.reverse(step_results)}

        Enum.empty?(thermal_trips) and Enum.empty?(non_thermal_trips) ->
          {%{state | stable: true}, Enum.reverse(step_results)}

        true ->
          # Apply thermal trip
          state = apply_trips(state, thermal_trips)

          # Redispatch after trip (cover any generation/load imbalance)
          state = maybe_redispatch_after_trip(state)

          do_cascade(state, step_results, callback)
      end
    end
  end

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
    records = inherit_island_states(state.island_states, islands, state.loads)
    {%{state | island_states: records}, islands}
  end

  # Start the island's deficit clock when a sustained gap opens, stop it when
  # the gap closes. The reserve tiers ramp on the elapsed time this records.
  defp mark_deficit_clock(state, island_bus_set, sustained_deficit) do
    now = state.simulated_time

    records =
      Enum.map(state.island_states, fn record ->
        if MapSet.disjoint?(record.buses, island_bus_set) do
          record
        else
          update_deficit_clock(record, sustained_deficit, now)
        end
      end)

    %{state | island_states: records}
  end

  defp update_deficit_clock(record, sustained_deficit, now) when sustained_deficit > 0.5 do
    %{record | deficit_since_s: record.deficit_since_s || now}
  end

  defp update_deficit_clock(record, _sustained_deficit, _now) do
    %{record | deficit_since_s: nil}
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
      now: state.simulated_time
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
      frequency_advance_s: 0.0
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

  # One live island, start to finish. `env` carries the island's slice of the
  # network; `record` its persistent frequency state.
  defp live_island(env, record, acc, ctx) do
    load_mw = sum_mw(env.loads, & &1.p_mw)

    # --- 1. Reserves ---------------------------------------------------------
    units =
      Enum.map(env.gens, fn g ->
        sustained_unit(g, dispatch_of(acc, g), Map.get(acc.primary_reserve, g.id, 0.0))
      end)

    sustained_mw = sum_mw(units, & &1.p_dispatch_mw)
    deficit_mw = load_mw - sustained_mw - env.tie_mw

    record = update_deficit_clock(record, deficit_mw, ctx.now)
    elapsed_s = record_elapsed(record, ctx.now)

    alloc = Reserves.allocate(units, max(deficit_mw, 0.0), elapsed_s)

    raised =
      Enum.map(units, fn unit ->
        sustained = unit.p_dispatch_mw + Map.get(alloc.sustained_by_unit, unit.id, 0.0)
        {unit, sustained, Map.get(alloc.primary_by_unit, unit.id, 0.0)}
      end)

    sustained_gens = Enum.map(raised, fn {unit, sustained, _p} -> shape_at(unit, sustained) end)
    available_sustained = sum_mw(sustained_gens, & &1.p_dispatch_mw) + env.tie_mw

    acc = %{
      acc
      | dispatch: put_dispatch(acc.dispatch, raised),
        primary_reserve: put_primary(acc.primary_reserve, raised)
    }

    # --- 2. Trajectory evaluation -------------------------------------------
    # ONE segment of this island's frequency, resumed from where the last
    # disturbance left it. Everything below reads THIS trajectory, so the
    # rooftop inverters and the generator relays cannot disagree about what
    # the frequency did.
    {trajectory, eval_state} =
      simulate_island(record, sustained_gens, env.loads, load_mw - available_sustained)

    nadir = if trajectory, do: Frequency.nadir(trajectory), else: @nominal_frequency_hz

    # --- 3. Protection reads it ---------------------------------------------
    # IEEE 1547 legacy inverters trip on the frequency the island reached with
    # its rooftop still on, and what they leave behind is LOAD — the vicious
    # pairing of item 31: the fleet is gone at 59.3 Hz while the first UFLS
    # stage only arms BELOW 59.3 Hz.
    {loads, island_loads, load_mw, btm, btm_events} =
      evaluate_btm_trip(acc.btm, env.buses, env.loads, acc.loads, load_mw, nadir)

    acc = %{acc | loads: loads, btm: btm}
    env = %{env | loads: island_loads}

    exposure = accumulate_exposure(record.exposure, trajectory)

    gen_trips =
      if trajectory, do: Protection.generator_frequency_trips(exposure, sustained_gens), else: []

    # --- 4. Recompute --------------------------------------------------------
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

    events = btm_events ++ gen_events

    surviving_gens = Enum.map(survivors, fn {unit, _s, _p} -> unit end)

    if island_dead?(env.buses, surviving_gens) do
      # The island lost every machine it had — the frequency feedback loop
      # closing on itself. What is left is a blackout, not a deficit: there is
      # nothing to shed against and nothing to solve. The segment it died in
      # still happened, so it still moves the clock.
      {advance_s, _state, _exposure} = settle_segment(trajectory, eval_state, [])

      acc
      |> black_out_island(env.loads)
      |> add_trips(events)
      |> put_record(fresh_island_record(env.island))
      |> Map.update!(:frequency_advance_s, &max(&1, advance_s))
    else
      settle_island(env, record, acc, ctx, %{
        survivors: survivors,
        events: events,
        trajectory: trajectory,
        eval_state: eval_state,
        recompute?: MapSet.size(tripped_ids) > 0 or btm_events != [],
        load_mw: load_mw
      })
    end
  end

  # --- 5. Residual shed, and 6. solve ---------------------------------------
  defp settle_island(env, record, acc, ctx, step) do
    sustained_gens = Enum.map(step.survivors, fn {u, s, _p} -> shape_at(u, s) end)
    available_sustained = sum_mw(sustained_gens, & &1.p_dispatch_mw) + env.tie_mw
    available_output = sum_mw(step.survivors, fn {_u, s, p} -> s + p end) + env.tie_mw

    imbalance_mw = step.load_mw - available_sustained

    # The authoritative trajectory: when the rooftop or a generator left, the
    # island is answering a DEEPER gap than the evaluation saw, so the segment
    # is re-integrated from the same starting state rather than patched.
    {trajectory, eval_state} =
      if step.recompute? do
        simulate_island(record, sustained_gens, env.loads, imbalance_mw)
      else
        {step.trajectory, step.eval_state}
      end

    lost_mw = frequency_lost_mw(record.frequency_state, imbalance_mw)

    {shed_loads, ufls_events, frequency_state} =
      if lost_mw > 0.5 do
        LoadShedding.apply_ufls_with_state(
          env.loads,
          sustained_gens,
          step.load_mw - lost_mw,
          step.load_mw,
          frequency_state: record.frequency_state,
          duration_seconds: @frequency_window_s
        )
      else
        {env.loads, [], eval_state}
      end

    ufls_shed_mw = sum_mw(ufls_events, &Map.get(&1.details, :shed_mw, 0.0))

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

    shed_events = ufls_events ++ force_events
    shed_mw = sum_mw(shed_events, &Map.get(&1.details, :shed_mw, 0.0))
    served_mw = step.load_mw - shed_mw

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
      Enum.map(step.survivors, fn {unit, _s, _p} ->
        shape_at(unit, Map.get(dispatch, unit.id, 0.0))
      end)

    frequency_state = credit_shed(frequency_state, record.frequency_state, shed_mw)

    {advance_s, frequency_state, exposure} =
      settle_segment(trajectory, frequency_state, record.exposure)

    record = %{
      record
      | frequency_state: frequency_state,
        exposure: exposure,
        deficit_since_s:
          update_deficit_clock(record, served_mw - available_sustained, ctx.now).deficit_since_s
    }

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
      |> put_record(record)

    solve_island_flows(%{env | loads: island_loads}, solver_gens, acc, ctx)
  end

  # --- 6. DC power flow, and the protection that reads it -------------------
  defp solve_island_flows(env, solver_gens, acc, ctx) do
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

      voltage_trips = Protection.check_voltage_violations(solution.bus_ids, solution.vm_pu)

      bus_index = solution.bus_ids |> Enum.with_index() |> Map.new()

      zone3_trips =
        Protection.check_zone3_encroachment(
          solution.line_flows,
          env.lines ++ env.transformers,
          env.buses,
          solution.vm_pu,
          solution.va_rad,
          bus_index
        )

      # Zone 3 trips integrate duty while continuously asserted using their
      # own fixed 0.5 s timer. The cause-specific relay key keeps this duty
      # completely separate from thermal exposure on the same branch.
      zone3_timed = Enum.map(zone3_trips, &Map.put(&1, :trip_time_s, 0.5))

      %{
        acc
        | trips: acc.trips ++ voltage_trips,
          results: [solution | acc.results],
          overloads: acc.overloads ++ timed ++ zone3_timed
      }
    rescue
      e ->
        error = Exception.message(e)
        Logger.error("island solve raised #{error}; island dropped from this step")
        island_solve_failed(acc, env, error)
    catch
      thrown ->
        error = inspect(thrown)
        Logger.error("island solve threw #{error}; island dropped from this step")
        island_solve_failed(acc, env, error)
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
  defp settle_segment(nil, state, exposure), do: {0.0, state, exposure}

  defp settle_segment(trajectory, state, exposure) do
    started_at = hd(trajectory).time
    settled_at = settle_time(trajectory)

    trimmed = Enum.filter(trajectory, &(&1.time <= settled_at))

    {settled_at - started_at, %{state | time: settled_at}, accumulate_exposure(exposure, trimmed)}
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
      tripped: state.btm_tripped_buses || MapSet.new(),
      tripped_mw: 0.0
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
        # The voltage trigger is checked whatever the frequency did, since a
        # bus can be depressed without the island being short of generation.
        tripping =
          Enum.filter(candidates, fn {_bus_id, _legacy_mw, vm_pu} ->
            legacy_btm_trips?(nadir, vm_pu)
          end)

        apply_btm_trip(btm, tripping, island_loads, all_loads, island_load_mw, nadir)
    end
  end

  # Buses in this island that still have legacy rooftop to lose, with the
  # voltage each currently holds.
  defp btm_candidates(btm, island_buses) do
    Enum.reduce(island_buses, [], fn bus, acc ->
      legacy_mw = Map.get(btm.by_bus, bus.id, 0.0)

      if legacy_mw > 0.0 and not MapSet.member?(btm.tripped, bus.id) do
        [{bus.id, legacy_mw, Map.get(bus, :vm_pu) || 1.0} | acc]
      else
        acc
      end
    end)
  end

  # IEEE 1547-2003 must-trip envelope. Frequency is an island-wide quantity, so
  # every candidate bus sees the same nadir; voltage is local to the bus.
  #
  # > #### The voltage trigger is unreachable today {: .warning}
  # >
  # > `vm_pu` comes from the bus as the snapshot carries it, and the DC power
  # > flow neither models voltage magnitude nor writes one back — every bus
  # > sits at a flat 1.0 pu (the CAS-14 family of caveats). So the 0.88 pu term
  # > below is correct and inert: it can only fire once the Q-V / QSS-AC work
  # > gives buses real magnitudes. It is implemented rather than deferred so
  # > that landing those voltages turns the mechanism on without anyone having
  # > to remember this clause exists.
  defp legacy_btm_trips?(nadir_hz, vm_pu) do
    nadir_hz <= @btm_trip_frequency_hz or vm_pu <= @btm_trip_voltage_pu
  end

  defp apply_btm_trip(btm, [], island_loads, all_loads, island_load_mw, _nadir) do
    {all_loads, island_loads, island_load_mw, btm, []}
  end

  defp apply_btm_trip(btm, tripping, island_loads, all_loads, island_load_mw, nadir) do
    loads_by_bus = Enum.group_by(island_loads, & &1.bus_id)

    {additions, tripped_mw, tripped_bus_ids} =
      Enum.reduce(tripping, {%{}, 0.0, []}, fn {bus_id, legacy_mw, _vm_pu},
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
          tripped_mw: btm.tripped_mw + tripped_mw
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
  defp advance_relay_timers([], _relay_duty), do: {nil, 0.0, %{}}

  defp advance_relay_timers(timed_overloads, relay_duty) do
    overloads_with_remaining =
      Enum.map(timed_overloads, fn trip ->
        key = relay_key(trip)
        duty = Map.get(relay_duty, key, 0.0)
        {trip, remaining_trip_time(trip.trip_time_s, duty)}
      end)

    finite_overloads =
      Enum.reject(overloads_with_remaining, fn {_trip, remaining} -> remaining == :infinity end)

    case finite_overloads do
      [] ->
        retained_duty =
          Map.new(overloads_with_remaining, fn {trip, _remaining} ->
            key = relay_key(trip)
            {key, Map.get(relay_duty, key, 0.0)}
          end)

        {nil, 0.0, retained_duty}

      _ ->
        {fastest, time_advance_s} =
          Enum.min_by(finite_overloads, fn {_trip, remaining} -> remaining end)

        advanced_duty =
          Map.new(overloads_with_remaining, fn {trip, _remaining} ->
            key = relay_key(trip)
            current_duty = Map.get(relay_duty, key, 0.0)
            {key, accrue_relay_duty(current_duty, time_advance_s, trip.trip_time_s)}
          end)

        fastest_key = relay_key(fastest)

        if Map.fetch!(advanced_duty, fastest_key) >= 1.0 - 1.0e-9 do
          retained_duty = drop_tripped_relay_duty(advanced_duty, fastest)
          {Map.delete(fastest, :trip_time_s), time_advance_s, retained_duty}
        else
          {nil, time_advance_s, advanced_duty}
        end
    end
  end

  @doc false
  def relay_key(trip), do: {trip.failure_cause, trip.component_type, trip.component_id}

  defp accrue_relay_duty(duty, _delta_s, :infinity), do: duty
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
