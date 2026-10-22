#!/usr/bin/env python3
"""One lap of D-RELEASE-RUN-STEP-INCIDENTS-CANNOT-BE-SETTLED.

tools/release_run.py records each step's outcome as a run of row `release:<step>`, filed under
the placeholder configuration `1/any` or the step's own. The incident gate lists a failed one
until a record names it (tools/defects.py update --cell CONFIG:ROW:ISO) or a reviewed annotation
settles it (tools/criteria.py amend/infra). Each of those must take that run's key:

  - defects.parse_cell reads it as configuration `1/any`, row `release:<step>`, the stamp whole
    (splitting at the first two colons read row `release` and stamp `<step>:...`, and parse_at
    refused `1/any`);
  - defects.check_cells finds the run in the primary ledger, where release_run.py writes it, as a
    run that did not pass;
  - criteria.annotated_run gives the annotation that row and configuration (a find() on the board
    knows no `release:` row).

The lap runs the three, in a fresh interpreter, on one release step FAIL the ledger holds.

    EXPOSED   the ledger holds that run, a FAIL of a `release:` row (nothing else is the trigger)
    PASS      all three take it, with row `release:<step>`, configuration `1/any` and the stamp
    FAIL      any of them refuses it or reads another row, configuration or stamp

Bound, derived: one interpreter start reading the queue and the primary ledger, ~1-2 s; 30 s.

Usage: tests/release_step_cell_lap.py [CONFIG:ROW:ISO]
       (default 1/any:release:boards:2026-10-21T19:29:49Z, a step FAIL of dry run 0.90.133-2)
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PROBE = """
import json, os, sys, types
sys.path.insert(0, os.environ["LAP_ROOT"] + "/tools")
import criteria, defects
cell = os.environ["LAP_CELL"]
out = {}
try:
    out["parsed"] = defects.parse_cell(cell, False)
except SystemExit as exc:
    out["parse_error"] = str(exc)
    print(json.dumps(out)); sys.exit(0)
try:
    defects.check_cells([out["parsed"]])
    out["checked"] = True
except SystemExit as exc:
    out["check_error"] = str(exc)
try:
    data = criteria.read_board(criteria.SPEC)
    args = types.SimpleNamespace(id=out["parsed"]["row"], at=out["parsed"]["config"])
    out["annotated"] = list(criteria.annotated_run(data, args))
except SystemExit as exc:
    out["annotate_error"] = str(exc)
print(json.dumps(out))
"""


def main() -> int:
    cell = sys.argv[1] if len(sys.argv) > 1 else "1/any:release:boards:2026-10-21T19:29:49Z"
    config, rest = cell.split(":", 1)
    row, iso = rest.rsplit(":", 3)[0], ":".join(rest.rsplit(":", 3)[1:])
    want = {"config": config, "row": row, "iso": iso}
    ledger = ROOT / "data" / "criteria.runs.jsonl"
    found = None
    with ledger.open() as handle:
        for line in handle:
            if f'"{iso}"' not in line:
                continue
            try:
                run = json.loads(line)
            except ValueError:
                continue
            if run.get("kind") == "run" and run.get("row") == row and run.get("iso") == iso \
                    and run.get("config") == config:
                found = run
    if not found:
        print(f"ABORT: the primary ledger holds no run {cell}")
        return 2
    if row.startswith("release:") and found.get("outcome") == "FAIL":
        print(f"EXPOSED: {cell} is a recorded FAIL of release step {row}")
    env = dict(os.environ, LAP_ROOT=str(ROOT), LAP_CELL=cell)
    env.pop("MXFS_CRIT", None)
    env.pop("MXFS_OWN_RIG", None)
    out = subprocess.run([sys.executable, "-c", PROBE], cwd=ROOT, env=env, capture_output=True,
                         text=True, timeout=25)
    if out.returncode != 0 or not out.stdout.strip():
        print(f"ABORT: probe rc={out.returncode}: {(out.stdout + out.stderr).strip()[-300:]}")
        return 2
    seen = json.loads(out.stdout.strip().splitlines()[-1])
    print(f"INFO {json.dumps(seen)[:600]}")
    wrong = []
    if seen.get("parse_error"):
        wrong.append(f"parse_cell refused it: {seen['parse_error'][:160]}")
    elif seen.get("parsed") != want:
        wrong.append(f"parse_cell read {seen.get('parsed')}, not {want}")
    if not wrong:
        if seen.get("check_error"):
            wrong.append(f"check_cells refused it: {seen['check_error'][:160]}")
        if seen.get("annotate_error"):
            wrong.append(f"annotated_run refused it: {seen['annotate_error'][:160]}")
        elif seen.get("annotated") != [row, config]:
            wrong.append(f"annotated_run read {seen.get('annotated')}, not {[row, config]}")
    if wrong:
        print("STEP_CELL_LAP FAIL " + "; ".join(wrong))
        return 1
    print(f"STEP_CELL_LAP PASS {cell} parses, is found in the ledger and can be annotated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
