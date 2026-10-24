#!/bin/bash
# lap_bounded_lap.sh — does a lap's own step bound count only its own work, and
# is nothing the step started left holding a lock once the bound has ended it?
#
# WHY THIS EXISTS.  D-BATCH-LAP-BOUND-SPENDS-95S-BEFORE-PREP-UNLOGGED-IN-POOL-LOCK-OR-PREFLIGHT:
# laps bound their own prep with 'timeout 120 ./run.sh ... prep_cluster', which
# reads no wait ledger.  On attempt 20 an 8-node prep waited 97 s for other
# lanes' power-ups and ran out its bound in its teardown step
# (tests/evidence/20261024T164328Z_fledger_f20s1/prep.log), and the lap's next
# step 1 s later found its node 'held by another run'
# (tests/evidence/20261024T164528Z_fledger_f20s0/prep.log).  The fix runs such a
# step under tools/lap_bounded.py (tools/batch_lap.py's run_bounded: the bound
# extended by the ledger's waits, and every process the step started ended
# before it returns).  MXFS_LAP_BOUNDED=0 runs each arm under 'timeout' instead,
# as the laps did: the control.
#
# SHAPE, on the host alone (no rig node, no shared lock: a lap that held the
# pool lock on purpose while lanes ran made other lanes' preps go INCOMPLETE):
#   wait  a holder keeps a private lock file for HOLD_S (over BOUND); the step
#         takes it through tests/lib/runlock.sh runlock_take (which writes its
#         wait to MXFS_LAP_WAIT_FILE, as run.sh's own lock takes do) and then
#         does nothing
#   held  the step takes a second private lock, leaves a child in a session of
#         its own holding the lock's descriptor (a shell's children inherit its
#         fds; timeout(1) signals its child's process group, which a setsid'd
#         child, an ssh session or a self-daemonising helper has left) and
#         sleeps past BOUND; once the bounded step has returned, a second taker
#         tries the lock without waiting.  Which process held test7 on attempt
#         20 is not recorded; this arm is the shape that would, not a finding.
#   work  the step sleeps BOUND + 5 s itself, waiting on nothing
#   EXPOSED  the wait arm's step started with BOUND s or more of the holder's
#            hold still ahead
#   PASS     the wait arm's step finished (rc 0); the held arm's lock was free
#            the moment its bounded step returned; the work arm's step was ended
#            at its bound (rc 124)
#   FAIL     otherwise
#
# Bounds (derived): the holder takes its lock in under 1 s and holds it HOLD_S
# (20); the wait arm then needs under 1 s; the held and work arms run BOUND + 5
# and are ended at BOUND plus run_bounded's 5 s grace per signal.  The lap takes
# about HOLD_S + 3 x BOUND + 20 s; caller bound 2 x that, 140 s.
#
# Usage: lap_bounded_lap.sh <label>
# Env:   BOUND (10), HOLD_S (20), MXFS_LAP_BOUNDED (1)
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE" || exit 2
# the tree root holds run.sh and tools/batch_lap.py both: a draft of this lap run from a copy of
# a few files finds the tree's own library above it
while { [ ! -f run.sh ] || [ ! -f tools/batch_lap.py ]; } && [ "$(pwd)" != / ]; do cd ..; done
[ -f tools/batch_lap.py ] || { echo "ABORT: no tree root above $0"; exit 2; }
ROOT=$(pwd)
# the lap_bounded.py beside this lap's tests/ (a draft's own), else the tree's
LB=$HERE/../tools/lap_bounded.py
[ -f "$LB" ] || LB=$ROOT/tools/lap_bounded.py
[ -f "$LB" ] || { echo "ABORT: no tools/lap_bounded.py"; exit 2; }
BOUND=${BOUND:-10}
HOLD_S=${HOLD_S:-20}
ARM=${MXFS_LAP_BOUNDED:-1}
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_lapbounded_$LABEL
mkdir -p "$OUT"
s0=$(date +%s)
el() { echo $(( $(date +%s) - s0 )); }
echo "=== lap_bounded_lap label=$LABEL bound=${BOUND}s hold=${HOLD_S}s lap_bounded=$LB arm=$ARM $(date -u +%FT%TZ) ==="

