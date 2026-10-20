#!/usr/bin/env python3
"""defect_stamps_only_here.py — the board-cell stamps (ISO times such as
2026-10-19T15:13:51Z) a defect record names that nothing else names.

tools/board_failure_audit.py calls a non-PASS cell named when its stamp
appears in data/defects.json or CHANGELOG.md.  Removing a record takes its
evidence out of the queue, so a cell named only there becomes unnamed unless
the removal's --why (pasted into CHANGELOG.md) names it again.  Run this
before `tools/defects.py remove <id>` and carry every stamp it prints into the
--why.

Usage: tools/defect_stamps_only_here.py <id>
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STAMP = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    want = sys.argv[1]
    data = json.loads((ROOT / "data" / "defects.json").read_text())
    recs = data["defects"] if isinstance(data, dict) and "defects" in data else data
    recs = list(recs.values()) if isinstance(recs, dict) else recs
    mine = [r for r in recs if r.get("id") == want]
    if not mine:
        print(f"no record {want}", file=sys.stderr)
        return 1
    others = json.dumps([r for r in recs if r.get("id") != want])
    others += (ROOT / "CHANGELOG.md").read_text()
    stamps = sorted(set(STAMP.findall(json.dumps(mine[0]))))
    only = [s for s in stamps if s not in others]
    for s in only:
        print(s)
    print(f"{len(only)} of {len(stamps)} stamps named only by {want}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
