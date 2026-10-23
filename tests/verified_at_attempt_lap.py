#!/usr/bin/env python3
"""One lap of D-VERIFIED-AT-MATCHED-BY-VERSION-ALONE-CARRIES-TO-A-LATER-ATTEMPT.

A record verified at a configuration on a release candidate stops blocking it there
(tools/defects.py verified_here). A candidate is its version, frozen again after an attempt
fails, and a verification batch's laps ran on one attempt's tree only, so its mark must count on
that attempt and on no later one.

The lap reads the active candidate's manifest (data/candidates/<candidate>.json): the current
attempt's frozen-at stamp, and the newest earlier attempt's. It takes the newest verification
batch of the queue declared on that candidate, and gives a copy of its record one verified_at
mark at the batch's configuration, as `defects.py verify` writes it, stamped first with the
earlier attempt and then with the current one, asking defects.verified_here (in a fresh
interpreter) whether each stops the record blocking there on the current attempt.

    EXPOSED  the candidate has an earlier attempt to stamp a mark with (the trigger)
    PASS     the earlier attempt's mark does not stop it blocking, and the current one's does
    FAIL     the earlier attempt's mark stops it blocking (matched by the version alone), or the
             current attempt's mark does not

Bound, derived: one interpreter start reading the queue and the candidate manifest, 0.15 s
measured, ~1 s on a loaded host; 10 s.

Usage: tests/verified_at_attempt_lap.py
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PROBE = """
import copy, json, os, sys
sys.path.insert(0, os.environ["LAP_ROOT"] + "/tools")
import defects
data = defects.load()
entry, batch = defects.find_batch(data, os.environ["LAP_BATCH"])
out = {}
for name in ("earlier", "current"):
    rec = copy.deepcopy(entry)
    rec["verified_at"] = [{"config": batch["config"], "platform": batch.get("platform", "any"),
                           "candidate": batch["candidate"], "attempt": os.environ["LAP_" + name.upper()],
                           "build": batch.get("build", ""), "batch": batch["id"],
                           "approval": "", "date": ""}]
    out[name] = defects.verified_here(rec, batch["config"], batch.get("platform"),
                                      batch["candidate"])
out["record"] = entry["id"]
out["config"] = batch["config"]
print(json.dumps(out))
"""


def main() -> int:
    try:
        cand = json.loads((ROOT / "data" / "candidates" / "active.json").read_text())["candidate"]
        manifest = json.loads((ROOT / "data" / "candidates" / f"{cand}.json").read_text())
    except (OSError, ValueError, KeyError) as exc:
        print(f"ABORT: no active candidate manifest: {exc}")
        return 2
    current = str(manifest.get("created") or "")
    earlier = [str(a.get("created")) for a in manifest.get("attempts") or []
               if a.get("created") and str(a.get("created")) != current]
    if not current or not earlier:
        print(f"ABORT: candidate {cand} has no earlier attempt (current {current!r})")
        return 2
    queue = json.loads((ROOT / "data" / "defects.json").read_text())
    batches = [b for e in queue["defects"] for b in e.get("batches") or []
               if b.get("kind") == "verify" and b.get("candidate") == cand]
    if not batches:
        print(f"ABORT: no verification batch of the queue is declared on {cand}")
        return 2
    batch = batches[-1]
    print(f"EXPOSED: candidate {cand} was frozen at {earlier[-1]} before its current attempt "
          f"{current}; batch {batch['id']} at {batch['config']}")
    env = dict(os.environ, LAP_ROOT=str(ROOT), LAP_BATCH=batch["id"], LAP_EARLIER=earlier[-1],
               LAP_CURRENT=current)
    env.pop("MXFS_CRIT", None)
    env.pop("MXFS_OWN_RIG", None)
    out = subprocess.run([sys.executable, "-c", PROBE], cwd=ROOT, env=env, capture_output=True,
                         text=True, timeout=25)
    if out.returncode != 0 or not out.stdout.strip():
        print(f"ABORT: probe rc={out.returncode}: {(out.stdout + out.stderr).strip()[-300:]}")
        return 2
    seen = json.loads(out.stdout.strip().splitlines()[-1])
    print(f"INFO {json.dumps(seen)}")
    wrong = []
    if seen.get("earlier"):
        wrong.append(f"a mark from attempt {earlier[-1]} stops {seen['record']} blocking "
                     f"{seen['config']} on attempt {current}")
    if not seen.get("current"):
        wrong.append(f"a mark from the current attempt {current} does not stop it blocking")
    if wrong:
        print("VERIFIED_AT_LAP FAIL " + "; ".join(wrong))
        return 1
    print(f"VERIFIED_AT_LAP PASS a mark counts on its own attempt ({current}) and not on another")
    return 0


if __name__ == "__main__":
    sys.exit(main())
