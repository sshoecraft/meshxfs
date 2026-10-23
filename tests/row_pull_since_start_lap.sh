#!/bin/bash
# row_pull_since_start_lap.sh -- one lap of D-DIRENT-DURABILITY-CAPTURE-COPIES-STALE-DMESG-AT-FAIL-FROM-EARLIER-BOOTS.
#
# A cluster row that did not pass pulls each node's /root/drc_* captures and fsx logs into its
# evidence directory (run.sh pull_row_artifacts).  The nodes keep those files across rows and
# boots, and the pull took every one by name, so run_dirent_durability_20261019T191246Z-g8 carried
# dmesg_at_fail.txt copies of July and August boots, one with an old build's corruption line,
# beside that run's own kernel logs.  The fix: each node stamps the row's start on its own clock
# (mark_row_start) and the pull takes only files written after it.
#
# The lap plants on each node a capture as an earlier boot left one,
# /root/drc_blkdump_planted_<label>/dmesg_at_fail.txt dated 2026-07-26, then runs a cluster row
# made to fail at once: alloc_witness with rank 2 aborting after its fill (AW_ABORT_RANK=2), which
# ends in about a second with the abort named.  The row is recorded on a scratch copy of the board
# (MXFS_CRIT), never on the release board.  MXFS_PULL_SINCE_ROW passes through (0 is run.sh's
# switch back to the pull by name: the control).  The planted directories are removed at the end.
#
#   EXPOSED  every node held the planted capture when the row started, and the row's pull ran (its
#            evidence directory holds the nodes' kernel logs)
#   PASS     no planted capture is in the run's evidence
#   FAIL     a planted capture was copied into the run's evidence
#   ABORT    a capture could not be planted, the row did not fail, or its pull left no directory
#
# Bound, derived: planting and removing ~10 s; the row (rank 2 aborts after its fill: ~25 s
# measured with the abort broadcast, 120 s budget without it) plus run.sh's preflight and
# pre-assert (20-30 s) and the pull: about 170 s at worst, bounded at 200 s.
#
# Usage: tests/row_pull_since_start_lap.sh <label> <configuration>   (the pair formed, its group's env)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
AT=${2:?configuration}
cd "$(dirname "$0")/.." || exit 2
NODES=${MXFS_NODE_LIST:-test1,test2}; NODES=${NODES//,/ }
PL=drc_blkdump_planted_$LABEL
S=$(mktemp -d /tmp/mxfs_rowpull.XXXXXX) || { echo "LAP row_pull ABORT: no scratch directory"; exit 2; }
unplant() {
    local n
    for n in $NODES; do
        timeout 20 tools/mxfs_sshpass.sh "$n" "rm -rf /root/$PL" < /dev/null > /dev/null 2>&1
    done
    rm -rf -- "$S"
}
trap unplant EXIT
cp data/criteria.json "$S/criteria.json" || { echo "LAP row_pull ABORT: no board copy"; exit 2; }
for n in $NODES; do
    p=$(timeout 20 tools/mxfs_sshpass.sh "$n" "mkdir -p /root/$PL && echo 'PLANTED $LABEL: a capture an earlier boot left' > /root/$PL/dmesg_at_fail.txt && touch -d '2026-07-26 12:00:00' /root/$PL/dmesg_at_fail.txt /root/$PL && stat -c '%y' /root/$PL/dmesg_at_fail.txt" < /dev/null 2>/dev/null | grep -a '^2026-07-26' | tail -1)
    [ -n "$p" ] || { echo "LAP row_pull ABORT: could not plant the capture on $n"; exit 2; }
done
echo "LAP row_pull start $(date -u +%FT%TZ) label=$LABEL at=$AT since_row=${MXFS_PULL_SINCE_ROW:-1} planted=/root/$PL on $NODES"
env -u MXFS_BATCH MXFS_CRIT="$S/criteria.json" MXFS_TEST_ENV="AW_ABORT_RANK=2" \
    ./run.sh "$AT" alloc_witness < /dev/null > "$S/run.out" 2>&1
grep -aE '^\s+[A-Z]+\s+alloc_witness\b|logs: |ABORTED|^=== done' "$S/run.out" | cut -c1-300
python3 - "$S/criteria.runs.jsonl" "$AT" "$PL" $NODES <<'EOF'
import json, sys
from pathlib import Path
ledger, at, planted, nodes = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4:]
runs = []
if ledger.exists():
    for line in ledger.read_text().splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if item.get("kind") == "run" and item.get("row") == "alloc_witness" and item.get("config") == at:
            runs.append(item)
if not runs:
    print("LAP row_pull ABORT: run.sh recorded no alloc_witness run on the scratch board")
    sys.exit(2)
run = runs[-1]
art = Path("tests/evidence") / f"run_alloc_witness_{run.get('run_id')}"
print(f"LAP row_pull run={run.get('run_id')} outcome={run.get('outcome')} evidence={run.get('evidence', '')}")
if run.get("outcome") == "PASS":
    print("LAP row_pull ABORT: the row passed, so it pulled nothing")
    sys.exit(2)
kern = [n for n in nodes if (art / f"kernlog_{n}.gz").is_file()]
if len(kern) != len(nodes):
    print(f"LAP row_pull ABORT: the row's pull left kernel logs of {kern} of {nodes} in {art}")
    sys.exit(2)
print(f"EXPOSED: every node held /root/{planted} from 2026-07-26 and the row's pull ran ({art})")
copied = sorted(str(p) for p in art.glob(f"*_{planted}*"))
if copied:
    print(f"LAP row_pull FAIL: the earlier boot's capture was copied into the run's evidence: {' '.join(copied)}")
    sys.exit(1)
print(f"LAP row_pull PASS: no capture older than the row is in {art}")
sys.exit(0)
EOF
