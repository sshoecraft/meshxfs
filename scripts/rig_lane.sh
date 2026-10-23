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
# A lane holds every configuration its steps name (`run.sh <configuration>`,
# `--at <configuration>`) until it exits, and refuses to start while another
# lane holds one of them (rc 3, the holder in the summary): two lanes on one
# configuration collided on run.sh's configuration lock, so one lane's pair was
# never formed and its verification batches spent every lap on it, INCOMPLETE
# (D-LANES-ON-ONE-CONFIGURATION-COLLIDE-AND-BATCHES-SPEND-THEIR-LAPS-INCOMPLETE).
# A holder process keeps each lock (/tmp/mxfs_lane.<configuration>.lock) and
# exits with the lane; the lane closes its own copy, so neither a step nor
# anything a step leaves running keeps a configuration held after the lane.
# The lane's EXIT trap ends each holder and waits for it, so the locks are free
# before the lane's exit is seen: a holder that only polled for the lane noticed
# it gone up to a second later, and a lane started in that second was refused as
# if the ended one still ran
# (D-LANE-HOLD-LINGERS-AFTER-ITS-LANE-SO-THE-NEXT-LANE-IS-REFUSED). The holder's
# poll stays as the backstop for a lane killed outright. LANE_HOLD_RELEASE=0
# leaves the release to that poll alone, as before: the control of that fix.
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
HOLDERS=()
release_holds() {
    [ "${LANE_HOLD_RELEASE:-1}" = 0 ] && return
    local pid
    for pid in "${HOLDERS[@]}"; do
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    done
}
trap release_holds EXIT
for cfg in $(grep -v '^[[:space:]]*#' "$OUT/queue" \
             | grep -oE '(run\.sh|--at)[[:space:]]+[0-9]+/[^[:space:]]+' | awk '{print $2}' | sort -u); do
    lock=/tmp/mxfs_lane.${cfg//\//-}.lock
    exec {fd}>>"$lock"
    if ! flock -n "$fd"; then
        echo "$(date -u +%FT%TZ) lane $NAME refused: configuration $cfg is held by another lane ($(head -c 200 "$lock"))" >> "$SUM"
        date -u +%FT%TZ > "$OUT/DONE"
        exit 3
    fi
    echo "$$ $(date -u +%FT%TZ) lane $NAME" > "$lock"
    tail --pid=$$ -f /dev/null < /dev/null > /dev/null 2>&1 &
    HOLDERS+=("$!")
    exec {fd}>&-
    echo "$(date -u +%FT%TZ) holds configuration $cfg" >> "$SUM"
done
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
