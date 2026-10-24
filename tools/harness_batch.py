#!/usr/bin/env python3
"""The control and fix-on batches of a defect whose reproducer is a harness, run end to end.

    tools/harness_batch.py control <record> --row R --at X --runs N (--revert DIFF | --knob V)
                           --probe P --bound S --pass RE [--fail RE] [--evidence G]...
                           [--why W] [--batch B] -- <command> [args...]
    tools/harness_batch.py verify  <record> --control BATCH --row R --at X
                           --probe P --bound S --pass RE [--fail RE] [--evidence G]...
                           -- <command> [args...]

A record leaves the queue as FIXED AND VERIFIED only with a control batch that reproduced it with
the fix taken out and a verification batch with the fix in, sized from the control's rate
(docs/release-process.md). For a defect in a harness, a tool or a script, each lap is one run of
that harness through tools/batch_lap.py, which asks the queue whether the lap may run, bounds it,
reads its verdict line and records it in the run ledger. This drives the rest:

control  declares the batch (tools/defects.py batch --kind control) with the fix's diff and its
         sha256 as the variant, takes the fix out of the tree by applying DIFF in reverse, runs the
         N laps, puts the fix back and requires every file the diff touches to hash as it did
         before, closes the batch (defects.py measure), and names every lap that did not pass in
         the record (defects.py update --cell): a control lap's failure is the defect reproducing,
         and a failure no record names is an incident. The tree is restored on any exit, a signal
         included; nothing else may use the reverted files while the laps run.
verify   declares the verification batch sized from that control (defects.py plan-verify
         --control) on the tree's build, and on the frozen candidate MXFS_CANDIDATE names (the
         only batch `defects.py verify` applies), and runs its laps, stopping at the first
         failure, which ends a verification batch for good.

DIFF is the fix as `diff -u` output with a/ and b/ prefixes (patch -p1), kept under tests/evidence
so the reviewer reads the same bytes the variant names. `{lap}` in the command is replaced by the
lap's number. Every run of the harness is bounded by --bound, which the caller derives from what
the harness takes; an overrun is a FAIL.

--knob V is a control with no diff: the fix's own switch is turned off in the caller's
environment (a module argument through MXFS_EXTRA_MODARGS, a row's MXFS_TEST_ENV), V names that
as the batch's variant, and nothing in the tree is taken out or put back. --batch B continues a
control already declared with this record, row, configuration and variant, for its laps left.

A control records every file a candidate frozen at that moment would hold (tools/release_candidate.py
frozen_paths, with the stamp its manifest keeps: sha256, inode, size, mtime, ctime), under
tests/evidence/controls/<batch>.inputs.<phase>.json: `before` the fix is taken out, `during` the laps,
`after` it is put back (a --knob control: before and after). It prints which files differ between the
phases, so the control's tree is measured, not asserted. A control run in place just before a freeze
is then the candidate's source with only the fix reverted when `proof` finds that the files differing
during the laps are exactly the diff's, and that the attempt's frozen file list holds the `after`
content of every file with only the diff's files touched since:

    tools/harness_batch.py proof <control batch> <tests/evidence/candidates/<attempt>.files.json>

--board makes each lap a board row instead: `MXFS_BATCH=<batch> ./run.sh <at> <row>`, which
records the lap itself (run.sh enforces the row's budget from tests/suite/manifest, so --bound and
--pass are not used and no command follows `--`). The rig group comes from the caller's
environment (MXFS_GROUP, MXFS_MARKER, MXFS_NODE_LIST), and the lap's outcome is read from the
ledger line run.sh wrote for the batch. --rebuild CMD runs CMD (through the shell, in the tree)
after the fix is taken out and again after it is put back, for a fix in a compiled tool: the laps
run the binary built from the reverted source, and the tree's binary is rebuilt from the restored
one; a rebuild that fails stops the control.

Exit status: 0 when every lap ran (a control whose laps failed is a control that worked), 1 when a
verification lap failed, 2 when something refused, 3 when the tree could not be restored.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import criteria  # noqa: E402
import release_candidate  # noqa: E402

DEFECTS = [sys.executable, str(ROOT / "tools" / "defects.py")]
LAP = [sys.executable, str(ROOT / "tools" / "batch_lap.py")]
CONTROLS = ROOT / "tests" / "evidence" / "controls"
BATCH_ID = re.compile(r"\bb\d{8}-[0-9a-f]{6}\b")
LAP_LINE = re.compile(r"^(PASS|FAIL|INCOMPLETE) (\S+:\S+:\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) ")


def run(cmd: list, check: bool = True) -> subprocess.CompletedProcess:
    out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    sys.stdout.write(out.stdout + out.stderr)
    if check and out.returncode != 0:
        sys.exit(f"harness_batch: {' '.join(cmd[:4])} ... refused (rc={out.returncode})")
    return out


def tree_build() -> str:
    out = subprocess.run(["modinfo", "-F", "srcversion", str(ROOT / "mxfs.ko")],
                         capture_output=True, text=True)
    build = out.stdout.strip()
    if out.returncode != 0 or not build:
        sys.exit("harness_batch: no srcversion in mxfs.ko; a lap must carry its build")
    return build


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else "absent"


def diff_files(diff: Path) -> list:
    """The tree paths a -p1 diff changes."""
    files = []
    for line in diff.read_text().splitlines():
        if line.startswith("+++ "):
            name = line[4:].split("\t")[0].strip()
            if name.startswith("b/"):
                files.append(ROOT / name[2:])
    if not files:
        sys.exit(f"harness_batch: {diff} names no file (+++ b/<path>)")
    return files


def snapshot_inputs(bid: str, phase: str) -> dict:
    """Every file a candidate frozen now would hold, with its manifest stamp, kept as evidence."""
    stamps = {}
    for rel in release_candidate.frozen_paths():
        try:
            stamps[rel] = release_candidate.stamp_of(rel)
        except OSError:
            stamps[rel] = ["absent"]
    path = CONTROLS / f"{bid}.inputs.{phase}.json"
    path.write_text(json.dumps(stamps, indent=1, sort_keys=True) + "\n")
    print(f"inputs {phase}: {len(stamps)} files, {path.relative_to(ROOT)}", flush=True)
    return stamps


#: A stamp's permission bits (its sixth field, when both stamps have one) count as its content: a
#: fix that changes only a mode could not be proven when proof compared content hashes alone
#: (D-HARNESS-BATCH-PROOF-COMPARES-CONTENT-ONLY-SO-A-MODE-ONLY-FIX-CANNOT-BE-PROVEN).
#: MXFS_PROOF_MODE=0 compares the hashes alone, as before: the control.
PROOF_MODE = os.environ.get("MXFS_PROOF_MODE", "1") != "0"


def differs(a: list, b: list) -> bool:
    """Whether two stamps of one file differ in content: its hash, or its mode."""
    if a[0] != b[0]:
        return True
    return PROOF_MODE and len(a) > 5 and len(b) > 5 and a[5] != b[5]


def compare_inputs(first: dict, second: dict) -> dict:
    """What differs between two stamp maps: content (with the mode), inode change time alone,
    added, gone."""
    both = first.keys() & second.keys()
    return {
        "content": sorted(p for p in both if differs(first[p], second[p])),
        "touched": sorted(p for p in both
                          if not differs(first[p], second[p]) and first[p][4:5] != second[p][4:5]),
        "added": sorted(second.keys() - first.keys()),
        "gone": sorted(first.keys() - second.keys()),
    }


def report_inputs(label: str, found: dict) -> None:
    parts = [f"{kind}={len(paths)} {' '.join(paths[:12])}".rstrip()
             for kind, paths in found.items()]
    print(f"inputs {label}: {'; '.join(parts)}", flush=True)


def lap_args(args, bid: str) -> list:
    cmd = LAP + ["--batch", bid, "--at", args.at, "--row", args.row,
                 "--bound", str(args.bound), "--pass", args.passed]
    if args.failed:
        cmd += ["--fail", args.failed]
    for ev in args.evidence:
        cmd += ["--evidence", ev]
    for pattern in args.stall:
        cmd += ["--stall", pattern]
    return cmd + ["--"]


def ledger_reread(board) -> None:
    """Drop this process's copy of a board's ledger, so the next read sees what other processes
    appended since. tools/criteria.py reads a ledger once per process; run.sh appends to it in
    another, so a lap's run was read from the copy taken before the lap and was not found: the
    control b20261022-545d6a stopped after its first lap with 'recorded no run of the batch'
    though run.sh had recorded it (D-TOOLS-HARNESS-BATCH-PY-CONTROL-STOPPED-A-CONTROL-BATCH).
    MXFS_HARNESS_BATCH_REREAD=0 keeps the copy, as before: the same-build control."""
    if os.environ.get("MXFS_HARNESS_BATCH_REREAD", "1") != "0":
        criteria.ledger_cache.pop(str(Path(board).resolve()), None)


def stamps_before(board, config: str, row: str) -> set:
    """The stamps of the row's runs at the configuration, read before a lap."""
    ledger_reread(board)
    return {str(r.get("iso")) for r in criteria.ledger_runs(board, config, row)}


