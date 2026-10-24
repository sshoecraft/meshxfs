#!/usr/bin/env python3
"""Run one step of a lap for at most <bound> seconds of its own work.

    tools/lap_bounded.py <bound> -- <command> [args...]

A lap that bounds its own prep with `timeout 120 ./run.sh ... prep_cluster` counts every second
that prep spent waiting on a lock another lane held: the shared power-up hold, the pool lock, the
preflight's power-up wait. tools/batch_lap.py extends a lap's outer bound by those waits, read from
the wait ledger run.sh, tools/lun_pool.sh, scripts/clyde_preflight.sh and tests/lib/runlock.sh
append to (MXFS_LAP_WAIT_FILE), but the lap's own `timeout` reads no ledger: on attempt 20 an
8-node prep that waited 97 s for other lanes' power-ups ran out its 120 s bound in its teardown
step, and another reached its convergence step at 117 s and was cut at 120
(D-BATCH-LAP-BOUND-SPENDS-95S-BEFORE-PREP-UNLOGGED-IN-POOL-LOCK-OR-PREFLIGHT). This runs the
step under tools/batch_lap.py's run_bounded, so:

  - the bound is extended by the waits in the ledger the lap was given, or, for a lap a lane runs
    directly, a ledger of this step's own (a temporary file, exported to the step and removed
    after). MXFS_BATCH_LAP_WAIT_EXCLUDE=0 keeps none, as before: the same-build control;
  - on an overrun every process the step started is ended, SIGTERM then SIGKILL, and this returns
    only once none is left. `timeout` signals its child and returns, and a killed prep's run.sh
    was still in its teardown, holding the lap's nodes, when the lap's next step started 1 s
    later ('ERROR: test7 is held by another run'). MXFS_BATCH_LAP_KILLTREE=0 ends only the direct
    child, as before: the same-build control.

The step's output goes to this process's stdout; the overrun line run_bounded writes goes there
too. Exit status: the step's own, or 124 on an overrun, as timeout(1) returns.
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
# a copy of this file run from a tree's root (a draft beside a lap) finds that tree's batch_lap.py
sys.path.append(os.path.join(os.getcwd(), "tools"))
import batch_lap  # noqa: E402


def main() -> int:
    args = sys.argv[1:]
    if len(args) < 3 or args[1] != "--" or not args[0].isdigit():
        sys.exit("usage: tools/lap_bounded.py <bound s> -- <command> [args...]")
    bound, command = int(args[0]), args[2:]
    waits, own = None, None
    if os.environ.get("MXFS_BATCH_LAP_WAIT_EXCLUDE", "1") != "0":
        if os.environ.get("MXFS_LAP_WAIT_FILE"):
            waits = Path(os.environ["MXFS_LAP_WAIT_FILE"])
        else:
            fd, name = tempfile.mkstemp(prefix="lap_bounded.", suffix=".waits")
            os.close(fd)
            own = waits = Path(name)
            os.environ["MXFS_LAP_WAIT_FILE"] = name
    sys.stdout.flush()
    try:
        rc = batch_lap.run_bounded(command, os.getcwd(), sys.stdout, bound, waits)
    finally:
        if own is not None:
            own.unlink(missing_ok=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
