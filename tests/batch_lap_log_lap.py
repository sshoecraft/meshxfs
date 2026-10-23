#!/usr/bin/env python3
"""One lap of D-BATCH-LAP-LOG-NAMED-BY-THE-SECOND-SO-SUB-SECOND-LAPS-OVERWRITE-EACH-OTHER.

tools/batch_lap.py writes each lap's log, the evidence its ledger row names, through lap_log().
Two laps of one batch that start in one second must leave two logs, each holding its own lap's
lines: named by the second alone and opened with "w", the second lap truncated the first one's log
and that lap's PASS and exposure lines survived nowhere but the ledger row.

The lap starts two processes that each import tools/batch_lap.py, wait for one shared instant at
the start of a second, open their log with batch_lap.lap_log() in one scratch directory, write
their own line and close it: the two laps a batch runs back to back, started in one second.

    EXPOSED  both processes opened their log in the same second (the trigger)
    PASS     two logs, each holding exactly its own process's line
    FAIL     one log for both, or a log that lost its own line

If the two opens fall in different seconds (the instant is 0.3 s past a second, so only a stalled
process misses it), the attempt measured nothing and is made again, three times at most.

Bound, derived: each attempt is one interpreter start importing batch_lap.py (~0.3 s) and the wait
for the instant (under 2 s); three attempts under 8 s; 20 s.

Usage: tests/batch_lap_log_lap.py
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def child(logdir: str, n: str, at: str) -> int:
    sys.path.insert(0, str(ROOT / "tools"))
    import batch_lap
    delay = float(at) - time.time()
    if delay > 0:
        time.sleep(delay)
    path, handle = batch_lap.lap_log(Path(logdir))
    second = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    with handle:
        handle.write(f"LAP {n} own line\n")
    print(json.dumps({"n": n, "path": str(path), "second": second}))
    return 0


def attempt() -> tuple:
    """(exposed, wrong, info) of one attempt; exposed None when nothing was measured."""
    logdir = tempfile.mkdtemp(prefix="mxfs_lap_log.")
    try:
        at = int(time.time()) + 2.3
        procs = [subprocess.Popen([sys.executable, __file__, "--child", logdir, str(n), str(at)],
                                  cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  text=True) for n in (1, 2)]
        seen = []
        for proc in procs:
            out, _ = proc.communicate(timeout=8)
            if proc.returncode != 0 or not out.strip():
                return None, [], f"a child failed (rc={proc.returncode}): {out.strip()[-300:]}"
            seen.append(json.loads(out.strip().splitlines()[-1]))
        if seen[0]["second"] != seen[1]["second"]:
            return None, [], f"the opens fell in seconds {seen[0]['second']} and {seen[1]['second']}"
        logs = sorted(os.listdir(logdir))
        info = f"logs {logs}; opened at {seen[0]['second']}"
        wrong = []
        if seen[0]["path"] == seen[1]["path"]:
            wrong.append(f"both laps were given one log, {Path(seen[0]['path']).name}")
        for s in seen:
            text = Path(s["path"]).read_text() if Path(s["path"]).exists() else ""
            if text != f"LAP {s['n']} own line\n":
                wrong.append(f"lap {s['n']}'s log {Path(s['path']).name} holds {text!r}, "
                             f"not its own line")
        if len(logs) != 2:
            wrong.append(f"{len(logs)} log(s) for two laps")
        return True, wrong, info
    finally:
        shutil.rmtree(logdir, ignore_errors=True)


def main() -> int:
    if sys.argv[1:2] == ["--child"]:
        return child(*sys.argv[2:5])
    for tries in range(1, 4):
        exposed, wrong, info = attempt()
        if exposed is None:
            print(f"INFO attempt {tries}: measured nothing: {info}")
            continue
        print(f"EXPOSED: two laps opened their logs in one second ({info})")
        if wrong:
            print("BATCH_LAP_LOG_LAP FAIL " + "; ".join(wrong))
            return 1
        print("BATCH_LAP_LOG_LAP PASS two laps started in one second wrote two logs, each its own")
        return 0
    print("ABORT: three attempts and no two opens in one second")
    return 2


if __name__ == "__main__":
    sys.exit(main())