def lap_runs(board, config: str, row: str, bid: str, before: set) -> list:
    """The batch's runs of the row that were not there before the lap."""
    ledger_reread(board)
    return [r for r in criteria.ledger_runs(board, config, row)
            if r.get("batch") == bid and str(r.get("iso")) not in before]


def board_lap(args, bid: str, lap: int, count: int) -> tuple | None:
    """One lap as a board row; (outcome, CONFIG:ROW:ISO) from the ledger line run.sh wrote."""
    config = criteria.parse_at(args.at)
    board = criteria.board_for(config)
    before = stamps_before(board, config, args.row)
    env = dict(os.environ, MXFS_BATCH=bid)
    out = subprocess.run(["./run.sh", args.at, args.row], cwd=ROOT, env=env,
                         capture_output=True, text=True)
    runs = lap_runs(board, config, args.row, bid, before)
    row_line = next((l.strip() for l in out.stdout.splitlines()
                     if re.match(rf"^\s+\S+\s+{re.escape(args.row)}\b", l)), "")
    if not runs:
        tail = (out.stdout + out.stderr).strip()[-400:]
        print(f"lap {lap}/{count}: run.sh rc={out.returncode} recorded no run of the batch: {tail}",
              flush=True)
        return None
    run = runs[-1]
    print(f"lap {lap}/{count}: {run.get('outcome')} {config}:{args.row}:{run.get('iso')} "
          f"{run.get('measured', '')} -- {row_line[:300]}", flush=True)
    return (str(run.get("outcome")), f"{config}:{args.row}:{run.get('iso')}")


