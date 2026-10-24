#!/bin/bash
# pool_lock_powerup_lap.sh -- one lap of D-LUN-POOL-LOCK-WAIT-OVER-60S-REFUSES-A-PREP-WHILE-ANOTHER-LANE-HOLDS-IT.
#
# run.sh ran its host preflight holding the LUN pool lock (tools/lun_pool.sh quiet), and the
# preflight waits inside it for any lane's power-up (scripts/clyde_preflight.sh, shared on
# /tmp/mxfs_host_powerup.lock, which scripts/lab_power.sh holds exclusive for a whole 'up').  So
# a power-up held the pool for every lane: on 2026-10-24 lap pw8c4 took the pool at 10:40:47,
# its preflight waited 58 s on lane g4c's power-up, and lap lhmc5's alloc gave up after 60 s.
# The fix waits for the power-up before taking the pool (run.sh, PREFLIGHT_POWERUP_FIRST=0 the
# control).
#
# SHAPE: hold the power-up lock exclusive for HOLD_S seconds, as a power-up does (flock -x on
# the same file); while it is held, start a pooled prep of this lane's group
# (MXFS_FORCE_PREP=1 ./run.sh <configuration> --group <group> prep_cluster); once the prep has
# printed 'preflight starts', time a third caller's take of the pool lock
# (tools/lun_pool.sh quiet true, the lock and nothing else).
#   EXPOSED  the power-up hold was still held when the prep reached its preflight
#   PASS     the third caller took the pool in under WAIT_MAX_S (5) seconds, and the prep passed
#   FAIL     it waited longer: the pool was held while the prep waited for the power-up
#   ABORT    the hold or the prep could not be started, or the prep failed
#
# Bounds (derived): the hold HOLD_S (40); prep_cluster measured 37-58 s at 2 nodes plus the hold
# it may wait out; the third caller at most the hold (120 s bound); so the prep is bounded at
# 2 x (40 + 58) = 196 s, and a caller bounds the lap at 196 + 30 (the wait for the prep's
# preflight line) + 10 = 236 s.
#
# Usage: tests/pool_lock_powerup_lap.sh <label>   (MXFS_CONFIG, MXFS_GROUP: a pooled configuration
#        and an idle group; PREFLIGHT_POWERUP_FIRST=0 in the environment reaches run.sh)
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}
cd "$(dirname "$0")" || exit 2
while { [ ! -f run.sh ] || [ ! -f tools/mxfs_lab.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done
[ -f run.sh ] || { echo "ABORT: no tree root above $0"; exit 2; }
CONFIG=${MXFS_CONFIG:?MXFS_CONFIG}
GROUP=${MXFS_GROUP:?MXFS_GROUP}
HOLD_S=${HOLD_S:-40}
WAIT_MAX_S=${WAIT_MAX_S:-5}
LOCK=/tmp/mxfs_host_powerup.lock
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_poollockpu_$LABEL
mkdir -p "$OUT"
echo "LAP pool_lock_powerup start $(date -u +%FT%TZ) label=$LABEL at=$CONFIG group=$GROUP hold_s=$HOLD_S PREFLIGHT_POWERUP_FIRST=${PREFLIGHT_POWERUP_FIRST:-(unset)} out=$OUT"

# the power-up's hold, exactly as scripts/lab_power.sh takes it
flock -x -w 240 "$LOCK" sleep "$HOLD_S" & hold=$!
for t in $(seq 1 50); do
    flock -n -s "$LOCK" true 2>/dev/null || break
    sleep 0.1
done
flock -n -s "$LOCK" true 2>/dev/null && { kill "$hold" 2>/dev/null; echo "LAP pool_lock_powerup ABORT: the power-up hold was not taken"; exit 2; }
t_hold=$SECONDS

MXFS_FORCE_PREP=1 timeout 196 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 < /dev/null & prep=$!
for t in $(seq 1 300); do
    grep -aq 'pre-prep: preflight starts' "$OUT/prep.log" && break
    kill -0 "$prep" 2>/dev/null || break
    sleep 0.1
done
grep -aq 'pre-prep: preflight starts' "$OUT/prep.log" || { kill "$hold" 2>/dev/null; wait "$prep"; echo "LAP pool_lock_powerup ABORT: the prep never reached its preflight: $(tail -2 "$OUT/prep.log" | tr '\n' ' ' | cut -c1-200)"; exit 2; }
sleep 3
held=0; kill -0 "$hold" 2>/dev/null && held=1
t0=$(date +%s%N)
timeout 120 tools/lun_pool.sh quiet true > "$OUT/third.txt" 2>&1
trc=$?
waited_ms=$(( ($(date +%s%N) - t0) / 1000000 ))
echo "  the third caller's pool take: rc=$trc ${waited_ms} ms ($(tr '\n' ' ' < "$OUT/third.txt" | cut -c1-120)); the power-up hold was $([ $held = 1 ] && echo still || echo no longer) held, $(( SECONDS - t_hold )) s after it began"
wait "$hold"
wait "$prep"; prc=$?
grep -a 'pre-prep:\|waited .* for a power-up' "$OUT/prep.log" | sed 's/^/  PREP /' | head -12
[ "$held" = 1 ] || { echo "LAP pool_lock_powerup VACUOUS: the power-up hold had ended before the prep reached its preflight"; exit 3; }
echo "EXPOSED: a power-up held the host lock while the prep took its preflight"
[ "$prc" = 0 ] || { echo "LAP pool_lock_powerup ABORT: prep_cluster rc=$prc (evidence $OUT/prep.log)"; exit 2; }
[ "$trc" = 0 ] || { echo "LAP pool_lock_powerup FAIL: the third caller did not take the pool lock (rc=$trc)"; exit 1; }
if [ "$waited_ms" -lt $(( WAIT_MAX_S * 1000 )) ]; then
    echo "LAP pool_lock_powerup PASS: the third caller took the pool in ${waited_ms} ms while the power-up held the host"
    exit 0
fi
echo "LAP pool_lock_powerup FAIL: the third caller waited ${waited_ms} ms for the pool while the power-up held the host"
exit 1
