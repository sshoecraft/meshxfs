#!/usr/bin/env python3
"""One lap of D-DEFECTS-PARSE-CELL-REFUSES-A-DAY-STAMP-SO-MIGRATED-RUNS-CANNOT-BE-NAMED: naming and
dropping runs whose stamps the board migration and the release orchestrator wrote.

The boards moved into run ledgers on 2026-10-21, and a run its board had recorded by date only kept
that date as its stamp: 32/net/mesh/direct:prep_cluster:2026-08-28 (data/criteria.runs.jsonl). The
incident gate lists it, and tools/defects.py parse_cell took only a full ...THH:MM:SSZ stamp, so
`update --cell` refused it ("a board run is CONFIG:ROW:ISO") and no record could name it. A release
step's run (row `release:<step>`, a colon of its own) has to keep parsing under the same anchored
form. In a scratch tree of its own (tests/release_step_cell_lap.py's copy: the tools and everything
they read or write, so nothing live is written; the lap's two records added to the copy's queue, and
the runs' live names and annotations taken out of the copy) the lap runs three parts, each with the
queue's own command, and asks the copy's gate after each:

    day       `update <record> --cell <day-stamped run>`: returns 0 and the gate no longer lists it
    step      `update <record> --cell <release step run>`: returns 0 and the gate no longer lists it
    drop      the day-stamped run named by both records, `update <record> --drop-cell <run>
              --drop-why ...`: returns 0, the record no longer names it, and the gate still does
              not list it (the other record accounts for it)

    EXPOSED   before the first part, the unfiltered gate lists the day-stamped run
    PASS      all three parts as above
    FAIL      any part refused or its gate reading wrong (every part runs; each is reported)

MXFS_CELL_DAY_STAMP=0 (tools/defects.py) takes only a full stamp, as before the fix: the same-build
control, in which day and drop are refused and step passes. The lap hands its environment to every
command.

Bound, derived: one scratch copy, three updates (a queue load and save each) and four gate reads;
measured on 2026-10-24 at 3.1 s with the fix and 2.1 s without (the copy's 12k-line ledger), so a
batch lap is bounded at twice the longest, 7 s; each command at 20 s.

Usage: tests/cell_day_stamp_lap.py [DAY_RUN] [STEP_RUN]
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_step_cell_lap as cell_lap  # noqa: E402

DAY_RUN = sys.argv[1] if len(sys.argv) > 1 else "32/net/mesh/direct:prep_cluster:2026-08-28"
STEP_RUN = sys.argv[2] if len(sys.argv) > 2 else "1/any:release:boards:2026-10-21T19:29:49Z"
#: the lap's own records, added to the scratch queue only
RECORD = "D-CELL-DAY-STAMP-LAP-SCRATCH-RECORD"
OTHER = "D-CELL-DAY-STAMP-LAP-SCRATCH-OTHER"
DAY_KEY = re.compile(r"([^:]+):(.+):(\d{4}-\d\d-\d\d)")


def add_record(tree: Path, rid: str, names: tuple = ()) -> None:
    """A record in the scratch queue, through its own load and save; it names the runs given
    without check_cells, as a record that named them before this fix could not have."""
    probe = ("import sys, datetime; sys.path.insert(0, 'tools'); import defects\n"
             "data = defects.load()\n"
             "if any(r['id'] == sys.argv[1] for r in data['defects']):\n"
             "    sys.exit('the scratch queue already holds ' + sys.argv[1])\n"
             "cells = [dict(zip(('config', 'row', 'iso'), sys.argv[i:i + 3]))\n"
             "         for i in range(2, len(sys.argv), 3)]\n"
             "data['defects'].append({'id': sys.argv[1], 'severity': 'minor', 'nodes': 1,\n"
             "    'config': '*/*/*', 'opened': datetime.date.today().isoformat(),\n"
             "    'summary': 'scratch record of tests/cell_day_stamp_lap.py', 'cells': cells})\n"
             "defects.save(data)\n")
    argv = ["-c", probe, rid]
    for key in names:
        argv += list(key)
    out = cell_lap.command(tree, argv)
    if out.returncode != 0:
        raise RuntimeError(f"add_record rc={out.returncode}: {(out.stdout + out.stderr).strip()[-300:]}")


def names(tree: Path, rid: str, key: tuple) -> bool:
    out = cell_lap.command(tree, ["-c", "import sys; sys.path.insert(0, 'tools'); import defects\n"
                                  "e = [r for r in defects.load()['defects'] if r['id'] == sys.argv[1]]\n"
                                  "print(any((c['config'], c['row'], c['iso']) == tuple(sys.argv[2:5])\n"
                                  "          for c in (e[0].get('cells') or []) if e))\n",
                                  rid] + list(key))
    return out.stdout.strip() == "True"


def update(tree: Path, argv: list) -> tuple:
    out = cell_lap.command(tree, ["tools/defects.py", "update"] + argv)
    return out.returncode, (out.stdout + out.stderr).strip()


def main() -> int:
    print(f"INFO MXFS_CELL_DAY_STAMP={os.environ.get('MXFS_CELL_DAY_STAMP') or '(unset)'} "
          f"day_run={DAY_RUN} step_run={STEP_RUN}")
    day = DAY_KEY.fullmatch(DAY_RUN)
    step = cell_lap.KEY.fullmatch(STEP_RUN)
    if not day or not step or not step.group(2).startswith("release:"):
        print(f"ABORT: {DAY_RUN} is not a date-stamped run key or {STEP_RUN} not a release step's")
        return 2
    for run, match in ((DAY_RUN, day), (STEP_RUN, step)):
        found = cell_lap.live_run(match.groups())
        if not found or found.get("outcome") == "PASS":
            print(f"ABORT: the primary ledger holds no failed run {run}")
            return 2
    wrong = []
    base = Path(tempfile.mkdtemp(prefix="cell_day_stamp_lap."))
    try:
        tree = cell_lap.scratch_tree(base / "tree")
        for match in (day, step):
            cell_lap.unname(tree, match.groups())
            cell_lap.unsettle(tree, match.groups())
        add_record(tree, RECORD)
        before = cell_lap.listed(tree, DAY_RUN)
        if before is None:
            print("ABORT: the scratch gate could not be read")
            return 2
        if not before:
            print(f"ABORT: the scratch gate does not list {DAY_RUN}")
            return 2
        print(f"EXPOSED: the unfiltered gate lists {DAY_RUN}, a run stamped with a date alone")
        for part, run in (("day", DAY_RUN), ("step", STEP_RUN)):
            rc, text = update(tree, [RECORD, "--cell", run])
            print(f"INFO {part} update --cell {run}: rc={rc} {text[-200:]}")
            if rc != 0:
                wrong.append(f"{part}: update --cell {run} refused: {text[-160:]}")
                continue
            after = cell_lap.listed(tree, run)
            if after is None:
                print(f"ABORT: the scratch gate could not be read after {part}")
                return 2
            if after:
                wrong.append(f"{part}: {RECORD} names {run} but the gate still lists it")
            else:
                print(f"INFO {part}: {RECORD} names {run} and the gate no longer lists it")
        # drop: the day-stamped run named by both records, then dropped from one
        if not names(tree, RECORD, day.groups()):
            unrec = cell_lap.command(tree, [
                "-c", "import sys; sys.path.insert(0, 'tools'); import defects\n"
                "data = defects.load()\n"
                "r = next(r for r in data['defects'] if r['id'] == sys.argv[1])\n"
                "r.setdefault('cells', []).append(dict(zip(('config', 'row', 'iso'), sys.argv[2:5])))\n"
                "defects.save(data)\n", RECORD] + list(day.groups()))
            if unrec.returncode != 0:
                print(f"ABORT: could not name {DAY_RUN} in {RECORD}: {(unrec.stdout + unrec.stderr)[-200:]}")
                return 2
        add_record(tree, OTHER, (day.groups(),))
        rc, text = update(tree, [RECORD, "--drop-cell", DAY_RUN, "--drop-why",
                                 f"cell_day_stamp_lap scratch drop: {OTHER} names it"])
        print(f"INFO drop update --drop-cell {DAY_RUN}: rc={rc} {text[-200:]}")
        if rc != 0:
            wrong.append(f"drop: update --drop-cell {DAY_RUN} refused: {text[-160:]}")
        elif names(tree, RECORD, day.groups()):
            wrong.append(f"drop: {RECORD} still names {DAY_RUN} after the drop")
        else:
            still = cell_lap.listed(tree, DAY_RUN)
            if still is None:
                print("ABORT: the scratch gate could not be read after the drop")
                return 2
            if still:
                wrong.append(f"drop: the gate lists {DAY_RUN} although {OTHER} names it")
            else:
                print(f"INFO drop: {RECORD} no longer names {DAY_RUN} and {OTHER} still accounts for it")
    except subprocess.TimeoutExpired as exc:
        print(f"ABORT: a command overran its {cell_lap.COMMAND_BOUND} s bound: {exc.cmd}")
        return 2
    except RuntimeError as exc:
        print(f"ABORT: {exc}")
        return 2
    finally:
        shutil.rmtree(base, ignore_errors=True)
    if wrong:
        print(f"FAIL: {len(wrong)} of 3 parts: " + "; ".join(w[:220] for w in wrong))
        return 1
    print("PASS: a day-stamped run named and dropped, and a release step's run named, each "
          "settling the gate as the command says")
    return 0


if __name__ == "__main__":
    sys.exit(main())
