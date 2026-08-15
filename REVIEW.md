# PowerModel Full-Codebase Review — 2026-08-15

Method: seven domain-specialist agents (solver math, energy systems, cascade/protection,
plants, lines, data pipeline, map/UI) each performed a read-only review of their domain.
Findings below were verified by the reviewers (numeric probes, live HIFLD pulls, executed
repros) where marked. Prior audit rounds' fixes (LU pivoting, swing signs, IEC curve, duty
integral, Q-limit conventions, bus shunts, DC taps, conservation buckets, ERCOT seam,
Form-860 status) were re-verified clean by all reviewers and are NOT re-listed.

Disposition legend:
- **[FIX:R3-x]** — being fixed in remediation round 3 by package `x` (see §Packages)
- **[DEFER]** — real, documented, not in this round (most need schema/design work)
- **[ACCEPTED]** — intended behavior or accepted limitation, documented here

Fix packages (file ownership is exclusive per package):
- **R3-solver** — solver/{partition,solution,dc_power_flow,newton_raphson}.ex, engine/{interconnection,cache}.ex, solver tests
- **R3-cascade** — failure/{cascade,load_shedding}.ex, cascade tests
- **R3-freq** — solver/frequency.ex, failure/protection.ex, demand.ex, their tests, proofs/README note
- **R3-plants** — ingestion/eia/{form860,form923}.ex, ingestion/epa/egrid.ex, generator migrations, their tests
- **R3-lines** — ingestion/hifld/{substations,transmission_lines}.ex, ingestion/parameter_estimator.ex, their tests
- **R3-data** — ingestion/{bus_mapper,ba_mapper,cleanup,international_connections}.ex, ingestion/census/population.ex, ingestion/water/san_diego.ex, grid.ex, grid_export.ex, mix tasks, data migrations, their tests
- **R3-uijs** — assets/js/**, assets/css/grid/**, root layout CSS link
- **R3-engine** — engine/simulation_server.ex, power_model_web/** (LiveView + components + web tests). Runs AFTER the others (depends on their contracts).

---

## SOL — Solver numerical core

**SOL-1 (HIGH) [FIX:R3-solver]** A total blackout reports `converged: true` with zero load.
`partition.ex:60-62` — `merge_solutions([], base)` inherits `Solution.new` defaults
(`converged: true, max_mismatch: 0.0`). Executed repro: 200-bus all-dead snapshot →
`%{converged: true, total_load_mw: 0.0}` and `energy_balance` ok.
Fix guidance: empty-islands merge must yield `converged: false` and carry
`n_islands_solved: 0`; add `dead_load_mw`/`dead_bus_count` fields to `Solution` populated
by `solve_islands` from Partition's dead set, so callers can see unserved load.

**SOL-2 (HIGH) [FIX:R3-solver]** `Solution.energy_balance/2` is tautological.
DC sets `total_gen_mw = total_load_mw` by definition (`dc_power_flow.ex:121-129`); converged
AC defines gen = load + loss (`newton_raphson.ex:110-113`). No genuine solve can fail it.
Fix guidance: give `energy_balance` an optional expected-load argument (snapshot demand);
`SimulationServer.audit_solution` must compare `solution.total_load_mw + dead_load_mw`
against the snapshot's load sum, not solution-internal identities. (SimulationServer side
lands in R3-engine; Solution/DC side here.)

**SOL-3 (HIGH) [FIX:R3-solver]** Dead-island load vanishes from merged totals; 1-bus islands
with gen+load are discarded. `partition.ex:21-31` (`min_buses \\ 2`), `dc_power_flow.ex:24-31`
never re-attaches dead islands. Fix guidance: single-bus islands with generation are trivially
solvable (θ=0) — solve them; dead-island buses/loads surface via SOL-1's fields.

**SOL-4 (HIGH) [FIX:R3-solver]** Unguarded O(n³) pure-Elixir Gaussian fallback: measured 21 s
at 300 buses, extrapolates to hours at 3k, inside a GenServer call. Only identified entry:
dead `Engine.Interconnection` (SOL-6). Fix guidance: cap `gaussian_solve` (e.g. n ≤ 500 →
else return singular/oversize error) and let callers' fallback chain surface an error.

**SOL-5 (MED) [FIX:R3-solver]** `aggregate_q_limits` uses dot-access on optional keys —
`newton_raphson.ex:279-280` raises KeyError on plain maps without q limits, violating the
documented Map.get convention (ybus.ex:139). Same pattern at newton_raphson.ex:963,965,978,
1002,1004,1020 and dc_power_flow.ex:218,413,431,437. Fix: Map.get with defaults everywhere;
regression test with a limit-less generator map.

**SOL-6 (MED) [FIX:R3-solver]** `Engine.Interconnection` is dead code violating the
partition-first rule (`interconnection.ex:26` calls `solve/2` not `solve_islands/2`; broken
catch/Task semantics). `Engine.Cache` is dead code that raises on first use (no `init/0` in
supervision tree). Fix: delete both modules (verify no callers first).

**SOL-7 (MED) [FIX:R3-freq]** `Frequency.simulate` with duration < dt iterates a DESCENDING
range (`1..0`) emitting a non-monotonic 3-record trajectory. `frequency.ex:122,141`.
Fix: `total_steps <= 0 → return [initial_record]`; use `1..total_steps//1`.

**SOL-8 (MED) [ACCEPTED]** `q_gen` is an all-zeros array threaded through ten signatures —
harmless only because every generator bus is PV. Documented here; simplify when NR is next
reworked.

**SOL-9 (LOW) [ACCEPTED]** Empty-grid signalled by `throw` not return value (both solvers).
**SOL-10 (LOW) [FIX:R3-solver]** NR `solve_jacobian_gauss` zeroes free variables on singular
pivot instead of erroring (`newton_raphson.ex:911-937`); divergence guard misses NaN.
Fix: mirror DC's throw-on-singular; add NaN check (`mis != mis`).
**SOL-11 (LOW) [FIX:R3-solver]** YBus sizes by `map_size` vs NR by `length(buses)` — duplicate
bus ids silently understate losses. Fix: raise on duplicate bus ids in both.

## CAS — Cascade engine / engine layer

**CAS-1 (HIGH) [FIX:R3-engine]** Partial AC refinement broadcast as whole-grid authoritative:
islands > 3,000 buses dropped, diverged islands filtered, remainder merged and broadcast
(`simulation_server.ex:384-422`); client reset+repaint erases every mark on skipped islands
(`map_manager.js:265-275`), metrics collapse to the fragment totals. Fix guidance: broadcast
`ac_update` ONLY when the AC result covers every island the DC solve covered; otherwise log
and skip (honest degradation). Never overwrite metrics from a partial result.

**CAS-2 (HIGH) [FIX:R3-cascade]** `@max_steps` is a per-SESSION budget: `state.step` never
resets, so after 50 cumulative steps every further trip is a silent no-op (executed repro).
`cascade.ex:25,502-507`. Fix guidance: reset `step`, `simulated_time`, and `relay_duty` at
every public trip entry point (each manual injection = a new cascade event); add a
max-steps regression test; when the budget IS exhausted mid-cascade, mark it loudly
(`stable: false` + event).

**CAS-3 (MED-HIGH) [FIX:R3-engine]** LiveView reports every finished cascade as "Stable" —
`index.ex:283-295` ignores `payload.stable`. Fix: read it; render distinct states.

**CAS-4 (MED-HIGH) [FIX:R3-engine]** Sim servers are never reaped — one permanent GenServer
holding a full grid snapshot per browser visit. Fix: LiveView `terminate/2` stops its server
AND SimulationServer gets an idle timeout (e.g. 30 min without calls → stop).

**CAS-5 (MED) [FIX:R3-engine]** Server start failure / mid-cascade crash wedges the UI
(spinner forever; restart silently desyncs client). `index.ex:63-101,356-375`. Fix: check
`start_child` result; run trips under a supervised/monitored task that reports failures to
the LiveView; on server restart broadcast a reset event.

**CAS-6 (MED) [FIX:R3-engine]** `sim_id` from node-local `:erlang.unique_integer` collides
across cluster nodes on the cluster-wide PubSub. Fix: random/unique id (crypto hex).

**CAS-7 (MED) [FIX:R3-engine]** In "all" mode the session is pinned to the first-clicked
interconnection; later clicks in other interconnections are rejected forever. Fix: track the
server's scope; on mismatch stop and restart with the new scope.

**CAS-8 (MED) [FIX:R3-engine]** "Tripped" metric counts every event (incl. one per shed
load) — `total_events` semantics. Fix: count component trip events only.

**CAS-9/10 (LOW-MED) [FIX:R3-solver]** Dead `Engine.Cache` / `Engine.Interconnection` — see SOL-6.

**CAS-11 (LOW) [FIX:R3-cascade]** Library-level `trip_*` doesn't guard re-tripping an
already-tripped component (server guards it; direct callers exposed). Fix: no-op with log.

**CAS-12 (LOW) [DEFER]** `shed_ids` payload field is dead weight with an id-space hazard;
`overloaded_count` omits transformers. Remove/rename when payloads are next reshaped.

**CAS-13 (LOW) [FIX:R3-engine]** `handle_call(:reset)` runs a full base-case solve inline
(up to ~120 s block). Fix with UI-C2: async reset.

**CAS-14 (CONTEXT) [ACCEPTED]** Zone-3 relays are unreachable in the DC-only cascade path
(flat 1.0 voltages). Known limitation; lands with AC-in-cascade.

## ENE — Energy systems / frequency / demand

**ENE-1 (HIGH) [FIX:R3-engine + R3-freq]** Default (nil-hour) simulations run at ~85% of
nameplate ≈ 2× real demand — `maybe_scale_loads(_, _, nil)` passes the raw baseline through
(`grid.ex:370`), and the LiveView starts with `selected_hour: nil`. Fix guidance: R3-freq adds
`Demand.latest_demand_hour/0` (most recent hour with EIA-930 rows); R3-engine defaults the
LiveView/SimulationServer to it when the user hasn't picked an hour, falling back to the
baseline only when no demand data exists (with a loud log).

**ENE-2 (HIGH) [FIX:R3-freq]** Regional snapshots with zero BA-mapped loads get scaled to
NATIONAL demand (~10× for ERCOT) — `demand.ex:144-148,189-196`. Fix: apply the national
fallback only when the snapshot is national in scope (no interconnection filter) AND no load
carries a BA; otherwise leave baseline and `Logger.warning` with the MW involved.

**ENE-3 (HIGH) [FIX:R3-cascade]** Island deficits < ~1.17% of island load are silently
unserved (UFLS returns `[]`, no force-shed tier in `solve_islands_timed`; numeric probe
confirms), and deficits beyond the 30% schedule cap leak the same way. Also non-thermal trips
(`apply_trips` at cascade.ex:596) are not followed by redispatch, leaving unbalanced islands.
Fix guidance: give the island-deficit path the same residual force-shed round
`trigger_ufls_for_deficit` has; run `maybe_redispatch_after_trip` after non-thermal trips;
add a generation-side conservation test asserting `dispatched_gen_mw ≈ served_load_mw`
(balance/1 already exposes both).

**ENE-4 (HIGH) [FIX:R3-freq]** `h_sys < 0.01 → 0.5` floors the inertia CONSTANT, creating a
measured 34× discontinuity in 2HS from a 20 MW fleet change. Fix: floor the PRODUCT
(minimum kinetic-energy proxy, e.g. `2HS ≥ 1.0 * max(total_load, 1)`) and document.

**ENE-5 (HIGH) [FIX:R3-freq]** dt=0.1 is hard-coded while the proven stability bound
(`beta < 2 ⟺ dt < 4HS/(D·Pload)`, proofs/Proofs/Swing.lean) is never checked — measured
β=2.57 case produces a 55↔65 Hz square wave, nadir saturating at exactly 55.0. Fix: compute
β per simulation and shrink dt to keep β ≤ 1 (cap the extra steps); flag trajectories that
touch the clamp (`collapsed: true` metadata record) so callers can distinguish saturation.

**ENE-6 (MED) [FIX:R3-freq]** UFLS stages shed 7.5% of the ORIGINAL load and damping uses
pre-shed load — over-shedding to 62-65 Hz settling on small islands. Fix: shed fraction of
currently-connected load (`total - cumulative_shed`); damping on remaining load. Note the
linearization divergence in proofs/README (Swing.lean holds Pload constant).

**ENE-7 (MED) [FIX:R3-freq]** `Protection.estimate_frequency/2-3` (static fallback) bottoms
out at 57 Hz for total generation loss and cannot trigger meaningful UFLS. Fix: replace with
the damping-consistent steady-state estimate `f = f0·(1 − deficit/(D·load))` clamped to
[55, 65]; document as the struct-less fallback.

**ENE-8 (MED) [FIX:R3-freq]** Partial EIA-930 coverage silently mixes real demand with the
2× baseline; log line reports load COUNT not MW. Fix: log unmatched MW and BA codes.

**ENE-9 (MED) [FIX:R3-freq]** A zero/negative demand row zeroes an entire BA's loads.
Fix: fall back to baseline for that BA with a warning instead of scaling to 0.

**ENE-10 (LOW) [FIX:R3-cascade]** `apply_proportional_shedding` divides by zero on empty
loads (`load_shedding.ex:84`). Fix: guard, return `{loads, []}`.

**ENE-11 (LOW) [FIX:R3-freq]** Same as SOL-7 (duration guard).

**ENE-12 (LOW) [FIX:R3-cascade]** One shed event per load including zero-MW sheds on
already-blacked-out loads; tens of thousands of events at national scale. Fix: skip
`shed_mw == 0.0` events.

## PLT — Plants / generators

**PLT-1 (CRITICAL) [FIX:R3-plants]** NULL `capacity_factor` dispatches at 100% of nameplate —
measured ~170 GW (13% of fleet) after eGRID pass; those units also get full inertia with ZERO
governor headroom. Fix guidance: final ingest pass + migration backfilling NULL CFs with
fuel-typical defaults (NUC .93, coal .50, NG CC .55, NG CT .12, oil .10, hydro .40, wind .35,
solar .25, storage .10, geo .70, other .40 — constants documented in module); log the MW
backfilled per fuel; `|| 1.0` call sites stay but become unreachable for ingested data.

**PLT-2 (CRITICAL) [FIX:R3-plants]** eGRID reader is a hand-rolled `String.split(",")` that
breaks on commas in plant names — 1,191 rows / 42.7 GW misparsed (Gavin 2,600 MW among them),
reproduced on the real file. Fix: parse with NimbleCSV exactly like `ba_mapper.ex`'s
EGridPLNTParser; regression test with a quoted-comma fixture row.

**PLT-3 (HIGH) [FIX:R3-freq (constants) + documented here]** `normalize_fuel/1` doesn't
recognize stored EIA codes: SUB/LIG/RC/WC (~110 GW coal) → "gas" (governor 10× too fast),
MWH (27 GW storage) → gas inertia, DFO/RFO/GEO misbucketed. Fix: explicit EIA code table
before substring heuristics — SUB/LIG/RC/WC/BIT→coal, MWH→storage (H=0, no governor),
DFO/RFO→oil (steam-ish H=4, t_gov=5), GEO→geothermal (H=3.5, t_gov=5), NUC→nuclear, NG→gas,
WAT→hydro, WND→wind, SUN→solar; unknown→gas with a debug log. Tests with real codes.

**PLT-4 (HIGH) [FIX:R3-plants]** Form 923 computes each row's CF against WHOLE-plant capacity
then overwrites per plant nondeterministically under Flow (`form923.ex:33-59`); silent no-op
if the header lookup misses. Fix: aggregate rows per plant first (sum net gen), one CF per
plant = Σnet_gen/(plant_cap·8760), single write, clamp [0,1], loud warning when the header
is not found; filter status in both numerator context and write.

**PLT-5 (HIGH) [FIX:R3-plants]** Generators have no natural key — re-ingest doubles the fleet
(no unique index anywhere; `on_conflict: :nothing` without target is a no-op). Fix: add
`generator_id` column (EIA Generator ID, col 6), capture it in form860, migration dedupes
existing rows then adds `unique_index(:generators, [:eia_plant_id, :generator_id])` (partial,
where both non-null), insert with proper conflict_target.

**PLT-6 (MED) [FIX:R3-plants]** Status `OA` (203 units / 7.2 GW — out of service but expected
to return) hits the unknown-code path. Fix: explicit `OA → "standby"` with doc comment.

**PLT-7 (MED) [FIX:R3-data]** `Cleanup.remap_generators/0` relocates up to 100 km with no
interconnection check — plants can cross asynchronous seams. Fix: restrict candidate buses to
the generator's interconnection (when known) in the remap query.

**PLT-8 (MED) [FIX:R3-plants]** Missing EIA-860 Plant file silently yields a coordinate-less
(and therefore invisible) fleet. Fix: hard error listing the expected file; document the
xlsx→csv expectation and the title-row requirement in the moduledoc.

**PLT-9 (MED) [FIX:R3-plants]** eGRID CFACT admits values up to 3.44 into the weighted sum and
floors true-zero plants at 0.01. Fix: clamp each unit CFACT to [0,1] BEFORE weighting;
all-nonpositive plants store 0.0 (not NULL, not 0.01).

**PLT-10 (MED) [FIX:R3-data]** Quebec HVDC double-count: "Châteauguay–Sandy Pond" is the same
physical Phase II link as entry 1, and its US terminal is placed in upstate NY instead of
Ayer MA. Fix: remove the duplicate entry; correct remaining coordinates (Sandy Pond ≈
(-71.58, 42.56) if kept as the Phase II terminal); leave a comment citing real ratings.

**PLT-11 (LOW) [FIX:R3-data]** `full_pipeline` skips generators/egrid/map_bas/population/
demand/datacenters/water/cleanup → degenerate 1 MW/bus grid reported as success. Fix: run the
full documented order; print per-stage results.

**PLT-12 (LOW) [DEFER]** FC/FW/DC prime movers get synchronous Q-limits; EIA nameplate power
factor column unread. **PLT-13 (LOW) [DEFER]** International ties fixed at CF 0.5, never
export/reverse.

## LIN — Lines / transformers / HIFLD

**LIN-1 (CRITICAL) [FIX:R3-lines]** Substation identity = raw HIFLD name: 3,272 names span
> 5 km; MIDWAY merges 88 endpoints over 4,258 km; sentinel "NOT AVAILABLE" fuses 2,138
endpoints; 45.9% of endpoints end up beyond snap range of their own substation (live-data
verified). Fix guidance: substation identity becomes name + geographic cluster — group
same-name endpoints with a ~5 km clustering pass (e.g. union-find over endpoints within 5 km,
id = `NAME@lat,lon` of cluster centroid rounded to 2 decimals); sentinel names
("NOT AVAILABLE", "NONE", "DEADHEAD", existing UNKNOWN*/TAP*) get per-endpoint identities
(coordinate-derived id) instead of merging. Update `hifld_id` generation + upsert; document
that re-ingest on an existing DB will create the corrected substations alongside old rows
(cleanup pass out of scope).

