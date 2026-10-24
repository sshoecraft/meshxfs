#!/usr/bin/env python3
"""One lap of D-MEASURE-REFUSES-A-BATCH-WHOSE-SETTLED-LAP-CHECK-BATCH-LAP-COUNTED-AS-RUN: do
measure, check_batch_lap and tools/harness_batch.py's resume count a batch's plan the same way?

tools/defects.py check_batch_lap counts every PASS, FAIL and INCOMPLETE lap against a batch's
plan and refuses a lap past it; an INFRA lap uses up no place, so a lap is run in its stead.
cmd_measure required its PASS and FAIL laps alone to equal the plan, so a batch holding a settled
INCOMPLETE lap was stuck: no lap could be added, and measure refused 'planned 10 laps and has 9;
run the rest first' (control b20261024-1d2fde, tests/evidence/lanes/g8b_a17b_20261024T111854Z/
step2.log). The first fix counted settled INFRA laps toward the plan as well, which moved the
disagreement to a batch whose INFRA lap was run again (review data/reviews/P20261024-7f4fc9.md).
All three now count with defects.plan_laps.

Every case runs in a scratch tree of its own: a copy of tools/*.py and of everything they read or
write (data/, each own-rig board and its ledger), so nothing is written to the live queue or
ledgers.

    live      each open calibration or control batch of the live queue whose PASS, FAIL and
              settled INCOMPLETE laps fill its plan: measure must close it with a rate
    settled-incomplete
              a scratch calibration batch of 2 laps holding one FAIL and one INCOMPLETE lap
              settled by an infra_proven note: measure must close it at 1 FAIL of 1
    settled-infra
              a scratch calibration batch of 2 laps holding two FAILs and, besides them, one INFRA
              lap settled by an infra_proven note (the lap run again in its stead): measure must
              close it at 2 FAILs of 2
    plan      a scratch calibration batch of 2 laps holding one FAIL and one INFRA lap: plan_laps
              must count 1, check_batch_lap (defects.py batch-check) must let one more lap run,
              and so must tools/harness_batch.py's resume, which counts with plan_laps

The scratch cases' laps are fixtures the lap writes into its own scratch ledger, each stamped in
2000-01-01 and marked 'fixture of tests/measure_settled_lap.py'; they never reach a live ledger.

    EXPOSED   the settled-incomplete case was built (a batch at its full plan with a settled
              INCOMPLETE lap): always, once the scratch tree is made
    PASS      every case above as stated
    FAIL      any case otherwise

MXFS_MEASURE_COUNT_SETTLED=0 (tools/defects.py) counts only PASS and FAIL laps toward the plan in
measure, as before the fix: the control. The lap hands its environment to every command.

The tree root is the nearest directory above the lap holding tools/criteria.py and
data/defects.json; a drafts tree beside it (its own tools/*.py) is copied over the root's tools, so
a draft of tools/defects.py is what the scratch tree runs.

Bound, derived: copying data/ (~10 MB) and reading the queue (1.5 MB) and primary ledger (6 MB) in
one interpreter, measured 1.0 s a lap for two live batches (precheck 2026-10-24, both arms); the
three scratch cases are one tree and about six interpreter starts more (bound from the
precheck below).

Usage: tests/measure_settled_lap.py
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
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
FIXTURE_RECORD = "D-MEASURE-SETTLED-LAP-SCRATCH-FIXTURE"
FIXTURE_CONFIG = "2/net/mesh/direct"
FIXTURE_ROW = "lap:measure_settled_fixture"


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


def live_batches() -> list:
    """(record, batch, measured, settled) for each open calibration or control batch whose PASS,
    FAIL and settled INCOMPLETE laps fill its plan, with at least one settled INCOMPLETE."""
    found = []
    for entry in json.loads((ROOT / "data" / "defects.json").read_text())["defects"]:
        for batch in entry.get("batches", []):
            if batch.get("state") != "open" or batch.get("kind") not in ("calibrate", "control"):
                continue
            board = criteria.board_for(batch["config"])
            laps = [r for r in criteria.ledger_runs(board, batch["config"], batch["row"])
                    if r.get("batch") == batch["id"]]
            measured = [r for r in laps if r.get("outcome") in ("PASS", "FAIL")]
            settled = [r for r in laps if r.get("outcome") == "INCOMPLETE"
                       and criteria.settled(board, batch["config"], batch["row"], str(r.get("iso")))]
            if settled and len(measured) + len(settled) == int(batch["planned"]):
                found.append((entry["id"], batch, len(measured), len(settled)))
    return found


def command(tree: Path, env: dict, args: list) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable] + args, cwd=tree, env=env, capture_output=True,
                          text=True, timeout=COMMAND_BOUND)


def batch_of(tree: Path, rid: str, bid: str) -> tuple:
    """(the batch, its rates) in the scratch tree's queue."""
    queue = json.loads((tree / "data" / "defects.json").read_text())["defects"]
    entry = [e for e in queue if e["id"] == rid]
    batches = [b for b in (entry[0].get("batches") or []) if b["id"] == bid] if entry else []
    rates = [r for r in (entry[0].get("rates") or []) if r.get("batch") == bid] if entry else []
    return (batches[0] if batches else {}), rates


