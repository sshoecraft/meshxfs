#!/usr/bin/env python3
"""One lap of D-RELEASE-RUN-STEP-INCIDENTS-CANNOT-BE-SETTLED: every disposition a failed release
step can take, through its own command, on each shape of key a step's run is filed under.

tools/release_run.py records each step's outcome as a run of row `release:<step>` in the primary
board's ledger, under the placeholder configuration `1/any` or the step's own configuration, which
can be an own-rig one whose board is not the primary (2/net/mesh/drbd). `tools/criteria.py
incidents` lists a failed one until an open record names it or a reviewed disposition settles it.
The lap takes three recorded step FAILs, one of each shape:

    1/any:release:boards:2026-10-21T19:29:49Z                  the placeholder configuration
    2/net/mesh/direct:release:platforms:2026-10-21T20:12:33Z   a configuration parse_at takes
    2/net/mesh/drbd:release:drbd:2026-10-22T00:35:43Z          an own-rig configuration

and settles each in the three ways a session settles one:

    infra    defects.py propose infra-proven --target, review --approve, criteria.py infra
    amend    defects.py propose detector-defect --target, review --approve, criteria.py amend;
             then criteria.py unamend takes it back
    removal  defects.py update <record> --cell, propose remove-disproved, review --approve,
             defects.py remove --disproved, whose retire_cells retires the run; then
             criteria.py unretire takes the retirement back

Each of the nine runs in a scratch tree of its own: a copy of tools/*.py and of everything those
tools read or write (data/, the DRBD board and its ledger, CHANGELOG.md), so the lap writes nothing
to the live queue, proposals, reviews or ledgers. The copy's queue first stops naming the run, so
the copy's gate reads it as unaccounted for. The approvals are the scratch tree's own, written
only to drive the commands there.

    EXPOSED   in a scratch tree, before its disposition, the gate lists the run
    PASS      after each of the nine dispositions the gate no longer lists its run, and after
              each take-back (unamend, unretire) it lists the run again
    FAIL      a command refused, the gate still lists the run after its disposition, or no
              longer lists it after the take-back

MXFS_RELEASE_STEP_SETTLE=0 (tools/criteria.py) reads and routes a release step's run as any other
run, as before the fix: the fix's control. The lap hands its environment to every command.

Bound, derived: each command is one interpreter reading the queue (1.5 MB), the proposals and the
primary board and ledger (6 MB); a disposition is 3-5 commands and the gate twice. Measured on the
tree of 2026-10-23 with every disposition settling: all nine with their copies (~10 MB each) in
15.1 s. A batch lap is bounded at 2x that, 30 s; each command at 20 s.

Usage: tests/release_step_cell_lap.py
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
RUNS = ("1/any:release:boards:2026-10-21T19:29:49Z",
        "2/net/mesh/direct:release:platforms:2026-10-21T20:12:33Z",
        "2/net/mesh/drbd:release:drbd:2026-10-22T00:35:43Z")
DISPOSITIONS = ("infra", "amend", "removal")
#: the command that takes a disposition back (criteria.py withdraw); infra has none
TAKE_BACK = {"amend": "unamend", "removal": "unretire"}
#: the record the removal disposition names the run in and removes, in the scratch tree only
RECORD = "D-RELEASE-RUN-STEP-INCIDENTS-CANNOT-BE-SETTLED"
COMMAND_BOUND = 20
KEY = re.compile(r"([^:]+):(.+):(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)")
PROPOSAL = re.compile(r"\bproposal (P\d{8}-[0-9a-f]{6})\b")
#: the environment that would point a scratch tree's tools at the live files
LIVE_POINTERS = ("MXFS_CRIT", "MXFS_OWN_RIG", "MXFS_SPEC", "MXFS_DEFECTS")


def own_boards() -> list:
    """Every own-rig board data/configurations.json names, as tree paths."""
    declared = json.loads((ROOT / "data" / "configurations.json").read_text())
    return sorted({spec["board"] for spec in (declared.get("attaches") or {}).values()
                   if isinstance(spec, dict) and spec.get("board")})


def scratch_tree(base: Path) -> Path:
    """A tree holding copies of the tools and of every file they read or write."""
    (base / "tools").mkdir(parents=True)
    for source in (ROOT / "tools").glob("*.py"):
        shutil.copy2(source, base / "tools" / source.name)
    shutil.copytree(ROOT / "data", base / "data", symlinks=True)
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


def command(tree: Path, argv: list) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k not in LIVE_POINTERS}
    return subprocess.run([sys.executable] + argv, cwd=tree, env=env, capture_output=True,
                          text=True, timeout=COMMAND_BOUND)


def listed(tree: Path, run: str) -> bool | None:
    """Whether the scratch tree's gate lists the run; None when the gate could not be read."""
    out = command(tree, ["tools/criteria.py", "incidents"])
    if out.returncode not in (0, 1):
        print(f"INFO gate rc={out.returncode}: {(out.stdout + out.stderr).strip()[-300:]}")
        return None
    return any(line.strip().startswith(run + " ") for line in out.stdout.splitlines())