**LIN-2 (HIGH) [FIX:R3-lines]** "NOT AVAILABLE" status → out_of_service discards 20.9% of the
network while only 65 records are genuinely inactive; nil already maps to in_service. Fix:
unknown/"NOT AVAILABLE" → in_service; only explicit INACTIVE/RETIRED/UNDER CONSTRUCTION/
PROPOSED/DECOMMISSIONED → out. Mirror in substations.ex. Tests.

**LIN-3 (HIGH) [FIX:R3-data]** Transformer x_pu fixed at 0.1 on the SYSTEM base while rated
100–1000 MVA — 2–10× too impedant on own base; at nameplate a bank sits at the steady-state
stability limit. Fix: `x_pu = 0.10 * (100.0 / rated_mva)`, `r_pu = 0.003 * (100.0/rated_mva)`
at creation (bus_mapper), plus a data migration rebasing existing rows from their rated_mva.

**LIN-4 (HIGH) [FIX:R3-data]** Transformers duplicate on every `map_buses` re-run (no unique
constraint; found independently by two reviewers). Fix: dedupe-then-unique-index migration on
(from_bus_id, to_bus_id), insert with conflict_target.

**LIN-5 (HIGH) [DEFER]** Only max/min voltage levels get buses — 5,218 endpoints land on
levels with no bus; KEYSTONE gets a fictitious 500/115 transformer. Needs substation schema
rework (store full voltage list). Documented; revisit with LIN-7.

