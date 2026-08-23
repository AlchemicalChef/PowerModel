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
- **DAT-35 (MED)** `generator_support_targets/2` subtracts the RAW load-bank
  requirement rather than the bank actually installed, so a bus whose raw Q was
  clipped by `bank_target_mvar/2` (below 1.2 MVAr, or over its class ceiling) has
  more subtracted than exists. Latent while `@load_compensation` ships at 0.0 and
  `load_banks` is empty — but the coverage figures in that docstring were measured
  through this path, so they are suspect.
- **DAT-36 (MED)** Headroom is tracked per BUS but `eligible/6` picks one bus per
  YARD, and which level it picks depends on the campus's own floor — so a 40 MW
  hall and a 300 MW campus can each spend a full class ceiling at the same
  substation, crediting it with 450 MW of delivery. `LoadEstimator.candidates/0`
  consolidates by `yard_key` for exactly this reason; the placer consolidates for
  selection but not for accounting.
- **DAT-37 (LOW)** The stale-shunt cleanup widened from `bs_mvar < 0.0` to
  `<> 0.0`, so the old guarantee "capacitor banks are never touched" is now scoped
  to `@reactor_excluded_sources` (`matpower` alone). Intended under the new
  one-column ownership model and documented there, and checked safe today — all
  1,288 positive-shunt buses are this pass's own output — but the guarantee that
  replaced it is much narrower than the one it replaced.
- **DAT-38 (LOW)** `OSM.run/1` writes `tmp/osm_unmatched_yards.csv` on a DRY run,
  contradicting its own "nothing is written" contract.
- **DAT-39 (LOW)** `with_reach/1` fires one PostGIS query per flagged bus, and the
  `EXISTS` predicate defeats the KNN index the `<->` ordering is written for. A
  few hundred flagged buses means minutes. One `LATERAL` would do it in a round
  trip.
- **DAT-40 (LOW)** Two hand-rolled geodesy helpers where
  `HIFLD.EndpointMatcher.haversine_km/4` exists, and `format_kv/1` copied verbatim
  between `BusMapper` and `OSM.Matcher` — the copy feeds `source_id`, so a
  divergence duplicates every retargeted yard with no compile-time signal.
