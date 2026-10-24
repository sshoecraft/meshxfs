#!/usr/bin/env python3
"""One lap of D-PRESTEPS-FORM-PAIR-UNDER-G2-MARKER-BUT-SELF-TESTS-READ-DEFAULT-MARKER, observed.

tools/release_run.py's presteps form the pair with `run.sh <config> --group <group> prep_cluster`,
which describes it in the group's own cluster marker (.cluster_marker.<group>.json), then run
tests/rig_lib_contract.sh and tests/capture_fault_gate.sh in the environment
Run.env(**presteps_env(group)) gives them. tests/presteps_env_lap.py only computes which marker
that environment would make a tool read. This lap runs the tools and watches them read it.

It builds a scratch tree in which the default marker (.cluster_marker.json) describes one pair and
the group's marker another: each with its own node list, configuration, rig tag, LUN and
filesystem uuid, so every value a tool ends up holding names the marker it came from. The scratch
tree holds symlinks to this tree's tools/mxfs_rig_tag.sh, tools/mxfs_lab.sh, tests/lib/rig.sh,
tests/capture_fault_gate.sh and tests/capture_gate.manifest; the tools find the tree from their own
path (`cd $(dirname $0)/..`, BASH_SOURCE), so their default marker is the scratch one. It holds
no mxfs.ko that modinfo can read and no tools/mxfs_sshpass.sh, so nothing in it can reach a node.

presteps_env(group) is taken from tools/release_run.py in a fresh interpreter with its ROOT set to
the scratch tree: the function's own code names the scratch group marker exactly as it names
<repo>/.cluster_marker.<group>.json in a release run. MXFS_PRESTEPS_GROUP_MARKER in this lap's
environment reaches that interpreter, so `=0` is the fix's control. Then, each under strace (the
openat of every marker file is recorded), in that environment:

    tools/mxfs_rig_tag.sh                       the rig tag it prints (the marker's `rig`)
    tests/lib/rig.sh mxfs_dev_declared          the LUN it declares (resolved through the tag)
    tests/lib/rig.sh mxfs_host_image            the fsid it checks a host image against (its own
                                                read of the marker, tests/lib/rig.sh mxfs_host_image)
    tests/capture_fault_gate.sh                 the configuration it would form the pair under
                                                (PAIR_CONFIG, its own read, seen with bash -x; the
                                                gate then stops at its missing-module ABORT)

    EXPOSED   the two scratch markers, read back, describe different pairs
    PASS      every tool opened the group's marker and nothing else, and holds its pair
    FAIL      a tool opened the default marker or holds the default marker's pair
    ABORT     a tool opened no marker, a marker outside the scratch tree, or holds a value that
              names neither marker (nothing was measured)

Bound, derived: the whole lap measured 0.82-0.84 s wall on clyde (one interpreter start, four
traced tool runs of ~0.15 s each); 2x rounds up to 2 s, the caller bound. No single call may take
longer than the lap's own bound, so each subprocess carries 2 s as well.

Usage: tests/presteps_marker_read_lap.py [group]   (default g2, the presteps' group)
Exit: 0 PASS, 1 FAIL, 2 ABORT.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CALL_BOUND = 2
LINKED = ("tools/mxfs_rig_tag.sh", "tools/mxfs_lab.sh", "tests/lib/rig.sh",
          "tests/capture_fault_gate.sh", "tests/capture_gate.manifest")
#: what a release run's own environment would not carry, and what would let a tool skip its
#: marker read (an explicit rig, LUN, device or image) or reach a node (SSH)
UNSET = ("MXFS_MARKER", "MXFS_GROUP", "MXFS_NODE_LIST", "MXFS_RIG_TAG", "MXFS_RIG_TAG_FRESH",
         "MXFS_RIG_NODE", "MXFS_LUN_WWID", "MXFS_DEV", "MXFS_HOST_IMAGE_PATH", "MXFS_CONFIG",
         "MXFS_CRIT", "SSH")

PROBE = """
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["LAP_ROOT"] + "/tools")
import release_run
release_run.ROOT = Path(os.environ["LAP_SCRATCH"])
told = release_run.presteps_env(os.environ["LAP_GROUP"])
run = release_run.Run.__new__(release_run.Run)
run.cid = os.environ.get("MXFS_CANDIDATE") or "presteps-marker-lap"
print(json.dumps({"told": told, "switch": release_run.PRESTEPS_GROUP_MARKER, "env": run.env(**told)}))
"""


def write_marker(path: Path, nodes: list, config: str, rig: str, wwid: str, fsid: str) -> None:
    path.write_text(json.dumps({
        "nodes": len(nodes), "configuration": config, "srcversion": "presteps-marker-lap",
        "node_list": ",".join(nodes), "dev": f"/dev/disk/by-id/wwn-0x{wwid}", "rig": rig,
        "wwid": f"naa.{wwid}", "fsid": fsid, "gen": 1,
        "iso": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "modargs": ""},
        indent=2) + "\n")


def traced(scratch: Path, name: str, args: list, env: dict) -> tuple:
    """Run `args` under strace; return (rc, output, the marker files it opened as strace saw them)."""
    trace = scratch / f"strace.{name}"
    out = subprocess.run(["strace", "-f", "-qq", "-e", "trace=openat,open", "-o", str(trace)] + args,
                         cwd=scratch, env=env, capture_output=True, text=True, timeout=CALL_BOUND)
    opens = [line.strip() for line in trace.read_text(errors="replace").splitlines()
             if "cluster_marker" in line]
    return out.returncode, out.stdout + out.stderr, opens


def main() -> int:
    group = sys.argv[1] if len(sys.argv) > 1 else "g2"
    if not shutil.which("strace"):
        print("ABORT: strace is not installed, so no marker read can be observed")
        return 2
    scratch = Path(tempfile.mkdtemp(prefix="presteps-marker-lap-"))
    try:
        return lap(group, scratch)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def lap(group: str, scratch: Path) -> int:
    for rel in LINKED:
        (scratch / rel).parent.mkdir(parents=True, exist_ok=True)
        (scratch / rel).symlink_to(ROOT / rel)
    (scratch / "mxfs.ko").write_bytes(b"")
    nodes = subprocess.run([str(ROOT / "tools" / "mxfs_lab.sh"), "group", group], capture_output=True,
                           text=True, timeout=CALL_BOUND).stdout.split()
    if not nodes:
        print(f"ABORT: tools/mxfs_lab.sh names no nodes for group {group}")
        return 2
    # the pair the presteps form, and the one the 0.90.134 fix-on batch found in the default marker
    own_path, default_path = scratch / f".cluster_marker.{group}.json", scratch / ".cluster_marker.json"
    sides = {own_path.name: (own_path, nodes, "2/net/mesh/direct", f"lap-{group}"),
             default_path.name: (default_path, ["test15"], "1/xfs", "lap-default")}
    rigs = {}
    for path, side_nodes, config, rig in sides.values():
        ident = uuid.uuid4()
        write_marker(path, side_nodes, config, rig, ident.hex, str(ident))
        rigs[rig] = {"lun_wwid": f"naa.{ident.hex}"}
    (scratch / "data").mkdir()
    (scratch / "data" / "rigs.json").write_text(json.dumps(rigs, indent=2) + "\n")
    held = {}  # marker name -> what it describes, as read back from the file
    for name, (path, _n, _c, _r) in sides.items():
        m = json.loads(path.read_text())
        held[name] = {"nodes": m["node_list"], "config": m["configuration"], "rig": m["rig"],
                      "lun": m["wwid"][len("naa."):], "fsid": m["fsid"]}
        print(f"INFO scratch {name}: nodes={m['node_list']} config={m['configuration']} "
              f"rig={m['rig']} fsid={m['fsid']}")
    if (held[own_path.name]["nodes"], held[own_path.name]["config"]) != \
            (held[default_path.name]["nodes"], held[default_path.name]["config"]):
        print(f"EXPOSED: the default marker describes another pair than {group}'s")
    # the image a host-side check is run against carries the group marker's filesystem uuid
    image = scratch / "host.img"
    image.write_bytes(b"MXFS" + bytes(12) + uuid.UUID(held[own_path.name]["fsid"]).bytes
                      + bytes(4096 - 32))

    probe_env = dict(os.environ, LAP_ROOT=str(ROOT), LAP_SCRATCH=str(scratch), LAP_GROUP=group)
    for name in UNSET:
        probe_env.pop(name, None)
    out = subprocess.run([sys.executable, "-c", PROBE], cwd=ROOT, env=probe_env,
                         capture_output=True, text=True, timeout=CALL_BOUND)
    if out.returncode != 0:
        print(f"ABORT: presteps_env rc={out.returncode}: {(out.stdout + out.stderr).strip()[-300:]}")
        return 2
    probe = json.loads(out.stdout.strip().splitlines()[-1])
    env = {k: v for k, v in probe["env"].items() if not k.startswith("LAP_")}
    told = {k: v.replace(str(scratch), "<scratch>") for k, v in probe["told"].items()}
    print(f"INFO presteps_env({group}) with MXFS_PRESTEPS_GROUP_MARKER="
          f"{os.environ.get('MXFS_PRESTEPS_GROUP_MARKER', '(unset)')} (fix "
          f"{'in' if probe['switch'] else 'out'}) tells the self-tests {json.dumps(told)}")

    rig_sh = str(scratch / "tests" / "lib" / "rig.sh")
    runs = (
        ("tools/mxfs_rig_tag.sh", [str(scratch / "tools" / "mxfs_rig_tag.sh")], {}),
        ("tests/lib/rig.sh mxfs_dev_declared",
         ["bash", "-c", '. "$1"; mxfs_dev_declared', "lap", rig_sh], {}),
        ("tests/lib/rig.sh mxfs_host_image",
         ["bash", "-c", '. "$1"; mxfs_host_image', "lap", rig_sh], {"MXFS_HOST_IMAGE_PATH": str(image)}),
        ("tests/capture_fault_gate.sh",
         ["bash", "-x", str(scratch / "tests" / "capture_fault_gate.sh"), "presteps_marker_lap"], {}),
    )
    verdicts = []
    for index, (tool, args, extra) in enumerate(runs):
        rc, text, opens = traced(scratch, str(index), args, dict(env, **extra))
        opened = []
        for line in opens:
            hit = re.search(r'"([^"]*cluster_marker[^"]*)"', line)
            if not hit:
                continue
            path = Path(hit.group(1)) if hit.group(1).startswith("/") else scratch / hit.group(1)
            if scratch.resolve() not in path.resolve().parents:
                print(f"ABORT: {tool} opened a marker outside the scratch tree: {line}")
                return 2
            opened.append(path.name)
            print(f"OPEN {tool}: {line.replace(str(scratch), '<scratch>')}")
        value = what_it_holds(tool, rc, text)
        source = [name for name, h in held.items() if value and value in (h["rig"], h["lun"], h["fsid"], h["config"])]
        print(f"READ {tool}: rc={rc} holds {value or '(nothing)'}"
              + (f" = {source[0]}'s pair nodes={held[source[0]]['nodes']} config={held[source[0]]['config']}"
                 if len(source) == 1 else ""))
        for line in text.splitlines():
            if line.startswith("ABORT: "):  # the gate's stop at its missing module, a check's refusal
                print(f"  {tool}| {line.replace(str(scratch), '<scratch>')}")
        if not opened or len(source) != 1:
            for line in text.strip().splitlines()[-4:]:
                print(f"  {tool}| {line.replace(str(scratch), '<scratch>')}")
            print(f"ABORT: {tool} opened {sorted(set(opened)) or 'no marker'} and holds a value naming "
                  f"{source or 'neither marker'}: nothing was measured")
            return 2
        verdicts.append((tool, sorted(set(opened)), source[0]))
    wrong = [f"{tool} opened {', '.join(opened)} and holds {source}'s pair "
             f"(nodes={held[source]['nodes']} config={held[source]['config']})"
             for tool, opened, source in verdicts if opened != [own_path.name] or source != own_path.name]
    if wrong:
        print("PRESTEPS_MARKER_LAP FAIL " + "; ".join(wrong))
        return 1
    print(f"PRESTEPS_MARKER_LAP PASS every tool opened {own_path.name} alone and holds the pair the "
          f"presteps formed (nodes={held[own_path.name]['nodes']} config={held[own_path.name]['config']})")
    return 0


def what_it_holds(tool: str, rc: int, text: str) -> str:
    """The value the tool's run left it holding, from its own output."""
    lines = text.splitlines()
    if tool == "tools/mxfs_rig_tag.sh":
        return lines[-1].strip() if rc == 0 and lines else ""
    if tool.endswith("mxfs_dev_declared"):
        return lines[-1].strip() if rc == 0 and lines else ""
    if tool.endswith("mxfs_host_image"):
        # HOST-IMAGE ... (the marker's fsid matched the image) or the ABORT naming the marker's fsid
        for line in lines:
            hit = re.search(r"while the LUN under test carries (\S+) \(cluster-marker\)", line)
            if hit:
                return hit.group(1)
            hit = re.match(r"HOST-IMAGE path=\S+ fsid=(\S+) reference=cluster-marker", line)
            if hit:
                return hit.group(1)
        return ""
    for line in lines:
        hit = re.match(r"\++ PAIR_CONFIG=(\S*)$", line)
        if hit:
            return hit.group(1).strip("'")
    return ""


if __name__ == "__main__":
    sys.exit(main())
