#!/usr/bin/env python3
"""Does the text a user reads say what the release data says?

    tools/release_text_check.py            exit 0 iff every check passes
    tools/release_text_check.py --list     the files read and the claims derived

WHY THIS EXISTS.  What is released lives in data (`data/configurations.json`: the
release matrix and the configurations verified by a rig of their own;
`data/platforms.json`; `VERSION`; `data/defects.json`).  The README, the manual
pages, the installed module-options file, the storage guide and the module's
own parameter descriptions repeat it in prose, and prose does not update
itself.  Measured on 2026-10-04, two releases after sixteen nodes shipped and
with multipath and DRBD verified: the README still called DRBD "not in any
release", `mxfs(5)` listed DRBD as unsupported and dm-multipath as not
verified, four places said the lock managers were released up to eight nodes on
one path, `modinfo` described disk/caw as "in development", and the README
quoted a defect count that was two records old.  Readers, and the tools that
read for them, concluded the released product was not ready.

WHAT IT CHECKS.  Derived from the data, never from a second list kept here:

  1. The README's "Released" table names exactly the released configurations,
     and its "Released in an earlier version" table names exactly the ones an
     earlier release claimed and this one does not, each with the version
     that verified it.
  2. The README names the tree's VERSION as the current release, in the table's
     closing sentence and in its first news heading.
  3. The count in the README's "Released: <n> configurations" heading.
  4. Every released platform's name is in the README.
  5. No public file describes a released thing as unreleased: the phrases in
     STALE below.  Each is a statement that was true once.
  6. No public file gives the released cluster sizes as a list that stops
     short of the largest one.
  7. The files that state released cluster sizes name the largest one.
  8. bench/README.md's results tables are what tools/bench_report.py writes from
     the release boards.  Until 2026-10-19 that page held development notes from
     May 2026 that no release refreshed, and readers took them for the current
     numbers.

The README no longer states how many records the defect queue holds: a count
written at release time was wrong again as soon as a record was added or
removed, so it points at the queue and the command that reads it instead.

A phrase that is right where it stands (history that names its own version, a
statement about something genuinely unreleased) is listed in ALLOWED with the
reason, by file and by the exact text of its line.  Nothing else is exempt.

WHERE IT RUNS.  Before a release candidate's packages are built, with
--before-build: checks 5-7, over the text the packages ship.  Checks 1-4 (the
README's release claims) and 8 (the benchmark page) ship in no package and are
written when the version is released, so they run at the candidate's sealing
step and again when scripts/release.sh publishes it; both stop on a failure.
tests/full_verify.sh records its result with the build's other audits.  It
reads the tree only.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# The text a user, or a tool reading for one, meets: the front page, what the
# packages install, the guides the front page sends them to, and what modinfo
# prints.  Design notes, rulings and history are not release claims.
PUBLIC = [
    "README.md",
    "bench/README.md",
    "docs/man/man5/mxfs.5",
    "docs/man/man8/chk_mxfs.8",
    "docs/man/man8/mkfs.mxfs.8",
    "docs/man/man8/mxfs_admin.8",
    "docs/man/man8/resize_mxfs.8",
    "docs/iscsi_setup.md",
    "docs/attachment-methods.md",
    "docs/mpath-verification.md",
    "packaging/mxfs-modprobe.conf",
    "packaging/mkdeb.sh",
    "packaging/mkdeb_pve.sh",
    "packaging/mkrpm.sh",
    "packaging/packaging.md",
    "frontend/proxmox/MXFSPlugin.pm",
    "frontend/proxmox/mxfs-storage.js",
]
# Source files: only their MODULE_DESCRIPTION / MODULE_PARM_DESC text is public.
MODULE_TEXT = ["dlm/v5_mount.c", "pal/linux/kern.c", "pal/linux/xfs_super.c"]

# Files that state the released cluster sizes and must name the largest.
SIZES_STATED_IN = ["README.md", "docs/man/man5/mxfs.5", "docs/iscsi_setup.md",
                   "packaging/mxfs-modprobe.conf"]

NUMBER_WORDS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                "seventeen", "eighteen", "nineteen", "twenty", "twenty-one", "twenty-two",
                "twenty-three", "twenty-four", "twenty-five", "twenty-six", "twenty-seven",
                "twenty-eight", "twenty-nine", "thirty", "thirty-one", "thirty-two"]

# (pattern, what it wrongly says).  Matched per line, case-insensitively.
STALE = [
    (r"\btrial\b", "calls something a trial; a released attachment is not one"),
    (r"not (yet )?recommended for production", "recommends against production use"),
    # A reader keeps "test data only" as the product's label long after the
    # defect that prompted it is fixed: a found defect in a published release
    # withdraws that release, it does not narrow what the product is for.
    (r"\btest data\b|\b(for|on) testing only\b|\bnot (meant |intended )?for production\b",
     "tells readers the product is for test data or not for production"),
    (r"(CAW|disk/caw)[^.\n]{0,60}\bin development\b|\bin development\b[^.\n]{0,60}(CAW|disk/caw)",
     "calls the disk/caw lock manager in development"),
    (r"\bthe released (transport|configuration)\b", "implies one lock manager is the released one"),
    (r"\b(not in|outside) the release matrix\b", "places a configuration outside the release"),
]

# How prose names an attachment.  A public file must not call a RELEASED
# attachment unverified, unsupported or unreleased; which ones are released
# comes from the data.  DRBD was released in 0.90.41, withdrawn on 2026-10-06
# and released again in 0.90.107; text that names that history by its dates and
# versions is right, and a present-tense "not released" is not.
ATTACH_WORDS = {"mpath": r"dm-multipath|multipath|\bmpath\b", "drbd": r"DRBD"}


def attach_rule(rel: list[str]) -> tuple[str, str] | None:
    names = sorted({c.split("/")[3] for c in rel} & set(ATTACH_WORDS))
    if not names:
        return None
    return (r"(" + "|".join(ATTACH_WORDS[n] for n in names) + r")[^.\n]{0,120}"
            r"\b(not verified|unverified|not supported|not released|not in any release)\b",
            "calls a released attachment (" + ", ".join(names) + ") unverified, unsupported or unreleased")

# (file, exact stripped line, reason).  The line must still be in the file: a
# stale exemption fails the check, so this list cannot outlive what it excuses.
ALLOWED: list[tuple[str, str, str]] = []


def read(rel: str) -> str:
    return (ROOT / rel).read_text(errors="replace")


def released() -> list[str]:
    d = json.loads(read("data/configurations.json"))
    own = [k for k in d.get("released_by_own_rig", {}) if k != "_"]
    return list(d["release_matrix"]) + own


def released_earlier() -> dict[str, str]:
    """{configuration: the version that verified it} for those an earlier release claimed."""
    d = json.loads(read("data/configurations.json"))
    return {k: v["verified_in"] for k, v in d.get("released_earlier", {}).items() if k != "_"}


def matrix_sizes() -> list[int]:
    d = json.loads(read("data/configurations.json"))
    return sorted({int(k.split("/")[0]) for k in d["release_matrix"]})


def module_text(rel: str) -> list[tuple[int, str]]:
    """The lines of MODULE_DESCRIPTION / MODULE_PARM_DESC statements in a source file."""
    out, inside = [], False
    for i, line in enumerate(read(rel).splitlines(), 1):
        if re.search(r"\bMODULE_(PARM_DESC|DESCRIPTION)\s*\(", line):
            inside = True
        if inside:
            out.append((i, line))
            if ");" in line:
                inside = False
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--list", action="store_true", help="print the files and the derived claims")
    #: The packages are built from a frozen release candidate BEFORE anything is verified on them.
    #: What they ship (the manual pages, the module-options file, the storage plugin, the module's
    #: own text) is checked then: checks 5-7. The README's release claims (checks 1-4) and the
    #: benchmark page (check 8) ship in no package; they are written when the version is
    #: released, from what qualification found, and checked at sealing and at publication. Asking
    #: for them before the build made every candidate fail until its README claimed a release
    #: nothing had verified yet.
    ap.add_argument("--before-build", action="store_true",
                    help="checks 5-7 only: the text the packages ship (before a candidate's "
                         "packages are built)")
    ap.add_argument("--candidate", default="",
                    help="check 8 against this release candidate's runs")
    args = ap.parse_args()

    fails: list[str] = []
    rel = released()
    sizes = matrix_sizes()
    top = sizes[-1]
    version = read("VERSION").strip()
    readme = read("README.md")

    if not args.before_build:
        readme_claims(readme, rel, version, fails)

    # 5 and 6. stale phrases
    allowed_seen = set()
    short = [n for n in sizes if n < top]
    word = lambda n: NUMBER_WORDS[n]
    stops_short = []
    if len(short) >= 2:
        a, b = short[:-1], short[-1]
        stops_short = [
            ", ".join(word(n) for n in a) + " and " + word(b),
            ", ".join(str(n) for n in a) + " and " + str(b),
            ", ".join(f"{n}-" for n in a) + f" and {b}-node",
        ]
    texts = [(f, list(enumerate(read(f).splitlines(), 1))) for f in PUBLIC if (ROOT / f).exists()]
    texts += [(f, module_text(f)) for f in MODULE_TEXT if (ROOT / f).exists()]
    stale = STALE + [r for r in [attach_rule(rel)] if r]
    for f, lines in texts:
        for i, line in lines:
            hit = None
            for pat, why in stale:
                if re.search(pat, line, re.I):
                    hit = why
                    break
            if not hit:
                low = line.lower()
                for s in stops_short:
                    if s in low and str(top) not in low and word(top) not in low:
                        hit = f"lists the released cluster sizes and stops at {short[-1]}; {top} is released"
                        break
            if not hit:
                continue
            # a line that names a configuration the data does not release is
            # talking about that configuration (`32/disk/caw/mpath ... not released`)
            keys = re.findall(r"\b\d+/[a-z]+/[a-z]+/[a-z][a-z0-9]*\b", line)
            if keys and any(k not in rel for k in keys):
                continue
            ok = [a for a in ALLOWED if a[0] == f and a[1] == line.strip()]
            if ok:
                allowed_seen.add((f, ok[0][1]))
                continue
            fails.append(f"{f}:{i}: {hit}: {line.strip()[:150]}")
    for f, text, _ in ALLOWED:
        if (f, text) not in allowed_seen:
            fails.append(f"tools/release_text_check.py: the exemption for {f} ('{text[:60]}...') "
                         f"matches no line any more; remove it")

    # 7. the largest released size is named where sizes are stated
    for f in SIZES_STATED_IN:
        t = read(f).lower()
        if not re.search(rf"\b{top}\b|\b{word(top)}\b", t):
            fails.append(f"{f}: states released cluster sizes and never names {top}")

    # 8. the benchmark page holds the release boards' numbers
    if not args.before_build:
        bench = subprocess.run([sys.executable, str(ROOT / "tools/bench_report.py"), "--check"]
                               + (["--candidate", args.candidate] if args.candidate else []),
                               capture_output=True, text=True)
        if bench.returncode != 0:
            fails.append("bench/README.md: " + (bench.stdout + bench.stderr).strip().replace("\n", "; "))

    if args.list:
        print("released:", " ".join(rel))
        print("version:", version)
        print("files:", " ".join(f for f, _ in texts))
    for line in fails:
        print("FAIL", line)
    print(f"release_text_check: {len(fails)} failure(s) over {len(texts)} files, "
          f"{len(rel)} released configurations, version {version}"
          f"{' (before the build: checks 5-7)' if args.before_build else ''}")
    return 1 if fails else 0


def readme_claims(readme: str, rel: list, version: str, fails: list) -> None:
    """Checks 1-4: what the README claims for this release."""
    # 1. the Released table
    section = readme.split("### Released", 1)[1].split("###", 1)[0] if "### Released" in readme else ""
    rows = re.findall(r"^> \| `(\d+/[a-z]+/[a-z]+/[a-z][a-z0-9]*)` \|", section, re.M)
    for c in rel:
        if c not in rows:
            fails.append(f"README.md: the Released table has no row for {c}")
    for c in rows:
        if c not in rel:
            fails.append(f"README.md: the Released table lists {c}, which the release data does not")
    earlier = released_earlier()
    head = "### Released in an earlier version"
    section = readme.split(head, 1)[1].split("###", 1)[0] if head in readme else ""
    rows = dict(re.findall(r"^> \| `(\d+/[a-z]+/[a-z]+/[a-z][a-z0-9]*)` \| ([0-9]+\.[0-9]+\.[0-9]+) \|", section, re.M))
    for c, v in earlier.items():
        if rows.get(c) != v:
            fails.append(f"README.md: the '{head[4:]}' table gives {c} as {rows.get(c, 'nothing')}; "
                         f"the release data says {v}")
    for c in rows:
        if c not in earlier:
            fails.append(f"README.md: the '{head[4:]}' table lists {c}, which the release data does not")

    # 2. the current release
    m = re.search(r"verified on the current release, ([0-9.]+[0-9])", readme)
    if not m or m.group(1) != version:
        fails.append(f"README.md: 'verified on the current release, <v>' says "
                     f"{m.group(1) if m else 'nothing'}; VERSION is {version}")
    m = re.search(r"^> ## ([0-9]+\.[0-9]+\.[0-9]+):", readme, re.M)
    if not m or m.group(1) != version:
        fails.append(f"README.md: the first news heading is for {m.group(1) if m else 'no version'}; "
                     f"VERSION is {version}")

    # 3. the count in the heading
    m = re.search(r"^> ## .*Released: ([a-z-]+|\d+) configurations", readme, re.M)
    want = NUMBER_WORDS[len(rel)] if len(rel) < len(NUMBER_WORDS) else str(len(rel))
    if not m or m.group(1) not in (want, str(len(rel))):
        fails.append(f"README.md: the 'Released: <n> configurations' heading says "
                     f"{m.group(1) if m else 'nothing'}; the data has {len(rel)} ({want})")

    # 4. released platforms
    plats = json.loads(read("data/platforms.json"))
    plats = plats.get("platforms", plats)
    for key, p in plats.items():
        if isinstance(p, dict) and p.get("status") == "released":
            name = re.split(r"\s*\(", p.get("name", key))[0].split(" / ")[0].strip()
            if name and name not in readme:
                fails.append(f"README.md: released platform '{name}' ({key}) is not named")


if __name__ == "__main__":
    sys.exit(main())
