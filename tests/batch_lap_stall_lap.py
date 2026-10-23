#!/usr/bin/env python3
"""One lap of D-BATCH-LAP-RECORDS-NO-STALL-SO-A-HARNESS-LAP-OVER-THE-STALL-LIMIT-GRADES-PASS.

tools/batch_lap.py records a harness lap's outcome from the harness's own verdict line. A board
row's operation stall over the policy's stall_limit_s turns its PASS into a FAIL
(tools/criteria.py stall_over_limit), but a harness lap's stall was neither recorded nor graded,
so a lap in which an operation stalled 31 s and that then printed its PASS line recorded a PASS.

The lap records three harness laps end to end through tools/batch_lap.py main(), on scratch copies
of the queue and the board (MXFS_DEFECTS, MXFS_CRIT), so nothing reaches the real ledgers: for each
it declares a one-lap calibration batch of this record there (row lap:batch_lap_stall_inner_<form>
at 2/net/mesh/direct), runs batch_lap.py on a harness that prints its operations and then
`RESULT: PASS`, and reads the run batch_lap.py appended to the scratch ledger, against the limit in
data/release_policy.json. batch_lap.py reads a stall in two forms and keeps only the worst, so each
form is measured in a lap of its own, where nothing else can carry the deciding value:

    mark     one operation a second over the limit as `max_stall_ms=`, and no `--stall` declared
    pattern  one operation a second and a half over the limit through a pattern the lap declares
             (`--stall '\\bop_ms=(\\d+)'`), and no `max_stall_ms=` line
    clean    one operation a second under the limit in each form, with the pattern declared

    EXPOSED  the mark and pattern runs' own logs hold their operation over the limit and the PASS line
    PASS     the mark and pattern runs are each a FAIL whose measured text carries its own stall,
             and the clean run is a PASS
    FAIL     a run over the limit is a PASS or carries another value, or the clean run is a FAIL

MXFS_BATCH_LAP_STALL=0 in the environment turns the fix's own switch off: the control.

Bound, derived: three laps of three interpreters each (defects.py to declare, batch_lap.py with
its queue check, the harness), each well under a second; measured on the tree of 2026-10-23 at
1.5 s for all three, with the fix in and with it out; 20 s.

Usage: tests/batch_lap_stall_lap.py
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import criteria  # noqa: E402

RECORD = "D-BATCH-LAP-RECORDS-NO-STALL-SO-A-HARNESS-LAP-OVER-THE-STALL-LIMIT-GRADES-PASS"
ROW = "lap:batch_lap_stall_inner"
AT = "2/net/mesh/direct"
PATTERN = r"\bop_ms=(\d+)"


def harness(form: str, limit_ms: int) -> int:
    """The form's operations, then the PASS line. They are built here, not passed in: batch_lap.py
    writes the command into the lap's log, and an operation in its arguments would be read there
    as though the harness had printed it."""
    for line in next(lines for name, lines, *rest in forms(limit_ms) if name == form):
        print(line)
    print("RESULT: PASS label=stall")
    return 0


def quiet(text: str) -> str:
    """Text printed with the stall token renamed: this lap's own output is read by the
    tools/batch_lap.py that runs it, and a max_stall_ms= in it would grade the lap itself."""
    return text.replace("max_stall_ms=", "worst_ms=")


def forms(limit_ms: int) -> list:
    """(form, the harness's operation lines, the --stall patterns declared, the stall the run must
    carry, the outcome it must have) for each lap."""
    over_ms, under_ms = limit_ms + 1000, limit_ms - 1000
    return [("mark", [f"op 1 max_stall_ms={over_ms}"], [], over_ms, "FAIL"),
            ("pattern", [f"op 2 op_ms={over_ms + 500}"], [PATTERN], over_ms + 500, "FAIL"),
            ("clean", [f"op 1 max_stall_ms={under_ms}", f"op 2 op_ms={under_ms}"], [PATTERN],
             under_ms, "PASS")]


def recorded(s: Path, env: dict, build: str, limit_ms: int, form: str, lines: list,
             patterns: list) -> dict | str:
    """The one run batch_lap.py main() recorded for a lap of this form, or why there is none."""
    row = f"{ROW}_{form}"
    declared = subprocess.run(
        [sys.executable, str(ROOT / "tools" / "defects.py"), "batch", RECORD, "--row", row,
         "--at", AT, "--kind", "calibrate", "--runs", "1", "--probe", r"\b(max_stall|op)_ms=\d",
         "--build", build, "--why", f"tests/batch_lap_stall_lap.py: the {form} lap through "
         "batch_lap.py main() on a scratch queue and board"],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=30)
    found = re.search(r"\bb\d{8}-[0-9a-f]{6}\b", declared.stdout)
    if declared.returncode != 0 or not found:
        return (f"the scratch batch of the {form} lap was not declared (rc={declared.returncode}): "
                f"{(declared.stdout + declared.stderr).strip()[-300:]}")
    batch = found.group(0)
    stall = [arg for pattern in patterns for arg in ("--stall", pattern)]
    lap = subprocess.run(
        [sys.executable, str(ROOT / "tools" / "batch_lap.py"), "--batch", batch, "--at", AT,
         "--row", row, "--bound", "10", "--pass", r"^RESULT: PASS", "--fail", r"^RESULT: FAIL"]
        + stall + ["--", sys.executable, __file__, "--harness", form, str(limit_ms)],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=20)
    output = (lap.stdout + lap.stderr).strip()
    print(f"batch_lap.py main() {form}: rc={lap.returncode} "
          f"{quiet(output.splitlines()[-1][:300] if output else '')}")
    ledger = criteria.ledger_path(s / "criteria.json")
    runs = []
    if ledger.exists():
        for line in ledger.read_text().splitlines():
            try:
                item = json.loads(line)
            except ValueError:
                continue
            if item.get("kind") == "run" and item.get("batch") == batch:
                runs.append(item)
    if len(runs) != 1:
        return f"batch_lap.py recorded {len(runs)} run(s) of the {form} lap's scratch batch {batch}"
    run = runs[0]
    log = ROOT / str(run.get("evidence", ""))
    text = log.read_text(errors="replace") if log.is_file() else ""
    if any(line not in text for line in lines) or "RESULT: PASS" not in text:
        return (f"the {form} run's log {run.get('evidence')} does not hold its operations and "
                f"PASS line")
    return run


def main() -> int:
    limit_ms = int(criteria.policy().get("stall_limit_s", 30)) * 1000
    build = subprocess.run(["modinfo", "-F", "srcversion", str(ROOT / "mxfs.ko")],
                           capture_output=True, text=True).stdout.strip()
    if not build:
        print("UNMEASURED: no srcversion in the tree's mxfs.ko, which batch_lap.py records")
        return 2
    with tempfile.TemporaryDirectory(prefix="batch_lap_stall.") as scratch:
        s = Path(scratch)
        shutil.copy(ROOT / "data" / "defects.json", s / "defects.json")
        shutil.copy(ROOT / "data" / "criteria.json", s / "criteria.json")
        env = {k: v for k, v in os.environ.items()
               if k not in ("MXFS_CANDIDATE", "MXFS_BATCH", "MXFS_GROUP", "MXFS_NODE_LIST")}
        env.update(MXFS_DEFECTS=str(s / "defects.json"), MXFS_CRIT=str(s / "criteria.json"))
        runs = {}
        for form, lines, patterns, stall, outcome in forms(limit_ms):
            run = recorded(s, env, build, limit_ms, form, lines, patterns)
            if isinstance(run, str):
                print(f"UNMEASURED: {run}")
                return 2
            runs[form] = (run, stall, outcome)
        print("EXPOSED: the run batch_lap.py recorded of each lap over the limit printed its "
              f"operation against the {limit_ms} ms limit, then its PASS line: " + "; ".join(
                  f"{form} {stall} ms ({run.get('config')}:{run.get('row')}:{run.get('iso')}, "
                  f"log {run.get('evidence')})"
                  for form, (run, stall, outcome) in runs.items() if outcome == "FAIL"))
        wrong = []
        for form, (run, stall, outcome) in runs.items():
            measured = str(run.get("measured", ""))
            print(f"recorded {form} {run.get('outcome')}: {quiet(measured)} -- "
                  f"{quiet(str(run.get('reason', '')))[:300]}")
            carried = re.search(rf"\bmax_stall_ms={stall}\b", measured)
            if run.get("outcome") != outcome or (outcome == "FAIL" and not carried):
                wrong.append(f"{form} ({stall} ms) recorded {run.get('outcome')}"
                             f"{'' if carried else ' without its stall'}")
        if not wrong:
            print("PASS: the recorded run of each passing lap with a stall over the limit, in either "
                  "form alone, is a FAIL carrying its own stall, and the lap under the limit is a PASS")
            return 0
        print("FAIL: a lap with an operation over the limit, or one under it, was recorded wrong: "
              + "; ".join(wrong))
        return 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["--harness"]:
        sys.exit(harness(sys.argv[2], int(sys.argv[3])))
    sys.exit(main())
