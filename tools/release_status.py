#!/usr/bin/env python3
"""release_status.py — the release table: every configuration a release ships, and whether it is
ready, computed from the evidence each row names in data/release_table.json.

    tools/release_status.py              the table
    tools/release_status.py -v           with the reason behind every row that is not ready
    tools/release_status.py --details    with the records blocking each configuration a default
                                         install can run
    tools/release_status.py --candidate 0.90.134 --gate   graded for one release candidate;
                                         exit 1 unless every row is Ready and nothing on the
                                         default install path is blocked
    watch -n 10 tools/release_status.py

A row is one of:
    ✅ Ready             every source passes on the release build and nothing blocks it
    ⏳ In progress       a board of the row has cells marked PENDING (a run is filling them),
                         or one of its runs is live and has not printed its verdict
    ❌ Not ready: ...    the first thing in the way

Every row is a configuration the release is meant to ship.  A ❌ row holds the
release until it is Ready.  A row whose testing is in progress reads In progress whatever
else it waits on; -v still lists every reason, and once the run ends the row reads the
first of them.

What stands in the way, in the order it is reported:
  1. a release-blocking defect open for any of the row's configurations (tools/defects.py's
     own test: reaches the configuration, and its impact is not `noblock`);
  2. a board cell that is not PASS (FAIL, UNKNOWN, ...) or that was earned on another
     build (criteria.py calls that STALE);
  3. a run whose newest evidence file does not end in PASS on the release build.

The release build is this tree's mxfs.ko and VERSION. A board on hosts that build the module
against their own kernel names its build by the marker its run recorded, since its srcversion
differs from this tree's by construction; its cells must all carry that one build.

It reads the boards and the queue directly, once, so it is fast enough to watch.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
#: the table names configurations verified by a rig of their own (2/net/mesh/drbd)
os.environ.setdefault("MXFS_OWN_RIG", "1")
sys.path.insert(0, str(REPO / "tools"))
import configuration   # noqa: E402
import criteria   # noqa: E402
import defects    # noqa: E402

TABLE = REPO / "data" / "release_table.json"


def release_build() -> tuple:
    version = (REPO / "VERSION").read_text().strip()
    srcv = ""
    ko = REPO / "mxfs.ko"
    if ko.is_file():
        out = subprocess.run(["modinfo", "-F", "srcversion", str(ko)],
                             capture_output=True, text=True).stdout.strip()
        srcv = out
    return version, srcv


def board_problem(board: dict, srcv: str, crit_cache: dict, candidate: str = "") -> tuple:
    """(state, reason) for one board: state is ok | progress | bad. With a candidate, every row is
    graded on that candidate's runs; without one, on the release build."""
    config = board["config"]
    path = REPO / board.get("crit", "data/criteria.json")
    if path not in crit_cache:
        try:
            crit_cache[path] = json.loads(path.read_text()).get("criteria", [])
        except (OSError, ValueError):
            crit_cache[path] = None
    entries = crit_cache[path]
    if entries is None:
        return "bad", f"{config}: no board ({path.relative_to(REPO)})"
    want = srcv
    if board.get("build_from_marker"):
        try:
            want = json.loads((REPO / board["build_from_marker"]).read_text()).get("srcversion", "")
        except (OSError, ValueError):
            return "bad", f"{config}: no cluster marker {board['build_from_marker']}"
    rows = [e for e in entries if criteria.applies(e, config)]
    if not rows:
        return "bad", f"{config}: the board has no rows for it"
    pending, failed, unrun = [], [], []
    for entry in rows:
        mark = criteria.cell_status(entry, config, "" if candidate else want, candidate, path)
        if mark in criteria.GREEN:
            continue
        if mark == "PENDING":
            pending.append(entry["id"])
        elif mark in ("STALE", "UNKNOWN", "NOT RUN"):
            unrun.append(entry["id"])
        else:
            failed.append(f"{entry['id']} {mark}")
    if failed:
        return "fail", f"{config}: " + ", ".join(failed[:3]) + (f" (+{len(failed) - 3})" if len(failed) > 3 else "")
    if pending:
        return "progress", f"{config}: {len(pending)} row(s) running"
    if unrun:
        return "unrun", f"{config}: not run on the release build ({len(unrun)} row(s))"
    return "ok", ""


