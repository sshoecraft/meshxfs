#!/usr/bin/env python3
"""Qualify a release candidate: every step a release needs, in order, on one frozen candidate.

    tools/release_run.py start <candidate> [--only step,step]   launch detached (the normal way)
    tools/release_run.py run   <candidate> [--only step,step]   in the foreground
    tools/release_run.py status <candidate>                     each step's state and outcome

THE ONE ENTRY POINT. A release used to be qualified by a chain script, a follow-on script that ran
the DRBD verification and the Proxmox suites only if someone remembered, a full_verify run for
the platforms, and a loop agent deciding when it had all finished. 0.90.131 was published while
some of it was still running. Here every step is a mandatory part of one directed sequence, the
candidate's manifest records each step's state, and the candidate is QUALIFIED only when the
sealing step finds every one of them passed. "The chain is done" is not a verdict.

THE STEPS, in order (each is skipped on a resumed run once it has passed):
    freeze      the candidate's frozen files are unchanged (checked again before EVERY step)
    presteps    the harness and checker self-tests: tools/harness_lint.py,
                tests/chk_oracle_calibration.sh, then (on g2, formed on the candidate's module)
                tests/rig_lib_contract.sh and tests/capture_fault_gate.sh
    build       a clean copy builds the candidate's module (same srcversion), its tools, the
                user-mode tests and the source audits
    textcheck   the text the packages ship agrees with the release data (checks 5-7; the
                README's release claims and the benchmark page are checked at seal)
    packages    the release packages, built from the frozen tree BEFORE anything is verified on
                them, into dist/<version>/
    boards      every released configuration's board, in waves on disjoint rig groups
    drbd        the DRBD dual-primary verification, graded by its own board for this candidate
    pve:<k>     the Proxmox VE suite on each claimed Proxmox kernel
    platforms   every released platform's packaged round and hung-node test, on these packages
    guards      the test of every guard data/guards.json declares
    batches     the declared verification batches for this candidate (tools/defects.py)
    repeats     the repeat rounds tools/release_plan.py schedules within the budget
    seal        the benchmark page from this candidate's runs, the public text (all checks), the
                incident gate, the release table for this candidate, a last freeze check

Every step's outcome is also a run in the primary board's ledger (row `release:<step>`), so a
step that failed on one candidate and passed on the next is still an incident until a defect
record names it. Nothing here wraps run.sh in a timeout: every row enforces its own budget, and
every other step script carries its own derived bounds.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import configuration       # noqa: E402
import criteria            # noqa: E402
import release_candidate   # noqa: E402

EVIDENCE = ROOT / "tests" / "evidence" / "candidates"
RUN_LOCK = release_candidate.RUN_LOCK


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


#: A scoped run (--configs, --platforms, --skip, --only) exercises part of a qualification, for a
#: dry run of the machinery or a resumed step; it can never seal a candidate.
SCOPE = {"configs": [], "platforms": [], "skip": []}


class Run:
    def __init__(self, cid: str):
        self.cid = cid
        self.manifest = release_candidate.load(cid)
        self.version = self.manifest["version"]
        # every evidence file and harness label of this attempt (the candidate is its version,
        # and another attempt at it, or a plain run of a harness, logs under the version)
        self.tag = release_candidate.attempt_tag(self.manifest)
        self.log = EVIDENCE / f"{self.tag}.run.log"
        EVIDENCE.mkdir(parents=True, exist_ok=True)

    def say(self, text: str) -> None:
        line = f"{now()} {text}"
        print(line, flush=True)
        with self.log.open("a") as handle:
            handle.write(line + "\n")

    def save(self) -> None:
        release_candidate.save(self.manifest)

    def reload(self) -> None:
        self.manifest = release_candidate.load(self.cid)

    def env(self, **extra) -> dict:
        env = dict(os.environ)
        env["MXFS_CANDIDATE"] = self.cid
        env.update({k: str(v) for k, v in extra.items()})
        return env

    def sh(self, args: list, log: Path, **env) -> int:
        """Run one command with its output in `log`; return its exit code."""
        self.say("run: " + " ".join(str(a) for a in args) + f"  (log {log.relative_to(ROOT)})")
        with log.open("a") as handle:
            handle.write(f"=== {now()} {' '.join(str(a) for a in args)} ===\n")
            handle.flush()
            rc = subprocess.run([str(a) for a in args], cwd=ROOT, stdout=handle,
                                stderr=subprocess.STDOUT, env=self.env(**env)).returncode
            handle.write(f"=== rc={rc} ({now()}) ===\n")
        # The command may have appended to any board's ledger, and criteria.py caches a ledger
        # per process: without this, every verdict read after a lap is the ledger from before it.
        criteria.ledger_cache.clear()
        return rc

    def record(self, step: str, outcome: str, detail: str, evidence: str, config: str) -> None:
        """The step's outcome in the candidate's manifest and, as a run, in the primary ledger."""
        self.reload()
        started = (self.manifest.get("steps") or {}).get(step, {}).get("started", "")
        # `started` stays: tools/release_plan.py sums each step's start to end as time spent
        self.manifest.setdefault("steps", {})[step] = {
            "state": "done" if outcome == "PASS" else "failed", "outcome": outcome,
            "detail": detail[:600], "evidence": evidence, "started": started, "ended": now()}
        self.save()
        recorded, status = outcome, "PASS" if outcome == "PASS" else "FAIL"
        if step == "seal" and outcome != "PASS" and self.manifest.get("dry_run"):
            # a dry run is never published, so its seal refuses by construction: an expected
            # refusal, not an incident (owner, 2026-10-22, data/release_policy.json)
            recorded, status = "CONTROL", "CONTROL"
            detail = "a dry run's seal refuses by construction: " + detail
        handle = criteria.lock_board(criteria.SPEC)
        criteria.append_ledger(criteria.SPEC, [{
            "kind": "run", "config": config, "row": f"release:{step}", "iso": now(),
            "candidate": self.cid, "build": self.manifest["srcversion"], "outcome": recorded,
            "status": status, "reason": detail[:2000], "evidence": evidence}])
        del handle
        self.say(f"step {step}: {outcome} — {detail[:300]}")

    def frozen_ok(self) -> bool:
        problems = release_candidate.drift(self.manifest)
        if not problems:
            return True
        release_candidate.move(self.manifest, "INVALID",
                               f"{len(problems)} frozen file(s) changed: " + "; ".join(problems[:5]))
        self.say("candidate INVALID: " + "; ".join(problems[:10]))
        return False


# ---------------------------------------------------------------------------------------------
# THE STEPS. Each returns (outcome, detail, evidence path, configuration the ledger files it under).
# ---------------------------------------------------------------------------------------------

def step_freeze(run: Run) -> tuple:
    return ("PASS", "every frozen file unchanged", run.manifest["files"], "1/any")


#: The pair the rig-library contract and the capture fault gate run on: their harnesses default to
#: test1,test2 at 2/net/mesh/direct, and nine gate entries reuse that pair's live mount (NOPREP=1).
PRESTEP_GROUP, PRESTEP_CONFIG = "g2", "2/net/mesh/direct"


def presteps_env(group: str) -> dict:
    """What the self-tests are told about the pair the presteps formed under `group`.

    The pool lends the pair its LUN by node set: a harness resolves its device from the nodes it
    is told (tests/lib/rig.sh), and without them it stops INFRA at stage=device. They are told the
    group the pair was formed under as well. run.sh keeps a group's cluster marker apart
    (.cluster_marker.<group>.json), and a tool that is not told reads the default marker, which
    describes whatever ran there last; a prep a harness starts itself re-forms the pair outside
    the group and rewrites that default one. MXFS_GROUP carries the group into those preps
    (run.sh), and MXFS_MARKER names its marker to every tool (tools/mxfs_rig_tag.sh,
    tests/lib/rig.sh). tests/presteps_env_lap.py checks it against the markers on disk."""
    return {"MXFS_NODE_LIST": ",".join(lab("group", group).split()), "MXFS_GROUP": group,
            "MXFS_MARKER": str(ROOT / f".cluster_marker.{group}.json")}


def step_presteps(run: Run) -> tuple:
    """The instruments are checked before anything is graded with them. The lint and the checker
    calibration are host-local; the rig-library contract and the capture fault gate need the pair
    formed on the candidate's module, so this powers g2 and forms it first."""
    log = EVIDENCE / f"{run.tag}.presteps.log"
    failed = []
    # Bounds: the lint is a static scan (2.5 s measured 2026-10-21; 30 s). The calibration and the
    # contract take the caller bounds their headers derive (150 s, 300 s). The gate bounds each of
    # its laps from its manifest, so it is not wrapped.
    for name, args in (("harness lint", ["timeout", "30", "python3", "tools/harness_lint.py",
                                         "--new-only"]),
                       ("checker calibration", ["timeout", "150", "tests/chk_oracle_calibration.sh",
                                                run.tag])):
        rc = run.sh(args, log)
        if rc != 0:
            failed.append(f"{name} rc={rc}")
    run.sh(["scripts/lab_power.sh", "up", f"group:{PRESTEP_GROUP}"], log)
    if not host_settled(run, log):
        return ("INCOMPLETE", "; ".join(failed + ["the host preflight did not pass after powering "
                                                  + PRESTEP_GROUP]), str(log.relative_to(ROOT)), "1/any")
    run.sh(["./run.sh", PRESTEP_CONFIG, "--group", PRESTEP_GROUP, "prep_cluster"], log)
    # run.sh exits 0 over a failed row: the verdict is the row's ledger run for this candidate
    # (and of this attempt: an earlier attempt at the version left its runs under the same name)
    prep = next(iter(criteria.ledger_runs(criteria.SPEC, PRESTEP_CONFIG, "prep_cluster")), {})
    if prep.get("candidate") != run.cid or prep.get("outcome") != "PASS" \
            or str(prep.get("iso", "")) < run.manifest["created"]:
        return ("INCOMPLETE", "; ".join(failed + [f"prep_cluster at {PRESTEP_CONFIG} on "
                                                  f"{PRESTEP_GROUP} did not pass for {run.cid}: "
                                                  f"{prep.get('outcome')} {prep.get('reason', '')}"]),
                str(log.relative_to(ROOT)), "1/any")
    pair = presteps_env(PRESTEP_GROUP)
    rc = run.sh(["timeout", "300", "tests/rig_lib_contract.sh", run.tag], log, **pair)
    if rc != 0:
        failed.append(f"rig library contract rc={rc}")
    rc = run.sh(["tests/capture_fault_gate.sh", run.tag], log, **pair)
    gate = [line for line in log.read_text(errors="replace").splitlines()
            if line.startswith("RESULT: ") and f" label={run.tag} " in line]
    if rc != 0 or not gate or not gate[-1].startswith("RESULT: PASS "):
        failed.append(f"capture fault gate rc={rc}: {gate[-1][:160] if gate else 'no RESULT line'}")
    if failed:
        return ("FAIL", "self-tests failed: " + "; ".join(failed), str(log.relative_to(ROOT)), "1/any")
    return ("PASS", "harness lint, checker calibration, rig library contract, capture fault gate",
            str(log.relative_to(ROOT)), "1/any")


