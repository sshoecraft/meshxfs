#!/bin/bash
#
# board_laps.sh — run a configuration's whole board N times back to back
#
# Usage: scripts/board_laps.sh <configuration> <laps> [<log-dir>]
#   e.g. MXFS_CRIT=$PWD/tests/evidence/vsphere/criteria.json \
#        MXFS_NODE_LIST=vstest1,vstest2 scripts/board_laps.sh 2/disk/caw/direct 9
#
# A platform is only shown to work by boards that keep passing, so this runs a
# whole board several times on one build (an own-rig board: vSphere, the
# Proxmox pair).  Passing laps never push an earlier failure out of anything:
# every run is kept in the board's run ledger, and a failure counts until a
# defect record names it (tools/criteria.py).  Each lap is a plain
# `./run.sh <configuration>` with the caller's environment (MXFS_CRIT,
# MXFS_NODE_LIST pass through), its log kept as lap-<n>.log.  run.sh enforces
# every row's budget itself, so nothing here adds a timeout of its own.
#
# Each lap is graded from the runs it recorded (`tools/criteria.py lap <run id>`),
# and the laps stop at the first lap with a row that did not pass: the run
# after a fault would be scored on whatever the fault left behind.
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
    # The lap is graded from the runs it recorded itself (its run id), never
    # from the board: the board also shows rows this lap did not reach.
    rid=$(grep -a -m1 -oE '^=== run @ [^ ]+ \(run_id=[^)]+\)' "$log" | sed 's/.*run_id=//; s/)$//')
    if [ -z "$rid" ]; then
        echo "lap $i/$LAPS rc=$rc wall=${w}s DID NOT RUN: no run id in $log"
        echo "LAPS_DONE $ran/$LAPS stopped: lap $i did not run (log $log)"
        exit 2
    fi
    # harness-lint: ok - `lap` reads only the runs recorded under this lap's own run id, never the board
    tools/criteria.py lap "$rid" > "$DIR/lap-$i.lap" 2>&1
    lrc=$?
    if [ "$lrc" = 2 ]; then
        echo "lap $i/$LAPS rc=$rc wall=${w}s DID NOT RUN: run $rid recorded no row"
        echo "LAPS_DONE $ran/$LAPS stopped: lap $i did not run (log $log)"
        exit 2
    fi
    ran=$i
    bad=$(awk '$3 != "PASS" && $3 != "SKIP" && NF >= 3 && $1 !~ /^lap$/ {print $2"="$3}' "$DIR/lap-$i.lap" | tr '\n' ' ')
    echo "lap $i/$LAPS rc=$rc wall=${w}s run $rid: $(tail -1 "$DIR/lap-$i.lap")${bad:+ NOT-PASSING: $bad}"
    [ "$lrc" = 0 ] || { echo "LAPS_DONE $ran/$LAPS stopped: lap $i left rows not passing (log $log)"; exit 1; }
done
echo "LAPS_DONE $ran/$LAPS clean (logs $DIR)"
