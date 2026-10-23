#!/usr/bin/env python3
"""One lap of D-TOOLS-HARNESS-BATCH-PY-CONTROL-STOPPED-A-CONTROL-BATCH.

tools/harness_batch.py runs a board-row lap as `./run.sh <at> <row>` and finds the run that lap
recorded by reading the board's run ledger before and after it. tools/criteria.py reads a ledger
once per process, and run.sh appends to it in another process, so the read after the lap returned
the copy taken before it: the lap's run was not there, and the control b20261022-545d6a stopped
after its first lap ('run.sh rc=0 recorded no run of the batch') though run.sh had recorded it
(data/criteria.runs.jsonl:7378). Its second call, started after harness_batch.py dropped the copy
before each read, found every lap.

The lap reads a scratch board's ledger through harness_batch.py as a board lap does (the stamps
before the lap), appends a run of a lap-unique batch to that ledger from another process through
tools/criteria.py append_ledger (as run.sh's record does), and then asks harness_batch.py for the
lap's runs.

    EXPOSED  the run is in the ledger file, appended by another process after the first read
    PASS     harness_batch.py found that run
    FAIL     it did not

MXFS_HARNESS_BATCH_REREAD=0 in the environment keeps the ledger copy, as before the fix: the
control. The scratch board is a copy of data/criteria.json in a directory of its own (MXFS_CRIT);
nothing is written to the release board or its ledger.

Bound, derived: three interpreters importing tools/criteria.py (~0.3 s each) and a copy of the
board; 10 s.

Usage: tests/harness_batch_reread_lap.py
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = "2/net/mesh/direct"
ROW = "lap:harness_batch_reread"

APPEND = """
import json, sys
sys.path.insert(0, sys.argv[1])
import criteria
criteria.append_ledger(sys.argv[2], [json.loads(sys.argv[3])])
"""


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="harness_batch_reread.") as scratch:
        board = Path(scratch) / "criteria.json"
        shutil.copyfile(ROOT / "data" / "criteria.json", board)
        os.environ["MXFS_CRIT"] = str(board)
        sys.path.insert(0, str(ROOT / "tools"))
        import harness_batch  # noqa: E402
        bid = f"b-lap-{uuid.uuid4().hex[:6]}"
        before = harness_batch.stamps_before(board, CONFIG, ROW)
        iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        run = {"kind": "run", "config": CONFIG, "row": ROW, "iso": iso, "outcome": "PASS",
               "status": "PASS", "measured": "lap", "batch": bid, "build": None}
        out = subprocess.run([sys.executable, "-c", APPEND, str(ROOT / "tools"), str(board),
                              json.dumps(run)], capture_output=True, text=True, timeout=5)
        ledger = Path(scratch) / "criteria.runs.jsonl"
        lines = ledger.read_text().splitlines() if ledger.exists() else []
        if out.returncode != 0 or not any(json.loads(l).get("batch") == bid for l in lines):
            print(f"UNMEASURED: no run of {bid} reached the scratch ledger (rc={out.returncode}): "
                  f"{(out.stdout + out.stderr).strip()[-300:]}")
            return 2
        print(f"EXPOSED: another process appended {CONFIG}:{ROW}:{iso} of batch {bid} after "
              f"harness_batch.py read the ledger ({len(before)} earlier runs of the row)")
        found = harness_batch.lap_runs(board, CONFIG, ROW, bid, before)
    if [r.get("iso") for r in found] == [iso]:
        print(f"PASS: harness_batch.py found the lap's run {CONFIG}:{ROW}:{iso}")
        return 0
    print(f"FAIL: harness_batch.py found {len(found)} run(s) of the batch after the lap: the run "
          f"another process recorded was read from the copy taken before it")
    return 1


if __name__ == "__main__":
    sys.exit(main())