def rebuild(args, when: str) -> None:
    if not args.rebuild:
        return
    out = subprocess.run(args.rebuild, shell=True, cwd=ROOT, capture_output=True, text=True)
    print(f"rebuild ({when}): rc={out.returncode} {(out.stdout + out.stderr).strip()[-300:]}",
          flush=True)
    if out.returncode != 0:
        raise RuntimeError(f"the rebuild {when} failed (rc={out.returncode})")


def run_laps(args, bid: str, count: int, stop_on_fail: bool) -> list:
    """[(outcome, CONFIG:ROW:ISO)] of each lap, in order."""
    results = []
    for lap in range(1, count + 1):
        if args.board:
            result = board_lap(args, bid, lap, count)
            if result is None:
                print("harness_batch: the lap recorded nothing (refused?); stopping", flush=True)
                break
            results.append(result)
            if stop_on_fail and result[0] == "FAIL":
                break
            continue
        command = [part.replace("{lap}", str(lap)) for part in args.command]
        out = subprocess.run(lap_args(args, bid) + command, cwd=ROOT, capture_output=True,
                             text=True)
        line = next((l for l in out.stdout.splitlines() if LAP_LINE.match(l)), "")
        print(f"lap {lap}/{count}: {line or (out.stdout + out.stderr).strip()[-400:]}", flush=True)
        match = LAP_LINE.match(line)
        if not match:
            print("harness_batch: the lap recorded nothing (refused?); stopping", flush=True)
            break
        results.append((match.group(1), match.group(2)))
        if stop_on_fail and match.group(1) == "FAIL":
            break
    return results


def find_batch(bid: str) -> tuple:
    """(record id, batch) of a declared batch."""
    queue = json.loads((ROOT / "data" / "defects.json").read_text())["defects"]
    found = [(e["id"], b) for e in queue for b in e.get("batches") or [] if b.get("id") == bid]
    if not found:
        sys.exit(f"harness_batch: no batch {bid}")
    return found[0]


