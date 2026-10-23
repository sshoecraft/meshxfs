#!/usr/bin/env python3
"""release_blockers.py — where each release-blocking record stands on its way out of the queue.

    tools/release_blockers.py            one block per record: reach, batches, proposals, next step
    tools/release_blockers.py -v         the next step in full
    tools/release_blockers.py --pending  only the proposals still waiting for a review

A record blocks a release when it reaches a configuration the release table claims and its
impact is not `noblock` (tools/release_status.py --defects lists the same set). A record leaves
the queue only through `tools/defects.py remove`, which needs a control batch that reproduced
the failure with the fix out, a verification batch sized from it, and an approved proposal;
this report shows how far each record has got. It reads the queue and the proposals and writes
nothing.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))
import defects          # noqa: E402
import release_status   # noqa: E402


def batch_line(batch: dict, rates: list) -> str:
    rate = next((r for r in rates if r.get("batch") == batch.get("id")), None)
    kn = f" k/n={rate['k']}/{rate['n']}" if rate else ""
    where = batch.get("candidate") or f"build {batch.get('build') or '?'}"
    variant = f" variant={batch['variant']}" if batch.get("variant") else ""
    return (f"    batch {batch.get('id')} {batch.get('kind')} {batch.get('state')} "
            f"{batch.get('row')} @{batch.get('config')} planned={batch.get('planned')}{kn} "
            f"on {where}{variant}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("-v", "--verbose", action="store_true", help="the next step in full")
    ap.add_argument("--pending", action="store_true",
                    help="only the proposals still waiting for a review")
    ap.add_argument("ids", nargs="*", help="only the records whose id contains one of these")
    args = ap.parse_args()

    spec = json.loads(release_status.TABLE.read_text())
    queue = defects.load()["defects"]
    byid = {e["id"]: e for e in queue}
    hits = release_status.reaching(release_status.table_rows(spec), queue)
    blocking = [i for i in hits if str(byid[i].get("impact", "")).lower() != "noblock"]
    rank = {s: i for i, s in enumerate(defects.SEVERITIES)}
    blocking.sort(key=lambda i: (rank.get(byid[i].get("severity"), 9), i))

    props = defects.load_proposals().get("proposals", {})
    props = list(props.values()) if isinstance(props, dict) else props
    by_record: dict = {}
    for p in props:
        by_record.setdefault(p.get("record"), []).append(p)

    if args.pending:
        pending = [p for p in props if p.get("state") == "pending"]
        for p in sorted(pending, key=lambda p: p.get("id", "")):
            mark = "blocks" if p.get("record") in blocking else "      "
            print(f"{p.get('id')}  {p.get('kind'):17} {mark}  {p.get('record')}")
        print(f"Total: {len(pending)} pending proposals, "
              f"{sum(1 for p in pending if p.get('record') in blocking)} on release-blocking records")
        return 0

    shown = [i for i in blocking if not args.ids or any(s in i for s in args.ids)]
    for i in shown:
        e = byid[i]
        print(f"### {i}")
        if args.verbose:
            print(f"    summary: {' '.join(str(e.get('summary') or '').split())}")
        print(f"    {e.get('severity')} {e.get('impact') or 'unadjudicated'} nodes={e.get('nodes')} "
              f"config={e.get('config')} platform={e.get('platform') or 'any'} "
              f"rows={len(hits[i])} cells={len(e.get('cells') or [])}")
        repro = str(e.get("reproducer") or "")
        print(f"    reproducer: {repro[:160] if repro else '-'}")
        rates = e.get("rates") or []
        for b in e.get("batches") or []:
            print(batch_line(b, rates))
        for v in e.get("verified_at") or []:
            print(f"    verified_at {json.dumps(v)[:160]}")
        for p in sorted(by_record.get(i, []), key=lambda p: p.get("id", "")):
            print(f"    proposal {p.get('id')} {p.get('kind')} {p.get('state')}")
        nxt = e.get("next")
        nxt = " | ".join(nxt) if isinstance(nxt, list) else str(nxt or "")
        nxt = " ".join(nxt.split())
        print(f"    next: {nxt if args.verbose else nxt[:400]}")
    print(f"Total: {len(blocking)} records block a release"
          + (f", {len(shown)} shown" if args.ids else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
