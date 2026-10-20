#!/bin/bash
#
# lapq_rows.sh — one line per lap of each named lap queue, with the verdict of
# every board row the lap ran, so several queues running side by side can be
# read in one look instead of opening each lap's board log.
#
# Usage: tools/lapq_rows.sh <queue-label> [<queue-label> ...]
#   <queue-label> is the label given to tests/lap_queue.sh (its log is
#   tests/evidence/lapq_<label>.log).
#
# For each lap the queue log names, the board logs that lap wrote are found by
# the lap's own label (the second word of a tests/board_4node_chain.sh command,
# or the tag of a tests/mpath/lap_chain.sh laps command plus its lap letter),
# and every "  PASS|FAIL|FLAKY|ABORTED|SKIP  <row>" result line in them is
# printed as <STATUS>:<row>.  Host-preflight lines (kernel log rate, flood)
# are gate output, not rows, and are left out; a refused preflight shows as the
# run.sh line that says so.
set -u
cd "$(dirname "$0")/.." || exit 2
ev=tests/evidence
for label in "$@"; do
    log=$ev/lapq_$label.log
    [ -r "$log" ] || { echo "== $label: no $log"; continue; }
    echo "== $label  ($(grep -c 'rc=' "$log") laps ended; $(tail -1 "$log" | cut -c1-90))"
    grep -E 'QUEUE lap=[0-9]+ starting' "$log" | while read -r line; do
        n=$(sed -E 's/.*lap=([0-9]+).*/\1/' <<<"$line")
        cmd=$(sed -E 's/.*cmd=\[([^]]*)\].*/\1/' <<<"$line")
        set -- $cmd
        case "$1" in
            tests/board_4node_chain.sh) tag=$2 ;;
            tests/mpath/lap_chain.sh) tag="${5}a" ;;
            *) tag="" ;;
        esac
        rc=$(grep -E "QUEUE lap=$n rc=" "$log" | sed -E 's/.*rc=([0-9]+) wall=([0-9]+s).*/rc=\1 \2/')
        rows=""
        if [ -n "$tag" ]; then
            for b in $ev/board_*_"$tag".log; do
                [ -r "$b" ] || continue
                rows="$rows $(grep -E '^\s+(PASS|FAIL|FLAKY|ABORTED|ABORT|SKIP)\s+[a-z_]+\s' "$b" \
                    | grep -v -E 'kernel log|flooding' \
                    | awk '{printf "%s:%s ", $1, $2}')"
                grep -q 'run.sh ABORTED: host-safety preflight' "$b" && rows="$rows [preflight-refused-a-run.sh]"
            done
        fi
        echo "lap $n ${rc:-running} $tag:${rows:- (no rows yet)}"
    done
done
