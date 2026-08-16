defmodule PowerModel.Dispatch do
  @moduledoc """
  Unit dispatch from measured EIA-930 per-fuel generation.

  EIA-930 publishes, for every balancing authority and hour, how many MW each
  fuel actually produced (`PowerModel.Demand.BAFuelHour`). This module places
  those MW on individual units: within one (BA, fuel, hour) the measured MW are
  filled into that BA's in-service units of that fuel in merit order —
  capacity factor descending — each unit capped at its seasonal capability.

  ## Absolute MW, scaled only by the snapshot's share (REVIEW ENE-20)

  The measured MW are used as absolute targets: nothing is normalized to the
  snapshot's load, so a BA's generation minus its load reproduces its real
  interchange by construction instead of the fictitious self-sufficiency a
  load-balanced dispatch imposes (ROADMAP item 6).

  There is exactly one scaling, and it is the one the LOAD side already
  applies. `PowerModel.Demand.scale_loads/3` serves a snapshot its SHARE of
  each BA's demand — the fraction of that BA's geolocated load baseline the
  snapshot actually holds (ENE-17) — so this module offers that BA's units the
  same share of its measured generation. Placing 100% of a BA's fuel MW into a
  snapshot serving 67% of its demand is what made Eastern's operating point run
  65.3 GW long, which is 23% of Eastern's load baseline sitting on off-main
  fragments showing up on the generation side and nowhere else.

  The share is read from the database AT DISPATCH TIME
  (`Demand.snapshot_load_shares/1`) rather than carried as a constant, so
  connectivity repair that returns those fragments to the main component moves
  every share toward 1.0 and retires the correction on its own. Coverage
  reports it per BA and in aggregate, and compares `implied_interchange_mw`
  against `share x reported` — the whole BA's interchange belongs to the whole
  BA, not to this slice of it.

  One BA-level exception (ENE20-C). EIA's own identity `net_generation -
  (demand + interchange)` does not close for every BA: BPAT misses by ~4.4 GW
  on every hour it publishes. For a BA `Demand.broken_identity_bas/0` screens
  in — by measurement, never by a stored list, because a re-ingest changes who
  qualifies — the generation budget is anchored on `share x (demand +
  interchange)` and spread over the BA's published fuel mix, and the MW that
  correction moved are reported as `identity_correction_mw`.

  ## Utility-scale solar and wind, onsite solar and wind

  EIA-930's per-fuel columns are a UTILITY-SCALE measurement: for solar and
  wind they count grid-connected plant, not the arrays sitting behind a
  commercial or industrial meter. The fuel-anchored pool for those two fuels
  therefore contains only units EIA-860 tagged `utility_scale` (see
  `PowerModel.Ingestion.EIA.Form860`), and the BA's measured MW are filled
  into those units alone.

  Onsite solar and wind units are dispatched OUTSIDE the pool, each at its own
  capacity factor capped at seasonal capability, and their MW are never
  subtracted from the BA's fuel target — the target measured other machines.
  The accounting that follows from that:

    * `by_ba[ba].by_fuel["solar"].target_mw` and `.dispatched_mw` describe the
      utility-scale pool only; `.onsite_mw` and `.onsite_units` report what was
      placed beside it, and the top-level `onsite_mw` totals it.
    * `by_ba[ba].dispatched_mw` (and therefore `implied_interchange_mw`) DOES
      include onsite MW: those are real injections at real buses, and the
      network has to carry them.
    * A BA reporting utility-scale solar whose only solar units are onsite now
      shows that solar in `unmatched` rather than placing it on an onsite
      unit — the measured plant is genuinely missing from the model.

  The onsite operating point is a flat annual capacity factor, so it does not
  fall to zero at night; ROADMAP item 30 replaces it with the BA's own hourly
  utility-solar capacity factor. The magnitude is small (~0.75 GW of onsite PV
  against 122 GW utility-scale) — this is a correctness fix, not a large one.

  Every other fuel is unaffected: sector plays no part in allocating gas,
  coal, nuclear, hydro, petroleum or other.

  ## Storage (ROADMAP item 17)

  Batteries sit outside the fuel-anchored pool the same way onsite VRE does,
  and for a sharper reason: EIA-930's `"other"` column is a NET measurement
  that goes negative when the fleet charges, and a fuel target floored at zero
  can only ever make a battery generate. `PowerModel.Dispatch.Storage` gives
  them an SOC-conserving daily duty cycle instead — charging in the BA's
  net-load trough, discharging across its peak — and their MW are **negative
  while charging**.

  The `"other"` target the remaining pool is offered is `reported - storage`,
  floored at zero, so no battery MW is counted twice and the BA's total
  generation still adds up to what EIA reported (see
  `PowerModel.Dispatch.Storage.adjust_fuel_totals/2`). The schedule is held
  under that same column hour by hour, so a battery can never discharge MW the
  measurement does not contain, and `by_fuel[fuel].reported_mw` carries the
  raw measurement beside the `target_mw` the pool was actually offered.

  A negative dispatch value travels the whole chain unchanged:
  `Cascade.apply_dispatch/2` hands the solver `p_max_mw = the negative MW`,
  `Solver.DCPowerFlow` injects `p_max_mw * capacity_factor` so a charging unit
  is a load at its bus, and `Solver.Frequency.simulate/5` keeps only units with
  `p_max_mw > 0` online — which correctly excludes a charging battery from
  inertia and governor response, since it is not spinning and its inverter is
  absorbing rather than supporting. `coverage.online_units` follows the same
  `mw > 0.0` rule, so a charging unit counts as offline there;
  `coverage.storage.charging_units` reports it explicitly.

  ## Minimum load and OFFLINE units

  A unit whose remaining allocation would fall below its `p_min_mw` is left
  OFFLINE rather than part-loaded below a level it cannot physically hold; the
  allocation moves on to the next unit in merit order, which may be small
  enough to take it. Every generator appears in the returned map — offline
  ones with an explicit `0.0`.

  When that leaves measured MW STRANDED — the merit order ran out of units it
  could start while machines were still cold — the group is re-loaded instead
  (ENE20-B): the shortest merit-order prefix that can bracket the target is
  committed, and each committed unit takes its minimum load plus a share of
  the remainder proportional to the room it has above that minimum. ERCO's
  four nuclear units are the case it exists for: their minimum loads total
  4,775 MW against a 4,808 MW target, so all four can run — but a merit fill
  offering the 4th unit only the leftover 1,008 MW left it below its own
  minimum, ran three units, and stranded ~1 GW. Only groups the merit fill
  could not serve are touched.

  That explicit zero is load-bearing. `Cascade.apply_dispatch/2` defaults a
  generator MISSING from the dispatch map to `p_max_mw * capacity_factor`, and
  it hands the solver shape `p_max_mw = dispatched MW, capacity_factor = 1.0`
  (physical values ride along as `:p_dispatch_mw` / `:p_nameplate_mw`).
  `PowerModel.Solver.Frequency.simulate/5` keeps only generators with
  `capacity_factor > 0` and `p_max_mw > 0` as online, so a unit dispatched at
  0.0 contributes zero inertia and zero governor response — but a unit merely
  ABSENT from the map would silently come back online at its capacity factor.

  ## Contingency reserve (REVIEW ENE-19)

  A merit-order fill loads every unit it touches to its seasonal capability
  and part-loads only the marginal one, so the operating point it produces
  carries almost no headroom — and what headroom it does carry is wherever
  the merit order happened to leave it, not on machines with governors. The
  measured consequence: ERCOT's fuel-anchored operating point held ~1.27 GW of
  governor-duty headroom against a 1,375 MW design contingency, so the island
  shed customers for its own largest credible single loss.

  Each interconnection therefore holds **primary-capable spinning reserve of at
  least its design contingency** (`contingency_reserve_mw/1`), by backing
  governor-duty units down proportionally inside their own fuel's allocation:
  a hold-back fraction is applied to every governor-duty unit's capability
  cap, so the same measured MW spread across MORE units, each carrying
  headroom a governor can actually reach.

  Three properties of that mechanism are worth stating because they are what
  makes it safe:

    * **The measurement always wins.** The hold-back is a CAP on the merit
      fill, not a reduction of the target. When a fuel's measured MW cannot
      fit under the cap, a second pass fills the remainder at full capability.
      A (BA, fuel) group therefore places exactly the MW it placed before, and
      the fuel-mix total-variation distance is unchanged by construction.
    * **Only governor-duty fuels are touched** (`Frequency.governor_duty?/1`).
      Nuclear, wind, solar and batteries fill exactly as they did: holding
      them back would buy no frequency response at all.
    * **Reserve is measured as `Frequency.primary_response_capability_mw/1`**
      — delivery rate over the nadir window, capped by headroom — never as
      `capability - dispatch`, which credits a nuclear unit's idle megawatts
      as frequency response it will never provide.

  The requirement per interconnection is the resource-loss contingency each
  one sizes its frequency response against, and they are the same anchors the
  BAL-003 acceptance work uses (`test/power_model/solver/frequency_beta_test.exs`):
  Eastern and Western are two-unit nuclear plant losses (Western's is the Palo
  Verde pair), ERCOT's is the South Texas Project pair. Override with

      config :power_model, :contingency_reserve_mw, %{"ERCOT" => 1375.0}

  ## Fallback

  Generators whose bus carries no BA, or whose fuel the BA did not report for
  that hour (including import pseudo-generators, which EIA-930 has no fuel
  column for), are dispatched proportionally within their electrical island
  against whatever load the measured fuels left unserved. When the island's
  measured generation already covers its load the residual is zero and those
  units stay offline; when the island is a net importer the residual is the
  import, which is exactly what an import pseudo-generator should carry.

  ## Return shape

      {:ok, %{
        dispatch: %{generator_id => mw},          # every generator, 0.0 when offline
        coverage: %{
          hour: DateTime.t(),
          season: :summer | :winter,
          target_mw: float,          # measured MW offered to units
          dispatched_mw: float,      # MW actually placed (fuel + fallback)
          unserved_mw: float,        # measured MW no unit could absorb
          share: %{                 # REVIEW ENE-20, the snapshot's share
            aggregate: float,        # target / published, measurement-weighted
            published_mw: float, target_mw: float,
            identity_correction_mw: float, bas_corrected: integer,
            partial_bas: integer, by_ba: %{ba_id => share}
          },
          # BAs with published fuel MW but no demand row for the hour: real
          # exports to neighbours, with nothing local to check them against
          unanchored: [%{ba_id:, code:, published_mw:, dispatched_mw:, load_mw:}],
          unanchored_mw: float,
          # BAs in the snapshot EIA published nothing at all for: their loads
          # keep the synthetic baseline and their units run on the fallback
          no_data: [%{ba_id:, code:, published_mw:, dispatched_mw:, load_mw:}],
          no_data_mw: float,
          fallback_mw: float,        # MW placed by the island fallback
          fallback_capacity_mw: float,
          onsite_mw: float,          # MW placed on onsite solar/wind
          onsite_units: integer,     # in-service onsite solar/wind units
          storage: %{               # ROADMAP item 17, negative = charging
            net_mw: float, charge_mw: float, discharge_mw: float,
            units: integer, charging_units: integer, capability_mw: float,
            by_ba: %{ba_id => storage_stat}   # see Dispatch.Storage
          },
          reserve: %{               # REVIEW ENE-19, contingency reserve
            requirement_mw: float, primary_reserve_mw: float, met?: boolean,
            by_interconnection: %{name => %{
              requirement_mw: float, primary_reserve_mw: float,
              holdback_fraction: float, met?: boolean,
              committed_units: integer, governor_duty_units: integer
            }}
          },
          units: integer,
          online_units: integer,
          offline_units: integer,
          bas: integer,
          by_ba: %{ba_id => %{
            code: String.t() | nil,
            target_mw: float, dispatched_mw: float, unserved_mw: float,
            storage_mw: float,
            load_mw: float | nil,
            share: float,                    # this snapshot's share of the BA
            identity_correction_mw: float,   # MW the ENE20-C anchor moved
            implied_interchange_mw: float | nil,
            reported_interchange_mw: float | nil,
            scaled_interchange_mw: float | nil,   # share x reported
            by_fuel: %{fuel => %{target_mw: float, reported_mw: float,
                                 dispatched_mw: float,
                                 units: integer, online_units: integer,
                                 onsite_mw: float, onsite_units: integer}}
          }},
          missing: [%{ba_id: integer | nil, fuel: String.t(), capacity_mw: float,
                      units: integer}],       # units with no measurement
          unmatched: [%{ba_id: integer, fuel: String.t(), mw: float}],
          unmatched_mw: float                 # measured MW with no unit
        }
      }}

  `{:error, :no_fuel_data}` is returned when no BA reported any fuel for the
  hour — the caller is expected to fall back to its own dispatch rule.

  ## Options

    * `:bus_interconnection` — `%{bus_id => interconnection_name}`, which is
      what the contingency-reserve requirement is keyed by; queried from the
      database when omitted, and simply absent (no requirement held) when the
      caller supplies neither it nor a database
    * `:bus_ba` — `%{bus_id => ba_id}`; queried from the database when omitted
    * `:islands` — list of `MapSet` of bus ids; one island when omitted
    * `:loads` — snapshot loads, used for the island fallback residual and for
      the interchange identity in coverage
    * `:fuel_totals` — `%{ba_id => %{fuel => mw}}`. Supplying it declares the
      caller as the source of truth for the measured MW and suppresses the
      database reads that serve them (BA codes and reported interchange
      included), so the module runs against fixtures with no repo at all.
    * `:storage_profile` — the hourly net-load profile storage is scheduled
      from, in the shape `PowerModel.Dispatch.Storage.profile/2` returns. It
      is a DIFFERENT series from the measured MW, so `:fuel_totals` does not
      cover it: this is queried whenever the snapshot holds a battery and the
      option is absent. Pass `%{}` for a repo-free run with storage in it.
      Supplied or queried, it is stated in the BA's WHOLE published MW and is
      share-scaled on the way into the schedule (ENE-24).
    * `:ba_snapshot_share` — `%{ba_id => share in 0..1}`, the share of each
      BA's load universe this snapshot holds (REVIEW ENE-20). Queried through
      `PowerModel.Demand.snapshot_load_shares/1` when omitted and a database
      is available; **an absent BA is 1.0**, so a repo-free fixture dispatches
      exactly the MW it is given.
    * `:ba_identity_anchor` — `%{ba_id => demand_mw + interchange_mw}` for the
      BAs whose published identity is persistently broken (ENE20-C). Queried
      through `PowerModel.Demand.broken_identity_anchors/1` when omitted and a
      database is available; an absent BA keeps its published fuel mix.
  """

  require Logger

  import Ecto.Query

  alias PowerModel.Demand
  alias PowerModel.Dispatch.Storage
  alias PowerModel.Grid.{BalancingAuthority, Bus, Interconnection}
  alias PowerModel.Repo
  alias PowerModel.Solver.Frequency

  # Design contingency per interconnection (MW): the resource loss each one
  # sizes its frequency response against, and the floor on the primary-capable
  # spinning reserve the dispatch holds (REVIEW ENE-19). Same anchors as
  # `test/power_model/solver/frequency_beta_test.exs`.
  @design_contingency_mw %{
    "Eastern" => 2600.0,
    "Western" => 2626.0,
    "ERCOT" => 1375.0
  }

  # Hold-back search bounds. A governor-duty unit is never backed below this
  # share of its capability: past it the "reserve" is a commitment decision
  # (start another unit), not a loading decision, and the merit order is no
  # longer recognisable.
  @max_holdback_fraction 0.35

  # Bisection steps for the hold-back. Reserve is monotone in the hold-back,
  # so 16 halvings resolve it to ~5e-6 of capability — far finer than the
  # megawatt the requirement is stated in.
  @holdback_iterations 16

  # EIA energy-source code -> the EIA-930 fuel column that reports it.
  # Codes EIA-930 folds into "Other Fuel Sources" / "Other Energy Storage"
  # (biomass, waste, geothermal, batteries, manufactured gases) map to "other";
  # anything unrecognized stays out of the canonical set on purpose so it goes
  # to the island fallback instead of competing for another fuel's MW.
  @fuel_codes %{
    "NUC" => "nuclear",
    "ANT" => "coal",
    "BIT" => "coal",
    "LIG" => "coal",
    "SUB" => "coal",
    "RC" => "coal",
    "WC" => "coal",
    "SC" => "coal",
    "SGC" => "coal",
    "NG" => "natural_gas",
    "DFO" => "petroleum",
    "JF" => "petroleum",
    "KER" => "petroleum",
    "PC" => "petroleum",
    "RFO" => "petroleum",
    "WO" => "petroleum",
    "WAT" => "hydro",
    "WND" => "wind",
    "SUN" => "solar",
    "GEO" => "other",
    "MWH" => "other",
    "BFG" => "other",
    "OG" => "other",
    "PG" => "other",
    "SGP" => "other",
    "LFG" => "other",
    "OBG" => "other",
    "OBL" => "other",
    "OBS" => "other",
    "AB" => "other",
    "BLQ" => "other",
    "MSW" => "other",
    "SLW" => "other",
    "TDF" => "other",
    "WDL" => "other",
    "WDS" => "other",
    "PUR" => "other",
    "WH" => "other",
    "OTH" => "other"
  }

  # Prime movers that make a WAT unit pumped storage, which EIA-930 reports
  # outside the hydro column (and this schema folds into "other").
  @pumped_storage_prime_movers ~w(PS)

  @doc """
  Dispatch `generators` for `hour` from measured EIA-930 per-fuel generation.

  See the module documentation for the return shape and options.
  """
  def for_hour(generators, hour, opts \\ [])

  def for_hour(generators, %DateTime{} = hour, opts) do
    hour = truncate_to_hour(hour)
    supplied = Keyword.get(opts, :fuel_totals)
    fuel_totals = supplied || Demand.fuel_generation_at(hour)

    if map_size(fuel_totals) == 0 do
      {:error, :no_fuel_data}
    else
      allocate_hour(generators, hour, fuel_totals, Keyword.put(opts, :db?, is_nil(supplied)))
    end
  end

  defp allocate_hour(generators, hour, fuel_totals, opts) do
    season = season_for(hour)

    bus_ba =
      Keyword.get_lazy(opts, :bus_ba, fn ->
        if opts[:db?], do: bus_ba_map(generators), else: %{}
      end)

    bus_interconnection =
      Keyword.get_lazy(opts, :bus_interconnection, fn ->
        if opts[:db?], do: bus_interconnection_map(generators), else: %{}
      end)

    loads = Keyword.get(opts, :loads, [])
    islands = Keyword.get(opts, :islands)

    units = Enum.map(generators, &unit(&1, bus_ba, bus_interconnection, season))
    {dispatchable, unavailable} = Enum.split_with(units, & &1.in_service?)

    # Kept so coverage can report what EIA published next to what the pool was
    # actually asked for, once the snapshot's share and the batteries' MW have
    # come out of it.
    reported_totals = fuel_totals

    # REVIEW ENE-20: the snapshot serves its SHARE of each BA's demand
    # (ENE-17), so its units are offered that same share of the BA's measured
    # generation. This runs BEFORE the storage schedule on purpose — the duty
    # cycle is bounded by the "other" column, and sizing it on an unscaled
    # column only to net it against a scaled target would double-count the
    # difference.
    shares = snapshot_shares(opts, loads, islands)

    {fuel_totals, share_stats} = scale_to_snapshot_share(fuel_totals, hour, shares, opts)

    # Batteries run their own duty cycle rather than filling a fuel target
    # that is measured NET of their charging (ROADMAP item 17), so they leave
    # the pool first and the "other" target the pool is offered drops by what
    # they were scheduled to do. The same shares go into the storage profile
    # (ENE-24), so the whole 24 h window it is shaped from is in the units the
    # scaled "other" target above is already in.
    {storage, non_storage} = Enum.split_with(dispatchable, & &1.storage?)
    {storage_alloc, storage_stats} = schedule_storage(storage, hour, fuel_totals, opts, shares)

    fuel_totals = Storage.adjust_fuel_totals(fuel_totals, storage_stats)

    # EIA-930 measures utility-scale solar and wind, so onsite units of those
    # fuels are held out of the pool and run on their own capacity factor.
    {onsite, pooled} = Enum.split_with(non_storage, &onsite_vre?/1)
    {onsite_alloc, onsite_stats} = onsite_dispatch(onsite)

    # Grouped by the (BA, fuel) key the measurement is published at.
    by_group = Enum.group_by(pooled, &{&1.ba_id, &1.fuel})

    {fuel_alloc, group_stats, missing} = allocate_groups(by_group, fuel_totals, %{})

    # REVIEW ENE-19: back governor-duty units down until each interconnection
    # carries primary-capable spinning reserve for its design contingency.
    # The measured MW are unchanged — only which units carry them, and how
    # hard each one is pushed.
    {fuel_alloc, group_stats, reserve_stats} =
      hold_contingency_reserve(by_group, fuel_totals, fuel_alloc, group_stats)

    # A unit inside a measured group that lost the merit order stays offline —
    # the measurement placed every MW it had. Only units whose group was never
    # measured at all are left for the fallback.
    measured_keys = MapSet.new(Map.keys(group_stats))
    leftover = Enum.reject(pooled, &MapSet.member?(measured_keys, {&1.ba_id, &1.fuel}))

    # Onsite and storage MW count as generation already placed on the island,
    # so the fallback's residual does not ask other units to serve that load
    # again — and a charging battery correctly DEEPENS the residual.
    {fallback_alloc, fallback_mw} =
      fallback_dispatch(
        leftover,
        fuel_alloc |> Map.merge(onsite_alloc) |> Map.merge(storage_alloc),
        dispatchable,
        loads,
        islands
      )

    dispatch =
      units
      |> Map.new(&{&1.id, 0.0})
      |> Map.merge(fuel_alloc)
      |> Map.merge(onsite_alloc)
      |> Map.merge(storage_alloc)
      |> Map.merge(fallback_alloc)

    coverage =
      build_coverage(
        hour,
        season,
        units,
        dispatch,
        group_stats,
        onsite_stats,
        storage_stats,
        missing,
        unmatched(fuel_totals, by_group, dispatchable, storage_stats),
        fallback_mw,
        leftover,
        onsite,
        loads,
        bus_ba,
        reported_totals,
        reserve_stats,
        share_stats,
        opts
      )

    log_summary(coverage, unavailable)

    {:ok, %{dispatch: dispatch, coverage: coverage}}
  end

  # ---------------------------------------------------------------------------
  # Unit view
  # ---------------------------------------------------------------------------

  defp unit(generator, bus_ba, bus_interconnection, season) do
    capability = capability_mw(generator, season)
    bus_id = Map.get(generator, :bus_id)

    %{
      id: generator.id,
      bus_id: bus_id,
      ba_id: Map.get(bus_ba, bus_id),
      interconnection: Map.get(bus_interconnection, bus_id),
      fuel: fuel_for(generator),
      capability_mw: capability,
      # A minimum above the seasonal capability would make the unit
      # undispatchable at any MW; clamp so it can still run at capability.
      p_min_mw: min(Map.get(generator, :p_min_mw) || 0.0, capability),
      capacity_factor: Map.get(generator, :capacity_factor) || 0.0,
      in_service?: (Map.get(generator, :status) || "in_service") == "in_service",
      utility_scale?: utility_scale?(generator),
      storage?: Storage.storage?(generator),
      # Frequency-response properties, read once from the swing model's own
      # per-fuel table so the reserve this module holds is the reserve that
      # model will credit (REVIEW ENE-19).
      governor_duty?: Frequency.governor_duty?(generator),
      # Delivery rate on the SEASONAL capability rather than nameplate: the
      # dispatch cannot load a unit above capability, so crediting a rate
      # against nameplate would hold less reserve than the fleet needs.
      primary_rate_mw_per_s:
        Frequency.machine_constants(generator).primary_response_rate_pct_per_s / 100.0 *
          capability
    }
  end

  # Read defensively: only EIA-860 sets this column, so a MATPOWER import, an
  # import pseudo-generator, or a plain-map fixture has no value at all. Both
  # "absent" and NULL mean utility-scale, which is what EIA-860 is
  # overwhelmingly made of — see PowerModel.Ingestion.EIA.Form860.
  defp utility_scale?(generator), do: Map.get(generator, :utility_scale, true) != false

  # Onsite solar and wind: the two fuels whose EIA-930 columns exclude
  # behind-the-meter plant. Every other fuel is measured whoever hosts it.
  defp onsite_vre?(unit), do: not unit.utility_scale? and unit.fuel in ~w(solar wind)

  @doc """
  The EIA-930 fuel column a generator's output is reported in.

  Returns one of the canonical `PowerModel.Demand.BAFuelHour` fuels, or a
  non-canonical string (`"import"`, `"unknown"`) for units EIA-930 does not
  report as generation — those are left to the island fallback.
  """
  def fuel_for(generator) do
    code = generator |> Map.get(:fuel_type) |> to_string() |> String.trim() |> String.upcase()
    prime_mover = generator |> Map.get(:prime_mover) |> to_string() |> String.trim()

    cond do
      code == "WAT" and String.upcase(prime_mover) in @pumped_storage_prime_movers -> "other"
      Map.has_key?(@fuel_codes, code) -> Map.fetch!(@fuel_codes, code)
      code == "" -> "unknown"
      true -> heuristic_fuel(code)
    end
  end

  # Free-text fuel descriptions (MATPOWER imports, hand-built fixtures).
  defp heuristic_fuel(code) do
    f = String.downcase(code)

    cond do
      String.contains?(f, "import") -> "import"
      String.contains?(f, "nuclear") -> "nuclear"
      String.contains?(f, "coal") -> "coal"
      String.contains?(f, "gas") -> "natural_gas"
      String.contains?(f, "oil") or String.contains?(f, "petrol") -> "petroleum"
      String.contains?(f, "hydro") -> "hydro"
      String.contains?(f, "wind") -> "wind"
      String.contains?(f, "solar") -> "solar"
      String.contains?(f, "nuc") -> "nuclear"
      true -> "unknown"
    end
  end

  # Seasonal capability, read defensively: the summer/winter capability columns
  # are being added in parallel, so a struct without them (or a plain map from
  # a fixture) falls back to summer capability and then to nameplate.
  defp capability_mw(generator, season) do
    seasonal =
      case season do
        :winter ->
          Map.get(generator, :winter_capacity_mw) || Map.get(generator, :summer_capacity_mw)

        :summer ->
          Map.get(generator, :summer_capacity_mw)
      end

    seasonal || generator.p_max_mw || 0.0
  end

  # EIA's summer capability season (June-September); everything else is rated
  # on winter capability.
  defp season_for(%DateTime{month: month}) when month in 6..9, do: :summer
  defp season_for(%DateTime{}), do: :winter

  # ---------------------------------------------------------------------------
  # Snapshot share and identity anchoring (REVIEW ENE-20)
  # ---------------------------------------------------------------------------

  # Rewrite each BA's measured fuel MW into the target THIS snapshot's units
  # should be offered, and return the per-BA arithmetic for coverage.
  defp scale_to_snapshot_share(fuel_totals, hour, shares, opts) do
    anchors = identity_anchors(opts, hour)

    Enum.reduce(fuel_totals, {%{}, %{}}, fn {ba_id, fuels}, {totals, stats} ->
      share = Map.get(shares, ba_id, 1.0)
      {targets, correction_mw} = ba_targets(fuels, share, Map.get(anchors, ba_id))

      stat = %{
        share: share,
        published_mw: sum_values(fuels),
        target_mw: sum_values(targets),
        identity_correction_mw: correction_mw
      }

      {Map.put(totals, ba_id, targets), Map.put(stats, ba_id, stat)}
    end)
  end

  # The plain rule: the snapshot is offered its share of every fuel column,
  # which leaves the BA's measured fuel MIX exactly as published.
  defp ba_targets(fuels, share, nil), do: {scale_fuels(fuels, share), 0.0}

  # ENE20-C: a BA whose own published identity `NG - (D + TI)` never closes
  # (BPAT misses by ~4.4 GW on every one of its 4,417 hours) cannot have its
  # net-generation column and its demand/interchange columns both be right,
  # and this dispatch is judged against the second pair — served load and
  # implied interchange. So a SCREENED BA's budget is anchored on `D + TI`,
  # spread over the fuels in the proportions the measurement reports, and the
  # snapshot's share applies to that instead. `PowerModel.Demand` decides who
  # is screened by measurement, never by a stored list.
  defp ba_targets(fuels, share, anchor_mw) do
    positive_mw = fuels |> Map.values() |> Enum.filter(&(&1 > 0.0)) |> Enum.sum()

    if positive_mw <= 0.0 do
      {scale_fuels(fuels, share), 0.0}
    else
      budget_mw = max(anchor_mw, 0.0) * share

      targets =
        Map.new(fuels, fn
          {fuel, mw} when mw > 0.0 -> {fuel, budget_mw * mw / positive_mw}
          # A negative column is storage charging, not generation to re-budget.
          {fuel, mw} -> {fuel, mw * share}
        end)

      {targets, sum_values(targets) - share * sum_values(fuels)}
    end
  end

  defp scale_fuels(fuels, 1.0), do: fuels
  defp scale_fuels(fuels, share), do: Map.new(fuels, fn {fuel, mw} -> {fuel, mw * share} end)

  # Absent from the options and with no database, every share is 1.0 and this
  # module runs exactly as it did before ENE-20 — which is what keeps repo-free
  # fixtures byte-identical.
  defp snapshot_shares(opts, loads, islands) do
    Keyword.get_lazy(opts, :ba_snapshot_share, fn ->
      if opts[:db?], do: Demand.snapshot_load_shares(snapshot_bus_ids(loads, islands)), else: %{}
    end)
  end

  defp identity_anchors(opts, hour) do
    Keyword.get_lazy(opts, :ba_identity_anchor, fn ->
      if opts[:db?], do: Demand.broken_identity_anchors(hour), else: %{}
    end)
  end

  # The buses this snapshot holds. Islands cover the whole bus set; the load
  # bus ids are the half that can carry a baseline, and are enough on their own
  # when the caller passed no islands.
  defp snapshot_bus_ids(loads, islands) do
    island_ids = if islands, do: Enum.flat_map(islands, &MapSet.to_list/1), else: []

    island_ids
    |> Enum.concat(Enum.map(loads, &Map.get(&1, :bus_id)))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # ---------------------------------------------------------------------------
  # Measured allocation
  # ---------------------------------------------------------------------------

  defp allocate_groups(by_group, fuel_totals, holdback) do
    Enum.reduce(by_group, {%{}, %{}, []}, fn {{ba_id, fuel}, group_units},
                                             {alloc, stats, missing} ->
      case measured_mw(fuel_totals, ba_id, fuel) do
        nil ->
          {alloc, stats,
           [
             %{
               ba_id: ba_id,
               fuel: fuel,
               units: length(group_units),
               capacity_mw: sum_by(group_units, & &1.capability_mw)
             }
             | missing
           ]}

        target_mw ->
          {group_alloc, remaining} = fill(group_units, max(target_mw, 0.0), holdback)

          dispatched = target_mw |> max(0.0) |> Kernel.-(remaining)

          stat = %{
            target_mw: target_mw,
            dispatched_mw: dispatched,
            units: length(group_units),
            online_units: Enum.count(group_alloc, fn {_id, mw} -> mw > 0.0 end)
          }

          {Map.merge(alloc, group_alloc), Map.put(stats, {ba_id, fuel}, stat), missing}
      end
    end)
  end

  # Measured MW the network cannot place at all: the BA is in this snapshot but
  # owns no in-service unit of that fuel, so the generation is simply missing
  # from the model. The other half of the coverage gap from `missing`.
  #
  # `fuel_totals` here is already net of storage, so what a BA's batteries
  # carried is not reported as missing; a BA whose only "other" plant IS its
  # batteries has no `by_group` entry for the fuel and is excluded explicitly.
  defp unmatched(fuel_totals, by_group, dispatchable, storage_stats) do
    snapshot_bas = dispatchable |> Enum.map(& &1.ba_id) |> Enum.reject(&is_nil/1) |> MapSet.new()

    for {ba_id, fuels} <- fuel_totals,
        MapSet.member?(snapshot_bas, ba_id),
        {fuel, mw} <- fuels,
        not Map.has_key?(by_group, {ba_id, fuel}),
        not (fuel == "other" and Map.has_key?(storage_stats, ba_id)),
        mw != 0.0 do
      %{ba_id: ba_id, fuel: fuel, mw: mw}
    end
    |> Enum.sort_by(&(-abs(&1.mw)))
  end

  # A group is measured only when the BA reported that exact fuel. Storage
  # charging shows up as negative net generation; it is floored at zero here
  # (charging as load is ROADMAP item 17) but the negative target is kept in
  # coverage so the discrepancy stays visible.
  defp measured_mw(_fuel_totals, nil, _fuel), do: nil

  defp measured_mw(fuel_totals, ba_id, fuel) do
    fuel_totals |> Map.get(ba_id, %{}) |> Map.get(fuel)
  end

  # Merit order fill: highest capacity factor first, then largest unit, then id
  # so the order is stable across runs.
  #
  # `holdback` is the contingency-reserve hold-back per interconnection
  # (REVIEW ENE-19): governor-duty units are capped BELOW their capability so
  # the same measured MW spread over more machines, each keeping headroom a
  # governor can reach. It is a cap on the fill, never a cut to the target —
  # if the capped fleet cannot absorb the measurement, a second pass places
  # the remainder at full capability, because a reserve requirement may not
  # make measured generation disappear.
  defp fill(units, target_mw, holdback) do
    sorted = Enum.sort_by(units, &{-&1.capacity_factor, -&1.capability_mw, &1.id})
    {alloc, remaining} = fill_pass(sorted, target_mw, holdback, %{})

    {alloc, remaining} =
      if remaining > 1.0e-9 and map_size(holdback) > 0 do
        fill_pass(sorted, remaining, %{}, alloc)
      else
        {alloc, remaining}
      end

    if remaining > 1.0e-9 do
      proportional_fill(sorted, target_mw, alloc, remaining)
    else
      {alloc, remaining}
    end
  end

  # REVIEW ENE-20 (ENE20-B): a merit fill loads each unit flat out and offers
  # the REMAINDER to the next one, so a target that falls between two
  # commitment points strands the last slice — ERCO's nuclear group ran 3 of
  # 4 units and left ~1 GW unserved the moment ENE-20 scaled its target down.
  # The MW are there; the merit order just cannot cut a unit in half.
  #
  # So when a merit fill ends short with machines still cold, the group is
  # re-loaded instead: commit the shortest merit-order prefix that can bracket
  # the target, then give every committed unit its minimum load plus a share
  # of what is left, proportional to the room it has above that minimum.
  #
  # Loading over the RANGE rather than over capability is what makes this work
  # on the case it was built for: ERCO's four units carry minimum loads at
  # 90-97% of capability, so a uniform fraction of capability would push two
  # of them under their own minimum even though the group's minimums
  # (4,775 MW) sit below the 4,808 MW target. Anywhere between those two
  # bounds an operating point exists, and every committed unit lands inside
  # `[p_min, capability]` by construction.
  #
  # Commitment order, the per-fuel total and the minimum-load rule all
  # survive; only the loading changes, and only for groups the merit fill
  # could not serve.
  defp proportional_fill(sorted, target_mw, merit_alloc, merit_remaining) do
    idle? =
      Enum.any?(sorted, &(Map.get(merit_alloc, &1.id, 0.0) <= 0.0 and &1.capability_mw > 0.0))

    case idle? and commit(sorted, [], 0.0, 0.0, target_mw) do
      committed when is_list(committed) ->
        room_mw = sum_by(committed, &(&1.capability_mw - &1.p_min_mw))
        above_minimum_mw = target_mw - sum_by(committed, & &1.p_min_mw)

        alloc =
          Enum.reduce(committed, Map.new(sorted, &{&1.id, 0.0}), fn unit, alloc ->
            room = unit.capability_mw - unit.p_min_mw
            extra = if room_mw > 0.0, do: above_minimum_mw * room / room_mw, else: 0.0

            Map.put(alloc, unit.id, unit.p_min_mw + extra)
          end)

        {alloc, 0.0}

      _ ->
        {merit_alloc, merit_remaining}
    end
  end

  # Grow the committed set in merit order until its capability covers the
  # target. A committed set also has to be able to run DOWN to the target, so
  # when its minimum loads already exceed it the largest must-run unit is
  # dropped and the search continues. A dropped unit never returns, so this
  # terminates in at most two passes over the group. `nil` when no prefix can
  # bracket the target, which leaves the merit fill — and its unserved MW,
  # genuinely unplaceable at that point — exactly as it was.
  defp commit(rest, committed, capability_mw, minimum_mw, target_mw)
       when capability_mw >= target_mw do
    if minimum_mw <= target_mw do
      Enum.reverse(committed)
    else
      worst = Enum.max_by(committed, &{&1.p_min_mw, &1.id})

      commit(
        rest,
        committed -- [worst],
        capability_mw - worst.capability_mw,
        minimum_mw - worst.p_min_mw,
        target_mw
      )
    end
  end

  defp commit([], _committed, _capability_mw, _minimum_mw, _target_mw), do: nil

  defp commit([unit | rest], committed, capability_mw, minimum_mw, target_mw) do
    commit(
      rest,
      [unit | committed],
      capability_mw + unit.capability_mw,
      minimum_mw + unit.p_min_mw,
      target_mw
    )
  end

  defp fill_pass(sorted_units, target_mw, holdback, alloc) do
    Enum.reduce(sorted_units, {alloc, target_mw}, fn unit, {alloc, remaining} ->
      already = Map.get(alloc, unit.id, 0.0)
      take = min(capped_capability_mw(unit, holdback) - already, remaining)

      cond do
        take <= 0.0 ->
          {Map.put_new(alloc, unit.id, 0.0), remaining}

        already == 0.0 and take < unit.p_min_mw ->
          # Below its minimum load this unit cannot run at all; leave it
          # offline and offer the remaining MW to the next unit in merit order.
          {Map.put(alloc, unit.id, 0.0), remaining}

        true ->
          {Map.put(alloc, unit.id, already + take), remaining - take}
      end
    end)
  end

  defp capped_capability_mw(unit, holdback) do
    case unit.governor_duty? and Map.get(holdback, unit.interconnection) do
      fraction when is_number(fraction) -> unit.capability_mw * (1.0 - fraction)
      _ -> unit.capability_mw
    end
  end

  # ---------------------------------------------------------------------------
  # Contingency reserve (REVIEW ENE-19)
  # ---------------------------------------------------------------------------

  @doc """
  Design-contingency reserve requirement for an interconnection, in MW, or
  `nil` for a system with no requirement configured.

  Override the whole table with

      config :power_model, :contingency_reserve_mw, %{"ERCOT" => 1375.0}
  """
  @spec contingency_reserve_mw(String.t() | nil) :: float() | nil
  def contingency_reserve_mw(interconnection) do
    Map.get(contingency_reserves(), interconnection)
  end

  @doc "The whole design-contingency table, config override included."
  @spec contingency_reserves() :: %{optional(String.t()) => float()}
  def contingency_reserves do
    Application.get_env(:power_model, :contingency_reserve_mw, @design_contingency_mw)
  end

  @doc """
  Primary-capable spinning reserve one dispatched unit carries, in MW.

  `PowerModel.Solver.Frequency.primary_response_capability_mw/1` in the
  dispatch's own terms: delivery rate over the nadir window, capped by the
  headroom below seasonal capability, and zero for a unit with no governor
  duty or one the merit order left offline (a governor on an unsynchronised
  machine moves nothing).
  """
  @spec unit_primary_reserve_mw(map(), float()) :: float()
  def unit_primary_reserve_mw(unit, dispatched_mw) do
    if unit.governor_duty? and dispatched_mw > 0.0 do
      min(
        unit.primary_rate_mw_per_s * Frequency.nadir_window_seconds(),
        max(unit.capability_mw - dispatched_mw, 0.0)
      )
    else
      0.0
    end
  end

  # Find, per interconnection, the smallest hold-back that meets the design
  # contingency, and re-fill with it. Reserve is monotone non-decreasing in the
  # hold-back, so a bisection is exact enough and cheap; the interconnections
  # are resolved one at a time because a (BA, fuel) group whose units straddle
  # a seam is rare and its coupling is second-order.
  defp hold_contingency_reserve(by_group, fuel_totals, alloc, stats) do
    requirements = contingency_reserves()
    pooled = by_group |> Map.values() |> List.flatten()

    present =
      pooled
      |> Enum.map(& &1.interconnection)
      |> Enum.uniq()
      |> Enum.filter(&Map.has_key?(requirements, &1))

    {alloc, stats, _holdback, reserve} =
      Enum.reduce(present, {alloc, stats, %{}, %{}}, fn name, {alloc, stats, holdback, reserve} ->
        requirement = Map.fetch!(requirements, name)
        units = Enum.filter(pooled, &(&1.interconnection == name))
        held = reserve_mw(units, alloc)

        {alloc, stats, holdback, fraction, held} =
          if held >= requirement do
            {alloc, stats, holdback, 0.0, held}
          else
            search_holdback(by_group, fuel_totals, units, name, requirement, holdback)
          end

        {alloc, stats, holdback,
         Map.put(reserve, name, %{
           requirement_mw: requirement,
           primary_reserve_mw: held,
           holdback_fraction: fraction,
           met?: held >= requirement - 1.0e-6,
           committed_units: Enum.count(units, &(Map.get(alloc, &1.id, 0.0) > 0.0)),
           governor_duty_units: Enum.count(units, & &1.governor_duty?)
         })}
      end)

    {alloc, stats, reserve}
  end

  # Bisect on this interconnection's hold-back fraction, keeping the fractions
  # already resolved for its neighbours. The largest fraction is evaluated
  # first, so a requirement the fleet cannot meet at all still leaves the best
  # operating point available rather than the untouched one.
  defp search_holdback(by_group, fuel_totals, units, name, requirement, holdback) do
    {ceiling_alloc, ceiling_stats, ceiling_held} =
      evaluate_holdback(by_group, fuel_totals, units, name, @max_holdback_fraction, holdback)

    if ceiling_held < requirement do
      {ceiling_alloc, ceiling_stats, Map.put(holdback, name, @max_holdback_fraction),
       @max_holdback_fraction, ceiling_held}
    else
      {_low, _high, alloc, stats, fraction, held} =
        Enum.reduce(
          1..@holdback_iterations,
          {0.0, @max_holdback_fraction, ceiling_alloc, ceiling_stats, @max_holdback_fraction,
           ceiling_held},
          fn _i, {low, high, alloc, stats, fraction, held} ->
            mid = (low + high) / 2.0

            {mid_alloc, mid_stats, mid_held} =
              evaluate_holdback(by_group, fuel_totals, units, name, mid, holdback)

            if mid_held >= requirement do
              {low, mid, mid_alloc, mid_stats, mid, mid_held}
            else
              {mid, high, alloc, stats, fraction, held}
            end
          end
        )

      {alloc, stats, Map.put(holdback, name, fraction), fraction, held}
    end
  end

  defp evaluate_holdback(by_group, fuel_totals, units, name, fraction, holdback) do
    {alloc, stats, _missing} =
      allocate_groups(by_group, fuel_totals, Map.put(holdback, name, fraction))

    {alloc, stats, reserve_mw(units, alloc)}
  end

  defp reserve_mw(units, alloc) do
    sum_by(units, &unit_primary_reserve_mw(&1, Map.get(alloc, &1.id, 0.0)))
  end

  # ---------------------------------------------------------------------------
  # Onsite solar and wind
  # ---------------------------------------------------------------------------

  # Onsite units run at their own capacity factor against seasonal capability.
  # There is no measured MW to fill them from — EIA-930 counted the utility
  # fleet — so nothing here competes for, or consumes, a BA's fuel target.
  # Stats come back keyed the way the measurement is, so coverage can report
  # the onsite MW next to the utility-scale target it is NOT part of.
  defp onsite_dispatch([]), do: {%{}, %{}}

  defp onsite_dispatch(units) do
    Enum.reduce(units, {%{}, %{}}, fn unit, {alloc, stats} ->
      mw = min(unit.capability_mw * unit.capacity_factor, unit.capability_mw)
      mw = if mw <= 0.0 or mw < unit.p_min_mw, do: 0.0, else: mw

      stat =
        stats
        |> Map.get({unit.ba_id, unit.fuel}, %{onsite_mw: 0.0, onsite_units: 0})
        |> then(&%{onsite_mw: &1.onsite_mw + mw, onsite_units: &1.onsite_units + 1})

      {Map.put(alloc, unit.id, mw), Map.put(stats, {unit.ba_id, unit.fuel}, stat)}
    end)
  end

  # ---------------------------------------------------------------------------
  # Storage
  # ---------------------------------------------------------------------------

  # The duty cycle needs the BA's hourly net-load profile: two queries covering
  # the BAs that actually own storage, and none at all for a snapshot with no
  # batteries in it.
  #
  # This read is deliberately NOT gated on `:fuel_totals`. That option means
  # "these are the measured MW for the hour", and the profile is a different
  # series entirely — gating it left every replayed hour with an idle fleet
  # AND its share of the "other" column stranded as unserved. A caller with no
  # repo passes `:storage_profile` (`%{}` for none).
  defp schedule_storage([], _hour, _fuel_totals, _opts, _shares), do: {%{}, %{}}

  defp schedule_storage(storage, hour, fuel_totals, opts, shares) do
    # Scaled AFTER the option is read, not only inside the query, so a
    # fixture-supplied profile lands in the same units as a queried one
    # (ENE-24). With every share 1.0 this is the identity.
    profile =
      opts
      |> Keyword.get_lazy(:storage_profile, fn ->
        storage
        |> Enum.map(& &1.ba_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Storage.profile(hour)
      end)
      |> Storage.scale_profile(shares)

    Storage.schedule(storage, hour, profile, fuel_totals)
  end

  # ---------------------------------------------------------------------------
  # Island fallback
  # ---------------------------------------------------------------------------

  # Units the measurement cannot place: no BA, or a fuel the BA did not report.
  # They share whatever load the measured MW left unserved inside their island.
  defp fallback_dispatch([], _fuel_alloc, _all_units, _loads, _islands), do: {%{}, 0.0}

  defp fallback_dispatch(leftover, fuel_alloc, all_units, loads, islands) do
    islands = islands || [:all]

    Enum.reduce(islands, {%{}, 0.0}, fn island, {alloc, total} ->
      island_units = Enum.filter(leftover, &in_island?(&1, island))

      if island_units == [] do
        {alloc, total}
      else
        island_load = loads |> Enum.filter(&in_island?(&1, island)) |> sum_by(& &1.p_mw)

        placed_mw =
          all_units
          |> Enum.filter(&in_island?(&1, island))
          |> sum_by(&Map.get(fuel_alloc, &1.id, 0.0))

        {island_alloc, island_mw} = spread(island_units, island_load, placed_mw, loads == [])

        {Map.merge(alloc, island_alloc), total + island_mw}
      end
    end)
  end

  defp in_island?(_item, :all), do: true
  defp in_island?(item, island), do: MapSet.member?(island, Map.get(item, :bus_id))

  # Without loads there is no residual to spread, so uncovered units keep the
  # capacity-factor operating point they would have had before this module
  # existed. With loads, they share the island's unserved MW in proportion to
  # their expected output.
  defp spread(units, island_load, placed_mw, no_loads?) do
    expected = sum_by(units, &(&1.capability_mw * &1.capacity_factor))
    residual = island_load - placed_mw

    factor =
      cond do
        no_loads? -> 1.0
        expected <= 0.0 -> 0.0
        residual <= 0.0 -> 0.0
        true -> min(residual / expected, 1.0)
      end

    Enum.reduce(units, {%{}, 0.0}, fn unit, {alloc, total} ->
      mw = min(unit.capability_mw * unit.capacity_factor * factor, unit.capability_mw)

      if mw <= 0.0 or mw < unit.p_min_mw do
        {Map.put(alloc, unit.id, 0.0), total}
      else
        {Map.put(alloc, unit.id, mw), total + mw}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Coverage
  # ---------------------------------------------------------------------------

  defp build_coverage(
         hour,
         season,
         units,
         dispatch,
         group_stats,
         onsite_stats,
         storage_stats,
         missing,
         unmatched,
         fallback_mw,
         leftover,
         onsite,
         loads,
         bus_ba,
         reported_totals,
         reserve_stats,
         share_stats,
         opts
       ) do
    by_ba_fuel = Enum.group_by(group_stats, fn {{ba_id, _fuel}, _stat} -> ba_id end)
    load_by_ba = load_by_ba(loads, bus_ba)

    reported = if opts[:db?], do: Demand.interchange_at(hour), else: %{}
    demand = if opts[:db?], do: Demand.demand_at(hour), else: %{}

    dispatch_by_ba = dispatch_by_ba(units, dispatch)

    # A BA whose only "other" plant is its batteries has no measured group at
    # all, and still has to appear: its storage is real MW on the network.
    ba_ids = MapSet.union(MapSet.new(Map.keys(by_ba_fuel)), MapSet.new(Map.keys(storage_stats)))

    by_ba =
      Map.new(ba_ids, fn ba_id ->
        fuels =
          by_ba_fuel
          |> Map.get(ba_id, [])
          |> Map.new(fn {{_ba, fuel}, stat} ->
            onsite = Map.get(onsite_stats, {ba_id, fuel}, %{onsite_mw: 0.0, onsite_units: 0})

            {fuel,
             stat
             |> Map.take([:target_mw, :dispatched_mw, :units, :online_units])
             |> Map.put(:reported_mw, reported_mw(reported_totals, ba_id, fuel))
             |> Map.merge(onsite)}
          end)

        target = fuels |> Map.values() |> sum_by(& &1.target_mw)
        ba_dispatch = Map.get(dispatch_by_ba, ba_id, 0.0)
        load_mw = Map.get(load_by_ba, ba_id)
        share = share_stats |> Map.get(ba_id, %{}) |> Map.get(:share, 1.0)
        reported_ix = Map.get(reported, ba_id)

        {ba_id,
         %{
           code: nil,
           target_mw: target,
           dispatched_mw: ba_dispatch,
           unserved_mw: max(target - (fuels |> Map.values() |> sum_by(& &1.dispatched_mw)), 0.0),
           storage_mw: storage_stats |> Map.get(ba_id, %{}) |> Map.get(:net_mw, 0.0),
           load_mw: load_mw,
           # ENE-20: the snapshot holds `share` of this BA's load universe, so
           # it should reproduce `share` of the interchange EIA reported — the
           # full figure belongs to the whole BA, not to this slice of it.
           share: share,
           identity_correction_mw:
             share_stats |> Map.get(ba_id, %{}) |> Map.get(:identity_correction_mw, 0.0),
           implied_interchange_mw: load_mw && ba_dispatch - load_mw,
           reported_interchange_mw: reported_ix,
           scaled_interchange_mw: reported_ix && reported_ix * share,
           by_fuel: fuels
         }}
      end)

    snapshot_bas = bus_ba |> Map.values() |> Enum.reject(&is_nil/1) |> MapSet.new()
    anchors = anchor_buckets(reported_totals, demand, dispatch_by_ba, load_by_ba, snapshot_bas)
    by_ba = if opts[:db?], do: attach_codes(by_ba), else: by_ba
    anchors = if opts[:db?], do: attach_bucket_codes(anchors), else: anchors
    target_mw = by_ba |> Map.values() |> sum_by(& &1.target_mw)
    dispatched_mw = dispatch |> Map.values() |> Enum.sum()
    online = Enum.count(dispatch, fn {_id, mw} -> mw > 0.0 end)

    %{
      hour: hour,
      season: season,
      target_mw: target_mw,
      dispatched_mw: dispatched_mw,
      share: share_coverage(Map.take(share_stats, MapSet.to_list(snapshot_bas))),
      unanchored: anchors.unanchored,
      unanchored_mw: sum_by(anchors.unanchored, & &1.published_mw),
      no_data: anchors.no_data,
      no_data_mw: sum_by(anchors.no_data, & &1.dispatched_mw),
      unserved_mw: by_ba |> Map.values() |> sum_by(& &1.unserved_mw),
      fallback_mw: fallback_mw,
      fallback_capacity_mw: sum_by(leftover, & &1.capability_mw),
      onsite_mw: sum_by(onsite, &Map.get(dispatch, &1.id, 0.0)),
      onsite_units: length(onsite),
      storage: storage_coverage(storage_stats),
      reserve: reserve_coverage(reserve_stats),
      units: length(units),
      online_units: online,
      offline_units: length(units) - online,
      bas: map_size(by_ba),
      by_ba: by_ba,
      missing: Enum.sort_by(missing, &(-&1.capacity_mw)),
      unmatched: unmatched,
      unmatched_mw: sum_by(unmatched, & &1.mw)
    }
  end

  # What the BA reported for the fuel before the snapshot's share and the
  # batteries' MW were taken out of it.
  defp reported_mw(reported_totals, ba_id, fuel) do
    reported_totals |> Map.get(ba_id, %{}) |> Map.get(fuel, 0.0)
  end

  # ENE20-D: the aggregate share, weighted by the measurement it was applied
  # to, so one number says how much of the country's published generation this
  # snapshot was offered — and drifts back toward 1.0 as connectivity repair
  # pulls fragments into the main component.
  defp share_coverage(share_stats) do
    stats = Map.values(share_stats)
    published_mw = sum_by(stats, & &1.published_mw)
    target_mw = sum_by(stats, & &1.target_mw)

    %{
      aggregate: if(published_mw != 0.0, do: target_mw / published_mw, else: 1.0),
      published_mw: published_mw,
      target_mw: target_mw,
      identity_correction_mw: sum_by(stats, & &1.identity_correction_mw),
      bas_corrected: Enum.count(stats, &(&1.identity_correction_mw != 0.0)),
      partial_bas: Enum.count(stats, &(&1.share < 0.999)),
      by_ba: Map.new(share_stats, fn {ba_id, stat} -> {ba_id, stat.share} end)
    }
  end

  # ENE20-E: the two ways a BA can carry MW with nothing to anchor them to.
  #
  #   * `unanchored` — EIA published per-fuel generation for it but no demand
  #     row for the hour, so there is no demand and no interchange to check
  #     its injection against (measured: DEAA, GRID, HGMA, AVRN, ~1.6 GW in
  #     Western). Their MW are real exports to neighbours whose demand IS
  #     counted, so they are dispatched — and named here, because otherwise
  #     they read as an unexplained residual in the interconnection balance.
  #   * `no_data` — a BA in the snapshot that EIA published nothing for this
  #     hour (measured: GRIF has no row of either kind, ever; SEPA and YAD
  #     report zero fuel MW). Its loads keep the synthetic baseline and its
  #     units run on the island fallback, which is a different quantity from
  #     an unanchored measurement and must not be added to it.
  defp anchor_buckets(reported_totals, demand, dispatch_by_ba, load_by_ba, snapshot_bas) do
    anchored? = fn ba_id -> is_number(Map.get(demand, ba_id)) end

    {unanchored, no_data} =
      snapshot_bas
      |> Enum.reject(anchored?)
      |> Enum.map(fn ba_id ->
        %{
          ba_id: ba_id,
          code: nil,
          published_mw: reported_totals |> Map.get(ba_id, %{}) |> sum_values(),
          dispatched_mw: Map.get(dispatch_by_ba, ba_id, 0.0),
          load_mw: Map.get(load_by_ba, ba_id, 0.0)
        }
      end)
      |> Enum.split_with(&(&1.published_mw != 0.0))

    %{
      unanchored: Enum.sort_by(unanchored, &(-&1.published_mw)),
      no_data:
        no_data
        |> Enum.reject(&(&1.dispatched_mw == 0.0 and &1.load_mw == 0.0))
        |> Enum.sort_by(&(-&1.dispatched_mw))
    }
  end

  defp attach_bucket_codes(%{unanchored: unanchored, no_data: no_data} = buckets) do
    ba_ids = Enum.map(unanchored ++ no_data, & &1.ba_id)

    if ba_ids == [] do
      buckets
    else
      codes =
        from(ba in BalancingAuthority, where: ba.id in ^ba_ids, select: {ba.id, ba.code})
        |> Repo.all()
        |> Map.new()

      Map.new(buckets, fn {key, entries} ->
        {key, Enum.map(entries, &%{&1 | code: Map.get(codes, &1.ba_id)})}
      end)
    end
  end

  defp reserve_coverage(reserve_stats) do
    stats = Map.values(reserve_stats)

    %{
      requirement_mw: sum_by(stats, & &1.requirement_mw),
      primary_reserve_mw: sum_by(stats, & &1.primary_reserve_mw),
      met?: Enum.all?(stats, & &1.met?),
      by_interconnection: reserve_stats
    }
  end

  defp storage_coverage(storage_stats) do
    stats = Map.values(storage_stats)

    %{
      net_mw: sum_by(stats, & &1.net_mw),
      charge_mw: sum_by(stats, & &1.charge_mw),
      discharge_mw: sum_by(stats, & &1.discharge_mw),
      capability_mw: sum_by(stats, & &1.capability_mw),
      units: stats |> Enum.map(& &1.units) |> Enum.sum(),
      charging_units: stats |> Enum.map(& &1.charging_units) |> Enum.sum(),
      by_ba: storage_stats
    }
  end

  defp dispatch_by_ba(units, dispatch) do
    Enum.reduce(units, %{}, fn unit, acc ->
      mw = Map.get(dispatch, unit.id, 0.0)

      if unit.ba_id, do: Map.update(acc, unit.ba_id, mw, &(&1 + mw)), else: acc
    end)
  end

  defp load_by_ba([], _bus_ba), do: %{}

  defp load_by_ba(loads, bus_ba) do
    Enum.reduce(loads, %{}, fn load, acc ->
      case Map.get(bus_ba, load.bus_id) do
        nil -> acc
        ba_id -> Map.update(acc, ba_id, load.p_mw, &(&1 + load.p_mw))
      end
    end)
  end

  defp attach_codes(by_ba) when map_size(by_ba) == 0, do: by_ba

  defp attach_codes(by_ba) do
    codes =
      from(ba in BalancingAuthority, where: ba.id in ^Map.keys(by_ba), select: {ba.id, ba.code})
      |> Repo.all()
      |> Map.new()

    Map.new(by_ba, fn {ba_id, entry} -> {ba_id, %{entry | code: Map.get(codes, ba_id)}} end)
  end

  defp log_summary(coverage, unavailable) do
    Logger.info(
      "Dispatch #{DateTime.to_iso8601(coverage.hour)} (#{coverage.season}): " <>
        "#{gw(coverage.dispatched_mw)} GW on #{coverage.online_units}/#{coverage.units} units " <>
        "across #{coverage.bas} BAs " <>
        "(measured #{gw(coverage.target_mw)} GW, unserved #{gw(coverage.unserved_mw)} GW, " <>
        "island fallback #{gw(coverage.fallback_mw)} GW of " <>
        "#{gw(coverage.fallback_capacity_mw)} GW capacity, " <>
        "onsite solar/wind #{gw(coverage.onsite_mw)} GW on #{coverage.onsite_units} units, " <>
        "storage #{gw(coverage.storage.net_mw)} GW net " <>
        "(#{gw(coverage.storage.discharge_mw)} GW discharging, " <>
        "#{gw(coverage.storage.charge_mw)} GW charging on " <>
        "#{coverage.storage.charging_units}/#{coverage.storage.units} units), " <>
        "#{length(unavailable)} units out of service)"
    )

    share = coverage.share

    if share.partial_bas > 0 or share.identity_correction_mw != 0.0 do
      Logger.info(
        "Dispatch share (ENE-20): units were offered #{pct(share.aggregate)} of the " <>
          "#{gw(share.published_mw)} GW EIA published for the snapshot's BAs " <>
          "(#{share.partial_bas} of #{map_size(share.by_ba)} BAs partially in the snapshot)" <>
          if(share.bas_corrected == 0,
            do: "",
            else:
              ", including #{round1(share.identity_correction_mw)} MW of identity correction " <>
                "on #{share.bas_corrected} BA(s) whose published NG - (D + TI) never closes"
          )
      )
    end

    if coverage.unanchored != [] or coverage.no_data != [] do
      Logger.info(
        "Dispatch anchoring: #{round1(coverage.unanchored_mw)} MW published by " <>
          "#{length(coverage.unanchored)} BAs with no demand row " <>
          "(#{bucket_codes(coverage.unanchored, :published_mw)}); " <>
          "#{round1(coverage.no_data_mw)} MW of fallback dispatch on " <>
          "#{length(coverage.no_data)} BAs EIA published nothing for " <>
          "(#{bucket_codes(coverage.no_data, :dispatched_mw)})"
      )
    end

    for {name, r} <- coverage.reserve.by_interconnection do
      Logger.info(
        "Dispatch reserve #{name}: #{Float.round(r.primary_reserve_mw, 0)} MW primary-capable " <>
          "spinning against a #{Float.round(r.requirement_mw, 0)} MW design contingency " <>
          "(#{if r.met?, do: "met", else: "SHORT"}; " <>
          "#{Float.round(r.holdback_fraction * 100, 2)}% hold-back on " <>
          "#{r.governor_duty_units} governor-duty units, #{r.committed_units} committed)"
      )
    end

    if coverage.missing != [] do
      top =
        coverage.missing
        |> Enum.take(5)
        |> Enum.map_join(", ", fn m ->
          "#{m.fuel}@BA #{inspect(m.ba_id)} #{gw(m.capacity_mw)} GW"
        end)

      Logger.info(
        "Dispatch: #{length(coverage.missing)} (BA, fuel) groups had no EIA-930 measurement " <>
          "and fell back to island-proportional dispatch -- largest: #{top}"
      )
    end
  end

  defp gw(mw), do: Float.round(mw / 1000.0, 1)
  defp round1(mw), do: Float.round(mw * 1.0, 1)
  defp pct(share), do: "#{Float.round(share * 100.0, 1)}%"

  defp bucket_codes([], _key), do: "none"

  defp bucket_codes(entries, key) do
    entries
    |> Enum.take(6)
    |> Enum.map_join(", ", &"#{&1.code || "BA #{&1.ba_id}"} #{round1(Map.fetch!(&1, key))} MW")
  end

  defp sum_by(list, fun), do: list |> Enum.map(fun) |> Enum.sum()
  defp sum_values(map), do: map |> Map.values() |> Enum.sum()

  defp bus_ba_map(generators) do
    bus_ids = generator_bus_ids(generators)

    if bus_ids == [] do
      %{}
    else
      from(b in Bus, where: b.id in ^bus_ids, select: {b.id, b.balancing_authority_id})
      |> Repo.all()
      |> Map.new()
    end
  end

  defp bus_interconnection_map(generators) do
    bus_ids = generator_bus_ids(generators)

    if bus_ids == [] do
      %{}
    else
      from(b in Bus,
        join: i in Interconnection,
        on: i.id == b.interconnection_id,
        where: b.id in ^bus_ids,
        select: {b.id, i.name}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  defp generator_bus_ids(generators) do
    generators |> Enum.map(&Map.get(&1, :bus_id)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp truncate_to_hour(%DateTime{} = ts) do
    ts = DateTime.shift_zone!(ts, "Etc/UTC")

    %{ts | minute: 0, second: 0, microsecond: {0, 0}} |> DateTime.truncate(:second)
  end
end