**LIN-6 (MED) [FIX:R3-lines + R3-data]** HVDC lines ingested as AC — the Pacific DC Intertie
becomes a 1000 kV AC line absorbing Western N-S flow. Fix: R3-lines sets `line_type: "dc"`
from VOLT_CLASS; R3-data excludes `line_type == "dc"` from all AC snapshot queries (grid.ex)
with a comment pointing at future injection modeling.

**LIN-7 (MED) [DEFER]** z_base uses the line's own kV, not the terminal bus base — up to 32%
x_pu error when snap windows cross voltage classes; also permits lines joining buses of
different base kV. Needs estimation-after-mapping redesign.

**LIN-8 (MED) [DEFER]** No GSU transformers; Cleanup's synthetic tie welds 13.8 kV to 500 kV
with near-zero impedance. Design work with LIN-5/7.

**LIN-9 (LOW-MED) [FIX:R3-lines]** Multi-part ArcGIS geometries flattened into phantom bridge
segments (64 bridges, worst 203 km, feeding x_pu); the correct nested parser is unreachable
dead code; a future returnZ would scramble coordinates. Fix: parse paths per-part (use the
existing nested parser), sum lengths per part; drop Z coords explicitly; tests.

**LIN-10 (LOW) [FIX:R3-lines + R3-data]** Near-duplicate voltage levels (115/120) become two
zero-distance buses with nondeterministic line assignment; `round(kv)` in bus source_id
collides 138.0/138.4. Fix: R3-lines clusters levels within 5% in substations.ex; R3-data uses
one-decimal kv in bus source_id.

