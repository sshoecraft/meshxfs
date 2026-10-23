#!/usr/bin/env python3
"""One lap of D-BATCH-LAP-TIMEOUT-KILLS-ONLY-THE-DIRECT-CHILD-SO-THE-HARNESS-WRITES-ON.

tools/batch_lap.py bounds a harness lap. With subprocess.run(timeout=) only the direct child was
killed when the bound ran out; the harness's own children went on running and writing into the
lap's log, and the evidence the lap was graded from, after the lap had been recorded. The writer
in the record's evidence ran as the capture gate runs every entry: a bash script running it under
GNU timeout (tests/capture_fault_gate.sh), which puts itself and its child in a process group of
their own, so ending the lap's process group missed it too.

The lap runs tools/batch_lap.py run_bounded() three times, each on a bash harness that starts a
writer and then sleeps 10 s, under a 1 s bound. The writer records its pid, sleeps 2 s and then
appends a line to a scratch file; each harness starts it one way a process can leave the lap's
process group or its parentage:

    timeout   `timeout 30 sh -c ...` in the foreground, without --foreground, as the gate does
    setsid    `setsid sh -c ... &`, a session of its own
    orphan    `( sh -c ... & )`, a double fork: the writer's parent exits at once

After each bound the lap waits 4 s, twice the writer's sleep, and reads the scratch file.

    EXPOSED  every writer had started, before its bound ran out, a write due after it
    PASS     no writer wrote after run_bounded returned
    FAIL     a writer's line landed after the lap would have been recorded (named by shape)

MXFS_BATCH_LAP_KILLTREE=0 in the environment ends only the direct child, as before the fix: the
control.

Bound, derived: one interpreter importing tools/batch_lap.py (~0.3 s), three times the 1 s bound,
at most 2 x 5 s for a harness's processes to end (KILL_GRACE_S) and the 4 s wait; 50 s.

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

#: The writer: its pid into $2, 2 s asleep, then a line into $1.
WRITER = "echo $$ > \"$2\"; sleep 2; echo \"the harness writer wrote on\" >> \"$1\""

#: How each harness starts the writer, then sleeps past its 1 s bound.
SHAPES = {
    "timeout": f"timeout 30 sh -c '{WRITER}' sh \"$1\" \"$2\"; sleep 10",
    "setsid": f"setsid sh -c '{WRITER}' sh \"$1\" \"$2\" & sleep 10",
    "orphan": f"( sh -c '{WRITER}' sh \"$1\" \"$2\" & ); sleep 10",
}


def one_shape(shape: str, scratch: Path) -> tuple:
    """(exposed, wrote_late, note) of one harness shape under a 1 s bound."""
    marker, started, log = (scratch / f"{shape}.marker", scratch / f"{shape}.pid",
                            scratch / f"{shape}.log")
    with log.open("w") as handle:
        begun = time.time()
        rc = batch_lap.run_bounded(["bash", "-c", SHAPES[shape], "harness", str(marker),
                                    str(started)], ROOT, handle, 1)
    returned = time.time()
    text = lambda: log.read_text(errors="replace").strip()  # noqa: E731
    if rc != 124:
        return False, False, f"the 1 s bound did not run out (rc={rc}): {text()[-200:]}"
    if not started.exists() or not started.read_text().strip():
        return False, False, f"the writer never started: {text()[-200:]}"
    due = started.stat().st_mtime + 2
    if due <= begun + 1:
        return False, False, "the writer's write was not due after the bound"
    time.sleep(4)
    late = marker.exists() and marker.stat().st_mtime >= returned
    return True, late, (f"writer pid {started.read_text().strip()}, its write due "
                        f"{due - (begun + 1):.1f} s after the bound; run_bounded: "
                        f"{text().splitlines()[-1][:200] if text() else '(nothing)'}")


def main() -> int:
    late, unexposed = [], []
    with tempfile.TemporaryDirectory(prefix="batch_lap_killtree.") as scratch:
        for shape in SHAPES:
            exposed, wrote, note = one_shape(shape, Path(scratch))
            print(f"{shape}: exposed={int(exposed)} wrote_late={int(wrote)} -- {note}")
            if not exposed:
                unexposed.append(shape)
            elif wrote:
                late.append(shape)
    if unexposed:
        print(f"UNMEASURED: {' '.join(unexposed)} did not reach its trigger")
        return 2
    print("EXPOSED: every bound ran out with its harness's writer alive and its write due "
          "(timeout, setsid, orphan)")
    if late:
        print(f"FAIL: the harness's writer wrote after the lap was bounded and recorded: "
              f"{' '.join(late)}")
        return 1
    print("PASS: nothing the lap started wrote after its bound ended it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