def release_builds(version: str) -> dict:
    """The release's module build per kernel (data/release_builds.json), measured on hosts."""
    try:
        return json.loads((REPO / "data" / "release_builds.json").read_text()).get(version, {})
    except (OSError, ValueError):
        return {}


def live_comms() -> set:
    """Every live process's comm. /proc/<pid>/comm never blocks on a task wedged holding its
    mmap_lock, which cmdline and ps do."""
    comms = set()
    for p in glob.glob("/proc/[0-9]*/comm"):
        try:
            comms.add(Path(p).read_text().strip())
        except OSError:
            pass
    return comms


def run_live(run: dict, version: str) -> str:
    """The log of a run of this source that is going now, or "": its process is live (by
    comm) and the newest log naming this version (and kernel) has no verdict line yet."""
    live = run.get("live")
    if not live or live["comm"] not in live_comms():
        return ""
    select = live["select"].replace("{version}", re.escape(version)).replace(
        "{kernel}", re.escape(run.get("kernel", "")))
    files = [f for f in glob.glob(str(REPO / live["glob"]))
             if re.search(select, Path(f).read_text(errors="replace"), re.M)]
    if not files:
        return ""
    newest = max(files, key=os.path.getmtime)
    if re.search(live["terminal"], Path(newest).read_text(errors="replace"), re.M):
        return ""
    return os.path.relpath(newest, REPO)


#: Set by main for a candidate: the tag its evidence files are named by (the candidate id) and
#: the module build its qualification measured on each kernel (its manifest's `kernels`).
CANDIDATE_TAG = ""
CANDIDATE_KERNELS: dict = {}


def run_problem(run: dict, version: str, srcv: str) -> tuple:
    going = run_live(run, version)
    if going:
        return "progress", f"{run['what']}: running ({going})"
    globs = run["glob"] if isinstance(run["glob"], list) else [run["glob"]]
    files = []
    for g in globs:
        files += glob.glob(str(REPO / g.replace("{version}", CANDIDATE_TAG or version)))
    files = sorted(set(files), key=os.path.getmtime)
    if run.get("kernel"):
        #: a run on hosts that build against their own kernel: the release's build for that
        #: kernel, and only the runs whose every host ran it
        want = (CANDIDATE_KERNELS if CANDIDATE_TAG else release_builds(version)).get(run["kernel"])
        if not want:
            return "unrun", f"{run['what']}: no {version} build recorded for {run['kernel']}"
        def on_release(f):
            hosts = re.findall(run["host_build"], Path(f).read_text(errors="replace"), re.M)
            return bool(hosts) and all(h == want for h in hosts)
        files = [f for f in files if on_release(f)]
        if not files:
            return "unrun", f"{run['what']}: not run on {version}"
        text = Path(files[-1]).read_text(errors="replace")
        if run.get("terminal") and not re.search(run["terminal"], text, re.M):
            #: the newest such run has not printed its verdict: it is still going
            if any(re.search(run["pass"], Path(f).read_text(errors="replace"), re.M) for f in files[:-1]):
                return "ok", ""
            return "progress", f"{run['what']}: running ({os.path.relpath(files[-1], REPO)})"
        if not re.search(run["pass"], text, re.M):
            return "bad", f"{run['what']}: last run did not pass ({os.path.relpath(files[-1], REPO)})"
        return "ok", ""
    if run.get("select"):
        #: only the runs this source is about (a kernel, say), read from the file itself
        files = [f for f in files if re.search(run["select"], Path(f).read_text(errors="replace"))]
    if not files:
        return "unrun", f"{run['what']}: not run on {version}"
    text = Path(files[-1]).read_text(errors="replace")
    if not re.search(run["pass"], text, re.M):
        return "bad", f"{run['what']}: last run did not pass ({os.path.relpath(files[-1], REPO)})"
    if run.get("build"):
        found = re.findall(run["build"], text, re.M)
        if not found or found[-1] != srcv:
            return "bad", f"{run['what']}: passed on {found[-1] if found else 'an unnamed build'}, not {srcv}"
    if run.get("version"):
        found = re.findall(run["version"], text, re.M)
        if not found or found[-1] != version:
            return "bad", f"{run['what']}: passed on {found[-1] if found else 'an unnamed version'}, not {version}"
    return "ok", ""


