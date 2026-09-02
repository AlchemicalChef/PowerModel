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

**UI-M17 (LOW) [OPEN]** Island splits are counted but never LISTED: thermal mw_at_risk
dominates the ranking, so 0 of the top-10 entries are :island_split on any interconnection
(41% of ERCOT branches are bridges). If splits are to be actionable they need their own
ranked row. Found at UI-3 integration, 2026-08-16.
**UI-L14 (LOW) [OPEN]** Flow-classification id lists (rerouted/overloaded/stressed) are
re-sent in full on every cascade step — 60% (134 KB) of a 50-step cascade's client
payload. Delta-encoding them changes the map repaint/scrub contract and is deliberately
NOT bought yet; the UIW-4 gate is restated as measured: per-frame < 100 KB (met at 34.2 KB
worst, 65× under the original 2.2 MB defect) plus per-step-linear total (~4.4 KB/step
measured). Post-DR-1, budget-exhausted 50-step cascades are the NORMAL case on physically
rated anchors, not the exception. Found at UI-2 re-basing, 2026-08-16.

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
**UI-M15 (FIXED 2026-08-16)** Real N-1 is live: ContingencyScreening via the engine's
screening_snapshot, per-scope budgets, largest-island disclosure for multi-island scopes
(the default "all" is THREE islands and LODF refuses them — the naive wiring would have
failed every fresh session's first click). First real numbers post-DR-1: Eastern worst
mw_at_risk 582,431.6 → 10,819.8 MW (54×; top entry a 345/138 step-down transformer at
1072%), sweep 65.7 s. ORIGINAL: The N-1 screening result shown in the UI was a stub:
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
**CAS-15 (FIXED 2026-08-15)** `island_dead?/2` still declares single-bus islands dead,
contradicting SOL-3's `min_buses = 1` fix; `cascade_test.exs` pins the old behavior.
**CAS-16 (FIXED 2026-08-15)** `simulated_time` advances 0 s on steps whose only trips
are non-thermal — any future ramp/AGC modeling is unlimited until fixed (ROADMAP item 16).
**ENE-14 (LOW) [OPEN]** `Frequency.normalize_fuel` has no case for OIL or biomass/waste
codes (~15 GW geolocated falls to gas dynamics); the 268 GW `COL` case is entirely on
coordinate-less MATPOWER buses and never simulated — worth a comment in the fuel table.
**DAT-19 (DECISION) [RESOLVED 2026-08-15]** Ingestion pulls HIFLD from an unofficial,
unlicensed, unversioned ArcGIS mirror; HIFLD Open was shut down by DHS 2025-08-26.
Snapshots pinned with checksums — see data/vendored/PROVENANCE.md; source switch is
ROADMAP Phase 2.
**LIN-13 (MEASURED, HIGH → Phase 2 gate) [OPEN]** No AC solution EXISTS at real demand
on any interconnection — the network data, not the solver, is now the blocker. A lossless
branch carries at most V·V/x; wherever DC needs >90° across a branch, AC is infeasible.
Census at hour-scaled demand (2026-08-15): ERCOT 1 branch >90° + 58 radial buses >50 MW
(worst 721 MW on one spur), converges only ≤25% of demand with a textbook nose curve;
Western 3 branches (max 193°), fails from BOTH sides (voltage collapse above ~13% load,
Ferranti >1.1 pu on 5,337 buses below — 44 GVAr of line charging doesn't scale with
load), and at α=0.12 exactly TWO buses at the floor sit behind one placeholder
x=1.148 pu radial branch; Eastern 15 branches (max 243°), converges ≤15%. Fix is Phase 2
items 8/10/12 + DAT-21 (impedance recompute, EHV classes, connectivity repair) — more
solver is not. Until then the voltage chain (UVLS, distance relays, IBR LVRT) is inert
at real demand: CAS-1's honest-degradation rule correctly keeps DC. Found by FDPF
convergence probing, 2026-08-15. PRACTICAL CORRECTION (Wave 3b, 2026-08-16): in a settled
real-demand ERCOT cascade, 93 of 170 island-solves DID carry a voltage layer — the ~5,400-bus
main island diverges every time, but every fragment that breaks off converges. LIN-13 is
true of the whole island and false of the pieces; the voltage chain is live mid-cascade
today, and the Phase 2 data repair raises coverage rather than enabling it.
FURTHER CORRECTION (DR-2, 2026-08-16): synthesized EHV line-end reactors (−65.1 GVAr,
48% of Western's charging) take Western from NO AC solution at any load level to
α ≤ 0.105 with overvoltage fully solved (5,151 → 18 buses >1.1 pu at α=0.08). The
ceiling is pinned by LOW voltage in the 115 kV Pacific-Northwest corridor at every
reactor constant swept — a topology gate for DR-4's remap, not reactive supply.
WAVE-END (DR-1..DR-5, 2026-08-16): the >90° census is 0/1/0 balanced AND as-dispatched
(from 15/1/3) — Eastern and Western CLEAN; the ERCOT survivor (72357, 95.3°, 522 MW of
wind on a 69 kV radial) is a HIFLD source gap: exactly one circuit within 3 km of its
yard, an OSM-wave item. Western FDPF α ceiling 0.10 → 0.22, ERCOT 0.25 → 0.50. The
mechanism stack: dispatch balance (DR-1) + reactance floor/reactors (DR-2) + 8,814
restored circuits (DR-3) + plant-level voltage-aware placement/welds (DR-4) +
capability-weighted load spread (DR-5). Full-demand AC remains open (α=1.0 needs the
OSM voltage backfill and the remaining ~100 GW of placement residuals) but the voltage
chain's mid-cascade coverage and the reduced-demand envelope are now measured, not
blocked.
**SOL-12 (FIXED 2026-08-16)** Floor lowered 1.0e-3 → 1.0e-5 with the estimator write
clamp aligned (whichever clamp is larger silently binds). x1000 invariance probe now
bit-identical (Eastern sum|Δflow| 27,761 → 0.0 MW); the ACTIVSg2000 DC deviation was the
floor alone — worst 8.7e-9 rad, the reference's own print quantization. 18 overload-flag
flips at ≤230 kV, re-baselined. ORIGINAL: `YBus.effective_reactance/1` floors |x| at 1.0e-3 pu — far
coarser than the divide-by-zero guard requires. Three real ACTIVSg2000 branches
(true x 7.0e-4–8.8e-4) are inflated 14–43%, confirmed as the sole source of the case's
DC deviation. Lower the floor (e.g. 1e-5) with the sign-preserving semantics intact.
**SOL-13 (FIXED 2026-08-15)** The original diagnosis was wrong in one respect: traced
on ACTIVSg2000, the outer loop does NOT oscillate to the round cap — it reaches a fixed
point in 5 rounds where no bus wants to change type, and bus 1070's required Q
legitimately falls inside its limit once the other 175 buses settle. The 2.86% voltage
gap was a POLICY difference, not a bug: the pandapower/MATPOWER reference never
back-switches, and its fixed point violates complementarity at 48 of its 195 pinned
buses (30 at q_max with V above setpoint). Our default (`:complementary`) satisfies
complementarity at all 392 generator buses; a latch (a re-violating bus stays pinned,
≤3 type changes per bus) makes termination a guarantee. A `:q_limit_policy: :matpower`
option reproduces the reference's rule — 191/195 buses agree, losses 0.0151% — and the
un-skipped ACTIVSg2000 AC tests run under it as the "same rule ⇒ same answer" gate,
while fdpf_test.exs asserts the complementarity property the reference itself fails.
Closed for both NR and FDPF paths (the rule is shared). Fixed by p4-fdpf with item 19.
**ENE-19 (FIXED 2026-08-15)** Fuel-anchored dispatch carries no
contingency-reserve requirement: ERCOT's operating point leaves ~1.27 GW of
governor-duty headroom against its 1,375 MW design contingency, so the island sheds
customers for its own largest credible single loss (nadir 59.282, 3,357 MW shed at the
modal hour). The old nameplate-droop model masked this by accident. Fix belongs in the
Phase 3 reserve tiers (item 16): hold spinning reserve ≥ the BA/interconnection design
contingency at dispatch time. Found by the β acceptance work, 2026-08-15.
**CAS-18 (VOLUME, LOW) [OPEN]** Large cascades now emit ~16.7k ufls_shed events on the
ERCOT reference case (was 948) — per-load event granularity at collapse scale. Needs a
DAT-20-style aggregation decision when payloads are next reshaped (UI-H6 territory).
**DAT-22 (MED-HIGH) [OPEN]** `Grid.map_datacenters_to_grid/0` carries TOPO-2's defect:
55 rows / 19.7 GW placed at the nearest bus with NO voltage or capability check — 11 on
degree≤1 buses (3,800 MW), 3 below 60 kV (400 MW on a 13.8 kV bus). After DR-5 these
rows are the ENTIRE residual of the load-placement census (flat_mw/flat_only sections
attribute them). Reuse LoadEstimator.capability/1. Water-facility placement shares the
gap at smaller scale. Found at DR-5, 2026-08-16.
**DAT-23 (MED) [OPEN]** Pipeline ordering: `estimate_loads` runs BEFORE
`repair_connectivity` in full_pipeline (ingest.ex ~:422 vs :432), so on a fresh ingest
the capability cap sees the network without 10,000+ repair branches. One-line move.
Also: 3,114 buses (2,701 restoration + 413 synthetic) carry no balancing authority —
DR-5's known-BA guard excludes them from load, but BA assignment should re-run at
ingest end; unguarded they absorbed 34 GW the scaler can never rescale and manufactured
a new >90° branch. A "(none)" row in a per-BA load sum is the tell. Found at DR-5.
**DAT-24 (MED) [OPEN]** `EIA.Form861.bus_shares/0` still carries a copy of the OLD
KNN-25 allocation rule; its docstring claims BTM capacity "lands exactly where the load
it offsets landed," which is no longer true after DR-5's spread. Align it with
LoadEstimator or the BTM layer's bus placement drifts from the load it offsets. Found
at DR-5, 2026-08-16.
**CAS-19 (LOW) [OPEN]** Two Wave 3b bookkeeping refinements, deliberately not made
mid-wave: (a) `Protection.gfl_derate/3` takes one fleet-wide p_set_pu, treating every
inverter as fully loaded (knee 0.833 pu); deriving per-unit p_set from
p_dispatch/p_nameplate inside the function is strictly more accurate and
gfl_available_fraction/2 already supports it. (b) `AGC.step/3` records commanded MW, not
delivered — when Reserves caps delivery at the deficit, dispatched_by_unit overstates and
reserve_remaining_mw/1 is pessimistic (measured 1,709 MW commanded vs ~100 MW deliverable;
bounded and self-limiting since ACE → 0 as the deficit closes). Found at Wave 3b, 2026-08-16.
**CAS-17 (DRIFT, LOW) [OPEN]** `FailureEvent` changeset whitelists component_type to
transmission_line/generator/transformer/load/bus, but live event streams also carry
water_facility, datacenter, island, cascade, and (new) btm_solar — nothing routes through
the changeset today, so it is drift, not breakage. Wave 3b grew the surface again: causes
uvls_shed (load), btm_voltage_trip (btm_solar), undervoltage_trip/overvoltage_trip
(generator), voltage_violation + generator_voltage_trips (island), conductor_thermal,
distance_zone1/2/3. Reconcile when events are next persisted through it. Found at item-31
integration, 2026-08-15.
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
**ENE-20 (FIXED 2026-08-16)** Root cause: dispatch placed 100% of each BA's EIA-930 fuel
MW while ENE-17 restricted load to the snapshot's share — 181.6 GW (23%) of Eastern's load
baseline sits on off-main fragments. Fixed by share-scaling fuel targets at dispatch time
(Demand.snapshot_load_shares/1; shares recomputed per run, so topology repair self-retires
the correction), range-proportional re-load for p_min lumpiness, and a DYNAMIC
broken-identity screen (catches BPAT alone; budget = share × (D+TI), see ENE-18).
Measured at 2025-01-01T04:00Z, as-dispatched: Eastern −65,100 → −174.9 MW (−0.07%); ERCOT
+3,223 → +652 MW (+1.55%) — NOTE the prior claim "ERCOT/Western dispatch was validated in
Phase 3" was mis-scoped: Phase 3 validated fuel-mix TV and the interchange identity, not
absolute balance, and ERCOT ran +7.7% long — confirmed at three hours (+7.67% reference,
+6.72% at 2024-11-30T18:00Z, +2.70% at 2024-12-31T18:00Z). The pre-fix ERCOT reference
cascade propagated on that surplus: neighbors of the tripped line carried fictitious
slack-bound flow at 0.77× vs 0.25× balanced, so the same trip now settles with 0 MW shed —
the controlled re-baseline of global gate 5, evidenced not assumed; Western −2,355 MW gross (−3.0%), −1,058 MW
(−1.4%) net of 1,297 MW of named unanchored generation (fleet-mapping residual, ENE-15/
DR-4/DR-5 territory). Eastern base overloads 4,444 → 778 (balanced control was 712);
Eastern >90° branches 15 → 1, the survivor being a LIN13-B stranded-wind spur (DR-4), and
Western's >90° set shifted onto a 115 kV Pacific-Northwest data-defect corridor (lines
61121–61147) now carrying redistributed power — DR-2/DR-4 own it. balance_operating_point
closes deficits but not surpluses, so dispatch-balance claims must measure RAW dispatch vs
connected load, never sol.mismatch_mw. ORIGINAL FINDING: Eastern's as-dispatched operating point ran ~65 GW
long: dispatched generation 300.3 GW against 235.0 GW connected load, with the slack bus
absorbing −60.6 GW (`mismatch_mw` −65,100). Every flow-derived number on Eastern is
suspect at that operating point — the first N-1 census measured the dispatch imbalance,
not the network: base overloads 4,366 (6.8%) vs 712 (1.1%) under a balanced control
scaling gen to load, worst mw_at_risk 362 GW vs 10.6 GW, and the two top-10 contingency
lists share ZERO entries. Likely interacts with ENE-17's cross-boundary BA scaling.
ERCOT/Western dispatch was validated in Phase 3 and does not show this. Found by the
LODF screening sweep 2026-08-15. Fix belongs in dispatch/balance_operating_point
ownership; until then, Eastern screening results should use the balanced control.
**ENE-21 (MED, NONDETERMINISM) [OPEN]** `Cascade.init` returns one of two dispatch
states on identical snapshots — measured 76.3 MW spread across 1,107 Western generators
on a snapshot agreeing to 1e-13; flips the Western overload census 585/586 between
identical runs. The solver is exonerated (row-shuffled and repeated solves bit-identical;
1e-9 MW injection swap moves flows 1.8e-9 MW). Dispatch-side map/order dependence is the
suspect. Until fixed, census gates on Western must be stated ±1 or pinned to one dispatch
draw. Also: Eastern base-overload reads differ by path (DR-2 census 781 vs UI-3
screening-base 807 on the same tree) — reconcile the two bases when ENE-21 is fixed.
Found by DR-2's A/B harness, 2026-08-16.
**ENE-22 (MED, DISCREPANCY) [OPEN]** Two identity screens disagree at runtime:
`Demand.broken_identity_bas/0` (DR-1, drives the dispatch correction) finds BPAT alone
broken, while `Ingestion.Validation`'s balance screen still reproduces the OLD numbers
(BPAT 0/4,417, MISO 5/4,389, CISO 611/2,473) on the same DB — observed in the 2026-08-16
re-ingest validate run. Same nominal formula (NG − (D+TI)); suspect a sign/column
divergence (raw vs Adjusted, or TI orientation) in validation.ex's SQL vs Demand's.
RESOLVED 2026-08-16 with ENE-23 — and the recorded root cause was WRONG: not sign or
column, but TOLERANCE (Demand screened at 5% relative, Validation at 1% — the entirety of
the MISO discrepancy). One implementation now (Demand.identity_closure_by_ba/0, on the
fuel sum dispatch actually places); Validation's own tolerance knobs deleted.
**ENE-18 (DATA CAVEAT) [RE-MEASURED 2026-08-16]** EIA-930's own identity NG − (D+TI)
fails for BPAT alone in the current DB: 0 of 4,417 hours close at 5% tolerance, mean
residual −4,317 MW (sd 725). The previously-recorded MISO and CISO are no longer broken
after the ENE-16 re-ingest — MISO closes 4,389/4,389, CISO 2,090/2,473 (84.5%); next-worst
IID at 60.9%. The screened set is therefore a MEASUREMENT (Demand.broken_identity_bas/0,
≥24 h and closure <50%), never a stored list — a stale list would now mis-correct two
healthy BAs.
**ENE-20 anchoring decision (DECIDED 2026-08-16).** For a screened BA the dispatch budget
is share × (demand + interchange) allocated in the BA's published fuel-mix proportions,
not share × net_generation. Rationale: a BA whose identity never closes cannot have both
its generation column and its demand/interchange pair be right, and this model is judged
against the second pair — served load and implied interchange. Measured Western at the
reference hour: +2.2% pre-fix (BPAT's −4.4 GW error accidentally cancelling the fragment
surplus), −8.1% under share-scaling alone, −3.0% with the correction (−1.4% net of the
named 1,297 MW unanchored). The rejected alternative — share × (D+TI) for EVERY BA —
reaches −2.2% but degrades Western fuel-mix TV 0.025 → 0.054 by re-weighting BPAT's
hydro-heavy mix into capability limits, failing the TV regression gate. The correction is
reported per BA as identity_correction_mw and retires itself if EIA revises the data.
**LIN-12 (FIXED 2026-08-16)** Root cause: the Pacific DC Intertie (HIFLD 200823,
voltage_kv=1000) seeded phantom voltage levels via augment_voltage_levels_from_lines.
Fixed by dc-line exclusion + 765 kV cap in the augment, and a predicate-based migration
retiring the phantom levels/transformers (Western buses exactly −2, the 765kV+ class
gone, CELILO/SYLMAR EAST corrected, dc_ties id=1 untouched). DR-3.
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


## Post-round bug hunt — 2026-08-16 (four domain reviewers, executed repros)

Method: rev-solver / rev-cascade / rev-data / rev-ui, read-only, primed with the
known-open list; every finding below carries an executed repro or a concrete reachable
scenario; clean bills recorded in the session log. Conservation identity survived five
adversarial cascades designed to break it; the Blue Cut guard proved exactly disjoint;
reactor signs verified end-to-end; the NIF error contract verified at all 12 call sites.

**CAS-20 (FIXED 2026-08-16)** Collapsed islands report nadir 60.00 Hz: the three island-death
paths (cascade.ex ~:1992/:2065/:2191) replace the record with fresh_island_record and
DISCARD the trajectory that killed the island; step_nadir_hz reads the survivors. A total
blackout renders 60.00/60.00 — the misreading the frequency contract exists to prevent.
Fix: accumulate nadir where trajectories are produced (solve_islands_timed accumulator).
**CAS-21 (FIXED 2026-08-16)** Nadir leaks across cascade events: begin_cascade_event rebases the
floor but record.exposure keeps 180 s of history, so the next event's step 1 re-reads the
old dip (measured: a 3 MW trip "reaching" 59.16 Hz). Same fix as CAS-20.
**CAS-22 (FIXED 2026-08-16)** (per-tier delivered ledger on the island record) Clock-ramped reserve tiers re-grant the full elapsed-time ramp on
every allocate/4 call; the cascade calls up to 3x per island per step — a slow fleet
delivers up to 3x its own ramp past 600 s and UFLS under-fires (measured 60 MW from a
20 MW/min unit). Fix: per-unit delivered-under-this-clock tracking fed as already_mw.
**CAS-23 (FIXED 2026-08-16)** (per-zone timers; worsening faults trip sooner) Distance-relay duty is keyed by zone cause, so a branch whose
apparent impedance walks inward loses accrued duty and trips LATER than a static fault
(zone3 0.9 duty + zone2 restart = 1.75 s vs 1.50 s). Real relays run zone timers in
parallel. Fix: key distance duty {:distance, type, id} with per-zone timers in the value.
**CAS-24 (FIXED 2026-08-16)** voltage_alarm (absolute bus-count high-water) is inherited
untouched across splits, so the smaller fragment can never re-alarm. Reset it alongside
ac_voltage in inherit_record's non-equal branch.
**CAS-25 (DOCUMENTED 2026-08-16)** (list authoritative; synthetic frame would desync step indexing) :budget_exhausted never reaches a callback-stream
consumer (the budget clause fires INSTEAD of a step; the stamp lands only on the returned
list). Latent: SimulationServer broadcasts the list. Document or emit a final callback.
**CAS-19 re-rated LOW → MED**: the fleet-wide p_set_pu default measured as PHANTOM
generation loss (a 20 MW-dispatched farm at 0.60 pu loses 5.6 MW that lands in the
deficit and drives UFLS) — biases cascades toward collapse, not just bookkeeping.

**SOL-14 (FIXED 2026-08-16)** (cutoff 300 by boundary measurement; Solution.solver stamp; hard_failure window widening documented as intended) FDPF's dense-NR fallback is a cliff: measured 5.2 s / 120.4 s /
340.8 s at 306/933/1,318 buses (all converged:false — same answer the 0.25 s refusal
gives), 1.4 GB peak at 1,318, O(n^3) to ~67 min at the 3,000-bus cutoff. Fires on real
islands (LIN-13 makes non-convergence the NORMAL case) inside the 120 s trip timeout.
Fix: cutoff → ~300 and stamp the Solution with the producing solver.
**SOL-15 (FIXED 2026-08-16)** solve_jacobian_gauss (newton_raphson.ex:1047) is the uncapped
twin of the gaussian_solve SOL-4 capped — reached when native LU fails on exactly the
ill-conditioned islands SOL-14 sends there; extrapolates to ~47 h at cutoff size. Cap it.
**SOL-16 (FIXED 2026-08-16)** (the :clean mislabel was latent — every pair draws from pre-solved seed columns; the reachable worker-crash arm is tested; the {:error,_} arm of evaluate_pair is correct but unreachable via the public API — not dead code) screen_n2 reports a FAILED pair solve as :clean
(contingency_screening.ex:448) and lacks sweep/3's {:exit,_} clause — contradicting the
module's own no-partial-results contract. Propagate and abort like screen/2.
**SOL-17 (FIXED 2026-08-16)** LODF.flows/1 error path silently returns BASE flows as
post-outage flows (lodf.ex:300) — contradicts the module's "never silently degraded"
promise. No callers yet; fix the return shape before one appears. needs_refactorize?/1
is likewise wired to nothing.
**SOL-18 (FIXED 2026-08-16)** (parameter_estimator's text was wrong on BOTH numbers: 4,485 repair rows at v0 / min |x| 1.2e-5 above the clamp — exclusion load-bearing for length-correctness, not clamping) Stale invariants: lodf.ex:68 still says ±1e-3 floor; parameter_
estimator.ex:31 still claims repair rows at v0/below-clamp; newton_raphson.ex:551's
"where n^2 is affordable" contradicts SOL-14's measurements.
**SOL-19 (FIXED 2026-08-16)** bus.vm_pu dot-access (newton_raphson.ex:477) — the SOL-5 pattern,
ten lines above the comment documenting the opposite rule; raises on plain-map buses
(unreachable in production, bites tests/fixtures). bus_type at :410/:430/:476 same.
**SOL-20 (FIXED 2026-08-16)** (the two branches named and derived: 765 kV jumpers at 100/184 m, floor inflates 2.1x/1.1x) YBus's "floors nothing physical" claim is false by two lines: two
sub-200 m 765 kV jumpers sit exactly at the 1e-5 write floor. Reword or lower the pair.
Also for the record: ZERO bus_type=3 rows exist DB-wide — every solver derives slack from
the largest-generator tiebreak (measured stable, but the slack moves when that unit trips);
zero capacitor banks exist, so B'' has never seen a diagonal-weakening shunt.

**DAT-25 (FIXED 2026-08-16)** (the specified fix was incomplete — interconnection_demand_for_date/1 has its own query; both filtered) Generation-only BA rows (demand_mw NULL — created by
DR-1's form930 fix + migration on the NEXT demand ingest; 0 exist in dev today) crash
Demand.interconnection_demand_for_date/1 and scale_loads_to_national/2 (nil arithmetic);
the first is called unconditionally by the dashboard. Fix: not is_nil(demand_mw) in
demand_at/1 (the nil-tolerant readers key on absence already).
**DAT-26 (FIXED 2026-08-16)** (line-pass-only moved — the full move would have silently synthesized zero reactors; remap stage added) full_pipeline runs map_buses (stage 7) before
estimate_parameters (stage 9), so DR-4's capability-ranked placement sees rating_a_mva
nil→0 on lines (87.8% of capability at generator buses; 6,433 buses / 632.9 GW have zero
transformer capacity) and falls through to the pre-DR-4 nearest-any-level rule; the
repairing remap_stranded_generators has NO pipeline caller (migration 150003 only). Fix:
reorder + add a remap stage after repair_connectivity.
**DAT-27 (FIXED 2026-08-16)** (down nulls generators + refuses on un-nullable referents; verify via Migration.Runner in-process, NEVER Ecto.Migrator against dev — see the 2026-08-16 incident note) Migration 20260816150000's down/0 raises FK violation 23503:
150003 later moved 102 generators onto the synthetic buses it deletes, and 150003's own
down is :ok. Executed in a rolled-back transaction. Fix: null generator bus_ids first, or
refuse with the map_buses pointer like 150002/150003.
**ENE-23 (FIXED 2026-08-16)** (single implementation on the fuel sum; screened set now BPAT+WALC; Western −255.9 MW, in gate; Eastern/ERCOT exactly 0.0) The ENE20-C identity screen tests ba_demand_hourly.net_generation
while dispatch places ba_fuel_hour fuel columns — a different series. WALC: NG closes
0.995 but fuel-sum closes 0.313, over-dispatched +20.7% of own demand on 69% of hours,
invisible to the screen; national fuel-sum runs +2,202 MW (+0.5%) above the D+TI anchor.
Fix: screen on sum(ba_fuel_hour) — the same one-query change as reconciling ENE-22.
ENE-22 ADDENDUM: the dispatch correction's ORIENTATION is confirmed correct (BPAT's NG and
fuel-sum residuals agree to 2 MW); ENE-22 lives entirely in validation.ex's screen.
**DAT-28 (FIXED 2026-08-16)** (stranded nameplate, zero-capability buses, deg-1 load share in the baseline) priv/topology_baseline.json records only counts/connectivity — no
placement, capability, stranding or load-distribution metric — so DAT-26's degradation
passes the pipeline's final gate clean. Also enshrines buses_without_ba=2701: DAT-23's
fix will fail the gate and needs --update-baseline in the same change.
**ENE-24 (FIXED 2026-08-16)** (worse than logged: share 0.5 broke SOC conservation by −8,747 MWh/day) Storage duty cycle mixes share-scaled (dispatch-hour) and
unscaled (other 23 h) series in day_shape/cap_to_measurement; grows with (1−share), worst
on fragmented interconnections. Pass the share into Storage.profile/2.

**UI-M18 (FIXED 2026-08-16)** (manifest.bin content tag, counts + max(updated_at), written last; caught live drift on first run) ensure_exported checks FORMAT only (count>0,
BLD tag) and cannot see the DB moved: after the re-ingest the map served 13,290 fewer
in-service lines than the DB (silently unpaintable trips) and pre-DR-5 demand hexbins.
Export regenerated 2026-08-16 (ops); code fix: content tag (row counts / max updated_at)
in the header, compared at boot.
**UI-M19 (FIXED 2026-08-16)** (scrub refused while live — replay only ever runs against a settled timeline) Scrubbing during a LIVE cascade permanently desyncs the map:
showCascadeStep rewinds and replays 0..position, later-arriving frames apply on top, the
skipped frames' trip marks are gone for the session (executed JS repro); the final
dc_update restores flow classes but never STATE_TRIPPED. Fix: replay full history on next
live frame, or disable scrub while cascadeActive.
**UI-M20 (FIXED 2026-08-16)** (epoch on results, < comparison, task cancel/drain on reset/DOWN/hour-change) assign_n1({:result,...}) sets n1_stale: false unconditionally —
a sweep completing after a mid-sweep trip ERASES the advisory banner that trip raised,
presenting a pre-trip LODF linearisation as current (executed LiveView repro). The engine
already stamps :epoch on screening_snapshot for exactly this; index.ex never reads it.
Also: reset/DOWN clear n1_result but not n1_task, so an in-flight sweep repopulates after
reset. Fix: carry epoch into the result and OR into staleness.
**UI-M21 (FIXED 2026-08-16)** Post-cascade scrubbing re-enters cascade mode (vignette, ghost,
forced layers) with no exit except Reset — shouldBeActive derives from history length,
and no second cascade_done is coming. Track ended-ness explicitly.
**UI-M22 (FIXED 2026-08-16)** inject_failure has no re-entrancy guard: double-click orphans the
first trip monitor and the second's {:error, :already_tripped} reply sets
cascade_active: false MID-CASCADE (badge "Already tripped", button re-offered). One-line
guard + ignore stale trip_rejected.
**UI-M23 (FIXED 2026-08-16)** run_n1_screening has no re-entrancy guard: two fast clicks = two
full sweeps (240 s national CPU each), first task orphaned, older result can overwrite
newer. One-line guard.
**UI-L15 (FIXED 2026-08-16)** A failed post-cascade DC solve suppresses the voltage overlay
broadcast entirely (simulation_server.ex ~:427) — :solve_failed is exactly when the
operator most needs the voltage picture, and the cascade's converged per-island AC is
independent of that final solve. Hoist the broadcast.
**UI-L16 (FIXED 2026-08-16)** Zero aria-live/role=status in the grid UI: every status
transition added this round (Collapsed, step-budget, solve-failed, N-1 states, banners)
is silent to screen readers; the sparkline SVG has no accessible name.
**UI-L17 (FIXED 2026-08-16)** (surfaced: '+N more · M not itemised') :trips_omitted is computed, shipped, and read by nothing — the
200-trip itemisation cap is never surfaced. Render it or drop it from the client payload.

### Fix-wave residue (2026-08-16)

**SOL-21 (LOW) [OPEN]** DCPowerFlow.find_slack_index/3 (dc_power_flow.ex:248) has the
SOL-19 dot-access pattern (`&1.bus_type == 3`) — raises KeyError on keyless plain-map
buses. Found by fix-solver's regression test; out of its stamp-only DC scope.
**DAT-29 (LOW) [OPEN]** BADemandHour.changeset still validate_required(:demand_mw) while
Form930 inserts NULL-demand rows via insert_all — schema and ingest disagree; bites the
next changeset-path writer. Found at DAT-25.
**CAS-19(b) [STILL OPEN, deliberate]** AGC records commanded not delivered — needs the
delivered-feedback path from the allocate result done whole; explicitly not half-fixed.
**ENE-20 RE-BASELINE NEEDED**: the recorded reference-hour numbers (Eastern −0.07%,
ERCOT +1.55%) no longer reproduce on the current tree (+0.76% / +1.66%) — measured
invariant under every fix-wave change, so the drift belongs to the DR-4/DR-5 remaps plus
dev-DB movement (incl. the 2026-08-16 migration incident: dev is functionally consistent
but not bit-identical; +10 synthetic buses, +24 NULL endpoints). Still inside all gates;
re-measure and re-record when next touched. Baseline caveat (dated 2026-08-16):
priv/topology_baseline.json was regenerated post-incident, so it bakes in the +10
synthetic buses (93,093) and +24 unrecovered endpoints (4,691) — checked behaviourally
inert: the diff tolerances (±4,655 / ±235) swallow both deltas, so a clean re-ingest
landing on pre-incident values diffs clean in both directions. Not annotated in the JSON
itself because write_baseline! regenerates the note field verbatim and an incident line
there would outlive its truth.
**Notes for the record (fix-solver, confirmed by query):** no bus in the DB is marked
slack (bus_type=3 count 0) — all three solvers fall through to the largest-generator
tiebreak, stable in measurement but the slack MOVES when that unit trips, which is a
cascade scenario, not a hypothetical. And zero capacitor banks exist (all 7,222 shunts
are reactors, diagonal-STRENGTHENING) — the first capacitor bank ingested is the first
real test of B'' conditioning.

## Voltage-coverage wave — 2026-08-19..22 (diagnosis wave + four fix agents, measured)

Method: a two-agent diagnosis wave attributed the LIN-13 α ceiling per interconnection,
then four fix agents (loads, corridor, compensation, OSM) worked under exclusive file
ownership with every DB write gated on the lead. α means the highest uniform scaling of
hour-scaled load P **and** Q **and** generator dispatch at which an AC solution exists,
bisected to 0.01 on the largest island of `Partition.split/1`, hour =
`Demand.latest_demand_hour/0`, `FDPF.solve(base_mva: 100.0, dense_nr_max_buses: 0,
max_iterations: 400)`.

| stage | Western | ERCOT | Eastern |
|---|---|---|---|
| diagnosis baseline | 0.2313 | 0.5687 | 0.3938 |
| + OSM corridor voltage corrections | 0.175 | 0.5938 | 0.4313 |
| + generator-support banks + interface compensation | 0.2062 | 0.6375 | 0.4313 |
| + OSM voltage backfill (58,766-element pull) | ceiling-neutral | ceiling-neutral | ceiling-neutral |

**MEASUREMENT LAW (adopted mid-wave, after it was violated).** Day one produced two
invalidated baselines: loads were rewritten at 01:29 UTC underneath agents that had
cached them earlier, so their "deltas" measured two waves at once. The rule that
replaced it — and that every number above obeys — is *A/B on ONE snapshot, control
being an in-memory undo of the treatment*, never a re-read of a table another writer
may have moved. Corollaries that also had to be written down: private per-agent caches
(the shared cache rebuilt only when a file was ABSENT, so it never noticed staleness);
label every result with `max(updated_at)` fingerprints of its input tables; wait for an
agent's explicit completion report rather than inferring completion from a table
timestamp; pre-register the predicted direction before measuring.

**LIN-13 CORRECTION (2026-08-19..22).** The wave's central negative result: **the OSM
voltage backfill is NOT the α = 1.0 path.** ROADMAP item 24 was carried as the unlock
for the voltage chain; measured, it is ceiling-neutral on all three interconnections.
What it bought is data correctness — voltage-blind yards 8,404 → 3,617 — which is worth
having and is not the same claim. The ceiling has three DIFFERENT causes, one per
interconnection, and they need three different fixes:
- **Western — LOCAL generator reactive exhaustion.** 22% of generator buses sit pinned
  at `q_max` while the island as a whole is absorbing reactive power. The `qmax10` lever
  (generator q limits ×10) alone buys +46%. This is a voltage-CONTROL gap, not a
  reactive-supply gap: the vars exist, in the wrong places, with no mechanism to move
  them. Capability curves, AVR/remote regulation and ULTC transformers are the shape of
  the fix — see the note under "rejected" below, which this measurement reopens.
- **Eastern — sub-transmission impedance.** The `xcap005` lever alone buys +71%;
  every reactive lever moves it ~0%. This is a parameter-estimation defect and the
  single highest-leverage number in the model.
- **ERCOT — three super-additive constraints.** `caps100` + `freeq10` + `xcap010`
  together reach α = 0.9875; no one of them is close on its own.
All failures were confirmed to be genuine loss of the AC solution (past-the-nose
trajectories), not solver artifacts. Max-lever walls — the ceiling with every lever
applied at once — are Western 0.5062, ERCOT 1.4937, Eastern 1.2062, so ERCOT and
Eastern have a reachable α = 1.0 and Western does not.

**LIN-14 (MEASURED, HIGH) [OPEN]** Each interconnection's α swing is attributable to
ONE line: 73687 (Western), 72357 (ERCOT), 67217 (Eastern) — proven by ablation, not
inferred. Two consequences. First, the ceiling is far more brittle than a
whole-network number suggests: a single mis-parameterised circuit can hold an entire
interconnection's loadability. Second, the Western DROP at the corridor stage
(0.2313 → 0.175) is a deliberate loss of a wrong number — line 67217 had been carrying
a voltage class the OSM corridor pull contradicts, and correcting it removed artificial
support. A ceiling that falls because the data got more honest is the right trade, but
it means the α series is only comparable within a fixed data vintage. The >90° census
is now 0/0/0 (72357 resolved as 138 kV, closing the last DR-wave survivor).

**CAS-26 (MEASURED, HIGH) [OPEN]** The base case is overloaded to the point that
contingency response is binary. Lines sit at 124–250% loading at rest, so a
contingency either settles at zero (everything downstream was already immune) or runs
away past the step budget; there is no settled non-trivial cascade regime in this model
today. This is upstream of every cascade result the model produces and it will break
ROADMAP item 26's historical replays before they can fail for an interesting reason.
It is also directly testable: item 27's blackout-size CCDF against DOE OE-417's
published α ≈ 1.31 should come out bimodal rather than power-law, and that measurement
costs far less than fixing it.

**CAS-27 (MED-HIGH) [OPEN]** Equipment-side voltage dropout is absent. The model keeps
19.7 GW of datacenter load energised at ANY voltage sag, but real PSU/UPS front ends
transfer or disconnect below roughly 0.85–0.90 pu (ITIC/CBEMA). This is a third,
distinct mechanism from the two that DO exist and DO fire: utility UVLS (0.92/0.89/0.86
pu, 8/5/3 s) and IEEE 1547 BTM trips. Stated carefully because an earlier framing of
this finding — "nothing sheds on voltage" — was wrong and had to be retracted: plenty
sheds on voltage, and the gap is specifically the load's own equipment.

**LIN-15 (LOW, DOCUMENTATION) [OPEN]** The synthesized line-end reactor is
K × the line's OWN charging on ≥230 kV circuits only, and 69% of the population sits
at exactly 230.0 kV. That makes the reactor pass SELF-DAMPING under reclassification —
moving a circuit across the 230 kV boundary moves its charging and its reactor
together, so the net swing is far smaller than the gross. Worth recording because it
was mis-predicted twice during the wave, once by 200× and once in the wrong direction.

**DAT-30 (MED) [OPEN]** Key-design trap, with its own control case. `BusMapper` writes
`buses.source_id` as `"<substation id>_<kv>kV"` — the key EMBEDS the voltage — so any
voltage restamp renames the bus and silently orphans anything keyed to it. Measured
after the OSM backfill: 60 of 1,627 reactive-support-study banks stopped resolving,
every one a `..._138.0kV` id (down to 46 after the review gate's reverts). The fix
shipped is a LOUD drop plus self-heal on re-derive, deliberately NOT fuzzy prefix
matching: a yard has buses at several voltages and a bank on the wrong one is worse
than no bank. Contrast `yard_key/1`, which parses only the integer prefix and is
structurally immune to the same event. Any future key over substation identity should
follow `yard_key`, not `source_id`.

**DAT-31 (MED) [OPEN]** `priv/reactive_planning/reactive_support_banks.json` is a
measured planning study carried as committed data with a full `basis` block (hour,
snapshot recipe, solver options, control definition, lever, per-interconnection α), but
it has NO committed producer — the harness that derives it lived in a session
scratchpad both times it was run. The basis block makes it reproducible by a careful
reader and that is why the re-derivation was possible at all; it should still become a
mix task, because the study must be re-derived after ANY change to voltage data
(see DAT-30) and a study nobody can regenerate on demand will go stale silently.

**SOL-22 (LOW, CONTRACT) [OPEN]** Interface compensation has exactly one opt-out seam,
and it is load-bearing. A published MATPOWER/IEEE case states each bus's load as the
NET reactive demand already measured at the transmission bus; synthesizing our
distribution compensation on top double-counts it and moves the case off its published
solution. `PowerModel.Test.MATPOWER` therefore stamps `load_compensation: 0.0` on every
case it parses (one line), and the global default stays ON because our own loads are
synthesized at a flat 0.95 pf, which is a penalty threshold rather than an operating
point. Any second importer of external cases must stamp the same field or it will
silently reproduce the bug the reference tests caught.

**LIN-16 (MEASURED, MED-HIGH) [OPEN]** Conflation anchor cases for the next wave, all
selected because they are the ones that did NOT fix themselves:
- Generator 21001 (wind) is stranded: its real point of interconnection is OSM 345 kV
  way 1058593873, 7.52 km away, absent from HIFLD entirely. Remap survivors were
  selected for unfixability, so this is the shape of the residue.
- A systemic 138 kV misclassification across southwest Utah.
- ERCOT bus 69603 carries six distinct OSM yards conflated onto one bus.
Bus-level conflation puts load and generation in the wrong ELECTRICAL place, which is
upstream of impedance, ratings and dispatch alike.

**DAT-22 (CLOSED 2026-08-22)** Datacenter placement now derives its voltage floor from
the same C57.12.00 delivery-ceiling table the load estimator uses (≤50 MW → 60 kV,
≤250 → 100 kV, >250 → 230 kV, saturating at 230), prefers a single yard, doubles its
search radius to 120 km, places largest-first, and splits campuses that no single bus
can serve. `Datacenter.bus_id` is now the anchor (largest share). Verified by census
on the live DB 2026-08-22: every gated section zero — unservable 0, radial >200 MW 0,
over single-branch rating 0, over 0.8× capability 0, over class ceiling 0,
transformer-fed above 0.8× bank 0, below the 60 kV load-serving floor 0.0 MW (from
2,518 MW), worst degree-1 load share 10.8% against a 15% limit.

**Process note — the three self-corrections.** The compensation agent caught and
reversed three of its own conclusions before shipping any of them: a claimed shed-Q
defect (retracted — `load_shedding.ex` already scales `q_mvar` with `p_mw`, confirmed
across all four load mutations), uniform datacenter compensation (reversed on device
physics — active front ends hold power factor across voltage, so a passive V² model
would have overdrawn ~12% at 0.9 pu on 19.7 GW), and a reactor alarm that was
overstated 200× and pointed the wrong way. One root cause: reasoning about a single
term in isolation. The refined rule, worth keeping: *"I already looked at that file"
is not "I checked whether this mechanism exists."*

### Closing cycle — 2026-08-22 (reallocation + re-derived reactive study)

Ran solo after the wave's fix agents finished. Three arms per interconnection on ONE
snapshot each, control being an in-memory undo (stored `bs_mvar` minus
`capacitor_bank_targets/1`) so no arm can contaminate another and the DB is untouched
until the end:

| interconnection | A control (reactors only) | B incumbent banks | C re-derived banks |
|---|---|---|---|
| Eastern | 0.4297 | 0.4297 | 0.4297 |
| ERCOT | 0.625 | 0.6406 | 0.6406 |
| Western | 0.1875 | 0.2031 | 0.2031 |

**Eastern gains EXACTLY NOTHING from reactive support** — 13.1 GVAr of banks across the
interconnection and the ceiling does not move one bisection step. This is an independent
confirmation of the diagnosis wave's attribution (Eastern is bound by sub-transmission
impedance; reactive levers ~0%) arriving down a different measurement path, and it is
the sharpest evidence available that Eastern's α is a parameter problem rather than an
equipment problem. ERCOT +2.5% and Western +8.3% are where the banks earn their place.

**The re-derivation is ceiling-neutral (C == B at 0.01 resolution) and shipped anyway.**
It resolves all 1,720 banks where the incumbent study left 46 orphaned by the OSM
restamp (DAT-30), so it removes a standing warning at zero measured cost, and it is
derived on the network as it now stands rather than on a superseded voltage vintage.
Recording the neutrality explicitly because the tempting misreading is that healing the
orphans mattered: it did not. The 46 dropped banks were not load-bearing for the
ceiling. What re-derivation buys is a study that describes the current network and a
pass that no longer warns — not α.

Method reproducibility, which is the reason to trust the above: re-deriving from scratch
against a network that had moved returned ERCOT at 592 gen buses / 232 pinned / 205 with
shortfall against the 2026-08-19 study's identical 592/232/205, and Western's control α
at 0.1875 against the same figure recorded in that study's own basis block. New totals
1,720 banks / 8,912.6 MVAr (from 1,627 / 8,808.2).

Reallocation, in the order the reserve logic requires (`map_datacenters_to_grid` anchors
campuses, `reallocate` yields around them via `committed_load_by_bus`, then
`resize_transformers_to_through_load`): 15,197.7 MW moved across 68,509 buses, 860
emptied, 829 at their capability cap, residual 0.0 MW; datacenter MW conserved exactly
at 19,715.0; constant-power total +2.4 MW on 1.12 TW, which is `Float.round/2` at two
decimals over 70,694 rows. Transformers needed no resizing. `synthesize_bus_shunts/1`
verified idempotent both times it ran (second pass wrote 0 rows).

**DAT-32 (LOW) [OPEN]** 4,485 `connectivity_repair` lines and all 27 `international`
lines sit at `params_version: 0`. This is inert rather than wrong — those rows are
externally authored and the recompute predicate is guarded against them twice (ROADMAP
item 8 records the near-miss where it was not) — but a v0 stamp normally MEANS "the
estimator should revisit this", so the two readings of the same value should be
separated before someone acts on the wrong one.

**Topology baseline re-recorded 2026-08-22** (`priv/topology_baseline.json`,
`generated_at` 2026-08-16T10:54:33Z → 2026-08-22T21:16:09Z). Every metric that moved
moved in the IMPROVING direction and nothing regressed, which is why this was recorded
rather than investigated: ERCOT `degree_1_load_mw` 4791 → 4107 (−14.3%, the metric that
tripped the tolerance), Eastern 110581 → 106683 (−3.5%), Western 31781 → 31656 (−0.4%),
matching shares, and `stranded_nameplate_mw` 99792 → 99641. The 2026-08-16 caveat still
applies unchanged and is NOT re-litigated by this rewrite: `bus_count` is still 93,093,
so the +10 synthetic buses and +24 unrecovered endpoints from the migration incident
remain baked in, still inside the ±4,655 / ±235 diff tolerances in both directions.

### Eastern impedance — three hypotheses measured and refuted (2026-08-22)

The closing cycle proved Eastern's ceiling is not reactive (13.1 GVAr moves it zero
bisection steps), so the next question was which impedance. Recorded because each of
these is the obvious guess and each is WRONG, and re-running them costs hours:

**REFUTED — "the per-km impedance recipe is too high."** It is not. Implied series
reactance is 0.335-0.50 Ω/km at the median across every voltage class, squarely in the
physical band for overhead line, and NOT ONE in-service circuit exceeds 1 Ω/km. The
monstrous per-unit values are real ohms divided by a tiny Z-base: line 76582 carries
2.41 Ω over 5.36 km — entirely normal — but sits at `voltage_kv = 3.0`, so
Z_base = 0.09 Ω and x_pu = 26.8. The estimator is right; the VOLTAGE CLASS on a handful
of circuits is absurd (3.0 kV, 7.5 kV, 24.9 kV "transmission lines"), and several of the
worst are `osm_rederived`, so the backfill moved some circuits DOWN into classes where
their real length makes them electrically opaque. That is a data-correctness item, not
the ceiling.

**REFUTED — "load sits behind branches past their angle limit."** A lossless branch
carries at most V·V/x, i.e. 100/x MW on a 100 MVA base, and the guess was that load
placement respects the THERMAL rating while violating this one. Measured across all
20,581 degree-1 load buses: **zero** exceed their single branch's angle limit, and the
worst ratio in the population is 0.2. The angle limit is looser than thermal on
99.6%+ of circuits in every class (median 100/x is 2,876 MW at 46-99 kV against a
median rating of 116 MVA). `LoadEstimator`'s capability check against rating is the
correct check.

**REFUTED (with a caveat) — "load is delivered too many sub-transmission hops from
generation."** The asymmetry is real and worth knowing: generation sits on EHV and load
does not. Share of nameplate generation on a ≥230 kV bus vs share of load, by BFS hop
distance over lines+transformers — Eastern 72.8% gen / 12.4% load, ERCOT 52.9% / 6.1%,
Western 66.9% / 11.6%; 32.5% / 47.4% / 26.5% of load sits 5+ hops out. But lifting every
load deeper than 2 hops up its BFS parent chain to the nearest shallow bus, conserving
island MW exactly and changing only WHERE load is delivered, moved α: Eastern
0.4297 → 0.4219 (−1.8%, one bisection step, i.e. slightly WORSE), ERCOT 0.6406 → 0.6953
(+8.5%), Western 0.2031 → 0.2031 (0.0%) — while relocating 65.7% / 77.7% / 60.5% of each
island's load. CAVEAT, stated because it limits the conclusion: lifting removes series
impedance but CONCENTRATES load onto few shallow buses, so a null result is consistent
with two effects cancelling rather than with depth being irrelevant. What it does rule
out is depth as a *dominant* single cause — a 189 GW relocation cannot move Eastern one
step in the right direction.

The `xcap005` lever's +71% on Eastern therefore comes from the high TAIL of x_pu
(≈19,000 sub-161 kV branches above 0.05 pu), not from the average delivery path and not
from any single-branch limit. Which branches, at the failing operating point, is the
next measurement — `Solution.vm_floor_bus_ids` (added by this wave for exactly this
purpose) names the buses that cannot satisfy their own Q equation when the solve gives
up.

### The ceiling names one bus, and it is a generator-interconnection defect (2026-08-22)

`Solution.vm_floor_bus_ids` — the telemetry this wave added for exactly this
question — answers what three refuted hypotheses could not. At one bisection step
past its ceiling, **Eastern reports `vm_floor_count = 1`**: bus 74129, 69 kV,
degree 2, carrying 3.2 MW at the reference hour. ERCOT reports 3. Western's worst
branch by angle is 67217, which is the line the wave attributed its whole swing to
by ablation — an independent method landing on the same element.

**LIN-17 (MEASURED, HIGH) [OPEN]** The α ceiling is set by SINGLE-ELEMENT HIFLD
data defects at specific yards, not by any distributed property of the network.

CORRECTION (same day, before this hardened): this entry first said "generator
interconnection defects", which is true of ERCOT and FALSE of Eastern — Eastern's
floor bus carries no generation at all, and its defect is a mis-tagged voltage
class on a 6.5 MW load pocket. The common thread is the DATA, not the mechanism.
Both cases are one element, and both are worth more than ten percent of their
interconnection's ceiling:
- **ERCOT bus 58121 is a 345 kV switchyard with ZERO 345 kV lines**, holding a
  525 MW generator. Its only path out is a 600 MVA transformer to 69 kV, 8.4 km of
  69 kV, then lines 74137 and 72922 — ERCOT's #1 and #2 worst branches at **69.0°
  and 64.9°**, closing on the 90° limit past which no AC solution exists. Those two
  lines carry 172.8 and 103.5 MW at α = 0.64: the plant's output, exported through
  69 kV.
- **Eastern bus 74129** hangs off two long 69 kV lines (37.9 km at x = 0.358,
  48.8 km at x = 0.461), its #2 and #3 worst by angle.

Peeling confirms it is STRUCTURAL, not load: zeroing the load at Eastern's floor
buses and re-bisecting leaves α at 0.4297 for six consecutive rounds, with buses
74129 and 74130 still on the floor **carrying zero MW**. Yard 73977's 33 kV line
**73688** carries `x = 1.5263 pu` over 36.9 km — verified 2026-08-22 against the
row itself, after this entry first mis-cited it as 73687, which is a different
(OSM-corridor-corrected, 69 kV, x = 0.0467) line. At 69 kV, the yard's own other
level, the same ohms would be 0.349 pu. One mis-tagged yard is pinning an
interconnection.

Geography, for whoever repairs it: yard 73977 is substation "#6" in eastern New
Mexico (33.937, -103.673), levels {69, 33}, carrying 6.5 MW — and it sits 14.8 km
from a 230 kV bus. ERCOT's 58121 has a 345 kV bus with lines 29.5 km away, and
FOUR more 345 kV buses within 54 km that ALSO carry zero lines, so the missing-EHV
-circuit defect there is regional (the San Angelo area) rather than a one-off.

**REPAIRS MEASURED (2026-08-22, in-memory hypothesis tests, nothing written).**
The question the census could not answer on its own is whether it measures
something that MOVES α or merely something that is wrong. It moves α, and by a
lot per element:

| repair | α before | α after | change |
|---|---|---|---|
| ERCOT: one synthetic 345 kV tie from bus 58121 to bus 72395 (29.5 km) | 0.6406 | 0.7188 | **+12.2%** |
| Eastern: line 73688 reclassed 33 → 69 kV (the yard's own other level) | 0.4297 | 0.4766 | **+10.9%** |

One branch and one voltage tag, each worth over a tenth of a ceiling. ERCOT has 45
more flagged buses; Eastern's census population is 322.

A synthetic tie is a CLAIM about what the real network has, and these runs do not
establish that claim — they measure what the ceiling would be if it were true,
which is what decides whether chasing the real circuit is worth the effort. It is.

This MERGES two items previously ranked apart: the α work and the conflation wave
(LIN-16) are the same work. HIFLD is missing the EHV circuits that connect large
plants, so the model routes their output through whatever sub-transmission it does
have. Census below.

Also measured at Eastern's ceiling, and against the earlier framing: **two-thirds
of the reactive absorption is on EHV** (43.1% on ≥345 kV, 23.6% on 230-344, against
7.7% below 100 kV), and the worst branch angle anywhere is 29.4°. Eastern's ceiling
is not an angle problem and not a sub-transmission problem — which is why banks at
generator buses moved it zero steps.

**Reach, from the census (2026-08-22):** every one of ERCOT's 16,575 flagged MW
sits within 50 km of a bus that ALREADY carries lines at the voltage it needs —
H.O. Clarke's 828.9 MW has a 345 kV bus 8.6 km away, bus 71881's 1,884.4 MW has
one at 33.0 km. These are missing circuits beside existing infrastructure, not
plants stranded in empty country, which is why the reach column was added: it
sorts the census into work somebody can actually do.

**OSM coverage of the fix path, measured**: of Eastern's 64 stranded yards ≥100 MW,
48 carry an OSM match and 16 (3,455 MW) show a HIGHER voltage level than the bus the
generator sits on, at 0-86 m. ERCOT — the biggest population at 17.3 GW over 51
yards — has 7 matched and **zero** with a higher level. So the substation pull does
not cover ERCOT's cases; recovering them needs a targeted OSM *line* pull around
those yards, which is ROADMAP item 24's second bullet, now prioritised by MW.

### Reference corpus — "is this number normal?" becomes a lookup (2026-08-22)

`PowerModel.Reference` + `priv/reference/structural_stats.json` +
`mix grid.reference_stats`. Structural distributions from the MATPOWER cases
already vendored for solver validation, so a census can be read against something.

It paid for itself before it shipped. The depth experiment above cost an hour and
relocated 189 GW to return "inconclusive". `case_ACTIVSg2000` answers the same
question in a lookup, and answers it the other way round from how the experiment was
framed: **32% of its load sits 5+ hops from the top voltage level, against our 32.5%
— our depth is ORDINARY.** What is not ordinary is where the load sits by voltage:
reference places 100% of load at 115 kV (64.8%) and 161 kV (35.2%), **none on EHV
and none below 115 kV**, where ours puts 12.4% of Eastern's on ≥230 kV.

**Deliberate non-conclusions.** A reference case is one modeller's choices, and
several differences are CONVENTION rather than defect. ACTIVSg2000 models every
machine at its 13.8 kV terminal behind an explicit step-up; we place generators on
the substation bus. It terminates at the distribution substation and therefore
contains no sub-115 kV network at all, so our 364 GW of load outside its band is
reported by the census as an OBSERVATION, explicitly not a gate — it is a
convention difference until something ties it to a defect. The corpus module says
this in its own moduledoc so the caveat travels with the numbers.

**DAT-33 (LOW) [OPEN]** Both reference cases are small (2,000 and 118 buses) and
neither is an Eastern-scale mesh; ACTIVSg2000 has no 345 kV level and case118 no
500 kV. The corpus is honest about order-of-magnitude and presence/absence and
should not be read finer than that. Adding RTS-GMLC or a published planning case
would widen it.

**LIN-18 (MEASURED, HIGH) [OPEN]** New gate: `mix grid.census
generator_interconnection`, the generation-side mirror of `load_placement`. Where
that census gates load against the C57.12.00 delivery ceiling, this one gates
generation against the POI floor observed in the reference cases (115 kV above
25 MW, 138 above 200, 230 above 800 — the LOWEST any reference case uses, so a
flagged bus is one no reference case would produce even at its most generous).
Measured on the live DB 2026-08-22: **574 buses / 87,285 MW below the floor**
(Eastern 322 / 45.4 GW, Western 206 / 25.3 GW, ERCOT 46 / 16.6 GW) and **24,961 MW
of generation on a bus with no branch at all**.

Two design decisions, both of which the obvious version got wrong and only the
reference corpus revealed:
- **The metric is POI voltage, not degree.** "Generation on a bus with no line of
  its own" looked like a 54.2 GW finding until the corpus showed 22.4% of
  `case_ACTIVSg2000`'s buses are exactly that, because of the step-up convention. A
  generator bus with no line is normal; a generator whose output has nowhere to go
  after the step-up is not.
- **The comparison carries a 0.95 class tolerance.** 220 kV and 230 kV are the same
  class in different utilities (SCE vs PG&E), and 66 against 69 is the same split one
  level down. The raw comparison flagged 3 buses / 2.3 GW of ordinary Western
  generation. The tolerance is wide enough for a class variant (220/230 = 0.957) and
  far too narrow for a real class gap (115/138 = 0.833).

### DAT-31 CLOSED, DAT-30 gated (2026-08-22)

`mix power_model.reactive_study` is the committed producer the study never had.
Verified faithful against the scratchpad harness it replaces: identical α per
interconnection (0.4297 / 0.625 / 0.1875), identical 1,720 banks, identical
per-interconnection shortfall totals.

`Grid.network_signature/0` stamps the study with a CONTENT DIGEST of the five
tables a power flow reads. **Deliberately not `max(updated_at)`**, which is what
`export_signature/0` uses for its different job: `synthesize_bus_shunts/1` writes
`buses.bs_mvar`, so a table-level timestamp would be invalidated by the study's own
OUTPUT the moment it was applied, and a gate that always fires is a gate everyone
learns to ignore. `bs_mvar`/`gs_mw` are therefore excluded from the digest — they
are what a study produces, not what it consumes — and there is a regression test
whose whole job is that applying a study does not invalidate its own stamp. Cost
measured at 0.26 s over 93k buses / 105k lines / 71k loads.

Enforcement is split on purpose: `ParameterEstimator` WARNS, because a hard stop
inside the ingest pipeline is worse than slightly-stale banks; `Ingestion.Validation`
FAILS, because that is what CI reads and nothing is half-written there. "Unstamped"
warns rather than passing — the 2026-08-19 study was unstamped, and reading that as
fresh is exactly how it reached a network it did not describe.

**Gate-design note, learned by tripping it.** The first version of the reactive-study
gate failed on every database that was not the one the study was derived on —
including every fresh checkout and every CI run against an un-ingested database.
It broke two existing validation tests immediately, which is the cheap version of
the lesson. A study can only be stale RELATIVE TO a network, so a database with no
buses now reports `:skipped`, not `:error`. Stated because the same trap was already
avoided once in the same change, in a different form (a `max(updated_at)` signature
would have been invalidated by the study's own output) and was walked into anyway
from the other direction: **a gate that fires when nothing is wrong is one people
learn to route around, which costs more than the gate was ever worth.**

**Method note — a broken unit propagated into an experiment, not just a report.**
The first repair run's Eastern "tie" arms reported `alpha = 0.0` in ZERO seconds
and were discarded, not believed. Cause: the tie target (bus 65674) came from a
distance query using `ST_Distance` on `geometry`, which returns DEGREES; every
distance rounded to `0.00 km` and the "nearest" bus was arbitrary. 65674 is in
ERCOT, 312.6 km away, so the arm added a cross-island branch and the solver threw
on every bisection step. Casting to `::geography` gives metres and the real
neighbours.

Two things worth keeping from that. First, the tell was the CLOCK, not the number:
a 59,826-bus island cannot bisect in zero seconds, so the arm was structurally
impossible before it was wrong. The re-run prints a warning when an arm finishes
under five seconds for exactly this reason. Second, a bad measurement does not
stop at being a bad number — this one silently chose the design of the next
experiment. The 0.00 km readings were visible on screen and looked like rounding.

A second target (bus 71740) was then rejected before spending compute on it: it is
an Eastern bus 31.4 km away, but it sits in a FRAGMENT rather than the simulated
island, so the arm would have thrown the same way. Island membership is now
asserted in the harness before an arm runs.

### OSM verification of the POI census, and what it says about the floor (2026-08-23)

**The vendored line snapshot does not cover the flagged yards, for a structural
reason.** Only 10 of the 574 below-floor yards (3.0% of their MW) were queried by
the 2026-08-18 line pull, and only 1 of the top 25 by MW has any snapshot way
within 400 m. That pull queried "the 6,066 yards left UNMATCHED by the substation
pass" — it was scoped to fill VOLTAGE gaps. These yards mostly have voltage; what
they lack is CIRCUITS. Different gap, different query. (The no-branch population
fares better at 32.2% of MW, because those yards were more often unmatched.)

**Probe: 25 largest flagged yards, one Overpass request, 600-1000 m radius.**
10 of 25 have an OSM circuit at or above their POI floor within 1 km — 9,210 of
22,654 MW, **40.7%**. Confirmed cases include yard 6150 (2,055 MW, model escapes
at 130.5 kV, OSM shows 765 kV at 230 m) and 72209 (1,884 MW, escapes 138 kV, OSM
shows 345 kV at 450 m).

**The other 15 are the more useful half, and they indict the floor rather than the
network.** Eleven are cases where OSM AGREES with the model: yard 70528 carries
1,175 MW and escapes at 138 kV, and the best OSM circuit within a kilometre is
also 138 kV. Same for 71182 (1,082 MW), 74844 (1,052 MW, 115 kV), 67901, 22833,
62519 and others. Those plants really do interconnect below the floor this census
applies. Four more have no voltage-tagged way within 1 km at all — unknown, not
confirmed.

**CORRECTION, same session, from a capacity cross-check: the "OSM agrees" group
are NOT false positives.** The hypothesis was that those plants interconnect at
138 kV over SEVERAL circuits and are therefore fine. Measured against the summed
rating of every branch at each bus, they are not fine — bus 70528 carries
1,082 MW on ONE 200 MVA branch (5.4x), 75342 carries 640 MW on one 116 MVA branch
(5.5x), 75222 1,052 MW on two branches totalling 358 MVA (2.9x). Across the 23
generator buses at the 25 probe yards, **19 are tight or stranded on escape
capacity and 13 are stranded outright.**

So the census names the right buses and mis-names the DEFECT at about half of
them. Two distinct failures, both "HIFLD has too few circuits at this plant":
- a missing HIGHER-VOLTAGE circuit (the 10 OSM-confirmed cases), and
- missing PARALLEL circuits at the voltage the plant really uses (the rest).

As a screen for "this plant cannot export its output through the modelled
network" the precision is therefore ~83%, not the 41% the voltage test alone
suggests. The 41% figure — which this entry and the census moduledoc briefly
carried as *the* precision — measures only the first failure mode. Both documents
now say so.

**The floor does still over-read at the top band, and the reason is in the
corpus's own limits (DAT-33).** The >800 MW → 230 kV band rests on TEN plants
across `case_ACTIVSg2000` and `case118`, neither of which contains a 138 kV level
paired with a large plant — ACTIVSg2000 runs 115/161/230/500 and case118 runs
138/161/345. Real US practice interconnects large plants at 138 kV routinely,
usually over SEVERAL circuits, which the census cannot see because it reads only
the single highest escape voltage.

**Consequences, taken deliberately rather than by patching the number:**
- The census stays a SCREEN, not a verdict: 574 flagged is not 574 confirmed
  defects. But the measured hit rate for "cannot export its output" is ~83% at
  the top of the list, and the census must report WHICH defect it found rather
  than assuming the voltage one. Both figures now live in the moduledoc.
- OSM is the VERIFIER. Flagged AND an OSM circuit above the floor nearby = a
  confirmed missing circuit with a named way to go and find. That intersection,
  not the raw flag list, is the work list.
- Escape CAPACITY and escape VOLTAGE are different tests and neither subsumes the
  other. `mix grid.census stranding` already scores generation against summed
  branch ratings; it sees the parallel-circuit defect and is blind to voltage
  class. Running the two together is what separated the failure modes above, and
  is how the "multi-circuit plants are fine" hypothesis got killed in ten minutes
  instead of surviving into the roadmap.

**No-branch population, from the EXISTING snapshot (2026-08-23, inconclusive by
construction — recorded so it is not re-run as if it were).** 346 of the 804
generation-with-no-branch yards (8,046 MW) were covered by the 2026-08-18 line
pull. A tagged OSM circuit lies within 1 km of 67 of them (1,841 MW, 22.9%).

That 22.9% is NOT a statement about OSM's coverage of these yards: the snapshot
was pulled at a **120 m radius**, so a circuit 500 m from a yard is absent from
the file unless it happened to sit near some other queried yard. The number is
bounded by the old pull geometry. Answering the question properly needs these
yards re-pulled at the wider radius the flagged-yard pull uses.

What IS informative is the shape of the hits: where a circuit is found its voltage
matches the bus's own exactly (69→69, 23→23, 34.5→34.5, 115→115, 230→230). Those
are CONNECTIVITY defects rather than missing-circuit defects — the circuit exists
in OSM at the right level and the ingest simply did not attach the bus to it,
which is a different and cheaper repair than finding an absent circuit.

### The 145 confirmed repairs are worth ZERO on α — and that is the finding (2026-08-23)

All 130 OSM-confirmed repairs that land in a simulated island were applied in
memory, in two arms, and re-bisected:

| | confirmed in island | MW | control | line-only | full (bus+xfmr+line) |
|---|---|---|---|---|---|
| Eastern | 66 | 12,093 | 0.4297 | 0.4297 | 0.4297 |
| ERCOT | 17 | 5,789 | 0.6406 | 0.6406 | 0.6406 |
| Western | 47 | 6,224 | 0.2031 | 0.2031 | 0.2031 |

Not one bisection step, anywhere, in either arm.

**Verified against a positive control before being believed.** The same harness,
same code paths, adding the tie already known to move ERCOT (58121 → 72395,
345 kV, 29.5 km) reproduces α 0.6406 → 0.7188 — and so does the synthesized
high-side-bus variant, so BOTH repair paths are detectable. The flat result is a
property of the network, not of the experiment.

**What it means: α is weakest-link, and only repairs at the BINDING bus move it.**
This is consistent with everything else measured this week — the peel experiment
held Eastern at 0.4297 through six rounds; `vm_floor_count` is 1 in Eastern and 3
in ERCOT. The two repairs that DID move α were both at or beside the binding
element (Eastern's 73688 reclass +10.9%, ERCOT's 58121 tie +12.2%). The 145
confirmed missing circuits are somewhere else, so they buy nothing.

**Consequences, and they redirect the work:**
- The productive loop for α is **find the floor bus → repair it → re-measure →
  find the next one**, using `Solution.vm_floor_bus_ids`. It is NOT bulk defect
  repair, and a census — any census — cannot substitute for it. Each round buys
  ~10% and exposes the next constraint.
- `mix grid.census generator_interconnection` remains worth having, for MODEL
  FIDELITY: 145 yards with a named OSM way above their floor are real data
  defects, and a plant exporting through a circuit that does not exist misplaces
  flows in every contingency. That is a different and still valuable claim from
  "this raises the ceiling", and this entry exists so the two are never conflated
  again.
- LIN-17 is refined a THIRD time. "Single-element data defects at specific yards"
  is right; "the flagged yards are those elements" is wrong. The binding elements
  are wherever the voltage floor bites, which so far has been a 6.5 MW load pocket
  (Eastern) and a plant switchyard (ERCOT) — one of which the census never flagged
  because it holds no generation at all.

**And the ERCOT +12.2% tie is NOT evidence-backed.** Yard 70023's OSM evidence is
a single 69 kV way at 10 m — which AGREES with the model's 69 kV escape and
CONTRADICTS the model's own 345 kV bus at that yard. So the honest reading of that
experiment is "if this plant had a 345 kV tie, α would rise 12.2%", not "this
plant is missing a 345 kV tie". It was framed as a hypothesis test when run and
that framing holds, but the label matters.

**DAT-34 (MED) [OPEN]** New candidate defect class from the above: yard 70023
carries a 345 kV bus in the model with ZERO 345 kV branches, while OSM shows only
69 kV there. A spurious high-side bus is the mirror image of the missing one that
127 of the 145 confirmed yards have, and both come from voltage inference at
ingest. Worth a census of its own — buses at a voltage level with no branch at
that level and no OSM support for it.

### Self-review of this week's work — three bugs found in it (2026-08-23)

Reviewing the eight commits above rather than trusting them.

**BUG 1 (CORRECTNESS, fixed) — the network digest could not see a NULL move
between columns.** `Grid.network_signature/0` built its md5 from
`concat_ws('|', col::text, ...)`, and `concat_ws` OMITS null arguments rather
than emitting an empty field. So `('100', NULL, '-50')` and `('100', '-50',
NULL)` render identically as `100|-50` and hash the same. Verified in psql:
`md5(concat_ws('|','1',NULL,'x')) = md5(concat_ws('|','1','x',NULL))` is TRUE.
Not hypothetical — 27 in-service `transmission_lines` carry a null in these
columns today, and `generators.q_max_mvar`/`q_min_mvar` are adjacent and both
nullable. The comment in the code asserted the opposite ("NULLs are rendered as
the empty string"), which is how it survived being written. Fixed with
`coalesce(col::text, '')`; regression test pins it and was confirmed to FAIL
against the old form before being kept.

**BUG 2 (CORRECTNESS, fixed) — the POI floor was derived on the wrong basis.**
`Reference.poi_floor_kv/1` maps plant MW to a voltage, and the census scores
`generators.p_max_mw`, which in this schema is NAMEPLATE. But the table was
derived from the MATPOWER parser's `p_max_mw`, which the parser explicitly sets
to the DISPATCHED Pg. `case_ACTIVSg2000` sums to 96,292 MW of Pmax against
68,725 MW of Pg — a 1.40x basis error — and 34 of its 390 plants sit in a
different POI band under one basis than the other. So the census was comparing
one plant's rating against another plant's dispatch.

Fixed by carrying `p_nameplate_mw` alongside in the parser (additive, unread by
any solver) and deriving the table from it. **The derived bands come out
IDENTICAL** — `[[25, 115.0], [200, 138.0], [800, 230.0]]` — because the floor is
a MINIMUM and moving plants between bands rarely moves a minimum. Recorded that
way rather than as a fix that changed the answer: the bug was real, the reasoning
was wrong, and the output happened not to move.

**BUG 3 (CONSISTENCY, fixed) — introduced while fixing bug 2.** Moving
`generation_mw_share_by_poi_kv` to nameplate left
`generation_mw_share_by_bus_kv` on dispatched Pg, so the corpus briefly carried
two generation metrics on two different bases. Both now go through one
`nameplate/1` helper, and the artifact records `generation_basis` explicitly so
a reader never has to infer it.

**Not fixed, judged not worth it:** `Reference.stats/0` reads and parses the
artifact on every call, so the census's ~9,600 `poi_floor_kv/1` calls cost about
0.6 s. Measured at 0.072 ms per call against a multi-minute run whose cost is
dominated by 574 spatial KNN queries. A cache would need invalidation to stay
correct across `mix grid.reference_stats`, which is more machinery than 0.6 s
justifies. Documented in the moduledoc instead.

**Also documented, not changed:** this census is DB-wide and has no `--graph`
flag, unlike its siblings. That is right for a data-quality census, but its
totals overstate what any solve sees — of the 145 OSM-confirmed yards, 130 fall
in a simulated island and 15 do not. The moduledoc now says so, since comparing
its totals against a solver result without intersecting is an easy mistake.

### Code review of the week's work — 15 findings, triaged (2026-08-23)

Ran `/code-review` over the eight commits after self-reviewing them, and it found
things the self-review missed. Two of my own findings (the double
`network_signature/0` call and the `concat_ws` NULL collision) were already fixed
in the working tree while it read, so it excluded them.

**FIXED — correctness:**
- **Compensation leaked through island splits.** `Partition.split/1` rebuilt each
  island from a fixed key list and dropped `:load_compensation` while forwarding
  `:dc_ties`. A published MATPOWER case stamped 0.0 measured 0.0 solved whole and
  **0.382 solved through `solve_islands`** — the exact double-count the stamp
  exists to prevent, 38.2% of published Qd compensated away. This was a hole in
  the compensation work shipped three days ago, in the one seam built to stop it.
- **A migration called a deleted function.** `synthesize_line_end_reactors/0` →
  `synthesize_bus_shunts/1` left migration 20260816120001 raising
  `UndefinedFunctionError` on every fresh `mix ecto.migrate`. Nine migrations here
  call into `lib` and a rename cannot break them at compile time, so the fix is a
  test that extracts fully-qualified calls from every migration and asserts each
  is still exported — confirmed to FAIL against the old name before being kept.
- **`nil >= 500.0` is TRUE** (atoms sort above numbers), so
  `LoadEstimator.class_ceiling(nil)` returned 1000.0, the MOST permissive ceiling,
  making a voltage-less bus the most attractive load and datacenter target in the
  network. `cap_class_ceiling/1` already chose conservatively for the identical
  case — two implementations of one idea disagreeing. Same trap in `candidates/0`
  and `DatacenterPlacement.eligible/6`. Latent: zero NULL `base_kv` rows today.
- **`class_ceiling(-5.0)` and `interconnection_floor_kv(0.0)` raised MatchError**
  from documented public API. Both now answer conservatively.
- **The reactive study could write a fake measurement.** `ceiling/1` returns the
  low end of the bisection, so "nothing converged" is 0.0; scaling to 0.0 zeroes
  every injection, the flat case converges trivially, no bus can be pinned, and
  the task wrote an empty bank list and exited 0. `solve!/2` cannot catch it
  because the zero solve DOES converge. Now raises.
- **Campus MW vanished silently.** `split_fill/2` placed what it could and dropped
  the remainder, while `search/6` widened the radius only when NO yard was
  eligible — never when eligible yards existed with too little headroom. A campus
  reported as mapped, `unmapped` stayed 0, and `Datacenter.power_mw` no longer
  equalled the sum of its load rows. The search now widens on partial placement,
  and a campus that still cannot be placed in full is reported in `partial:` and
  warned about with the MW that has no home. Live fleet re-checked: 19,715.0 MW
  requested, 19,715.0 placed, 0 partial.

**FIXED — performance, both mine:**
- `gen_q_by_bus/2` used `Enum.at/2` on a ~90k list per generator bus — about
  2×10⁸ list cells on Eastern, twice per interconnection. Inverts `bus_index`
  once now.
- `warn_stale/2` computed the full five-table md5 signature on every
  `capacitor_bank_targets/1` call, to emit a warning the pipeline is documented as
  continuing through. Counts only now; the full digest stays in the hard gate.

**FIXED — process:** `mix format` was failing on `shunt_capacitor_test.exs`, so
`mix precommit` was red on this branch.

**OPEN, with reasons:**
- **DAT-35 (FIXED 2026-08-23)** `generator_support_targets/2` subtracted the RAW
  load-bank requirement rather than the bank actually installed: a 69 kV bus
  wanting 600 MVAr installs 100 (its class ceiling) and one wanting 0.8 MVAr
  installs nothing, yet both had the raw figure deducted from their measured
  shortfall — crediting them with support that does not exist and leaving them
  no top-up. Now clipped through `bank_target_mvar/2` first. Residual stated in
  the code rather than hidden: the class ceiling is applied again to the SUM of
  both components, so a bus near its ceiling can still have slightly more
  subtracted than finally installed — bounded by the ceiling, where the
  raw-vs-installed gap was not. The docstring's Western/ERCOT coverage figures
  were taken with load banks OFF and are unaffected; any figure measured with
  `@load_compensation` non-zero predates this and should be re-taken.
- **DAT-36 (FIXED 2026-08-23)** Headroom was tracked per BUS while `eligible/6`
  picks one bus per YARD, and which level it picks depends on the campus's own
  floor — so a small hall and a large campus kept two independent ledgers at one
  station. NOT latent, contrary to the first triage: measured on the live fleet,
  yard 77032 carried 100 MW at 120 kV and 350 MW at 360 kV, 450 MW of delivery
  from one substation. Now keyed by `yard_key`, the way
  `LoadEstimator.candidates/0` has always done it. After: 0 yards receive load
  at more than one bus, 19,715.0 MW requested and 19,715.0 placed.

  The regression test needed a genuine TWO-LEVEL substation to reproduce — the
  first version passed against the buggy code because the fixture had one level,
  where `bus_id` and `yard_key` are 1:1 and the two ledgers cannot diverge. With
  a 69/230 kV yard it fails at 440 MW against the old ledger and passes at 400
  with the fix.
- **DAT-37 (LOW)** The stale-shunt cleanup widened from `bs_mvar < 0.0` to
  `<> 0.0`, so the old guarantee "capacitor banks are never touched" is now scoped
  to `@reactor_excluded_sources` (`matpower` alone). Intended under the new
  one-column ownership model and documented there, and checked safe today — all
  1,288 positive-shunt buses are this pass's own output — but the guarantee that
  replaced it is much narrower than the one it replaced.
- **DAT-38 (FIXED 2026-08-23)** `OSM.run/1` wrote `tmp/osm_unmatched_yards.csv`
  on a DRY run, contradicting its own "with `apply: false` nothing is written"
  contract and mutating a shared checkout for anyone previewing the pass. The
  write is a fetch input for the next apply run, so it is now gated on `apply?`
  and the dry run says what it WOULD write instead.
- **DAT-39 (LOW)** `with_reach/1` fires one PostGIS query per flagged bus, and the
  `EXISTS` predicate defeats the KNN index the `<->` ordering is written for. A
  few hundred flagged buses means minutes. One `LATERAL` would do it in a round
  trip.
- **DAT-40 (LOW)** Two hand-rolled geodesy helpers where
  `HIFLD.EndpointMatcher.haversine_km/4` exists, and `format_kv/1` copied verbatim
  between `BusMapper` and `OSM.Matcher` — the copy feeds `source_id`, so a
  divergence duplicates every retargeted yard with no compile-time signal.

### The α loop, run: it is 1-2 elements per interconnection, then the MODE changes (2026-08-23)

The week established that α is weakest-link. The open question was whether that
means five fixes or five hundred. Running the loop — solve at the ceiling, read
`vm_floor_bus_ids`, neutralise the worst-parameterised branch on it, re-measure —
answers it, and the answer is neither.

| | α before | α after | neutralisations | why it stopped |
|---|---|---|---|---|
| Eastern | 0.4297 | **0.5156** (+20.0%) | 1 | no floor bus at the new ceiling |
| ERCOT | 0.6406 | **0.7188** (+12.2%) | 2 | no floor bus at the new ceiling |
| Western | 0.2031 | 0.2031 | 0 | **no floor bus at its ceiling at all** |

The "repair" is deliberately the weakest defensible one: set the branch's
impedance to the MEDIAN for its own voltage class, computed from the island's own
population. It is not a claim about the real circuit — it asks "if this branch
were merely TYPICAL rather than extreme, where would the ceiling be", which is
what decides whether chasing the real data is worth it.

**The elements are extreme, not marginal.** Eastern's line 77986 is 69 kV,
48.8 km, x = 0.4612 pu — **12.6x its class median of 0.0365**. ERCOT's 72922 and
73149 are 10.2x and 10.6x. These are not close calls.

**ERCOT's round-1 floor bus is 58121** — the 525 MW plant on a 345 kV yard with
no 345 kV lines. Neutralising one of its 69 kV export paths buys +12.2%, the
SAME figure a synthetic 345 kV tie bought. Two framings of one constraint: the
plant's export path is the binding element, and it does not matter whether you
fix it by giving the plant the circuit it should have or by making the circuit it
does have plausible.

**The loop is short because the failure MODE changes, not because the network
runs out of bad elements.** After one or two repairs `vm_floor_bus_ids` comes
back EMPTY — the solve still fails, but no bus is pinned at the voltage floor.
So that instrument diagnoses the first one or two constraints per
interconnection and then goes quiet, and a different one is needed past it.

**Western never had a floor bus.** Its ceiling is not set by a weak bus at all,
which is consistent with the diagnosis wave's attribution (local generator
reactive exhaustion, 22% of gen buses pinned at q_max) and with the closing
cycle's finding that 13.1 GVAr of banks moved Eastern zero steps. Three
interconnections, three mechanisms — and only two of them are visible to this
instrument.

**What this means for planning:** the α work is NOT a large repair programme. It
is one or two named elements per interconnection, worth 12-20% each, followed by
a different problem that needs a different diagnostic. ROADMAP's "budget it per
round, not per defect" was right; the round count is 1-2, and the next question
is what fails when no bus is on the floor.

### What fails when no bus is on the floor — three signatures, one shared surprise (2026-08-23)

The α loop left `vm_floor_bus_ids` diagnosing only the first one or two
constraints per interconnection before going quiet, and Western never had a
floor bus at all. Instrumenting the failing solve directly — residual by
equation, which bus carries it, how many machines are at a reactive limit —
gives three DIFFERENT answers:

| | failure | residual at the failing step | worst bus | gen at q_max |
|---|---|---|---|---|
| Eastern | reactive | 10.8 MVAr / 2.7 MW — tiny, one bus | 74129 | 26.5% |
| ERCOT | reactive | **994 MVAr / 404 MW** — system-wide | 68327 | 35.6% |
| Western | **active** | 8.6 MW / 0.8 MVAr — tiny, no floor bus | 88550 | 14.2% |

Eastern's ceiling is one bus missing its Q equation by 5.1 MVAr — the same bus
74129 the floor instrument named, so the two agree. ERCOT's is two orders of
magnitude larger and spread across the island. Western's is ACTIVE-dominated and
has no floor bus at all, which is why the floor instrument was silent there.
Three mechanisms, and only two of them are visible to the tool built for it.

**The shared surprise: reactive pinning is universal, not Western's alone.** At
their CONVERGED ceilings, 26.5% (Eastern), 35.6% (ERCOT) and 14.2% (Western) of
generator buses are already at `q_max`. The diagnosis wave attributed reactive
exhaustion to Western and impedance to Eastern; the pinning is in all three, and
what differs is whether it is the BINDING constraint. Eastern is pinned heavily
and still fails locally on one bus; ERCOT is pinned hardest and fails globally.

**CAS-28 (MEASURED, HIGH) [OPEN] — α measures solvability, not operability, and
the gap is large.** The converged solutions at these ceilings are operating
points no system would run:

- Eastern converges with **Vm min 0.6163** and 17 buses under 0.90 pu
- ERCOT converges with **Vm min 0.7448** and **90 buses** under 0.90 pu
- Western with 0.8615 and 9

This repo's own UVLS arms at 0.92/0.89/0.86 pu, so `Failure.LoadShedding` would
shed load to escape the exact state the ceiling is measured at. Every α figure
in this document therefore answers "how much load can the solver find a root
for", not "how much load can the network carry" — and those are not close. Any
coverage claim derived from α inherits the gap.

**CAS-28 MEASURED (2026-08-23) — and the answer is worse than "α overstates".**
`mix grid.census loadability` scores each interconnection against a TWO-SIDED
voltage band instead of bare convergence:

| | solvable (historical α) | emergency 0.90-1.10 pu | normal 0.95-1.05 pu |
|---|---|---|---|
| Eastern | 0.4297 / 123,635 MW | α 0.02-0.25 / 71,931 MW | **none** |
| ERCOT | 0.6406 / 27,839 MW | α 0.2-0.3 / 13,037 MW | **none** |
| Western | 0.2031 / 16,914 MW | **none** | **none** |

**No interconnection can hold every bus inside the normal band at any load
scaling.** Eastern and ERCOT do have an emergency-band window — at 58% and 47%
of their solvable ceilings respectively — and Western has none at all: it cannot
keep every bus inside 0.90-1.10 pu at ANY α.

(An earlier draft of this entry, written before Eastern's run finished, said
"two of three have no load level with an acceptable profile". That overstated
it: two of three DO have an emergency-band window, and what is universal is the
failure to reach the normal band. Corrected rather than left standing.)

Eastern's normal-band failure is narrow and two-sided in the same way: at its
emergency floor of α 0.02 the profile is 0.9113-1.0523, so it misses 1.05 on the
UPPER bound at light load and 0.95 on the lower at heavy load. Western's is not
narrow — it reaches Vm 1.5 with 167 buses over 1.10 pu as α approaches zero.

**Method error found and fixed in the same session, worth recording.** The first
version bisected each band from zero and returned α = 0.0 for `normal`
everywhere. That was the METHOD, not the grid: bisection from zero assumes
monotonicity — if α works, everything below works — and an upper bound breaks
it, because at LIGHT load the network overvolts on line charging with nothing to
absorb it (Western reaches Vm 1.5 with 167 buses over 1.10 pu as α → 0). A
two-sided criterion defines a WINDOW with a floor and a ceiling, and a bisection
starting below the floor finds nothing and calls it zero. The banded rows are
now scanned on a coarse α grid and reported as the feasible interval.

This also explains why the single-sided α reads as high as it does: it only ever
tested the undervoltage side, on a network that fails from both. LIN-13 recorded
"Western fails from BOTH sides" on 2026-08-15 and the ceiling metric never
reflected it.

**What this changes.** The reactive substrate — charging, shunt plant,
impedances, generator capability placement — cannot hold a normal operating
profile at any loading on any interconnection, and cannot hold even an emergency
one on Western. That is upstream of every voltage-layer and cascade result. It
is a bigger finding than the α ceiling it replaces, and it makes the
reactive-planning work (switched shunts, ULTC, capability curves) the
load-bearing item rather than an optimisation.

The emergency windows also give the first defensible coverage numbers this repo
has had: Eastern 71,931 MW and ERCOT 13,037 MW are load levels at which the
model holds a profile a real operator would tolerate under contingency. Those,
not the solvable α, are what a cascade result should be quoted against.

**CAS-29 (BUILT + MEASURED, 2026-08-31) — controllable reactive plant: switched
shunts and LTC taps as an outer loop, and what the normal band looks like with
them.** CAS-28 said the reactive substrate cannot hold a profile because nothing
in it MOVES. `PowerModel.Solver.VoltageControl` is the layer that moves:
capacitor and reactor steps at every bus the rules place them on, LTC taps on
every voltage-crossing transformer, all switched on local voltage in an outer
loop around `FDPF.solve/2`. The substrate objection ("no data") turned out to
be weaker than recorded: every transformer in the live model is stamped high
side = `from` (14,374 of 14,374, zero exceptions, all taps nominal), so an LTC
prior is unambiguous, and the plant already in `bs_mvar` — 38.7/4.8/21.8 GVAr
of synthesized reactors and 5.6/2.6/0.4 GVAr of generator-support banks — is
switchable equipment that had been modelled as a constant.
`mix grid.census loadability --controls` is the acceptance instrument.

| | solvable | emergency 0.90-1.10 | normal 0.95-1.05 |
|---|---|---|---|
| ERCOT, fixed plant (CAS-28) | 0.6406 / 27,839 MW | α 0.2-0.3 / 13,037 MW | none |
| **ERCOT, controls** | **0.6719 / 29,199 MW** | **α 0.02-0.5 / 21,729 MW** | **α 0.15-0.2 / 8,691 MW** |
| Western, fixed plant | 0.2031 / 16,914 MW | none | none |
| **Western, controls** | **0.2109 / 17,563 MW** | **α 0.05-0.2 / 16,656 MW** | none |
| Eastern, fixed plant | 0.4297 / 123,635 MW | α 0.02-0.25 / 71,931 MW | none |
| **Eastern, controls** | **0.4766 / 137,129 MW** | **α 0.02-0.3 / 86,317 MW** | none |

ERCOT is the clean result: the emergency band now holds from the lightest grid
point to α 0.5 — 21.7 GW, 67 % more than the fixed-plant window — and the
normal band, which no interconnection reached before, holds at α 0.15-0.2 and
misses by 2-5 buses out of 5,748 through α 0.4. Fresh per-α point solves show
the same: `out[0.90,1.10] = 0` at every α from 0.02 to 0.5, versus 27-65 buses
uncontrolled at the light end and 36 at α 0.5. Western, which held NO α at
either band with fixed plant, holds the emergency band over α 0.05-0.2 —
16.7 GW, 95 % of its solvable ceiling — with 555 MVAr of switched reactor in
and 142 taps moved; its normal band is still out of reach, 70-90 buses at
every α, on the same 115/230 kV subtransmission that the pocket below sits in.
Eastern's emergency window grows a grid step, 71.9 → 86.3 GW (+20 %), and its
solvable ceiling 0.4297 → 0.4766 (+11 %) — a bigger move than 130 confirmed
OSM circuits bought it (LIN-17: zero steps), because this is the first change
that acts at the binding buses rather than around them. The uncontrolled rows
were re-run under the restructured census and reproduce CAS-28's numbers
exactly.

**Eleven rules, every one of them a measurement.** The first version of the
loop made things WORSE on every interconnection (Western α 0.2: out of band
9 → 48, then a diverged round), and each rule in the module's docs is the fix
for a specific measured failure. The ones that mattered most:

- *Taps alone make it worse; reactors alone settle in one round.* Isolation
  runs at Western α 0.2: reactors 97 → 33 out of band in one round; LTCs at
  four steps/round 97 → 106 with the EHV side rising 1.127 → 1.231. A tap only
  redistributes; shunts supply. Hence shunts first, one tap step per round.
- *Capacitor steps at weak buses diverge FDPF, and the self-susceptance
  strength estimate cannot see a weak radial pocket* (a bus with three short
  lines inside a pocket hanging on one 32-km line looks strong). Hence the
  no-overshoot rule — a move that carries its bus across the band is undone —
  and step-halving down to an 8-way split before a device is latched.
- *LTC blocking, both ways.* With the rules above, the normal-band count
  improved but the MINIMUM voltage got worse everywhere (Western α 0.2 0.873 →
  0.815; ERCOT α 0.4 0.900 → 0.818), with 12-26 taps run to 0.90 lifting low
  sides a var-starved high side could not supply — the LTC voltage-collapse
  mechanism. And at light load the mirror image: ERCOT 138 kV buses at 1.06
  in the base case ended at 1.157 AFTER control, because the taps under them
  ran to 1.10 pulling their low sides down and shedding the absorption the
  138 kV side depended on. Utilities fit LTC blocking on transmission voltage
  for exactly the first; the second is the same rule with the sign flipped.
  With both: ERCOT α 0.4 Vm min 0.900 → 0.944 and max 1.115 → 1.058 at α 0.1.

- *Discretisation and attribution, the last two.* With every rule above,
  Western still held a 500 kV cluster at 1.127 pu at α 0.05 and 0.2. Two
  causes, both mine: bus 73810's 185 MVAr of charging against a stamped −111
  MVAr reactor truncated to ONE 100 MVAr step the stamped reactor already
  occupied (steps now cover the capacity exactly); and a diverged round of 8
  capacitor steps plus 10 reactor steps latched all 18, the innocent reactors
  included (the back-off now retries the absorbing moves alone and halves the
  offenders instead of latching them). With both: Western α 0.05 emergency
  violations 165 → 0 (Vm max 1.389 → 1.067), α 0.2 Vm 0.873-1.127 →
  0.906-1.063.

**Continuation is not capability.** A scan that carries device positions
upward from α 0.02 left 1-2 ERCOT buses outside the normal band at 0.15-0.25
where a fresh solve leaves none — hysteresis from an unphysically light start
(α 0.02 is 870 MW for all of ERCOT). The census therefore solves each grid
point fresh and uses continuation only to seed the ceiling bisection, where a
cold solve diverges before any device can act.

**The St. George pocket (Western), found on the way.** Western's 1.5 pu at
light load is not distributed: it is a 147-bus region (55 at 69 kV, 34 at 138,
30 at 115, 21 at 230) around bus 62631 whose ONLY in-service connection to the
rest of the interconnection is transmission line 67217 — a 32.5 km, 69 kV-class
Dixie Escalante REA circuit (x 0.31 pu) — and the same bus 55628 at its mouth is
Western's floor bus at α 0.3 (Vm 0.6247). Both of Western's failure ends are one
topology defect. OSM has Red Butte as a 345/138 kV station 39 km away (HIFLD
stamps it 345/115 with no 138 kV bus in the model), so the pocket's real tie is
a 138 kV network the model lacks. Controls now hold the pocket inside the
emergency band at light load (every one of its 147 buses), but nothing in
this layer can feed it at heavy load — its mouth is still Western's α floor —
and that is a data repair, ROADMAP item 2's loop, and the next Western move.

**The cascade runs it, opt-in.** `Cascade.init/3` takes `voltage_control:
true`: devices are derived once from the base snapshot (a bank must not shrink
as the cascade sheds load), each island's AC solve gets its share and resumes
the positions its previous segment settled at through
`record.ac_voltage.control_state`. Off by default, so every existing cascade
number is unchanged; nothing has been re-measured under cascades with it on
yet, and that measurement — not this census — is what should decide the
default.

**What is not done.** Device placement is rule-derived, not ingested — the
rules are in the module and every number above depends on them (peak
multiplier 1.75, class step sizes, the 2 % strength guard, 100 % reactor
compensation ceiling, the 0.95/1.05 blocking thresholds); a sensitivity pass
over those is owed before any of it is called calibrated. Reactor devices
exist only at ≥ 230 kV, so a 138 kV region with a var surplus at light load has
nothing to absorb it except the LTC block; that is where the remaining
light-load normal-band misses sit.

**CAS-29 MEASURED UNDER CASCADES (2026-09-01).** Same snapshot, same initiating
N-1 (the worst thermal contingency by MW at risk: ERCOT transformer 4547,
517 % post-outage loading; Western transformer 10433, 477 %), controls off vs
on, at real demand and at scaled load levels where the AC layer actually
solves (loads and nameplate × α, proportional dispatch, both arms identical).

| | off | on |
|---|---|---|
| ERCOT α 1.0 (43.5 GW) | budget_exhausted / degraded; 8,473 MW UFLS; 46 lines + 5 xfmrs | **identical** outcome and trips; in the two fragments that solve AC, 465 MVAr of stamped caps switched OUT, Vm max 1.335 → 1.036, the two `voltage_violation` events gone |
| ERCOT α 0.5 (21.7 GW) | settled / degraded; served 16,932 MW; **550 MW UVLS**, 4,246 MW blackout; 82 undervoltage + 14 underfrequency generator trips | settled / degraded; served 16,951 MW; **1 MW UVLS**, 4,777 MW blackout; 0 undervoltage + 96 underfrequency trips |
| ERCOT α 0.4 (17.4 GW) | settled / **degraded**: 3 MW of UVLS at Vm 0.906 | settled / **intact**: 0 MW, Vm min 0.923, 93 taps + 70 MVAr |
| Western α 1.0 (83.3 GW) | settled / intact, 7 lines + 2 xfmrs | identical |
| Western α 0.2, 0.15 | settled / intact in one step (the trip is benign at this load), Vm max 1.126 / 1.127 | identical outcome; Vm max 1.064 / 1.071 with 642 / 737 MVAr of reactor in |

Three readings. (1) At real demand the layer is INERT on the main island —
FDPF does not converge there (LIN-13), so no device ever gets a converged
operating point to act on, and the headline cascade numbers are bit-identical
with it on; it acts only in the small fragments that do solve, and there it
does the right thing. (2) At a load level the network can carry (ERCOT α 0.4)
the fixed-plant cascade sheds load through UVLS that a network with switched
plant would not — `degraded` becomes `intact`. Three megawatts, but the
mechanism is exactly the one CAS-28 predicted. (3) At ERCOT α 0.5 the served
load is the same to 0.1 % but the PATHWAY changes: the 550 MW of UVLS and the
82 generators lost to undervoltage vanish, and the same 96 generators are lost
to underfrequency instead, with 531 MW more island blackout. The voltage
pathway was standing in front of a frequency deficit; holding voltage does not
create the megawatts the island is short. Cost: 1.5-10× wall time on
AC-solving steps (ERCOT α 0.5: 11 s → 34 s).

**Default decision:** stays OFF. It cannot change a real-demand result until
the main island has an AC solution at real demand, and the scaled-load
evidence, while in the right direction, is one contingency on two
interconnections. Turn it on for what-if studies at loadings inside the
controlled emergency window; re-decide when item 1's external target (2011
Southwest, a Western light-load event) is runnable both ways.

**CAS-30 (BUILT + MEASURED, 2026-09-01) — no AC solution at real demand because
the load is carried on branches at multiples of their rating; the parallel
circuits inferred from that flow give ERCOT its first AC solution at real
demand.** CAS-29's cascade A/B ended on "the layer is inert at real demand
because the main island has no AC solution there". This entry is why, and the
fix.

**The diagnosis is the DC flow, which always solves.** At the reference hour
with nothing out of service:

| | rated branches over 100 % | over 200 % | overload |
|---|---|---|---|
| ERCOT | 218 of 7,465 | 26 | 22,097 MW |
| Western | 135 of 22,155 | 18 | 12,030 MW |
| Eastern | 335 of 79,673 | 34 | 37,989 MW |

The worst are 69 kV lines carrying 300-520 MW on 116 MVA ratings (ERCOT line
79903 at 449 %), 138/69 kV transformers at 250-340 %, New York City 138 kV
circuits at 900 MW each (East Astoria-Corona, Corona-Jamaica), Turkey Point's
230 kV tie at 1,291 MW on 402 MVA, and — Western's #1 and #2 — the St. George
pocket's own tie (CAS-29): 496 MW through a 100 MVA transformer and a 116 MVA
69 kV line. A 69 kV line does not carry 520 MW, and the real grid carries this
load today, so a branch at several times its rating with nothing out of
service is a MODELLING GAP — capacity the real grid has along that corridor
and the model does not (HIFLD carries no circuit count; a double-circuit
tower is one record; a missing 138 or 230 kV path leaves its 69 kV neighbour
doing its work) — not an overload. It is also CAS-26 in a sentence: the
"binary contingency regime" is what a network looks like when a seventh of
it is already past its rating before anything happens. And it is why AC
fails: forcing bulk power through subtransmission is the P-V nose, and the
AC floor buses at real demand are 69/115 kV (ERCOT 82 buses under 0.7 pu,
57 of them at 69 kV).

**The pass.** `PowerModel.Ingestion.CapacityInference`: solve the DC flow at a
measured operating point; every rated branch over 80 % gets
`ceil(loading / 0.8)` circuits (series impedance / n, charging and ratings ×
n); iterate until nothing is over; over the peak and latest ingested hours,
take the larger. The count is stored as `inferred_circuits`, the factor is
folded into r/x/b and the ratings exactly as `ParameterEstimator` folds its
per-class `typical_circuits`, and every run unfolds the stored count first —
idempotent, re-runnable. Branches that would need more than 8 circuits are
left alone and named (Eastern 21 at peak, ERCOT 24, Western 3 — St. George's
transformer 422 wants 9): that is misplaced load or a missing corridor, not a
missing parallel, and eight circuits of 69 kV would hide it. Data migration
20260901100001 applied it; `mix power_model.validate` gained an
`at_rest_loading` gate (warns on any rated branch over its rating at rest,
fails above 0.5 %).

What it wrote, at the peak hour 2024-07-15 21:00Z and the reference hour:
ERCOT 1,015 lines + 91 transformers (17.7 % of its in-service lines; 1,761
extra line circuits), Western 599 + 123 (3.1 %; 827), Eastern 3,332 + 473
(4.4 %; 4,417). By class the extra circuits sit at 138 kV (2,047), 230 (1,426),
115 (949), 69 (705), 161 (633), 345 (454), 500 (292). ERCOT's 17.7 % is the
honest measure of how far its HIFLD network is from carrying its own peak.

**What it bought.**

| | fixed plant (CAS-28) | + controls (CAS-29) | + inferred circuits |
|---|---|---|---|
| ERCOT solvable | 0.6406 / 27,839 MW | 0.6719 / 29,199 MW | **1.0 / 43,457 MW** |
| ERCOT emergency | α 0.2-0.3 / 13,037 MW | α 0.02-0.5 / 21,729 MW | **α 0.02-0.9 / 39,111 MW** |
| ERCOT normal | none | α 0.15-0.2 / 8,691 MW | **α 0.3-0.4 / 17,383 MW** |
| Western solvable | 0.2031 / 16,914 MW | 0.2109 / 17,563 MW | **0.4922 / 40,989 MW** |
| Western emergency | none | α 0.05-0.2 / 16,656 MW | **α 0.02-0.3 / 24,983 MW** |
| Western normal | none | none | none |
| Eastern solvable | 0.4297 / 123,635 MW | 0.4766 / 137,129 MW | **0.8984 / 258,490 MW** |
| Eastern emergency | α 0.02-0.25 / 71,931 MW | α 0.02-0.3 / 86,317 MW | **α 0.02-0.6 / 172,634 MW** |
| Eastern normal | none | none | none |

ERCOT solves AC at the full 43,457 MW of real demand — the first time this
model has had an operating point at real demand on any interconnection — and
holds the emergency band to 90 % of it. Western's ceiling more than doubles
(0.21 → 0.49, 41 GW) with a clean 0.93-1.06 profile at the top, and its
emergency window widens to 25 GW. Eastern's ceiling nearly doubles (0.48 →
0.90, 258 GW of 288) and its emergency window doubles to 173 GW — a
coverage figure that, for the first time, is the same order as the
interconnection's real demand. The normal band is still unreached on Western
and Eastern. Under a cascade at real demand the
main island now solves AC (`ac_diverged` 50 → 0), the worst thermal N-1 is a
line at 197 % post-outage rather than a transformer at 517 %, and it settles
`intact` in one or two steps where before it exhausted the step budget with
8,473 MW of UFLS: CAS-26's binary regime is gone on ERCOT. And the control
layer now has something to act on at real demand: controls off leaves a bus
at 0.575 pu and a `voltage_violation`; on, 253 taps and 769 MVAr of banks hold
the island at 0.871-1.041.

**Western's next binding element is not capacity.** With circuits inferred,
its fresh-start AC fails at α 0.4 with 11 buses on the 0.5 pu floor and a
mismatch of 0.14 MVA — a pocket collapsing, not a network. The pocket is a
66 kV load area in the San Bernardino mountains (CAISO; buses 74381, 75046,
76906, 77081, 78283; ~30 MW at α 0.4) whose ONLY feed in the model is a chain
of 33 kV lines — L85410 14.5 km, L85419 13.3 km, L85418 10 km, x 0.60 + 0.55 +
0.41 pu — so 30 MW sits at the P-V nose of 1.5 pu of series reactance. Its
MVA loading is 54 %, which is exactly why an at-rest MW criterion cannot see
it: the impedance, not the rating, is the limit, and the real 66 kV feed is
missing from HIFLD. It is the St. George pattern (CAS-29) at a smaller scale,
and it says what the remaining Western work is: pockets fed through a
lower-voltage remnant, found by the floor buses, repaired by topology. An
AC-driven pass — floor region → its feeding path → infer capacity there —
would automate ROADMAP item 2's loop; it is not built.

**What it is not.** The capacity lands at the same voltage class between the
same buses. Often the missing path is a HIGHER class, so the inferred network
has the right capacity in the right place at the wrong voltage: correct for
flows and for the AC solution, wrong for anything that reads the class of a
circuit. `inferred_circuits > 1` marks every such row so an OSM circuit count
or a confirmed line can replace it. The 80 % threshold, the two hours and the
8-circuit cap are choices; the peak-hour requirement (1,761 ERCOT circuits
against 476 for the reference hour alone) shows the answer depends on the
hour, and a pass over more hours would raise it further.

**CAS-30, second rule (BUILT + MEASURED, 2026-09-01) — the pockets the at-rest
test cannot see.** The San Bernardino pocket above was the general case, not
an exception: with the at-rest circuits in, every remaining AC failure on
Western between α 0.5 and 1.0 was a load area fed through a chain whose
IMPEDANCE, not rating, is the limit — 54 % MVA loading and past the P-V nose.
`CapacityInference.raise_ceiling/2` is ROADMAP item 2's loop automated: step
α upward; when the controlled AC solve fails, take the buses under 0.7 pu in
its last iterate as pockets, and from each pocket's deepest bus trace ONE
series path outward along the largest DC inflow until a source — a bus whose
generation can carry the load the path has picked up, or an EHV bus — then
double the highest-reactance branch on that path until `S_path · X_path ≤
0.2`, the radial loadability criterion. Re-solve; repeat. Refusals are
recorded, not hidden.

Two earlier forms of the loop are worth keeping because they were wrong in
instructive ways. Summing every branch of a meshed 152-bus region as if it
were one radial produced `S · X = 17` and multiplied 219 branches to the
cap — 2,870 phantom circuits and a "ceiling" of 1.0 that meant nothing; the
criterion is only meaningful for a series path, so the walk is one. And
stopping the walk at any bus with a generator made a 2 MW machine a source
and a 1-branch path; a source has to carry what the path picked up. A third,
a units error in the "evidence wins" rule (`S · X` compared against `X`),
silently refused Captain Jack-Sycan 500 kV and two 69 kV lines in eastern
New Mexico until the DB rows said n = 1 and n = 2, not 8.

Measured in memory from the at-rest network:

| | ceiling before | after | fixes | circuits added | refused |
|---|---|---|---|---|---|
| Western | 0.49 | **1.0** | 22 pockets | 448 on 100 branches | 4 |
| Eastern | 0.90 | **1.0** | 2 pockets | 61 on 11 branches | 0 |
| ERCOT | 1.0 | 1.0 | — | — | — |

Western's fixes are what they should be — paths of 4-17 branches at 33-138 kV
with `S · X` brought from 0.6-3.2 to ~0.2, plus two single doublings at 230
and 500 kV — and its refusals are the honest boundary: three regions of
1,024-1,127 MW behind 4-5-branch 69/115 kV paths already at the 8-circuit cap.
A gigawatt does not arrive over 115 kV; those are misplaced load or a missing
EHV corridor, and the pass declines them by design.

**Persisted, then corrected.** Migration 20260901110000 applied `run_ceiling/1`
at the reference hour (Western 14 fixes / 297 circuits, Eastern 1, ERCOT 0;
all three reached α 1.0 inside the pass). The totals then showed four Western
lines at 64 inferred circuits and a transformer at 24: the loop had applied
its 8-circuit cap to what it added in its own run, not to what the at-rest
pass had already stored. A 33 kV line with 64 circuits is what the cap exists
to refuse, so the cap now counts stored × added (a test pins it), migration
20260901120000 rescaled the over-cap rows back to 8, and the pockets behind
them became refusals. The honest census on the capped network:

| | + at-rest circuits | **+ pocket loop, capped** |
|---|---|---|
| ERCOT solvable / emergency / normal | 1.0 / α 0.02-0.9 / 0.3-0.4 | unchanged (no pockets) |
| Western solvable | 0.4922 / 40,989 MW | **0.7422 / 61,809 MW** |
| Western emergency | α 0.02-0.3 / 24,983 MW | **α 0.02-0.6 / 49,967 MW** |
| Western normal | none | none |
| Eastern solvable | 0.8984 / 258,490 MW | **0.9922 / 285,479 MW** |
| Eastern emergency | α 0.02-0.6 / 172,634 MW | **α 0.02-0.75 / 215,792 MW** |
| Eastern normal | none | none |

Western's ceiling went 0.21 → 0.49 → 0.74 across the three passes, its
emergency window 0 → 25 → 50 GW. What refuses at α 0.8 is a 147-bus collapse
whose feeding paths are at the cap: an 857 MW region behind three 69 kV lines,
1.0-1.1 GW regions behind 115 kV. A gigawatt does not arrive over 69 kV.

**Cold starts, and the cascade.** The loop climbs by continuation — each step
from the previous step's voltages and device positions — and the cascade's AC
attempt is one cold solve. Measured on Western: the same capped network holds
the emergency band at α 0.5 and 0.6 from a flat start and diverges from flat
at 0.7 with 147 buses on the floor, while a continuation from 0.5 reaches
0.7. `VoltageControl.solve/2` gained `:ramp` — a load-ramp continuation
(0.5, 0.7, 0.85, 0.95, then the full snapshot), on when the cascade runs with
controls. It cannot reach what the ceiling refuses: the Western cascade at
real demand still runs DC-only (α 1.0 > 0.74), at 45 s instead of 3.5 s.
ERCOT's runs AC. Eastern's now does too: with controls and the ramp its main
island solves at real demand under the cascade (`ac_diverged` 1 → 0, Vm
0.754-1.035 after 9 rounds, 30 taps and 2,973 MVAr of banks), where the
fixed-plant arm runs DC-only — the first Eastern cascade with a voltage
layer at real demand. Its initiating N-1 is the Vogtle tie below, and both
arms lose the same 238 MW island to it. The price is stark: 1,123 s against
11 s, five controlled solves of a 60,000-bus island each running up to forty
device rounds. That is why the layer stays opt-in, and it is the next
solver-cost item — the ramp should carry B′ across rounds and steps rather
than refactorize it, which FDPF's design already allows (SOL-14).

**The refusals are the worklist.** Every refusal names a corridor whose real
supply path — usually a higher class — HIFLD does not carry: Eastern's worst
N-1 at real demand is Plant Vogtle's 230 kV tie carrying 14.6 GW at rest
(1,615 % post-outage) because the model has Vogtle's 500 kV bus with ONE
500 kV line; Western's are the 69/115 kV paths above and Captain Jack-Sycan
500 kV. `data/vendored/ehv_corridor_worklist_2026-09-01.csv` lists them with
coordinates, flow and class, the way the OSM stranded-yard worklist did for
item 24. That, not more inference, is the next Western and Eastern move.

**Twin yards are not the corridor problem (NEGATIVE, 2026-09-01).** Vogtle and
Red Butte both turned out to be one physical station carried as two HIFLD
records the model never ties together — Vogtle's two 500 kV yards 0.6 km apart
with no branch between them, each with its own 500/230 transformer, so the
plant's 4.7 GW leaves at 230 kV — and the count of such pairs is large: 1,825 /
249 / 249 unconnected same-class twins within 1 km at ≥ 138 kV on Eastern /
ERCOT / Western. DR-4's weld phase (`BusMapper.weld_colocated_buses/1`,
250 m) already covers the tight ones; what is left inside the main islands at
250 m is 0 on ERCOT and 2 on Western. So the hypothesis was tested at 600 m,
in memory, unfolding the stored circuits first: ERCOT's 96 twins cut the
at-rest overload 22,097 → 21,999 MW (0.4 %) and the circuits the inference
needs 509 → 506; Western's 396 twins moved the overload the other way
(12,030 → 12,179 MW) and the circuits 376 → 368. Split yards are a real defect
and a negligible cause of the corridors. The corridors are missing lines and
missing higher-class yards, and only OSM evidence names them — which is what
the worklist is for. Two sites had that evidence in hand and were corrected
individually (below); the general weld radius was left at 250 m.