def measure(tree: Path, env: dict, rid: str, bid: str, want: tuple | None) -> str:
    """Run measure in the scratch tree; "" when it closed the batch with exactly the rate
    want = (k, n) (any one rate when want is None), else what went wrong."""
    out = command(tree, env, ["tools/defects.py", "measure", rid, "--batch", bid])
    text = (out.stdout + out.stderr).strip()
    batch, rates = batch_of(tree, rid, bid)
    print(f"  measure rc={out.returncode} state={batch.get('state')} rates={len(rates)}: {text[-300:]}")
    if out.returncode != 0 or batch.get("state") != "closed" or len(rates) != 1:
        return f"measure did not close {bid}: rc={out.returncode} state={batch.get('state')}"
    print(f"  rate {rates[0]['k']} of {rates[0]['n']}")
    if want is not None and (rates[0]["k"], rates[0]["n"]) != want:
        return f"{bid} closed at {rates[0]['k']} of {rates[0]['n']}, not {want[0]} of {want[1]}"
    return ""


def fixture_batch(tree: Path, env: dict, name: str, outcomes: list, infra_settled: list) -> str:
    """Declare a 2-lap calibration batch on the scratch fixture record and write one ledger run
    per outcome into the scratch primary ledger, an infra_proven note on each index in
    infra_settled. Returns the batch id."""
    out = command(tree, env, ["tools/defects.py", "batch", FIXTURE_RECORD, "--kind", "calibrate",
                              "--row", FIXTURE_ROW, "--at", FIXTURE_CONFIG, "--runs", "2",
                              "--why", f"fixture of tests/measure_settled_lap.py: {name}"])
    bid = next((w for w in out.stdout.split() if w.startswith("b") and w.count("-") == 1
                and w[1:9].isdigit()), "")
    if out.returncode != 0 or not bid:
        raise RuntimeError(f"declaring the {name} fixture batch: rc={out.returncode} "
                           f"{(out.stdout + out.stderr).strip()[-300:]}")
    items = []
    for number, outcome in enumerate(outcomes):
        iso = f"2000-01-01T00:{len(name) % 60:02d}:{number:02d}Z"
        items.append({"kind": "run", "config": FIXTURE_CONFIG, "row": FIXTURE_ROW,
                      "outcome": outcome, "iso": iso, "batch": bid, "build": None,
                      "measured": f"fixture of tests/measure_settled_lap.py ({name})"})
        if number in infra_settled:
            items.append({"kind": "note", "config": FIXTURE_CONFIG, "row": FIXTURE_ROW,
                          "iso": iso, "note": "infra_proven",
                          "value": {"approval": "fixture of tests/measure_settled_lap.py"},
                          "date": "2000-01-01"})
    ledger = (tree / "data" / "criteria.runs.jsonl")
    with ledger.open("a") as handle:
        for item in items:
            handle.write(json.dumps(item, sort_keys=True) + "\n")
    return bid


