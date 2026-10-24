#!/bin/bash
# exposure_follow.sh — node side of run.sh's batch exposure count: a follower of this node's
# /dev/kmsg that keeps only the lines matching the batch's probe, from the lap's first row to
# the count.
#
# run.sh counted a batch lap's exposure from `dmesg` read when the batch's row ended.  A lap
# whose trigger is in a supporting row (path_answer_lost before chk_clean) logs tens of
# thousands of lines per node before the count, so the ring may no longer hold the trigger's
# lines; the count then reads 0 on a lap that reached the trigger.  The follower runs from the
# lap's start and keeps only probe lines, so it is small and loses nothing the ring rotates out.
#
#   start <batch> <probe base64>        start the follower (replacing one left for that batch)
#   count <batch> <t0 s> <probe base64> print RING=<n> FOLLOW=<n|none>: lines matching the probe
#                                       since uptime t0, from the ring and from the follower;
#                                       then stop the follower and remove its file
# A /dev/kmsg record is "pri,seq,usec,flags;text"; a reader opened fresh starts at the oldest
# record in the ring, so the follower's lines are filtered on usec >= t0 as the ring's are.
set -u
cmd=${1:?start|count}
batch=${2:?batch}
F=/run/mxfs_expo.$batch
case $cmd in
start)
    pb=${3:?probe}
    [ -f "$F.pid" ] && kill -- "-$(cat "$F.pid")" 2>/dev/null
    rm -f "$F" "$F.pid"
    P=$(echo "$pb" | base64 -d) F=$F nohup setsid sh -c 'echo $$ > "$F.pid"; exec cat /dev/kmsg | grep -aE --line-buffered -- "$P" > "$F"' > /dev/null 2>&1 < /dev/null &
    for t in 1 2 3 4 5; do [ -s "$F.pid" ] && break; sleep 0.2; done
    [ -s "$F.pid" ] && echo FOLLOW_STARTED || echo FOLLOW_FAILED
    ;;
count)
    t0=${3:?t0}
    pb=${4:?probe}
    p=$(echo "$pb" | base64 -d)
    ring=$(dmesg 2>/dev/null | awk -v t0="$t0" '{ if (match($0, /^\[ *[0-9]+\.[0-9]+\]/)) { ts = substr($0, 2, RLENGTH - 2) + 0; if (ts >= t0) print } }' | grep -cE -- "$p")
    if [ -f "$F" ] && [ -s "$F.pid" ]; then
        sleep 1
        follow=$(awk -F';' -v t0="$t0" '{ split($1, h, ","); if (h[3] / 1000000 >= t0) n++ } END { print n + 0 }' "$F")
    else
        follow=none
    fi
    [ -f "$F.pid" ] && kill -- "-$(cat "$F.pid")" 2>/dev/null
    rm -f "$F" "$F.pid"
    echo "RING=${ring:-0} FOLLOW=$follow"
    ;;
*) echo "usage: exposure_follow.sh start|count <batch> ..."; exit 2 ;;
esac