def resume_runs(batch: dict) -> int:
    """The laps a declared control has left, counted as check_batch_lap counts them: an INFRA
    lap uses up no place in the plan, so a lap is run in its stead. Counting every recorded lap,
    the resume ran none in place of an INFRA lap, and the batch could not be filled
    (D-MEASURE-REFUSES-A-BATCH-WHOSE-SETTLED-LAP-CHECK-BATCH-LAP-COUNTED-AS-RUN).
    MXFS_RESUME_PLAN_LAPS=0 counts every recorded lap, as before: the control of this part."""
    import defects  # noqa: E402
    if os.environ.get("MXFS_RESUME_PLAN_LAPS", "1") == "0":
        used = defects.batch_runs(batch)
    else:
        used = defects.plan_laps(batch)
    return max(int(batch["planned"]) - len(used), 0)


def cmd_control(args) -> int:
    if bool(args.revert) == bool(args.knob):
        sys.exit("harness_batch: a control takes the fix out one way: --revert DIFF or --knob TEXT")
    diff, files, before = None, [], {}
    if args.knob:
        # the fix's own switch turned off by the caller's environment (a module argument in
        # MXFS_EXTRA_MODARGS, a row's MXFS_TEST_ENV); the tree is not touched
        variant = args.knob
    else:
        # not resolved: tests/evidence is a link out of the tree, and the variant names the
        # tree path
        diff = ROOT / args.revert
        if not diff.is_file():
            sys.exit(f"harness_batch: no diff at {args.revert}")
        files = diff_files(diff)
        before = {f: sha256(f) for f in files}
        dry = subprocess.run(["patch", "-p1", "-R", "--dry-run", "-i", str(diff)], cwd=ROOT,
                             capture_output=True, text=True)
        if dry.returncode != 0:
            sys.exit(f"harness_batch: the fix does not come out cleanly:\n{dry.stdout}{dry.stderr}")
        variant = f"fix reverted: {diff.relative_to(ROOT)} sha256={sha256(diff)}"
    if args.batch:
        # the rest of a control already declared: same record, row, configuration, variant
        owner, batch = find_batch(args.batch)
        wrong = [k for k, want in (("record", args.record), ("kind", "control"),
                                   ("state", "open"), ("row", args.row), ("variant", variant))
                 if (owner if k == "record" else batch.get(k)) != want]
        if wrong or batch.get("config") != criteria.parse_at(args.at):
            sys.exit(f"harness_batch: {args.batch} is not this control ({', '.join(wrong) or 'config'})")
        bid = args.batch
        args.runs = resume_runs(batch)
    else:
        declared = run(DEFECTS + ["batch", args.record, "--kind", "control", "--row", args.row,
                                  "--at", args.at, "--build", tree_build(),
                                  "--runs", str(args.runs), "--probe", args.probe,
                                  "--variant", variant,
                                  "--why", args.why or "the fix taken out: the defect must reproduce"])
        match = BATCH_ID.search(declared.stdout)
        if not match:
            sys.exit("harness_batch: no batch id in the declaration above")
        bid = match.group(0)

    call = f"{bid}.{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
    inputs_before = snapshot_inputs(call, "before")
    restored = False

    def restore(*caught) -> None:
        nonlocal restored
        if restored:
            return
        restored = True
        if diff is None:
            if caught:
                sys.exit(2)
            return
        put = subprocess.run(["patch", "-p1", "--no-backup-if-mismatch", "-i", str(diff)],
                             cwd=ROOT, capture_output=True, text=True)
        bad = [str(f.relative_to(ROOT)) for f in files if sha256(f) != before[f]]
        if put.returncode != 0 or bad:
            print(f"harness_batch: RESTORE FAILED (patch rc={put.returncode}; differ: {bad}); "
                  f"apply {diff.relative_to(ROOT)} by hand\n{put.stdout}{put.stderr}", flush=True)
            sys.exit(3)
        print(f"restored: {', '.join(str(f.relative_to(ROOT)) for f in files)} hash as before",
              flush=True)
        try:
            rebuild(args, "with the fix back in")
        except RuntimeError as exc:
            print(f"harness_batch: RESTORE INCOMPLETE: {exc}; rebuild by hand", flush=True)
            sys.exit(3)
        if caught:
            sys.exit(2)

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, restore)
    if diff is not None:
        took = subprocess.run(["patch", "-p1", "-R", "--no-backup-if-mismatch", "-i", str(diff)],
                              cwd=ROOT, capture_output=True, text=True)
        if took.returncode != 0:
            restored = True
            sys.exit(f"harness_batch: taking the fix out failed:\n{took.stdout}{took.stderr}")
    print(f"--- control {bid}: the fix is out ({variant}) ---", flush=True)
    try:
        rebuild(args, "with the fix out")
        if diff is not None:
            report_inputs("before -> during",
                          compare_inputs(inputs_before, snapshot_inputs(call, "during")))
        results = run_laps(args, bid, args.runs, stop_on_fail=False)
    except RuntimeError as exc:
        print(f"harness_batch: {exc}; no lap ran", flush=True)
        results = []
    finally:
        restore()
    report_inputs("before -> after", compare_inputs(inputs_before, snapshot_inputs(call, "after")))
    run(DEFECTS + ["measure", args.record, "--batch", bid], check=False)
    # every lap of the batch, a continued one's earlier laps too, from the ledger
    config = criteria.parse_at(args.at)
    criteria.ledger_cache.clear()
    laps = [r for r in criteria.ledger_runs(criteria.board_for(config), config, args.row)
            if r.get("batch") == bid]
    for lap in laps:
        if lap.get("outcome") != "PASS":
            run(DEFECTS + ["update", args.record, "--cell",
                           f"{config}:{args.row}:{lap.get('iso')}"], check=False)
    fails = sum(1 for r in laps if r.get("outcome") == "FAIL")
    print(f"control {bid}: {fails} of {len(laps)} laps failed with the fix out "
          f"({len(results)} run by this call)")
    return 0


