#!/usr/bin/env python3
"""One lap of D-CRITERIA-INCIDENTS-AT-REFUSES-A-RELEASE-STEP-CONFIGURATION-1-ANY: the incidents
listing narrowed to the placeholder configuration a release step's run is filed under.

tools/release_run.py files most step runs (row `release:<step>`) under `1/any`, which is no
configuration of MXFS, and `tools/criteria.py incidents --at` handed its argument to parse_at,
which refused it, so the listing could not be narrowed to those runs. The lap takes the recorded
step FAIL 1/any:release:boards:2026-10-21T19:29:49Z and, in a scratch tree of its own (the copy
tests/release_step_cell_lap.py makes: the tools and everything they read or write, so nothing live
is written), stops the copy's queue naming it, then asks the copy's gate:

    EXPOSED   the unfiltered `incidents` lists the run
    PASS      `incidents --at 1/any` exits 1 and lists the run, and lists no run filed under any
              other configuration
    FAIL      `incidents --at 1/any` is refused, does not list the run, or lists a run of another
              configuration

MXFS_RELEASE_STEP_LIST=0 (tools/criteria.py) hands `1/any` to parse_at, as before the fix: the
same-build control. The lap hands its environment to every command.

Bound, derived: one scratch copy (~10 MB, measured 0.5-1.5 s in tests/release_step_cell_lap.py's
laps), the unname (one queue load and save) and two gate reads (0.3 s each on the tree of
2026-10-23): about 3 s, so a batch lap is bounded at 2x that, 6 s; each command at 20 s.

Usage: tests/release_step_incidents_at_lap.py
Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_step_cell_lap as cell_lap  # noqa: E402

RUN = "1/any:release:boards:2026-10-21T19:29:49Z"
AT = "1/any"


def gate(tree: Path, argv: list) -> subprocess.CompletedProcess:
    return cell_lap.command(tree, ["tools/criteria.py", "incidents"] + argv)


def listed_runs(out: subprocess.CompletedProcess) -> list:
    """The CONFIG:ROW:ISO keys a gate listing names, one per indented line."""
    runs = []
    for line in out.stdout.splitlines():
        if line.startswith("  ") and line.strip():
            runs.append(line.split()[0])
    return runs


def main() -> int:
    print(f"INFO MXFS_RELEASE_STEP_LIST={os.environ.get('MXFS_RELEASE_STEP_LIST') or '(unset)'}")
    match = cell_lap.KEY.fullmatch(RUN)
    found = cell_lap.live_run(match.groups()) if match else None
    if not found or found.get("outcome") != "FAIL":
        print(f"ABORT: the primary ledger holds no release step FAIL {RUN}")
        return 2
    base = Path(tempfile.mkdtemp(prefix="release_step_incidents_at_lap."))
    try:
        tree = cell_lap.scratch_tree(base / "tree")
        cell_lap.unname(tree, match.groups())
        whole = gate(tree, [])
        if whole.returncode not in (0, 1):
            print(f"ABORT: the scratch gate could not be read: rc={whole.returncode} "
                  f"{(whole.stdout + whole.stderr).strip()[-300:]}")
            return 2
        if RUN not in listed_runs(whole):
            print(f"ABORT: the scratch gate does not list {RUN}")
            return 2
        print(f"EXPOSED: the unfiltered gate lists {RUN}, a release step FAIL filed under {AT}")
        narrowed = gate(tree, ["--at", AT])
        text = (narrowed.stdout + narrowed.stderr).strip()
        runs = listed_runs(narrowed)
        print(f"INFO incidents --at {AT}: rc={narrowed.returncode}, {len(runs)} run(s) listed")
        if narrowed.returncode != 1:
            print(f"FAIL: incidents --at {AT} exited {narrowed.returncode}: {text[-300:]}")
            return 1
        if RUN not in runs:
            print(f"FAIL: incidents --at {AT} does not list {RUN}")
            return 1
        other = [r for r in runs if not r.startswith(AT + ":")]
        if other:
            print(f"FAIL: incidents --at {AT} lists {len(other)} run(s) of another configuration: "
                  + ", ".join(other[:5]))
            return 1
        print(f"PASS: incidents --at {AT} lists {RUN} and {len(runs) - 1} other {AT} run(s), "
              "none of another configuration")
        return 0
    except subprocess.TimeoutExpired as exc:
        print(f"ABORT: a command overran its {cell_lap.COMMAND_BOUND} s bound: {exc.cmd}")
        return 2
    except RuntimeError as exc:
        print(f"ABORT: {exc}")
        return 2
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
