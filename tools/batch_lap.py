#!/usr/bin/env python3
"""One lap of a declared batch whose row is a harness, not a board row.

    tools/batch_lap.py --batch <id> --at <configuration> --row <row> --bound <s>
                       --pass <regex> [--fail <regex>] [--evidence <dir or glob>]...
                       [--stall <regex>]... [--build-from <mxfs.ko>] -- <command> [args...]

A batch (tools/defects.py batch / plan-verify) counts laps from the run ledger: every lap is a run
of the batch's row at its configuration, keyed (configuration, row, iso), and run.sh records one
for each board row it runs. A defect found in a harness that is not a board row -- an entry of the
capture fault gate, a host-only check -- had no way to record a lap, so its fix could never be
measured against a control and verified, and the record could never leave the queue. This runs
the harness once and records the lap the way run.sh records a board row's:

  - it asks the queue first (`defects.py batch-check`), which refuses a lap outside an open,
    declared batch with this row, configuration and candidate, or past its planned count, and
    names the batch's probe and variant;
  - the harness runs under `--bound` seconds, which the caller derives from what the harness
    takes (RULE: TIMEOUTS ARE PERFORMANCE ASSERTIONS, NOT SAFETY NETS); an overrun is a FAIL;
  - the outcome is read from the harness's own verdict line: PASS when a line matches `--pass`,
    FAIL when one matches `--fail` or the bound ran out, INCOMPLETE when neither (it measured
    nothing anyone can name);
  - exposure: the batch's probe counted in the lap's own output and in every file under each
    `--evidence` path the lap wrote, appended to `measured` as `exposure=<n>` (tools/defects.py
    exposed() reads it). A harness's trigger shows in its own log, not in a kernel's;
  - the worst operation stall, read from the same texts: every `max_stall_ms=<ms>` the harness
    prints and every match of each `--stall` pattern (one capture group, an operation's
    milliseconds), appended to `measured` as `max_stall_ms=<ms>` and graded as a board row's is
    (tools/criteria.py stall_over_limit): a PASS whose stall is over the policy's stall_limit_s is
    a FAIL. A lap with no stall graded none, so an operation stalled 31 s inside a lap that then
    printed its PASS line recorded a PASS
    (D-BATCH-LAP-RECORDS-NO-STALL-SO-A-HARNESS-LAP-OVER-THE-STALL-LIMIT-GRADES-PASS).
    MXFS_BATCH_LAP_STALL=0 measures and grades nothing, as before: the same-build control;
  - the run carries the build (`--build-from`, the tree's mxfs.ko by default), the candidate
    (MXFS_CANDIDATE), the batch, and a variant as run.sh's does: the batch's as `batch:<variant>`,
    and the lap's own (env_variant), so a verification lap on a pair prepped with a module argument
    never counts for the candidate as it ships
    (D-BATCH-LAP-RECORDS-NO-VARIANT-FOR-MODULE-ARGUMENTS-SO-A-VARIANT-LAP-CAN-COUNT).
    MXFS_BATCH_LAP_ENV_VARIANT=0 records only the batch's, as before: the same-build control;
  - it is appended, under the board's lock, to the ledger of the board that keeps the batch's
    configuration (tools/criteria.py board_for and append_ledger, as tools/release_run.py records
    its steps), which is where tools/defects.py reads the batch's laps; the lap's log is its
    evidence;
  - the lab VMs the lap uses, those MXFS_NODE_LIST names and the nodes of the rig group
    MXFS_GROUP, are held for tools/vm_pool.sh while the lap runs, as tests/lib/runlock.sh
    vmhold_take holds them. Every run.sh leaves a reaper behind (vm_pool.sh release --after
    <its pid>) that shuts its nodes off once they have gone unheld for 600 s after it exits, and a
    lane that formed its pair with run.sh and then ran harness laps lost both nodes under a lap
    that way (D-BATCH-LAP-HOLDS-NO-VM-SO-RUN-SH-REAPER-POWERS-ITS-NODES-OFF-MID-LAP).
    MXFS_BATCH_LAP_HOLD=0 holds nothing, as before: the same-build control.

Exit status: 0 PASS, 1 FAIL, 2 INCOMPLETE or refused.
"""
from __future__ import annotations