def cmd_verify(args) -> int:
    # A verification batch is applied (defects.py verify) only for the frozen candidate its laps
    # ran on; batch_lap.py and run.sh stamp each lap with MXFS_CANDIDATE, and the batch must name
    # the same candidate, or no lap of it counts and the review refuses it.
    candidate = os.environ.get("MXFS_CANDIDATE", "")
    planned = run(DEFECTS + ["plan-verify", args.record, "--row", args.row, "--at", args.at,
                             "--probe", args.probe, "--build", tree_build(),
                             "--control", args.control]
                  + (["--candidate", candidate] if candidate else []))
    match = BATCH_ID.search(planned.stdout)
    count = re.search(r", (\d+) clean laps", planned.stdout)
    if not match or not count:
        sys.exit("harness_batch: no batch id or lap count in the declaration above")
    bid = match.group(0)
    results = run_laps(args, bid, int(count.group(1)), stop_on_fail=True)
    fails = [cell for o, cell in results if o == "FAIL"]
    print(f"verify {bid}: {sum(1 for o, _ in results if o == 'PASS')} PASS, {len(fails)} FAIL "
          f"of {count.group(1)} planned")
    return 1 if fails else 0


def cmd_proof(argv: list) -> int:
    """Whether a control ran on an attempt's frozen source with only its fix taken out."""
    parser = argparse.ArgumentParser(prog="harness_batch.py proof")
    parser.add_argument("batch", help="the control batch")
    parser.add_argument("files", help="the attempt's frozen file list (<attempt>.files.json)")
    parser.add_argument("--built", action="append", default=[],
                        help="a file the control's --rebuild wrote (repeat)")
    args = parser.parse_args(argv)
    _, batch = find_batch(args.batch)
    manifest = json.loads(Path(args.files).read_text())
    named = re.search(r"fix reverted: (\S+\.diff)", str(batch.get("variant", "")))
    fix = sorted(str(p.relative_to(ROOT)) for p in diff_files(ROOT / named.group(1))) \
        if named else []
    calls = sorted({p.name.split(".inputs.")[0]
                    for p in CONTROLS.glob(f"{args.batch}.*.inputs.before.json")})
    if not calls:
        print(f"proof {args.batch}: no inputs were recorded for this control")
        return 2
    held = True
    for call in calls:
        phases = {}
        for phase in ("before", "during", "after"):
            path = CONTROLS / f"{call}.inputs.{phase}.json"
            phases[phase] = json.loads(path.read_text()) if path.exists() else None
        checks = []
        if phases["after"] is None:
            checks.append((False, "the call recorded no `after`: it did not end"))
        else:
            frozen = compare_inputs(phases["after"], manifest)
            checks.append((not (frozen["content"] or frozen["added"] or frozen["gone"]),
                           f"the attempt froze every file as it was after the restore "
                           f"(content {frozen['content'][:8]}, added {frozen['added'][:8]}, "
                           f"gone {frozen['gone'][:8]})"))
            checks.append((not frozen["touched"],
                           f"nothing was touched between the restore and the freeze "
                           f"({frozen['touched'][:8]})"))
            back = compare_inputs(phases["before"], phases["after"])
            checks.append((not (back["content"] or back["added"] or back["gone"]),
                           f"the restore put back every file (content {back['content'][:8]})"))
        if fix:
            if phases["during"] is None:
                checks.append((False, "the call recorded no `during`"))
            else:
                out = compare_inputs(phases["before"], phases["during"])
                extra = sorted(set(out["content"]) - set(fix) - set(args.built))
                checks.append((set(fix) <= set(out["content"]) and not extra
                               and not (out["added"] or out["gone"]),
                               f"during the laps the fix's files differed {fix} and nothing "
                               f"else ({extra[:8]}, added {out['added'][:8]}, "
                               f"gone {out['gone'][:8]})"))
        for ok, text in checks:
            held = held and ok
            print(f"{'HOLDS' if ok else 'FAILS'} {call}: {text}")
    print(f"proof {args.batch} against {args.files}: {'HOLDS' if held else 'FAILS'}")
    return 0 if held else 1


