#!/usr/bin/env python3
"""One lap of D-BATCH-LAP-RECORDS-NO-STALL-SO-A-HARNESS-LAP-OVER-THE-STALL-LIMIT-GRADES-PASS.

tools/batch_lap.py records a harness lap's outcome from the harness's own verdict line. A board
row's operation stall over the policy's stall_limit_s turns its PASS into a FAIL
(tools/criteria.py stall_over_limit), but a harness lap's stall was neither recorded nor graded,
so a lap in which an operation stalled 31 s and that then printed its PASS line recorded a PASS.

The lap records one harness lap end to end through tools/batch_lap.py main(), on scratch copies
of the queue and the board (MXFS_DEFECTS, MXFS_CRIT), so nothing reaches the real ledgers: it
declares a one-lap calibration batch of this record there (row lap:batch_lap_stall_inner at
2/net/mesh/direct), runs batch_lap.py on a harness that prints one operation a second over the
limit as `max_stall_ms=`, another half a second longer through a pattern the lap declares
(`--stall '\\bop_ms=(\\d+)'`), and then `RESULT: PASS`, and reads the run batch_lap.py appended to
the scratch ledger, against the limit in data/release_policy.json.

    EXPOSED  the recorded run's own log holds the operation over the stall limit and the PASS line
    PASS     the recorded run is a FAIL, its measured text carrying the longer operation's stall
    FAIL     the recorded run is a PASS

MXFS_BATCH_LAP_STALL=0 in the environment turns the fix's own switch off: the control.

Bound, derived: three interpreters (defects.py to declare, batch_lap.py, the harness), each well
under a second, and batch_lap.py's queue check; 20 s.

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


def harness(over_ms: int) -> int:
    print(f"op 1 max_stall_ms={over_ms}")
    print(f"op 2 op_ms={over_ms + 500}")
    print("RESULT: PASS label=stall")
    return 0


def quiet(text: str) -> str:
    """Text printed with the stall token renamed: this lap's own output is read by the
    tools/batch_lap.py that runs it, and a max_stall_ms= in it would grade the lap itself."""
    return text.replace("max_stall_ms=", "worst_ms=")


def main() -> int:
    limit_ms = int(criteria.policy().get("stall_limit_s", 30)) * 1000
    over_ms = limit_ms + 1000
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
        declared = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "defects.py"), "batch", RECORD, "--row", ROW,
             "--at", AT, "--kind", "calibrate", "--runs", "1", "--probe", r"\bop_ms=",
             "--build", build, "--why", "tests/batch_lap_stall_lap.py: one lap through "
             "batch_lap.py main() on a scratch queue and board"],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=30)
        found = re.search(r"\bb\d{8}-[0-9a-f]{6}\b", declared.stdout)
        if declared.returncode != 0 or not found:
            print(f"UNMEASURED: the scratch batch was not declared (rc={declared.returncode}): "
                  f"{(declared.stdout + declared.stderr).strip()[-300:]}")
            return 2
        batch = found.group(0)
        lap = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "batch_lap.py"), "--batch", batch, "--at", AT,
             "--row", ROW, "--bound", "10", "--pass", r"^RESULT: PASS", "--fail", r"^RESULT: FAIL",
             "--stall", r"\bop_ms=(\d+)", "--", sys.executable, __file__, "--harness",
             str(over_ms)],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=20)
        print(f"batch_lap.py main(): rc={lap.returncode} "
              f"{quiet((lap.stdout + lap.stderr).strip().splitlines()[-1][:300] if (lap.stdout + lap.stderr).strip() else '')}")
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
            print(f"UNMEASURED: batch_lap.py recorded {len(runs)} run(s) of scratch batch {batch}")
            return 2
        run = runs[0]
        log = ROOT / str(run.get("evidence", ""))
        text = log.read_text(errors="replace") if log.is_file() else ""
        if f"max_stall_ms={over_ms}" not in text or "RESULT: PASS" not in text:
            print(f"UNMEASURED: the recorded run's log {run.get('evidence')} holds no operation "
                  f"over the limit and PASS line")
            return 2
        print(f"EXPOSED: the run batch_lap.py recorded ({run.get('config')}:{run.get('row')}:"
              f"{run.get('iso')}, log {run.get('evidence')}) printed operations of {over_ms} and "
              f"{over_ms + 500} ms against the {limit_ms} ms limit, then its PASS line")
        measured = str(run.get("measured", ""))
        print(f"recorded {run.get('outcome')}: {quiet(measured)} -- {quiet(str(run.get('reason', '')))[:300]}")
        if run.get("outcome") == "FAIL" and f"max_stall_ms={over_ms + 500}" in measured:
            print("PASS: the recorded run of a passing lap with a stall over the limit is a FAIL")
            return 0
        print(f"FAIL: a lap with an operation of {over_ms + 500} ms was recorded {run.get('outcome')}")
        return 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["--harness"]:
        sys.exit(harness(int(sys.argv[2])))
    sys.exit(main())
