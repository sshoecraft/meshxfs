#!/bin/bash
# alloc_witness_census_lap.sh -- one lap of D-ALLOC-WITNESS-WROTE-NO-PHASE-MARKER-SO-A-TIMED-OUT-ROW-CENSUS-READS-NONE.
#
# When a row runs out its budget, run.sh's timeout census reads each node's last
# `mxfs-CCph rank=N PHASE=<phase>` kernel-log line and records last_phase_census[<phase>=<n>,...]
# in the row's reason, `none` for a node that wrote no marker.  tests/tooling/alloc_witness.sh
# wrote none, so its timed-out runs recorded last_phase_census[none=2] and kept no phase of the
# ranks the budget killed.  The fix: ccph() writes a marker as each phase starts.
#
# The lap runs the row through run.sh on the formed pair with rank 2 made to abort right after its
# fill (AW_ABORT_RANK=2) and the abort broadcast off (AW_ABORT_BROADCAST=0, the script's old
# waits), so rank 1 waits at its next rendezvous until the row's budget ends it and the census is
# taken.  The row is recorded on a scratch copy of the board (MXFS_CRIT), never on the release
# board: an injected abort is not a filesystem verdict.
#
# run.sh's census reads each node's newest CCph line in the whole kernel ring, so an earlier row's
# marker on the same boot would stand in for this row's
# (D-RUN-SH-TIMEOUT-CENSUS-READS-AN-EARLIER-ROWS-PHASE-MARKER-FROM-THE-BOOTS-RING).  The lap first
# writes `mxfs-CCph rank=0 PHASE=lapmark` on each node, so a row that writes no marker of its own
# is read as `lapmark`, whatever earlier rows left.
#
#   EXPOSED  the row ran out its budget and run.sh took its census (last_phase_census in the reason)
#   PASS     the census names a phase of the row for every node, none of them `none` or `lapmark`
#   FAIL     a node's entry is `none` or `lapmark`: a rank the budget killed left no phase
#   ABORT    the row did not run, rank 2 never reached its fill, or the row ended before its
#            budget (no census, nothing measured)
#
# The control is the fix's switch off, AW_PHASE_MARKS=0 in the lap's environment, which the lap
# passes to the row's ranks: ccph() then writes no marker, as before the fix.
#
# Bound, derived: the row's budget in tests/tooling/manifest (120 s), which run.sh enforces and
# which this lap runs out, plus run.sh's preflight and pre-assert (measured 20-30 s a row on 2
# nodes) and the census itself (one ssh per node, a second's sleep in each): about 160 s, bounded
# at 180 s.
#
# Usage: tests/alloc_witness_census_lap.sh <label> <configuration>   (the pair formed, its group's env)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
AT=${2:?configuration}
cd "$(dirname "$0")/.." || exit 2
NODES=${MXFS_NODE_LIST:-test1,test2}; NODES=${NODES//,/ }
S=$(mktemp -d /tmp/mxfs_awcensus.XXXXXX) || { echo "LAP aw_census ABORT: no scratch directory"; exit 2; }
trap 'rm -rf -- "$S"' EXIT
cp data/criteria.json "$S/criteria.json" || { echo "LAP aw_census ABORT: no board copy"; exit 2; }
echo "LAP aw_census start $(date -u +%FT%TZ) label=$LABEL at=$AT nodes=$NODES"
for n in $NODES; do
    timeout 20 tools/mxfs_sshpass.sh "$n" "echo 'mxfs-CCph rank=0 PHASE=lapmark' > /dev/kmsg && echo MARK-OK" \
        < /dev/null 2>/dev/null | grep -q '^MARK-OK$' || { echo "LAP aw_census ABORT: cannot mark $n's kernel log"; exit 2; }
done
env -u MXFS_BATCH MXFS_CRIT="$S/criteria.json" \
    MXFS_TEST_ENV="AW_ABORT_RANK=2 AW_ABORT_BROADCAST=0${AW_PHASE_MARKS:+ AW_PHASE_MARKS=$AW_PHASE_MARKS}" \
    ./run.sh "$AT" alloc_witness < /dev/null > "$S/run.out" 2>&1
grep -aE '^\s+[A-Z]+\s+alloc_witness\s|ABORTED|^=== done' "$S/run.out" | cut -c1-300
python3 - "$S/criteria.runs.jsonl" "$AT" $NODES <<'EOF'
import json, re, sys
from pathlib import Path
ledger, at, nodes = Path(sys.argv[1]), sys.argv[2], sys.argv[3:]
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
    print("LAP aw_census ABORT: run.sh recorded no alloc_witness run on the scratch board")
    sys.exit(2)
run = runs[-1]
measured, reason = str(run.get("measured", "")), str(run.get("reason", ""))
rank2 = Path("tests/evidence/alloc_witness") / str(run.get("run_id", "")) / "rank2.txt"
text = rank2.read_text(errors="replace") if rank2.is_file() else ""
print(f"LAP aw_census run={run.get('run_id')} outcome={run.get('outcome')} "
      f"elapsed={run.get('elapsed_s')}s budget={run.get('budget_s')}s reason=[{reason[:300]}]")
if "ABORT AW_ABORT_RANK=2" not in text:
    print(f"LAP aw_census ABORT: rank 2's record {rank2} holds no injected abort: the lap never reached it")
    sys.exit(2)
census = re.search(r"last_phase_census\[([^\]]*)\]", measured + " " + reason)
if not census:
    print("LAP aw_census ABORT: the row recorded no phase census (it did not run out its budget)")
    sys.exit(2)
entries = dict(item.split("=", 1) for item in census.group(1).split(",") if "=" in item)
counted = sum(int(n) for n in entries.values() if n.isdigit())
print(f"EXPOSED: the row ran out its budget and run.sh took its census: last_phase_census[{census.group(1)}]")
if "none" in entries or "lapmark" in entries or counted != len(nodes):
    unmarked = int(entries.get("none", "0")) + int(entries.get("lapmark", "0"))
    print(f"LAP aw_census FAIL: {unmarked} of {len(nodes)} nodes left no phase of the row "
          f"(census [{census.group(1)}], {counted} entries for {len(nodes)} nodes)")
    sys.exit(1)
print(f"LAP aw_census PASS: every node's rank left its phase: [{census.group(1)}]")
sys.exit(0)
EOF