def unname(tree: Path, key: tuple) -> None:
    """The scratch queue stops naming the run, through the queue's own load and save, so the
    scratch gate shows what the disposition alone does."""
    probe = ("import sys; sys.path.insert(0, 'tools'); import defects\n"
             "key = tuple(sys.argv[1:4])\n"
             "data = defects.load()\n"
             "for record in data['defects']:\n"
             "    for field in ('cells', 'collateral'):\n"
             "        if record.get(field):\n"
             "            record[field] = [c for c in record[field]\n"
             "                             if (c.get('config'), c.get('row'), c.get('iso')) != key]\n"
             "defects.save(data)\n")
    out = command(tree, ["-c", probe] + list(key))
    if out.returncode != 0:
        raise RuntimeError(f"unname rc={out.returncode}: {(out.stdout + out.stderr).strip()[-300:]}")


def step(tree: Path, argv: list, label: str) -> str:
    out = command(tree, argv)
    text = (out.stdout + out.stderr).strip()
    if out.returncode != 0:
        raise RefusedError(f"{label} refused (rc={out.returncode}): {text[-260:]}")
    return text


class RefusedError(Exception):
    pass


def approved(tree: Path, propose_argv: list) -> str:
    """A proposal made and approved in the scratch tree; its id."""
    text = step(tree, ["tools/defects.py", "propose"] + propose_argv
                + ["--argument", "release_step_cell_lap: drives the command in a scratch tree",
                   "--evidence", "data/criteria.runs.jsonl"], "propose")
    match = PROPOSAL.search(text)
    if not match:
        raise RefusedError(f"propose printed no proposal id: {text[-200:]}")
    pid = match.group(1)
    review = tree / "data" / "reviews" / f"{pid}.md"
    review.write_text(f"# {pid}\n\nScratch-tree approval made by tests/release_step_cell_lap.py "
                      "to drive the disposition's own command; it exists only in the lap's copy.\n")
    step(tree, ["tools/defects.py", "review", pid, "--approve", "--file",
                str(review.relative_to(tree))], "review")
    return pid


def dispose(tree: Path, how: str, run: str, key: tuple) -> None:
    config, row, iso = key
    if how == "infra":
        pid = approved(tree, ["infra-proven", "--target", run])
        step(tree, ["tools/criteria.py", "infra", row, "--at", config, "--iso", iso,
                    "--why", "release_step_cell_lap scratch disposition", "--approval", pid],
             "criteria.py infra")
    elif how == "amend":
        pid = approved(tree, ["detector-defect", "--target", run])
        step(tree, ["tools/criteria.py", "amend", row, "--at", config, "--iso", iso,
                    "--detector-defect", "release_step_cell_lap scratch disposition",
                    "--approval", pid], "criteria.py amend")
    else:
        step(tree, ["tools/defects.py", "update", RECORD, "--cell", run], "defects.py update --cell")
        pid = approved(tree, ["remove-disproved", "--record", RECORD])
        step(tree, ["tools/defects.py", "remove", RECORD, "--disproved", "--why",
                    "release_step_cell_lap scratch disposition", "--approval", pid],
             "defects.py remove")


