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
  Western 16.6%, ERCOT 30.6%. One branch in seven is overloaded at rest, and base-case
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
24. **OSM circuits/voltage/substation polygons** (M–L): measured Ohio sample: 68% of
    lines carry `circuits`, 89% `voltage`; substation polygons anchor the 78% of
    endpoints with sentinel names. Requires local Overpass off the Geofabrik extract.
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
