# MATPOWER validation cases

Test cases and committed reference solutions for the solver validation ladder
(ROADMAP Phase 0 item 4). Loaded by `PowerModel.Test.MATPOWER` in
`test/support/matpower.ex`; consumed by `test/power_model/solver/ieee_118_test.exs`
and `test/power_model/solver/activsg2000_test.exs`.

## Case files

| File | Buses | Branches | Gens (in service) | Source | License |
| --- | ---: | ---: | ---: | --- | --- |
| `case118.m` | 118 | 186 | 54 | [MATPOWER `data/case118.m`](https://raw.githubusercontent.com/MATPOWER/matpower/master/data/case118.m) | BSD 3-Clause (MATPOWER) |
| `case_ACTIVSg2000.m` | 2000 | 3206 | 432 of 544 | [MATPOWER `data/case_ACTIVSg2000.m`](https://raw.githubusercontent.com/MATPOWER/matpower/master/data/case_ACTIVSg2000.m) | CC BY 4.0 |

Fetched 2026-08-15, verbatim and unmodified, so the checksums below can be
compared against upstream at any time.

```
bc2e6f22b4b9e776572885ee4b50e4f4ab2ee0c5577e9126e86d906f14c4b5f7  case118.m
8d00618de8fd10bf35a599f59d2deebfecd0d86e28fcff73219ad7c4ebab860b  case_ACTIVSg2000.m
```

### `case118.m` — IEEE 118-bus

The standard IEEE 118-bus test case, converted from the IEEE Common Data
Format. Distributed with MATPOWER under its BSD 3-Clause license. No branch
carries a `rateA`, so nothing in this case can report as overloaded.

### `case_ACTIVSg2000.m` — ACTIVSg2000 (Synthetic Texas)

An entirely synthetic 2000-bus system geographically situated in Texas,
built under the US ARPA-E GRID DATA project. It models no actual lines and
contains no CEII. Licensed **CC BY 4.0**, which the ROADMAP records as
verified open; the license header travels inside the `.m` file itself.

When publishing results based on this case, cite:

> A.B. Birchfield, T. Xu, K.M. Gegner, K.S. Shetye, T.J. Overbye, "Grid
> Structural Characteristics as Validation Criteria for Synthetic Networks,"
> IEEE Transactions on Power Systems, vol. 32, no. 4, pp. 3258–3265, July 2017.
> doi: 10.1109/TPWRS.2016.2616385

MATPOWER's copy is used rather than the TAMU original because it is the same
data with a stable, checksummable URL. The upstream authority is
<https://electricgrids.engr.tamu.edu>, whose ACTIVSg2000 page serves a
PowerWorld bundle (`Texas 2000 - June 2016`) through a Google Drive link; that
bundle's `.m` export is a different vintage with 2007 buses.

### ACTIVSg10k — not vendored

Deliberately skipped. The download is frictionless — the TAMU
[ACTIVSg10k page](https://electricgrids.engr.tamu.edu/electric-grid-test-cases/activsg10k/)
links a Google Drive bundle (file id `1qZSiF66ZvLLNiwovEi2RazrrYr8nGgjW`,
11.6 MB, fetchable with plain `curl` against
`https://drive.google.com/uc?export=download&id=<id>`) — but the solvers cannot
use it yet. `DCPowerFlow.build_b_prime_and_injection/9` materializes B′ densely,
which at 10k buses is a 10⁸-element list; ROADMAP Phase 4 item 18 (sparse DC
assembly) is the precondition. Add it here once that lands.

## Reference solutions

`case118_reference.json` and `case_ACTIVSg2000_reference.json` are produced by
`scripts/generate_references.py` and committed. Regenerate with:

```
pip install pandapower
python scripts/generate_references.py
```

**The references come from pandapower, never from the solvers under test.**
pandapower's power flow is a maintained fork of MATPOWER/PYPOWER, so it is an
independent implementation of the same equations.

Each JSON carries, per bus, AC `vm_pu` and `va_deg` and DC `va_deg`, plus total
generation, load and losses, along with the source file's SHA-256 and the
generating package versions.

### Conventions

* **Angles are in degrees**, shifted so the reference (slack) bus is exactly 0.
  MATPOWER carries whatever angle the case file assigned the slack bus (30° for
  case118); these solvers pin it to 0. The removed shift is recorded as
  `va_shift_deg_removed`.
* **AC runs with `enforce_q_lims=True`**, matching the outer-loop Q-limit
  enforcement in `NewtonRaphson.outer_solve/18`. One difference remains: this
  codebase aggregates Q limits per bus, MATPOWER and pandapower enforce them per
  generator. The two agree on the total at a bus whose generators all bind
  together, which is the case in both fixtures.
* **Losses** are summed per branch (lines, transformers and pandapower's
  `impedance` elements), and cross-checked against generation − load before the
  file is written.

### How the references are corroborated

Two independent checks, both recorded in the JSON:

1. `unconstrained_q_cross_check` — the same solve with Q limits released. For
   case118 this gives **132.86 MW** of losses, the figure MATPOWER's own
   `runpf case118` is documented to produce. This is the one genuinely external
   number available, and it matches.
2. `embedded_solution_check` — the AC reference against the solved `VM`/`VA`
   columns stored in `mpc.bus`, written by a third tool (PowerWorld, or the IEEE
   CDF converter). This is a **loose** corroboration, not an equality: the
   stored profile reflects switched shunts, tap changers and remote voltage
   regulation that a plain power flow does not reproduce. case118 agrees to
   0.018 pu worst-case with a single bus over 0.005 pu; case_ACTIVSg2000 to
   0.031 pu with 161 buses over 0.005 pu. Enforcing Q limits moves the
   ACTIVSg2000 solution markedly *toward* the stored profile (421 such buses
   down to 161), which is what one expects if the limits are being enforced the
   same way.

## Known modeling gaps these fixtures expose

The parser refuses to paper over the places where the snapshot shape cannot
carry MATPOWER's data; each is counted on the parse result and asserted in the
tests.

* **No phase-shift support.** Branches with a nonzero `SHIFT` are omitted and
  counted in `:skipped_phase_shifters`. Neither fixture contains one, so both
  comparisons are against the complete network.
* **Transformers drop charging susceptance.** `YBus.transformer_triplets/2` has
  no `b` term, so a tapped branch with nonzero `b` would lose it; counted in
  `:transformers_with_dropped_charging`. Zero in both fixtures — case118's nine
  tapped branches all have `b = 0` and `r = 0`.
* **The reactance floor is coarse.** `YBus.effective_reactance/1` floors `|x|`
  at 1.0e-3 pu. Three branches in case_ACTIVSg2000 have a true `x` between
  7.0e-4 and 8.8e-4 pu, so their reactance is inflated by 14–43%. Measured
  effect on the DC solution: **0.108° (1.9e-3 rad) worst-case bus angle, 0.033°
  mean** across all 2000 buses. The DC tolerance in
  `activsg2000_test.exs` is set to admit exactly this and no more.

* **Q-limit switching does not scale.** How many generators need switching
  differs by two orders of magnitude between the two cases. Solved with Q limits
  released, **6 of case118's 54** generator buses end up outside their reactive
  limits, against **176 of case_ACTIVSg2000's 392**.

  At six, `NewtonRaphson` is exact: it switches precisely the same six buses as
  the reference, which `ieee_118_test.exs` asserts bus for bus. At 176 it stops
  short. The converged ACTIVSg2000 solve (max mismatch 3.1e-10) takes **164**
  generator buses off setpoint against the reference's **195** — 163 of them the
  same buses, **32 the solver never switches**, 1 it switches alone. The
  unswitched buses are the error: the worst is **2.86% off**, bus 1070 sitting
  at its 1.040 pu setpoint where the reference floats to 1.071 pu, against a
  0.5% contract. Losses still land within contract at 0.335% and served load is
  exact, so the damage is confined to the voltage profile.

  The suspect is the back-switching rule in
  `NewtonRaphson.update_pv_pq_switching/7`: a bus pinned at `q_max` returns to
  PV as soon as its voltage exceeds setpoint. That is a sound local test when a
  handful of buses switch, but the post-switch voltage is set by the *global*
  switching state — bus 1070 does violate `q_max` (36.57 against 34.19 MVAr) and
  yet lands above its setpoint once the other 175 buses are clamped, which
  satisfies the back-switch condition and returns it to PV to violate again. The
  `@max_qlim_rounds 6` cap in `outer_solve/18` then ends the round trip with the
  bus pinned at setpoint. This is a correctness gap, independent of the speed
  gap, and making the solver faster will not close it.