def live_run(key: tuple) -> dict | None:
    config, row, iso = key
    found = None
    with (ROOT / "data" / "criteria.runs.jsonl").open() as handle:
        for line in handle:
            if f'"{iso}"' not in line:
                continue
            try:
                item = json.loads(line)
            except ValueError:
                continue
            if item.get("kind") == "run" and (item.get("config"), item.get("row"),
                                              item.get("iso")) == key:
                found = item
    return found


def main() -> int:
    switch = os.environ.get("MXFS_RELEASE_STEP_SETTLE", "")
    print(f"INFO MXFS_RELEASE_STEP_SETTLE={switch or '(unset)'}")
    keys = {}
    for run in RUNS:
        match = KEY.fullmatch(run)
        found = live_run(match.groups()) if match else None
        if not found or found.get("outcome") != "FAIL" or not found.get("row", "").startswith("release:"):
            print(f"ABORT: the primary ledger holds no release step FAIL {run}")
            return 2
        keys[run] = match.groups()
    wrong, exposed = [], 0
    base = Path(tempfile.mkdtemp(prefix="release_step_cell_lap."))
    try:
        for number, (run, how) in enumerate((r, h) for r in RUNS for h in DISPOSITIONS):
            if True:
                tree = scratch_tree(base / f"{number:02d}")
                unname(tree, keys[run])
                before = listed(tree, run)
                if before is None:
                    print(f"ABORT: the scratch gate could not be read before {how} of {run}")
                    return 2
                if not before:
                    print(f"ABORT: the scratch gate does not list {run} before {how}")
                    return 2
                exposed += 1
                print(f"EXPOSED: the gate lists {run}, a release step FAIL, before {how}")
                try:
                    dispose(tree, how, run, keys[run])
                except RefusedError as exc:
                    wrong.append(f"{how} {run}: {exc}")
                    print(f"INFO {how} {run}: {exc}")
                    shutil.rmtree(tree)
                    continue
                after = listed(tree, run)
                if after is None:
                    print(f"ABORT: the scratch gate could not be read after {how} of {run}")
                    return 2
                if after:
                    wrong.append(f"{how} {run}: the gate still lists it")
                    print(f"INFO {how} {run}: the gate still lists it after the disposition")
                    shutil.rmtree(tree)
                    continue
                print(f"INFO {how} {run}: settled, the gate no longer lists it")
                back = TAKE_BACK.get(how)
                if back:
                    config, row, iso = keys[run]
                    try:
                        step(tree, ["tools/criteria.py", back, row, "--at", config, "--iso", iso,
                                    "--why", "release_step_cell_lap scratch take-back"],
                             f"criteria.py {back}")
                    except RefusedError as exc:
                        wrong.append(f"{back} {run}: {exc}")
                        print(f"INFO {back} {run}: {exc}")
                        shutil.rmtree(tree)
                        continue
                    again = listed(tree, run)
                    if again is None:
                        print(f"ABORT: the scratch gate could not be read after {back} of {run}")
                        return 2
                    if not again:
                        wrong.append(f"{back} {run}: the gate does not list it again")
                        print(f"INFO {back} {run}: the gate does not list it after the take-back")
                    else:
                        print(f"INFO {back} {run}: taken back, the gate lists it again")
                shutil.rmtree(tree)
    except subprocess.TimeoutExpired as exc:
        print(f"ABORT: a command overran its {COMMAND_BOUND} s bound: {exc.cmd}")
        return 2
    finally:
        shutil.rmtree(base, ignore_errors=True)
    if wrong:
        print(f"STEP_CELL_LAP FAIL {len(wrong)} of {exposed} dispositions did not settle their "
              "run: " + "; ".join(w[:220] for w in wrong))
        return 1
    print(f"STEP_CELL_LAP PASS all {exposed} dispositions settled their run "
          "(3 key shapes x infra, amend, removal) and both take-backs listed it again")
    return 0


if __name__ == "__main__":
    sys.exit(main())
