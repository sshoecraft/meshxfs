#!/bin/bash
#
# board_laps.sh — run a configuration's whole board N times back to back
#
# Usage: scripts/board_laps.sh <configuration> <laps> [<log-dir>]
#   e.g. MXFS_CRIT=$PWD/tests/evidence/vsphere/criteria.json \
#        MXFS_NODE_LIST=vstest1,vstest2 scripts/board_laps.sh 2/disk/caw/direct 9
#
# A FLAKY row reads PASS again only after its genuine FAILs leave the 11-run
# window (tools/flake_laps.py says how many runs each row still needs), and a
# platform is only shown to work by boards that keep passing.  Each lap is a
# plain `./run.sh <configuration>` with the caller's environment (MXFS_CRIT,
# MXFS_NODE_LIST pass through), its log kept as lap-<n>.log.  run.sh enforces
# every row's budget itself, so nothing here adds a timeout of its own.
#
# The laps stop at the first board with a row that is neither PASS nor FLAKY:
# the run after a fault would be scored on whatever the fault left behind.
# Prints one line per lap and LAPS_DONE <ran>/<laps> at the end; exit 0 when
# every lap ran clean.
#   --group <g> runs every lap on that rig group (`./run.sh <cfg> --group <g>`),
#   so two configurations' laps can run side by side on disjoint groups with
#   no environment assignment at the prompt.
#
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
USAGE="usage: $0 <configuration> <laps> [--group <g>] [<log-dir>]"
CFG="${1:?$USAGE}"
LAPS="${2:?$USAGE}"
shift 2
GRP=()
if [ "${1:-}" = --group ]; then
    GRP=(--group "${2:?$USAGE}")
    shift 2
fi
DIR="${1:-$HERE/tests/evidence/board_laps_$(date -u +%Y%m%dT%H%M%SZ)${GRP[1]:+_${GRP[1]}}}"
mkdir -p "$DIR"
cd "$HERE" || exit 2

ran=0
for i in $(seq 1 "$LAPS"); do
    log="$DIR/lap-$i.log"
    s=$(date +%s)
    ./run.sh "$CFG" "${GRP[@]}" > "$log" 2>&1
    rc=$?
    w=$(( $(date +%s) - s ))
    # A run.sh that never ran a row (preflight, lock or VM start refused it)
    # leaves the board as the previous lap wrote it: reading that board again
    # reported a lap that did not run as clean (g4 lap 4, 2026-10-15, a 9 s
    # host-preflight abort counted as 37 PASS).
    if grep -aq -E '^=== run\.sh ABORTED|^ERROR: could not start|^ERROR: .* held by another run' "$log"; then
        echo "lap $i/$LAPS rc=$rc wall=${w}s DID NOT RUN: $(grep -a -m1 -E '^=== run\.sh ABORTED|^ERROR:' "$log" | cut -c1-160)"
        echo "LAPS_DONE $ran/$LAPS stopped: lap $i did not run (log $log)"
        exit 2
    fi
    ran=$i
    board=$(tools/criteria.py "$CFG" 2>&1)
    echo "$board" > "$DIR/lap-$i.board"
    total=$(echo "$board" | grep -a '^Total:')
    bad=$(echo "$board" | grep -a -E '^[0-9]+ +\|' | awk -F'|' '{gsub(/ /,"",$3); if ($3!="PASS" && $3!="FLAKY") print $2"="$3}' | tr -d ' ' | tr '\n' ' ')
    echo "lap $i/$LAPS rc=$rc wall=${w}s $total${bad:+ NOT-PASSING: $bad}"
    [ -z "$bad" ] || { echo "LAPS_DONE $ran/$LAPS stopped: lap $i left rows not passing (log $log)"; exit 1; }
done
echo "LAPS_DONE $ran/$LAPS clean (logs $DIR)"