def step_build(run: Run) -> tuple:
    """The candidate's module from a clean copy (no objects), its tools, the user-mode tests and
    the source audits, in a scratch directory removed afterwards."""
    log = EVIDENCE / f"{run.tag}.build.log"
    scratch = Path(tempfile.mkdtemp(prefix=f"mxfs-build-{run.cid}-"))
    # The copy is the candidate's frozen file list and nothing else, so the build proves what
    # was frozen builds the candidate's module. A whole-tree copy also took result files (a
    # root-only bench.json stopped 0.90.133-2's build) and anything not frozen.
    frozen = json.loads((ROOT / run.manifest["files"]).read_text())
    listing = scratch.with_name(scratch.name + ".files")
    listing.write_text("".join(rel + "\n" for rel in sorted(frozen) if not os.path.isabs(rel)))
    try:
        rc = run.sh(["rsync", "-a", f"--files-from={listing}", f"{ROOT}/", f"{scratch}/"], log)
        if rc != 0:
            return ("FAIL", "could not copy the frozen files", str(log.relative_to(ROOT)), "1/any")
        rc = run.sh(["make", "-C", str(scratch), "modules", f"-j{os.cpu_count()}"], log)
        built = subprocess.run(["modinfo", "-F", "srcversion", str(scratch / "mxfs.ko")],
                               capture_output=True, text=True).stdout.strip()
        problems = []
        if rc != 0:
            problems.append(f"make modules rc={rc}")
        elif built != run.manifest["srcversion"]:
            problems.append(f"the clean build is {built!r}; the candidate's module is "
                            f"{run.manifest['srcversion']}")
        # The built tools are frozen files, so the copy carries them with their times and a plain
        # make rebuilt nothing ("Nothing to be done", 0.90.133-3). Rebuilt from clean, each must
        # be the frozen binary byte for byte (the build is reproducible: measured 2026-10-21), as
        # the module must be its srcversion: otherwise the rig ran tools built from other sources.
        if run.sh(["make", "-C", str(scratch / "tools"), "clean", "all"], log) != 0:
            problems.append("make -C tools failed")
        else:
            names = re.search(r"^TOOLS\s*=\s*(.+)$", (scratch / "tools" / "Makefile").read_text(),
                              re.M)
            for name in names.group(1).split() if names else []:
                rel = f"tools/{name}"
                if rel not in frozen:
                    problems.append(f"{rel} was not built when the candidate was frozen")
                elif release_candidate.sha256(scratch / rel) != frozen[rel][0]:
                    problems.append(f"{rel}: the clean build differs from the frozen binary")
        if run.sh(["make", "-C", str(scratch / "tests" / "tauth"), "clean", "test"], log) != 0:
            problems.append("tests/tauth failed")
        for audit in ("scripts/extern_decl_audit.py", "scripts/inode_flag_bits_audit.py"):
            if run.sh(["python3", audit], log) != 0:
                problems.append(f"{audit} failed")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
        listing.unlink(missing_ok=True)
    if problems:
        return ("FAIL", "; ".join(problems), str(log.relative_to(ROOT)), "1/any")
    return ("PASS", f"clean build {built}, tools identical to the frozen ones, tauth, audits",
            str(log.relative_to(ROOT)), "1/any")


