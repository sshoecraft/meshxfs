#!/usr/bin/env python3
"""One lap of a declared batch whose row is a harness, not a board row.

    tools/batch_lap.py --batch <id> --at <configuration> --row <row> --bound <s>
                       --pass <regex> [--fail <regex>] [--evidence <dir or glob>]...
                       [--build-from <mxfs.ko>] -- <command> [args...]

A batch (tools/defects.py batch / plan-verify) counts laps from the run ledger: every lap is a run
of the batch's row at its configuration, keyed (configuration, row, iso), and run.sh records one
for each board row it runs. A defect found in a harness that is not a board row -- an entry of the
capture fault gate, a host-only check -- had no way to record a lap, so its fix could never be
measured against a control and verified, and the record could never leave the queue. This runs
the harness once and records the lap the way run.sh records a board row's:

  - it asks the queue first (`defects.py batch-check`), which refuses a lap outside an open,
    declared batch with this row, configuration and candidate, or past its planned count, and
    names the batch's probe and variant;
  - the harness runs under `--bound` seconds, which the caller derives from what the harness
    takes (RULE: TIMEOUTS ARE PERFORMANCE ASSERTIONS, NOT SAFETY NETS); an overrun is a FAIL;
  - the outcome is read from the harness's own verdict line: PASS when a line matches `--pass`,
    FAIL when one matches `--fail` or the bound ran out, INCOMPLETE when neither (it measured
    nothing anyone can name);
  - exposure: the batch's probe counted in the lap's own output and in every file under each
    `--evidence` path the lap wrote, appended to `measured` as `exposure=<n>` (tools/defects.py
    exposed() reads it). A harness's trigger shows in its own log, not in a kernel's;
  - the run carries the build (`--build-from`, the tree's mxfs.ko by default), the candidate
    (MXFS_CANDIDATE), the batch, and the batch's variant as `batch:<variant>`, as run.sh's does;
  - it is appended, under the board's lock, to the ledger of the board that keeps the batch's
    configuration (tools/criteria.py board_for and append_ledger, as tools/release_run.py records
    its steps), which is where tools/defects.py reads the batch's laps; the lap's log is its
    evidence.

Exit status: 0 PASS, 1 FAIL, 2 INCOMPLETE or refused.
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import criteria  # noqa: E402


def stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def batch_check(args) -> dict:
    """The queue's answer for this lap: PROBE, VARIANT, LEAVES_CLUSTER; exit when it refuses."""
    cmd = ["python3", str(ROOT / "tools" / "defects.py"), "batch-check", args.batch,
           "--row", args.row, "--at", args.at]
    if os.environ.get("MXFS_CANDIDATE"):
        cmd += ["--candidate", os.environ["MXFS_CANDIDATE"]]
    out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stdout + out.stderr, end="")
        sys.exit("batch_lap: the queue refused this lap (above)")
    answer = {}
    for line in out.stdout.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            answer[key.strip()] = value
    return answer