**LIN-11 (LOW) [FIX:R3-lines]** `estimate_length/1` crashes on 3-tuple (Z) coordinates that
sibling modules handle. Fix: accept `{lon, lat, _}`.

## DAT — Data pipeline / grid queries / export

**DAT-1 (HIGH) [FIX:R3-data]** = LIN-4 (transformer duplication).

**DAT-2 (HIGH) [FIX:R3-data]** Export and solver snapshot are different sets both ways:
unmapped-endpoint lines exported (clickable but unsimulatable → `:not_in_network`), synthetic
ties simulated but exported with zero geometry (invisible trips). Fix: export filters mirror
snapshot predicates (mapped endpoints, self-loop, dc exclusion); synthetic/no-geometry lines
export a 2-point geometry from their endpoint bus coordinates.

**DAT-3 (HIGH) [FIX:R3-data]** `cleanup_orphaned_buses` misses loads/water/datacenter refs →
FK crash mid-task; `water_facilities.bus_id` has no FK at all → dangling ids crash later load
rebuilds. Fix: extend the orphan query to all referencing tables; migration adds the water FK
(`on_delete: :nilify_all`) after nulling dangling ids.

**DAT-4 (MED-HIGH) [FIX:R3-data]** BA topology fill uses `max(ba_id)` — insert-order-dependent
interconnection assignment that silently deletes straddling branches. Fix: majority vote among
neighbors with a deterministic tiebreak (smallest BA code string), documented.

