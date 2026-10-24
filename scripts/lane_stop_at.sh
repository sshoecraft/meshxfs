#!/bin/bash
# lane_stop_at.sh — end a running rig lane when it starts a given step.
#
# A running lane reads its own copy of its queue (tests/evidence/lanes/<lane>/queue), so a
# queue edit cannot take a step out of it, and editing scripts/rig_lane.sh under a running
# lane changes the script bash is still reading.  When a lane's later segment must not run
# beside another lane (a solo segment found sharing the rig), this waits for the lane's
# summary.log to show that step's start line, then sends SIGTERM to the lane's process group
# (rig_lane.sh is started with setsid, so its pid is its group), which ends the step's
# processes and runs the lane's EXIT trap that frees its configuration holds.  The step that
# was starting is cut where it stood; the caller undoes what it had begun (a power-up, say).
#
# The match is a fixed string against the text after "step N start: " in the summary.
# Bounded by <bound s>, which the caller derives from the steps before the one waited for;
# past it nothing is killed and the exit is 1, so an overrun is visible.
#
# Usage: scripts/lane_stop_at.sh <lane dir> '<step command text>' <bound s>
# Exit 0 the lane was ended at that step, 1 the bound passed, 2 the lane ended first.
set -u
dir=${1:?usage: lane_stop_at.sh <lane dir> <step command text> <bound s>}
want=${2:?step command text}
bound=${3:?bound in seconds}
pid=$(cat "$dir/pid" 2>/dev/null)
[ -n "$pid" ] || { echo "lane_stop_at: no pid in $dir"; exit 2; }
start=$(date +%s)
while :; do
    line=$(grep -F " start: $want" "$dir/summary.log" 2>/dev/null | tail -1)
    if [ -n "$line" ]; then
        kill -TERM -- "-$pid" 2>/dev/null
        for t in $(seq 1 30); do [ -d "/proc/$pid" ] || break; sleep 1; done
        if [ -d "/proc/$pid" ]; then
            echo "lane_stop_at: lane pid $pid still running 30 s after SIGTERM at: $line"
            exit 1
        fi
        echo "lane_stop_at: ended lane $(basename "$dir") at: $line"
        echo "$(date -u +%FT%TZ) lane ended by scripts/lane_stop_at.sh at: $line" >> "$dir/summary.log"
        exit 0
    fi
    [ -d "/proc/$pid" ] || { echo "lane_stop_at: lane pid $pid ended before that step"; exit 2; }
    if [ $(( $(date +%s) - start )) -ge "$bound" ]; then
        echo "lane_stop_at: FAIL $(basename "$dir") did not start that step within ${bound}s"
        exit 1
    fi
    sleep 2
done
