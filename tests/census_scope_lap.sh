#!/bin/bash
# census_scope_lap.sh -- one lap of D-RUN-SH-TIMEOUT-CENSUS-READS-AN-EARLIER-ROWS-PHASE-MARKER-FROM-THE-BOOTS-RING.
#
# When a row runs out its budget, run.sh's timeout census records each node's last
# `mxfs-CCph rank=N PHASE=<phase>` kernel-log line as last_phase_census[<phase>=<n>,...], `none`
# for a node with none.  It read the newest such line in the whole kernel ring, so a row whose
# ranks wrote no marker was credited with the phase an earlier row of the same boot wrote.  The
# fix: mark_row_start writes a line unique to the row into each node's kernel log, and the census
# reads only the markers after it.
#
# The lap writes `mxfs-CCph rank=0 PHASE=earlierrow` into each node's kernel log, standing in for
# an earlier row's marker on this boot, then runs alloc_witness through run.sh on the formed pair
# with the row's own markers off (AW_PHASE_MARKS=0), rank 2 made to abort right after its fill
# (AW_ABORT_RANK=2) and the abort broadcast off (AW_ABORT_BROADCAST=0), so rank 1 waits at its
# next rendezvous until the row's budget ends it and the census is taken.  The row is recorded on
# a scratch copy of the board (MXFS_CRIT), never on the release board: an injected abort is not a
# filesystem verdict.
#
#   EXPOSED  the row ran out its budget and run.sh took its census (last_phase_census in the reason)
#   PASS     every node's entry is `none`: the row wrote no marker and none is credited to it
#   FAIL     a node's entry is `earlierrow`: the census credited the row with a marker it never wrote
#   ABORT    the row did not run, rank 2 never reached its fill, the row ended before its budget,
#            or a census entry is neither (`nomark`: the row's own mark was not in the ring)
#
# The control is the fix's switch off, MXFS_CENSUS_SINCE_ROW=0 in the lap's environment, which
# run.sh inherits: the census reads the whole ring, as before.
#
# Bound, derived: the row's budget in tests/tooling/manifest (120 s), which run.sh enforces and
# which this lap runs out, plus run.sh's preflight and pre-assert (measured 20-30 s a row on 2
# nodes) and the census itself (one ssh per node, a second's sleep in each): about 160 s, bounded
# at 180 s, as tests/alloc_witness_census_lap.sh, which runs the same row the same way.
#
# Usage: tests/census_scope_lap.sh <label> <configuration>   (the pair formed, its group's env)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
AT=${2:?configuration}
cd "$(dirname "$0")/.." || exit 2
NODES=${MXFS_NODE_LIST:-test1,test2}; NODES=${NODES//,/ }
S=$(mktemp -d /tmp/mxfs_censusscope.XXXXXX) || { echo "LAP census_scope ABORT: no scratch directory"; exit 2; }
trap 'rm -rf -- "$S"' EXIT
cp data/criteria.json "$S/criteria.json" || { echo "LAP census_scope ABORT: no board copy"; exit 2; }
echo "LAP census_scope start $(date -u +%FT%TZ) label=$LABEL at=$AT nodes=$NODES census_since_row=${MXFS_CENSUS_SINCE_ROW:-1}"
for n in $NODES; do
    timeout 20 tools/mxfs_sshpass.sh "$n" "echo 'mxfs-CCph rank=0 PHASE=earlierrow' > /dev/kmsg && echo MARK-OK" \
        < /dev/null 2>/dev/null | grep -q '^MARK-OK$' || { echo "LAP census_scope ABORT: cannot mark $n's kernel log"; exit 2; }
done
env -u MXFS_BATCH MXFS_CRIT="$S/criteria.json" \
    MXFS_TEST_ENV="AW_PHASE_MARKS=0 AW_ABORT_RANK=2 AW_ABORT_BROADCAST=0" \
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
    print("LAP census_scope ABORT: run.sh recorded no alloc_witness run on the scratch board")
    sys.exit(2)
run = runs[-1]
measured, reason = str(run.get("measured", "")), str(run.get("reason", ""))
rank2 = Path("tests/evidence/alloc_witness") / str(run.get("run_id", "")) / "rank2.txt"
text = rank2.read_text(errors="replace") if rank2.is_file() else ""
print(f"LAP census_scope run={run.get('run_id')} outcome={run.get('outcome')} "
      f"elapsed={run.get('elapsed_s')}s budget={run.get('budget_s')}s reason=[{reason[:300]}]")
if "ABORT AW_ABORT_RANK=2" not in text:
    print(f"LAP census_scope ABORT: rank 2's record {rank2} holds no injected abort: the lap never reached it")
    sys.exit(2)
census = re.search(r"last_phase_census\[([^\]]*)\]", measured + " " + reason)
if not census:
    print("LAP census_scope ABORT: the row recorded no phase census (it did not run out its budget)")
    sys.exit(2)
entries = dict(item.split("=", 1) for item in census.group(1).split(",") if "=" in item)
counted = sum(int(n) for n in entries.values() if n.isdigit())
print(f"EXPOSED: the row ran out its budget and run.sh took its census: last_phase_census[{census.group(1)}]")
if "earlierrow" in entries:
    print(f"LAP census_scope FAIL: {entries['earlierrow']} of {len(nodes)} nodes credited with the earlier "
          f"row's marker, which this row never wrote (census [{census.group(1)}])")
    sys.exit(1)
if set(entries) != {"none"} or counted != len(nodes):
    print(f"LAP census_scope ABORT: the census holds an entry the lap cannot grade "
          f"([{census.group(1)}], {counted} entries for {len(nodes)} nodes)")
    sys.exit(2)
print(f"LAP census_scope PASS: no node is credited with a marker the row did not write: [{census.group(1)}]")
sys.exit(0)
EOF
