#!/usr/bin/env python3
"""One lap of D-BATCH-LAP-RECORDS-NO-VARIANT-FOR-MODULE-ARGUMENTS-SO-A-VARIANT-LAP-CAN-COUNT: a
harness lap recorded through tools/batch_lap.py on a pair that runs a non-default module argument.

tools/batch_lap.py recorded a lap's variant only from its batch, never from the module arguments
the pair was prepped with, so a verification lap run with MXFS_EXTRA_MODARGS in its environment (or
on a pair whose marker recorded them) was recorded with no variant, and tools/defects.py counted it
for the candidate as it ships. The defect is in a host tool, so the lap runs on the host, in a
scratch tree of its own (the copy tests/release_step_cell_lap.py makes: the tools and everything
they read or write, so nothing live is written), through the copy's own batch_lap.py exactly as a
lane invokes it. In that copy it declares a calibration batch of two laps on the record (no variant,
the lap's row at 2/disk/caw/mpath, the configuration of the review that found it), then records:

    lap 1  MXFS_EXTRA_MODARGS=dead_timeout_ms=12000 in the environment, as the late-fill lane
           exported it (tests/evidence/lanes/g2b_a14_latefill_20261023T204131Z/summary.log:10)
    lap 2  no such variable, MXFS_MARKER naming a marker whose prep recorded that argument

and reads each recorded run back from the copy's ledger, and asks the copy's defects.py whether the
batch would count it (unplanned_variant).

    EXPOSED   a lap ran through batch_lap.py with a module argument on its pair
    PASS      both runs carry the argument in their variant and neither counts for the batch
    FAIL      a run carries no variant naming the argument, or the batch would count it

MXFS_BATCH_LAP_ENV_VARIANT=0 (tools/batch_lap.py) records only the batch's variant, as before the
fix: the same-build control. The lap hands its environment to every command it runs.

Bound, derived: one scratch copy (0.5-1.5 s, measured by tests/release_step_cell_lap.py's laps), a
batch declaration and two batch_lap.py runs of /bin/echo (one queue and one ledger write each, ~0.5 s
on the tree of 2026-10-23) and two reads: about 4 s, so a batch lap is bounded at 2x that, 8 s; each
command at 20 s.

Usage: tests/batch_lap_variant_lap.py
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_step_cell_lap as cell_lap  # noqa: E402

RECORD = "D-BATCH-LAP-RECORDS-NO-VARIANT-FOR-MODULE-ARGUMENTS-SO-A-VARIANT-LAP-CAN-COUNT"
AT = "2/disk/caw/mpath"
ROW = "lap:batch_lap_variant"
ARG = "dead_timeout_ms=12000"
#: what a lap's environment must not carry into the scratch tree's own commands: the live pointers,
#: a lane's candidate and rig, and every name batch_lap.py would read as a variant
STRIP = cell_lap.LIVE_POINTERS + ("MXFS_CANDIDATE", "MXFS_GROUP", "MXFS_MARKER", "MXFS_NODE_LIST",
                                  "MXFS_EXTRA_MODARGS", "MXFS_RETIRE_CONTRACT", "MXFS_TEST_ENV",
                                  "MXFS_RIG_BUDGETS", "MXFS_STRACE_RANK", "MXFS_MPATH_TMO",
                                  "RULE0_CALIBRATE", "MXFS_SETTLE_MS", "MXFS_BATCH")


def run(tree: Path, argv: list, extra: dict) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k not in STRIP}
    env.update(extra)
    return subprocess.run([sys.executable] + argv, cwd=tree, env=env, capture_output=True,
                          text=True, timeout=cell_lap.COMMAND_BOUND)


def recorded(tree: Path, bid: str) -> list:
    runs = []
    for ledger in tree.rglob("*.runs.jsonl"):
        for line in ledger.read_text(errors="replace").splitlines():
            if f'"{bid}"' in line:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("batch") == bid:
                    runs.append(entry)
    return sorted(runs, key=lambda r: r.get("iso", ""))


def main() -> int:
    print(f"INFO MXFS_BATCH_LAP_ENV_VARIANT={os.environ.get('MXFS_BATCH_LAP_ENV_VARIANT') or '(unset)'}")
    ko = cell_lap.ROOT / "mxfs.ko"
    srcv = subprocess.run(["modinfo", "-F", "srcversion", str(ko)], capture_output=True,
                          text=True, timeout=cell_lap.COMMAND_BOUND).stdout.strip()
    if not srcv:
        print(f"ABORT: no srcversion in {ko}")
        return 2
    base = Path(tempfile.mkdtemp(prefix="batch_lap_variant_lap."))
    try:
        tree = cell_lap.scratch_tree(base / "tree")
        out = run(tree, ["tools/defects.py", "batch", RECORD, "--row", ROW, "--at", AT, "--build",
                         srcv, "--kind", "calibrate", "--runs", "2", "--why",
                         "scratch lap of the record: what batch_lap.py records as a lap's variant"],
                  {})
        found = re.search(r"\bbatch (b\d{8}-[0-9a-f]{6})\b", out.stdout)
        if out.returncode != 0 or not found:
            print(f"ABORT: the scratch batch was not declared: rc={out.returncode} "
                  f"{(out.stdout + out.stderr).strip()[-300:]}")
            return 2
        bid = found.group(1)
        marker = base / "marker.json"
        marker.write_text(json.dumps({"configuration": AT, "srcversion": srcv, "modargs": ARG}))
        lap = ["tools/batch_lap.py", "--batch", bid, "--at", AT, "--row", ROW, "--bound", "10",
               "--pass", "^LAPOK", "--build-from", str(ko), "--", "/bin/echo", "LAPOK"]
        cases = (("environment", {"MXFS_EXTRA_MODARGS": ARG}), ("marker", {"MXFS_MARKER": str(marker)}))
        for how, extra in cases:
            extra = dict(extra, MXFS_BATCH_LAP_HOLD="0")
            done = run(tree, lap, extra)
            if done.returncode != 0:
                print(f"ABORT: the {how} lap was not recorded as a PASS: rc={done.returncode} "
                      f"{(done.stdout + done.stderr).strip()[-300:]}")
                return 2
        runs = recorded(tree, bid)
        if len(runs) != 2:
            print(f"ABORT: the scratch ledger holds {len(runs)} run(s) of {bid}, not 2")
            return 2
        print(f"EXPOSED: two laps of {bid} ran through batch_lap.py with {ARG} on their pair "
              "(one in the environment, one in the pair's marker)")
        check = run(tree, ["-c", "import json,sys; sys.path.insert(0,'tools'); import defects; "
                                 "d=defects.load(); e,b=defects.find_batch(d, sys.argv[1]); "
                                 "print(json.dumps([defects.unplanned_variant(r, b) "
                                 "for r in json.loads(sys.argv[2])]))", bid, json.dumps(runs)], {})
        try:
            counted = [not x for x in json.loads(check.stdout.strip().splitlines()[-1])]
        except (ValueError, IndexError):
            print(f"ABORT: the scratch queue could not be asked: rc={check.returncode} "
                  f"{(check.stdout + check.stderr).strip()[-300:]}")
            return 2
        failed = []
        for (how, _), entry, counts in zip(cases, runs, counted):
            variant = str(entry.get("variant") or "")
            print(f"INFO {how} lap {entry.get('iso')}: variant={variant or '(none)'} "
                  f"counted={'yes' if counts else 'no'}")
            if ARG not in variant:
                failed.append(f"the {how} lap's run carries no variant naming {ARG}")
            if counts:
                failed.append(f"the batch would count the {how} lap for the build as it ships")
        if failed:
            print("FAIL: " + "; ".join(failed))
            return 1
        print(f"PASS: both laps carry {ARG} in their variant and neither counts for {bid}")
        return 0
    except subprocess.TimeoutExpired as exc:
        print(f"ABORT: a command overran its {cell_lap.COMMAND_BOUND} s bound: {exc.cmd}")
        return 2
    except RuntimeError as exc:
        print(f"ABORT: {exc}")
        return 2
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