**Two sites corrected from OSM evidence (2026-09-01).** Plant Vogtle: the
model carried two 500 kV yards 0.6 km apart (HIFLD 37107 with the plant's
4,658 MW and the Thomson Primary 500 kV line; HIFLD 40786 with the West
McIntosh and Warthen 500 kV lines) with no branch between them, each with its
own 500/230 kV transformer and the 230 kV yards tied — so the plant and two
of its three 500 kV circuits reached the third through 230 kV, and line
109468 carried 14,639 MW at rest. OSM way 863571818 is one "Vogtle 500KV
Switchyard" whose busbar ways span both HIFLD positions. Red Butte: HIFLD's
yard 58560 carries 345 and "115" kV; OSM's is 345/138 with no 115 level, and
the 138 kV yard the model DOES have (63596, 130 m away, three ST GEORGE-RED
BUTTE 138 kV lines, the double circuit OSM way 173899732 shows) had no path
to the 345 kV because the 345/138 transformer landed on the mislabelled bus.
Migration 20260901130000 ties Vogtle's 500 kV yards, reclasses Red Butte's
bus and line to 138 kV and welds it to the 138 kV yard, then re-runs both
capacity passes from scratch (`run/0` unfolds every stored count first).
Record: `data/vendored/osm_corridor_corrections_2026-09-01.json`.

