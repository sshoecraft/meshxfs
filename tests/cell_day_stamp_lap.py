#!/usr/bin/env python3
"""One lap of D-DEFECTS-PARSE-CELL-REFUSES-A-DAY-STAMP-SO-MIGRATED-RUNS-CANNOT-BE-NAMED: naming a run
the board migration brought into the ledger, whose stamp is a date alone.

The boards moved into run ledgers on 2026-10-21, and a run its board had recorded by date only kept
that date as its stamp: 32/net/mesh/direct:prep_cluster:2026-08-28 (data/criteria.runs.jsonl). The
incident gate lists it, and tools/defects.py parse_cell took only a full ...THH:MM:SSZ stamp, so
`update --cell` refused it ("a board run is CONFIG:ROW:ISO") and no record could name it. In a
scratch tree of its own (tests/release_step_cell_lap.py's copy: the tools and everything they read
or write, so nothing live is written) the lap names the run with the record's own command and asks
the copy's gate:

    EXPOSED   the unfiltered `incidents` lists the run, a date-stamped FAIL or INCOMPLETE
    PASS      `defects.py update <record> --cell <run>` returns 0 and the gate no longer lists it
    FAIL      the update is refused, or the gate still lists the run

MXFS_CELL_DAY_STAMP=0 (tools/defects.py) takes only a full stamp, as before the fix: the same-build
control. The lap hands its environment to every command.

Bound, derived: one scratch copy, one update (a queue load and save) and two gate reads; the
precheck on 2026-10-24 took 1.21 s with the fix and 0.75 s without, so a batch lap is bounded at
twice the longest, 3 s; each command at 20 s.

Usage: tests/cell_day_stamp_lap.py [RECORD] [RUN]
       (defaults: D-32NETMESH-PREP-CLUSTER-FAILED-AFTER-9S-NO-EVIDENCE-RETAINED and its run)
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

RECORD = sys.argv[1] if len(sys.argv) > 1 else \
    "D-32NETMESH-PREP-CLUSTER-FAILED-AFTER-9S-NO-EVIDENCE-RETAINED"
RUN = sys.argv[2] if len(sys.argv) > 2 else "32/net/mesh/direct:prep_cluster:2026-08-28"
KEY = re.compile(r"([^:]+):(.+):(\d{4}-\d\d-\d\d)")


def main() -> int:
    print(f"INFO MXFS_CELL_DAY_STAMP={os.environ.get('MXFS_CELL_DAY_STAMP') or '(unset)'} "
          f"record={RECORD} run={RUN}")
    match = KEY.fullmatch(RUN)
    if not match:
        print(f"ABORT: {RUN} is not a date-stamped run key")
        return 2
    found = cell_lap.live_run(match.groups())
    if not found or found.get("outcome") == "PASS":
        print(f"ABORT: the primary ledger holds no failed run {RUN}")
        return 2
    base = Path(tempfile.mkdtemp(prefix="cell_day_stamp_lap."))
    try:
        tree = cell_lap.scratch_tree(base / "tree")
        cell_lap.unname(tree, match.groups())
        before = cell_lap.listed(tree, RUN)
        if before is None:
            print("ABORT: the scratch gate could not be read")
            return 2
        if not before:
            print(f"ABORT: the scratch gate does not list {RUN}")
            return 2
        print(f"EXPOSED: the unfiltered gate lists {RUN}, a run stamped with a date alone "
              f"({found.get('outcome')})")
        out = cell_lap.command(tree, ["tools/defects.py", "update", RECORD, "--cell", RUN])
        text = (out.stdout + out.stderr).strip()
        print(f"INFO update --cell: rc={out.returncode} {text[-200:]}")
        if out.returncode != 0:
            print(f"FAIL: defects.py update {RECORD} --cell {RUN} was refused: {text[-200:]}")
            return 1
        after = cell_lap.listed(tree, RUN)
        if after is None:
            print("ABORT: the scratch gate could not be read after the update")
            return 2
        if after:
            print(f"FAIL: {RECORD} names {RUN} but the gate still lists it")
            return 1
        print(f"PASS: {RECORD} names {RUN} and the gate no longer lists it")
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
