#!/usr/bin/env python3
"""One lap of D-HARNESS-LAP-TIMED-OPS-REACH-NO-STALL-GRADER-JDT-31S-UNMOUNT-GRADED-PASS.

A gate lap of tests/join_during_takeover.sh run through tools/batch_lap.py is held to the release
policy's stall limit only by the max_stall_ms= lines in the lap's own output. Two links carry a
timed operation there: join_during_takeover.sh prints max_stall_ms=<worst so far> after each timed
mount and unmount (op_ms; JDT_MAX_STALL=0 prints none), and tests/capture_fault_gate.sh, which
writes each harness's output into a log of its own, relays the worst one onto its own output
(relay_stall; GATE_RELAY_STALL=0 relays none). Without both, a 31 s last-member unmount inside a
gate lap was recorded PASS (batch b20261022-548ef2).

The lap runs the gate's join_during_takeover entry as a healthy lap (`--healthy-only --only
join_during_takeover`) through tools/batch_lap.py main() on scratch copies of the queue and the
board (MXFS_DEFECTS, MXFS_CRIT), so nothing reaches the real ledgers, with an operation over the
limit forced: JDT_FORCE_OP_S (the policy's stall limit plus one second) makes B's first unmount
sleep inside its timed window, so op_ms times it past the limit, on jdt's default arm (EXPECT=clean
ARM=ondemand). The stall arm (ARM=stall) the lap used before cannot make such an operation: B's
root request meets no transition, B mounts in seconds and nothing over the limit is timed
(D-JDT-STALL-ARM-GRADES-A-JOIN-THAT-MET-NO-TRANSITION-AS-A-FAILED-REFUSAL; control
b20261023-9da1ae, every lap UNMEASURED with its worst operation 7853-8196 ms). It declares a one-lap
calibration batch of this record there (row lap:jdt_gate_stall_inner at 2/net/mesh/direct) and
reads back the run batch_lap.py appended to the scratch ledger:

    EXPOSED  the jdt log the gate wrote holds a timed operation over the limit (an ms= past
             stall_limit_s on one of its INFO lines) and the gate's healthy lap ended OK
    PASS     the recorded run is a FAIL carrying max_stall_ms= over the limit
    FAIL     the recorded run is a PASS, or a FAIL without the stall

Either switch off in the lap's environment is the control of its own fix site; the lap hands its
environment to the gate and through it to jdt.

Bound, derived: the gate's pair check (~1 s when formed) and jdt's clean:ondemand lap at
NFILES=4000: the create of the entries (~NFILES/25 s = 160 s), B's clean unmount (~40 s at most,
measured with ~15k pages handed back at NFILES=32000) plus the forced 31 s, A's last-member unmount
and lone remount (~3 s), the pass paced 30 ms a page until it is seen (~15 s), B's mount served on
demand (~5 s; jdt bounds it at 90 s), captures ~20 s, the directory reads (~5 s): about 280 s;
600 s at 2x, rounded up. batch_lap.py is given that bound.

Usage: tests/jdt_gate_stall_lap.py   (on the g2 pair, formed at 2/net/mesh/direct)
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import criteria  # noqa: E402

RECORD = "D-HARNESS-LAP-TIMED-OPS-REACH-NO-STALL-GRADER-JDT-31S-UNMOUNT-GRADED-PASS"
ROW = "lap:jdt_gate_stall_inner"
AT = "2/net/mesh/direct"
LAP_BOUND = 600
# At NFILES=4000 the pass is ~500 pages and ended inside jdt's first in-flight sample, so every
# lap of the first control aborted before the stall arm's hold (b20261023-9da1ae, laps 1-5:
# 'the takeover pass was not seen in flight (activations=493 ...)'). JDT_PASS_PACE_MS=30 holds
# the pass 30 ms a page until it is seen, ~15 s for ~500 pages, inside the bound below.
MANIFEST_LINE = "join_during_takeover | 228 | {bound} | NFILES=4000 JDT_PASS_PACE_MS=30 |\n"
GATE_OK = re.compile(r"^GATE join_during_takeover healthy: rc=0 .*-> OK$", re.M)
OP_MS = re.compile(r"^  INFO .*\bms=(\d+)", re.M)


def quiet(text: str) -> str:
    """Text printed with the stall token renamed: this lap's own output is read by the
    tools/batch_lap.py that runs it, and a max_stall_ms= in it would grade the lap itself."""
    return text.replace("max_stall_ms=", "worst_ms=")


def main() -> int:
    for switch in ("JDT_MAX_STALL", "GATE_RELAY_STALL"):
        print(f"INFO {switch}={os.environ.get(switch) or '(unset)'}")
    limit_ms = int(criteria.policy().get("stall_limit_s", 30)) * 1000
    build = subprocess.run(["modinfo", "-F", "srcversion", str(ROOT / "mxfs.ko")],
                           capture_output=True, text=True).stdout.strip()
    if not build:
        print("UNMEASURED: no srcversion in the tree's mxfs.ko, which batch_lap.py records")
        return 2
    with tempfile.TemporaryDirectory(prefix="jdt_gate_stall.") as scratch:
        s = Path(scratch)
        shutil.copy(ROOT / "data" / "defects.json", s / "defects.json")
        shutil.copy(ROOT / "data" / "criteria.json", s / "criteria.json")
        manifest = s / "capture_gate.manifest"
        manifest.write_text(MANIFEST_LINE.format(bound=LAP_BOUND - 60))
        env = {k: v for k, v in os.environ.items()
               if k not in ("MXFS_CANDIDATE", "MXFS_BATCH", "MXFS_GROUP")}
        env.update(MXFS_DEFECTS=str(s / "defects.json"), MXFS_CRIT=str(s / "criteria.json"),
                   EXPECT="clean", ARM="ondemand", WANT="any",
                   JDT_FORCE_OP_S=str(limit_ms // 1000 + 1))
        declared = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "defects.py"), "batch", RECORD, "--row", ROW,
             "--at", AT, "--kind", "calibrate", "--runs", "1", "--probe", r"^GATE join_during",
             "--build", build, "--why", "tests/jdt_gate_stall_lap.py: one gate lap through "
             "batch_lap.py main() on a scratch queue and board"],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=30)
        found = re.search(r"\bb\d{8}-[0-9a-f]{6}\b", declared.stdout)
        if declared.returncode != 0 or not found:
            print(f"UNMEASURED: the scratch batch was not declared (rc={declared.returncode}): "
                  f"{(declared.stdout + declared.stderr).strip()[-300:]}")
            return 2
        batch = found.group(0)
        try:
            lap = subprocess.run(
                [sys.executable, str(ROOT / "tools" / "batch_lap.py"), "--batch", batch, "--at", AT,
                 "--row", ROW, "--bound", str(LAP_BOUND), "--pass", r"^RESULT: PASS",
                 "--fail", r"^RESULT: FAIL", "--", "tests/capture_fault_gate.sh", "jdtstall",
                 "--healthy-only", "--only", "join_during_takeover", str(manifest)],
                cwd=ROOT, env=env, capture_output=True, text=True, timeout=LAP_BOUND + 60)
        except subprocess.TimeoutExpired:
            print(f"UNMEASURED: batch_lap.py overran its {LAP_BOUND + 60} s bound")
            return 2
        output = (lap.stdout + lap.stderr).strip()
        print(f"batch_lap.py main(): rc={lap.returncode} "
              f"{quiet(output.splitlines()[-1][:300] if output else '')}")
        ledger = criteria.ledger_path(s / "criteria.json")
        runs = []
        if ledger.exists():
            for line in ledger.read_text().splitlines():
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                if item.get("kind") == "run" and item.get("batch") == batch:
                    runs.append(item)
        if len(runs) != 1:
            print(f"UNMEASURED: batch_lap.py recorded {len(runs)} run(s) of the scratch batch {batch}")
            return 2
        run = runs[0]
        log = ROOT / str(run.get("evidence", ""))
        text = log.read_text(errors="replace") if log.is_file() else ""
        gate_dir = re.search(r"evidence=(tests/evidence/\S+_capture_gate_jdtstall)", text)
        jdt_log = ROOT / gate_dir.group(1) / "join_during_takeover_ok.log" if gate_dir else None
        jtext = jdt_log.read_text(errors="replace") if jdt_log and jdt_log.is_file() else ""
        ops = [int(v) for v in OP_MS.findall(jtext)]
        worst = max(ops) if ops else 0
        if not GATE_OK.search(text) or worst <= limit_ms:
            print(f"UNMEASURED: the gate's healthy lap did not end OK, or its jdt log "
                  f"({jdt_log.relative_to(ROOT) if jdt_log else 'none'}) holds no timed operation "
                  f"over {limit_ms} ms (worst {worst} ms)")
            return 2
        print(f"EXPOSED: the gate's jdt lap ({jdt_log.relative_to(ROOT)}) timed an operation at "
              f"{worst} ms against the {limit_ms} ms limit and the gate ended OK")
        measured = str(run.get("measured", ""))
        print(f"recorded {run.get('outcome')}: {quiet(measured)} -- "
              f"{quiet(str(run.get('reason', '')))[:300]}")
        carried = re.search(r"\bmax_stall_ms=(\d+)\b", measured)
        if run.get("outcome") == "FAIL" and carried and int(carried.group(1)) > limit_ms:
            print(f"PASS: the gate lap with an operation at {worst} ms was recorded FAIL carrying "
                  f"its stall ({carried.group(1)} ms)")
            return 0
        print(f"FAIL: the gate lap with an operation at {worst} ms was recorded "
              f"{run.get('outcome')}{'' if carried else ' without a stall'}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
