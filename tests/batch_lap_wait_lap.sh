#!/bin/bash
# batch_lap_wait_lap.sh — does a batch lap's bound count only the lap's own work?
#
# WHY THIS EXISTS.  D-BATCH-LAP-BOUND-SPENDS-95S-BEFORE-PREP-UNLOGGED-IN-POOL-LOCK-OR-PREFLIGHT:
# a lap run through tools/batch_lap.py is bounded from its start, and a run.sh
# it starts waits on locks other lanes hold before its prep (the pool lock, a
# power-up, the host lock).  Lap ysc1 waited about 95 s there and overran its
# 146 s bound before its workload ran, and was recorded a FAIL.  The fix: every
# such wait is written to the lap's wait ledger (MXFS_LAP_WAIT_FILE), and
# run_bounded extends the bound by the time spent in them.
# MXFS_BATCH_LAP_WAIT_EXCLUDE=0 keeps no ledger, as before: the control.
#
# SHAPE, on the host alone (no rig node): tools/batch_lap.py's own wait_ledger
# and run_bounded run two commands under BOUND seconds each.
#   wait  a holder keeps the LUN pool's lock for HOLD_S (over BOUND) through
#         'tools/lun_pool.sh quiet sleep', and the command, 'tools/lun_pool.sh
#         quiet true', waits for it and then does nothing
#   work  the command sleeps BOUND + 5 s itself, waiting on nothing
#   EXPOSED  the wait arm's command started with BOUND s or more of the holder's
#            hold still ahead (the holder stamps when it took the lock and when
#            it let it go: a waiter ended at its bound never says how long it
#            waited)
#   PASS     the wait arm's command finished (rc 0), and the work arm's was
#            ended at its bound (rc 124): the bound still holds the lap's own work
#   FAIL     otherwise
#
# Bounds (derived): the holder takes the lock in under 1 s and holds it HOLD_S
# (20); the wait arm then needs under 1 s of its own; the work arm BOUND + 5
# killed at BOUND plus batch_lap.py's 5 s grace per signal.  The lap takes about
# HOLD_S + 2 x BOUND + 10 s; caller bound 2 x that, 100 s.  The pool lock held
# 20 s delays another lane's allocation by as much, inside its 60 s wait.
#
# Usage: batch_lap_wait_lap.sh <label>
# Env:   BOUND (10), HOLD_S (20)
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE" || exit 2
# the tree root holds run.sh and tools/criteria.py both: a draft of this lap run from a copy of
# a few files finds the tree's own library above it
while { [ ! -f run.sh ] || [ ! -f tools/criteria.py ]; } && [ "$(pwd)" != / ]; do cd ..; done
[ -f tools/criteria.py ] || { echo "ABORT: no tree root above $0"; exit 2; }
ROOT=$(pwd)
# the batch_lap.py and lun_pool.sh beside this lap's tests/ (a draft's own), else the tree's
BL=$HERE/../tools/batch_lap.py
[ -f "$BL" ] || BL=$ROOT/tools/batch_lap.py
LP=$HERE/../tools/lun_pool.sh
[ -f "$LP" ] || LP=$ROOT/tools/lun_pool.sh
POOLDIR=$(. tools/mxfs_lab.sh && lab_need paths pool) || { echo "ABORT: no pool directory in the lab file"; exit 2; }
BOUND=${BOUND:-10}
HOLD_S=${HOLD_S:-20}
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_lapwait_$LABEL
mkdir -p "$OUT"
s0=$(date +%s)
el() { echo $(( $(date +%s) - s0 )); }
echo "=== batch_lap_wait_lap label=$LABEL bound=${BOUND}s hold=${HOLD_S}s batch_lap=$BL lun_pool=$LP exclude=${MXFS_BATCH_LAP_WAIT_EXCLUDE:-1} $(date -u +%FT%TZ) ==="

bounded() {  # <log> <command...> -> prints RC= and WAITED=
    local log=$1; shift
    PYTHONPATH=$ROOT/tools python3 - "$BL" "$ROOT/$log" "$BOUND" "$ROOT" "$@" <<'EOF'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("batch_lap", sys.argv[1])
bl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bl)
log, bound, root, cmd = Path(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5:]
waits = bl.wait_ledger(log)
with log.open("w") as handle:
    rc = bl.run_bounded(cmd, root, handle, bound, waits)