**DAT-5 (MED-HIGH) [DEFER]** BA fills are sticky across re-runs (only plant-vote rewrites).
Needs a re-vote strategy; document in ba_mapper moduledoc (R3-data adds the doc note only).

**DAT-6 (MED-HIGH) [FIX:R3-data]** County-population upserts never delete stale FIPS — mixed
vintages double-count (CT counties vs planning regions). Fix: after upsert, delete rows whose
fips was not in the ingested file (log count). Same for datacenters: deactivate campuses
absent from `@campuses`.

**DAT-7 (MED) [FIX:R3-data]** `generate_demo_data` overwrites real exports and the boot guard
can't tell; a pre-ingest export writes a permanent empty file. Fix: demo task writes to
`grid_data_demo/` (or requires `--force` to touch real paths); `ensure_exported` also
regenerates when the export is empty (0 records).

**DAT-8 (MED) [FIX:R3-data]** Water ingest `on_conflict: :nothing` can never correct curated
values. Fix: `{:replace, [...]}` like datacenters.

**DAT-9 (MED) [DEFER]** Substation voltage change orphans the old bus and creates phantom
transformer chains. Needs LIN-5's schema work.

**DAT-10 (MED) [FIX:R3-data]** Nearest-neighbor BA pass writes NULL and reports success when
no donor exists. Fix: skip the write when the subquery is NULL; report actual assigned count.

**DAT-11 (LOW) [FIX:R3-data]** `get_regional_grid_snapshot` diverges (no interconnection
guard, no coordinate check on extra buses, no hour scaling, missing :datacenters key). Fix:
align predicates with the full snapshot and add the missing key.

**DAT-12 (LOW) [FIX:R3-data]** `export_substations` emits Null Island for nil coordinates.
Fix: filter like the other exporters.

**DAT-13 (LOW) [FIX:R3-data]** `interconnection_stats` totals ignore snapshot filters. Fix:
apply coordinate/status/self-loop filters so headline GW match what is simulated.

**DAT-14 (LOW) [DEFER]** N+1 spatial queries in mapping passes (correct shape exists in
population_per_bus). **DAT-15 (LOW) [DEFER]** Form-930 partial-file ingestion
indistinguishable from complete (needs per-BA hours histogram). **DAT-16 (LOW) [FIX:R3-data]**
= PLT-11 (full_pipeline).
Micro [DEFER]: num_points u16 clamp in grid_export.

## UI — LiveView / map / JS

**UI-C1 (CRIT) [FIX:R3-engine + R3-uijs]** Client never told the cascade ended — map stuck in
cascade mode (ghosting, vignette, forced layers) until Reset. Fix contract: server pushes
`push_event(socket, "cascade_done", %{stable: boolean})`; JS handles it, clears
`cascadeActive`, keeps final classification.

**UI-C2 (CRIT) [FIX:R3-engine]** Reset blocks the LiveView up to 120 s (and `:noproc` kills
it). Fix: async reset via monitored task; `solver_status: :resetting` meanwhile; catch exits.

**UI-C3 (CRIT) [FIX:R3-engine]** Failed server start leaves "Solving…" forever with all
recovery controls hidden. Fix: surface start/trip failures to the LiveView (monitored task,
start_child result), reset `cascade_active`, show an error state.

**UI-H1 (HIGH) [FIX:R3-engine]** Unvalidated `?interconnection=` and component ids crash the
LiveView (`String.to_integer` on raw params at index.ex:65,137,365). Fix: parse-validate all
of them (reuse `parse_int`), ignore invalid.

**UI-H2 (HIGH) [FIX:R3-engine + R3-uijs]** "Loading %" view has never worked (reads unset
`loadingPct`; all lines green). Fix contract: `dc_update` payload gains
`"line_loading": %{line_id => pct}` for lines with loading ≥ 30% (server already computes
these); JS stores it in DataStore and the transmission layer colors from it, defaulting
< 30% for absent ids.

