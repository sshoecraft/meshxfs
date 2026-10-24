#!/usr/bin/env python3
"""One lap of D-HARNESS-BATCH-PROOF-COMPARES-CONTENT-ONLY-SO-A-MODE-ONLY-FIX-CANNOT-BE-PROVEN: what a
control's proof reads when a fix changes only a file's mode.

tools/harness_batch.py proof decides that a control's tree differed from the candidate only by the
fix's files by comparing the input snapshots' stamps (tools/release_candidate.py stamp_of), and it
compared content hashes alone, which no chmod changes: proof of control b20261023-844929, whose
only change was the execute bit of tests/release_step_copy_race.py, printed FAILS. The lap takes a
file of its own in a fresh temporary directory, stamps it as a snapshot does, sets its execute
bits, stamps it again, and hands both to the proof's own comparison (compare_inputs):

    EXPOSED   the two stamps carry the same content hash and the file's mode really changed
              (os.stat before and after)
    PASS      compare_inputs lists the file as differing in content, as proof needs a fix's file
              to be listed
    FAIL      it does not (it lists the file as touched only, or not at all)

MXFS_PROOF_MODE=0 (tools/harness_batch.py) compares the hashes alone, as before the fix: the
same-build control. The comparison runs in this process, so the switch is read from the lap's
environment.

Bound, derived: two stat calls, one chmod and an import of tools/harness_batch.py; the precheck on
2026-10-24 took 0.09-0.11 s on both arms, so a batch lap is bounded at twice the longest, rounded up
to the next second, 1 s.

Usage: tests/proof_mode_lap.py
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import harness_batch  # noqa: E402
import release_candidate  # noqa: E402


def main() -> int:
    print(f"INFO MXFS_PROOF_MODE={os.environ.get('MXFS_PROOF_MODE') or '(unset)'}")
    base = Path(tempfile.mkdtemp(prefix="proof_mode_lap."))
    try:
        target = base / "fix_target.py"
        target.write_text("#!/usr/bin/env python3\nprint('a lap file whose mode a fix changes')\n")
        target.chmod(0o664)
        key = str(target)
        before = {key: release_candidate.stamp_of(key)}
        mode0 = stat.S_IMODE(os.stat(target).st_mode)
        target.chmod(0o775)
        during = {key: release_candidate.stamp_of(key)}
        mode1 = stat.S_IMODE(os.stat(target).st_mode)
        if before[key][0] != during[key][0] or mode0 == mode1:
            print(f"ABORT: not exposed: hash {before[key][0][:12]} -> {during[key][0][:12]}, "
                  f"mode {mode0:o} -> {mode1:o}")
            return 2
        print(f"EXPOSED: the file's mode changed {mode0:o} -> {mode1:o} and its content hash did "
              f"not ({before[key][0][:12]})")
        found = harness_batch.compare_inputs(before, during)
        print(f"INFO compare_inputs: content={len(found['content'])} "
              f"touched={len(found['touched'])} added={len(found['added'])} "
              f"gone={len(found['gone'])}")
        if key in found["content"]:
            print("PASS: the mode-only change is listed as a content difference, as a fix's file "
                  "must be for proof to hold")
            return 0
        where = "touched only" if key in found["touched"] else "not at all"
        print(f"FAIL: the mode-only change is listed {where}, so proof cannot find the fix's file")
        return 1
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
