#!/usr/bin/env python3
"""One lap of D-FREEZE-HOOK-LETS-A-NEW-FILE-INTO-A-FROZEN-DIRECTORY.

scripts/candidate_freeze_hook.py refuses an Edit or Write to a file a RUNNING candidate froze. It
asked only whether the path was in the candidate's frozen list, so a Write creating a new file in
a frozen directory went through, and drift (tools/release_candidate.py) counts an added file as a
change that makes the candidate INVALID: a Write of tests/typeflip_shell_dead_lap.sh went through
while attempt 17 of 0.90.134 was RUNNING.

The lap hands the hook three Write events, as Claude Code does (JSON on stdin), and reads its exit:

    new      a path that does not exist, under tests/ (a frozen directory): the fix refuses (2)
    frozen   a file in the candidate's frozen list: refused (2) in both arms
    mutable  a new path under tests/evidence/ (mutable): let through (0) in both arms

    EXPOSED  a candidate is RUNNING and the new path is absent from its frozen list
    PASS     new 2, frozen 2, mutable 0
    FAIL     anything else

MXFS_FREEZE_NEW_FILES=0 in the lap's environment, which the hook inherits, is the control: the
hook asks only the frozen list, as before. Nothing is written: the hook only reads.

Bound: three hook runs, each a Python start and a read of the candidate's file list (~0.3 s), so
10 s at well over twice.

Usage: tests/freeze_hook_new_file_lap.py
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "scripts" / "candidate_freeze_hook.py"
HOOK_BOUND = 10


def hook(path: Path) -> int:
    event = {"tool_name": "Write", "tool_input": {"file_path": str(path), "content": ""}}
    out = subprocess.run([sys.executable, str(HOOK)], input=json.dumps(event), cwd=ROOT,
                         capture_output=True, text=True, timeout=HOOK_BOUND)
    print(f"  hook {path.relative_to(ROOT)}: exit {out.returncode} "
          f"{out.stderr.strip().splitlines()[0][:160] if out.stderr.strip() else ''}")
    return out.returncode


def main() -> int:
    print(f"INFO MXFS_FREEZE_NEW_FILES={os.environ.get('MXFS_FREEZE_NEW_FILES') or '(unset)'}")
    try:
        active = json.loads((ROOT / "data" / "candidates" / "active.json").read_text())
    except (OSError, ValueError) as exc:
        print(f"UNMEASURED: no readable data/candidates/active.json ({exc})")
        return 2
    if active.get("state") != "RUNNING":
        print(f"UNMEASURED: no candidate is RUNNING (state {active.get('state')}), so the hook "
              f"freezes nothing")
        return 2
    sys.path.insert(0, str(ROOT / "tools"))
    import release_candidate  # noqa: E402
    files = json.loads((ROOT / release_candidate.load(active["candidate"])["files"]).read_text())
    tag = uuid.uuid4().hex[:12]
    new = ROOT / "tests" / f"freeze_hook_lap_{tag}.sh"
    mutable = ROOT / "tests" / "evidence" / f"freeze_hook_lap_{tag}.txt"
    frozen = ROOT / "run.sh"
    if new.exists() or str(new.relative_to(ROOT)) in files or "run.sh" not in files:
        print("UNMEASURED: the new path exists or is listed, or run.sh is not frozen")
        return 2
    print(f"EXPOSED: candidate {active['candidate']} is RUNNING and "
          f"{new.relative_to(ROOT)} is absent from its {len(files)} frozen files")
    try:
        got = {"new": hook(new), "frozen": hook(frozen), "mutable": hook(mutable)}
    except subprocess.TimeoutExpired:
        print(f"UNMEASURED: the hook overran its {HOOK_BOUND} s bound")
        return 2
    want = {"new": 2, "frozen": 2, "mutable": 0}
    wrong = [f"{k} exit {got[k]} (want {want[k]})" for k in want if got[k] != want[k]]
    if wrong:
        print(f"FREEZE_HOOK_LAP FAIL: {'; '.join(wrong)}")
        return 1
    print("FREEZE_HOOK_LAP PASS: the hook refused the new file in tests/ and the frozen run.sh, "
          "and let the new file in tests/evidence/ through")
    return 0


if __name__ == "__main__":
    sys.exit(main())
