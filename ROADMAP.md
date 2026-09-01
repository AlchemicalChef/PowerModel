# PowerModel Accuracy Roadmap — 2026-08-15

Produced by six domain-specialist explorations (solver math, energy systems, cascade/
protection, plants, lines, data), each of which MEASURED the live system — DB queries,
EIA-930 replays, live HIFLD pulls, solver benchmarks, A/B experiments — before ranking.
Companion to REVIEW.md (correctness tracker); this file is about what to BUILD.
Measurement scripts referenced live in the session scratchpad; headline numbers are
reproduced here so the document stands alone.

## The measured state of the model

- **24.3% of all generation sits on the wrong fuel** (total-variation distance, 168-hour
  EIA-930 replay across the 15 largest BAs). The model schedules a constant 532 GW while
  real national demand swings 342–745 GW; ERCOT dispatches 9.8 GW of solar at 4 a.m.;
  PJM nuclear runs 19 GW low with the difference placed on distant wind farms.
- **Two dispatch rules exist and the worse one wins**: the cascade's uniform pro-rata
  (`balance_dispatch`) discards capacity factors entirely (its docstring claims
  otherwise), and it is the rule every simulation actually runs.
- **Primary frequency response is over-delivered 5–16×**: modeled Eastern droop ≈
  14,700 MW/0.1 Hz vs NERC's 923 MW/0.1 Hz obligation; nuclear gets working governors.
  Nadirs are too shallow, UFLS under-fires, cascades settle when they should collapse.
- **The simulated network is a fragment**: Eastern simulates 27% of its geolocated buses,
  Western 16.6%, ERCOT 30.6%. One branch in seven is overloaded at rest (RESOLVED
  2026-09-01: capacity inference, REVIEW CAS-30 — zero rated branches over their
  rating at rest on all three at the peak and reference hours), and base-case
  masking makes 27.6% of ERCOT's 345 kV backbone trip-immune.
- **Stored EHV parameters came from a dead code version** (exactly 2× today's table; a
  500 kV line carries the same 900 MVA rating as a 345 kV) and can never be corrected
  because estimators only fill NULLs.
- **~1,500 GWh/week of phantom battery generation** (ERCOT + CISO); storage never charges.
- **DC solve cost is assembly, not factorization** (dense B′ materialization ≈ 1,500× the
  sparse solve it feeds); a full Eastern DC solve OOMs. The 3,000-bus AC cap is fiction —
  the practical dense-NR ceiling is ~600–800 buses.
- **Topology provenance is thin**: 65% of HIFLD line geometry is flagged INFERRED by
  HIFLD itself (field not ingested); only 22% of lines have real substation names on both
  ends. HIFLD Open was shut down 2025-08-26; ingestion points at an unofficial, unlicensed
  ArcGIS mirror.

## Phased plan (cross-domain synthesis)

Ordering favors accuracy-per-effort and measured dependency; S ≈ days, M ≈ 1–2 wk,
L ≈ multi-week.

> **STATUS 2026-08-16: DATA-REPAIR + UI ROUND LANDED** (ultracode review → 5 DR + 4 UI
> packages + the outcome feature, all adversarially planned and gate-measured):
> - Eastern dispatch −65,100 → −175 MW (−0.07%); ERCOT +7.7% → +1.6%; the UI's first
>   real N-1 (Eastern worst mw_at_risk 582 GW artifact → 10.8 GW real transformer).
> - >90° census 15/1/3 → **0/1/0** (survivor = documented HIFLD source gap);
>   Western FDPF α 0 (no solution) → **0.22**; ERCOT α 0.25 → **0.50**.
> - 8,814 silently-dropped HIFLD circuits restored (94,619/94,619 features ingest);
>   Eastern largest component 80.5 → 89.2%; bridges −5 to −7 pts; stranded nameplate
>   546 → 98.1 GW; Grand Coulee on its 500 kV yard; PDCI phantom 765 kV+ class retired.
> - Load: county-centroid KNN → capability-weighted polygon spread (594.8 GW moved,
>   deg-1 load share T 31.5 → 4.9%); reactance floor 1e-3 → 1e-5 (bit-identical
>   invariance); EHV line-end reactors synthesized (−65.1 GVAr).
> - UI: crash fix (at-limit conductor), payload 2.2 MB → 22 KB client frames, real N-1
>   panel, current+nadir frequency with AGC, H3 voltage-depth overlay with the bus-id
>   channel it needed, collapse-vs-settled outcome through engine→seam→badge.
> - Suite 1,248 → 1,415 tests, 0 failures. Open follow-ups: DAT-22/23/24, ENE-21/22,
>   UI-M17/L14, ERCOT spur 72357 → OSM wave (item 24).
>
> **STATUS 2026-08-15 (later): Phase 2 LANDED** (items 8–13 + ENE-17) with a fresh
> re-ingest from the vendored snapshots. Measured: buses carrying a branch 49.7% →
> **91.7%**; largest components Eastern 27.2% → 80.5%, Western 16.6% → 89.7%, ERCOT
> 30.6% → 87.7%; >5:1 welds 2,989 → 0; kV-mismatch 12.3% → 0.3%; buses without BA → 0;
> unplaced nuclear 24.2 → 1.7 GW; fuel-mix TV 0.096 → **0.0068**; interchange MAE
> −71%; generation coverage 98.5%; all 8 HVDC ties placed; 1,599 branches freed from
> trip immunity. Key data discovery: HIFLD's `UNKNOWN<id>`/`TAP<id>` endpoint names are
> per-yard KEYS (81.5% of endpoints match by name). Consequences: item 18 (sparse DC
> assembly) is now load-bearing for MEASUREMENT — Eastern (51,713 buses) and Western
> (17,265) exceed the dense-solve cap, so their base cases are currently unmeasurable;
> 13,520 no-voltage substations carry placeholder 138 kV levels (REVIEW DAT-21, OSM
> polygons in item 24 are the fix).
>
> **STATUS 2026-08-15: Phases 0 and 1 LANDED** (items 1–7). Measured result via the new
> `mix power_model.validate --legacy`: fuel-mix TV distance 0.293 (legacy proportional)
> → 0.107 (fuel-anchored), a 64% reduction; interchange MAE −42%. The residual 0.107 is
> decomposed as fleet-mapping gap (60.1 GW unplaced, 24.2 GW nuclear — REVIEW ENE-15),
> which Phases 2's connectivity work will drive down, measured by these instruments.
> Caveats: seasonal capability columns exist but are NULL until the re-ingest (dispatch
> caps at nameplate meanwhile); ACTIVSg2000 AC assertions are honestly skipped pending
> Phase 4 (see REVIEW SOL-13 — the Q-limit switching mechanism, not just speed, gates
> them).

### Phase 0 — Make accuracy measurable (S, do first, parallelizable)
1. **EIA-930 replay harness** (`mix power_model.validate`): per-BA fuel-mix TV distance,
   interchange error, served-load error, conservation residual. Seed with the measured
   baseline (24.3%) so every later change is a number, not a claim.
2. **Network accuracy scoreboard** (`mix grid.accuracy`): island counts,
   largest-component share, base-overload rate by voltage class, kV-mismatch census,
   plus an in-memory A/B mode. (Prototypes exist in scratchpad; ~150 lines.)
3. **Ingest-time validation gates**: hour completeness (fixes the boundary-hour default —
   see REVIEW DAT-15/ENE-13), capacity feasibility per BA-fuel, per-BA balance at
   screened hours, eGRID vintage check, topology census golden file.
4. **Solver validation ladder**: MATPOWER `.m` loader; IEEE-118 → ACTIVSg2000 →
   ACTIVSg10k with committed reference JSONs (generate once via MATPOWER/pandapower).
   ACTIVSg license verified open ("free for commercial or non-commercial use").

