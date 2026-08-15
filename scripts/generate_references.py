#!/usr/bin/env python3
"""Generate committed power-flow reference solutions for the solver validation ladder.

The Elixir solvers under test (``PowerModel.Solver.DCPowerFlow`` and
``PowerModel.Solver.NewtonRaphson``) are validated against these JSONs by
``test/power_model/solver/ieee_118_test.exs`` and
``test/power_model/solver/activsg2000_test.exs``. The references are therefore
produced by an *independent* implementation — pandapower, whose power flow is a
maintained fork of MATPOWER/PYPOWER — never by the code under test.

Every reference is additionally cross-checked against the solved voltage
profile embedded in the MATPOWER case file itself (the ``VM``/``VA`` columns of
``mpc.bus``, written by PowerWorld or the IEEE Common Data Format converter).
That embedded profile comes from a third, unrelated tool, so agreement between
it and pandapower is real corroboration rather than self-confirmation. The
comparison is recorded in the JSON under ``embedded_solution_check`` and printed
by this script; a large residual there means the reference is not trustworthy
and the run should be treated as failed.

Conventions baked into the output, all of which the Elixir tests rely on:

* Angles are stored in **degrees** (the MATPOWER/pandapower native unit) and
  shifted so the reference (slack) bus sits at exactly 0. The Elixir solvers
  pin the slack angle to 0.0, whereas MATPOWER carries whatever angle the case
  file assigned to the slack bus (30 deg for IEEE-118), so the shift is what
  makes the two directly comparable.
* AC power flow is run with ``enforce_q_lims=True`` to match the outer-loop
  Q-limit enforcement in ``NewtonRaphson.outer_solve/18``.
* Losses are reported in MW as the sum over branches of the real power lost.

Usage::

    python scripts/generate_references.py                  # regenerate all
    python scripts/generate_references.py case118          # one case

Requires ``pandapower`` (``pip install pandapower``). The generated JSONs are
committed, so this script only needs to run when a case file changes.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURE_DIR = REPO_ROOT / "test" / "fixtures" / "matpower"

# MATPOWER column indices (0-based), per CASEFORMAT.
BUS_I, BUS_TYPE, PD, QD, GS, BS, BUS_AREA, VM, VA, BASE_KV = range(10)
GEN_BUS, PG, QG, QMAX, QMIN, VG, MBASE, GEN_STATUS, PMAX, PMIN = range(10)
F_BUS, T_BUS, BR_R, BR_X, BR_B, RATE_A, RATE_B, RATE_C, TAP, SHIFT, BR_STATUS = range(11)

CASES = {
    "case118": "case118.m",
    "case_ACTIVSg2000": "case_ACTIVSg2000.m",
}


# ── MATPOWER .m parsing ───────────────────────────────────────────────────


def _parse_matrix(text: str, name: str) -> np.ndarray:
    """Extract ``mpc.<name> = [ ... ];`` as a float array."""
    match = re.search(r"mpc\.%s\s*=\s*\[(.*?)\n\s*\];" % re.escape(name), text, re.S)
    if match is None:
        raise ValueError("no mpc.%s block found" % name)

    rows = []
    for line in match.group(1).splitlines():
        line = line.split("%")[0].strip().rstrip(";").strip()
        if not line:
            continue
        rows.append([float(tok) for tok in line.split()])

    width = max(len(r) for r in rows)
    if any(len(r) != width for r in rows):
        raise ValueError("ragged mpc.%s block: row widths %s" % (name, {len(r) for r in rows}))
    return np.array(rows, dtype=float)


def load_ppc(path: Path) -> dict:
    """Read a MATPOWER case file into a PYPOWER-style ``ppc`` dict."""
    text = path.read_text(encoding="utf-8", errors="replace")
    base_mva = float(re.search(r"mpc\.baseMVA\s*=\s*([\d.eE+-]+)\s*;", text).group(1))
    return {
        "version": "2",
        "baseMVA": base_mva,
        "bus": _parse_matrix(text, "bus"),
        "gen": _parse_matrix(text, "gen"),
        "branch": _parse_matrix(text, "branch"),
    }


# ── Reference solves ──────────────────────────────────────────────────────


def _shift_to_slack_zero(va_deg: dict, slack_bus: int) -> tuple[dict, float]:
    shift = va_deg[slack_bus]
    return {bus: angle - shift for bus, angle in va_deg.items()}, shift


def _branch_loss_mw(net) -> float:
    """Total real power lost in branches, MW.

    Summed per branch rather than read off a generation-minus-load identity, so
    it stays correct in the presence of shunt elements. from_ppc splits
    MATPOWER branches across three tables — lines, transformers, and
    ``impedance`` for branches it can represent as neither — and all three must
    be counted.
    """
    total = 0.0
    for table in ("res_line", "res_trafo", "res_impedance"):
        res = getattr(net, table, None)
        if res is not None and len(res):
            total += float(res["pl_mw"].sum())
    return total


def _totals_mw(net) -> tuple[float, float]:
    """(generation, load) in MW at the converged operating point."""
    gen = float(net.res_gen["p_mw"].sum()) + float(net.res_ext_grid["p_mw"].sum())
    if hasattr(net, "res_sgen") and len(net.res_sgen):
        gen += float(net.res_sgen["p_mw"].sum())
    load = float(net.res_load["p_mw"].sum())
    return gen, load


def solve_reference(ppc: dict, case_name: str) -> dict:
    import pandapower as pp
    from pandapower.converter.pypower.from_ppc import from_ppc

    slack_bus = int(ppc["bus"][ppc["bus"][:, BUS_TYPE] == 3][0, BUS_I])

    net = from_ppc(ppc, f_hz=60)

    # from_ppc indexes buses by their MATPOWER bus number, which is also the bus
    # id the Elixir snapshot carries, so the pandapower index can be used
    # directly as the join key. Assert it rather than assume it: a silent
    # renumbering would misalign every bus in the reference.
    ppc_bus_ids = sorted(int(r[BUS_I]) for r in ppc["bus"])
    if sorted(int(i) for i in net.bus.index) != ppc_bus_ids:
        raise RuntimeError(
            "%s: from_ppc renumbered buses; cannot join reference to MATPOWER ids" % case_name
        )

    pp.runpp(
        net,
        algorithm="nr",
        calculate_voltage_angles=True,
        enforce_q_lims=True,
        init="flat",
        tolerance_mva=1e-8,
        max_iteration=50,
    )
    if not net.converged:
        raise RuntimeError("%s: pandapower AC power flow did not converge" % case_name)

    # Read before rundcpp below replaces net._ppc with the DC solve's.
    ac_iterations = int(net._ppc["iterations"])

    ac_vm = {int(i): float(v) for i, v in net.res_bus["vm_pu"].items()}
    ac_va_raw = {int(i): float(v) for i, v in net.res_bus["va_degree"].items()}
    ac_va, ac_shift = _shift_to_slack_zero(ac_va_raw, slack_bus)
    ac_loss = _branch_loss_mw(net)
    ac_gen, ac_load = _totals_mw(net)

    # gen - load - loss must vanish; a nonzero residual means the loss figure
    # and the voltage profile disagree and the reference cannot be trusted.
    residual = ac_gen - ac_load - ac_loss
    if abs(residual) > max(0.05, 1e-6 * ac_load):
        raise RuntimeError(
            "%s: AC reference violates energy balance by %.4f MW "
            "(gen %.3f, load %.3f, loss %.3f)" % (case_name, residual, ac_gen, ac_load, ac_loss)
        )

    # Same solve with Q limits released. For IEEE-118 this reproduces the loss
    # figure MATPOWER's own `runpf case118` is documented to give (132.86 MW),
    # which is the one genuinely external number available for these cases.
    free_q = from_ppc(ppc, f_hz=60)
    pp.runpp(
        free_q,
        algorithm="nr",
        calculate_voltage_angles=True,
        enforce_q_lims=False,
        init="flat",
        tolerance_mva=1e-8,
        max_iteration=50,
    )
    unconstrained_loss = _branch_loss_mw(free_q)

    pp.rundcpp(net)
    dc_va_raw = {int(i): float(v) for i, v in net.res_bus["va_degree"].items()}
    dc_va, dc_shift = _shift_to_slack_zero(dc_va_raw, slack_bus)

    # Cross-check against the solved profile shipped inside the case file.
    embedded_vm = {int(r[BUS_I]): float(r[VM]) for r in ppc["bus"]}
    embedded_va_raw = {int(r[BUS_I]): float(r[VA]) for r in ppc["bus"]}
    embedded_va, _ = _shift_to_slack_zero(embedded_va_raw, slack_bus)

    dvm = {b: abs(ac_vm[b] - embedded_vm[b]) for b in ac_vm}
    dva = {b: abs(ac_va[b] - embedded_va[b]) for b in ac_va}
    worst_vm_bus = max(dvm, key=dvm.get)
    worst_va_bus = max(dva, key=dva.get)

    return {
        "case": case_name,
        "base_mva": float(ppc["baseMVA"]),
        "n_buses": len(ppc["bus"]),
        "n_generators": int((ppc["gen"][:, GEN_STATUS] > 0).sum()),
        "n_branches": len(ppc["branch"]),
        "slack_bus": slack_bus,
        "angle_convention": (
            "degrees, shifted so the slack bus is exactly 0 "
            "(the Elixir solvers pin the slack angle to 0.0)"
        ),
        "ac": {
            "algorithm": "newton-raphson",
            "enforce_q_lims": True,
            "converged": True,
            "iterations": ac_iterations,
            "total_loss_mw": round(ac_loss, 6),
            "total_gen_mw": round(ac_gen, 6),
            "total_load_mw": round(ac_load, 6),
            "va_shift_deg_removed": round(ac_shift, 6),
            "buses": {
                str(b): {"vm_pu": round(ac_vm[b], 6), "va_deg": round(ac_va[b], 6)}
                for b in sorted(ac_vm)
            },
        },
        "dc": {
            "va_shift_deg_removed": round(dc_shift, 6),
            "buses": {str(b): {"va_deg": round(dc_va[b], 6)} for b in sorted(dc_va)},
        },
        "embedded_solution_check": {
            "description": (
                "AC reference vs the solved VM/VA columns of mpc.bus, which were "
                "written by a third tool (PowerWorld / the IEEE CDF converter). This "
                "is a loose corroboration, not an equality: the stored profile "
                "reflects switched shunts, tap changers and remote voltage "
                "regulation that a plain power flow does not reproduce."
            ),
            "max_abs_vm_error_pu": round(dvm[worst_vm_bus], 6),
            "worst_vm_bus": worst_vm_bus,
            "max_abs_va_error_deg": round(dva[worst_va_bus], 6),
            "worst_va_bus": worst_va_bus,
            "buses_over_0.005_pu": sum(1 for e in dvm.values() if e > 0.005),
        },
        "unconstrained_q_cross_check": {
            "description": (
                "Same solve with enforce_q_lims released, kept as a check against "
                "externally published figures where one exists. For case118 this "
                "reproduces the 132.86 MW of losses MATPOWER's own `runpf case118` "
                "is documented to give."
            ),
            "total_loss_mw": round(unconstrained_loss, 6),
        },
    }


def main(argv: list[str]) -> int:
    import pandapower as pp
    import scipy

    wanted = argv[1:] or sorted(CASES)
    stamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat()

    for case_name in wanted:
        if case_name not in CASES:
            print("unknown case %r; known: %s" % (case_name, sorted(CASES)), file=sys.stderr)
            return 2

        source = FIXTURE_DIR / CASES[case_name]
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        ppc = load_ppc(source)

        reference = solve_reference(ppc, case_name)
        reference["source_file"] = source.name
        reference["source_sha256"] = digest
        reference["generated_at"] = stamp
        reference["generated_by"] = "pandapower %s / numpy %s / scipy %s" % (
            pp.__version__,
            np.__version__,
            scipy.__version__,
        )
        reference["generator_script"] = "scripts/generate_references.py"

        out = FIXTURE_DIR / ("%s_reference.json" % case_name)
        out.write_text(json.dumps(reference, indent=1, sort_keys=False) + "\n", encoding="utf-8")

        check = reference["embedded_solution_check"]
        print(
            "%-20s %4d buses  AC loss %9.3f MW  |  vs embedded solution: "
            "max dVm %.5f pu (bus %d), max dVa %.4f deg (bus %d)  ->  %s"
            % (
                case_name,
                reference["n_buses"],
                reference["ac"]["total_loss_mw"],
                check["max_abs_vm_error_pu"],
                check["worst_vm_bus"],
                check["max_abs_va_error_deg"],
                check["worst_va_bus"],
                out.relative_to(REPO_ROOT),
            )
        )

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