import argparse
import ctypes
import fcntl
import glob
import json
import os
import re
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import criteria  # noqa: E402


def stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def batch_check(args) -> dict:
    """The queue's answer for this lap: PROBE, VARIANT, LEAVES_CLUSTER; exit when it refuses."""
    cmd = ["python3", str(ROOT / "tools" / "defects.py"), "batch-check", args.batch,
           "--row", args.row, "--at", args.at]
    if os.environ.get("MXFS_CANDIDATE"):
        cmd += ["--candidate", os.environ["MXFS_CANDIDATE"]]
    out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stdout + out.stderr, end="")
        sys.exit("batch_lap: the queue refused this lap (above)")
    answer = {}
    for line in out.stdout.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            answer[key.strip()] = value
    return answer


def lap_vms() -> list:
    """The lab VMs the caller says the lap uses: MXFS_NODE_LIST, and the rig group MXFS_GROUP's
    nodes (tools/mxfs_lab.sh group)."""
    vms = [vm for vm in os.environ.get("MXFS_NODE_LIST", "").split(",") if vm]
    group = os.environ.get("MXFS_GROUP", "")
    if group:
        out = subprocess.run([str(ROOT / "tools" / "mxfs_lab.sh"), "group", group],
                             capture_output=True, text=True, timeout=30)
        if out.returncode != 0:
            sys.exit(f"batch_lap: no rig group {group!r} (tools/mxfs_lab.sh group): {out.stderr.strip()}")
        vms += out.stdout.split()
    return sorted(set(vms))


def hold_vms(vms: list, what: str) -> list:
    """A shared flock on each VM's /tmp/mxfs_vmhold.<vm>.lock, kept until this process exits: the
    hold tools/vm_pool.sh reads, as tests/lib/runlock.sh vmhold_take takes it."""
    handles = []
    for vm in vms:
        handle = open(f"/tmp/mxfs_vmhold.{vm}.lock", "a")
        fcntl.flock(handle.fileno(), fcntl.LOCK_SH)
        handle.write(f"{os.getpid()} {stamp()} {what}\n")
        handle.flush()
        handles.append(handle)
    return handles