Re-measured on the corrected network (both passes re-derived): **Western's
controlled ceiling 0.7422 → 0.9922 — 82,628 MW, 99 % of real demand** — and
its emergency band α 0.02-0.6 → 0.02-0.75 (49,967 → 62,459 MW). One
transformer landing on the wrong bus was the binding element of an
interconnection; the pocket loop had been inferring 69 kV circuits around it.
Under a cascade at real demand Western's worst thermal N-1 now cascades to a
settled, non-binary outcome — 3 steps, a generator frequency trip, 499 MW of
UFLS — where before the trip was benign; the ramp solves the main island AC
(4 AC islands to 2) at 301 s against 13.5 s.

Vogtle was necessary and not sufficient. With its 500 kV yards tied, line
109468 still carries 14,318 MW at rest (was 14,639) and remains the worst
Eastern N-1 at 1,280 % post-outage (was 1,615 %): the 230 kV corridor is
standing in for a 500 kV path the model does not have at all. OSM names it —
Vogtle-Wadley 500 kV (way 160057254) — and the model's Wadley carries 230,
130.5 and 115 kV buses and no 500 kV yard. Adding a yard is a bus, a
transformer and a line; it is the first entry on the worklist that needs
more than a tie, and the next Eastern move. ERCOT is unchanged by any of
this (no pockets, no twins at 250 m). Eastern's census is unchanged by the tie (solvable 0.9922 / 285,479 MW, emergency α 0.02-0.75 / 215,792 MW), which is the same finding from the other side.

