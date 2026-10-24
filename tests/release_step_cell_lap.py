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

and settles each in the four ways a session settles one:

    infra    defects.py propose infra-proven --target, review --approve, criteria.py infra
    amend    defects.py propose detector-defect --target, review --approve, criteria.py amend;
             then criteria.py unamend takes it back
    removal  defects.py update <record> --cell, propose remove-disproved, review --approve,
             defects.py remove --disproved, whose retire_cells retires the run; then
             criteria.py unretire takes the retirement back
    named    the removal of a record that already names the run: the scratch queue names it
             through its own load and save, so update --cell (check_cells) is not run and the
             removal's retire_cells is reached on every key; then criteria.py unretire

Each of the twelve runs in a scratch tree of its own: a copy of tools/*.py and of everything those
tools read or write (data/, the DRBD board and its ledger, CHANGELOG.md), so the lap writes nothing
to the live queue, proposals, reviews or ledgers. The copy's queue first stops naming the run, so
the copy's gate reads it as unaccounted for. The approvals are the scratch tree's own, written
only to drive the commands there.

    EXPOSED   in a scratch tree, before its disposition, the gate lists the run
    PASS      after each of the twelve dispositions the gate no longer lists its run, and after
              each take-back (unamend, unretire) it lists the run again
    FAIL      a command refused, the gate still lists the run after its disposition, or no
              longer lists it after the take-back

Each part of the fix has a switch (tools/criteria.py), and each switch off is that part as before
the fix, the control of one record: MXFS_RELEASE_STEP_SETTLE=0 parses a step's run as any other
(every disposition refused at the parse); MXFS_RELEASE_STEP_ANNOTATE=0 looks a step's row up as a
board criterion (infra, amend and every take-back refused by find on every key);
MXFS_RELEASE_STEP_BOARD=0 gives criteria.py the DRBD board for a command naming the drbd key (its
infra and amend refused "records no run stamped", and the take-back of each removal refused);
MXFS_RELEASE_STEP_ROUTE=0 looks a named run up and retires it on its configuration's board (the
drbd key's propose --target and update --cell refused "records no run stamped", and its named
removal leaving it listed). The lap hands its environment to every command.

Bound, derived: each command is one interpreter reading the queue (1.5 MB), the proposals and the
primary board and ledger (6 MB); a disposition is 3-5 commands and the gate twice. Measured on the
tree of 2026-10-23 with every disposition settling: all nine of the first three ways with their
copies (~10 MB each) in 15.1 s. Measured on the tree of 2026-10-24 (a 12k-line ledger, its copy
rewritten by unsettle for each of the twelve): all twelve in 26.8 s. A batch lap is bounded at 2x
that, 54 s; each command at 20 s.

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
DISPOSITIONS = ("infra", "amend", "removal", "named")
#: the command that takes a disposition back (criteria.py withdraw); infra has none
TAKE_BACK = {"amend": "unamend", "removal": "unretire", "named": "unretire"}
#: the fix's switches (tools/criteria.py), one per part
SWITCHES = ("MXFS_RELEASE_STEP_SETTLE", "MXFS_RELEASE_STEP_ANNOTATE", "MXFS_RELEASE_STEP_BOARD",
            "MXFS_RELEASE_STEP_ROUTE")
#: the record the removal disposition names the run in and removes, in the scratch tree only.
#: The lap adds it to each scratch queue itself: the live record it used to name was removed from
#: the queue, so every scratch tree, a copy of that queue, lacked it, and the lap died at name()
#: with a StopIteration before any verdict
#: (D-RELEASE-STEP-CELL-LAP-NAMES-A-REMOVED-RECORD-AND-DIES-WITHOUT-A-VERDICT).
#: The same holds for the live ledger's annotations of the lap's runs (unsettle).
#: Each part has a switch of its own, so the control of one reaches the code it is about:
#: MXFS_STEP_LAP_OWN_RECORD=0 names the live record and adds none, as before;
#: MXFS_STEP_LAP_UNSETTLE=0 keeps the live annotations in the scratch ledgers, as before.
#: OWN_RECORD=0 also keeps them, since the earlier code did neither.
RECORD = "D-RELEASE-STEP-CELL-LAP-SCRATCH-RECORD"
LIVE_RECORD = "D-RELEASE-RUN-STEP-INCIDENTS-CANNOT-BE-SETTLED"
OWN_RECORD = os.environ.get("MXFS_STEP_LAP_OWN_RECORD", "1") != "0"
UNSETTLE = OWN_RECORD and os.environ.get("MXFS_STEP_LAP_UNSETTLE", "1") != "0"
if not OWN_RECORD:
    RECORD = LIVE_RECORD
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


def copy_present(source: str, target: str) -> str:
    """shutil.copy2, except that a file gone since copytree listed its directory is left out."""
    try:
        return shutil.copy2(source, target)
    except FileNotFoundError:
        if os.path.lexists(source):
            raise
        return target


def scratch_tree(base: Path) -> Path:
    """A tree holding copies of the tools and of every file they read or write.

    data/ is live while the lap copies it: tools/defects.py and tools/criteria.py replace the
    queue, the proposals and the boards by writing <name>.json.tmp and renaming it over the file,
    so a temporary file copytree listed could be gone by the time it was copied, and the lap died
    on shutil.Error with no verdict
    (D-RELEASE-STEP-CELL-LAP-COPIES-LIVE-DATA-DIR-AND-DIES-ON-A-VANISHED-TMP-FILE). No tool reads
    a *.tmp, so they are not copied, and a file that vanishes between the listing and the copy is
    left out. MXFS_RELEASE_STEP_COPY=0 copies data/ whole, as before: the same-build control."""
    (base / "tools").mkdir(parents=True)
    for source in (ROOT / "tools").glob("*.py"):
        shutil.copy2(source, base / "tools" / source.name)
    if os.environ.get("MXFS_RELEASE_STEP_COPY", "1") == "0":
        shutil.copytree(ROOT / "data", base / "data", symlinks=True)
    else:
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


def unsettle(tree: Path, key: tuple) -> None:
    """The scratch ledgers lose every annotation of the run (an infra, detector-defect, retired_by
    or withdrawn line the live ledger holds for it), so the scratch gate lists the run whatever
    the live tree has since done with it: the live ledger settled two of the three runs after
    the lap was written, and the lap aborted that its gate did not list them. Only the scratch
    copies are rewritten; the run lines themselves are kept."""
    config, row, iso = key
    ledgers = [tree / "data" / "criteria.runs.jsonl"]
    ledgers += [(tree / board).with_name((tree / board).stem + ".runs.jsonl") for board in own_boards()]
    for ledger in ledgers:
        if not ledger.exists():
            continue
        kept = []
        for line in ledger.read_text().splitlines(keepends=True):
            if f'"{iso}"' in line:
                try:
                    item = json.loads(line)
                except ValueError:
                    item = {}
                if (item.get("kind") not in (None, "run")
                        and (item.get("config"), item.get("row"), item.get("iso")) == key):
                    continue
            kept.append(line)
        ledger.write_text("".join(kept))


def own_record(tree: Path) -> None:
    """The scratch queue gains the record the removal dispositions name and remove, through the
    queue's own load and save, so the lap depends on no record of the live queue."""
    probe = ("import sys, datetime; sys.path.insert(0, 'tools'); import defects\n"
             "data = defects.load()\n"
             "if any(r['id'] == sys.argv[1] for r in data['defects']):\n"
             "    sys.exit('the scratch queue already holds ' + sys.argv[1])\n"
             "data['defects'].append({'id': sys.argv[1], 'severity': 'minor', 'nodes': 1,\n"
             "    'config': '*/*/*', 'opened': datetime.date.today().isoformat(),\n"
             "    'summary': 'scratch record of tests/release_step_cell_lap.py: its removal'\n"
             "               ' dispositions name a release step run in it and remove it'})\n"
             "defects.save(data)\n")
    out = command(tree, ["-c", probe, RECORD])
    if out.returncode != 0:
        raise RuntimeError(f"own_record rc={out.returncode}: {(out.stdout + out.stderr).strip()[-300:]}")


def name(tree: Path, key: tuple) -> None:
    """The scratch queue's record names the run, through the queue's own load and save, as a
    record that named it before update --cell checked a named run: its removal then reaches
    retire_cells without check_cells."""
    probe = ("import sys; sys.path.insert(0, 'tools'); import defects\n"
             "config, row, iso = sys.argv[1:4]\n"
             "data = defects.load()\n"
             "record = next(r for r in data['defects'] if r['id'] == sys.argv[4])\n"
             "record.setdefault('cells', []).append({'config': config, 'row': row, 'iso': iso})\n"
             "defects.save(data)\n")
    out = command(tree, ["-c", probe] + list(key) + [RECORD])
    if out.returncode != 0:
        raise RuntimeError(f"name rc={out.returncode}: {(out.stdout + out.stderr).strip()[-300:]}")


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
        if how == "named":
            name(tree, key)
        else:
            step(tree, ["tools/defects.py", "update", RECORD, "--cell", run],
                 "defects.py update --cell")
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
    for switch in SWITCHES + ("MXFS_RELEASE_STEP_COPY", "MXFS_STEP_LAP_OWN_RECORD",
                              "MXFS_STEP_LAP_UNSETTLE"):
        print(f"INFO {switch}={os.environ.get(switch) or '(unset)'}")
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
                if UNSETTLE:
                    unsettle(tree, keys[run])
                if OWN_RECORD:
                    own_record(tree)
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
          "(3 key shapes x infra, amend, removal, named removal) and every take-back listed it "
          "again")
    return 0


if __name__ == "__main__":
    sys.exit(main())
