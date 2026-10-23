#!/bin/bash
# fsx_tmp_log_lap.sh -- one lap of D-FSX-SH-SENT-FSX-OUTPUT-TO-A-TMP-LOG-ITS-EXIT-TRAP-DELETED.
#
# tests/suite/fsx.sh sent fsx's output to /tmp/fsx.$$.*.log on the node and deleted it in its EXIT
# trap, so a failing check's log did not survive the row on the node for any pull to collect.  The
# fix keeps a failing check's log as /root/fsx.<seed>.<ops>.log and names it in the row's measured
# text.  This lap reads the node, not the pull (run.sh's pull is its own fix, with its own lap,
# tests/fsx_log_pull_lap.sh), and depends on nothing the fix adds: neither the log's name nor its
# fsx_fail_log entry in the measured text.
#
# The lap marks the row's node (the first of MXFS_NODE_LIST, as run.sh takes it; test1 by
# default), then runs the fsx row through run.sh with FSX_SEED=-1 on a scratch copy of the board
# (MXFS_CRIT), never on the release board: fsx prints its usage for a negative seed and exits
# non-zero, so both checks fail at once.  Then it lists the files on that node, in /root and /tmp,
# written after the mark that hold fsx's usage text: each is a failing check's output that
# survived the row.
#
#   EXPOSED  the row failed both of its checks (the suite library's own failed=2)
#   PASS     the node holds a surviving file of fsx's output for each failed check
#   FAIL     fewer survive: the row deleted a failing check's output
#   ABORT    the row did not run, did not fail both checks, or the node could not be read
#
# The control is the candidate's source with only the fix reverted in tests/suite/fsx.sh
# (tools/harness_batch.py control --revert), so the lap reads the node as the old fsx.sh left it.
#
# Bound, derived: the row's 88 s budget (tests/suite/manifest; fsx with a bad seed exits at once)
# plus run.sh's preflight, pre-assert and artifact pull (20-30 s a row on 2 nodes) and three ssh
# calls to the node (a second or two each): about 120 s, bounded at 150 s.
#
# Usage: tests/fsx_tmp_log_lap.sh <label> <configuration>   (the pair formed, its group's env)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
AT=${2:?configuration}
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
NODE=$(echo "${MXFS_NODE_LIST:-test1}" | tr ',' ' ' | awk '{print $1}')
MARK="/root/.fsx_tmp_log_lap.$$"
S=$(mktemp -d /tmp/mxfs_fsxtmp.XXXXXX) || { echo "LAP fsx_tmp ABORT: no scratch directory"; exit 2; }
trap 'rm -rf -- "$S"; timeout 20 "$SSH" "$NODE" "rm -f $MARK" > /dev/null 2>&1' EXIT
cp data/criteria.json "$S/criteria.json" || { echo "LAP fsx_tmp ABORT: no board copy"; exit 2; }
echo "LAP fsx_tmp start $(date -u +%FT%TZ) label=$LABEL at=$AT node=$NODE"
timeout 20 "$SSH" "$NODE" "touch $MARK && echo MARK-OK" 2>/dev/null | grep -q '^MARK-OK$' \
    || { echo "LAP fsx_tmp ABORT: cannot mark $NODE"; exit 2; }
env -u MXFS_BATCH MXFS_CRIT="$S/criteria.json" MXFS_TEST_ENV="FSX_SEED=-1" \
    ./run.sh "$AT" fsx < /dev/null > "$S/run.out" 2>&1
grep -aE '^\s+[A-Z]+\s+fsx\b|ABORTED|^=== done' "$S/run.out" | cut -c1-300
REMOTE="find /root /tmp -maxdepth 1 -type f -newer $MARK 2>/dev/null | while read -r f; do grep -qs 'usage: fsx' \"\$f\" && echo \"KEPT \$f\"; done; echo READ-OK"
timeout 20 "$SSH" "$NODE" "$REMOTE" > "$S/kept" 2>/dev/null
python3 - "$S/criteria.runs.jsonl" "$AT" "$NODE" "$S/kept" <<'EOF'
import json, re, sys
from pathlib import Path
ledger, at, node, kept = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4])
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
    print("LAP fsx_tmp ABORT: run.sh recorded no fsx run on the scratch board")
    sys.exit(2)
run = runs[-1]
measured = str(run.get("measured", ""))
print(f"LAP fsx_tmp run={run.get('run_id')} outcome={run.get('outcome')} measured=[{measured[:240]}]")
failed = re.search(r"\bfailed=(\d+)\b", measured)
if run.get("outcome") != "FAIL" or not failed or int(failed.group(1)) < 2:
    print("LAP fsx_tmp ABORT: the row did not fail both checks "
          f"(failed={failed.group(1) if failed else '?'})")
    sys.exit(2)
lines = kept.read_text(errors="replace").splitlines() if kept.exists() else []
if "READ-OK" not in lines:
    print(f"LAP fsx_tmp ABORT: {node} could not be read after the row")
    sys.exit(2)
print(f"EXPOSED: the fsx row failed both checks (failed={failed.group(1)}) on {node}")
survived = [line.split(" ", 1)[1] for line in lines if line.startswith("KEPT ")]
print(f"LAP fsx_tmp survived on {node}: {' '.join(survived) or 'none'}")
if len(survived) < int(failed.group(1)):
    print(f"LAP fsx_tmp FAIL: {len(survived)} of {failed.group(1)} failed checks' fsx output "
          f"survived the row on {node}")
    sys.exit(1)
print(f"LAP fsx_tmp PASS: each failed check's fsx output survived the row on {node}")
sys.exit(0)
EOF