## External denominators (EXT)

**EXT-1 (MEASURED, HIGH, 2026-09-01) — the model's congestion is not where the
ISOs' congestion is, and the at-rest capacity inference erased the part that
was.** The first external score this repo has had. Two real records:
ERCOT's SCED binding transmission constraints, every 5-minute run the MIS
listed (2026-08-28 to 09-01, 12,265 rows, 92 distinct constraints; ERCOT's
listing expires in a day, so the flattened pull is committed), and MISO's
real-time binding-constraint reports for 2024-12-25 to 2025-01-01 — market
date 2024-12-31 is the model's reference day — 4,723 rows, 35 binding
branches, 30 named contingency elements. Method (`scripts/score_congestion.py`,
model side `mix power_model.loadings`): each real element's stations are
geocoded through OSM's named yards (ERCOT's are internal short names — SNDSW,
WAP, STP — matched by stripping suffixes and subsequence), located in the model
as buses within 1.5 km at the class, and looked for as a path of ≤ 4 branches
at that class. The instrument's own coverage is the first limit: 31 of 80
ERCOT elements and 29 of 57 MISO elements geocode at both ends.

| | ERCOT (different dates) | MISO (same day) |
|---|---|---|
| real elements geocoded both ends | 31 / 80 | 29 / 57 |
| exist in the model | **23 (74 %)** | **11 (38 %)**; 16 yards absent at class |
| model DC loading of those, median | **20 %** (real: at 100 % of limit) | **36 %** |
| percentile rank among all model branches, median | 22.5 % | 3.8 % |
| in the model's top 5 % | 6 / 23 | 6 / 11 |
| on inferred capacity (n > 1) | **6 / 21 lines** | 0 / 11 |
| reverse: model's top-30 loaded branches with both yards among real constraint stations | **1 / 23** | 0 / 7 |