def main() -> int:
    if sys.argv[1:2] == ["proof"]:
        return cmd_proof(sys.argv[2:])
    # The harness command is everything after `--`, split off before parsing: a REMAINDER
    # positional after the record would swallow every option that follows it.
    argv = sys.argv[1:]
    cut = argv.index("--") if "--" in argv else len(argv)
    argv, command = argv[:cut], argv[cut + 1:]
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="mode", required=True)
    for mode in ("control", "verify"):
        p = sub.add_parser(mode)
        p.add_argument("record")
        p.add_argument("--row", required=True, help="the batch's row, e.g. lap:<harness>")
        p.add_argument("--at", required=True, help="the batch's configuration")
        p.add_argument("--probe", default="",
                       help="the line that shows a lap reached the trigger (a kernel-log pattern "
                            "for --board)")
        p.add_argument("--bound", type=int, default=0, help="seconds per lap, derived")
        p.add_argument("--pass", dest="passed", default="", help="regex of the PASS line")
        p.add_argument("--fail", dest="failed", default="", help="regex of the FAIL line")
        p.add_argument("--evidence", action="append", default=[])
        p.add_argument("--stall", action="append", default=[],
                       help="a regex whose one capture group is an operation's milliseconds, "
                            "passed to tools/batch_lap.py (repeat)")
        p.add_argument("--board", action="store_true",
                       help="each lap is the board row: MXFS_BATCH=<batch> ./run.sh <at> <row>")
        p.add_argument("--rebuild", default="",
                       help="shell command rebuilding what the diff's files compile into")
        if mode == "control":
            p.add_argument("--runs", type=int, default=0,
                           help="laps to declare (with --batch: the declared batch's rest)")
            p.add_argument("--batch", default="", help="continue this declared control batch")
            p.add_argument("--revert", default="", help="the fix as a -p1 diff")
            p.add_argument("--knob", default="",
                           help="the variant, when the caller's environment turns the fix's "
                                "own switch off (no diff)")
            p.add_argument("--why", default="")
        else:
            p.add_argument("--control", required=True, help="the closed control batch")
    args = parser.parse_args(argv)
    args.command = command
    if args.board:
        if args.command:
            sys.exit("harness_batch: --board runs the row itself; nothing follows --")
    elif not args.command:
        sys.exit("harness_batch: name the harness command after --")
    elif not (args.probe and args.bound > 0 and args.passed):
        sys.exit("harness_batch: a harness lap needs --probe, --bound and --pass")
    return cmd_control(args) if args.mode == "control" else cmd_verify(args)


if __name__ == "__main__":
    sys.exit(main())