step() {  # <log> <command...> -> the step's rc, bounded as a lap's prep is
    local log=$1; shift
    if [ "$ARM" = 0 ]; then
        timeout "$BOUND" "$@" > "$log" 2>&1
    else
        PYTHONPATH=$ROOT/tools python3 "$LB" "$BOUND" -- "$@" > "$log" 2>&1
    fi
}

# ---- the wait arm
timeout $(( HOLD_S + 30 )) flock -x "$OUT/wait.lock" sh -c "date +%s.%N > $OUT/holder.start; sleep $HOLD_S; date +%s.%N > $OUT/holder.end" > "$OUT/holder.txt" 2>&1 &
hpid=$!
for i in $(seq 1 20); do [ -s "$OUT/holder.start" ] && break; sleep 0.25; done
echo "STAGE holder took its lock: $([ -s "$OUT/holder.start" ] && echo yes || echo no) at +$(el)s"
WSTART=$(date +%s.%N)
step "$OUT/wait.log" bash -c ". tests/lib/runlock.sh; runlock_take $OUT/wait.lock exclusive lap_bounded_wait $(( HOLD_S + 10 )) && echo TAKEN"
WRC=$?
wait "$hpid"
HELD_AHEAD=$(awk -v s="$(cat "$OUT/holder.start" 2>/dev/null)" -v e="$(cat "$OUT/holder.end" 2>/dev/null)" -v w="$WSTART" \
    'BEGIN { if (s == "" || e == "" || s > w) print 0; else printf "%d\n", e - w }')
echo "STAGE wait arm: rc=$WRC the holder's hold left at the step's start=${HELD_AHEAD}s at +$(el)s"
sed 's/^/    /' "$OUT/wait.log" | head -5

# ---- the held arm
step "$OUT/held.log" bash -c "exec 9>>$OUT/held.lock; flock -x 9; setsid sleep $(( BOUND + 30 )) & echo child \$!; sleep $(( BOUND + 5 ))"
HRC=$?
if flock -n -x "$OUT/held.lock" true; then HFREE=yes; else HFREE=no; fi
echo "STAGE held arm: rc=$HRC lock free when the step returned=$HFREE at +$(el)s"
sed 's/^/    /' "$OUT/held.log" | head -5
# a child the control left behind is ended here, by the pid it printed, so it holds nothing after
# the lap (its own sleep ends at BOUND + 30 regardless)
cpid=$(awk '/^child /{print $2; exit}' "$OUT/held.log")
[ -n "$cpid" ] && [ -r "/proc/$cpid/stat" ] && kill "$cpid" 2>/dev/null

# ---- the work arm
step "$OUT/work.log" sleep $(( BOUND + 5 ))
KRC=$?
echo "STAGE work arm: rc=$KRC at +$(el)s"

if [ "$HELD_AHEAD" -lt "$BOUND" ]; then
    echo "  the holder had ${HELD_AHEAD} s of its hold left when the step started, under the ${BOUND} s bound: nothing here makes the step wait past its bound"
    echo "RESULT: VACUOUS label=$LABEL stage=no-wait wall=$(el)s evidence=$OUT"; exit 3
fi
echo "EXPOSED: the wait arm's step started with ${HELD_AHEAD} s left of another holder's lock, over its ${BOUND} s bound"
fails=0
if [ "$WRC" = 0 ]; then echo "  PASS the wait arm finished (rc 0): its bound counted the wait as not its own"
else echo "  FAIL the wait arm's step was ended (rc $WRC) while it waited on another holder's lock; its own work takes under 1 s"; fails=$((fails+1)); fi
if [ "$HFREE" = yes ]; then echo "  PASS the held arm's lock was free the moment its bounded step returned"
else echo "  FAIL the held arm's step returned (rc $HRC) with a process it started still holding its lock"; fails=$((fails+1)); fi
if [ "$KRC" = 124 ]; then echo "  PASS the work arm was ended at its bound (rc 124)"
else echo "  FAIL the work arm was not ended at its bound (rc $KRC)"; fails=$((fails+1)); fi
echo "LAP lap_bounded $( [ $fails = 0 ] && echo PASS || echo FAIL ): wait arm rc=$WRC with ${HELD_AHEAD}s of another holder's lock ahead, held arm lock free=$HFREE, work arm rc=$KRC"
echo "RESULT: $( [ $fails = 0 ] && echo PASS || echo FAIL ) label=$LABEL fails=$fails wall=$(el)s evidence=$OUT"
[ $fails = 0 ]
