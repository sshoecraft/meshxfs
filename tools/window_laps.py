#!/usr/bin/env python3
"""window_laps.py — the window laps a configuration's board still needs, derived
from the board itself, in the LAPS form tests/release_verify_chain.sh takes.

A row reads FLAKY while a genuine FAIL sits in its 11-run window
(tools/criteria.py flake_count: the live cell plus ten past verdicts; a FAIL
whose reason is rig formation, or that carries a detector_defect amendment,
does not count).  A row whose newest genuine FAIL is at window index k (0 = the
live cell) reads PASS again only after 11-k more runs of it, the board run that
ends the chain being one of them, so it needs 10-k laps before that board.  The
chain's header derives these by hand; this reads them off the board so a count
is never guessed.

Usage: tools/window_laps.py [-v] <configuration> [<configuration> ...]
  -v  every row with a genuine FAIL in its window: k, the run's stamp and reason
Output: one LAPS entry per (configuration, lap count), rows joined by commas,
then a LAPS= line joining every entry with spaces.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import criteria  # noqa: E402  (tools/criteria.py: the board and its flake rule)


def newest_genuine_fail(entry: dict, config: str):
    """(k, run) of the newest genuine FAIL in the row's window, or (None, None)."""
    cell = criteria.cell_of(entry, config)
    if not cell:
        return None, None
    runs = ([cell] + list(cell.get("history") or []))[:criteria.FLAKE_WINDOW]
    for k, run in enumerate(runs):
        if (str(run.get("status", "")).upper().strip() == "FAIL"
                and not criteria.RIG_NOISE.search(str(run.get("reason", "")))
                and not run.get("detector_defect")):
            return k, run
    return None, None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("configs", nargs="+")
    args = parser.parse_args()
    data = criteria.load()
    specs = []
    for config in args.configs:
        by_count: dict = {}
        for entry in data["criteria"]:
            row = str(entry.get("id", ""))
            if row in criteria.NEVER_FLAKE or not criteria.applies(entry, config):
                continue
            k, run = newest_genuine_fail(entry, config)
            if k is None:
                continue
            laps = criteria.FLAKE_WINDOW - 1 - k
            if args.verbose:
                print(f"{config} {row} k={k} laps={laps} iso={run.get('iso', '?')} "
                      f"reason={criteria.flat(run.get('reason', ''), 120)}")
            if laps > 0:
                by_count.setdefault(laps, []).append(row)
        for laps in sorted(by_count, reverse=True):
            specs.append(f"{config}:{','.join(by_count[laps])}:{laps}")
    for spec in specs:
        print(spec)
    print("LAPS=" + " ".join(specs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