Three readings. (1) *Existence is decent on ERCOT and poor on MISO*: 16 of
29 located MISO elements have no model bus at the class within 1.5 km — the
"nobus" class is missing yards (CANADIAN RIVER 345, WATSEKA 138, CRANDALL
345, WILTON CENTER 765), worklist material of the Wadley kind. (2) *Loading is
wrong almost everywhere*: the elements that bind at 100 % of their limit in
the real market sit at a median 20 % (ERCOT) and 36 % (MISO) in the model,
and the model's own most-loaded branches — Exxon-Baytown 138, Channelview-
Greens Bayou 345, Battle Creek-Argenta 345, Monticello-Sherburne 345 at
70-77 % — appear in neither ISO's list. The model concentrates flow on EHV
corridors and industrial ties; reality binds on specific 69/138/161 kV lines
and 345/115 transformers. (3) *The inference erased the part the model got
right.* Six of the 21 ERCOT lines found sit on inferred capacity, and their
single-circuit-equivalent loadings — the loading the model had BEFORE the
at-rest pass gave them circuits — are 222 % (Frontera-S. Mission 138 kV,
ERCOT's most frequent constraint, 480 binding intervals), 204 % (Bruni 138,
410), 138 % (Seagoville 138), 90 %, 88 %, 66 %. The raw network was overloaded
at rest exactly where ERCOT's market is congested; CAS-30's rule read that as
missing capacity and gave them 2-3 circuits. It was not missing capacity. It
was a real transmission constraint that the real market manages by
re-dispatching generation, which this model has no mechanism for: its
dispatch is placed by BA and fuel and never asked whether a branch can carry
it. A branch over its rating at rest is therefore one of two things — capacity
the model lacks, or a real limit the real grid operates at — and the at-rest
pass cannot tell them apart. The ISO records can.