def build_of(ko: str) -> str:
    out = subprocess.run(["modinfo", "-F", "srcversion", ko], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else ""


def written_since(paths: list, t0: float) -> list:
    """Every regular file under the given dirs or globs modified since the lap began."""
    candidates = []
    for pattern in paths:
        for top in glob.glob(str(ROOT / pattern)):
            if os.path.isfile(top):
                candidates.append(top)
            for base, dirs, names in os.walk(top):
                candidates += [os.path.join(base, name) for name in names]
    found = []
    for path in candidates:
        try:
            if os.path.getmtime(path) >= t0:
                found.append(path)
        except OSError:
            continue
    return sorted(set(found))


def count_probe(probe: str, texts: list) -> int:
    pattern = re.compile(probe)
    return sum(1 for text in texts for line in text.splitlines() if pattern.search(line))


def lap_log(logdir: Path) -> tuple:
    """The lap's log, created for this lap alone: (path, handle).

    Named by the second the lap starts and a random tag, and created exclusively, so two laps
    that start in one second write two logs. Named by the second alone and opened with "w", the
    second lap truncated the first one's log, and that lap's PASS and exposure lines survived
    nowhere but its ledger row
    (D-BATCH-LAP-LOG-NAMED-BY-THE-SECOND-SO-SUB-SECOND-LAPS-OVERWRITE-EACH-OTHER)."""
    while True:
        log = logdir / (f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
                        f"-{uuid.uuid4().hex[:8]}.log")
        try:
            return log, log.open("x")
        except FileExistsError:
            continue


def verdict(rc: int, text: str, passed: str, failed: str, bound: int) -> tuple:
    """(outcome, reason) from the harness's own verdict line, or FAIL when it overran its bound."""
    pass_line = next((l for l in text.splitlines() if re.search(passed, l)), "")
    fail_line = next((l for l in text.splitlines() if failed and re.search(failed, l)), "")
    if rc == 124:
        return "FAIL", f"elapsed>{bound}s: the harness overran its bound"
    if fail_line:
        return "FAIL", fail_line.strip()
    if pass_line:
        return "PASS", pass_line.strip()
    return "INCOMPLETE", f"no verdict line (rc={rc}): {text.strip().splitlines()[-1][:300]}"


#: Seconds a timed-out lap's processes get after SIGTERM, and again after SIGKILL, to be gone.
KILL_GRACE_S = 5

#: prctl(2): make the caller the reaper of its orphaned descendants (<linux/prctl.h>).
PR_SET_CHILD_SUBREAPER = 36


def become_subreaper() -> None:
    """Make every orphaned descendant of this process its child rather than init's, so a process
    the lap started that outlives its parent (a self-daemonising helper, or what a killed shell
    left behind) is still found by its parent pid."""
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        err = ctypes.get_errno()
        raise OSError(err, f"prctl(PR_SET_CHILD_SUBREAPER): {os.strerror(err)}")


def proc_table() -> dict:
    """pid -> (ppid, session, state) of every process, from /proc/<pid>/stat. Never cmdline, which
    takes the process's mmap_lock, so one task wedged holding its own makes the read hang for good
    (RULE: NEVER WEDGE THE LAB HOST)."""
    table = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/stat") as stat:
                text = stat.read()
        except OSError:
            continue
        # the command name is in parentheses and may hold spaces or parentheses itself
        fields = text[text.rfind(")") + 2:].split()
        table[int(name)] = (int(fields[1]), int(fields[3]), fields[0])
    return table


def lap_processes(leader: int) -> dict:
    """pid -> state of every process the lap started that is still in the process table: the
    lap command's descendants by parent pid, every orphan reparented to this subreaper, and every
    member of the session the command leads."""
    table = proc_table()
    me = os.getpid()
    children = {}
    for pid, (ppid, _, _) in table.items():
        children.setdefault(ppid, []).append(pid)
    found = set()
    todo = [leader] + children.get(me, [])
    while todo:
        pid = todo.pop()
        if pid in found or pid not in table or pid == me:
            continue
        found.add(pid)
        todo += children.get(pid, [])
    found |= {pid for pid, (_, sid, _) in table.items() if sid == leader and pid != me}
    return {pid: table[pid][2] for pid in found}


def reap(proc, lap: dict) -> None:
    """Collect the exit of the lap's command and of every orphan reparented to this process."""
    proc.poll()
    for pid, state in lap.items():
        if state == "Z" and pid != proc.pid:
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass


def run_bounded(command: list, cwd, handle, bound: int) -> int:
    """Run the lap's command for at most `bound` seconds; 124 on an overrun, as timeout(1) returns.

    subprocess.run(timeout=) ends only its direct child, so a harness's own children went on
    running and writing into the lap's log, and into the evidence the lap is graded from, after
    the lap had been recorded (D-BATCH-LAP-TIMEOUT-KILLS-ONLY-THE-DIRECT-CHILD-SO-THE-HARNESS-
    WRITES-ON). Ending the lap's process group was not enough either: GNU timeout, which the
    capture gate runs every entry under, puts itself and its child in a group of their own, and
    setsid or a self-daemonising helper leaves it too. This process is now a subreaper, the lap
    runs in a session of its own, and an overrun signals every process the lap started (its
    descendants by parent pid, the orphans reparented here, the members of its session), SIGTERM
    and then SIGKILL, and waits until none of them is left before the lap is recorded.
    MXFS_BATCH_LAP_KILLTREE=0 ends only the direct child, as before: the same-build control."""
    if os.environ.get("MXFS_BATCH_LAP_KILLTREE", "1") == "0":
        try:
            return subprocess.run(command, cwd=cwd, stdout=handle, stderr=subprocess.STDOUT,
                                  timeout=bound).returncode
        except subprocess.TimeoutExpired:
            return 124
    become_subreaper()
    proc = subprocess.Popen(command, cwd=cwd, stdout=handle, stderr=subprocess.STDOUT,
                            start_new_session=True)
    try:
        return proc.wait(timeout=bound)
    except subprocess.TimeoutExpired:
        pass
    leader = proc.pid
    lap = lap_processes(leader)
    started = len(lap)
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in lap:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + KILL_GRACE_S
        while lap and time.monotonic() < deadline:
            reap(proc, lap)
            time.sleep(0.1)
            lap = lap_processes(leader)
        if not lap:
            break
    reap(proc, lap)
    proc.wait()
    lap = lap_processes(leader)
    left = ("gone" if not lap else "STILL ALIVE after SIGKILL: " +
            " ".join(f"{pid}({state})" for pid, state in sorted(lap.items())))
    handle.write(f"=== the lap overran its bound of {bound}s: the {started} process(es) it had "
                 f"started were ended ({left}) ===\n")
    handle.flush()
    return 124


#: The stall line every harness may print, read whatever `--stall` patterns a lap declares.
STALL_LINE = r"\bmax_stall_ms=(\d+)"


def stall_graded(outcome: str, reason: str, measured: str, texts: list,
                 patterns: list) -> tuple:
    """(outcome, reason, measured) with the lap's worst operation stall recorded and graded the
    way tools/criteria.py grades a board row's: over the policy's stall_limit_s, a PASS is a FAIL."""
    if os.environ.get("MXFS_BATCH_LAP_STALL", "1") == "0":
        return outcome, reason, measured
    worst = -1
    for pattern in [STALL_LINE] + list(patterns):
        for text in texts:
            for match in re.finditer(pattern, text):
                worst = max(worst, int(match.group(1)))
    if worst < 0:
        return outcome, reason, measured
    measured += f" max_stall_ms={worst}"
    stall = criteria.stall_over_limit(measured)
    if stall and outcome == "PASS":
        limit = int(criteria.policy().get("stall_limit_s", 30))
        outcome = "FAIL"
        reason = (f"operation stall {stall} ms is over the {limit} s limit "
                  f"(data/release_policy.json stall_limit_s): a stability defect; {reason}")
    return outcome, reason, measured


def fresh_iso(board: Path, config: str, row: str) -> str:
    """A stamp no run of this row at this configuration already carries."""
    taken = {str(r.get("iso", "")) for r in criteria.ledger_runs(board, config, row)}
    iso = stamp()
    while iso in taken:
        time.sleep(0.2)
        iso = stamp()
    return iso


#: what run.sh records as a VARIANT from its environment (run.sh, "A VARIANT is a run that changes
#: what is measured"); a lap runs its harness in the same environment, so the same names make it one
VARIANT_ENV = ("MXFS_EXTRA_MODARGS", "MXFS_RETIRE_CONTRACT", "MXFS_TEST_ENV", "MXFS_RIG_BUDGETS",
               "MXFS_STRACE_RANK", "MXFS_MPATH_TMO")


def env_variant() -> list[str]:
    """The lap's own variant, as run.sh derives a row's: each VARIANT_ENV name set in the lap's
    environment, RULE0_CALIBRATE=1 and a positive MXFS_SETTLE_MS, and the module arguments the
    pair was prepped with when the marker the lap's environment names (MXFS_MARKER, else
    MXFS_GROUP's) recorded any: a pair loaded with a non-default argument is not the candidate as it
    ships, whoever runs the lap on it. MXFS_BATCH_LAP_ENV_VARIANT=0 records none of these, as
    before: the same-build control."""
    if os.environ.get("MXFS_BATCH_LAP_ENV_VARIANT", "1") == "0":
        return []
    parts = [f"{name}={os.environ[name]}" for name in VARIANT_ENV if os.environ.get(name)]
    if os.environ.get("RULE0_CALIBRATE", "0") == "1":
        parts.append("RULE0_CALIBRATE=1")
    if re.fullmatch(r"0*[1-9]\d*", os.environ.get("MXFS_SETTLE_MS", "")):
        parts.append(f"MXFS_SETTLE_MS={os.environ['MXFS_SETTLE_MS']}")
    marker = os.environ.get("MXFS_MARKER") or (
        str(ROOT / f".cluster_marker.{os.environ['MXFS_GROUP']}.json")
        if os.environ.get("MXFS_GROUP") else "")
    if marker:
        try:
            prepped = str(json.loads(Path(marker).read_text()).get("modargs") or "")
        except (OSError, ValueError):
            prepped = ""
        if prepped:
            parts.append(f"marker_modargs={prepped}")
    return parts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--batch", required=True)
    parser.add_argument("--at", required=True, help="the batch's configuration")
    parser.add_argument("--row", required=True, help="the batch's row (a harness, e.g. gate:<entry>)")
    parser.add_argument("--bound", type=int, required=True,
                        help="seconds, derived from what the harness takes; an overrun is a FAIL")
    parser.add_argument("--pass", dest="passed", required=True, help="regex of the harness's PASS line")
    parser.add_argument("--fail", dest="failed", default="", help="regex of its FAIL line")
    parser.add_argument("--evidence", action="append", default=[],
                        help="a dir or glob the harness writes its lap into (repeat)")
    parser.add_argument("--stall", action="append", default=[],
                        help="a regex whose one capture group is an operation's milliseconds "
                             "(repeat); max_stall_ms= lines are always read")
    parser.add_argument("--build-from", default=str(ROOT / "mxfs.ko"))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        sys.exit("batch_lap: name the harness command after --")
    for pattern in args.stall:
        if re.compile(pattern).groups != 1:
            sys.exit(f"batch_lap: --stall {pattern!r} must have exactly one capture group, "
                     f"an operation's milliseconds")
    config = criteria.parse_at(args.at)
    answer = batch_check(args)
    probe, variant = answer.get("PROBE", ""), answer.get("VARIANT", "")
    build = build_of(args.build_from)
    if not build:
        sys.exit(f"batch_lap: no srcversion in {args.build_from}: a run must carry its build")
    logdir = ROOT / "tests" / "evidence" / "batch_laps" / args.batch
    logdir.mkdir(parents=True, exist_ok=True)
    log, handle = lap_log(logdir)
    vms = lap_vms() if os.environ.get("MXFS_BATCH_LAP_HOLD", "1") != "0" else []
    holds = hold_vms(vms, f"batch_lap {args.batch} {args.row}")
    print(f"--- batch {args.batch}: one lap of {args.row} at {config}"
          f"{', exposure probe ' + repr(probe) if probe else ''}"
          f"{', variant ' + variant if variant else ''}; bound {args.bound}s; "
          f"VMs held: {' '.join(vms) or 'none'}; log {log} ---", flush=True)
    t0 = time.time()
    with handle:
        handle.write(f"=== {stamp()} {' '.join(command)} (bound {args.bound}s) ===\n")
        handle.write(f"=== VMs held for the lap: {' '.join(vms) or 'none'} ===\n")
        handle.flush()
        rc = run_bounded(command, ROOT, handle, args.bound)
        elapsed = int(time.time() - t0)
        handle.write(f"=== rc={rc} elapsed={elapsed}s ({stamp()}) ===\n")
    text = log.read_text(errors="replace")
    outcome, reason = verdict(rc, text, args.passed, args.failed, args.bound)
    files = written_since(args.evidence, t0)
    measured = f"rc={rc} elapsed_s={elapsed}"
    texts = [text] + [Path(p).read_text(errors="replace") for p in files]
    if probe:
        measured += f" exposure={count_probe(probe, texts)}"
    outcome, reason, measured = stall_graded(outcome, reason, measured, texts, args.stall)
    with log.open("a") as handle:
        handle.write("=== evidence files the lap wrote: " + " ".join(
            os.path.relpath(p, ROOT) for p in files) + " ===\n")
    # the ledger tools/defects.py batch_runs reads this batch's laps from
    board = criteria.board_for(config)
    handle = criteria.lock_board(board)
    iso = fresh_iso(board, config, args.row)
    run = {"kind": "run", "config": config, "row": args.row, "iso": iso, "outcome": outcome,
           "status": outcome, "measured": measured, "reason": reason[:2000],
           "elapsed_s": elapsed, "budget_s": args.bound, "build": build,
           "run_id": f"{iso.replace('-', '').replace(':', '')}-batchlap-{uuid.uuid4().hex[:4]}",
           "batch": args.batch, "evidence": str(log.relative_to(ROOT))}
    if os.environ.get("MXFS_CANDIDATE"):
        run["candidate"] = os.environ["MXFS_CANDIDATE"]
    lap_variant = env_variant()
    if variant:
        lap_variant.append(f"batch:{variant}")
    if lap_variant:
        run["variant"] = ";".join(lap_variant)[:300]
    criteria.append_ledger(board, [run])
    del handle
    print(f"{outcome} {config}:{args.row}:{iso} {measured} -- {reason[:200]}")
    return {"PASS": 0, "FAIL": 1}.get(outcome, 2)


if __name__ == "__main__":
    sys.exit(main())