### Phase 1 — Dispatch realism (the unanimous #1; S–M, no new data)
5. **Hourly per-fuel dispatch from EIA-930**: the 16 per-fuel Adjusted columns are in
   `data/EIA930_BALANCE_2024_Jul_Dec.csv` and currently skipped by the parser. New
   `ba_fuel_hour` table + a Dispatch module allocating each BA-fuel-hour MW across units
   (merit key: capacity factor; honor `p_min_mw`; unallocated units are OFFLINE — zero
   inertia, zero governor). Replaces both dispatch rules. Beware two malformed EIA
   header names ("witho" typo, double space before "(Adjusted)") — exact-match resolvers
   silently miss them.
6. **Interchange-aware targets**: use per-fuel MW as absolute values so BA gen − load =
   real interchange by construction (`total_interchange_mw` is already ingested, used
   nowhere). Fixes fictitious self-sufficiency (BPA exports 137% of own demand).
7. **Seasonal capability + per-unit CFs** (S): summer/winter capacity (nameplate is
   83.1 GW above real summer capability, concentrated in the reserve-providing gas
   fleet); join eGRID per-unit CFACT via the new `generator_id`.

### Phase 2 — Network integrity (M–L)
8. **Recompute-not-fill-NULL pipeline** (M, gates everything here): params_version
   columns; estimators revisit stale rows; unordered-pair transformer key. Measured
   payoff of the EHV refresh alone: Western EHV overloads 22.6% → 10.3%.
    LANDED AND RE-SCOPED (2026-08-16). The versioned recompute stands at
    params_version 3. A blanket impedance recompute has NO TARGETS LEFT: stored x_pu
    already equals the estimator recipe on every row it owns (deviations were the
    write-time clamp) — item 8 cannot be what fixes LIN-13. What the recompute is FOR:
    (a) rating tables (v3 sub-69 kV scaling, 4,091 rows), (b) the write floor aligned
    to the solver's (951 rows), (c) the 8,814 restored circuits arriving at v0. It was
    also a HAZARD: the predicate matched the 5,628 connectivity_repair rows, now
    protected twice. Remaining work is a CENSUS GATE, not a rewrite: empty
    `mix grid.census subtransmission` via DR-4 remaps + DR-5 caps with no x_pu row
    edits; re-baseline after restoration+recompute (offenders tighten ~2.09x on v3).
9. **Emergency ratings driving protection** (S): rate B/C as real schema+migration (the
   dev DB has drifted — columns exist with no migration), relay pickup at rate C instead
   of 100% of rate A; shrinks the trip-immune `base_overloaded` set.
10. **EHV loadability + resistance + derate placement** (S): St. Clair/SIL-capped
    ratings ABOVE 300 kV only (measured: below 300 kV it makes things worse), EHV R
    raised ~2× to physical X/R, ambient derate moved from R (unread by DC) to ratings.
11. **Full voltage-level buses** (M–L): the per-substation voltage list is already
    computed and discarded at ingest; store it, one bus per level, transformers chained
    across adjacent levels, rating read from the true high side (19% currently read the
    wrong terminal). Kills the 3,000 >5:1 voltage welds and 532 EHV endpoints on
    13.8 kV buses; resolves REVIEW LIN-5/LIN-7/LIN-8 and DAT-9 in one change.
12. **Connectivity repair** (L, biggest absolute gain): use the stored-but-unused
    `sub_1`/`sub_2` names as primary endpoint keys, tiered snap radii, post-mapping
    component joining. Target: >80% of buses carrying a branch (vs 16.6–30.6% simulated
    today). Requires the re-ingest that also activates R3's substation-identity fix.
13. **HVDC as scheduled injections** (S–M): curated ~10-tie table (PDCI, Intermountain,
    ERCOT ties…). Note: `line_type='dc'` matches ZERO rows in the live DB until
    re-ingest — the PDCI is still an AC line in the data.

### Phase 3 — Frequency & cascade dynamics (S–M each) — **LANDED 2026-08-15**

> **STATUS 2026-08-15: Phase 3 LANDED** (items 14–17 + REVIEW CAS-15/CAS-16/ENE-19,
> ENE-14 closed in passing). Measured results:
> - **β = ΔP/Δf in the BAL-003 ±30% band on all three interconnections**: Eastern
>   1,961 (anchor 923–2,400 obligation basis), Western 892 (anchor 840), ERCOT 394
>   (anchor 381) MW/0.1 Hz — from a machine-constants table (per-fuel H, governor
>   duty/share, response rates), not tuned per-interconnection.
> - **ERCOT N-1 design contingency (1,375 MW trip): 3,356.6 MW UFLS shed → 0 MW shed**,
>   nadir 59.282 → 59.340 Hz. The reversal comes from ENE-19 (dispatch now holds back
>   contingency reserve on governor-duty units: Eastern 2,600 / Western 2,626 / ERCOT
>   1,375 MW) plus deliverable primary response (item 14) and ramp-limited secondary/
>   tertiary tiers on a real cascade clock (item 16,
>   `step_advance_s = max(relay_advance, frequency_advance)`).
> - Reserve hold-back made fuel-mix TV slightly BETTER (0.009060 → 0.008945): the
>   displaced MW land on p_min-blocked units.
> - **Persistent island frequency state** (item 15): `Frequency.simulate_with_state/4`
>   threads {f, governor state, UFLS stage} across cascade segments; islands inherit
>   state by plurality of load; PRC-024 generator UF/OF trips feed back into the same
>   step's deficit (protection.ex pure envelopes). Deep-deficit islands (≳27%) now
>   collapse through the trip→deficit→trip loop instead of paper-balancing —
>   the missing positive feedback of real blackouts. End-to-end ERCOT reference
>   cascade: 2,653.5 → 582.8 MW shed (the old number was mostly phantom UFLS from
>   restart-at-60.0-Hz double counting).
> - **Storage as duty-cycle charge/discharge** (item 17): SOC-conserving daily
>   schedule, discharge hard-ceilinged by the measured "other" column. Phantom
>   always-on battery energy 27.4 GWh/day → 0; CISO hourly correlation 0.891.
> - CAS-15: `island_dead?` is now "no generation", size-independent (consistent with
>   SOL-3). CAS-16: redispatch draws sustained reserve only, ramp-limited.
> - Follow-ups logged: CAS-18 (event volume at collapse scale), pumped-storage
>   extension, UI surfacing of reserve/collapse state.
14. **Deliverable primary response** (S–M): fuel-specific response-rate caps over the
    nadir window; governor-duty flags (nuclear ≈ none). Validate the β = ΔP/Δf slope
    against BAL-003 FRO per interconnection (±30% is a pass).
15. **Generator protection envelopes + persistent frequency state** (M): PRC-024-shaped
    UF/OF/UV trips fed back into the same step's deficit; `Frequency.simulate` accepts
    initial state so successive trips compound (today every step restarts at 60.0 Hz).
    This is the missing positive feedback of real blackouts.
16. **Ramp-limited reserve tiers on the cascade clock** (M): primary/secondary/
    contingency tiers with per-technology ramp rates; requires fixing the clock
    (non-thermal steps currently advance 0 s). Also fold in: `island_dead?` still
    contradicts SOL-3's single-bus-island fix.
17. **Storage as charge/discharge** (M): SOC state, duty-cycle or "Other"-residual
    schedule; eliminates the phantom GWh and CISO's 15.6% always-on battery dispatch.

### Phase 4 — The voltage chain (M then L)

