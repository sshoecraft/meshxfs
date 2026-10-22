#!/bin/bash
# rig_lane.sh — run a queue of rig commands one after another, detached from
# the session that queued them, each step with its own log, exit code and
# times.
#
# A background task of a Claude Code session dies with the session, and a rig
# lap often outlives one: a control batch of a capture-gate lap is an hour. A
# lane is started with nohup and setsid, so it survives the session, and the
# next session reads what each step did from files instead of re-running it.
#
# The queue is a file of steps, one per line, run in order by bash from the
# tree's root. A line `export NAME=value` sets the lane's environment for the
# steps after it (a rig group: MXFS_GROUP, MXFS_MARKER, MXFS_NODE_LIST). Blank
# lines and lines starting with # are skipped. A step that fails does not stop
# the lane, since the steps are independent laps or batches, each graded by its
# own record; its exit code is in the summary.
#
# Every step carries its own bounds (run.sh enforces each row's budget from
# tests/suite/manifest; tools/batch_lap.py and every harness bound themselves),
# so the lane wraps nothing in a timeout of its own.
#
# Output, under tests/evidence/lanes/<name>_<stamp>/:
#   summary.log    one line as each step starts and one as it ends: its number,
#                  rc, seconds and the command
#   step<N>.log    the step's own stdout and stderr
#   pid            the lane's pid, written at start
#   DONE           written when the last step has ended
#
# Usage: nohup setsid scripts/rig_lane.sh <name> <queue file> > /dev/null 2>&1 &
set -u
NAME=${1:?lane name}
QUEUE=${2:?queue file}
cd "$(dirname "$0")/.." || exit 2
[ -r "$QUEUE" ] || { echo "rig_lane: cannot read $QUEUE" >&2; exit 2; }
OUT=tests/evidence/lanes/${NAME}_$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT" || exit 2
cp "$QUEUE" "$OUT/queue"
echo $$ > "$OUT/pid"
SUM=$OUT/summary.log
n=0
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    if [[ "$line" =~ ^export\ ([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
        echo "$(date -u +%FT%TZ) env ${BASH_REMATCH[1]}=${BASH_REMATCH[2]}" >> "$SUM"
        continue
    fi
    n=$((n + 1))
    t0=$(date +%s)
    echo "$(date -u +%FT%TZ) step $n start: $line" >> "$SUM"
    bash -c "$line" < /dev/null > "$OUT/step$n.log" 2>&1
    rc=$?
    echo "$(date -u +%FT%TZ) step $n end rc=$rc $(( $(date +%s) - t0 ))s: $line" >> "$SUM"
done < "$OUT/queue"
echo "$(date -u +%FT%TZ) lane $NAME done: $n step(s)" >> "$SUM"
date -u +%FT%TZ > "$OUT/DONE"
