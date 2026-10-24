#!/usr/bin/env python3
"""Reproducer of D-RELEASE-STEP-CELL-LAP-COPIES-LIVE-DATA-DIR-AND-DIES-ON-A-VANISHED-TMP-FILE.

tests/release_step_cell_lap.py's scratch_tree copies the tree's data/ while other processes write
it. tools/defects.py save() replaces data/defects.json by writing data/defects.json.tmp and renaming
it over the queue, so a copy that listed the directory while the temporary file existed and reached
it after the rename died with shutil.Error (No such file or directory), and the lap recorded no
verdict.

This builds a scratch tree (a copy of TREE's data/, its own-rig boards and CHANGELOG.md; TREE is
this tree unless named, and a sibling checkout that has no tests/evidence/ names the one that
does), starts a writer process that saves the scratch queue in a loop through tools/defects.py
save() itself (MXFS_DEFECTS points it at the scratch queue), and while it writes, runs the lap's
own scratch_tree on the scratch tree, with the lap's ROOT pointed there, COPIES times. Each copy that raises is a
death; each copy whose data/defects.json is not a whole JSON document is torn. The writer's save
count shows it kept writing through the copies.

    EXPOSED  the writer saved the queue while the copies ran
    PASS     no copy died and none is torn
    FAIL     a copy died or is torn

MXFS_RELEASE_STEP_COPY=0 copies data/ whole, as before the fix: the control.

Bound, derived: one copy of data/ (15 MB) measured at about 0.05 s on the tree of 2026-10-23, so
200 copies are about 10 s, and the writer's saves of the 1.5 MB queue run beside them; 2x is 20 s,
and the writer stops itself at 30 s if the copies never end.

Usage: tests/release_step_copy_race.py [COPIES [TREE]]
Exit: 0 PASS, 1 FAIL, 2 the reproducer could not measure.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COPIES = 200
#: seconds the writer saves for at most, should the copies never end
WRITER_BOUND = 30


def writer(queue: str, stop: str) -> int:
    """Save the scratch queue through tools/defects.py save() until the stop file appears; print
    the number of saves."""
    os.environ["MXFS_DEFECTS"] = queue
    sys.path.insert(0, str(ROOT / "tools"))
    import defects
    data = defects.load()
    saves = 0
    deadline = time.monotonic() + WRITER_BOUND
    while not os.path.exists(stop) and time.monotonic() < deadline:
        defects.save(data)
        saves += 1
    print(saves)
    return 0


def lap_module():
    spec = importlib.util.spec_from_file_location("release_step_cell_lap",
                                                  ROOT / "tests" / "release_step_cell_lap.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(copies: int, source: Path) -> int:
    lap = lap_module()
    print(f"INFO MXFS_RELEASE_STEP_COPY={os.environ.get('MXFS_RELEASE_STEP_COPY') or '(unset)'}")
    scratch = Path(tempfile.mkdtemp(prefix="release_step_copy_race."))
    try:
        tree = scratch / "tree"
        (tree / "tools").mkdir(parents=True)
        # the scratch tree is built from TREE, whose data/ may be live, so the copy that builds it
        # skips the live writers' temporary files on its own
        shutil.copytree(source / "data", tree / "data", symlinks=True,
                        ignore=shutil.ignore_patterns("*.tmp"), copy_function=lap.copy_present)
        lap.ROOT = source
        for board in lap.own_boards():
            target = tree / board
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / board, target)
            ledger = (source / board).with_name(Path(board).stem + ".runs.jsonl")
            if ledger.exists():
                shutil.copy2(ledger, target.with_name(ledger.name))
        shutil.copy2(source / "CHANGELOG.md", tree / "CHANGELOG.md")
        lap.ROOT = tree
        stop = scratch / "stop"
        proc = subprocess.Popen([sys.executable, __file__, "--writer",
                                 str(tree / "data" / "defects.json"), str(stop)],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        while not (tree / "data" / "defects.json.tmp").exists() and proc.poll() is None:
            time.sleep(0.01)
        died, torn, first = 0, 0, ""
        t0 = time.monotonic()
        for number in range(copies):
            base = scratch / f"copy{number:03d}"
            try:
                lap.scratch_tree(base)
                try:
                    json.loads((base / "data" / "defects.json").read_text())
                except ValueError:
                    torn += 1
            except (shutil.Error, OSError) as exc:
                died += 1
                first = first or f"{type(exc).__name__}: {str(exc)[:300]}"
            shutil.rmtree(base, ignore_errors=True)
        elapsed = time.monotonic() - t0
        stop.touch()
        out, _ = proc.communicate(timeout=WRITER_BOUND)
        words = out.split()
        saves = int(words[-1]) if words and words[-1].isdigit() else 0
        if proc.returncode != 0 or not saves:
            print(f"UNMEASURED: the writer did not save the queue (rc={proc.returncode}): "
                  f"{out.strip()[-300:]}")
            return 2
        print(f"EXPOSED: the writer saved the scratch queue {saves} times through "
              f"tools/defects.py save() while {copies} copies ran ({elapsed:.1f} s)")
        if first:
            print(f"INFO first death: {first}")
        if died or torn:
            print(f"FAIL: {died} of {copies} copies died and {torn} are torn")
            return 1
        print(f"PASS: 0 of {copies} copies died and 0 are torn")
        return 0
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--writer"]:
        sys.exit(writer(sys.argv[2], sys.argv[3]))
    sys.exit(main(int(sys.argv[1]) if sys.argv[1:] else COPIES,
                  Path(sys.argv[2]).resolve() if sys.argv[2:] else ROOT))
