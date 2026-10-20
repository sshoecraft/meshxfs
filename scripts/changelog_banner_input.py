#!/usr/bin/env python3
"""
Print a version's CHANGELOG.md section as the input for its release banner.

    scripts/changelog_banner_input.py VERSION [CHANGELOG.md]

The banner (the release title) is written from the section a user reads: its
upgrade summary and configurations table verbatim, then the detail.  What
this drops: the section's own `##` heading (that is the banner being
written), and every paragraph of the detail that is about the test tooling or
the lab host rather than the filesystem -- a paragraph whose bold lead names a
file under tests/, scripts/ or tools/, or names the rig, a test run, a lap, a
sibling checkout or the lab host, and a removal of a defect that was in the
test tooling or the lab host itself.  The lab host's name becomes "the lab
host".
"""
import re
import sys

TOOLING_LEAD = re.compile(
    r"^\*\*(`(tests|scripts|tools)/|.*\b(rig groups?|test run|queued lap|lap whose|"
    r"sibling checkout|LUN image|lab host|blackhole test|volume audit)\b)", re.I)
TOOLING_DEFECT = re.compile(
    r"^\*\*Removed from the queue, [a-z ]+: D-(HARNESSES|CRASH-AUDIT|HOST-CLYDE|"
    r"CHK-COUNTS)", re.I)


def section(text, version):
    out, found = [], False
    for line in text.splitlines():
        if line.startswith("## "):
            if found:
                break
            if "— %s —" % version in line:
                found = True
                continue
        if found:
            out.append(line)
    return "\n".join(out) if found else None


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: changelog_banner_input.py VERSION [CHANGELOG.md]")
    version = sys.argv[1]
    path = sys.argv[2] if len(sys.argv) > 2 else "CHANGELOG.md"
    body = section(open(path, encoding="utf-8").read(), version)
    if body is None:
        sys.exit("no CHANGELOG section for %s" % version)
    kept = []
    for para in re.split(r"\n\s*\n", body):
        lead = para.lstrip()
        if TOOLING_LEAD.match(lead) or TOOLING_DEFECT.match(lead):
            continue
        kept.append(re.sub(r"\bclyde\b", "the lab host", para))
    print("\n\n".join(p.strip("\n") for p in kept if p.strip()))


if __name__ == "__main__":
    main()
