#!/usr/bin/env python3
"""One lap of D-TAUTH-LAPS-RELINK-FROZEN-TEST-BINARIES-AND-INVALIDATE-THE-CANDIDATE.

tests/tauth/adopted_grant_handoff_test.sh and tests/tauth/fenced_node_ledger_test.sh are the laps
of two records' verification batches, and a verification batch runs on a frozen release
candidate: a lap that rewrites a frozen file makes the candidate it runs on INVALID
(tools/release_candidate.py check). The lap stats every frozen file (release_candidate's
frozen_paths(), the set a freeze hashes), runs both tests as their laps run them, and stats the
set again, comparing as release_candidate's drift() does: a file whose inode, size or change time
moved has changed, and a file that joined or left the set too.

    EXPOSED  both tests were built and run (each printed its rc= line), which is the trigger
    PASS     no frozen file changed
    FAIL     a frozen file changed (named)

Bound, derived: each test is a compile of its .c and a link (~1-2 s, the shared objects already
built) and a run (under 12 s and under 10 s, each bounded at 60 s by its script); the two stat
passes over ~2500 files are under 1 s; about 30 s in all, bounded at 60 s. A first lap after a
change to dlm/dlm.c also rebuilds obj/dlm.o.

Usage: tests/tauth_freeze_lap.py
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import release_candidate  # noqa: E402

TESTS = ("tests/tauth/adopted_grant_handoff_test.sh", "tests/tauth/fenced_node_ledger_test.sh")


def snapshot() -> dict:
    stamps = {}
    for rel in release_candidate.frozen_paths():
        path = Path(rel) if os.path.isabs(rel) else ROOT / rel
        try:
            info = path.stat()
        except OSError:
            continue
        stamps[rel] = (info.st_ino, info.st_size, info.st_ctime_ns)
    return stamps


def main() -> int:
    before = snapshot()
    ran = []
    for test in TESTS:
        out = subprocess.run([str(ROOT / test)], cwd=ROOT, capture_output=True, text=True,
                             timeout=90)
        line = next((l for l in reversed(out.stdout.splitlines()) if l.startswith("rc=")), "")
        print(f"INFO {test}: rc={out.returncode} {line[:200]}")
        if out.returncode == 2 or not line:
            print(f"ABORT: {test} did not build or run: {(out.stdout + out.stderr).strip()[-300:]}")
            return 2
        ran.append(test)
    after = snapshot()
    print(f"EXPOSED: both tauth tests were built and run ({', '.join(Path(t).name for t in ran)})")
    changed = [rel for rel in sorted(set(before) | set(after)) if before.get(rel) != after.get(rel)]
    if changed:
        print("TAUTH_FREEZE_LAP FAIL frozen file(s) changed: " + ", ".join(changed[:20]))
        return 1
    print(f"TAUTH_FREEZE_LAP PASS none of the {len(after)} frozen files changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