def step_textcheck(run: Run) -> tuple:
    log = EVIDENCE / f"{run.tag}.textcheck.log"
    rc = run.sh(["python3", "tools/release_text_check.py", "--before-build"], log)
    return ("PASS" if rc == 0 else "FAIL", f"release_text_check checks 5-7 (packaged text) rc={rc}",
            str(log.relative_to(ROOT)), "1/any")


def step_packages(run: Run) -> tuple:
    log = EVIDENCE / f"{run.tag}.packages.log"
    dist = f"dist/{run.version}"
    sums = ROOT / dist / "SHA256SUMS"
    if sums.is_file():
        # An earlier attempt at this version (or a plain build of it) is there. A version that
        # was published is never built again; any other build is not this attempt's, so it is
        # removed and the packages are built from this attempt's frozen tree. The earlier
        # attempt's package hashes stay in this candidate's `attempts`.
        if run.version in json.loads((ROOT / "data" / "release_builds.json").read_text()):
            return ("FAIL", f"{dist} holds the published {run.version}; bump VERSION",
                    str(log.relative_to(ROOT)), "1/any")
        names = [line.split()[1] for line in sums.read_text().splitlines() if line.strip()]
        run.say(f"removing the earlier unpublished build in {dist}: {', '.join(names)}")
        for name in names + ["SHA256SUMS"]:
            (ROOT / dist / name).unlink(missing_ok=True)
    rc = run.sh(["scripts/release.sh"], log, MXFS_DIST=dist)
    if rc != 0 or not sums.is_file():
        return ("FAIL", f"scripts/release.sh rc={rc}", str(log.relative_to(ROOT)), "1/any")
    run.reload()
    run.manifest["dist"] = dist
    run.manifest["packages"] = {line.split()[1]: line.split()[0]
                                for line in sums.read_text().splitlines() if line.strip()}
    run.save()
    return ("PASS", f"{len(run.manifest['packages'])} packages in {dist}",
            str(log.relative_to(ROOT)), "1/any")


