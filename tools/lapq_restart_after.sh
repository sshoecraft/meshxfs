#!/bin/bash
#
# lapq_restart_after.sh — stop a running lap queue once a given lap has ended,
# then start a queue under a new label, without cutting a lap in half.
#
# A board killed mid-row finalizes that row ABORTED, so a queue whose remaining
# laps are wrong (a row list missing a prerequisite, a superseded build) is
# stopped between laps: this waits for the queue log's "QUEUE lap=<n> rc="
# line, signals the queue's process group (the lap that would start next may
# already be in its first seconds; it is in prep, before any row), and then
# starts tests/lap_queue.sh <new-label> <queue-file> detached.
#
# Usage: nohup setsid tools/lapq_restart_after.sh <old-label> <old-pgid> <lap-n> \
#            <bound-s> <new-label> <queue-file> > <log> 2>&1 &
#   <bound-s>  the old lap's own bound from its queue file: how long to wait for
#              its rc line before giving up (an overrun is the lap's failure and
#              the queue records it; this script then stops the queue anyway).
set -u
OLD=${1:?old label}; PGID=${2:?old pgid}; LAPN=${3:?lap number}
BOUND=${4:?bound s}; NEW=${5:?new label}; QFILE=${6:?queue file}
cd "$(dirname "$0")/.." || exit 2
LOG=tests/evidence/lapq_$OLD.log
[ -r "$QFILE" ] || { echo "no queue file $QFILE"; exit 2; }
grep -q "QUEUE lap=$LAPN rc=" "$LOG" 2>/dev/null \
    || timeout "$BOUND" tail -n0 -F "$LOG" | grep -m1 -q "QUEUE lap=$LAPN rc="
kill -TERM -- "-$PGID" 2>/dev/null
# lap_queue.sh runs each lap under `timeout`, which puts the lap in a process
# group of its own, so the signal above does not reach a lap the queue started
# in the instant between its rc line and that signal.  That lap is in its prep;
# it is stopped too, or it holds the configuration's run lock and the new queue
# is refused on every lap.
sleep 1
next=$(grep -E "QUEUE lap=$((LAPN + 1)) starting" "$LOG" | sed -E 's/.*cmd=\[([^]]*)\].*/\1/')
if [ -n "$next" ]; then
    tag=$(awk '{print $2}' <<<"$next")
    ps -o pgid=,args= -C timeout | grep -F -- " $tag " | awk '{print $1}' | sort -u \
        | while read -r g; do
            kill -TERM -- "-$g" 2>/dev/null && echo "stopped lap $((LAPN + 1)) ($tag), process group $g"
        done
    echo "QUEUE lap=$((LAPN + 1)) stopped by operator in its prep ($(date -u +%FT%TZ))" >> "$LOG"
fi
echo "QUEUE STOPPED by operator after lap $LAPN ($(date -u +%FT%TZ)); continued as label $NEW from $QFILE" >> "$LOG"
sleep 5
nohup setsid tests/lap_queue.sh "$NEW" "$QFILE" > "tests/evidence/lapq_$NEW.out" 2>&1 < /dev/null &
echo "started $NEW pid=$!"
