#!/bin/bash
# alloc_witness_abort_lap.sh -- one lap of D-ALLOC-WITNESS-RANK-ABORT-RECORDED-AS-BUDGET-EXHAUSTED:
# when one rank of tests/tooling/alloc_witness.sh aborted its own precondition, the other rank
# waited for it at the next rendezvous until the row's budget killed both, and the board recorded
# FAIL BUDGET_EXHAUSTED on both ranks with the abort nowhere in the row, and a phase census of
# `none` (run.sh reads mxfs-CCph markers the script did not write).  The fix: an aborting rank tells
# every peer at once (coord_signal_abort), every rendezvous returns the moment one has
# (aw_barrier), and each phase writes its CCph marker.
#
# The lap runs the row through run.sh on the formed pair with rank 2 made to abort right after its
# fill (AW_ABORT_RANK=2, the script's reproducer), AW_ABORT_BROADCAST passed through (0 is the
# script's own same-build control: the old waits).  The row is recorded on a scratch copy of the
# board (MXFS_CRIT), never on the release board: an injected abort is not a filesystem verdict.  The
# lap reads that scratch ledger's run and rank 2's witness record.
#
#   PASS  the row ended inside its budget, named the abort (injected_abort), and no rank was
#         recorded BUDGET_EXHAUSTED
#   FAIL  a rank was recorded BUDGET_EXHAUSTED, or the row ran to its budget
#   ABORT the row did not run or rank 2 never reached its fill (nothing measured)
#
# Exposure: rank 2's witness record (tests/evidence/alloc_witness/<run id>/rank2.txt) holds the
# injected ABORT line, written before any wait: `EXPOSED: rank2 aborted after its fill`.
#
# Bound, derived: the row's budget in tests/tooling/manifest (120 s), which run.sh enforces, plus
# run.sh's preflight and pre-assert (measured 20-30 s a row on 2 nodes): 160 s.
#
# Usage: tests/alloc_witness_abort_lap.sh <label> <configuration>   (the pair formed, its group's env)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
AT=${2:?configuration}
cd "$(dirname "$0")/.." || exit 2
S=$(mktemp -d /tmp/mxfs_awabort.XXXXXX) || { echo "LAP aw_abort ABORT: no scratch directory"; exit 2; }
trap 'rm -rf -- "$S"' EXIT
cp data/criteria.json "$S/criteria.json" || { echo "LAP aw_abort ABORT: no board copy"; exit 2; }
echo "LAP aw_abort start $(date -u +%FT%TZ) label=$LABEL at=$AT broadcast=${AW_ABORT_BROADCAST:-1}"
env -u MXFS_BATCH MXFS_CRIT="$S/criteria.json" \
    MXFS_TEST_ENV="AW_ABORT_RANK=2 AW_ABORT_BROADCAST=${AW_ABORT_BROADCAST:-1}" \
    ./run.sh "$AT" alloc_witness < /dev/null > "$S/run.out" 2>&1
rrc=$?
grep -aE '^\s+[A-Z]+\s+alloc_witness\s|ABORTED|^=== done' "$S/run.out" | cut -c1-300
python3 - "$S/criteria.runs.jsonl" "$AT" <<'EOF'
import json, sys
from pathlib import Path
ledger, at = Path(sys.argv[1]), sys.argv[2]
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
    print("LAP aw_abort ABORT: run.sh recorded no alloc_witness run on the scratch board")
    sys.exit(2)
run = runs[-1]
measured, reason = str(run.get("measured", "")), str(run.get("reason", ""))
elapsed, budget = int(run.get("elapsed_s") or 0), int(run.get("budget_s") or 0)
rank2 = Path("tests/evidence/alloc_witness") / str(run.get("run_id", "")) / "rank2.txt"
text = rank2.read_text(errors="replace") if rank2.is_file() else ""
print(f"LAP aw_abort run={run.get('run_id')} outcome={run.get('outcome')} elapsed={elapsed}s "
      f"budget={budget}s measured=[{measured[:200]}] reason=[{reason[:300]}]")
if "ABORT AW_ABORT_RANK=2" not in text:
    print(f"LAP aw_abort ABORT: rank 2's record {rank2} holds no injected abort: the lap never reached it")
    sys.exit(2)
print("EXPOSED: rank2 aborted after its fill")
exhausted = "BUDGET_EXHAUSTED" in measured or "BUDGET_EXHAUSTED" in reason
named = "injected_abort" in measured or "injected_abort" in reason
if not exhausted and named and (budget == 0 or elapsed < budget):
    print(f"LAP aw_abort PASS: the row ended in {elapsed}s of {budget}s and named the abort")
    sys.exit(0)
print(f"LAP aw_abort FAIL: budget_exhausted={int(exhausted)} abort_named={int(named)} "
      f"elapsed={elapsed}s of {budget}s")
sys.exit(1)
EOF
