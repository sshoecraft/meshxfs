#!/bin/bash
# lap_load_end_lap.sh — one lap of what a rig lap leaves of its loads on its nodes once it ends.
#
# tests/noino_fence_efd_hold_lap.sh and tests/fenced_ledger_rig_lap.sh run tests/mpath/pathload.py
# on each node with its logs in /run/<lap>_<label>, and end those loads through
# tests/lib/lap_load.sh lap_load_end from their exit trap: the stop file touched and the load
# waited for on every exit, then its /run files removed.  Before that the noino lap stopped its
# loads only on its normal path, so a lap that ABORTed after starting them left them running
# (D-NOINO-LAP-ABORT-LEAVES-ITS-LOADS-RUNNING-INTO-THE-NEXT-LAP), and neither lap removed the
# files (D-RIG-LAPS-LEAVE-LOAD-LOGS-IN-NODE-RUN-AND-A-FULL-RUN-KILLS-THE-NEXT-LOAD).  This lap
# runs one of them once and reads every node SETTLE_S after it returned.
#
#   LAP=noino|fledger  which lap (noino); its own environment passes through to it
#   MODE=abort|full    abort: the lap ABORTs right after its warm-up with its loads running
#                      (its own test-only LAP_ABORT_AFTER_LOAD=1); full: the lap runs to its
#                      own verdict, whatever that verdict is
#   LAP_LOAD_STOP=0, LAP_LOAD_CLEAN=0 reach the lap: the controls of the two parts.
#
#   EXPOSED  the lap started its loads (its <node>_load_start.txt reads LOAD_STARTED on every
#            node) and returned
#   PASS     SETTLE_S after the lap returned no pathload of its label runs on any node and none
#            of its /run paths (<ld>, <ld>.out, <ld>.stop) is left
#   FAIL     a load still runs on some node, or a path is left (each counted, by node)
#   ABORT    the lap ended before its loads started, or a node's count is unreadable
# Afterwards whatever the lap left is stopped and removed, so the next lap starts clean.
#
# Bounds (derived from the laps' own headers): MODE=abort ends after the prep (120), the
# follower and load starts (30 + 2 x 20 + 2 x 30), the warm-up (WARM_S, 10) and the exit's
# lap_load_end (60) and follower stop (2 x 15): 340 for noino; fledger's keys read and two
# 30 s follower starts make it 370.  MODE=full: the lane bounds of each lap at its defaults
# (noino 591, the fenced reason arm 260) plus the exit's 60: 651 and 320.  INNER_BOUND
# overrides.  Then the settle 10, the reads 20 a node, the cleanup 60 a node; a caller bounds
# the lap at INNER_BOUND + 10 + 80 x nodes.
#
# Usage: tests/lap_load_end_lap.sh <label>
# Env:   MXFS_NODE_LIST, MXFS_CONFIG, MXFS_GROUP (passed to the lap), LAP (noino), MODE (abort),
#        SETTLE_S (10), INNER_BOUND (above)
# Exit 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
cd "$(dirname "$0")" || exit 2
HERE=$(pwd)
while { [ ! -f run.sh ] || [ ! -f tests/lib/rig.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done
[ -f run.sh ] || { echo "ABORT: no tree root above $0"; exit 2; }
. tests/lib/rig.sh
LAP=${LAP:-noino}
MODE=${MODE:-abort}
SETTLE_S=${SETTLE_S:-10}
case $LAP:$MODE in
    noino:abort) SCRIPT=noino_fence_efd_hold_lap.sh; LD=/run/noinoefd_$LABEL; DEFB=340 ;;
    noino:full) SCRIPT=noino_fence_efd_hold_lap.sh; LD=/run/noinoefd_$LABEL; DEFB=651 ;;
    fledger:abort) SCRIPT=fenced_ledger_rig_lap.sh; LD=/run/fledger_$LABEL; DEFB=370 ;;
    fledger:full) SCRIPT=fenced_ledger_rig_lap.sh; LD=/run/fledger_$LABEL; DEFB=320 ;;
    *) echo "LAP must be noino or fledger, MODE abort or full"; exit 2 ;;
