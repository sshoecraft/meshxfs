#!/usr/bin/env python3
"""Write the results tables in bench/README.md from the release boards.

    tools/bench_report.py            rewrite the tables between the markers
    tools/bench_report.py --check    exit 1 if the tables are not what the boards hold now
    tools/bench_report.py --print    print the tables and change nothing

WHY THIS EXISTS.  bench/ is where a reader looks for MeshXFS's performance.
Until 2026-10-19 it held development notes from May 2026 (an rsync bench on a
build five months gone), because nothing in a release ever refreshed it, and
readers took those notes for the current numbers.  The release boards measure
throughput on every released shared-LUN configuration; this tool copies those
measurements into the page, and tools/release_text_check.py runs --check, so a
release cannot publish a page the boards no longer agree with.

WHAT IT READS, and nothing else: data/release_table.json (which configurations
are released, what the release table calls them, which rows carry a board),
data/criteria.json (each configuration's fio_perf and fio_perf_vs_xfs results,
with the build and time of the run) and data/release_builds.json (which
release a build is).
A released configuration whose board holds no PASS for either row stops the
tool with its name: the page never shows a gap or a guess.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAGE = ROOT / "bench" / "README.md"
START = "<!-- bench_report: start (written by tools/bench_report.py from the release boards; edit the tool, not this table) -->"
END = "<!-- bench_report: end -->"

# (key in the measured strings, column heading, unit)
COLUMNS = [("seqW", "Sequential write", "MiB/s"), ("seqR", "Sequential read", "MiB/s"),
           ("randW", "Random write", "IOPS"), ("randR", "Random read", "IOPS")]


def load(rel: str) -> dict:
    return json.loads((ROOT / rel).read_text())


def figures(measured: str, unit_re: str) -> dict[str, int]:
    out = {}
    for key, _, _ in COLUMNS:
        m = re.search(rf"\b{key}=([0-9]+){unit_re}", measured)
        if m:
            out[key] = int(m.group(1))
    return out


def measured_on(entry: dict, releases: dict[str, str]) -> str:
    """Which release build ran the measurement the board holds, and when: the
    cell's own run time and build (its history holds only earlier runs)."""
    when = str(entry.get("iso") or entry.get("recorded") or "")[:10]
    build = entry.get("build", "")
    return f"{releases.get(build, build or 'unknown build')}, {when}"


def release_of_build() -> dict[str, str]:
    """{srcversion: release} from data/release_builds.json."""
    out = {}
    for version, kernels in load("data/release_builds.json").items():
        if isinstance(kernels, dict):
            for srcversion in kernels.values():
                out[srcversion] = version
    return out


def tables() -> str:
    rows = [r for r in load("data/release_table.json")["rows"] if r.get("boards")]
    crit = {c["id"]: c for c in load("data/criteria.json")["criteria"]}
    perf = crit["fio_perf"].get("per_config", {})
    vsxfs = crit["fio_perf_vs_xfs"].get("per_config", {})
    releases = release_of_build()
    groups: dict[str, list[tuple[int, str]]] = {}
    for r in rows:
        for board in r["boards"]:
            cfg = board["config"]
            groups.setdefault(r["attachment"], []).append((int(cfg.split("/")[0]), cfg))
    missing, out = [], []
    for name, cfgs in groups.items():
        out += [f"#### {name}", "",
                "| Nodes | " + " | ".join(h for _, h, _ in COLUMNS) + " | Measured |",
                "|---:|" + "---:|" * len(COLUMNS) + ":---|"]
        for nodes, cfg in sorted(cfgs):
            p, v = perf.get(cfg, {}), vsxfs.get(cfg, {})
            if p.get("status") != "PASS" or v.get("status") != "PASS":
                missing.append(f"{cfg}: fio_perf {p.get('status', 'absent')}, "
                               f"fio_perf_vs_xfs {v.get('status', 'absent')}")
                continue
            abs_ = figures(p.get("measured", ""), r"(?:MiB/s|iops)")
            pct = figures(v.get("measured", ""), "%")
            if any(k not in abs_ or k not in pct for k, _, _ in COLUMNS):
                missing.append(f"{cfg}: a figure is missing from the board's measured text")
                continue
            cells = [f"{abs_[k]:,} {unit} ({pct[k]}%)" for k, _, unit in COLUMNS]
            out.append(f"| {nodes} | " + " | ".join(cells) + f" | {measured_on(p, releases)} |")
        out.append("")
    if missing:
        for m in missing:
            print(f"bench_report: no result to publish for {m}", file=sys.stderr)
        sys.exit(2)
    return "\n".join(out).rstrip("\n") + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="exit 1 if the page is not what the boards hold")
    ap.add_argument("--print", action="store_true", help="print the tables, change nothing")
    args = ap.parse_args()

    body = tables()
    if args.print:
        sys.stdout.write(body)
        return 0
    page = PAGE.read_text()
    if page.count(START) != 1 or page.count(END) != 1 or page.index(START) > page.index(END):
        print(f"bench_report: {PAGE.relative_to(ROOT)} needs exactly one marker pair:\n  {START}\n  {END}",
              file=sys.stderr)
        return 2
    head, rest = page.split(START, 1)
    current, tail = rest.split(END, 1)
    if args.check:
        if current.strip("\n") != body.strip("\n"):
            print(f"bench_report: {PAGE.relative_to(ROOT)} does not hold the release boards' numbers; "
                  f"run tools/bench_report.py")
            return 1
        print(f"bench_report: {PAGE.relative_to(ROOT)} matches the release boards")
        return 0
    PAGE.write_text(head + START + "\n" + body + END + tail)
    print(f"bench_report: wrote {PAGE.relative_to(ROOT)} from the release boards")
    return 0


if __name__ == "__main__":
    sys.exit(main())