def platform_problem(platform: str, version: str, spec: dict, kernel: str = "") -> tuple:
    """A released platform's round in full_verify's log: the last result of each of its steps.
    With `kernel`, the steps tagged KERNEL=<another kernel> belong to another row."""
    log = REPO / spec["log"].replace("{version}", CANDIDATE_TAG or version)
    if not log.is_file():
        return "bad", f"full_verify not run on {version}"
    last = {}
    for line in log.read_text(errors="replace").splitlines():
        m = re.match(r"^=== rc=(\d+): ([a-z0-9]+): (.*) ===$", line)
        if m and m.group(2) == platform:
            tagged = re.search(r"KERNEL=(\S+)", m.group(3))
            if kernel and tagged and not tagged.group(1).startswith(kernel):
                continue
            last[m.group(3)] = int(m.group(1))
    if not any("packaged_round.sh" in step for step in last):
        return "bad", f"not in full_verify {version}"
    failed = [step for step, rc in last.items() if rc != 0]
    if failed:
        return "bad", f"{len(failed)} full_verify step(s) failed: {failed[0][:50]}"
    return "ok", ""


def defect_problem(configs: list, queue: list, platform: str = "", candidate: str = "") -> tuple:
    hits = []
    for config in configs:
        nodes, selector, platform = defects.parse_at(config + (f"@{platform}" if platform else ""))
        for entry in queue:
            if str(entry.get("impact", "")).lower() == "noblock":
                continue
            if defects.blocks(entry, nodes, selector, platform, candidate) and entry["id"] not in hits:
                hits.append(entry["id"])
    if not hits:
        return "ok", ""
    if len(hits) == 1:
        return "bad", f"open defect {hits[0]}"
    return "bad", f"{len(hits)} open release-blocking defects"


def reaching(rows: list, queue: list) -> dict:
    """Every record that reaches a row's configuration, `noblock` or not: id -> the rows it reaches."""
    hits: dict = {}
    for row in rows:
        for config in row.get("configs", []):
            nodes, selector, platform = defects.parse_at(
                config + (f"@{row['platform']}" if row.get("platform") else ""))
            for entry in queue:
                if defects.blocks(entry, nodes, selector, platform):
                    hits.setdefault(entry["id"], set()).add(f"{row['nodes']} {row['attachment']}")
    return hits


#: what a row's status is when its sources disagree: a run still filling cells is In
#: progress whatever else the row is waiting on (an open defect stays among its reasons
#: and is what it reads once the run ends); otherwise an open defect or a real failure is
#: Not ready, and a source with nothing on the release build yet is Not ready
ORDER = ("progress", "bad", "fail", "unrun", "ok")


def default_install_configs(spec_rows: list) -> list:
    """Every configuration a default install can run, at the node counts releases are verified
    at: data/release_policy.json `default_install` (the packages load the network lock manager on
    any attachment) crossed with the node counts and attachments data/release_table.json names."""
    pattern = criteria.policy().get("default_install", {}).get("pattern", "net/mesh/*")
    found = []
    for row in spec_rows:
        for config in row.get("configs", []):
            try:
                parsed = configuration.parse(config)
            except configuration.ConfigurationError:
                continue
            if configuration.matches(pattern, parsed) and config not in found:
                found.append(config)
    for config in json.loads((REPO / "data" / "configurations.json").read_text()).get(
            "released_earlier", {}):
        if config != "_" and config not in found:
            found.append(config)
    return found


def guarded(config: str, version: str, srcv: str) -> tuple:
    """(True, how) when data/guards.json names a guard for `config` whose test passed on this
    release: the package refuses that configuration and says what to use instead."""
    try:
        guards = json.loads((REPO / "data" / "guards.json").read_text()).get("guards", {})
    except (OSError, ValueError):
        return False, "no data/guards.json"
    guard = guards.get(config)
    if not guard:
        return False, "no guard"
    state, reason = run_problem(guard["test"], version, srcv)
    return state == "ok", (guard.get("what", "guard") if state == "ok" else reason)