esac
INNER_BOUND=${INNER_BOUND:-$DEFB}
IFS=, read -r -a NODES <<< "${MXFS_NODE_LIST:?MXFS_NODE_LIST}"
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_lapload_$LABEL
mkdir -p "$OUT"
echo "LAP lap_load_end start $(date -u +%FT%TZ) label=$LABEL lap=$LAP mode=$MODE nodes=$MXFS_NODE_LIST ld=$LD inner_bound=${INNER_BOUND}s LAP_LOAD_STOP=${LAP_LOAD_STOP:-(unset)} LAP_LOAD_CLEAN=${LAP_LOAD_CLEAN:-(unset)} out=$OUT"

ABORTARG=()
[ "$MODE" = abort ] && ABORTARG=(env LAP_ABORT_AFTER_LOAD=1)
timeout -k 5 "$INNER_BOUND" "${ABORTARG[@]}" bash "$HERE/$SCRIPT" "$LABEL" > "$OUT/lap.txt" 2>&1
lrc=$?
res=$(grep -a '^RESULT:' "$OUT/lap.txt" | tail -1)
echo "  the lap: rc=$lrc ${res:-no RESULT line}"
grep -a '^LOAD-END ' "$OUT/lap.txt" | sed 's/^/  /'
ev=$(sed -n 's/.* evidence=\([^ ]*\).*/\1/p' <<<"$res")
started=0
for n in "${NODES[@]}"; do
    [ -n "$ev" ] && grep -aqx 'LOAD_STARTED' "$ev/${n}_load_start.txt" 2>/dev/null && started=$((started + 1))
done
if [ "$started" != "${#NODES[@]}" ]; then
    echo "LAP lap_load_end ABORT: the lap's loads started on $started of ${#NODES[@]} node(s) (evidence ${ev:-none}), so nothing here measures how it ends them"
    exit 2
fi
echo "EXPOSED: the lap started its loads on all ${#NODES[@]} node(s) and returned rc=$lrc"

sleep "$SETTLE_S"
busy="ps -o args= -C python3 | grep -F 'pathload.py run' | grep -cF ' $LD $LD.stop'"
running=0; left=0; bad=""
for n in "${NODES[@]}"; do
    c=$(rs 20 "$n" "echo RUNNING=\$($busy); echo LEFT=\$(for p in $LD $LD.out $LD.stop; do [ -e \$p ] && echo \$p; done | wc -l); df -k /run | tail -1")
    r=$(sed -n 's/^RUNNING=\([0-9]*\)$/\1/p' <<<"$c" | head -1)
    l=$(sed -n 's/^LEFT=\([0-9]*\)$/\1/p' <<<"$c" | head -1)
    echo "  $n: running=${r:-?} left=${l:-?} $SETTLE_S s after the lap; /run $(grep -av '=' <<<"$c" | awk '{print $3 "K used " $4 "K free"}')"
    [ -n "$r" ] && [ -n "$l" ] || bad="$bad $n"
    [ "${r:-0}" -gt 0 ] && running=$((running + 1))
    [ "${l:-0}" -gt 0 ] && left=$((left + 1))
done
# whatever the lap left, stopped and removed (both switches on, whatever this lap ran with)
for n in "${NODES[@]}"; do
    rs 60 "$n" "touch $LD.stop; for t in \$(seq 1 45); do [ \"\$($busy)\" = 0 ] && break; sleep 1; done; rm -rf --one-file-system $LD $LD.out $LD.stop; echo CLEANED running=\$($busy)" > "$OUT/cleanup_$n.txt"
    echo "  $n: cleanup $(tr '\n' ' ' < "$OUT/cleanup_$n.txt")"
done
[ -z "$bad" ] || { echo "LAP lap_load_end ABORT: unreadable count on$bad"; exit 2; }
if [ "$running" = 0 ] && [ "$left" = 0 ]; then
    echo "LAP lap_load_end PASS: no load of the lap ran and none of its /run paths was left on any node $SETTLE_S s after it returned"
    exit 0
fi
echo "LAP lap_load_end FAIL: a load of the lap still ran on $running node(s) and its /run paths were left on $left node(s) $SETTLE_S s after it returned"
exit 1
