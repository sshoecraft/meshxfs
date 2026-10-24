#!/usr/bin/env python3
"""One lap of D-VERIFY-REFUSAL-NAMES-VARIANT-LAPS-AS-UNEXPOSED: does a verification's refusal say
that exposed PASSes of an unplanned variant were dropped as a variant, not as unexposed?

tools/defects.py cmd_verify counts a PASS only when it is exposed and not an unplanned variant, and
its refusal counted every other PASS as one 'without exposure'. Verification b20261024-565ac2 of
D-PATH-ROW-REJOIN-DROPS-THE-LANES-MODARGS-SO-A-LANE-RUNS-MIXED-WINDOWS has six PASSes, each
exposure=1 and each run on a pair prepped with dead_timeout_ms=12000 (variant
marker_modargs=dead_timeout_ms=12000), and the refusal called them '6 PASS without exposure'.

The lap runs `defects.py verify` on that batch in a scratch tree of its own (a copy of tools/*.py
and of everything they read or write), so nothing is written to the live queue. The refusal exits
before anything is saved; the scratch tree keeps it so even if it did not.

    EXPOSED  the batch holds an exposed PASS of an unplanned variant (read from the live ledger with
             the tools' own exposed() and unplanned_variant())
    PASS     the refusal counts those PASSes as an unplanned variant, names the variant, and counts
             the PASSes without exposure apart
    FAIL     it counts them as PASSes without exposure, or does not name the variant

MXFS_VERIFY_NAME_VARIANT=0 (tools/defects.py) gives the refusal as before the fix: the control. The
lap hands its environment to the command.

Bound, derived: copying data/ (~10 MB) and reading the queue and the primary ledger in one
interpreter, as tests/measure_settled_lap.py does (1.0 s a lap for two batches); a batch lap is
bounded at 3 s, each command at 20 s.

Usage: tests/verify_refusal_variant_lap.py
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(os.path.abspath(__file__)).parents[1]
COMMAND_BOUND = 20
RECORD = "D-PATH-ROW-REJOIN-DROPS-THE-LANES-MODARGS-SO-A-LANE-RUNS-MIXED-WINDOWS"
BATCH = "b20261024-565ac2"
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
import defects  # noqa: E402


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
    shutil.copytree(ROOT / "data", base / "data", symlinks=True,
                    ignore=shutil.ignore_patterns("*.tmp"), copy_function=copy_present)
    declared = json.loads((ROOT / "data" / "configurations.json").read_text())
    for board in sorted({spec["board"] for spec in (declared.get("attaches") or {}).values()
                         if isinstance(spec, dict) and spec.get("board")}):
        source = ROOT / board
        target = base / board
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        ledger = source.with_name(source.stem + ".runs.jsonl")
        if ledger.exists():
            shutil.copy2(ledger, target.with_name(ledger.name))
    shutil.copy2(ROOT / "CHANGELOG.md", base / "CHANGELOG.md")
    return base


def main() -> int:
    print(f"INFO MXFS_VERIFY_NAME_VARIANT={os.environ.get('MXFS_VERIFY_NAME_VARIANT') or '(unset)'}")
    entry = next((e for e in json.loads((ROOT / "data" / "defects.json").read_text())["defects"]
                  if e["id"] == RECORD), None)
    batch = next((b for b in (entry or {}).get("batches", []) if b["id"] == BATCH), None)
    if batch is None or batch.get("state") != "open":
        print(f"RESULT: ABORT batch {BATCH} of {RECORD} is not an open batch in the queue")
        return 2
    board = criteria.board_for(batch["config"])
    passes = [r for r in criteria.ledger_runs(board, batch["config"], batch["row"])
              if r.get("batch") == BATCH and r.get("outcome") == "PASS"]
    variant = [r for r in passes if defects.exposed(r, batch) and defects.unplanned_variant(r, batch)]
    unexposed = [r for r in passes if not defects.exposed(r, batch)]
    names = sorted({str(r.get("variant") or r.get("build") or "?") for r in variant})
    if not variant:
        print(f"RESULT: ABORT batch {BATCH} holds no exposed PASS of an unplanned variant")
        return 2
    print(f"EXPOSED: batch {BATCH} holds {len(variant)} exposed PASS lap(s) of an unplanned variant "
          f"({', '.join(names)}) and {len(unexposed)} without exposure")
    env = {k: v for k, v in os.environ.items() if k not in LIVE_POINTERS}
    with tempfile.TemporaryDirectory(prefix="verify_refusal_") as scratch:
        tree = scratch_tree(Path(scratch) / "tree")
        out = subprocess.run([sys.executable, "tools/defects.py", "verify", RECORD, "--batch", BATCH],
                             cwd=tree, env=env, capture_output=True, text=True,
                             timeout=COMMAND_BOUND)
    text = (out.stdout + out.stderr).strip()
    print(f"  verify rc={out.returncode}: {text[-400:]}")
    want = (f"{len(unexposed)} PASS without exposure and {len(variant)} run as an unplanned variant "
            f"({', '.join(names)})")
    if out.returncode != 0 and want in text:
        print(f"VERIFY_REFUSAL_LAP PASS: the refusal names the {len(variant)} variant PASS(es) apart "
              f"from the {len(unexposed)} without exposure")
        return 0
    print(f"VERIFY_REFUSAL_LAP FAIL: the refusal does not say '{want}'")
    return 1


if __name__ == "__main__":
    sys.exit(main())