def lab(*args) -> str:
    return subprocess.run(["tools/mxfs_lab.sh", *args], cwd=ROOT, capture_output=True,
                          text=True).stdout.strip()


def board_configs() -> list:
    """Every configuration the release table grades by a board, except one this version does not
    claim (data/configurations.json released_earlier) -- the default-install gate decides those."""
    table = json.loads((ROOT / "data" / "release_table.json").read_text())
    earlier = json.loads((ROOT / "data" / "configurations.json").read_text()).get(
        "released_earlier", {})
    found = []
    for row in table["rows"]:
        for board in row.get("boards") or []:
            if board["config"] not in found and board["config"] not in earlier:
                found.append(board["config"])
    if SCOPE["configs"]:
        found = [c for c in found if c in SCOPE["configs"]]
    return found


def groups_of(nodes: int) -> list:
    """The rig groups of exactly `nodes` nodes, g<n>, g<n>b, g<n>c, ... in order."""
    found, index = [], 0
    while True:
        name = f"g{nodes}" + (chr(97 + index) if index else "")
        members = lab("group", name).split()
        if len(members) != nodes:
            return found
        found.append((name, members))
        index += 1


def big_luns() -> int:
    out = subprocess.run(["tools/lun_pool.sh", "status"], cwd=ROOT, capture_output=True,
                         text=True).stdout
    count = 0
    for line in out.splitlines():
        fields = line.split()
        if len(fields) >= 2 and re.fullmatch(r"lun\d+", fields[0]):
            size = fields[1].rstrip("G")
            if size.replace(".", "", 1).isdigit() and float(size) >= 80:
                count += 1
    return max(count, 1)


def waves() -> list:
    """Boards side by side on groups that share no node, and no more boards above 8 nodes in one
    wave than the pool has LUNs of 80G or more (a board above 8 nodes takes one)."""
    placed = []
    per_count: dict = {}
    for config in board_configs():
        nodes = int(config.split("/")[0])
        groups = groups_of(nodes)
        if not groups:
            raise SystemExit(f"release_run: no rig group of {nodes} nodes for {config}")
        index = per_count.get(nodes, 0)
        per_count[nodes] = index + 1
        placed.append((config, groups[index % len(groups)]))
    limit = big_luns()
    result: list = []
    for config, (group, members) in placed:
        big = len(members) > 8
        for wave in result:
            if not (set(members) & wave["nodes"]) and not (big and wave["big"] >= limit):
                wave["boards"].append(f"{config}@{group}")
                wave["nodes"] |= set(members)
                wave["big"] += int(big)
                break
        else:
            result.append({"boards": [f"{config}@{group}"], "nodes": set(members),
                           "big": int(big)})
    return [w["boards"] for w in result]


def host_settled(run: Run, log: Path) -> bool:
    """The host preflight passes, within the time a set of guests takes to boot and log in
    (~40 s measured) plus the login burst itself: 120 s."""
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if run.sh(["scripts/clyde_preflight.sh"], log) == 0:
            return True
        time.sleep(10)
    return False


