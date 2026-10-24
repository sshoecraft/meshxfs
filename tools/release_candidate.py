#!/usr/bin/env python3
"""A release candidate: the frozen tree a release is qualified on, and its record.

    tools/release_candidate.py create [--dry-run]   freeze this tree as the candidate for VERSION
    tools/release_candidate.py check <id>           exit 1 if anything frozen changed (sets INVALID)
    tools/release_candidate.py show [<id>]          the manifest (the active candidate by default)
    tools/release_candidate.py state <id> <STATE>   move a candidate on (the orchestrator does this)
    tools/release_candidate.py abandon <id> --why "..."
    tools/release_candidate.py frozen <path>        exit 0 if a RUNNING candidate freezes <path>

WHY. 0.90.131 was published before the checks on its shipped build had finished; a chain whose
packages step ran after a source edit built packages nobody had verified; a half-finished edit to
the board's own tool crashed a live run; and a release session changed how the board graded while
the release was being graded. Each was a rule an agent had to remember. A candidate makes them
mechanical: everything a qualification runs is hashed when the candidate is made, the orchestrator
(tools/release_run.py) re-checks the hashes before every step and at sealing, any change -- even
one reverted, which a hash alone would miss, so each file's inode change time is checked too --
makes the candidate INVALID, and the publisher (scripts/release.sh --publish --candidate) refuses
anything that is not QUALIFIED with its hashes intact (docs/release-process.md).

WHAT IS FROZEN is listed below, explicitly; every file under data/ is frozen unless it is named as
mutable, because data/ is where the specification and the policy live. The board's specification
(each row's requirement, detector, budget and dispatch fields in data/criteria.json) and
data/platforms.json without its `verified` records are hashed as projections: the results those
files also hold are written during qualification.

States: RUNNING -> QUALIFIED -> PUBLISHED; RUNNING -> COMPLETE_FAILED | BLOCKED | INVALID;
any -> ABANDONED. A `dry_run` candidate exercises the machinery and can never be QUALIFIED or
published.
"""
from __future__ import annotations

import argparse
import fcntl
import fnmatch
import hashlib
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CANDIDATES = ROOT / "data" / "candidates"
ACTIVE = CANDIDATES / "active.json"
EVIDENCE = ROOT / "tests" / "evidence" / "candidates"
#: held by tools/release_run.py for the whole of a qualification
RUN_LOCK = Path("/tmp/mxfs_release_run.lock")
LAB = Path(os.environ.get("MXFS_LAB") or Path.home() / ".config" / "mxfslab" / "lab")

#: Directories whose every file is frozen (minus MUTABLE).
FROZEN_DIRS = ("xfs", "dlm", "pal", "mxfs_clayer", "include", "compat", "tests", "tools",
               "scripts", "packaging", "frontend/proxmox", "docs/man")
#: Single files frozen by name, and root files frozen by pattern.
FROZEN_FILES = ("Kbuild", "Makefile", "VERSION", "run.sh", "docs/drbd-setup.md",
                ".claude/agents/release-reviewer.md", ".claude/settings.json")
FROZEN_ROOT_PATTERNS = (".xfs_fio_baseline*", ".raw_fio_ceiling.*.json", ".lrb_native.*")
#: Under data/: everything is frozen except these, which qualification itself writes.
DATA_MUTABLE = ("criteria.json", "criteria.pvephys.json", "*.runs.jsonl", "defects.json",
                "proposals.json", "release_builds.json", "platforms.json", "release_table.json.lock",
                "candidates/*", "reviews/*", ".*")
#: Written by runs, or rebuilt at every run's start, wherever they sit in a frozen directory.
MUTABLE = ("tests/evidence/*", "tests/suite/tools/fsx", "tools/.built_for", "*/__pycache__/*",
           "*.pyc", "*.o", "*.ko", "*.mod", "*.mod.c", "*.cmd", ".*.cmd", "*.tmp", "*/.tmp_*",
           "tests/queues/*.state", "tools/*.o")
#: The board's specification fields (tools/criteria.py's `rows` and `budget_of`).
SPEC_FIELDS = ("id", "phase", "applies_to", "coord", "min_nodes", "max_nodes", "budget_s",
               "budget_scale", "requirement", "detector", "leaves_cluster")
STATES = ("RUNNING", "BLOCKED", "COMPLETE_FAILED", "INVALID", "QUALIFIED", "PUBLISHED",
          "ABANDONED")


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def mutable(rel: str) -> bool:
    if any(fnmatch.fnmatch(rel, pattern) for pattern in MUTABLE):
        return True
    if rel.startswith("data/"):
        inner = rel[len("data/"):]
        return any(fnmatch.fnmatch(inner, pattern) for pattern in DATA_MUTABLE)
    return False