> **STATUS 2026-08-15: Wave 1 LANDED** (item 18 complete; item 20's protection
> math layer complete, wiring pending Wave 3). Measured:
> - **Eastern DC: unsolvable (dense B′ ≈ 400 GB, 3× machine RAM) → 404 ms
>   median, ~1 GB peak** (51,713 buses / 64,664 branches). Western 29.1 s /
>   45 GB → 92 ms / 339 MB; ERCOT 3.4 s → 27 ms (meets the <50 ms target).
>   Dense path deleted; pure triplet assembly (4 COO entries per branch, slack
>   dropped at emission); numerical equivalence vs old dense path at 1e-11
>   relative. First-ever full Eastern base-case census: 2,223/64,664 branches
>   overloaded (6.7%).
> - **Cached-factorization NIF** (ported by API shape from the pre-reset
>   snapshot, audited: RCM fill-reduction restored, ulp-symmetry panic fixed,
>   residual-verified solves, zero unsafe): `sparse_factor` → handle,
>   `sparse_cached_solve(_multi)`. Eastern: factor 120 ms, cached solve 2.9 ms
>   (42×). The SPD guard lives on the SOLVE residual, not the factor — an
>   indefinite B′ factors without complaint. Handles carry no topology memory:
>   rebuild on every topology change (ideal for FDPF/PTDF, useless for
>   cascade DC).
> - **Protection math layer** (pure, wiring in Wave 3): apparent impedance from
>   power flow (needs per-line Q at the from terminal — NEVER wire against DC:
>   0° angles land inside the PRC-023 blinder wedge = silent universal
>   blocking), mho zones 1/2/3 (0.85/1.25/adjacency-based, 0.05/0.40/1.50 s),
>   PRC-023-4 R1 load blinder on rate C, per-bus timer-integrated UVLS
>   (0.92/0.89/0.86 pu, 8/5/3 s, 5/5/10% — deeper = faster), exact-solution
>   conductor thermal (τ = 12 min; takes rate-A loading, NOT the rate-C basis).
> - Behaviour change: unsolvable large systems now throw instead of silently
>   degrading to a dense path that would OOM. `mix grid.accuracy` default cap
>   dropped (obsolete). Wave 3 wants a "longest line off the remote bus"
>   topology precompute for real zone-3 reaches.