def scratch_cases(tree: Path, env: dict) -> list:
    """The three fixture cases; returns what went wrong in each."""
    wrong = []
    add = command(tree, env, ["tools/defects.py", "add", "--id", FIXTURE_RECORD, "-s", "minor",
                              "-m", "fixture record of tests/measure_settled_lap.py, scratch tree only"])
    if add.returncode != 0:
        raise RuntimeError(f"adding the fixture record: {(add.stdout + add.stderr).strip()[-300:]}")
    bid = fixture_batch(tree, env, "settled-incomplete", ["FAIL", "INCOMPLETE"], [1])
    print(f"EXPOSED: scratch batch {bid} holds 1 FAIL and 1 settled INCOMPLETE lap of 2 planned")
    why = measure(tree, env, FIXTURE_RECORD, bid, (1, 1))
    if why:
        wrong.append(f"settled-incomplete: {why}")
    bid = fixture_batch(tree, env, "settled-infra", ["FAIL", "INFRA", "FAIL"], [1])
    print(f"INFO scratch batch {bid} holds 2 FAIL and 1 settled INFRA lap of 2 planned")
    why = measure(tree, env, FIXTURE_RECORD, bid, (2, 2))
    if why:
        wrong.append(f"settled-infra: {why}")
    bid = fixture_batch(tree, env, "plan", ["FAIL", "INFRA"], [])
    probe = ("import json, sys; sys.path.insert(0, 'tools'); import defects\n"
             "entry, batch = defects.find_batch(defects.load(), sys.argv[1])\n"
             "print(len(defects.plan_laps(batch)))\n")
    counted = command(tree, env, ["-c", probe, bid])
    check = command(tree, env, ["tools/defects.py", "batch-check", bid, "--row",
                                FIXTURE_ROW, "--at", FIXTURE_CONFIG])
    print(f"INFO scratch batch {bid} holds 1 FAIL and 1 INFRA lap of 2 planned: plan_laps "
          f"{(counted.stdout + counted.stderr).strip()[-120:]}, batch-check rc={check.returncode} "
          f"{(check.stdout + check.stderr).strip()[-160:]}")
    if counted.returncode != 0 or counted.stdout.strip() != "1":
        wrong.append(f"plan: plan_laps counted {(counted.stdout + counted.stderr).strip()[-120:]}, not 1")
    if check.returncode != 0:
        wrong.append("plan: batch-check refused a lap with one place left")
    resume = (tree / "tools" / "harness_batch.py").read_text()
    if "defects.plan_laps(batch)" not in resume:
        wrong.append("plan: tools/harness_batch.py's resume does not count with plan_laps")
    return wrong


def main() -> int:
    env = {k: v for k, v in os.environ.items() if k not in LIVE_POINTERS}
    print(f"INFO MXFS_MEASURE_COUNT_SETTLED={env.get('MXFS_MEASURE_COUNT_SETTLED') or '(unset)'}")
    wrong = []
    for rid, batch, measured, settled in live_batches():
        print(f"INFO live batch {batch['id']} of {rid} ({batch['row']} at {batch['config']}) holds "
              f"{measured} measured and {settled} settled INCOMPLETE lap(s) of {batch['planned']} planned")
        with tempfile.TemporaryDirectory(prefix="measure_settled_") as scratch:
            why = measure(scratch_tree(Path(scratch) / "tree"), env, rid, batch["id"], None)
        if why:
            wrong.append(f"live: {why}")
    with tempfile.TemporaryDirectory(prefix="measure_settled_") as scratch:
        try:
            wrong += scratch_cases(scratch_tree(Path(scratch) / "tree"), env)
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            print(f"RESULT: ABORT the scratch cases could not be built: {exc}")
            return 2
    if wrong:
        print(f"LAP measure_settled FAIL: {'; '.join(wrong)}")
        return 1
    print("LAP measure_settled PASS: every batch with a settled lap closed with its rate, and "
          "plan_laps, batch-check and the resume agree on an INFRA lap")
    return 0


if __name__ == "__main__":
    sys.exit(main())
