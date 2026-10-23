#!/bin/bash
# tests/lane_config_lock_lap.sh — one lap of
# D-LANES-ON-ONE-CONFIGURATION-COLLIDE-AND-BATCHES-SPEND-THEIR-LAPS-INCOMPLETE.
#
# Two rig lanes (scripts/rig_lane.sh) whose steps name one configuration must not run at once:
# lane g2's prep of 2/net/mesh/direct was refused because lane g2c's run.sh held that
# configuration, and g2's verification batches then spent every lap on a pair never formed.
#
# The lap starts lane A, whose one step names configuration 64/net/mesh/direct and holds for 4 s,
# and once A's step has started, lane B, whose one step names the same configuration and only
# records that it ran; when A has ended, lane C, the same as B. The steps touch no node, LUN or
# board: a lane reads the configurations its steps name from the queue's text, and 64 nodes is a
# configuration no rig lane runs, so the lap never holds up a real one.
#
#   EXPOSED  lane B was started while lane A's step was running (the trigger)
#   PASS     B refused to start, naming the configuration, and ran no step; and C, started 1.5 s
#            after A ended, ran its step (A's hold went with it)
#   FAIL     B ran its step while A held the configuration, or C was refused after A ended
#
# Bound, derived: A's step is 4 s, B and C a fraction of a second each, the wait for A's start
# under 1 s and the 1.5 s before C; under 8 s, bounded at 20 s.
#
# Usage: tests/lane_config_lock_lap.sh [<lap tag>]
# Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
set -u
cd "$(dirname "$0")/.." || exit 2
TAG=${1:-$$}
CFG=64/net/mesh/direct
Q=$(mktemp -d /tmp/mxfs_lanelap.XXXXXX) || { echo "ABORT: no scratch directory"; exit 2; }
trap 'rm -rf -- "$Q"' EXIT
echo "sleep 4; echo held ./run.sh $CFG" > "$Q/a"
echo "echo ran ./run.sh $CFG" > "$Q/b"
cp "$Q/b" "$Q/c"
lane_dir() {  # newest lane directory of a lane name
    ls -d tests/evidence/lanes/"$1"_* 2>/dev/null | tail -1
}
scripts/rig_lane.sh "lanelockA$TAG" "$Q/a" > /dev/null 2>&1 &
APID=$!
A=""
for _ in $(seq 1 30); do
    A=$(lane_dir "lanelockA$TAG")
    [ -n "$A" ] && grep -q ' step 1 start' "$A/summary.log" 2>/dev/null && break
    sleep 0.1
done
if [ -z "$A" ] || ! grep -q ' step 1 start' "$A/summary.log" 2>/dev/null; then
    echo "ABORT: lane A's step did not start ($(cat "$A/summary.log" 2>/dev/null | tail -1))"
    wait "$APID"
    exit 2
fi
a_running=1
grep -q ' step 1 end' "$A/summary.log" && a_running=0
scripts/rig_lane.sh "lanelockB$TAG" "$Q/b" > /dev/null 2>&1
B_RC=$?
B=$(lane_dir "lanelockB$TAG")
grep -q ' step 1 end' "$A/summary.log" && a_running=0
[ "$a_running" = 1 ] && echo "EXPOSED: lane B was started while lane A's step on $CFG was running"
wait "$APID"
# a lane's hold is a holder process that notices the lane has exited within its 1 s poll
sleep 1.5
C_RC=0
scripts/rig_lane.sh "lanelockC$TAG" "$Q/c" > /dev/null 2>&1 || C_RC=$?
C=$(lane_dir "lanelockC$TAG")
echo "INFO lane A: $(tr '\n' '|' < "$A/summary.log" | cut -c1-400)"
echo "INFO lane B rc=$B_RC: $(tr '\n' '|' < "$B/summary.log" 2>/dev/null | cut -c1-400)"
echo "INFO lane C rc=$C_RC: $(tr '\n' '|' < "$C/summary.log" 2>/dev/null | cut -c1-400)"
if [ "$a_running" != 1 ]; then
    echo "ABORT: lane A's step had ended before lane B was started; nothing measured"
    exit 2
fi
wrong=""
if grep -q ' step 1 start' "$B/summary.log" 2>/dev/null; then
    wrong="lane B ran its step while lane A held $CFG"
elif ! grep -q "refused: configuration $CFG" "$B/summary.log" 2>/dev/null; then
    wrong="lane B neither ran nor refused naming $CFG"
fi
if ! grep -q ' step 1 end rc=0' "$C/summary.log" 2>/dev/null; then
    wrong="${wrong:+$wrong; }lane C, started after lane A ended, did not run its step"
fi
if [ -n "$wrong" ]; then
    echo "LANE_LOCK_LAP FAIL $wrong"
    exit 1
fi
echo "LANE_LOCK_LAP PASS lane B refused $CFG while lane A held it, and lane C ran once A had ended"
exit 0
