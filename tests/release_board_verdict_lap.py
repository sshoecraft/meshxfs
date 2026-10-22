#!/usr/bin/env python3
"""One lap of D-RELEASE-RUN-BOARD-VERDICT-GRADED-NO-ROW-OF-AN-OWN-RIG-BOARD.

tools/release_run.py grades the DRBD step's board with board_verdict(candidate, 2/net/mesh/drbd,
tests/evidence/drbd_rig/criteria.json), from the orchestrator, where MXFS_OWN_RIG is not set. A
configuration of an attachment verified on its own rig parses only with that flag, so a
board_verdict that does not set it itself grades no row and returns [], which reads as clean.

The lap calls board_verdict twice, each in a fresh interpreter: as the orchestrator does (the
flag unset), and with the flag set by the caller, which grades the board's rows whichever way
board_verdict handles the flag. The two must name the same rows.

    EXPOSED   the board has rows that are not green for the candidate, so an empty verdict is
              wrong (when every row is green, an empty verdict is right and the lap cannot tell)
    PASS      the orchestrator's verdict names the same rows
    FAIL      it names others (an empty one: the board was graded clean without a row graded)

Bound, derived: two interpreter starts reading the board and its ledger, ~1 s each; 30 s.

Usage: tests/release_board_verdict_lap.py [candidate]   (default: VERSION)
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = "2/net/mesh/drbd"
BOARD = ROOT / "tests" / "evidence" / "drbd_rig" / "criteria.json"

# The probe takes its inputs from the environment, never from its command line: criteria.py sets
# MXFS_OWN_RIG itself at import when any argument names an own-rig configuration, so a probe
# handed 2/net/mesh/drbd as an argument graded the board whatever board_verdict did, and its
# control laps all passed with the fix out. The orchestrator's command line names no
# configuration (release_run.py start <candidate>).
PROBE = """
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["LAP_ROOT"] + "/tools")
import release_run
print(json.dumps(release_run.board_verdict(os.environ["LAP_CANDIDATE"], os.environ["LAP_CONFIG"],
                                           Path(os.environ["LAP_BOARD"]))))
"""


def verdict(candidate: str, own_rig: bool) -> list:
    env = dict(os.environ, LAP_ROOT=str(ROOT), LAP_CANDIDATE=candidate, LAP_CONFIG=CONFIG,
               LAP_BOARD=str(BOARD))
    env.pop("MXFS_OWN_RIG", None)
    env.pop("MXFS_CRIT", None)
    if own_rig:
        env["MXFS_OWN_RIG"] = "1"
    out = subprocess.run([sys.executable, "-c", PROBE], cwd=ROOT, env=env, capture_output=True,
                         text=True, timeout=14)
    if out.returncode != 0:
        print(f"ABORT: board_verdict (MXFS_OWN_RIG={'1' if own_rig else 'unset'}) rc={out.returncode}: "
              f"{(out.stdout + out.stderr).strip()[-300:]}")
        sys.exit(2)
    return json.loads(out.stdout.strip().splitlines()[-1])


def main() -> int:
    candidate = sys.argv[1] if len(sys.argv) > 1 else (ROOT / "VERSION").read_text().strip()
    if not BOARD.is_file():
        print(f"ABORT: no DRBD board at {BOARD}")
        return 2
    truth = verdict(candidate, own_rig=True)
    seen = verdict(candidate, own_rig=False)
    print(f"INFO candidate {candidate}: with the flag set {len(truth)} row(s) not green: {truth[:6]}")
    print(f"INFO as the orchestrator calls it: {len(seen)} row(s): {seen[:6]}")
    if truth:
        print(f"EXPOSED: {CONFIG} has {len(truth)} row(s) not green for {candidate}")
    if seen == truth:
        print(f"BOARD_VERDICT_LAP PASS the orchestrator's verdict names the {len(seen)} row(s)")
        return 0
    print(f"BOARD_VERDICT_LAP FAIL the orchestrator's verdict names {len(seen)} row(s), "
          f"the board has {len(truth)}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
