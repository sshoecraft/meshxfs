#!/bin/bash
# fsx_log_pull_lap.sh -- one lap of D-FSX-FAILING-CHECK-LOG-IS-DELETED-SO-NO-FAILING-RUN-KEEPS-ITS-EVIDENCE.
#
# tests/suite/fsx.sh keeps a failing check's log on the node as /root/fsx.<seed>.<ops>.log and
# names it in the row's measured text, but the fsx row runs through run.sh's run_none, which pulled
# nothing from the node: only a cluster row (run_coord) brought a node's files into the run's
# evidence, so no failing fsx run kept its log.  The fix: run_none pulls the node's kernel log and
# the files the row left there for a row that did not pass, with the same function run_coord uses
# (pull_row_artifacts).
#
# The lap runs the fsx row through run.sh with FSX_SEED=-1: fsx prints its usage for a negative
# seed and exits non-zero, so both checks fail at once and each leaves its log.  The row is recorded
# on a scratch copy of the board (MXFS_CRIT), never on the release board: a forced failure is not a
# filesystem verdict.  MXFS_PULL_RUN_NONE passes through (0 is run.sh's switch back to no pull: the
# control).
#
#   EXPOSED  the row failed with both checks' logs named in its measured text (fsx_fail_log=...)
#   PASS     the run's evidence directory holds both logs, each with fsx's usage text in it
#   FAIL     a named log is not in the run's evidence
#   ABORT    the row did not run, or did not fail both checks (nothing to keep)
#
# Bound, derived: the row's 88 s budget (tests/suite/manifest; fsx with a bad seed exits at once)
# plus run.sh's preflight and pre-assert (20-30 s a row on 2 nodes) and the artifact pull (a few
# seconds): about 120 s, bounded at 150 s.
#
# Usage: tests/fsx_log_pull_lap.sh <label> <configuration>   (the pair formed, its group's env)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
AT=${2:?configuration}
cd "$(dirname "$0")/.." || exit 2
S=$(mktemp -d /tmp/mxfs_fsxpull.XXXXXX) || { echo "LAP fsx_pull ABORT: no scratch directory"; exit 2; }
trap 'rm -rf -- "$S"' EXIT
cp data/criteria.json "$S/criteria.json" || { echo "LAP fsx_pull ABORT: no board copy"; exit 2; }
echo "LAP fsx_pull start $(date -u +%FT%TZ) label=$LABEL at=$AT pull=${MXFS_PULL_RUN_NONE:-1}"
env -u MXFS_BATCH MXFS_CRIT="$S/criteria.json" MXFS_TEST_ENV="FSX_SEED=-1" \
    ./run.sh "$AT" fsx < /dev/null > "$S/run.out" 2>&1
grep -aE '^\s+[A-Z]+\s+fsx\b|logs: |ABORTED|^=== done' "$S/run.out" | cut -c1-300
python3 - "$S/criteria.runs.jsonl" "$AT" <<'EOF'
import json, re, sys
from pathlib import Path
ledger, at = Path(sys.argv[1]), sys.argv[2]
runs = []
if ledger.exists():
    for line in ledger.read_text().splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if item.get("kind") == "run" and item.get("row") == "fsx" and item.get("config") == at:
            runs.append(item)
if not runs:
    print("LAP fsx_pull ABORT: run.sh recorded no fsx run on the scratch board")
    sys.exit(2)
run = runs[-1]
measured = str(run.get("measured", ""))
print(f"LAP fsx_pull run={run.get('run_id')} outcome={run.get('outcome')} "
      f"evidence={run.get('evidence', '')} measured=[{measured[:240]}]")
logs = re.findall(r"fsx_fail_log=([^:\s]+):(/root/(fsx\.[^\s]+\.log))", measured)
if run.get("outcome") != "FAIL" or len(logs) < 2:
    print(f"LAP fsx_pull ABORT: the row did not fail both checks ({len(logs)} log(s) named)")
    sys.exit(2)
print("EXPOSED: the fsx row failed both checks, logs named: "
      + " ".join(f"{node}:{path}" for node, path, _ in logs))
art = Path("tests/evidence") / f"run_fsx_{run.get('run_id')}"
missing = []
for node, path, base in logs:
    kept = art / f"{node}_{base}"
    if not kept.is_file() or "usage" not in kept.read_text(errors="replace").lower():
        missing.append(str(kept))
if missing:
    print(f"LAP fsx_pull FAIL: not in the run's evidence: {' '.join(missing)}")
    sys.exit(1)
print(f"LAP fsx_pull PASS: both failing checks' logs are in {art}")
sys.exit(0)
EOF