print(f"RC={rc} WAITED={bl.waited_s(waits):.1f} LEDGER={waits}")
EOF
}

# ---- the wait arm
# the holder stamps when it has the lock and when it lets it go, so the wait it imposed is read
# from the holder, whether or not the waiter lived to say how long it waited
timeout $(( HOLD_S + 30 )) "$LP" quiet sh -c "date +%s.%N > $OUT/holder.start; sleep $HOLD_S; date +%s.%N > $OUT/holder.end" > "$OUT/holder.txt" 2>&1 &
hpid=$!
for i in $(seq 1 20); do [ -s "$OUT/holder.start" ] && break; sleep 0.25; done
echo "STAGE holder took the pool lock: $([ -s "$OUT/holder.start" ] && echo yes || echo no) at +$(el)s"
WSTART=$(date +%s.%N)
bounded "$OUT/wait.log" "$LP" quiet true > "$OUT/wait.txt"
wait "$hpid"
WRC=$(grep -o 'RC=[0-9]*' "$OUT/wait.txt" | cut -d= -f2)
WAITED=$(grep -o 'WAITED=[0-9.]*' "$OUT/wait.txt" | cut -d= -f2)
LOCKW=$(grep -o 'pool lock waited [0-9]* s' "$OUT/wait.log" | awk '{print $4}')
# what the holder left of its hold when the waiter started: the least the waiter had to wait
HELD_AHEAD=$(awk -v s="$(cat "$OUT/holder.start" 2>/dev/null)" -v e="$(cat "$OUT/holder.end" 2>/dev/null)" -v w="$WSTART" \
    'BEGIN { if (s == "" || e == "" || s > w) print 0; else printf "%d\n", e - w }')
echo "STAGE wait arm: rc=${WRC:-?} the holder's hold left at the waiter's start=${HELD_AHEAD}s the command's own wait line=${LOCKW:-none} ledger waited=${WAITED:-0}s at +$(el)s"
sed 's/^/    /' "$OUT/wait.log" | head -5

# ---- the work arm
bounded "$OUT/work.log" sleep $(( BOUND + 5 )) > "$OUT/work.txt"
KRC=$(grep -o 'RC=[0-9]*' "$OUT/work.txt" | cut -d= -f2)
echo "STAGE work arm: rc=${KRC:-?} at +$(el)s"

if [ "$HELD_AHEAD" -lt "$BOUND" ]; then
    echo "  the holder had ${HELD_AHEAD} s of its hold left when the waiter started, under the ${BOUND} s bound: nothing here makes the waiter wait past its bound"
    echo "RESULT: VACUOUS label=$LABEL stage=no-wait wall=$(el)s evidence=$OUT"; exit 3
fi
echo "EXPOSED: the wait arm's command started with ${HELD_AHEAD} s left of another holder's pool lock, over its ${BOUND} s bound"
fails=0
if [ "${WRC:-}" = 0 ]; then echo "  PASS the wait arm finished (rc 0): its bound counted ${WAITED}s of waiting as not its own"
else echo "  FAIL the wait arm's command was ended (rc ${WRC:-?}) while it waited on another holder's lock; its own work takes under 1 s"; fails=$((fails+1)); fi
if [ "${KRC:-}" = 124 ]; then echo "  PASS the work arm was ended at its bound (rc 124)"
else echo "  FAIL the work arm was not ended at its bound (rc ${KRC:-?})"; fails=$((fails+1)); fi
echo "LAP batch_lap_wait $( [ $fails = 0 ] && echo PASS || echo FAIL ): wait arm rc=${WRC:-?} with ${HELD_AHEAD}s of another holder's lock ahead, work arm rc=${KRC:-?}"
echo "RESULT: $( [ $fails = 0 ] && echo PASS || echo FAIL ) label=$LABEL fails=$fails wall=$(el)s evidence=$OUT"
[ $fails = 0 ]
