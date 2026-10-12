#!/usr/bin/env python3
"""rule_rename.py — replace numbered rule citations (RULE 0, RULE-4, RULES 0, 2c
and 6) across the tree with the rule's name, as CLAUDE.md now names its rules:
`RULE: TIMEOUTS ARE PERFORMANCE ASSERTIONS, NOT SAFETY NETS`.

Usage: tools/rule_rename.py [--apply]
  Without --apply: prints, per file, how many citations would change and a few
  before/after samples, then the total.  With --apply: writes them.

What it never touches:
  - CLAUDE.md (its headings are the names; edited by hand) and CLAUDE.md.fable
  - data/derule-journal.txt (the record of an earlier sweep's old text)
  - .ccmemory/MEMORY.md (generated from each memory's description)
  - dlm/disklock.{c,h,md}: their lowercase "rule 3" / "rule 6" are the disklock
    protocol's own rules (only uppercase RULE is matched anyway)
  - identifiers such as RULE0_CALIBRATE: a citation needs a space or hyphen
    between RULE and its number
  - .git, tests/evidence, .ccloop/runs, dist, .claude/worktrees, *.backup*
    copies, NFS silly-rename files, and this file

data/defects.json is rewritten through tools/defects.py's own lock, load() and
save(): that tool is the queue's only writer.
"""
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

NAMES = {
    "0": "TIMEOUTS ARE PERFORMANCE ASSERTIONS, NOT SAFETY NETS",
    "1": "NEVER DOWNLOAD THE LINUX KERNEL SOURCE",
    "2": "NEVER REBOOT THE LAB HOST",
    "2b": "NEVER RUN A COMMAND THAT CAN TRIGGER A PERMISSION PROMPT",
    "2c": "NEVER WEDGE THE LAB HOST",
    "2d": "NEVER RUN THE RIG ON AN UNGUARDED HOST",
    "3": "A SCRIPT IS NEVER A TEMP FILE",
    "4": "TROUBLESHOOTING IS A LOOP, NOT A GUESS",
    "5": "CONSULT ANOTHER MODEL WHEN STUCK",
    "6": "ZERO ACCEPTED KNOWN DEFECTS",
    "7": "INSPECT WITH THE RIGHT TOOL",
    "8": "ZERO ACCEPTED KNOWN DEFECTS",
    "9": "THE POOL METERS REQUESTS",
    "10": "DELEGATE ITERATIVE GRIND",
}

# A rule renamed after its citations were written: the old name is replaced
# wherever it was cited.
RENAMED = {
    "RULE: NEVER REBOOT CLYDE": "RULE: NEVER REBOOT THE LAB HOST",
    "RULE: NEVER RUN A COMMAND THAT CAN WEDGE CLYDE UNKILLABLY": "RULE: NEVER WEDGE THE LAB HOST",
}

NUM = r"(?:10|[0-9])[bcd]?"
END = r"(?![0-9A-Za-z_])"
# RULES 0, 2c and 6 / RULES 0 and 2c / RULES 2b/2c
PLURAL = re.compile(r"\bRULES (" + NUM + r"(?:(?:, and |, | and | or | & |/)" + NUM + r")+)" + END)
# RULE 0 / RULE-4 / RULE 2b/2c
SINGLE = re.compile(r"\bRULE[- ](" + NUM + r"(?:/" + NUM + r")*)" + END)
SEP = re.compile(r"(, and |, | and | or | & |/)")

SKIP_DIRS = {".git", "dist", "worktrees", "__pycache__"}
SKIP_FILES = {"CLAUDE.md", "CLAUDE.md.fable", "derule-journal.txt", "rule_rename.py"}
# ccloop's per-session run records and the rig's evidence: records of what was
# said and measured at the time, not the project's text
SKIP_TREES = {ROOT / "tests" / "evidence", ROOT / ".ccloop" / "runs"}
SKIP_PATHS = {
    ROOT / ".ccmemory" / "MEMORY.md",
    ROOT / "data" / "defects.json",
    ROOT / "dlm" / "disklock.c",
    ROOT / "dlm" / "disklock.h",
    ROOT / "dlm" / "disklock.md",
}


def name(num: str) -> str:
    return "RULE: " + NAMES[num]


def expand(group: str) -> str:
    """'0, 2c and 6' -> 'RULE: A, RULE: B and RULE: C' (separators kept)."""
    parts = SEP.split(group)
    return "".join(p if SEP.fullmatch(p) else name(p) for p in parts)


def rename(text: str) -> tuple:
    count = 0

    def plural(m):
        nonlocal count
        count += 1
        return expand(m.group(1))

    def single(m):
        nonlocal count
        count += 1
        return expand(m.group(1))

    text = PLURAL.sub(plural, text)
    text = SINGLE.sub(single, text)
    for old, new in RENAMED.items():
        count += text.count(old)
        text = text.replace(old, new)
    return text, count


def tree_files():
    for dirpath, dirnames, filenames in os.walk(ROOT):
        here = Path(dirpath)
        dirnames[:] = [d for d in dirnames
                       if d not in SKIP_DIRS and (here / d) not in SKIP_TREES]
        for f in filenames:
            p = here / f
            if (f in SKIP_FILES or f.startswith(".nfs") or ".backup" in f
                    or p in SKIP_PATHS or p.is_symlink()):
                continue
            yield p


def samples(old: str, new: str, limit: int = 2) -> list:
    out = []
    for a, b in zip(old.splitlines(), new.splitlines()):
        if a != b:
            out.append((a.strip()[:160], b.strip()[:200]))
            if len(out) >= limit:
                break
    return out


def walk_strings(obj, fn):
    if isinstance(obj, str):
        return fn(obj)
    if isinstance(obj, list):
        return [walk_strings(v, fn) for v in obj]
    if isinstance(obj, dict):
        return {k: walk_strings(v, fn) for k, v in obj.items()}
    return obj


def main() -> int:
    apply = "--apply" in sys.argv[1:]
    total = files = 0
    for p in sorted(tree_files()):
        try:
            old = p.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        new, n = rename(old)
        if not n:
            continue
        total += n
        files += 1
        print(f"{n:5d}  {p.relative_to(ROOT)}")
        for a, b in samples(old, new):
            print(f"         - {a}\n         + {b}")
        if apply:
            p.write_text(new)

    import defects
    if apply:
        defects.take_lock()
    data = defects.load()
    qcount = 0

    def fn(s):
        nonlocal qcount
        t, n = rename(s)
        qcount += n
        return t

    renamed = walk_strings(data, fn)
    if qcount:
        print(f"{qcount:5d}  data/defects.json (through tools/defects.py)")
        total += qcount
        files += 1
        if apply:
            defects.save(renamed)
    print(f"{'applied' if apply else 'would change'}: {total} citations in {files} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