def build_of(ko: str) -> str:
    out = subprocess.run(["modinfo", "-F", "srcversion", ko], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else ""


def written_since(paths: list, t0: float) -> list:
    """Every regular file under the given dirs or globs modified since the lap began."""
    candidates = []
    for pattern in paths:
        for top in glob.glob(str(ROOT / pattern)):
            if os.path.isfile(top):
                candidates.append(top)
            for base, dirs, names in os.walk(top):
                candidates += [os.path.join(base, name) for name in names]
    found = []
    for path in candidates:
        try:
            if os.path.getmtime(path) >= t0:
                found.append(path)
        except OSError:
            continue
    return sorted(set(found))


def count_probe(probe: str, texts: list) -> int:
    pattern = re.compile(probe)
    return sum(1 for text in texts for line in text.splitlines() if pattern.search(line))


def fresh_iso(board: Path, config: str, row: str) -> str:
    """A stamp no run of this row at this configuration already carries."""
    taken = {str(r.get("iso", "")) for r in criteria.ledger_runs(board, config, row)}
    iso = stamp()
    while iso in taken:
        time.sleep(0.2)
        iso = stamp()
    return iso


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--batch", required=True)
    parser.add_argument("--at", required=True, help="the batch's configuration")
    parser.add_argument("--row", required=True, help="the batch's row (a harness, e.g. gate:<entry>)")
    parser.add_argument("--bound", type=int, required=True,
                        help="seconds, derived from what the harness takes; an overrun is a FAIL")
    parser.add_argument("--pass", dest="passed", required=True, help="regex of the harness's PASS line")
    parser.add_argument("--fail", dest="failed", default="", help="regex of its FAIL line")
    parser.add_argument("--evidence", action="append", default=[],
                        help="a dir or glob the harness writes its lap into (repeat)")
    parser.add_argument("--build-from", default=str(ROOT / "mxfs.ko"))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        sys.exit("batch_lap: name the harness command after --")
    config = criteria.parse_at(args.at)
    answer = batch_check(args)
    probe, variant = answer.get("PROBE", ""), answer.get("VARIANT", "")
    build = build_of(args.build_from)
    if not build:
        sys.exit(f"batch_lap: no srcversion in {args.build_from}: a run must carry its build")
    logdir = ROOT / "tests" / "evidence" / "batch_laps" / args.batch
    logdir.mkdir(parents=True, exist_ok=True)
    log = logdir / f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.log"
    print(f"--- batch {args.batch}: one lap of {args.row} at {config}"
          f"{', exposure probe ' + repr(probe) if probe else ''}"
          f"{', variant ' + variant if variant else ''}; bound {args.bound}s; log {log} ---",
          flush=True)
    t0 = time.time()
    with log.open("w") as handle:
        handle.write(f"=== {stamp()} {' '.join(command)} (bound {args.bound}s) ===\n")
        handle.flush()
        try:
            rc = subprocess.run(command, cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT,
                                timeout=args.bound).returncode
        except subprocess.TimeoutExpired:
            rc = 124
        elapsed = int(time.time() - t0)
        handle.write(f"=== rc={rc} elapsed={elapsed}s ({stamp()}) ===\n")
    text = log.read_text(errors="replace")
    pass_line = next((l for l in text.splitlines() if re.search(args.passed, l)), "")
    fail_line = next((l for l in text.splitlines() if args.failed and re.search(args.failed, l)), "")
    if rc == 124:
        outcome, reason = "FAIL", f"elapsed>{args.bound}s: the harness overran its bound"
    elif fail_line:
        outcome, reason = "FAIL", fail_line.strip()
    elif pass_line:
        outcome, reason = "PASS", pass_line.strip()
    else:
        outcome, reason = "INCOMPLETE", f"no verdict line (rc={rc}): {text.strip().splitlines()[-1][:300]}"
    files = written_since(args.evidence, t0)
    measured = f"rc={rc} elapsed_s={elapsed}"
    if probe:
        texts = [text] + [Path(p).read_text(errors="replace") for p in files]
        measured += f" exposure={count_probe(probe, texts)}"
    with log.open("a") as handle:
        handle.write("=== evidence files the lap wrote: " + " ".join(
            os.path.relpath(p, ROOT) for p in files) + " ===\n")
    # the ledger tools/defects.py batch_runs reads this batch's laps from
    board = criteria.board_for(config)
    handle = criteria.lock_board(board)
    iso = fresh_iso(board, config, args.row)
    run = {"kind": "run", "config": config, "row": args.row, "iso": iso, "outcome": outcome,
           "status": outcome, "measured": measured, "reason": reason[:2000],
           "elapsed_s": elapsed, "budget_s": args.bound, "build": build,
           "run_id": f"{iso.replace('-', '').replace(':', '')}-batchlap-{uuid.uuid4().hex[:4]}",
           "batch": args.batch, "evidence": str(log.relative_to(ROOT))}
    if os.environ.get("MXFS_CANDIDATE"):
        run["candidate"] = os.environ["MXFS_CANDIDATE"]
    if variant:
        run["variant"] = f"batch:{variant}"
    criteria.append_ledger(board, [run])
    del handle
    print(f"{outcome} {config}:{args.row}:{iso} {measured} -- {reason[:200]}")
    return {"PASS": 0, "FAIL": 1}.get(outcome, 2)


if __name__ == "__main__":
    sys.exit(main())