def frozen_paths() -> list:
    """Every frozen file, relative to the tree, sorted; the lab file is named by its absolute
    path (its secrets and per-platform copies are never hashed)."""
    found = set()
    for top in FROZEN_DIRS:
        base = ROOT / top
        for dirpath, dirnames, filenames in os.walk(base):
            rel_dir = os.path.relpath(dirpath, ROOT)
            dirnames[:] = [d for d in dirnames
                           if not mutable(os.path.join(rel_dir, d) + "/x")]
            for name in filenames:
                rel = os.path.join(rel_dir, name)
                if not mutable(rel) and not os.path.islink(ROOT / rel):
                    found.add(rel)
    for rel in FROZEN_FILES:
        if (ROOT / rel).is_file():
            found.add(rel)
    for pattern in FROZEN_ROOT_PATTERNS:
        for path in ROOT.glob(pattern):
            if path.is_file():
                found.add(path.name)
    for path in (ROOT / "data").rglob("*"):
        rel = str(path.relative_to(ROOT))
        if path.is_file() and not mutable(rel):
            found.add(rel)
    paths = sorted(found)
    if LAB.is_file():
        paths.append(str(LAB))
    return paths


def stamp_of(rel: str) -> list:
    path = Path(rel) if os.path.isabs(rel) else ROOT / rel
    info = path.stat()
    # the permission bits last, so an older list's five fields keep their places: a fix that
    # changes only a file's mode (an execute bit) has nothing else for a control's proof to
    # compare (tools/harness_batch.py compare_inputs)
    return [sha256(path), info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
            info.st_mode & 0o7777]


def spec_projection() -> str:
    board = json.loads((ROOT / "data" / "criteria.json").read_text())
    rows = [{k: e.get(k) for k in SPEC_FIELDS if k in e} for e in board.get("criteria", [])]
    return hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest()


def platforms_projection() -> str:
    data = json.loads((ROOT / "data" / "platforms.json").read_text())
    for info in (data.get("platforms") or {}).values():
        if isinstance(info, dict):
            info.pop("verified", None)
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()


