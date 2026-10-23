#!/usr/bin/env python3
"""One lap of D-BATCH-LAP-RECORDS-NO-STALL-SO-A-HARNESS-LAP-OVER-THE-STALL-LIMIT-GRADES-PASS.

tools/batch_lap.py records a harness lap's outcome from the harness's own verdict line. A board
row's operation stall over the policy's stall_limit_s turns its PASS into a FAIL
(tools/criteria.py stall_over_limit), but a harness lap's stall was neither recorded nor graded,
so a lap in which an operation stalled 31 s and that then printed its PASS line recorded a PASS.

The lap starts a harness that does exactly that: it prints one operation a second over the limit
as `max_stall_ms=`, another half a second longer through a pattern the lap declares (`op_ms=`), and
then `RESULT: PASS`. Its output is graded the way tools/batch_lap.py grades a lap (verdict(), then
stall_graded()), against the limit in data/release_policy.json.

    EXPOSED  the harness printed an operation over the stall limit and its PASS line (the trigger)
    PASS     the lap is graded FAIL, its measured text carrying the longer operation's max_stall_ms
    FAIL     the lap is graded PASS

MXFS_BATCH_LAP_STALL=0 in the environment turns the fix's own switch off: the control.

Bound, derived: one interpreter importing tools/batch_lap.py (~0.3 s) and one more for the harness
(~0.1 s); 10 s.

Usage: tests/batch_lap_stall_lap.py
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import batch_lap  # noqa: E402
import criteria  # noqa: E402


def harness(over_ms: int) -> int:
    print(f"op 1 max_stall_ms={over_ms}")
    print(f"op 2 op_ms={over_ms + 500}")
    print("RESULT: PASS label=stall")
    return 0


def main() -> int:
    limit_ms = int(criteria.policy().get("stall_limit_s", 30)) * 1000
    over_ms = limit_ms + 1000
    run = subprocess.run([sys.executable, __file__, "--harness", str(over_ms)], cwd=ROOT,
                         capture_output=True, text=True, timeout=5)
    text = run.stdout
    if f"max_stall_ms={over_ms}" not in text or "RESULT: PASS" not in text:
        print(f"UNMEASURED: the harness printed no operation over the limit and PASS line "
              f"(rc={run.returncode}): {text.strip()[-300:]} {run.stderr.strip()[-300:]}")
        return 2
    print(f"EXPOSED: a lap printed operations of {over_ms} and {over_ms + 500} ms against the "
          f"{limit_ms} ms limit, then its PASS line")
    outcome, reason = batch_lap.verdict(run.returncode, text, r"^RESULT: PASS", r"^RESULT: FAIL", 10)
    outcome, reason, measured = batch_lap.stall_graded(
        outcome, reason, f"rc={run.returncode} elapsed_s=0", [text], [r"\bop_ms=(\d+)"])
    print(f"graded {outcome}: {measured} -- {reason}")
    if outcome == "FAIL" and f"max_stall_ms={over_ms + 500}" in measured:
        print("PASS: the stall over the limit made the passing lap a FAIL")
        return 0
    print(f"FAIL: a lap with an operation of {over_ms + 500} ms was graded {outcome}")
    return 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["--harness"]:
        sys.exit(harness(int(sys.argv[2])))
    sys.exit(main())