> **STATUS 2026-08-15 (later): Wave 2 LANDED** (items 19 + 21; SOL-13 closed).
> Measured:
> - **FDPF (item 19)**: ACTIVSg2000 AC in 128 ms where dense NR took 347 s /
>   3.2 GB (2,708×), same answer to 8e-9 pu; faster than dense NR at EVERY size
>   measured (2× at 10 buses), cutoff 25 buses chosen for robustness not speed.
>   XB variant; B′ = the DC B′ exactly (shared handle); B″ = −Im(Ybus) over PQ
>   rows, refactorized alone on Q-limit switch rounds. No faer NIF needed —
>   exactly as the plan predicted. Hot paths: compute_power 631 ms → 0.3 ms
>   (Y-bus nonzeros), warm start 15.9 → 0.3 ms, YBus.build quadratic append
>   fixed. **Eastern AC converged for the first time** (51,713 buses, 46 iters,
>   4.8 s) — but only at ≤15% of real demand, which is the finding:
> - **The network, not the solver, is now the AC blocker** (REVIEW LIN-13): at
>   real demand DC needs >90° across 1/3/15 branches (ERCOT/Western/Eastern) so
>   no AC solution exists; Western also Ferranti-overvolts at low load (44 GVAr
>   of charging doesn't scale). ERCOT's nose curve is textbook — the solver is
>   behaving; Phase 2 items 8/10/12 + DAT-21 are the unlock for the whole
>   voltage chain (item 20 wiring is otherwise inert at real demand).
> - **SOL-13 closed with a diagnosis reversal**: the reference (MATPOWER-style,
>   no back-switching) violates complementarity at 48/195 pinned buses; our
>   default policy satisfies it at all 392 and a `:matpower` policy reproduces
>   the reference 191/195 bus-for-bus (losses 0.0151%). ACTIVSg2000 AC tests
>   un-skipped under `:matpower`.
> - **LODF/PTDF screening (item 21)**: exact vs full re-solve to 6e-11 (ERCOT)
>   / 3e-9 (Eastern); full N-1 sweeps 0.3 s / 3.2 s / 63 s for ERCOT/Western/
>   Eastern (~350× one-resolve-each); bridges by Tarjan (27.8–40.9% of branches
>   are bridges — itself a connectivity indictment); multi-outage via exact
>   rank-k Woodbury (sequential compounding measured at 6.5% error and
>   rejected). N-2 delivered (2.2 ms/pair). UI wiring = Wave 3 (UI-M15).
> - **ENE-20 found (HIGH, open)**: Eastern's operating point runs ~65 GW long
>   (gen 300.3 vs load 235.0 GW, slack absorbs −60.6 GW) — its N-1 census
>   currently measures the dispatch imbalance, not the network (top-10 lists
>   share zero entries with a balanced control). Needs a dispatch-side fix
>   before Eastern screening numbers mean anything.

> **STATUS 2026-08-16: Wave 3a LANDED** (voltage ride-through + AGC, both mined
> from the absorbed pre-reset history and standards-verified rather than
> copied). Measured:
> - **PRC-024 voltage envelopes** (cumulative band timers per the standard's own
>   Curve Details — opposite of UVLS drop-out semantics) + **IEEE 1547 BTM
>   voltage trips** (the actual Blue Cut mechanism; 2003 legacy vs 2018 Cat III
>   modern, cause-tagged into the conservation identity's btm_tripped term) +
>   **GFL current-ceiling derate** (min(1, V·1.2/P_set), knee derived not set).
>   Voltage state is intensive: splits conserve timers exactly.
> - **AGC closed-loop secondary** (controls/agc.ex, Cohn B = β from the machine
>   table): ERCOT N-1 now RESTORES 60.00 Hz in 1.8 min (BAL-002 allows 15) and
>   releases all 1,037.7 MW of governor deployment — primary reserve
>   replenished, which the open-loop clock tier never gave back. AGC dispatched
>   1,376.1 MW vs the 1,375 MW trip. β gate pinned to keep measuring the
>   open-loop model (with-AGC β doubles to 620 as secondary MW enters the value
>   window — in band, but a different quantity).
> - Wave 3b (cascade wiring) contracts settled: BTM-voltage-trips-then-UVLS
>   ordering; mark_tripped guard between the two Blue Cut halves; AGC owns the
>   secondary tier island-wide, redispatch keeps tertiary; protection layers
>   read FDPF voltages only, never DC.

> **STATUS 2026-08-16 (later): Wave 3b LANDED — item 20 complete, and with it
> every Phase 4 item except the UI surfacing.** Measured:
> - **The first voltage-driven cascade this model has produced** (ERCOT daytime
>   hour, α = 0.20 / 10.67 GW — the largest AC-feasible load — single
>   highest-flow line tripped): a 62-bus undervoltage pocket at 0.668 pu →
>   17.92 MW of rooftop tripped on voltage across 48 buses (5.37 legacy /
>   12.54 modern, breakdown balanced) → 7 PRC-024 undervoltage generator trips
>   → 69 UVLS blocks by depth → settled in 4 steps / 24.5 s, conservation
>   residual −0.0 MW. IEC overcurrent outruns conductor thermal at 186–324%
>   loading (the two-timescale design working); distance relays evaluated
>   6,964 branches, closest approach 1.007× a zone-3 reach.
> - **Regression at real demand, attributed by kill-switch**: conductor thermal
>   and the whole voltage layer are bit-identical no-ops; AGC is the entire
>   delta. Run to SETTLEMENT (step-budget comparisons of unfinished cascades
>   are invalid — a 50-step read showed a false 10× regression): baseline
>   9,028.8 MW shed / 126 gens / 79 lines / 9 xfmrs in 89 steps vs wired
>   9,213.2 MW (+2.0%) / 106 / 65 / 4 in 70 steps — AGC trades +184 MW shed
>   for 20 fewer machines lost and settlement in half the simulated time,
>   robust under perturbation controls.
> - **Voltage-layer coverage at real demand is 93 of 170 island-solves**: the
>   main island diverges (LIN-13) but every fragment converges — the voltage
>   chain is live mid-cascade TODAY; Phase 2 data repair raises coverage
>   rather than enabling it.
> - Structural guarantees: one writer for the AC layer (no path from a DC
>   solve to a voltage protection), Blue Cut double-count guarded both
>   directions, AGC-secondary/tertiary no-double-draw, UVLS+UFLS accounting
>   exact, intensive voltage timers conserved across splits.
> - Remaining for Phase 4: the UI wave — UI-M15 (real N-1 from
>   ContingencyScreening), surfacing voltage_layer/btm_trip_breakdown/AGC
>   fields, reconciling the display-side AC refinement with FDPF's config
>   (CAS-19 and the new event causes in CAS-17 ride along).

> **STATUS 2026-08-22: VOLTAGE-COVERAGE WAVE LANDED** (diagnosis wave -> four fix
> agents: loads, corridor, compensation, OSM). The wave set out to raise AC coverage
> so the voltage layer stops running on a fragment. Measured (alpha = highest uniform
> scaling of hour-scaled load P/Q AND generator dispatch with an AC solution, bisected
> to 0.01, largest island, FDPF `dense_nr_max_buses: 0`):
> - **Western 0.2313 -> 0.2062, ERCOT 0.5687 -> 0.6375, Eastern 0.3938 -> 0.4313.**
>   The Western number FELL, deliberately: line 67217 was carrying a voltage class the
>   OSM corridor pull contradicts, and correcting it removed artificial support. An
>   alpha series is only comparable within a fixed data vintage.
> - **The central negative result: OSM voltage backfill is NOT the alpha unlock this
>   document carried it as** (item 24 amended below). Measured ceiling-neutral on all
>   three interconnections. What it bought is data correctness -- voltage-blind yards
>   8,404 -> 3,617 -- which is worth having and is a different claim.
> - **The ceiling is three different bugs**, attributed by lever ablation (REVIEW
>   LIN-13 correction): Western = LOCAL generator reactive exhaustion (22% of gen buses
>   pinned at q_max while the island absorbs; qmax10 lever +46%); Eastern =
>   sub-transmission impedance (xcap005 alone +71%, reactive levers ~0%); ERCOT =
>   three super-additive constraints (caps100+freeq10+xcap010 -> 0.9875). Max-lever
>   walls: Western 0.5062, ERCOT 1.4937, Eastern 1.2062 -- ERCOT and Eastern have a
>   reachable alpha = 1.0, Western does not.
> - **Every interconnection's swing is ONE line** (73687/72357/67217, by ablation).
>   The >90 degree census is now 0/0/0; the last DR-wave survivor (72357) resolved as
>   138 kV.
> - **Interface compensation shipped** (`Solver.LoadModel`): Q_net(V) = q0.zip(V) -
>   k.q0.V^2 with k = 0.3822 for an interface pf of 0.98, plus a device split --
>   passive feeders fade as V^2, datacenter campuses (active front ends) hold power
>   factor across voltage. Cascade effect: converts blackout to shed on a 2,702 MW
>   case, +45% voltage-layer coverage, identical total load lost. FDPF needed zero
>   changes (it reaches injections through `NewtonRaphson.scheduled_injections`).
> - **Generator-support banks shipped**, sized from measured shortfall at each
>   island's ceiling and class-capped per IEEE 1036. Fixed LOAD-bus banks were tried
>   and REJECTED on measurement: no AC solution at alpha 0.05-0.10, Vm -> 1.5 pu. A
>   fixed `bs_mvar` cannot represent a switched installation.
> - **OSM pipeline shipped** with an ODbL-clean architecture: `voltage_source` markers
>   on substations AND transmission_lines plus an `osm_substation_matches` evidence
>   table make the OSM-derived portion extractable by construction. The review gate
>   earned its place: a mechanical rule (revert when placed load >= 5 MW AND an
>   incident >= 60 kV non-rederived line is inconsistent with every OSM level) caught
>   the ConEd low-side-tag pattern ("27000;4000" on 138 kV yards) -- 740 yards /
>   20,604 MW reverted, 882 yards / 1,350 MW confirmed.
> - Load placement census fully green afterwards (every gated section zero, from
>   2,518 MW below the load-serving floor); REVIEW DAT-22 closed.
> - **CLOSING CYCLE (2026-08-22, run solo):** load reallocation landed (15,197.7 MW
>   moved, load-placement census fully green, REVIEW DAT-22 closed) and the reactive
>   support study was re-derived against the post-OSM network. Three arms per
>   interconnection on one snapshot: control (reactors only) / incumbent banks /
>   re-derived banks = Eastern 0.4297 / 0.4297 / 0.4297, ERCOT 0.625 / 0.6406 / 0.6406,
>   Western 0.1875 / 0.2031 / 0.2031. **Eastern gains exactly nothing from 13.1 GVAr of
>   reactive support** — an independent confirmation, down a different measurement path,
>   that its ceiling is impedance and not equipment. The re-derivation is ceiling-neutral
>   and shipped for correctness only (all 1,720 banks resolve; the incumbent left 46
>   orphaned by the restamp).
> - **What this reopens:** the salvage note below judged OLTC/SVC/FACTS controllers
>   "not worth salvaging (no data substrate)". Western's ceiling is now measured to be
>   caused precisely by the absence of that layer -- vars present, in the wrong places,
>   with no mechanism to move them. The substrate objection is also weaker than it
>   looked: capability curves are derivable from EIA-860 nameplate + power factor +
>   fuel class, and ULTC presence is a defensible prior above a size threshold. Treat
>   the rejection as reopened, not overturned -- it needs its own measurement.
> - **2026-08-31: built and measured** — `PowerModel.Solver.VoltageControl`
>   (REVIEW CAS-29): switched shunts + LTC taps, eleven measured rules, run by
>   `mix grid.census loadability --controls` and opt-in in the cascade.
>   Western now holds the emergency band over α 0.05-0.2 where it held none;
>   ERCOT reaches the normal band for the first time. See item 0.

> **Salvage note (2026-08-15):** the absorbed pre-reset history (tip `159e900`,
> retrievable via `git show 159e900:<path>` — do NOT use `origin/master`, which
> now points at current work; the richer harmonics-era `lib.rs` is blob
> `de38f9d9` under commit `433bd4e`, via `git cat-file blob de38f9d9...`)
> contains prior-architecture modules worth mining, not resurrecting wholesale: a Rust cached-factorization
> NIF (`sparse_factor`/`sparse_cached_solve`/`sparse_cached_solve_multi`,
> ResourceArc LDLᵀ handle — handed to p4-sparse for item 18; items 19/21 build on
> it), `solver/lodf.ex` (439 lines: correct LODF core — sensitivity solve, bridge
> detection via 1−PTDF_self≈0, cumulative trips — but drift: non-sign-preserving
> x floor, asymmetric tap entries that break B′ symmetry, single-factorization
> compounding; reference seed for item 21), `failure/monte_carlo.ex` (N-2/N-k
> LODF screening — item 21 stretch), `transient/machine/ibr.ex` (IEEE 1547 LVRT
> voltage-trip envelopes — the voltage half of the Blue Cut mechanism, wire into
> item 20's QSS-AC wave), `failure/scenarios.ex` (geographic heat-wave/ice/
> wildfire/earthquake correlated failures — Phase 5 item 25 skeleton),
> `controls/agc.ex` (ACE-based AGC, 161 lines — the "revisit after AGC" hook),
> `controls/ras.ex` (latching SPS/RAS), `validation/{harness,scoring}.ex`
> (weighted acceptance scoring — useful when acceptance gates formalize).
> Judged not worth salvaging: `voltage_stability.ex`/`cpf.ex` (toy heuristics /
> step-halving scanner, superseded by item 20), harmonics, OPF/UC/economic
> dispatch (measured-anchored dispatch supersedes), OLTC/SVC/FACTS/HVDC
> controllers (no data substrate).
18. **Sparse DC assembly** (S–M, precondition): build B′ as triplets, never densify;
    delete the dense path. Turns OOM-at-Eastern into sub-second factorizations. Guard:
    negative-reactance branches break LDLᵀ SPD — detect and fall back loudly.
19. **Fast-decoupled AC at scale** (M): B′/B″ are symmetric and constant (no phase
    shifters in schema) — the EXISTING LDLᵀ NIF suffices, factorized once per topology.
    Dense NR stays as small-island fallback. Includes the two hot-path fixes: Y-bus
    nonzero iteration in compute_power, and the accidentally-quadratic warm start.
    Full sparse NR (new `faer` NIF) only if FDPF convergence proves inadequate —
    a decision for the measurement, not the plan.
20. **Q–V pass / QSS-AC in the cascade loop** (M–L): warm-started per-island AC (or the
    cheaper Stott–Alsac Q–V sub-solve) with honest DC fallback; brings undervoltage,
    UVLS, and real mho distance relays (zone 1/2/3 + PRC-023 load blinder, two-timescale
    thermal) to life for the first time. Every historical cascade's critical phase was
    voltage-driven; the model currently cannot produce one.
21. **Sparse PTDF/LODF screening** (M): make the N-1 UI number real (REVIEW UI-M15 —
    today it reports the count of components the user already tripped). LODF screens
    and ranks; the full solve stays authoritative (redispatch/islanding break LODF).

### Phase 5 — Spatial load & new sources (M–L)
22. **EIA-861** (M): service territory + sectoral sales (verified live, 4.6 MB).
    NOTE: item 30 (BTM solar) consumes this zip's Net_Metering + Service_Territory
    files and can front-run the sales half.
    Two payoffs: county-by-sector metered MWh replacing the population proxy, AND a
    county-resolution BA boundary map that retires the DAT-5 blocker. Gotcha: three-row
    stacked headers. Supersedes LODES/CBP (noise-infused; data centers employ nobody).
23. **EIA-930 subregional demand** (M): 8–9 largest BAs report 4–14 zones each; after
    #22, CISO zones (PGAE/SCE/SDGE) map straight to service territories.
24. **OSM circuits/voltage/substation polygons** (M–L). **LANDED 2026-08-22, and the
    headline claim below did NOT survive measurement:** this item was carried as the
    unlock for the voltage chain, and the backfill measured ceiling-neutral on all
    three interconnections. It is a DATA-CORRECTNESS item (voltage-blind yards
    8,404 -> 3,617), not an alpha item; the alpha work is the three per-interconnection
    causes in the 2026-08-22 status block above. Original scoping follows.
    Measured Ohio sample: 68% of
    lines carry `circuits`, 89% `voltage`; substation polygons anchor the 78% of
    endpoints with sentinel names. Requires local Overpass off the Geofabrik extract.
    SCOPE BOUNDARY (measured 2026-08-16, DR-3/TOPO-7 — this item must not absorb work
    already done or doable without OSM). Done without OSM this round: the 8,814
    no-voltage HIFLD circuits ingested at yard-inferred voltage (DR-3); welds/endpoint
    recovery (DR-4); load redistribution + connected-rating cap (DR-5); floor/LV
    ratings/EHV reactors (DR-2); dispatch balance (DR-1). Genuinely needs OSM:
    (1) real voltage for the 13,520 level-less substations — 5,117 of them are why
    3,936 restorations sit at a 138 kV default; the in-repo evidence is EXHAUSTED,
    not under-used (adding native MAX_VOLT/MIN_VOLT moves 19 of 8,814 circuits);
    (2) the ~123 genuine HIFLD spurs whose underground meshes are absent from the
    source entirely (count inherits an all-components basis; approximate). When OSM
    voltage lands, write params_version 0 alongside any corrected voltage or the
    estimator leaves impedance/rating on the inferred class. The restored set is
    re-derivable any time from the pinned snapshot by source_ID.
    ODbL is ARCHITECTURAL: keep OSM-derived tables separable (§4.5), plan to satisfy
    share-alike by open-sourcing the extraction pipeline (§4.6). Internal-only use
    triggers nothing.
25. **Weather coupling** (L): HRRR on AWS (anonymous, verified) for temperature/wind/
    irradiance → IEEE 738-2023 ratings (paid standard; equations reproduced in
    literature) + heat-wave/winter scenarios. NOT for demand fidelity (the model
    already replays measured demand); justify as scenario generation only. NOAA ISD is
    retired — use GHCNh or IEM ASOS.

### Phase 2.5 — Distributed solar (added 2026-08-15) — **LANDED same day**

> Measured results: fleet tagged (23,477 utility-scale / 1,288.6 GW vs 3,378 onsite /
> 36.2 GW; dispatch carve-out verified with zero double-counting); 55.8 GW of BTM solar
> allocated onto 51,138 buses (100% allocation coverage, CAISO 14.0 GW, steady-state
> byte-identity proven on all three snapshots); 1547 trip feedback live — at the 0.30
> legacy default, a 2 MW island shortfall sheds 14 MW (7× amplification), the extra shed
> exactly equaling the tripped rooftop MW; conservation identity extended to
> served + shed + blackout == original + btm_tripped (Lean divergence noted). Voltage
> trigger (0.88 pu) implemented but DC-unreachable until the Q-V/QSS-AC work.

Motivating profile (measured from the ingested 2024 fleet): all 122.9 GW of modeled PV
is utility-metered EIA-860 plant — 122.1 GW genuinely grid-scale (IPP 102.6 + utility
19.5), ~0.75 GW onsite C&I — while the ~50 GW of US residential/BTM rooftop appears
NOWHERE as generation. It is not missing from the energy balance: EIA-930 demand is
metered NET of BTM, so rooftop lives invisibly inside the demand signal we replay. The
work below makes it explicit without double counting, because the cases that matter —
inverter tripping mid-cascade, cloud-cover scenarios — are exactly where net-zero stops
holding.

29. **Sector tagging of the existing fleet** (S, independent, do first): store EIA-860
    `Sector Name` (already in the parsed CSV, currently dropped) on generators +
    a derived `utility_scale`/`onsite` classification for ALL fuels; migration +
    ingest capture; surface in dispatch coverage, exports, and the info panel.
    Refinement while in there: EIA-930's solar/wind columns are utility-scale
    generation, so fuel-anchored dispatch should allocate them to utility_scale units
    only, with onsite units on their own CF (0.6% effect today; correctness, not
    magnitude). Validate against the measured sector profile (7,132 PV units:
    694 utility / 6,113 IPP / ~320 onsite).
30. **Behind-the-meter solar layer** (M, needs the EIA-861 net-metering +
    service-territory files — a subset of item 22, downloadable now, no key):
    capacity by utility × state × sector from Net_Metering (+ non-NEM distributed
    file), allocated utility→county via Service_Territory, county→bus via the
    existing residential/commercial load weights; hourly output shaped by the BA's
    own utility-solar capacity factor from ba_fuel_hour (same insolation; Phase 5
    HRRR upgrade later). REPRESENTATION RULE (the double-counting guard): model BTM
    as bus-level gross-up + generation pair — load.gross = EIA-930 net + btm_output,
    btm_output subtracted back at the same bus — so every steady-state solve is
    IDENTICAL with the layer on or off (pin with a regression test). The layer only
    acts when something perturbs btm_output. Anchors: ~50 GW national capacity,
    CAISO ≈ 15 GW; validate state capacity totals against EIA's published
    small-scale estimates.
31. **IEEE 1547 trip behavior in the cascade** (M, needs 30; implement with or right
    after item 15 — it is the same feedback loop): split BTM capacity into legacy
    (1547-2003: MUST-trip at 59.3 Hz / 0.88 pu, ~0.16 s) and modern (1547-2018:
    mandatory ride-through) buckets — documented configurable split (~30/70 default)
    until per-vintage 861 history refines it. Tripped BTM feeds back as an INSTANT
    NET-LOAD INCREASE on the island within the same step (the Blue Cut mechanism;
    note the vicious pairing: an island dipping to 59.3 Hz sheds its legacy rooftop
    fleet before the first UFLS stage arms at the same frequency). No auto-reconnect
    inside a cascade (1547 mandates delayed return — item 28 territory). Validate:
    Blue Cut-style scenario, duck-curve day replay of net demand, and β
    (frequency-response) must not degrade.

### Phase 6 — System-level validation (M–L)
26. **Historical event replays**, in feasibility order: 2021 Uri (resource-adequacy
    test; inside EIA-930 window; success = nadir ≈ 59.30 Hz, ~4.5 min below 59.4, 15–20
    GW shed), 2011 Southwest (the true cascade test: named initiating line, near-binary
    outcome — does San Diego island and collapse), 2003 Northeast (structural analog
    ONLY — contemporary topology, no 2003 load data; score direction/ordering, never MW).
27. **Stochastic ensemble** (M): N-k initiating events + Chen–Thorp hidden-failure relay
    misoperation; validate the blackout-size CCDF exponent against DOE OE-417
    (published α ≈ 1.31 ± 0.08). A thin tail is a diagnostic that propagation mechanisms
    are still missing — the scoreboard for Phases 3–4. Breaker-failure lives here as a
    probability, not as invented bus-section topology.
28. **Restoration/reconnection** (L, last): reclosing, UFLS restoration, island
    resync — adds the duration dimension (customer-hours) the model cannot express.

## Where the model is weakest now — 2026-08-22 (re-ranked after the voltage wave)

The 2026-08-15 ranking at the top of this file was written before Phases 0-4 landed and
before the alpha ceiling was attributed. Three accuracies are worth separating: **is the
network the real network**, **is the operating point a real operating point**, **are the
failure dynamics real dynamics**. A year of network work moved the first a long way. The
second is where the model is genuinely broken, and it gates the third.

0. **An operating point at real demand exists now — on ERCOT — and the two
   things that made it are the two things the rest of the roadmap runs on**
   (REVIEW CAS-28 → CAS-29 → CAS-30, 2026-08-23 → 2026-09-01).
   *Capacity* (CAS-30): at real demand the load was carried on branches at
   multiples of their rating with nothing out of service — ERCOT 218 rated
   branches over 100 % and 22 GW of overload, Eastern 335 / 38 GW, Western
   135 / 12 GW; 69 kV lines at 300-520 MW, NYC 138 kV at 900 MW per circuit —
   which is at once why no AC solution existed at real demand and CAS-26's
   binary contingency regime. `Ingestion.CapacityInference` infers the parallel
   circuits that flow implies (stored as `inferred_circuits`, folded into the
   parameters, idempotent, gated by `validate`'s `at_rest_loading`), and its
   second rule finds the pockets the at-rest test cannot see — load areas fed
   through chains whose IMPEDANCE, not rating, is the limit — from where the
   AC solve collapses, and reinforces one series feeding path per pocket up
   to the radial loadability criterion. Both refuse past 8 circuits.
   *Control* (CAS-29): `Solver.VoltageControl`, switched shunts and LTC taps
   in an outer loop, eleven measured rules, a load-ramp continuation for cold
   starts, opt-in in the cascade.
   Controlled census, capped network (fixed plant → now): ERCOT solvable
   α 0.64 → **1.0 (43,457 MW, all of real demand)**, emergency band 0.2-0.3 →
   **0.02-0.9 (39,111 MW)**, normal none → **0.3-0.4**; Western solvable 0.20 →
   **0.99 (82,628 MW)**, emergency none → **0.02-0.75 (62,459 MW)**; Eastern
   solvable 0.43 → **0.99 (285,479 MW)**, emergency 0.02-0.25 → **0.02-0.75
   (215,792 MW)**. Under a
   cascade at real demand ERCOT's main island solves AC (`ac_diverged` 50 → 0)
   and the worst thermal N-1 settles intact instead of exhausting the step
   budget with 8.5 GW of UFLS; Eastern's and Western's main islands now solve AC at real
   demand too (controls + ramp), at 1,005 s and 301 s against 11 s and 14 s.
   Still open, in order: (a) **The refusals are the worklist**
   (`data/vendored/ehv_corridor_worklist_2026-09-01.csv`, 94 corridors): every
   one is a corridor whose real supply path — usually a higher class — HIFLD
   does not carry. Two were untied HIFLD records and were corrected from OSM
   (Vogtle's 500 kV yards; Red Butte's 345/138 — the latter took Western from
   0.74 to 0.99). Split yards in general are NOT the mechanism (measured:
   welding every same-class twin within 600 m moves the at-rest overload
   < 1 %). What is left needs missing yards and lines: Vogtle's 230 kV tie
   still carries 14.3 GW because Wadley has no 500 kV yard in the model at
   all (OSM: Vogtle-Wadley 500 kV). A yard is a bus, a transformer and a
   line — the next Eastern move; more inference is not. (b) The inferred capacity sits at the same class between
   the same buses; right for flows, wrong for anything reading circuit class;
   `inferred_circuits > 1` marks every such row for replacement. (c) Threshold
   0.8, the two hours, the 0.2 radial margin and the 8-circuit cap are
   choices; the peak-hour requirement (ERCOT 1,761 circuits against 476 for
   the reference hour) says more hours would ask for more. (d) The control
   layer stays opt-in in the cascade until re-measured across item 1's
   external target. (e) The normal band is unreached on Western and Eastern.

0b. **The first external score exists, and it says the congestion is in the
   wrong place** (REVIEW EXT-1, 2026-09-01). `scripts/score_congestion.py` +
   `mix power_model.loadings` score the model's branch loadings against the
   ISOs' real binding constraints (ERCOT SCED, committed because the MIS
   listing expires; MISO real-time reports for the model's own reference day).
   Of the real binding elements the model demonstrably contains, it loads them
   at a median 20 % (ERCOT) and 36 % (MISO) where the market has them at
   100 % of limit; 1 of its top-30 loaded ERCOT branches is a real constraint;
   and six ERCOT bottlenecks — Frontera-S. Mission and Bruni 138 kV among them,
   the market's two most frequent — were overloaded at rest in the raw model
   (222 %, 204 %) and were given circuits by the at-rest pass: real limits
   read as missing capacity. Both reorderings are BUILT and measured (EXT-2):
   (i) the exclusion list is live — the six ERCOT bottlenecks carry their raw
   overloads again (Frontera 223 %, Bruni 204 %) at no cost to the ceiling
   (a thermal overload is not an infeasibility); (ii) `Dispatch.Redispatch`
   holds them at their limits like the market does (Bruni → 100.0 %, 1,424 MW
   shifted; Frontera residual at 110 % — the Valley is import-constrained,
   faithfully), opt-in everywhere until measured under cascades. Still open:
   the distribution — the median found element loads 21 % and 27 of the
   model's top-30 are still not real constraints, which points at C1 (CEMS
   unit-level dispatch) and the instrument's coverage (31/80, 29/57
   geocoded); (iii) MISO's 16 "no bus at class" yards join the corridor
   worklist; (iv) `mix power_model.cascade_ccdf` ran (EXT-3):
   every N-1 and N-2 sample SETTLES — CAS-26's runaway regime is closed on
   ERCOT — and no tail exists (q99 ≈ 72 MW vs OE-417's gigawatt power law):
   the model now under-propagates because, post-inference, it runs far from
   its limits everywhere the BA-fuel dispatch reaches. The tail needs the
   operating point, not more samples: C1 (CEMS unit dispatch) + re-dispatch
   as the default, then re-run.

1. **Nothing external has ever scored this model** (Phase 6 item 26, unstarted). Every
   instrument is internal — alpha ceilings, census counts, TV distance, conservation
   residuals — so "more accurate" currently has no denominator. 2011 Southwest is the
   right first target: a named initiating element, a documented ~11-minute sequence,
   entirely inside Western, and a near-binary outcome (does San Diego island and
   collapse?). Item 27's CCDF-vs-OE-417 check (published alpha ~= 1.31 +/- 0.08) is the
   cheap companion and is diagnostic even when it fails.
2. **The alpha ceiling is weakest-link: only the BINDING bus moves it** (REVIEW
   LIN-17, measured 2026-08-22/23; this entry has now been rewritten twice as the
   measurements came in, and the current form is the one that survived a negative
   result). `vm_floor_bus_ids` names ONE bus in Eastern and three in ERCOT; peeling
   their load leaves alpha unmoved for six rounds, so it is structural. Repairs AT
   the binding element buy ~10-12% each (Eastern's 73688 reclassed 33 -> 69 kV,
   +10.9%; a 345 kV tie at ERCOT's 58121, +12.2%). Repairs anywhere else buy
   NOTHING: 130 OSM-confirmed missing circuits applied at once moved alpha zero
   bisection steps on all three interconnections, verified against a positive
   control.

   So the method is a LOOP, not a sweep: solve at the ceiling, read the floor bus,
   repair it, re-measure, find the next one. RUN 2026-08-23, and the round count
   is 1-2: Eastern 0.4297 -> 0.5156 (+20.0%) on ONE line, ERCOT 0.6406 -> 0.7188
   (+12.2%) on two, Western zero because it never has a floor bus. The elements
   are extreme rather than marginal (12.6x, 10.2x, 10.6x their class medians).

   The loop is short because the failure MODE changes, not because the network
   runs out of bad elements: after one or two repairs `vm_floor_bus_ids` comes
   back EMPTY while the solve still fails. So the alpha work is NOT a large
   repair programme — it is a couple of named elements per interconnection, and
   then a different problem needing a different diagnostic. **The open question
   is now: what fails when no bus is on the floor?**
   The generator-interconnection census and the conflation wave (LIN-16) keep their
   value for model FIDELITY — a plant exporting through a circuit that does not
   exist misplaces flows in every contingency — but they are NOT the alpha lever,
   and this document said they were for a day.
3. **Base-case overloads make contingencies binary** (REVIEW CAS-26). Lines at 124-250%
   at rest mean a contingency either settles at zero or runs away past the step budget;
   no settled non-trivial cascade regime exists. This is a PRECONDITION for item 26 —
   a historical replay fails here before it can fail for an interesting reason.
4. **Dispatch is still uniform inside the cascade** (REVIEW ENE-20, open). Fuel-anchored
   dispatch fixed the ingest layer, but `balance_dispatch` re-spreads pro-rata, Eastern
   runs ~65 GW long, and its N-1 census measures the dispatch imbalance rather than the
   network. Uniform re-spread invents flows — plausibly part of why Western shows LOCAL
   reactive exhaustion against a globally absorbing island.
5. **Absent mechanisms, by how often they decide real cascades**: equipment-side voltage
   dropout (REVIEW CAS-27); hidden-failure relay misoperation (item 27's other half —
   no relay in this model ever operates when it should not); restoration (item 28 —
   the model cannot express customer-hours, the unit every post-event report uses).

## Reference corpus (added 2026-08-22)

`PowerModel.Reference` / `priv/reference/structural_stats.json` /
`mix grid.reference_stats`. Structural distributions from the MATPOWER cases
already vendored for solver validation, so a census can be read against a
yardstick instead of a guess.

The motivating measurement: "12.4% of Eastern's load sits on EHV and 32.5% of it
sits 5+ hops out" was unreadable without a reference, so it cost a 189 GW
relocation experiment that returned "inconclusive". The corpus answers both in a
lookup — reference depth is 32%, so ours is ORDINARY; reference places 0% of load
on EHV and 0% below 115 kV, so our voltage placement is not. The experiment tested
the wrong half.

Uses landed:
- **item 32 (new): `mix grid.census generator_interconnection`** — generation-side
  mirror of `load_placement`, gating plant output against the reference POI floor.
  Measured 574 buses / 87.3 GW below floor, 25.0 GW on a bus with no branch.
- Reference caveats are carried in the module's own moduledoc so they travel with
  the numbers; the load-band section renders as an OBSERVATION, not a gate,
  because reference models terminate at the distribution substation and this one
  does not.

Worth adding next: RTS-GMLC or a published planning case (REVIEW DAT-33) — both
current sources are small and neither covers every voltage level.

## Europe (added 2026-08-23) — a reader, not a second pipeline

`PowerModel.Network.PyPSA` reads a PyPSA CSV export into the snapshot map the
solvers already consume, so `Partition`/`FDPF`/`Cascade` and the whole
protection stack run on a European network with no further plumbing. Same shape
as `Test.MATPOWER`, but in `lib` because this is a simulation substrate.

**Why a reader.** The EU publishes more than the US does — ENTSO-E Transparency
gives per-bidding-zone load and generation at 15-minute resolution, cross-border
flows, and per-unit generation and transmission OUTAGE data that has no US
equivalent — and the open modelling ecosystem has already spent years turning it
into networks. PyPSA-Eur builds a continental model from OSM and ENTSO-E and
ships it in this format. Rebuilding that as a second HIFLD-style ingest would
duplicate a mature effort and inherit none of it. What is missing THERE is what
this repo has: PyPSA is a capacity-expansion and dispatch optimiser and does no
AC contingency cascades, protection, UFLS/UVLS or voltage collapse.

**Measured on scigrid-de** (585 buses, 852 lines, 1,423 generators, 51.8 GW):

- **It converges at alpha = 1.0.** Full hour-load, 10 FDPF iterations, Vm
  0.9973-1.0039, losses 884.9 MW (1.7%). Against our own 0.2062/0.6375/0.4313.
  The alpha ceiling is substantially an artifact of ingesting raw HIFLD, and a
  curated 220/380 kV backbone does not have it.
- **Real per-circuit impedance** (`r_ohmkm`/`x_ohmkm`/`c_nfkm`, `length`,
  `num_parallel`), so no estimation from a voltage class — the root of LIN-13.
  Median `x_ohmkm` 0.32 against the 0.335-0.50 our estimator produces: an
  independent corroboration of that recipe.
- **`num_parallel` is present**, which is the missing-parallel-circuits half of
  the POI census findings.
- **Per-bus hourly load.** The whole load-ALLOCATION problem — population
  weights, delivery ceilings, capability caps — does not arise.
- **The Western reactive finding reproduces.** With naive uniform generator q
  limits at 0.95 pf the network FAILS (Vm -> 0.5) despite 56.7 GVAr of total
  absorption against 13.3 GVAr of charging. Local exhaustion, global surplus —
  the same mechanism, on a different continent's data, from a different source.

**What it costs.** The curated backbone has no sub-transmission, so the failure
modes that live there are absent too. And PyPSA carries no reactive limits and
no load Q; both are synthesized and declared in the returned `:synthesized` map
rather than assumed.

**Why this is the validation path.** REVIEW's standing top item is that nothing
external has ever scored this model. Europe has better-documented cascades than
the US record: the 2006 UCTE disturbance (the system split into three islands,
with a full UCTE final report), the 2021 Continental Europe separation, and the
April 2025 Iberian blackout with an ENTSO-E expert-panel investigation. Combined
with ENTSO-E's per-unit outage data, that is the first realistic route to
scoring this model against something it did not generate itself.

### Step 1 — continental network: DONE (2026-08-23)

`PowerModel.Network.GridKit` reads `data/entsoegridkit` from PyPSA-Eur — the
GridKit extraction of the ENTSO-E interactive map, **CC-BY-4.0** (SPDX
annotation in that repo's `REUSE.toml`). 8,510 AC buses, 9,936 lines, 1,017
transformers, 400,897 km of circuit, with real per-line `circuits` counts
(6,784 single / 3,014 double / 138 triple).

**It recovers the real synchronous areas with no area labels in the input** —
Continental Europe 6,761 buses (FR/RU/ES/DE/IT/UA, the March-2022 extract
predating UA/MD resynchronisation), Maghreb 565 (DZ/MA/TN/LY), Great Britain
385, all-island Ireland 60, Iceland 48, Cyprus 22. Those ARE separate
synchronous areas joined only by HVDC, and the reader drops the 62 DC links
deliberately (this repo models HVDC as scheduled injections), so the split is
the physically correct one rather than a connectivity failure. 92.7% of buses
sit in a component of 20 or more.

Unlike a PyPSA export this source carries NO electrical parameters — voltage,
circuits and length only — so impedance is DERIVED from PyPSA's standard type
library. That makes it a like-for-like test of our own estimator recipe on
another continent's topology rather than a way to avoid it. Its README's own
caveats (unofficial, unendorsed, voltage is the LOWER BOUND of the ENTSO-E
range, transformers inferred not sourced) are carried in `:provenance` so they
travel with the numbers. Source defect noted: 38 buses at 0.0 kV — which the
`class_ceiling` term-ordering guard added the same day now handles
conservatively instead of granting them the most permissive ceiling.

### Step 2 — ENTSO-E demand: BLOCKED on credentials, with a route around

The Transparency Platform API requires a registered account and a security
token, which cannot be obtained from here. Two consequences worth recording
rather than working around silently:

- The open substitute is **Open Power System Data** (`time_series` package,
  CC-BY-4.0), which republishes ENTSO-E hourly load per country without a
  token. It gives country totals, NOT per-bus demand — so using it reintroduces
  the load-ALLOCATION problem that `Network.PyPSA` avoided, and would need the
  same population/capability weighting the US pipeline uses.
- The per-unit OUTAGE feed — the thing with no US equivalent and the reason
  Europe is the validation path — is Transparency-only. It needs the token.

So step 2 is not "do this next"; it is "get a token, or accept country-level
allocation". That is a decision, not a task.

### Step 3 — 2006 UCTE replay: BLOCKED behind the frequency port

Two hard prerequisites, both now identified rather than assumed:

1. **The frequency layer is North American.** `Solver.Frequency` compiles
   `@f0 60.0` and UFLS at 59.3/58.9/58.5/58.1 Hz; a healthy 50 Hz system sits
   below every stage. `Grid.SystemStandard` now carries both standards and
   `Cascade.init/3` REFUSES the mismatch, so the failure is loud instead of
   silent — but refusing is not porting. Threading a standard through
   `Frequency`, `Protection`, `LoadShedding`, `Controls.AGC` and `Grid.BtmSolar`
   is the real prerequisite, and it is the next substantial piece of work.
2. **The network vintage is wrong.** The extract is March 2022; the 2006 UCTE
   split happened on a network that no longer exists. A replay would score
   topology-sensitive behaviour against the wrong topology. The honest first
   target is therefore a MECHANISM test — does a deliberate cut of the
   Continental Europe component separate it into islands the way the UCTE
   report describes — rather than an event replay.

**Ordering that follows from the above:** port the frequency layer (unblocks 3
and everything downstream), then decide the ENTSO-E credential question, then
attempt the mechanism test before any dated replay.

## Decisions needed now (independent of build order)

- **Vendor a pinned HIFLD snapshot — concrete targets verified live (2026-08):**
  - **Transmission lines**: HIFLD Next (hifld.publicenvirodata.org, no login, public
    domain) serves the final Data Rescue snapshot as GeoParquet — **94,619 features,
    46.4 MB** — versus the **52,244** in the unofficial ArcGIS mirror we currently pull.
    Switching sources nearly doubles line coverage AND fixes provenance in one move.
    (Alt archive: SeerAI on Source Cooperative, CC-BY, anonymous S3.)
  - **Substations**: the native layer was pulled from public HIFLD ~2022 and is ABSENT
    from every official archive. The last public cut survives on one third-party ArcGIS
    mirror (services6…OO2s4OoyCZkYJ6oE, **77,946 features**, full NAME/MAX_VOLT/MIN_VOLT
    schema, 2021 vintage, ~24% voltage sentinels) owned by a personal account —
    **one deletion away from extinction. Pin it immediately.** It directly feeds the
    already-coded native-substations path and the Phase-2 connectivity work.
  - **Power plants**: HIFLD Next has 16,317 features, but EIA-860/860M is the living
    upstream — use the archive only as a convenience join.
  - Record fetch dates + checksums for all three; stop pulling live.
  - Bonus: EIA-930 six-month bulk CSVs reach back to **July 2015** (API only to 2019) —
    the dispatch/validation work (Phases 0-1) should backfill from the CSVs.
  - FERC 715 rejection is now evidence-backed: the CEII NDA bars "any derivative form"
    of the data — a network model with traceable buses/branches is unpublishable, with
    $25k/day exposure. Even DOE's National Transmission Planning Study routed around it.
- **Schedule the re-ingest.** R3's substation-identity, status-recovery, and HVDC
  fixes are code-only until then; `line_type='dc'` matches zero rows today.
- **Close the dev-DB schema drift** (rating_b/c columns exist without migrations) —
  folded into item 9.
- **ODbL architecture** before any OSM ingestion (item 24).
- **Fix the default-hour boundary bug now** (REVIEW ENE-13): `latest_demand_hour/0`
  returns an hour where 17 of 53 BAs report; two-thirds of the country silently falls
  back to the ~2× baseline in the default run.

## Explicitly rejected (with reasons, so they stay rejected)

- **FERC Form 715**: CEII, non-redistributable — unusable for a publishable model.
- **MATPOWER/SyntheticUSA impedance graft**: no coordinates, lengths, or geometry on
  any matpower row — no join key exists. Keep as calibration reference only.
- **Weather-driven demand for fidelity**: strictly worse than replaying measured
  EIA-930 demand; scenario-generation is the only honest justification.
- **Explicit demand response**: ~1–2% of peak and already inside the 930 demand signal;
  modeling it separately double-counts. Revisit after AGC as an emergency tier.
- **Per-corridor circuit counts**: HIFLD already ships one record per circuit
  (measured: 5,196 double, 1,305 triple pairs) — multipliers would double-count.
- **ACTIVSg-style statistical parameter dispersion**: dispersion without information
  randomizes which line overloads; the 2× level errors dominate.
- **Straight-to-sparse-NR**: fast-decoupled reaches most of the accuracy at a fraction
  of the effort with zero new native code; sparse NR only if FDPF measurably fails.
- **Standalone reserve-margin model / LODES / CBP / NARIS nodal / breaker topology**:
  superseded, proxy-blind, non-public, or substrate-free respectively (see domain
  reports in session log for full arguments).

## Appendix: ISO market-data licensing (for when LMP validation is revisited)

Verified 2026-08-14. When Phase 1 makes congestion comparison meaningful, the access
pattern is constrained by licensing, not tooling:
- **Hosted gridstatus.io API: redistribution blocker.** ToS (2026-04-02) licenses data
  for internal use only, prohibits publishing anything that "substantially reproduces"
  it, and claims compilation copyright + trade secret. Raw or near-raw hosted data can
  never be committed to this repo. Free tier 500k rows/month; fine for private analysis.
- **OSS `gridstatus` lib (BSD-3, actively maintained)** pulling DIRECT from ISOs is the
  right pattern. Credential-free: CAISO, NYISO, SPP, IESO. Keys required: PJM (free),
  ERCOT API (geo-restricted), MISO, ISO-NE. The credential-free ERCOT/MISO/ISONE
  scraper paths are being deprecated.
- **Per-ISO redistribution**: ERCOT explicitly permissive (raw data may be redistributed
  in compilations/analyses); EIA public domain (already our scaling source); CAISO
  attribution + murky; **PJM prohibits non-member republishing** — validate against PJM
  privately, publish only derived metrics. History is shallow per-dataset (some 5-30
  days) — archive pulls promptly once validation starts.