def board_verdict(cid: str, config: str, board: Path | None = None) -> list:
    """The rows of `config` that do not read PASS for the candidate.

    A configuration of an attachment verified on its own rig (drbd) parses only with
    MXFS_OWN_RIG=1, which criteria.py sets only when its own command line names one. Without it
    here no row applied and the verdict was empty: the DRBD board was never graded (0.90.134 dry
    run). A verdict that graded no row is refused, never read as clean."""
    saved = os.environ.get("MXFS_OWN_RIG")
    if configuration.ATTACHES.get(config.rsplit("/", 1)[-1], {}).get("own_rig"):
        os.environ["MXFS_OWN_RIG"] = "1"
    try:
        data = criteria.read_board(board or criteria.SPEC)
        bad, graded = [], 0
        for entry in data["criteria"]:
            if not criteria.applies(entry, config):
                continue
            graded += 1
            mark = criteria.cell_status(entry, config, "", cid, board or criteria.SPEC)
            if mark not in criteria.GREEN:
                bad.append(f"{entry['id']}={mark}")
    finally:
        if saved is None:
            os.environ.pop("MXFS_OWN_RIG", None)
        else:
            os.environ["MXFS_OWN_RIG"] = saved
    if not graded:
        bad.append(f"no row of the specification applies at {config}: nothing was graded")
    return bad


def step_boards(run: Run) -> tuple:
    log = EVIDENCE / f"{run.tag}.boards.log"
    released = json.loads((ROOT / "data" / "platforms.json").read_text())["platforms"]
    sets = [k for k, v in released.items() if v.get("status") == "released"]
    run.sh(["scripts/lab_power.sh", "down", *sets], log)
    for number, wave in enumerate(waves(), 1):
        run.sh(["scripts/lab_power.sh", "up", *[f"group:{b.split('@')[1]}" for b in wave]], log)
        if not host_settled(run, log):
            return ("INCOMPLETE", f"the host preflight did not pass before wave {number}",
                    str(log.relative_to(ROOT)), "1/any")
        run.sh(["tests/board_4node_chain.sh", f"{run.tag}_w{number}", *wave], log)
    problems = []
    for config in board_configs():
        bad = board_verdict(run.cid, config)
        if bad:
            problems.append(f"{config}: " + ", ".join(bad[:6]) + (f" (+{len(bad) - 6})" if len(bad) > 6 else ""))
    if problems:
        return ("FAIL", "; ".join(problems), str(log.relative_to(ROOT)), "1/any")
    return ("PASS", f"{len(board_configs())} boards read PASS for {run.cid}",
            str(log.relative_to(ROOT)), "1/any")


def step_drbd(run: Run) -> tuple:
    log = EVIDENCE / f"{run.tag}.drbd.log"
    run.sh(["tests/drbd_release_verify.sh", run.version], log, MXFS_LOGTAG=run.tag)
    out = ROOT / "tests" / "evidence" / f"drbd_release_verify_{run.tag}.out"
    last = out.read_text().strip().splitlines()[-1] if out.is_file() and out.stat().st_size else ""
    board = ROOT / "tests" / "evidence" / "drbd_rig" / "criteria.json"
    bad = board_verdict(run.cid, "2/net/mesh/drbd", board)
    if not last.startswith(f"DRBD_RELEASE_VERIFY PASS version={run.version} ") or bad:
        return ("FAIL", (last or "no verdict line") + ("; board: " + ", ".join(bad[:8]) if bad else ""),
                str(out.relative_to(ROOT)), "2/net/mesh/drbd")
    return ("PASS", last, str(out.relative_to(ROOT)), "2/net/mesh/drbd")


def pve_kernels() -> list:
    data = json.loads((ROOT / "data" / "platforms.json").read_text())["platforms"]
    return [k for k in (data.get("pve9") or {}).get("kernel_releases") or [] if k]


def step_pve(run: Run, kernel: str) -> tuple:
    label = f"{run.tag}k{kernel.split('-')[0].replace('.', '')}"
    log = EVIDENCE / f"{run.tag}.pve_{kernel}.log"
    rc = run.sh(["scripts/pve_suite_on_kernel.sh", kernel, label], log)
    out = ROOT / "tests" / "evidence" / f"pve_full_suite_{label}.out"
    text = out.read_text(errors="replace") if out.is_file() else ""
    verdict = ([l for l in text.splitlines() if l.startswith("SUITE: ")] or [""])[-1]
    builds = set(re.findall(r"^192\.\S+ (?:[0-9.]+ )?([0-9A-F]{23}) ", text, re.M))
    if len(builds) == 1:
        build = builds.pop()
        run.reload()
        run.manifest.setdefault("kernels", {})[kernel] = build
        run.save()
    if rc != 0 or not verdict.startswith("SUITE: PASS"):
        return ("FAIL", verdict or f"pve_suite_on_kernel rc={rc}", str(log.relative_to(ROOT)),
                "3/disk/caw/mpath")
    return ("PASS", verdict, str(out.relative_to(ROOT)), "3/disk/caw/mpath")


