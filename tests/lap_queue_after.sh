#!/bin/bash
# lap_queue_after.sh — start a lap queue once the lap now running on the same
# rig group has ended, so a session can hand a group from one campaign to the
# next without polling and without two laps ever sharing its nodes.
#
#   cd <checkout> && setsid nohup tests/lap_queue_after.sh <pid> <label> <queue> \
#       > tests/evidence/lapq_<label>.after 2>&1 < /dev/null &
#
# <pid> is the running lap's `timeout` wrapper (ps -o pid,args -C timeout).
# Stop that lap's own queue runner first (kill its lap_queue.sh pid), or it
# starts its next lap on the same nodes the moment this one ends.  The queue
# starts from the checkout this script is started in, as tests/lap_queue.sh
# would.
#
# budget: this script adds no bound of its own.  The wrapper it waits on exits
# when the lap ends or when the lap's own derived bound fires, and every lap of
# the queue it starts carries its own bound from the queue file.
PID=${1:?usage: lap_queue_after.sh <pid> <label> <queue-file>}
LABEL=${2:?label}; QUEUE=${3:?queue file}
cd "$(dirname "$0")/.." || exit 2
[ -r "$QUEUE" ] || { echo "ABORT: no queue file $QUEUE"; exit 2; }
[ -e "tests/evidence/lapq_$LABEL.log" ] && { echo "ABORT: tests/evidence/lapq_$LABEL.log exists; pick another label"; exit 2; }
echo "=== lap_queue_after $LABEL waiting on pid $PID (comm $(cat /proc/$PID/comm 2>/dev/null || echo gone)) $(date -u +%FT%TZ) ==="
tail --pid="$PID" -f /dev/null
echo "pid $PID gone $(date -u +%FT%TZ); starting tests/lap_queue.sh $LABEL $QUEUE in $(pwd)"
exec tests/lap_queue.sh "$LABEL" "$QUEUE"