**UI-H3 (HIGH) [FIX:R3-uijs + R3-engine]** Timeline scrubbing indexes history by server step
number — wrong prefix after the first cascade; scrubbing to the last step disagrees with the
settled view. JS half DONE (replay by array position + final classification frame). Engine
half REQUIRED or the JS is inert: `cascade_timeline.ex:14` must emit the 0-based
`Enum.with_index` idx, not `step.step` (addendum item c). See also UI-M14.

**UI-H4 (HIGH) [FIX:R3-uijs]** Every `_updateLayers()` rebuilds and re-uploads entire
datasets (fresh arrays defeat memoization). Fix: memoize getData arrays; bump `stateVersion`
on mutation; substations layer gets stateVersion (fixes UI-M12's inert trigger).

**UI-H5 (HIGH) [FIX:R3-uijs]** 17.7 MB water JSON fetched on every load for a default-off
layer; TextLayer over 94,934 facilities at zoom ≥ 10. Fix: lazy-fetch on first toggle;
viewport-cull the label layer (render labels only within current bounds, cap count).

**UI-H6 (HIGH) [DEFER]** Cumulative payload fields resent per step, unbounded retention both
sides; unread fields shipped. Payload reshape deferred (keep CAS-12 note in mind).

**UI-M1 (MED) [DEFER]** Affected list rebuilt per render, shows oldest 50.
**UI-M2 (MED) [FIX:R3-engine]** Frequency metric permanently 60.00 — wire the min
`frequency_nadir` from shed events into system metrics during a cascade.
**UI-M3 (MED) [FIX:R3-engine]** Tripped count 0 until cascade_done — update per step.
**UI-M4 (MED) [DEFER]** Load-shed/islanded map states never painted (needs bus-level data).
**UI-M5 (MED) [FIX:R3-engine]** Touching the date field destroys a running simulation via
`hour: ""`. Fix: ignore incomplete selections (keep current hour until both fields valid).
**UI-M6 (MED) [FIX:R3-engine]** = CAS-7. **UI-M7 (MED) [FIX:R3-uijs]** Zoom LOD waits on a
server round trip — compute visibility thresholds client-side (still inform server), using
or deleting the dormant viewport_tracker. **UI-M8 (MED) [FIX:R3-uijs]** Clear
`window.__gridMapManager` in hook destroy. **UI-M9 (MED) [DEFER]** Unbounded
`hidden_legend_items` map from client strings. **UI-M10 (MED) [DEFER]** Synchronous
full-table aggregates per date change. **UI-M11 (MED) [FIX:R3-engine]** N-1 screening task
death leaves "Scanning…" forever — monitor it, timeout to an error state.
**UI-M12 (MED) [FIX:R3-uijs]** = H4. **UI-M13 (MED) [FIX:R3-engine]** Add catch-all
`handle_event` clause (log + noreply).
**UI-M14 (MED) [FIX:R3-engine]** `handle_info({:simulation_reset, _}, ...)`
(`index.ex:297-306`) clears `@cascade_steps` server-side but pushes nothing — the lone
asymmetric reset path. Harmless under step-number replay; under the new position-based
replay it permanently desyncs server and client frame lists. Fix: add
`push_event("reset_grid", %{})` to that clause (addendum item c).

**UI-L1 (LOW) [FIX:R3-uijs]** maplibre CSS from unpkg CDN in root layout — import from the
npm package into app.css instead. **UI-L2 (LOW) [FIX:R3-uijs]** No basemap error path (blank
page) — add `map.on("error")` + user-visible message. **UI-L3 (LOW) [FIX:R3-uijs + R3-engine]** Delete
dead CascadeTimelineHook. JS half DONE; engine half REQUIRED: remove
`phx-hook="CascadeTimeline"` from `cascade_timeline.ex:6`, keep the DOM id (addendum item a). **UI-L4 (LOW) [DEFER]** Dead components with Float.round crashes
(grid_components, dashboard_components, cluster_layer, viewport_tracker — delete or fix when
touched). **UI-L5 (LOW) [FIX:R3-engine]** Info-panel state names stop at 3 — add
rerouted/shed/islanded. **UI-L6 (LOW) [FIX:R3-engine]** fuel_type_name covers codes ≤ 7 —
add DFO/RFO/wood/geothermal/import. **UI-L7 (LOW) [FIX:R3-engine + R3-uijs]** Legend/color
class mismatches (115/161 kV, water pipeline, crypto) — align keys and rows. **UI-L8 (LOW)
[DEFER]** Accessibility pass. **UI-L9 (LOW) [DEFER]** Missing DOM ids (add as touched;
R3-engine adds ids to elements it modifies). **UI-L10 (LOW) [DEFER]** No LiveView tests —
R3-engine must add tests for what it changes. **UI-L11 (LOW) [DEFER]** daisyUI in scaffold
chrome. **UI-L12 (LOW) [FIX:R3-data]** Export name nil-guard for TextLayer.
**UI-M15 (MED) [DEFER→roadmap]** The N-1 screening result shown in the UI is a stub:
`index.ex` (~:399-407 pre-R3) returns `length(tripped_lines) + length(tripped_generators)`
— the count of components the user already tripped, presented as a violations count with no
relationship to what it claims to measure. Found by the solver accuracy exploration
(2026-08-15). Make it real via sparse PTDF/LODF screening (ROADMAP solver item 6) or remove
the number until it is.
**UI-L13 (LOW) [DEFER]** Three of four failure-logging paths untested (`map_manager.js:83`,
`grid_map_hook.js:10`, `grid_map_hook.js:31`); the hook pair encodes the "map fails, UI
still works" promise and nothing proves the hook survives either failure. Evidence the path
has unexercised semantics: the blackhole-Proxy fallback (`grid_map_hook.js:14-23`) returns
itself for every property, making it THENABLE — so `Promise.resolve(...)` at :30 receives a
thenable whose `then` never settles, and the `.catch` at :31 can never fire (benign today:
:10 already logged and the map is already dead). Needs a DOM/LiveView-hook harness beyond
the plain-Node runner added in R3. Identified at R3-uijs sign-off.

---

## Findings from the 2026-08-15 accuracy exploration (post-R3, measured)

**ENE-13 (MED-HIGH, promotes DAT-15) [OPEN]** `Demand.latest_demand_hour/0` returns the
file's boundary hour, where only 17 of 53 BAs report — so the ENE-1 default-hour fix is
partially defeated: two-thirds of load silently falls back to the ~2× baseline in the
default run. Fix: skip hours whose reporting-BA count is below modal−1 (ROADMAP item 3).
**DAT-17 (MED) [OPEN]** Dev-DB schema drift: `rating_b_mva`/`rating_c_mva` columns exist
in the live DB with no migration or schema behind them; fresh `mix ecto.setup` diverges.
Close via ROADMAP item 9.
**DAT-18 (HIGH) [OPEN→roadmap]** Parameter estimators are fill-NULL-only, so stored rows
written by older code versions are permanently uncorrectable — measured: EHV impedances
and ratings exactly 2× off the current table (a 500 kV line rated equal to a 345 kV).
ROADMAP item 8.
**CAS-15 (LOW-MED) [OPEN]** `island_dead?/2` still declares single-bus islands dead,
contradicting SOL-3's `min_buses = 1` fix; `cascade_test.exs` pins the old behavior.
**CAS-16 (MED) [OPEN→roadmap]** `simulated_time` advances 0 s on steps whose only trips
are non-thermal — any future ramp/AGC modeling is unlimited until fixed (ROADMAP item 16).
**ENE-14 (LOW) [OPEN]** `Frequency.normalize_fuel` has no case for OIL or biomass/waste
codes (~15 GW geolocated falls to gas dynamics); the 268 GW `COL` case is entirely on
coordinate-less MATPOWER buses and never simulated — worth a comment in the fuel table.
**DAT-19 (DECISION) [RESOLVED 2026-08-15]** Ingestion pulls HIFLD from an unofficial,
unlicensed, unversioned ArcGIS mirror; HIFLD Open was shut down by DHS 2025-08-26.
Snapshots pinned with checksums — see data/vendored/PROVENANCE.md; source switch is
ROADMAP Phase 2.
**SOL-12 (MED) [OPEN]** `YBus.effective_reactance/1` floors |x| at 1.0e-3 pu — far
coarser than the divide-by-zero guard requires. Three real ACTIVSg2000 branches
(true x 7.0e-4–8.8e-4) are inflated 14–43%, confirmed as the sole source of the case's
DC deviation. Lower the floor (e.g. 1e-5) with the sign-preserving semantics intact.
**SOL-13 (HIGH, scale-blocking) [OPEN→Phase 4]** Q-limit outer-loop switching does not
scale: on ACTIVSg2000, 32 of 195 buses that should switch to PQ never do (1 spurious) —
e.g. bus 1070 genuinely exceeds q_max but lands above setpoint once 175 others clamp,
satisfies the back-switch condition, returns to PV, and oscillates until
@max_qlim_rounds ends it. Worst bus voltage 2.86% off (5.7× contract) at converged
mismatch 3.1e-10. Faster linear algebra will NOT fix this — the switching mechanism
needs work (e.g. no back-switching for genuinely-violating buses within a round, or
simultaneous-violation resolution). Guarded bus-for-bus at IEEE-118 scale where it
works; the skipped ACTIVSg2000 AC tests are the acceptance gate. Found by the Phase 0
validation ladder, 2026-08-15.
**DAT-21 (DATA QUALITY, MED) [OPEN→Phase 5]** 13,520 substations (17%) in the native
layer report no voltage and receive the default 138 kV bus; 70% of connectivity-repair
joints connect two such yards (mean 0.78 km apart — the joins are right, the level and
250 MVA tie rating are placeholders). OSM substation polygons (ROADMAP item 24, 67%
voltage-tagged) are the enrichment path.
**ENE-17 (FIXED 2026-08-15)** Regional snapshots inflate straddling BAs: `Demand.scale_loads/3`
lands a BA's ENTIRE demand on whatever slice of its buses the snapshot contains. Nine BAs
straddle interconnection boundaries — MISO's 69 GW lands on stray ERCOT-labelled buses at
17.2×, AECI 191×, TEPC 28.8× — so hour-scaled ERCOT simulations carry ~151 GW against a
real ~45 GW. Regional and national runs are not comparable until per-interconnection
scaling restricts a BA's demand to its in-snapshot share. Found by the replay harness
2026-08-15 (`outsized scaling` flag: 16 BAs / 40.35 GW nationally).
**ENE-18 (DATA CAVEAT) [DOCUMENTED]** EIA-930's own generation identity (NG − TI = D)
never closes for BPAT (0/4,417 hours), MISO (5/4,389), CISO (611/2,473) — those BAs are
essentially unvalidatable against their own published totals. The harness's screened-hours
logic excludes them from balance gates; expect their metrics to carry wider error bars.
**LIN-12 (DATA DEFECT, LOW) [OPEN]** Western carries a 765 kV+ voltage class (1 line,
3 transformers), all 100% overloaded at rest — WECC has no 765 kV; bad voltage data.
Found by `mix grid.accuracy` 2026-08-15.
**ENE-15 (MEASURED GAP) [OPEN→Phase 2]** With fuel-anchored dispatch live (2026-08-15),
23.3 GW of measured nuclear cannot be placed on geolocated units: the BA-mapped fleet
holds 84.2 GW of nuclear capability vs 97.4 GW measured (101 GW of nuclear nameplate is
on coordinate-less MATPOWER buses; SRP 4.0 GW measured vs 1.4 mapped is BA attribution).
Concentrated: PJM 33.6 vs 26.4, MISO 11.1 vs 8.0, SOCO 8.1 vs 4.1. The dispatch coverage
report now tracks this per BA — it is the scoreboard for ROADMAP Phase 2
connectivity/plant-mapping work.
**ENE-16 (BUG, FIXED 2026-08-15)** Form 930's single-column field resolver made
`total_interchange_mw` NULL for the entire table (EIA blanks Imputed columns on rows
needing no imputation) and silently served RAW demand instead of Adjusted. Fixed with
tiered Adjusted→Imputed→raw resolution per row; older ingests must re-run (dev DB
re-ingested).
**DAT-20 (SYSTEMIC, MED) [OPEN]** OTP logger overload protection silently drops ~90% of
large per-row warning bursts (measured 2026-08-15: 1,079 Logger.warning calls through
Flow → only ~103-114 lines reach output, no drop notice). Any ingest path that reports
data anomalies per row under-counts them invisibly. Pattern fix (implemented in
form860.ex seasonal warnings): tally via :counters and emit one authoritative summary
line after the Flow, keeping per-row detail as best-effort. Apply to other per-row
warning sites as they are touched.

## Cross-package contracts (all agents read this)

1. `Demand.latest_demand_hour/0` (NEW, R3-freq): returns the most recent `DateTime` hour
   having BA demand rows, or nil. R3-engine uses it as the default simulation hour.
2. `push_event "cascade_done"` (NEW, R3-engine → client): `%{stable: boolean}`. R3-uijs
   handles it: clears cascade mode, retains final classification.
3. `dc_update` payload gains optional `"line_loading"`: map of line id → loading pct for
   lines ≥ 30% loaded (R3-engine sends; R3-uijs consumes; absent = < 30%).
4. Cascade step numbering (R3-cascade): `step`, `simulated_time`, `relay_duty` reset at each
   manual trip entry. UI scrubbing (R3-uijs) indexes by ARRAY POSITION, never step number.
5. `line_type == "dc"` (R3-lines writes it) is excluded from AC snapshots (R3-data filters).
6. `Solution` gains `dead_load_mw` / `dead_bus_count` (R3-solver); R3-engine's audit compares
   served + dead against snapshot demand.

### R3-engine addendum — exact server-side edit sites (client half already landed)

The R3-uijs package is complete; its reviewer verified the tree and pinned the server
edits R3-engine must make (all within R3-engine's owned files):

a. `grid_live/cascade_timeline.ex:6` — remove `phx-hook="CascadeTimeline"` (the JS hook was
   deleted); KEEP `id="cascade-timeline"`. Client logs "unknown hook" every cascade until done.
b. Contract #2 lands in `index.ex:283-295` (`:simulation_cascade_done` handler):
   `push_event("cascade_done", %{stable: payload.stable})` — payload.stable is populated on
   both broadcast branches. Client handler already exists (`grid_map_hook.js:49`).
c. Contract #4: `cascade_timeline.ex:14-22` must emit `phx-value-step={idx}` (the 0-based
   `Enum.with_index` position), NOT `step.step`; `scrub_timeline` passes it through.
   ALSO: the `handle_info({:simulation_reset, _}, ...)` clause (`index.ex:297-306`) clears
   `cascade_steps` but pushes nothing — add `push_event("reset_grid", %{})` there, or server
   and client frame lists desync and every scrub targets the wrong position.
d. Contract #3 trap: build `line_loading` from `solution.line_flows` by unwrapping ONLY
   `{:line, id}` keys — EXCLUDE `{:transformer, id}` (independently colliding id spaces).
   Client side is defensive (absent field = no-op, missing id = lowest band).
e. Legend rows (UI-L7 server half): add `115` and `161` to `@voltage_legend`
   (`index.ex:756-763`), a `pipeline` water row (`index.html.heex:254-366`), and `crypto` to
   `@datacenter_legend` (`index.ex:777-782`) — the client now derives all eight voltage
   classes plus those two types, and unmatched classes become untoggleable.
f. Already done client-side, no server action: water lazy-load (UI-H5), LOD client-side
   (UI-M7), memoization + stateVersion (UI-H4/M12), CDN CSS removal (UI-L1).

## Verification status

**Round 3 LANDED — 2026-08-15.** All eight packages implemented and adversarially verified
(uijs and engine each required one remediation round; the other six passed first
verification). Every finding tagged `[FIX:R3-*]` above is fixed with regression tests
that fail under the pre-fix behavior. Integration: full `mix test` 404 tests / 0 failures
(up from 221 pre-round), `mix precommit` clean, JS suite (new in this round) 30/30.
`[DEFER]` and `[ACCEPTED]` items remain open as tagged; re-ingest is required for the
LIN-1/LIN-2/LIN-10 substation-identity and status changes to take effect on an existing DB.
