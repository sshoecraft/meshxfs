#!/usr/bin/env python3
"""One lap of D-PRESTEPS-FORM-PAIR-UNDER-G2-MARKER-BUT-SELF-TESTS-READ-DEFAULT-MARKER.

tools/release_run.py's presteps form the pair with `run.sh <config> --group <group> prep_cluster`,
which describes it in the group's own cluster marker (.cluster_marker.<group>.json), and then run
the rig-library contract and the capture fault gate with the environment presteps_env(group)
gives them. Every tool reads its marker as tools/mxfs_rig_tag.sh and tests/lib/rig.sh do:
MXFS_MARKER, else the default .cluster_marker.json, which describes whatever ran outside a group
last. Told only the nodes, the self-tests read that default marker and checked another pair.

The lap takes presteps_env(group) from release_run.py in a fresh interpreter, resolves the marker
those tools would read with it, and compares what that marker describes with the group's own.

    EXPOSED   the default marker describes another pair than the group's (other nodes or another
              configuration), so a tool that reads it checks the wrong cluster
    PASS      the marker the self-tests read is the group's, describing the group's nodes, and
              MXFS_GROUP names the group
    FAIL      they read another marker, or are not told the group

Bound, derived: one interpreter start and tools/mxfs_lab.sh, ~1 s; 30 s.

Usage: tests/presteps_env_lap.py [group]   (default g2, the presteps' group)
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure (no marker for the group).
"""
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PROBE = """
import json, os, sys
sys.path.insert(0, os.environ["LAP_ROOT"] + "/tools")
import release_run
print(json.dumps(release_run.presteps_env(os.environ["LAP_GROUP"])))
"""


def marker(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def main() -> int:
    group = sys.argv[1] if len(sys.argv) > 1 else "g2"
    nodes = subprocess.run([str(ROOT / "tools" / "mxfs_lab.sh"), "group", group],
                           capture_output=True, text=True, timeout=10).stdout.split()
    own_path = ROOT / f".cluster_marker.{group}.json"
    own = marker(own_path)
    if not nodes or not own:
        print(f"ABORT: group {group} has no nodes or no marker at {own_path}")
        return 2
    default = marker(ROOT / ".cluster_marker.json")

    def pair(m: dict) -> tuple:
        return (str(m.get("node_list", "")), str(m.get("config", "")))

    print(f"INFO {group} marker: nodes={pair(own)[0]} config={pair(own)[1]}; default marker: "
          f"nodes={pair(default)[0]} config={pair(default)[1]}")
    if pair(default) != pair(own):
        print(f"EXPOSED: the default marker describes another pair than {group}'s")
    env = dict(os.environ, LAP_ROOT=str(ROOT), LAP_GROUP=group)
    for name in ("MXFS_MARKER", "MXFS_GROUP", "MXFS_NODE_LIST", "MXFS_CRIT"):
        env.pop(name, None)
    out = subprocess.run([sys.executable, "-c", PROBE], cwd=ROOT, env=env, capture_output=True,
                         text=True, timeout=20)
    if out.returncode != 0:
        print(f"ABORT: presteps_env rc={out.returncode}: {(out.stdout + out.stderr).strip()[-300:]}")
        return 2
    told = json.loads(out.stdout.strip().splitlines()[-1])
    read_path = Path(told.get("MXFS_MARKER") or ROOT / ".cluster_marker.json")
    read = marker(read_path)
    print(f"INFO the self-tests are told {json.dumps(told)}; they read {read_path.name}: "
          f"nodes={pair(read)[0]} config={pair(read)[1]}")
    wrong = []
    if read_path.resolve() != own_path.resolve() or pair(read) != pair(own):
        wrong.append(f"they read {read_path.name}, describing {pair(read)}, not {own_path.name}")
    if told.get("MXFS_GROUP") != group:
        wrong.append(f"MXFS_GROUP is {told.get('MXFS_GROUP')!r}, not {group}")
    if told.get("MXFS_NODE_LIST", "").split(",") != nodes:
        wrong.append(f"MXFS_NODE_LIST is {told.get('MXFS_NODE_LIST')!r}, not {','.join(nodes)}")
    if wrong:
        print("PRESTEPS_ENV_LAP FAIL " + "; ".join(wrong))
        return 1
    print(f"PRESTEPS_ENV_LAP PASS the self-tests read {own_path.name}, the pair the presteps formed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