**What this changes in the plan.** (a) `CapacityInference` must not add
circuits on branches an ISO reports as binding: the vendored constraint
records become an exclusion list with provenance, and the six ERCOT branches
are unfolded. (b) The missing operating-point mechanism is
transmission-constrained re-dispatch — a generation shift against branch
ratings (the repo's LODF/PTDF machinery is the sensitivity it needs; the
economics ROADMAP's salvage note rejected are not required) — which is what
would reproduce real binding patterns AND remove the need to infer capacity
at real bottlenecks. It goes ahead of the reactive-layer calibration. (c) The
"nobus" yards join the corridor worklist. (d) The score is re-run after each
of those; its coverage (31/80, 29/57) is itself a target — ERCOT's station
short names need a proper dictionary, which the ERCOT network model
publishes.

**EXT-2 (BUILT + MEASURED, 2026-09-01) — transmission-constrained re-dispatch,
and what the congestion score says about it.** EXT-1's finding was that the
model's dispatch never asks whether a branch can carry it, so a real limit the
market operates AT reads as an overload the capacity rule then "fixes".
`PowerModel.Dispatch.Redispatch.relieve/2` is the missing mechanism: B′
factorized once, then per iteration the DC flow, the worst overloaded branch,
its PTDF row in one cached solve (`LODF.sensitivity_batch/2`), and MW moved
from the units pushing flow onto it hardest to the units relieving it most,
in equal amounts, until it is at its rating. No costs — feasibility, the
minimum the real grid does. Pair effectiveness decides the move
(sensitivities are relative to the slack, whose unit reads zero; the pair
slack↓ / B↑ is perfectly effective, and the first version excluded it).
Opt-in in `Cascade.init(constrained_dispatch: true)` and
`CapacityInference.run(redispatch: true)`; `mix power_model.loadings
--redispatch` dumps the constrained operating point.

First, the exclusion list alone (migration 20260901140000: both capacity
passes re-derived with the 34 ISO-reported elements never given circuits):
with the
list keyed on HIFLD `source_id` (30 of 34 rows; the first emit predated the
column and excluded nothing — caught because the re-derivation changed
nothing, which a working exclusion could not have done), the found binding
elements sit on inferred capacity **0/23** (was 6/23), and the raw truth
returns: Frontera-S. Mission reads **223 %** at rest, Bruni **204 %**,
Seagoville 137 %. The controlled census does NOT move (ERCOT solvable α 1.0,
emergency 0.02-0.9): a thermal overload is not an infeasibility, so honesty
here cost nothing. Stored extra circuits: ERCOT 1,761 → 1,749.

Then the constrained operating point (`--redispatch`): 4 iterations,
**1,424 MW shifted, 2 branches relieved, 2 residual**. Per element:
**Bruni 204 % → 100.0 %** — at its limit, which is what "binding" means, and
what ERCOT's market shows 410 times in four days; Seagoville 137 % → 97 %;
**Frontera 223 % → 110 %, residual** — the shift ran out of effective units,
and that too is faithful: the Rio Grande Valley is import-constrained, which
is why it is ERCOT's chronic congestion. Mean found-element loading 45 % →
35 %; the model's top-30 with both yards among ERCOT's constraint stations:
1 → 3.

**What is fixed and what is not.** The six known bottlenecks now behave like
the market's: overloaded at rest, held at their limits by re-dispatch. The
DISTRIBUTION is still wrong — the median found element loads 21 %, the other
20 of 23 sit far from binding, and 27 of the model's top-30 are still not
real constraints. That residual is the operating point itself (BA-fuel
dispatch; C1's CEMS unit-level dispatch is the next lever) and the
instrument's coverage (31/80 geocoded). Re-dispatch is opt-in everywhere
(`constrained_dispatch: true` on `Cascade.init/3`, `--redispatch` on the
loadings, `redispatch: true` on the capacity pass) until measured under
cascades.

**EXT-3 (MEASURED, 2026-09-01) — blackout-size distribution vs OE-417
(ROADMAP item 27).** `mix power_model.cascade_ccdf`: random initiating
outages over the main island's rated branches at real demand, one cascade
each, the lost load's complementary cumulative distribution and an MLE tail
exponent against the published OE-417 blackout-size law (α ≈ 1.31). ERCOT,
150 samples per arm, seed 7, plain and `--constrained`.

**N-1: every sample settles.** Terminations 150/150 `settled` in both arms —
the step budget is never exhausted, so CAS-26's runaway mode ("a contingency
either settles at zero or runs away past the budget") is measurably gone on
ERCOT. 138/150 fully intact (132 constrained), largest single event 26 MW
(80 constrained), zero events ≥ 100 MW: no tail exists under single
contingencies. That is not by itself a failure against OE-417 — real
single-element events rarely make the report either — but it means the
N-1 ensemble cannot test the tail. Constrained dispatch trades a handful of
intact outcomes for small sheds (12 → 18 degraded): moving flow off the
real constraints spends margin elsewhere, in tens of MW.

**N-2: still no tail — and that is the finding.** Simultaneous pairs, same
seeds: 150/150 settle, 113 and 112 fully intact, q99 72 MW, at most one event
reaches 100 MW; OE-417's distribution reaches gigawatts on a power law. The
model has swung from CAS-26's binary regime ("a seventh of the network past
its rating at rest; a contingency either settles at zero or runs away") to
the opposite defect: almost nothing propagates. The reason is visible in the
at-rest numbers — after the capacity inference, zero rated branches are over
100 % and the fleet median loading is low, so an N-2 rarely pushes anything
past a rating, and thermal cascading needs stress to propagate. Reality's
fat tail comes from a grid operated NEAR its limits with re-dispatch holding
dozens of constraints at 100 % — which is exactly the operating point EXT-2
reproduces at six branches and the BA-fuel dispatch fails to reproduce
anywhere else. Caveats: initiating events here are branch trips only (no
generation or weather losses), one hour, one interconnection, 150 samples.

**What EXT-3 orders next.** The tail will not appear from more samples; it
needs the operating point: (a) C1's unit-level CEMS dispatch plus EXT-2's
re-dispatch as the DEFAULT operating point, so the fleet of real constraints
sits at 100 % the way the market's does; (b) the congestion score's coverage
(31/80) so the exclusion list grows toward the real constraint set; then
re-run this instrument. Its value today is the regime diagnosis, and that
CAS-26 is closed on ERCOT: no initiating pair exhausts the step budget.

**EXT-4 (BUILT + MEASURED, 2026-09-01) — measured unit dispatch (ROADMAP C1),
and the first blackout-size tail.** EXT-2 ended on "the distribution is still
wrong" and EXT-3 on "the tail needs the operating point"; both fingered the
same suspect, the BA-fuel dispatch, which spreads each fuel's measured MW over
a merit order the model invented. C1 replaces the invention with measurement:
EPA's continuous emissions monitors (CEMS) report gross load per fossil unit
per hour, keyed by the ORIS id that IS `eia_plant_id`, and the vendored
reference day (2024-07-15, nationwide, 3,990 units, 89 % of ERCOT's fossil
capacity) covers the model's peak hour. `Ingestion.Epa.Cems` reads it at
local STANDARD time — verified against EIA-930's ERCO gas shape (r = 0.992
at UTC−6 vs 0.929/0.956 at ±1 h), not assumed — and `Dispatch` pins each
measured plant to the measured shape. The division of authority is strict:
EIA-930 still owns every (BA, fuel) total (which also absorbs gross-vs-net
without a per-fuel constant), CEMS owns the shape inside it; units the
monitors watched sit idle stay OFF even when the merit order wants them, and
unmeasured units fill only the residual. Opt-in everywhere (`cems: true`,
`--cems`) until measured end to end.

**The congestion score moves at both ISOs.** ERCOT, same records and
instrument as EXT-1/2, baseline vs measured dispatch: median found-element
loading **20 % → 54 %** (mean 45 → 61 %), median percentile rank 22.5 % →
9.7 %. Four of ERCOT's real named constraints — Bruni (193 %), Seagoville
(183 %), Frontera (172 %), La Palma–Haine Dr (132 %) — now show up overloaded
in the model WITHOUT being told where they are; under EXT-2 the model had to
be handed their locations as an exclusion list before their overloads even
appeared. On La Palma–Haine Dr the model's 224 MVA rating brackets ERCOT's
own enforced limit (213–229 MVA in the SCED records): the remaining error
there is flow concentration, not the rating. Re-dispatch on the measured
point relieves the model's ARTIFACTS (a Permian 69 kV line at 560 % → 101 %,
a 138/69 transformer 122 % → 22 %) and cannot relieve the real four — 3,782
MW shifted, none of them moved — which is the market's own experience of
those constraints: they bind because no re-dispatch room is left on a July
peak. MISO's winter-week records score a summer hour poorly in either
direction (median 34–36 %), which is season mismatch, not signal: against a
freshly pulled season-matched July week (2024-07-09..16, 151 constraints, 85
geocoded, 34 in the model — richer than the winter set), the same move
appears: median **29 % → 48 %**, top-5 % membership 14 → 15 of 34.

