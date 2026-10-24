#!/bin/bash
# power_lock_lap.sh -- one lap of
# D-LANE-POWER-UP-FLOODS-THE-HOST-LOG-AND-ANOTHER-LANES-PREFLIGHT-REFUSES-ITS-PREP.
#
# Rig lanes start on their own, and a lane's first step powers its group up
# (scripts/lab_power.sh up), which floods the host's kernel log while the guests
# boot and log in to the target.  Another lane's prep runs the host preflight
# (scripts/clyde_preflight.sh, called by run.sh), whose log-rate check samples
# the host log for 3 s and refuses over 40 lines/s; sampled inside the flood, it
# refused a healthy prep ('kernel log is producing ~N lines/s').
#
# The fix: lab_power.sh up holds /tmp/mxfs_host_powerup.lock exclusive from its
# first start until every domain it started answers ssh, and the preflight takes
# the lock shared before it samples, waiting at most 240 s.  LAB_POWER_LOCK=0
# takes no lock on either side: the control (set it for the whole lap).
#
# SHAPE: the group POWER_GROUP (default g4d, four nodes) is powered off first.
# Then lab_power.sh up runs in the background, and while it runs this lap
# samples the host log rate in 3 s windows (sudo dmesg --follow-new) and, after
# PREFLIGHT_DELAY_S, runs the preflight itself once.
#   EXPOSED  some window before the power-up ended exceeded the preflight's
#            threshold (40 lines/s): a sample taken then would be refused
#   PASS     the preflight's log-rate check passed ('OK    kernel log ~')
#   FAIL     the preflight refused for the log rate ('kernel log is producing')
#   ABORT    the preflight failed some other check, or the group did not power
#            up or down
# The group is powered off again at the end.
#
# Bounds (derived): lab_power.sh down 90 s a node in parallel (SHUTDOWN_S),
# bound 120; up within BOOT_S=240, bound 260; the preflight samples 3 s and its
# other checks take under 10 s, plus a wait of at most 240 s on the lock, bound
# 270.  A caller bounds the lap at 2 x (120 + 260 + 120) = 1000 s.
#
# Usage: tests/power_lock_lap.sh <label>
# Env:   POWER_GROUP (g4d), PREFLIGHT_DELAY_S (8), LAB_POWER_LOCK
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}
cd "$(dirname "$0")" || exit 2
while [ ! -f run.sh ] && [ "$(pwd)" != / ]; do cd ..; done
[ -f run.sh ] || { echo "ABORT: no tree root above $0"; exit 2; }
GROUP=${POWER_GROUP:-g4d}
DELAY=${PREFLIGHT_DELAY_S:-8}
KMSG_MAX=40
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_powerlock_$LABEL
mkdir -p "$OUT"
echo "LAP power_lock start $(date -u +%FT%TZ) label=$LABEL group=$GROUP delay_s=$DELAY LAB_POWER_LOCK=${LAB_POWER_LOCK:-(unset)} out=$OUT"

timeout 120 scripts/lab_power.sh down "group:$GROUP" > "$OUT/down_before.txt" 2>&1 \
    || { echo "LAP power_lock ABORT: group:$GROUP did not power off first"; exit 2; }

timeout 260 scripts/lab_power.sh up "group:$GROUP" > "$OUT/up.txt" 2>&1 &
up_pid=$!
# the log rate in 3 s windows for as long as the power-up runs
( while kill -0 "$up_pid" 2>/dev/null; do
      n=$(sudo -n timeout 3 dmesg --follow-new --notime 2>/dev/null | wc -l)
      echo "WINDOW $(date -u +%T) lines=$n rate=$(( n / 3 ))"
  done ) > "$OUT/rate.txt" &
rate_pid=$!
sleep "$DELAY"
timeout 270 scripts/clyde_preflight.sh > "$OUT/preflight.txt" 2>&1
pf_rc=$?
wait "$up_pid"; up_rc=$?
wait "$rate_pid"
timeout 120 scripts/lab_power.sh down "group:$GROUP" > "$OUT/down_after.txt" 2>&1

peak=$(awk '{ sub("rate=", "", $4); if ($4 + 0 > m) m = $4 + 0 } END { print m + 0 }' "$OUT/rate.txt")
over=$(awk -v t=$KMSG_MAX '{ sub("rate=", "", $4); if ($4 + 0 > t) n++ } END { print n + 0 }' "$OUT/rate.txt")
echo "  power-up rc=$up_rc; host log windows over ${KMSG_MAX}/s: $over, peak ${peak}/s"
grep -a 'kernel log\|waited\|power-up still held' "$OUT/preflight.txt" | sed 's/^/  preflight:/'
[ "$up_rc" = 0 ] || { echo "LAP power_lock ABORT: group:$GROUP did not power up (rc=$up_rc)"; exit 2; }
others=$(grep -a '^  FAIL ' "$OUT/preflight.txt" | grep -vc 'kernel log is producing\|something is flooding dmesg')
[ "$others" = 0 ] || { echo "LAP power_lock ABORT: the preflight failed another check: $(grep -a '^  FAIL ' "$OUT/preflight.txt" | head -2 | tr '\n' ' ')"; exit 2; }
if [ "$over" = 0 ]; then
    echo "LAP power_lock VACUOUS: the power-up never raised the host log over ${KMSG_MAX}/s (peak ${peak}/s)"
    exit 3
fi
echo "EXPOSED: the power-up raised the host log over ${KMSG_MAX}/s in $over window(s), peak ${peak}/s"
if grep -aq 'kernel log is producing' "$OUT/preflight.txt"; then
    echo "LAP power_lock FAIL: the preflight sampled inside the power-up and refused: $(grep -a 'kernel log is producing' "$OUT/preflight.txt" | sed 's/^ *FAIL *//')"
    exit 1
fi
if grep -aq 'OK    kernel log ~' "$OUT/preflight.txt"; then
    echo "LAP power_lock PASS: the preflight's log-rate check passed ($(grep -a 'OK    kernel log ~' "$OUT/preflight.txt" | sed 's/^ *OK *//'); preflight rc=$pf_rc)"
    exit 0
fi
echo "LAP power_lock ABORT: the preflight printed no log-rate verdict"
exit 2
