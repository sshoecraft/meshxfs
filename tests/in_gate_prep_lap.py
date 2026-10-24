#!/usr/bin/env python3
"""One lap of D-IN-GATE-PREP-RUN-SH-WITHOUT-GROUP-REWRITES-THE-DEFAULT-MARKER.

A capture gate run by the release's presteps forms its pair again with a bare run.sh
(tests/capture_fault_gate.sh pair_ready: './run.sh "$PAIR_CONFIG" prep_cluster', no --group), and
run.sh takes the group only from MXFS_GROUP in its environment (run.sh GROUP, MARKER). Where that
variable does not reach the prep, it forms the pair outside the group and rewrites the default
.cluster_marker.json mid-gate. tools/release_run.py presteps_env exports MXFS_GROUP and MXFS_MARKER;
MXFS_PRESTEPS_GROUP_MARKER=0 exports neither, as before: the control.

The lap runs that prep, as the gate's restore runs it, in the environment presteps_env('g2') gives
(forced, MXFS_FORCE_PREP=1, since the gate restores only a pair that is not formed, and a prep
that reuses a formed pair writes no marker), and reads both markers before and after:

    EXPOSED  the prep ran to its end (rc=0), so it wrote a marker
    PASS     run.sh took the group branch for g2 ('--- run lock: group g2 '), .cluster_marker.g2.json
             was written, and .cluster_marker.json is as it was
    FAIL     the default marker changed, or the prep took no group branch

The configuration is the presteps' pair's, 2/net/mesh/direct, in both arms: the gate reads it from
the marker it is told, which in the control would be whatever ran last under the default marker.

Bound, derived: a 2-node prep measured 37-58 s (laps of this attempt's lanes), so 120 s for it;
the marker reads are instant. A caller bounds the lap at twice that, 250 s.

Usage: tests/in_gate_prep_lap.py <label>   (on g2, test1/test2)
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import release_run  # noqa: E402

GROUP = "g2"
CONFIG = "2/net/mesh/direct"
PREP_BOUND = 120
DEFAULT = ROOT / ".cluster_marker.json"
OWN = ROOT / f".cluster_marker.{GROUP}.json"


def snap(path: Path) -> tuple:
    if not path.is_file():
        return (None, None, None)
    data = path.read_bytes()
    try:
        gen = json.loads(data).get("gen")
    except ValueError:
        gen = "unreadable"
    return (hashlib.sha256(data).hexdigest()[:16], path.stat().st_mtime_ns, gen)


def main() -> int:
    label = sys.argv[1] if len(sys.argv) > 1 else "igp"
    out = ROOT / "tests" / "evidence" / f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}_ingateprep_{label}"
    out.mkdir(parents=True, exist_ok=True)
    print(f"INFO MXFS_PRESTEPS_GROUP_MARKER={os.environ.get('MXFS_PRESTEPS_GROUP_MARKER') or '(unset)'}")
    told = release_run.presteps_env(GROUP)
    print(f"INFO presteps_env({GROUP!r}) = {told}")
    env = {k: v for k, v in os.environ.items()
           if k not in ("MXFS_GROUP", "MXFS_MARKER", "MXFS_NODE_LIST", "MXFS_CONFIG", "MXFS_NODES")}
    env.update(told)
    env["MXFS_FORCE_PREP"] = "1"
    before = {"default": snap(DEFAULT), GROUP: snap(OWN)}
    print(f"INFO markers before: {before}")
    log = out / "prep.log"
    try:
        with log.open("w") as handle:
            prep = subprocess.run(["./run.sh", CONFIG, "prep_cluster"], cwd=ROOT, env=env,
                                  stdin=subprocess.DEVNULL, stdout=handle, stderr=subprocess.STDOUT,
                                  timeout=PREP_BOUND)
        rc = prep.returncode
    except subprocess.TimeoutExpired:
        print(f"UNMEASURED: the prep overran its {PREP_BOUND} s bound (log {log.relative_to(ROOT)})")
        return 2
    after = {"default": snap(DEFAULT), GROUP: snap(OWN)}
    print(f"INFO markers after: {after}")
    text = log.read_text(errors="replace")
    branch = f"--- run lock: group {GROUP} " in text
    print(f"INFO prep rc={rc}; group branch for {GROUP}: {'yes' if branch else 'no'} "
          f"(log {log.relative_to(ROOT)})")
    if rc != 0:
        print(f"UNMEASURED: the prep did not end OK (rc={rc}): "
              f"{' | '.join(text.strip().splitlines()[-2:])[:240]}")
        return 2
    print(f"EXPOSED: an in-gate prep (./run.sh {CONFIG} prep_cluster, no --group) ran to its end in "
          f"presteps_env({GROUP!r})")
    wrong = []
    if after["default"] != before["default"]:
        wrong.append(f"the default marker was rewritten ({before['default']} -> {after['default']})")
    if not branch:
        wrong.append(f"run.sh took no group branch for {GROUP}")
    if after[GROUP] == before[GROUP]:
        wrong.append(f"{OWN.name} was not written")
    if wrong:
        print(f"IN_GATE_PREP_LAP FAIL: {'; '.join(wrong)}")
        return 1
    print(f"IN_GATE_PREP_LAP PASS: the prep formed the pair under {GROUP}, wrote {OWN.name} "
          f"(gen {before[GROUP][2]} -> {after[GROUP][2]}) and left the default marker as it was")
    return 0


if __name__ == "__main__":
    sys.exit(main())