**The lesson of EXT-1 recurred and was closed the same day.** 12 of the 34
July MISO elements sat on inferred capacity — the exclusion list only knew
the winter week, so the at-rest pass had "fixed" the July constraints'
real limits. The July matches (57 rows, both ISOs) are now
`known_binding_elements_2026-09-01_jul.csv` and both capacity passes were
re-derived (migration 20260901150000; ceilings stayed at 1.0, one extra
circuit in Eastern — honesty again cost nothing). Post-derivation the MISO
score moves from good to right: median found-element loading **62 %** (mean
72 %), median rank 2.8 %, 20 of 34 in the model's top 5 %, and the reverse
direction lights up for the first time — **7 of the model's top-30 loaded
branches have both yards among MISO's constraint stations** (0 before C1,
0 after C1 alone). ERCOT re-scored unchanged (median 54 %, 0/23 on inferred
capacity). The exclusion list is not a static artifact; it grows
with every record set the scorer can reach, and re-derivation is part of
ingesting one.

**The tail exists now (item 27).** `mix power_model.cascade_ccdf`, ERCOT,
150 samples, seed 7, at the PEAK hour (EXT-3's arms ran at the winter latest
hour — stress matters even before dispatch does: plain N-2 q99 is 2.1 GW at
the peak vs 72 MW there). N-1: both arms 129/127 intact, q99 464/205 MW, ≤ 2
events ≥ 100 MW — still no tail under single contingencies, as OE-417 itself
would predict. N-2, measured dispatch: **10 of 150 events ≥ 100 MW and the
MLE tail exponent fits: α = 1.48, against OE-417's published ≈ 1.31**
(plain N-2 at the same hour: 5 events, below the fit floor). P[≥ 1 GW] =
3.3 %, P[≥ 10 GW] = 0.7 %, outcomes 108 intact / 42 degraded, terminations
150/150 settled (the N-1 measured arm had the session's only budget
exhaustion, 1/150 — CAS-26 stays closed, now with one asterisk). A first
fittable tail 0.17 above the published exponent, from 150 doubles at one
hour of one interconnection, is not agreement yet — but EXT-3's diagnosis
("the OE-417 tail is absent because almost nothing grows; the operating
point is the missing propagation mechanism") is now measured as TRUE: the
same instrument, same seeds, same network found the tail the moment the
fleet ran where the monitors saw it run.

**Caveats, honestly.** One vendored day (the reference day) — other hours
run unpinned by design; facility timezones are state+longitude approximate
(boundary plants can read one hour off); plant gross is apportioned to units
by capability (units of a plant share a bus, so flows barely notice); CEMS
covers fossil ≥ 25 MW only — nuclear/hydro/wind/solar stay on the BA-fuel
path; and the cascade's base-overload exclusion means the four real
constraints, overloaded at rest, are never themselves trip candidates — the
measured tail is if anything understated. Next: the scorer's geocoding
coverage (31/80 ERCOT), the Permian 69 kV through-flow artifacts the
measured dispatch exposed (branches 84309, 281180, T8927 — 1.9 GW routed
through subtransmission is a topology error, not congestion), and only then
the question of flipping `cems` + re-dispatch to default.

**CAS-31 (FIXED + MEASURED, 2026-09-01) — two yard complexes whose 345 kV
secondaries HIFLD carries as 69 kV.** EXT-4's first honest operating point
exposed the model's two worst overloads, and neither was congestion: ~2 GW
crossing North McCamey's yards on a 69 kV jumper at 560 %, and ~1.3 GW
crossing Eagle Mountain's on a synthetic repair weld at 201 %. OSM says the
voltage level the flow was crossing at does not exist: LCRA North McCamey is
345/138 (not HIFLD's 345/69), AEP North McCamey is 138-only, and the Eagle
Mountain complex is a 345 kV yard beside 138 kV yards with no 69 kV level
anywhere — both repair lines and both "69 kV" buses there touch nothing
real. HIFLD's 69s are inferred minimums. The correction (migration
20260901160000, evidence and priors in
`osm_corridor_corrections_2026-09-01b.json`) invents no equipment: the
misclassed secondaries become 138 kV — their existing transformers become
the real 345/138 banks — the ties are re-parameterised at 138 kV and
re-pointed to the real 138 kV buses, and McCamey's 69 kV chain hangs off the
AEP yard's HIFLD-asserted 138/69 transformer. Both capacity passes
re-derived; ceilings held at 1.0.

**What the fix did and did not do.** The congestion score is unmoved (median
53 %, the four real constraints unchanged) — removing fiction did not game
the instrument. The blackout-size tail moved TOWARD the published law:
N-2 measured-dispatch α = 1.48 → **1.39** on 11 events (OE-417 ≈ 1.31), all
150 samples settled — the kv fiction was suppressing tail mass. Honestly
still open: the corrected ties are STILL the top overloads (369 % and
225 %), now attracting even more through-flow at the lower impedance —
either a busbar-vs-line rating question (a 0.2–0.5 km intra-complex tie
rated as an ordinary 138 kV line) or missing parallel 345/138 injection
elsewhere in the region.

**And the systematic finding underneath.** Chasing the third suspect (T8927,
1.46 GW through a 138/69 transformer, 5 inferred circuits) found ~1.75 GW of
Colorado Bend CCGT sitting on a DEAD-END 69 kV bus — EIA-860 records those
plants' grid interconnection at 138 and 345 kV. Measured against EIA-860's
grid-voltage column across the fleet: **184 GW of in-service capacity
(11.7 % Eastern, 21.9 % Western, 26.8 % ERCOT) sits at least a full voltage
class below its recorded interconnection voltage**, including 4.5 GW plants
injected at 230 kV instead of 500. The bus mapper attaches plants to a
yard's lowest level. Under the BA-fuel dispatch this mattered little; under
measured dispatch every misassigned plant rams real MW through phantom
transformers. Generator bus assignment by EIA grid voltage is the next
correction pass.

**CAS-32 (FIXED + MEASURED, 2026-09-01) — generator bus assignment by
EIA-860 grid voltage, and what re-deriving at the honest operating point
taught about the at-rest rule.** CAS-31's systematic finding, closed:
EIA-860's plant-level "Grid Voltage (kV)" — where each plant actually
interconnects — said 184 GW of in-service capacity sat at least a full
class below it, because the bus mapper attached plants to a yard's lowest
level. The column now rides on every generator (`grid_voltage_kv`; Form860
sets it at ingest; migrations 20260901170000/170001 backfilled 15,983
plants / 26,854 generators — NOTE the plant file is a downloaded input, not
committed, so on a checkout without it the data migration no-ops and the
backfill belongs to the next ingest). The placement floor takes the value
as evidence that REPLACES the size heuristic, not merely raises it: the
first pass ran with max(size, evidence) semantics and stranded Colorado
Bend I — 608 MW recorded at 138 kV, size floor 230, no 230 kV bus within
reach — on its dead-end 69 kV bus; under replace semantics it landed on the
138 kV bus 0 m away. `remap_stranded_generators/1` (unchanged, still
strict-improvement-only) moved **1,014 plants, 2,025 generators, 162 GW**
of ~12,880 examined: Vogtle's 4,530 MW back at 500 kV, Crystal River at
500, Colorado Bend I at 138. Colorado Bend II (1,143 MW, recorded 345)
stays honestly stranded — no 345 kV bus exists within the search radius —
and joins the worklist. Ceilings held at 1.0 through every re-derivation.

**Honesty about the congestion score.** The re-map SOFTENED it, and partly
should have: Bruni's 193 % organic overload fell to 31 % — it was largely a
plant-misplacement artifact, right for the wrong reason (ERCOT's actual
Bruni record is BRUNI_69_1, a ~35 MVA 69 kV element; the scorer had matched
the 138 kV line — a matching caveat now on record). Of EXT-4's four organic
real-constraint overloads, two survive the corrections: Seagoville (191 %)
and Frontera (172 %). And the mirror defect is now measured: **547 plants /
144 GW sit ABOVE 1.45x their recorded class, 302 of them (121.6 GW) with an
in-class bus within 3 km** — injection attributed too high softens
subtransmission stress the same way attribution too low inflamed it. The
floor only pushes up; a class CEILING (place AT the recorded level when a
bus exists there) is the follow-up pass, and it also converges the ≤ 157
plants the max-semantics first pass may have over-moved.

**The derivation-regime experiment.** Moving 162 GW exposed that the
capacity passes still derived at the BA-fuel operating point while every
instrument measures at the CEMS one: two Permian 69 kV lines lost their
5 inferred circuits (BA-fuel at-rest flows < 80 % where measured flows
carry 750 MW) and lit up at 646 %. So the passes now dispatch with
`cems: true` by default — and the first CEMS-at-rest derivation taught the
next lesson: the ERCOT score's median fell to 41 % and the N-2 tail thinned
to 8 events, because the at-rest rule reads the measured stress AROUND real
constraints as missing capacity and inflates their parallel paths, which no
exclusion list can guard. The counter is EXT-2's own pipeline, re-dispatch
BEFORE inference ("only what a generation shift cannot relieve is missing
capacity"): derived that way, ERCOT recovers to median 46 %, mean 58 %,
**9/24 found elements in the model's top 5 % — the best yet** — at an
unchanged ceiling, and the cap-refused would-need warnings (9, 9 and 16
circuits on the Permian pair and the Eagle Mountain tie) correctly classify
them as topology gaps, not capacity. N-2 measured-dispatch CCDF at this
state: 5 of 150 doubles reach 100 MW — below the 10-event fit floor — while
q99 GROWS to 2.26 GW, the largest of any state measured tonight. Across the
corrected states the count sits at 5-8 of 150 against CAS-31's 11, so part
of the α = 1.39 fit was borrowed from misplacement stress; the corrected
model keeps gigawatt events and needs a larger ensemble (500+ doubles) for
an exponent it can stand behind. MISO, final state with the model's named yards in the
geocoder: 40 found elements (was 34), median 54 %, rank 4.7 %, 21/40 in the
top 5 %, reverse direction 8/30 — and 2 of the 6 newly found elements sit
on inferred capacity, which is the coverage loop asking for its next
emit-exclude-re-derive round.

Re-dispatch-before-inference is therefore now the derivation DEFAULT
(`redispatch: false` to opt out): its cost measured under a minute of
shifting even on Eastern. ERCOT's ceiling under it is confirmed at 1.0; the
Eastern/Western re-derivation under the new default was still in its ceiling
pass when this entry landed; it has since confirmed — Eastern 1.0, Western
1.0 (400 extra circuits over 84 branches, one unfixable pocket) — so a
fresh replay of the migration chain plus the EIA download reproduces the
dev state.

**Open, deliberately.** Validation's at-rest gate still dispatches
BA-fuel; boundary UTC hours the vendored CEMS day only partly covers pin
per-facility silently; steam-only CEMS units (blank gross, nonzero
operating time) read as OFF and could wrongly idle a cogeneration host's
electric units. All small today, all recorded here so none of them has to
be rediscovered.

**CAS-33 (FIXED + MEASURED, 2026-09-01) — the class ceiling, and round 2 of
the exclusion loop.** CAS-32's floor only pushed plants UP, and its audit
measured the mirror defect: 302 plants / 121.6 GW sitting a full class ABOVE
their EIA-860-recorded interconnection with an in-class bus within 3 km —
injection attributed at EHV that really enters at subtransmission, which
softens exactly the stress the congestion score measures.
`plant_voltage_band/2` now bounds placement from BOTH sides (same 0.7x/1.45x
class margins; the size heuristic keeps no ceiling — it is a lower-bound
argument only), the candidate ranking prefers in-class buses with capacity
still dominating, and the re-map moves an above-class plant down only onto
an in-class bus that can evacuate its nameplate. **201 plants — 837
generators, 93.8 GW — moved down**; the 101 that stayed had no in-class bus
that could carry them, which is the conservative gate working, not a gap.
The same migration (20260901180000) carried round 2 of the exclusion loop:
the geocoder's station source had found 6 more MISO binding elements, 2
already "fixed" with inferred circuits, so their emitted matches
(`known_binding_elements_2026-09-01_r2.csv`, 64 rows) joined the glob
before the single re-derivation. Ceilings held at 1.0 everywhere (Western
absorbed the down-moves with 228 extra circuits over 52 branches, one
unfixable pocket).

**Measured.** The congestion score is STABLE through a 94 GW placement
change — ERCOT median 45 % plain, 48 % at the constrained operating point
(rank 13.6 %, 9/24 in the top 5 %); MISO median 54 %, 18/40 in the top 5 %,
and **0/40 found elements on inferred capacity** — the coverage loop closed
its second round exactly as designed. What DID move is the honest part: the
plain-dispatch overload census grew from 8 to 50 branches, because 94 GW
now stresses the subtransmission it actually enters at, and the market-like
re-dispatch absorbs that back down to 23 (8.1 GW shifted) — the same
division of labour the real grid uses. Seagoville (216 %) and Frontera
(172 %) remain the residual binding pair through every state; the Eagle
Mountain weld reads 289 % constrained and the Permian 69 kV pair sits
cap-refused at 646 % — the same two topology gaps, now carrying more of the
story and still at the top of the worklist. One ERCOT found element drifted
back onto inferred capacity (1/24) — match drift between emit rounds, the
loop's next iteration catches it.

**The 500-double CCDF: the tail matches the national record.** The ensemble
this instrument has been asking for since EXT-3: 500 random N-2 doubles,
seed 7, peak hour, measured dispatch, at the corrected state. 42 events
reach 100 MW and the MLE tail exponent is **α = 1.31 — the OE-417 published
value** (α ≈ 1.31 ± 0.08; ours carries ≈ ±0.05 at n = 42, so
"indistinguishable", not "exact" — the two-decimal coincidence is luck).
The distribution reaches 20 GW (q99), P[≥ 10 GW] = 1.6 %, 359/500 fully
intact. After a day of corrections each of which THINNED a tail that had
been borrowing from artifacts, the honest network with the honest operating
point produces the real one. The asterisk, kept visible: 15 of 500 doubles
exhausted the step budget — 3 % of pairs still run away rather than settle,
so CAS-26's closure holds at N-1 and leaks at stressed N-2; those 15
samples are the next cascade-dynamics worklist.

**Open.** The two topology gaps above; Colorado Bend II's missing 345 kV
bus; the scorer's ERCOT short-name wall; validation's at-rest gate still
dispatches BA-fuel; sim-side `cems`/`constrained_dispatch` defaults for
cascades and the census once the CCDF at scale is read.