def step_platforms(run: Run) -> tuple:
    log = EVIDENCE / f"{run.tag}.platforms.log"
    if not run.manifest.get("dist"):
        # the rounds verify the candidate's own packages; without them full_verify would be
        # handed an empty MXFS_DIST (0.90.133-2 did exactly that after its packages step failed)
        return ("FAIL", "no packages to verify: the packages step did not pass",
                str(log.relative_to(ROOT)), "2/net/mesh/direct")
    extra = {"PLATFORMS": " ".join(SCOPE["platforms"])} if SCOPE["platforms"] else {}
    rc = run.sh(["tests/full_verify.sh", run.version], log, STEPS="platforms", POWER="1",
                MXFS_DIST=run.manifest["dist"], MXFS_LOGTAG=run.tag, **extra)
    main = ROOT / "tests" / "evidence" / f"full_verify_{run.tag}.log"
    if not main.is_file():
        last = [line for line in log.read_text(errors="replace").splitlines()
                if line.strip() and not line.startswith("=== ")]
        return ("FAIL", f"full_verify rc={rc} and wrote no log: {last[-1][:200] if last else '?'}",
                str(log.relative_to(ROOT)), "2/net/mesh/direct")
    failed = len(re.findall(r"^=== rc=[1-9]", main.read_text(errors="replace"), re.M))
    if rc != 0 or failed:
        return ("FAIL", f"full_verify platforms rc={rc}, {failed} failed step(s)",
                str(main.relative_to(ROOT)), "2/net/mesh/direct")
    return ("PASS", "every released platform's packaged round and hung-node test",
            str(main.relative_to(ROOT)), "2/net/mesh/direct")


def step_guards(run: Run) -> tuple:
    try:
        guards = json.loads((ROOT / "data" / "guards.json").read_text()).get("guards", {})
    except (OSError, ValueError):
        guards = {}
    log = EVIDENCE / f"{run.tag}.guards.log"
    failed = []
    for config, guard in guards.items():
        if run.sh(["bash", "-c", guard["test"]["command"]], log) != 0:
            failed.append(config)
    if failed:
        return ("FAIL", "guard tests failed: " + ", ".join(failed), str(log.relative_to(ROOT)),
                "1/any")
    return ("PASS", f"{len(guards)} guard test(s)", str(log.relative_to(ROOT)), "1/any")


def step_batches(run: Run) -> tuple:
    """Every open verification batch declared for this candidate, lap by lap. A lap that fails
    ends its batch (tools/defects.py verify then closes it as failed).

    A calibration or control batch declared for the candidate is not run here. Its laps measure a
    rate, and a failing one is the measurement; graded as a step it would fail the candidate."""
    sys.path.insert(0, str(ROOT / "tools"))
    import defects  # noqa: E402
    log = EVIDENCE / f"{run.tag}.batches.log"
    queue = defects.load()["defects"]
    batches = [(e["id"], b) for e in queue for b in e.get("batches") or []
               if b.get("candidate") == run.cid and b.get("state") == "open"
               and b.get("kind") == "verify"]
    summary, short = [], []
    for record, batch in batches:
        laps = [r for r in defects.batch_runs(batch)
                if r.get("outcome") in ("PASS", "FAIL", "INCOMPLETE")]
        for lap in range(len(laps), int(batch["planned"])):
            if lap == 0 or batch.get("leaves_cluster"):
                run.sh(["./run.sh", batch["config"], "prep_cluster"], log)
            run.sh(["./run.sh", batch["config"], batch["row"]], log, MXFS_BATCH=batch["id"])
            last = [r for r in defects.batch_runs(batch) if r.get("outcome")]
            if last and last[0].get("outcome") == "FAIL":
                break
        laps = [r for r in defects.batch_runs(batch)
                if r.get("outcome") in ("PASS", "FAIL", "INCOMPLETE", "INFRA")]
        good = sum(1 for r in laps if r["outcome"] == "PASS" and defects.exposed(r, batch)
                   and not defects.unplanned_variant(r, batch))
        bad = sum(1 for r in laps if r["outcome"] != "PASS")
        summary.append(f"{batch['id']} ({record}) {good}/{batch['planned']} exposed pass, "
                       f"{bad} fail or incomplete")
        # a lap that failed, or laps that ran out before the planned exposed passes, leave the
        # record blocking: the batch did not verify anything
        if bad or good < int(batch["planned"]):
            short.append(batch["id"])
    return ("FAIL" if short else "PASS",
            ("batches that did not verify: " + ", ".join(short) + "; " if short else "")
            + ("; ".join(summary) or "no open verification batch for this candidate"),
            str(log.relative_to(ROOT)), "1/any")