def default_path_problems(spec_rows: list, queue: list, version: str, srcv: str,
                          candidate: str) -> list:
    """Release-blocking records that reach a configuration a default install can run, with no
    tested guard there. Each one blocks the whole release (the owner's decision, 2026-10-21):
    leaving such a configuration out of the claims does not protect the people who install the
    package with its defaults."""
    problems = []
    for config in default_install_configs(spec_rows):
        nodes, selector, platform = defects.parse_at(config)
        hits = [e["id"] for e in queue if str(e.get("impact", "")).lower() != "noblock"
                and defects.blocks(e, nodes, selector, platform, candidate)]
        if not hits:
            continue
        safe, how = guarded(config, version, srcv)
        if not safe:
            problems.append((config, hits, how))
    return problems


def row_status(row: dict, version: str, srcv: str, queue: list, crit_cache: dict,
               candidate: str = "") -> tuple:
    found = []   # (state, reason)
    found.append(defect_problem(row.get("configs", []), queue, row.get("platform", ""), candidate))
    for board in row.get("boards", []):
        found.append(board_problem(board, srcv, crit_cache, candidate))
    for run in row.get("runs", []):
        found.append(run_problem(run, version, srcv))
    found = [f for f in found if f[0] != "ok"]
    found.sort(key=lambda f: ORDER.index(f[0]))
    if not found:
        return "ok", []
    state = {"bad": "bad", "fail": "bad", "unrun": "bad", "progress": "progress"}[found[0][0]]
    return state, [reason for _, reason in found]


def table(rows: list) -> str:
    head = ("Nodes", "Storage attachment", "Status")
    widths = [max(len(head[i]), *(len(r[i]) for r in rows)) for i in range(3)]

    def line(cells):
        return "| " + " | ".join(c.ljust(w) for c, w in zip(cells, widths)) + " |"

    rule = "+" + "+".join("-" * (w + 2) for w in widths) + "+"
    return "\n".join([rule, line(head), rule] + [line(r) for r in rows] + [rule])


