#!/usr/bin/env python3
"""One lap of D-CRITERIA-UNRETIRE-REFUSES-LAP-ROWS-SO-WRONG-LAP-RETIREMENTS-STAND: taking back a
retirement on a batch lap's run.

tools/defects.py verify writes a retired_by note on every cell of the record it verifies, batch
laps (row `lap:<name>`) included, and tools/criteria.py unretire is how a wrong one is taken back.
unretire found its run through annotated_run, which took a board criterion's id or a release
step's row and nothing else, so for a lap row it printed "criteria: nothing matches 'lap:<name>'"
and the retirement stood. In a scratch tree of its own (tests/release_step_cell_lap.py's copy:
the tools and everything they read or write, the DRBD rig's board and ledger included, so nothing
live is written) the lap takes one retired lap run, a control lap of the DRBD rig-tag record that
its verify retired, stops the copy's queue naming it, and asks the copy's gate:

    EXPOSED   the run is a lap row's FAIL that carries a retired_by note, and the gate does not
              list it (the retirement settles it)
    PASS      `criteria.py unretire <row> --at <config> --iso <stamp>` returns 0 and the gate
              lists the run again
    FAIL      unretire is refused, or the gate still does not list the run

MXFS_LAP_ANNOTATE=0 (tools/criteria.py) looks a lap's row up as a board criterion, as before the
fix: the same-build control. The lap hands its environment to every command.

Bound, derived: one scratch copy, two gate reads and one unretire; the precheck on 2026-10-24 took
1.07-1.08 s with the fix and 0.71 s without, so a batch lap is bounded at twice the longest, 3 s;
each command at 20 s.

Usage: tests/unretire_lap_row_lap.py [RUN]
       (default: 2/net/mesh/drbd:lap:drbd_rig_tag:2026-10-24T02:56:01Z, lap 1 of control
       b20261023-920e59)
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

RUN = sys.argv[1] if len(sys.argv) > 1 else "2/net/mesh/drbd:lap:drbd_rig_tag:2026-10-24T02:56:01Z"
KEY = re.compile(r"([^:]+):(lap:[^:]+):(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)")


def ledger_entries(tree: Path, key: tuple) -> tuple:
    """(the run, the notes on it) for the key, from the copy's run ledger of its configuration."""
    config, row, iso = key
    attach = config.rsplit("/", 1)[-1]
    declared = json.loads((tree / "data" / "configurations.json").read_text())
    board = (declared.get("attaches") or {}).get(attach, {}).get("board")
    ledger = tree / (board[:-len(".json")] + ".runs.jsonl" if board else "data/criteria.runs.jsonl")
    run, notes = None, []
    with ledger.open() as handle:
        for line in handle:
            if f'"{iso}"' not in line:
                continue
            try:
                item = json.loads(line)
            except ValueError:
                continue
            if (item.get("config"), item.get("row"), item.get("iso")) != key:
                continue
            if item.get("kind") == "run":
                run = item
            elif item.get("kind") == "note":
                notes.append(item)
    return run, notes


def standing_retirement(notes: list) -> bool:
    """Whether a retired_by note stands: one not taken back by a later withdrawn note of it."""
    standing = False
    for item in notes:
        if item.get("note") == "retired_by":
            standing = True
        elif item.get("note") == "withdrawn" and (item.get("value") or {}).get("of") == "retired_by":
            standing = False
    return standing


def main() -> int:
    print(f"INFO MXFS_LAP_ANNOTATE={os.environ.get('MXFS_LAP_ANNOTATE') or '(unset)'} run={RUN}")
    match = KEY.fullmatch(RUN)
    if not match:
        print(f"ABORT: {RUN} is not a lap row's run key")
        return 2
    key = match.groups()
    base = Path(tempfile.mkdtemp(prefix="unretire_lap_row_lap."))
    try:
        tree = cell_lap.scratch_tree(base / "tree")
        run, notes = ledger_entries(tree, key)
        if not run or run.get("outcome") not in ("FAIL", "INCOMPLETE"):
            print(f"ABORT: the ledger holds no failed lap run {RUN}")
            return 2
        if not standing_retirement(notes):
            print(f"ABORT: {RUN} carries no standing retired_by note")
            return 2
        cell_lap.unname(tree, key)
        before = cell_lap.listed(tree, RUN)
        if before is None:
            print("ABORT: the scratch gate could not be read")
            return 2
        if before:
            print(f"ABORT: the scratch gate lists {RUN} though its retirement stands")
            return 2
        print(f"EXPOSED: {RUN} is a lap row's {run.get('outcome')} settled by a retired_by note, "
              "and the gate does not list it")
        config, row, iso = key
        out = cell_lap.command(tree, ["tools/criteria.py", "unretire", row, "--at", config,
                                      "--iso", iso, "--why", "unretire_lap_row_lap scratch take-back"])
        text = (out.stdout + out.stderr).strip()
        print(f"INFO unretire: rc={out.returncode} {text[-200:]}")
        if out.returncode != 0:
            print(f"FAIL: criteria.py unretire {row} --at {config} --iso {iso} was refused: "
                  f"{text[-200:]}")
            return 1
        after = cell_lap.listed(tree, RUN)
        if after is None:
            print("ABORT: the scratch gate could not be read after the unretire")
            return 2
        if not after:
            print(f"FAIL: unretire returned 0 but the gate does not list {RUN} again")
            return 1
        print(f"PASS: the retirement of {RUN} was taken back and the gate lists it again")
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