def step_repeats(run: Run) -> tuple:
    log = EVIDENCE / f"{run.tag}.repeats.log"
    plan = subprocess.run(["python3", "tools/release_plan.py", "--candidate", run.cid, "--json"],
                          cwd=ROOT, capture_output=True, text=True)
    if plan.returncode != 0:
        return ("FAIL", "tools/release_plan.py: " + plan.stderr.strip()[:300],
                str(log.relative_to(ROOT)), "1/any")
    schedule = json.loads(plan.stdout)
    if SCOPE["configs"]:
        # a dry run exercises the step: its own configurations only, one repeat round each, not
        # the rounds a real qualification's budget buys
        kept, seen = [], set()
        for item in schedule.get("runs", []):
            if item["config"] in SCOPE["configs"] and item["config"] not in seen:
                seen.add(item["config"])
                kept.append(item)
        schedule["runs"] = kept
        schedule["hours"] = sum(i.get("predicted_s", 0) for i in kept) / 3600
    for item in schedule.get("runs", []):
        if item.get("prep", True):
            run.sh(["./run.sh", item["config"], "prep_cluster"], log)
        run.sh(["./run.sh", item["config"], *item["rows"]], log)
    problems = []
    for config in sorted({i["config"] for i in schedule.get("runs", [])}):
        bad = board_verdict(run.cid, config)
        if bad:
            problems.append(f"{config}: " + ", ".join(bad[:6]))
    if problems:
        return ("FAIL", "; ".join(problems), str(log.relative_to(ROOT)), "1/any")
    return ("PASS", f"{len(schedule.get('runs', []))} scheduled run(s), "
                    f"{schedule.get('hours', 0):.1f} h predicted", str(log.relative_to(ROOT)), "1/any")


def step_seal(run: Run) -> tuple:
    log = EVIDENCE / f"{run.tag}.seal.log"
    problems = []
    if run.sh(["python3", "tools/bench_report.py", "--candidate", run.cid], log) != 0:
        problems.append("bench page")
    if run.sh(["python3", "tools/release_text_check.py", "--candidate", run.cid], log) != 0:
        problems.append("public text")
    if run.sh(["python3", "tools/criteria.py", "incidents"], log) != 0:
        problems.append("incidents nothing accounts for")
    if run.sh(["python3", "tools/release_status.py", "--candidate", run.cid, "--gate", "-v",
                   "--details"], log) != 0:
        problems.append("release table / default install path")
    for name, state in (run.manifest.get("steps") or {}).items():
        if name != "seal" and state.get("outcome") != "PASS":
            problems.append(f"step {name} {state.get('outcome')}")
    if problems:
        return ("FAIL", "not sealed: " + "; ".join(problems), str(log.relative_to(ROOT)), "1/any")
    return ("PASS", "sealed", str(log.relative_to(ROOT)), "1/any")


def plan_steps() -> list:
    steps = ["freeze", "presteps", "build", "textcheck", "packages", "boards", "drbd"]
    steps += [f"pve:{k}" for k in pve_kernels()]
    steps += ["platforms", "guards", "batches", "repeats", "seal"]
    return steps


def do_step(run: Run, name: str) -> tuple:
    if name.startswith("pve:"):
        return step_pve(run, name.split(":", 1)[1])
    return {"freeze": step_freeze, "presteps": step_presteps, "build": step_build,
            "textcheck": step_textcheck, "packages": step_packages, "boards": step_boards,
            "drbd": step_drbd, "platforms": step_platforms, "guards": step_guards,
            "batches": step_batches, "repeats": step_repeats, "seal": step_seal}[name](run)


def cmd_run(args) -> int:
    lock = RUN_LOCK.open("w")
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit("release_run: another qualification holds %s" % RUN_LOCK)
    run = Run(args.candidate)
    if run.manifest["state"] != "RUNNING":
        sys.exit(f"release_run: candidate {args.candidate} is {run.manifest['state']}")
    # the runner records itself, so `status` can tell a run in the foreground is alive too
    (EVIDENCE / f"{run.tag}.pid").write_text(f"{os.getpid()}\n")
    steps = plan_steps()
    only = [s for s in (args.only or "").split(",") if s]
    SCOPE["configs"] = [c for c in (args.configs or "").split(",") if c]
    SCOPE["platforms"] = [p for p in (args.platforms or "").split(",") if p]
    SCOPE["skip"] = [s for s in (args.skip or "").split(",") if s]
    scoped = bool(only or SCOPE["configs"] or SCOPE["platforms"] or SCOPE["skip"])
    if scoped and not run.manifest.get("dry_run"):
        sys.exit("release_run: a scoped run (--only, --configs, --platforms, --skip) is for a "
                 "dry-run candidate; a real candidate is qualified whole")
    run.say(f"=== qualify {run.cid} (version {run.version}, module {run.manifest['srcversion']})"
            f"{' dry run' if run.manifest.get('dry_run') else ''}: {', '.join(only or steps)}"
            f"{' scope ' + json.dumps(SCOPE) if scoped else ''} ===")
    for name in steps:
        if only and name not in only:
            continue
        if name in SCOPE["skip"] or (name.startswith("pve:") and "pve" in SCOPE["skip"]):
            run.say(f"step {name}: skipped (scope)")
            continue
        done = (run.manifest.get("steps") or {}).get(name, {})
        if done.get("outcome") == "PASS" and name != "seal":
            run.say(f"step {name}: already passed")
            continue
        if not run.frozen_ok():
            return 1
        run.reload()
        run.manifest.setdefault("steps", {})[name] = {"state": "running", "started": now()}
        run.save()
        outcome, detail, evidence, config = do_step(run, name)
        run.record(name, outcome, detail, evidence, config)
    if not run.frozen_ok():
        return 1
    run.reload()
    if scoped:
        ran = [s for s in steps if (run.manifest["steps"].get(s) or {}).get("outcome")]
        bad = [s for s in ran if run.manifest["steps"][s]["outcome"] != "PASS"]
        run.say(f"=== scoped run done: {len(ran)} step(s) ran, not passed: {', '.join(bad) or 'none'}; "
                f"a scoped run never seals a candidate ===")
        # A scoped run is a dry run's, and a dry run is never qualified: leaving it RUNNING kept
        # the edit hook refusing every frozen file until someone abandoned it by hand.
        release_candidate.move(run.manifest, "ABANDONED",
                               f"scoped dry run done; not passed: {', '.join(bad) or 'none'}")
        return 1 if bad else 0
    if all((run.manifest["steps"].get(s) or {}).get("outcome") == "PASS" for s in steps):
        if run.manifest.get("dry_run"):
            release_candidate.move(run.manifest, "ABANDONED", "dry run complete: every step passed")
            run.say("=== DRY RUN COMPLETE: every step passed (a dry run is never qualified) ===")
            return 0
        release_candidate.move(run.manifest, "QUALIFIED", "every step passed")
        run.say(f"=== {run.cid} QUALIFIED ===")
        return 0
    failed = [s for s in steps if (run.manifest["steps"].get(s) or {}).get("outcome") != "PASS"]
    release_candidate.move(run.manifest, "COMPLETE_FAILED", "not passed: " + ", ".join(failed))
    run.say(f"=== {run.cid} COMPLETE_FAILED: {', '.join(failed)} ===")
    return 1