def module_build() -> str:
    out = subprocess.run(["modinfo", "-F", "srcversion", str(ROOT / "mxfs.ko")],
                         capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else ""


def manifest_path(cid: str) -> Path:
    return CANDIDATES / f"{cid}.json"


def attempt_tag(manifest: dict) -> str:
    """The label of the candidate's current attempt, `<version>_<when it was frozen>`: every
    evidence file and harness label of the attempt carries it. The candidate's name alone is
    shared by every attempt at the version (and is the version a plain run of a harness logs
    under), so a step reading its verdict from a file named by it could read another run's."""
    return f"{manifest['candidate']}_{manifest['created'].replace(':', '').replace('-', '')}"


def load(cid: str) -> dict:
    try:
        return json.loads(manifest_path(cid).read_text())
    except (OSError, ValueError) as exc:
        sys.exit(f"release_candidate: no candidate {cid}: {exc}")


def save(manifest: dict) -> None:
    CANDIDATES.mkdir(parents=True, exist_ok=True)
    path = manifest_path(manifest["candidate"])
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    os.replace(temporary, path)


def set_active(manifest: dict) -> None:
    temporary = ACTIVE.with_suffix(".json.tmp")
    temporary.write_text(json.dumps({"candidate": manifest["candidate"],
                                     "state": manifest["state"]}, indent=2) + "\n")
    os.replace(temporary, ACTIVE)


def active() -> dict:
    try:
        return json.loads(ACTIVE.read_text())
    except (OSError, ValueError):
        return {}


def drift(manifest: dict) -> list:
    """What changed since the candidate was frozen: content, or a change reverted since (the
    inode change time moved), or a file added to or gone from the frozen set."""
    files = json.loads((ROOT / manifest["files"]).read_text())
    problems = []
    now_paths = set(frozen_paths())
    for rel, was in files.items():
        path = Path(rel) if os.path.isabs(rel) else ROOT / rel
        if not path.is_file():
            problems.append(f"gone: {rel}")
            continue
        info = path.stat()
        if info.st_ctime_ns != was[4] or info.st_ino != was[1] or info.st_size != was[2]:
            if sha256(path) != was[0]:
                problems.append(f"changed: {rel}")
            else:
                problems.append(f"touched (content restored after a change, or rewritten): {rel}")
    for rel in sorted(now_paths - set(files)):
        problems.append(f"added: {rel}")
    if spec_projection() != manifest["spec"]:
        problems.append("changed: the board's specification (data/criteria.json row fields)")
    if platforms_projection() != manifest["platforms"]:
        problems.append("changed: data/platforms.json (apart from verification records)")
    if module_build() != manifest["srcversion"]:
        problems.append(f"changed: mxfs.ko is {module_build()!r}, the candidate is "
                        f"{manifest['srcversion']}")
    elif (ROOT / "mxfs.ko").is_file() and sha256(ROOT / "mxfs.ko") != manifest["module_sha256"]:
        # srcversion hashes the sources only: the same sources rebuilt with other flags or
        # defines keep it, so the binary itself is compared too
        problems.append("changed: mxfs.ko has the candidate's srcversion but a different binary "
                        "(sha256)")
    return problems


def cmd_create(args) -> int:
    version = (ROOT / "VERSION").read_text().strip()
    current = active()
    if current.get("state") == "RUNNING":
        sys.exit(f"release_candidate: {current['candidate']} is being qualified; end or abandon "
                 f"it first")
    # An ended attempt's orchestrator can still be running its steps: a new attempt at the same
    # version would take the runs it goes on recording as its own.
    with RUN_LOCK.open("a") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            sys.exit(f"release_candidate: a qualification is still running (it holds {RUN_LOCK}); "
                     f"freeze once it has stopped")
    build = module_build()
    if not build:
        sys.exit("release_candidate: no mxfs.ko in the tree; run make modules && make tools")
    built_for = (ROOT / "tools" / ".built_for")
    if not built_for.is_file():
        sys.exit("release_candidate: tools/.built_for is missing; run make tools")
    # A candidate is its version. Another attempt at the same version starts once the last one
    # has ended, and keeps the earlier ones in its history; grading counts only runs made after
    # the current attempt began (tools/criteria.py context_runs), so an earlier attempt's runs
    # never grade it. A version that qualified or was published is never frozen again.
    cid = version
    earlier = []
    if manifest_path(cid).is_file():
        old = load(cid)
        if old["state"] in ("RUNNING", "BLOCKED", "QUALIFIED", "PUBLISHED"):
            sys.exit(f"release_candidate: {cid} is {old['state']}; a new attempt needs it ended "
                     f"(a QUALIFIED or PUBLISHED version is never frozen again: bump VERSION)")
        earlier = list(old.get("attempts") or []) + [{
            "created": old.get("created"), "state": old.get("state"),
            "dry_run": old.get("dry_run"), "srcversion": old.get("srcversion"),
            "files": old.get("files"), "history": old.get("history"),
            "dist": old.get("dist"), "packages": old.get("packages"),
            "steps": {k: v.get("outcome") for k, v in (old.get("steps") or {}).items()}}]
    paths = frozen_paths()
    #: every frozen file is hashed; one this user cannot read would be left unfrozen
    unreadable = [rel for rel in paths
                  if not os.access(rel if os.path.isabs(rel) else ROOT / rel, os.R_OK)]
    if unreadable:
        sys.exit("release_candidate: %d frozen file(s) cannot be read, so they cannot be "
                 "frozen; make them readable first:\n  %s"
                 % (len(unreadable), "\n  ".join(unreadable)))
    files = {rel: stamp_of(rel) for rel in paths}
    digest = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    created = now()
    while earlier and created <= str(earlier[-1]["created"]):
        # two attempts frozen in one second would share a label and a grading start
        time.sleep(1)
        created = now()
    # each attempt's frozen list is kept, under the attempt's own label
    files_rel = (f"tests/evidence/candidates/"
                 f"{attempt_tag({'candidate': cid, 'created': created})}.files.json")
    manifest = {
        "candidate": cid, "version": version, "created": created, "state": "RUNNING",
        "attempts": earlier,
        "dry_run": bool(args.dry_run), "srcversion": build,
        "module_sha256": sha256(ROOT / "mxfs.ko"), "files": files_rel,
        "files_count": len(files), "files_digest": digest, "spec": spec_projection(),
        "platforms": platforms_projection(), "kernels": {}, "packages": {}, "dist": "",
        "steps": {}, "history": [{"state": "RUNNING", "at": now(), "why": "created"}],
    }
    (ROOT / files_rel).write_text(json.dumps(files, indent=1) + "\n")
    save(manifest)
    set_active(manifest)
    print(f"candidate {cid}: {len(files)} files frozen, module {build}"
          f"{' (dry run: can never be qualified or published)' if args.dry_run else ''}")
    return 0


#: The moves a candidate may make. A state outside a move's sources is refused, so a candidate
#: cannot be marked QUALIFIED by hand past its steps, nor an INVALID or ended one brought back.
MOVES = {
    "RUNNING": (),
    "BLOCKED": ("RUNNING",),
    "COMPLETE_FAILED": ("RUNNING",),
    "INVALID": ("RUNNING", "BLOCKED", "QUALIFIED"),
    "QUALIFIED": ("RUNNING",),
    "PUBLISHED": ("QUALIFIED",),
    "ABANDONED": ("RUNNING", "BLOCKED", "COMPLETE_FAILED", "INVALID", "QUALIFIED"),
}


def move(manifest: dict, state: str, why: str) -> None:
    if state not in STATES:
        sys.exit(f"release_candidate: state {state!r}; expected one of {list(STATES)}")
    if state in ("QUALIFIED", "PUBLISHED") and manifest.get("dry_run"):
        sys.exit("release_candidate: a dry-run candidate can never be qualified or published")
    if manifest["state"] not in MOVES[state]:
        sys.exit(f"release_candidate: {manifest['candidate']} is {manifest['state']}; it cannot "
                 f"become {state}")
    if state == "QUALIFIED":
        steps = manifest.get("steps") or {}
        short = [name for name, s in steps.items() if s.get("outcome") != "PASS"]
        if not steps or short or "seal" not in steps:
            sys.exit("release_candidate: QUALIFIED needs every step passed, the seal last "
                     f"(not passed: {', '.join(short) or 'no steps recorded'})")
    manifest["state"] = state
    manifest.setdefault("history", []).append({"state": state, "at": now(), "why": why})
    save(manifest)
    if active().get("candidate") == manifest["candidate"]:
        set_active(manifest)


def cmd_check(args) -> int:
    manifest = load(args.id)
    problems = drift(manifest)
    if not problems:
        print(f"candidate {args.id}: every frozen file is as it was frozen")
        return 0
    for line in problems[:200]:
        print("  " + line)
    print(f"candidate {args.id}: {len(problems)} change(s) since it was frozen")
    if manifest["state"] in ("RUNNING", "BLOCKED", "QUALIFIED"):
        move(manifest, "INVALID", f"{len(problems)} frozen file(s) changed: "
                                  + "; ".join(problems[:5]))
        print(f"candidate {args.id} is now INVALID")
    return 1


def cmd_state(args) -> int:
    manifest = load(args.id)
    move(manifest, args.state, args.why or "")
    print(f"candidate {args.id}: {args.state}")
    return 0


def cmd_abandon(args) -> int:
    manifest = load(args.id)
    move(manifest, "ABANDONED", args.why)
    print(f"candidate {args.id} abandoned")
    return 0


def cmd_show(args) -> int:
    cid = args.id or active().get("candidate")
    if not cid:
        sys.exit("release_candidate: no active candidate")
    print(json.dumps(load(cid), indent=2))
    return 0


def cmd_frozen(args) -> int:
    """For the edit hook: exit 0 when a RUNNING candidate freezes <path>, 1 when nothing does.
    Anything it cannot decide exits 2, which the hook turns into a refusal."""
    current = active()
    if current.get("state") != "RUNNING":
        return 1
    try:
        files = json.loads((ROOT / load(current["candidate"])["files"]).read_text())
    except (OSError, ValueError, KeyError):
        return 2
    path = Path(args.path).resolve()
    try:
        rel = str(path.relative_to(ROOT))
    except ValueError:
        rel = str(path)
    if rel in files or (rel.startswith("data/") and not mutable(rel)) \
            or rel == "data/criteria.json":
        print(f"frozen by candidate {current['candidate']}: {rel}")
        return 0
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    subs = ap.add_subparsers(dest="command", required=True)
    create = subs.add_parser("create", help="freeze this tree as the candidate for VERSION")
    create.add_argument("--dry-run", action="store_true",
                        help="exercise the machinery; never qualified or published")
    check = subs.add_parser("check", help="exit 1 if anything frozen changed")
    check.add_argument("id")
    show = subs.add_parser("show", help="the manifest")
    show.add_argument("id", nargs="?")
    state = subs.add_parser("state", help="move a candidate to a state")
    state.add_argument("id")
    state.add_argument("state", choices=STATES)
    state.add_argument("--why", default="")
    abandon = subs.add_parser("abandon", help="give a candidate up")
    abandon.add_argument("id")
    abandon.add_argument("--why", required=True)
    frozen = subs.add_parser("frozen", help="does a RUNNING candidate freeze this path?")
    frozen.add_argument("path")
    args = ap.parse_args()
    return {"create": cmd_create, "check": cmd_check, "show": cmd_show, "state": cmd_state,
            "abandon": cmd_abandon, "frozen": cmd_frozen}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
