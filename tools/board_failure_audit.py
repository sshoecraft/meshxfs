#!/usr/bin/env python3
"""board_failure_audit.py — every non-PASS verdict a board recorded since a
time, and whether the defect queue or a removal names it.

A failure is never aged out of the record: a board row that failed and then
passed often enough reads PASS again (tools/criteria.py's flake window), and
the failure is then visible only in the cell's history.  Before a release,
every one of them must be named by the evidence of an open record in
data/defects.json or by the --why of a removal (which lands in CHANGELOG.md),
and passing laps never stand in for that.  This lists them, live cells and
history alike, and marks each NAMED when its stamp (the cell's iso, e.g.
2026-10-19T15:51:52Z) appears in either file, else UNNAMED.

Usage: tools/board_failure_audit.py --since 2026-10-16T00:00:00Z [-u] [<configuration> ...]
  default configurations: every one the main board has a column for, plus
  2/net/mesh/drbd from its own board (one process per board file: tools/criteria.py
  picks its board from the command line at import, so the DRBD board is read
  by a second invocation of this tool)
  -u  print only the UNNAMED ones
Exit 1 if any is UNNAMED.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import criteria  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
NONPASS = ("FAIL", "FLAKY", "ABORTED", "BLOCKED", "SKIP", "NOT RUN", "NOT_RUN")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--since", required=True)
    parser.add_argument("-u", "--unnamed", action="store_true")
    parser.add_argument("configs", nargs="*")
    args = parser.parse_args()
    if not args.configs:
        rc = subprocess.call([sys.executable, __file__, "--since", args.since]
                             + (["-u"] if args.unnamed else []) + ["2/net/mesh/drbd"])
        configs = [c for c in criteria.CONFIGS if not c.endswith("/drbd")]
    else:
        rc = 0
        configs = args.configs
    text = (ROOT / "data" / "defects.json").read_text() + (ROOT / "CHANGELOG.md").read_text()
    data = criteria.load()
    unnamed = 0
    for config in configs:
        for entry in data["criteria"]:
            cell = criteria.cell_of(entry, config)
            if not cell:
                continue
            for run in [cell] + list(cell.get("history") or []):
                iso = str(run.get("iso", ""))
                status = str(run.get("status", "")).upper().strip()
                if not iso or iso < args.since or status == "PASS" or status not in NONPASS:
                    continue
                named = iso in text
                unnamed += 0 if named else 1
                if named and args.unnamed:
                    continue
                print(f"{'NAMED  ' if named else 'UNNAMED'} {config} {entry.get('id')} {status} "
                      f"{iso} {criteria.flat(run.get('reason', ''), 110)}")
    print(f"board_failure_audit: {unnamed} unnamed since {args.since}"
          f"{' (' + ' '.join(configs) + ')' if args.configs else ''}")
    return 1 if unnamed or rc else 0


if __name__ == "__main__":
    sys.exit(main())