def table_rows(spec: dict) -> list:
    """The release table's rows: data/release_table.json's own, then one per released platform
    and kernel, listed from data/platforms.json, so a platform the release claims cannot be
    missing from the table."""
    rows = list(spec["rows"])
    rounds = spec.get("platform_rounds")
    if rounds:
        plats = json.loads((REPO / "data" / "platforms.json").read_text())
        plats = plats.get("platforms", plats)
        for key, info in (plats.items() if isinstance(plats, dict) else []):
            if not isinstance(info, dict) or info.get("status") != "released":
                continue
            name = info.get("name") or info.get("label") or key
            kernels = info.get("kernels") or [""]
            #: a platform verified on several kernels gets a row per kernel: one passing must
            #: show, whatever the other is doing
            for k in (kernels if len(kernels) > 1 else [""]):
                prefix = re.match(r"\s*([0-9]+\.[0-9]+)", k) if k else None
                label = f"{re.sub(r' *[(].*', '', name)}, kernel {prefix.group(1)}" if prefix else name
                rows.append({"nodes": "2", "attachment": f"Platform: {label} (packaged install, hung-node test)",
                             "configs": rounds["configs"], "platform": key, "_platform_round": True,
                             "_kernel": prefix.group(1) if prefix else ""})
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("-v", "--verbose", action="store_true", help="every reason behind each row")
    ap.add_argument("--defects", action="store_true",
                    help="every record that reaches a released configuration, noblock included")
    ap.add_argument("--candidate", default="",
                    help="grade every row for this release candidate (data/candidates/<id>.json)")
    ap.add_argument("--details", action="store_true",
                    help="list the release-blocking records on each configuration a default "
                         "install can run")
    ap.add_argument("--gate", action="store_true",
                    help="exit 1 unless every row is Ready and no release-blocking record reaches "
                         "a configuration a default install can run")
    args = ap.parse_args()

    spec = json.loads(TABLE.read_text())
    version, srcv = release_build()
    candidate = args.candidate
    if candidate:
        try:
            manifest = json.loads((REPO / "data" / "candidates" / f"{candidate}.json").read_text())
        except (OSError, ValueError) as exc:
            sys.exit(f"release_status: no candidate {candidate}: {exc}")
        version, srcv = manifest["version"], manifest["srcversion"]
        global CANDIDATE_TAG, CANDIDATE_KERNELS
        CANDIDATE_TAG, CANDIDATE_KERNELS = candidate, dict(manifest.get("kernels") or {})
    queue = defects.load()["defects"]
    crit_cache: dict = {}
    out, notes = [], []
    rows = table_rows(spec)
    rounds = spec.get("platform_rounds")
    if args.defects:
        #: release-blocking first, then noblock; each by severity
        rank = {s: i for i, s in enumerate(defects.SEVERITIES)}
        byid = {e["id"]: e for e in queue}
        hits = reaching(rows, queue)
        noblock = {i for i in hits if str(byid[i].get("impact", "")).lower() == "noblock"}
        for i in sorted(hits, key=lambda i: (i in noblock, rank.get(byid[i].get("severity"), 9), i)):
            e = byid[i]
            print(f"{e.get('severity', '?'):8}  {str(e.get('impact') or 'unadjudicated'):14}  "
                  f"rows={len(hits[i]):<3} {i}")
        print(f"Total: {len(hits)} records reach a released configuration: "
              f"{len(hits) - len(noblock)} block a release, {len(noblock)} marked noblock")
        return 0
    #: configurations this release leaves out (data/configurations.json released_earlier): a row
    #: made only of those is not part of the release, and says so instead of reading Not ready
    left_out = {k for k in json.loads((REPO / "data" / "configurations.json").read_text())
                .get("released_earlier", {}) if k != "_"}
    failing = 0
    for row in rows:
        if row.get("configs") and set(row["configs"]) <= left_out:
            hits = [e["id"] for e in queue if str(e.get("impact", "")).lower() != "noblock"
                    and any(defects.blocks(e, *defects.parse_at(c), candidate)
                            for c in row["configs"])]
            out.append((row["nodes"], row["attachment"],
                        f"➖ Not in {version}: {len(hits)} open release-blocking defect(s)"))
            if args.verbose and hits:
                notes.append(f"{row['nodes']} {row['attachment']}:\n  " + "\n  ".join(hits))
            continue
        state, reasons = row_status(row, version, srcv, queue, crit_cache, candidate)
        if row.get("_platform_round"):
            s, r = platform_problem(row["platform"], version, rounds, row.get("_kernel", ""))
            if s == "bad":
                if state != "bad":
                    reasons.insert(0, r)
                else:
                    reasons.append(r)
                state = "bad"
        if state == "ok":
            status = "✅ Ready"
        elif state == "progress":
            status = "⏳ In progress"
            failing += 1
        else:
            status = "❌ Not ready: " + (reasons[0] if reasons else "unknown")
            if len(status) > 70:
                status = status[:67] + "..."
            failing += 1
        out.append((row["nodes"], row["attachment"], status))
        if args.verbose and reasons:
            notes.append(f"{row['nodes']} {row['attachment']}:\n  " + "\n  ".join(reasons))
    graded = f"candidate {candidate}, " if candidate else ""
    print(f"MeshXFS {version}  ({graded}release build {srcv or 'no mxfs.ko in the tree'})")
    print(table(out))
    if notes:
        print()
        print("\n".join(notes))
    #: THE DEFAULT INSTALL PATH. A configuration left out of the claims is still run by everyone
    #: who installs the package with its defaults, so a release-blocking record that reaches it
    #: holds the whole release, unless a tested guard refuses that configuration.
    # The gate counts it either way; the list is shown only when asked for.
    blocked = default_path_problems(list(spec["rows"]), queue, version, srcv, candidate)
    if blocked and args.details:
        print()
        print("Default install path blocked (holds the whole release):")
        for config, hits, how in blocked:
            print(f"  {config}: {', '.join(hits)} ({how})")
    if args.gate:
        if failing or blocked:
            print(f"GATE: {failing} row(s) not Ready, {len(blocked)} default-install "
                  f"configuration(s) blocked")
            return 1
        print("GATE: every row Ready, and nothing blocks a default install")
    return 0


if __name__ == "__main__":
    sys.exit(main())
