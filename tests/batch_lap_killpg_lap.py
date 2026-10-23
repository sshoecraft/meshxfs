#!/usr/bin/env python3
"""One lap of D-BATCH-LAP-TIMEOUT-KILLS-ONLY-THE-DIRECT-CHILD-SO-THE-HARNESS-WRITES-ON.

tools/batch_lap.py bounds a harness lap. With subprocess.run(timeout=) only the direct child was
killed when the bound ran out; the harness's own children went on running and writing into the
lap's log, and the evidence the lap was graded from, after the lap had been recorded.

The lap runs tools/batch_lap.py run_bounded() on a harness that starts a child of its own, which
sleeps 2 s and then appends a line to a scratch file, while the harness itself sleeps 10 s: the
1 s bound runs out with both alive. The lap then waits 4 s, twice the child's sleep, and reads the
scratch file.

    EXPOSED  the bound ran out with the harness's child alive (run_bounded returned 124)
    PASS     nothing was written after run_bounded returned
    FAIL     the child's line landed after the lap would have been recorded

MXFS_BATCH_LAP_KILLPG=0 in the environment ends only the direct child, as before the fix: the
control.

Bound, derived: one interpreter importing tools/batch_lap.py (~0.3 s), the 1 s bound, at most
2 x 5 s for the group to end (KILL_GRACE_S), the 4 s wait; 20 s.

Usage: tests/batch_lap_killpg_lap.py
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import batch_lap  # noqa: E402

CHILD = ("import sys, time; time.sleep(2); "
         "open(sys.argv[1], 'a').write('the harness child wrote on\\n')")


def harness(marker: str) -> int:
    subprocess.Popen([sys.executable, "-c", CHILD, marker])
    print("harness: started a child that writes in 2 s; sleeping 10 s", flush=True)
    time.sleep(10)
    return 0


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="batch_lap_killpg.") as scratch:
        marker = Path(scratch) / "marker"
        log = Path(scratch) / "lap.log"
        with log.open("w") as handle:
            rc = batch_lap.run_bounded([sys.executable, __file__, "--harness", str(marker)],
                                       ROOT, handle, 1)
        returned = time.time()
        if rc != 124:
            print(f"UNMEASURED: the 1 s bound did not run out (rc={rc}): "
                  f"{log.read_text(errors='replace').strip()[-300:]}")
            return 2
        print("EXPOSED: the bound ran out with the harness's child alive (rc=124)")
        time.sleep(4)
        late = marker.exists() and marker.stat().st_mtime >= returned
        text = log.read_text(errors="replace").strip()
    print(f"lap log: {text[-300:]}")
    if late:
        print("FAIL: the harness's child wrote after the lap was bounded and recorded")
        return 1
    print("PASS: nothing the lap started wrote after its bound ended it")
    return 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--harness"]:
        sys.exit(harness(sys.argv[2]))
    sys.exit(main())
