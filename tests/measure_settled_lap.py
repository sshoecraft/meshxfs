#!/usr/bin/env python3
"""One lap of D-MEASURE-REFUSES-A-BATCH-WHOSE-SETTLED-LAP-CHECK-BATCH-LAP-COUNTED-AS-RUN: can a
calibration or control batch holding a lap settled by a reviewed disposition be closed?

tools/defects.py check_batch_lap counts every PASS, FAIL and INCOMPLETE lap against a batch's
plan and refuses a lap past it, while cmd_measure required its PASS and FAIL laps alone to equal
the plan, though its own refusal of an unsettled lap says a reviewed infra disposition stands in
for one. A batch with a settled lap was therefore stuck: no lap could be added, and measure
refused 'planned 10 laps and has 9; run the rest first' (control b20261024-1d2fde,
tests/evidence/lanes/g8b_a17b_20261024T111854Z/step2.log).

The lap takes every open calibration or control batch of the live queue whose laps fill its plan
with at least one settled INCOMPLETE or INFRA lap, and runs `defects.py measure` on it in a
scratch tree of its own: a copy of tools/*.py and of everything they read or write (data/, each
own-rig board and its ledger), so nothing is written to the live queue or ledgers.

    EXPOSED   a batch at its full plan holds a settled lap
    PASS      measure closed every such batch in its scratch tree and recorded its rate over the
              PASS and FAIL laps
    FAIL      measure refused one, or closed it without a rate

MXFS_MEASURE_COUNT_SETTLED=0 (tools/defects.py) counts only PASS and FAIL laps, as before the fix:
the control. The lap hands its environment to every command.

The tree root is the nearest directory above the lap holding tools/criteria.py and
data/defects.json; a drafts tree beside it (its own tools/*.py) is copied over the root's tools, so
a draft of tools/defects.py is what the scratch tree runs.

Bound, derived: copying data/ (~10 MB) and reading the queue (1.5 MB) and primary ledger (6 MB) in
one interpreter, measured 1.0 s a lap for two batches (precheck 2026-10-24, both arms); a batch lap
is bounded at 2 x that rounded up, 3 s, each command at 20 s.

Usage: tests/measure_settled_lap.py
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure (no batch holds a settled lap at its full plan).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# not resolved: tests/evidence is a symbolic link out of the tree, and a draft under it must
# still find the tree it sits in
HERE = Path(os.path.abspath(__file__)).parents[1]
COMMAND_BOUND = 20
#: the environment that would point a scratch tree's tools at the live files
LIVE_POINTERS = ("MXFS_CRIT", "MXFS_OWN_RIG", "MXFS_SPEC", "MXFS_DEFECTS")


def tree_root() -> Path:
    for d in [HERE] + list(HERE.parents):
        if (d / "tools" / "criteria.py").is_file() and (d / "data" / "defects.json").is_file():
            return d
    print("RESULT: ABORT no tree root above %s" % HERE)
    sys.exit(2)


ROOT = tree_root()
sys.path.insert(0, str(ROOT / "tools"))
import criteria  # noqa: E402


def own_boards() -> list:
    """Every own-rig board data/configurations.json names, as tree paths."""
    declared = json.loads((ROOT / "data" / "configurations.json").read_text())
    return sorted({spec["board"] for spec in (declared.get("attaches") or {}).values()
                   if isinstance(spec, dict) and spec.get("board")})


def copy_present(source: str, target: str) -> str:
    """shutil.copy2, except that a file gone since copytree listed its directory is left out."""
    try:
        return shutil.copy2(source, target)
    except FileNotFoundError:
        if os.path.lexists(source):
            raise
        return target


def scratch_tree(base: Path) -> Path:
    (base / "tools").mkdir(parents=True)
    for source in (ROOT / "tools").glob("*.py"):
        shutil.copy2(source, base / "tools" / source.name)
    if HERE != ROOT:
        for source in (HERE / "tools").glob("*.py"):
            shutil.copy2(source, base / "tools" / source.name)
    shutil.copytree(ROOT / "data", base / "data", symlinks=True,
                    ignore=shutil.ignore_patterns("*.tmp"), copy_function=copy_present)
    for board in own_boards():
        source = ROOT / board
        target = base / board
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        ledger = source.with_name(source.stem + ".runs.jsonl")
        if ledger.exists():
            shutil.copy2(ledger, target.with_name(ledger.name))
    shutil.copy2(ROOT / "CHANGELOG.md", base / "CHANGELOG.md")
    return base


def stuck_batches() -> list:
    """(record, batch, measured, settled) for each open calibration or control batch whose laps
    fill its plan with at least one settled INCOMPLETE or INFRA lap."""
    found = []
    for entry in json.loads((ROOT / "data" / "defects.json").read_text())["defects"]:
        for batch in entry.get("batches", []):
            if batch.get("state") != "open" or batch.get("kind") not in ("calibrate", "control"):
                continue
            board = criteria.board_for(batch["config"])
            laps = [r for r in criteria.ledger_runs(board, batch["config"], batch["row"])
                    if r.get("batch") == batch["id"]]
            measured = [r for r in laps if r.get("outcome") in ("PASS", "FAIL")]
            settled = [r for r in laps if r.get("outcome") in ("INCOMPLETE", "INFRA")
                       and criteria.settled(board, batch["config"], batch["row"], str(r.get("iso")))]
            if settled and len(measured) + len(settled) == int(batch["planned"]):
                found.append((entry["id"], batch, len(measured), len(settled)))
    return found


def main() -> int:
    stuck = stuck_batches()
    if not stuck:
        print("RESULT: ABORT no open calibration or control batch holds a settled lap at its full plan")
        return 2
    env = {k: v for k, v in os.environ.items() if k not in LIVE_POINTERS}
    fails = 0
    for rid, batch, measured, settled in stuck:
        print(f"EXPOSED: batch {batch['id']} of {rid} ({batch['row']} at {batch['config']}) holds "
              f"{measured} measured and {settled} settled lap(s) of {batch['planned']} planned")
        with tempfile.TemporaryDirectory(prefix="measure_settled_") as scratch:
            tree = scratch_tree(Path(scratch) / "tree")
            out = subprocess.run([sys.executable, "tools/defects.py", "measure", rid,
                                  "--batch", batch["id"]], cwd=tree, env=env,
                                 capture_output=True, text=True, timeout=COMMAND_BOUND)
            text = (out.stdout + out.stderr).strip()
            after = [b for e in json.loads((tree / "data" / "defects.json").read_text())["defects"]
                     if e["id"] == rid for b in e.get("batches", []) if b["id"] == batch["id"]]
            rates = [r for e in json.loads((tree / "data" / "defects.json").read_text())["defects"]
                     if e["id"] == rid for r in e.get("rates", []) if r.get("batch") == batch["id"]]
        state = after[0].get("state") if after else "missing"
        print(f"  measure rc={out.returncode} state={state} rates={len(rates)}: {text[-300:]}")
        if out.returncode != 0 or state != "closed" or len(rates) != 1:
            fails += 1
        else:
            print(f"  rate {rates[0]['k']} of {rates[0]['n']}")
    if fails:
        print(f"LAP measure_settled FAIL: {fails} of {len(stuck)} batch(es) with a settled lap "
              f"could not be closed")
    else:
        print(f"LAP measure_settled PASS: every one of {len(stuck)} batch(es) with a settled lap "
              f"closed with its rate")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