def cmd_start(args) -> int:
    run = Run(args.candidate)
    out = EVIDENCE / f"{run.tag}.run.out"
    # No setsid(1) here: start_new_session already makes the child a session leader, and
    # setsid(1) run as a process group leader forks, so the pid recorded was a launcher that
    # exited at once while the runner went on under another pid (measured on 0.90.133-2).
    # nohup execs the runner in place, so child.pid is the runner.
    command = ["nohup", sys.executable, str(Path(__file__).resolve()), "run", args.candidate]
    for flag in ("only", "configs", "platforms", "skip"):
        if getattr(args, flag):
            command += [f"--{flag}", getattr(args, flag)]
    with out.open("a") as handle:
        child = subprocess.Popen(command, cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT,
                                 stdin=subprocess.DEVNULL, start_new_session=True)
    (EVIDENCE / f"{run.tag}.pid").write_text(f"{child.pid}\n")
    run.say(f"started pid {child.pid}; output {out.relative_to(ROOT)}, log {run.log.relative_to(ROOT)}")
    return 0


def runner_alive(tag: str) -> tuple:
    """(pid, alive) for the attempt's recorded runner: alive when /proc shows that pid running
    this tool's `run` for this candidate (read from comm and stat only -- never another process's
    cmdline, which takes its mmap_lock)."""
    try:
        pid = int((EVIDENCE / f"{tag}.pid").read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return (0, False)
    try:
        comm = Path(f"/proc/{pid}/comm").read_text().strip()
        state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
    except OSError:
        return (pid, False)
    return (pid, comm.startswith("python") and state != "Z")


def cmd_status(args) -> int:
    run = Run(args.candidate)
    manifest = run.manifest
    pid, alive = runner_alive(run.tag)
    print(f"{manifest['candidate']}  {manifest['state']}  version {manifest['version']}  "
          f"module {manifest['srcversion']}{'  DRY RUN' if manifest.get('dry_run') else ''}"
          f"  runner {pid or '-'} {'alive' if alive else 'not running'}")
    for name in plan_steps():
        state = (manifest.get("steps") or {}).get(name)
        if state:
            shown = state.get("outcome", state.get("state", "?"))
            if state.get("state") == "running" and not alive:
                shown = "DIED"
            print(f"  {name:22} {shown:11} "
                  f"{state.get('ended', state.get('started', ''))}  {state.get('detail', '')[:90]}")
        else:
            print(f"  {name:22} -")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    subs = ap.add_subparsers(dest="command", required=True)
    for name in ("start", "run"):
        sub = subs.add_parser(name)
        sub.add_argument("candidate")
        sub.add_argument("--only", help="comma-separated steps to run (dry-run candidates only)")
        sub.add_argument("--configs", help="only these board configurations (dry runs)")
        sub.add_argument("--platforms", help="only these platforms' rounds (dry runs)")
        sub.add_argument("--skip", help="steps to leave out, e.g. pve (dry runs)")
    status = subs.add_parser("status")
    status.add_argument("candidate")
    args = ap.parse_args()
    return {"start": cmd_start, "run": cmd_run, "status": cmd_status}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
