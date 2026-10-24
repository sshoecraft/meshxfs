#!/usr/bin/env python3
"""One lap of D-GUARD-AUDIT-MISSES-ONE-LINE-TYPE-NAME-DEFINITIONS: which function the guard census
names for a single-node guard inside a function defined 'type name(' on one line.

tools/sole_survivor_audit.py keys each guard by (file, enclosing function), and took a function's
name only from a column-0 'name(' line, the kernel's style with the return type on the line above.
A definition written 'bool mxfs_v5_dlm_is_mds(struct mxfs_v5_dlm *ctx)' was never seen, so its
guard (dlm/v5_mount.c, 'if (mxfs_v5_dlm_is_single_node(ctx)) return true;') was keyed to
v5_boot_k_lineage, 737 lines up, and the inventory note under that key described other code. The
lap runs the audit on this tree (--csv, read only) and reads the key of every guard whose line
lies inside a one-line typed definition, found from the source itself:

    EXPOSED   the tree holds at least one census guard inside a function whose definition line is
              'type name(' (not ending in ';'), found by scanning back from the guard's line to
              the definition that opens its function body
    PASS      every such guard is keyed to the name on that definition line
    FAIL      any such guard is keyed to another name

MXFS_GUARD_TYPED_DEF=0 (tools/sole_survivor_audit.py) takes only 'name(' lines, as before the fix:
the same-build control. The lap hands its environment to the audit.

Bound, derived: one audit of the tree and reading the few source files it names; the precheck on
2026-10-24 took 0.39-0.42 s on both arms, so a batch lap is bounded at twice the longest, rounded
up to the next second, 1 s; the audit at 30 s.

Usage: tests/guard_audit_typed_def_lap.py
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import csv
import io
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEF_LINE = re.compile(r"^(?:[A-Za-z_][A-Za-z0-9_]*[\s*]+)+\**([A-Za-z_][A-Za-z0-9_]*)\s*\(")


def opening_definition(lines: list, at: int) -> tuple:
    """(line number, name, typed?) of the column-0 definition whose body holds line `at` (1-based):
    scan back to the nearest column-0 '{' and take the definition line above it."""
    i = at - 1
    while i >= 0 and not lines[i].startswith("{"):
        i -= 1
    j = i - 1
    while j >= 0 and (not lines[j] or lines[j][0].isspace()):
        j -= 1
    if j < 0:
        return None, None, False
    text = lines[j]
    # a definition whose parameters run over several lines: the name is on its first line
    k = j
    while k > 0 and "(" not in lines[k] and lines[k - 1] and not lines[k - 1].rstrip().endswith((";", "}")):
        k -= 1
    text = lines[k]
    typed = DEF_LINE.match(text)
    if typed and not text.rstrip().endswith(";"):
        return k + 1, typed.group(1), True
    bare = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(", text)
    return k + 1, (bare.group(1) if bare else None), False


def main() -> int:
    print(f"INFO MXFS_GUARD_TYPED_DEF={os.environ.get('MXFS_GUARD_TYPED_DEF') or '(unset)'}")
    try:
        out = subprocess.run([sys.executable, "tools/sole_survivor_audit.py", "--csv"], cwd=ROOT,
                             capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        print("ABORT: the audit overran its 30 s bound")
        return 2
    if out.returncode != 0:
        print(f"ABORT: the audit rc={out.returncode}: {(out.stdout + out.stderr).strip()[-200:]}")
        return 2
    rows = list(csv.DictReader(io.StringIO(out.stdout)))
    if not rows:
        print("ABORT: the audit listed no guard")
        return 2
    sources, typed, wrong = {}, [], []
    for row in rows:
        path = ROOT / row["file"]
        if row["file"] not in sources:
            sources[row["file"]] = path.read_text(errors="replace").splitlines()
        line, name, is_typed = opening_definition(sources[row["file"]], int(row["line"]))
        if not is_typed:
            continue
        typed.append(f"{row['file']}:{row['line']} in {name} (defined :{line})")
        if row["function"] != name:
            wrong.append(f"{row['file']}:{row['line']} keyed {row['function']}, defined in {name} "
                         f"(:{line})")
    print(f"INFO {len(rows)} guard(s) in the census, {len(typed)} inside a one-line typed "
          "definition")
    if not typed:
        print("ABORT: not exposed: no census guard lies inside a one-line typed definition")
        return 2
    print(f"EXPOSED: {len(typed)} census guard(s) inside a one-line typed definition: "
          + "; ".join(typed[:6]))
    if wrong:
        print(f"FAIL: {len(wrong)} of {len(typed)} keyed to another function: "
              + "; ".join(w[:160] for w in wrong[:6]))
        return 1
    print(f"PASS: all {len(typed)} keyed to the function they are defined in")
    return 0


if __name__ == "__main__":
    sys.exit(main())
