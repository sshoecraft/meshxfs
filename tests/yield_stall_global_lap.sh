#!/bin/bash
# yield_stall_global_lap.sh -- one lap of
# D-YIELD-SCAN-SAVE-RESTORE-OF-AG-BAST-STALL-ITERS-RACES-AND-STICKS-AT-200.
#
# The cached-AG yield scan (mxfs_dlm_yield_basted_cached_ags, run before every
# slow-path inode DLM acquire) shortened its inline drain's stall bound by
# writing the module-wide ag_bast_stall_iters to 200 and restoring the value it
# had saved, with no lock.  Two overlapping scans on one node (A saves 600 and
# sets 200, B saves 200, A restores 600, B restores 200) leave the parameter at
# 200, and run.sh's live-parameter check then refuses every later row on that
# node as a stale prep.  The fix gives the bound to the one inline drain on its
# AG and writes nothing global; ag_yield_stall_global=1 writes it as before.
#
# A lap: form the pair (run.sh <configuration> prep_cluster, with the caller's
# MXFS_EXTRA_MODARGS), set dbg_yield_scan_hold_us=HOLD_US on both nodes, then on
# both at once WORKERS create/unlink loops for WORK_S seconds, worker w of each
# node in directory w, which both nodes' worker w use, so each directory's
# inode lock is contended across the nodes while every worker of a node
# acquires in a directory of its own; then each node's ag_yield_scan_n,
# ag_yield_drain_n, ag_yield_scan_overlap_n and ag_bast_stall_iters, and the
# hold set back to 0.
#   EXPOSED  a node counted a yield scan that began while another was in its
#            scan (ag_yield_scan_overlap_n > 0)
#   PASS     every node's ag_bast_stall_iters reads what prep loaded
#   FAIL     a node's ag_bast_stall_iters reads anything else
#   ABORT    the pair could not be formed, or a node's parameters could not be read
#
# Why the hold and why a directory per worker (the prechecks of 2026-10-24,
# tests/evidence/lanes/g2_pre_attempt15*): in one shared directory the parent's
# i_rwsem serialized each node's creates and no two scans overlapped in 4280
# pairs; with a directory per worker, 1 overlap per node in about 2300 scans and
# no inline drain, so every scan lasted microseconds and the save-restore never
# lost a restore on either arm.  A scan that drains an AG inline takes far
# longer, as on the 8/net/mesh/mpath victim where the parameter stuck.  The hold
# (TEST ONLY, written at runtime on both arms alike, 0 after the lap) stands in
# for that: with equal holds a scan that starts later ends later, which is the
# interleaving that leaves the parameter at 200 without the fix.  The fix-on arm
# runs the same hold and writes no global at all.
#
# The control is MXFS_EXTRA_MODARGS=ag_yield_stall_global=1 in the caller's
# environment (the lap's prep loads it): the same build with the old write.
#
# Bound, derived: prep_cluster 37-58 s on a 2-node pair (the 2026-10-23 laps);
# the workload is WORK_S (20 s) under timeout on each node, reached through one
# ssh each with a cap of WORK_S + 15 s; the reads a few seconds: the prechecks
# took 70-73 s, so a caller bounds the lap at twice what its precheck measures.
#
# Usage: tests/yield_stall_global_lap.sh <label> <configuration>
#        (the group's env exported: MXFS_GROUP, MXFS_MARKER, MXFS_NODE_LIST)
#        MXFS_EXTRA_MODARGS=ag_yield_stall_global=1 tests/yield_stall_global_lap.sh ...   (control)
# Leaves both nodes mounted.  Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
CONFIG=${2:?configuration}
cd "$(dirname "$0")/.." || exit 2
NODES=${MXFS_NODE_LIST:?MXFS_NODE_LIST}
SSH=tools/mxfs_sshpass.sh
MNT=${MXFS_MNT:-/mnt/shared}
WORKERS=${WORKERS:-8}
WORK_S=${WORK_S:-20}
HOLD_US=${HOLD_US:-2000}
. tests/lib/rig.sh
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_yieldstall_$LABEL
mkdir -p "$OUT"
echo "LAP yield_stall_global start $(date -u +%FT%TZ) label=$LABEL at=$CONFIG nodes=$NODES workers=$WORKERS work_s=$WORK_S hold_us=$HOLD_US modargs=[${MXFS_EXTRA_MODARGS:-}] out=$OUT"
prep=$(MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" ${MXFS_GROUP:+--group "$MXFS_GROUP"} prep_cluster < /dev/null 2>&1)
rc=$?
[ "$rc" = 0 ] || { echo "LAP yield_stall_global ABORT: prep_cluster rc=$rc: $(echo "$prep" | tail -2 | tr '\n' ' ' | cut -c1-240)"; exit 2; }
P=/sys/module/mxfs/parameters
declare -A LOADED
for n in ${NODES//,/ }; do
    v=$(rs 20 "$n" "cat $P/ag_bast_stall_iters $P/ag_yield_stall_global 2>/dev/null | tr '\n' ' '; echo $HOLD_US > $P/dbg_yield_scan_hold_us && cat $P/dbg_yield_scan_hold_us; grep -c ' mxfs ' /proc/mounts")
    set -- $v
    [ "$#" = 4 ] && [ "$3" = "$HOLD_US" ] && [ "$4" = 1 ] || { echo "LAP yield_stall_global ABORT: $n after prep: '$v' (want stall global hold=$HOLD_US mounted=1)"; exit 2; }
    LOADED[$n]=$1
    echo "  $n after prep: ag_bast_stall_iters=$1 ag_yield_stall_global=$2 dbg_yield_scan_hold_us=$3"
done
D="$MNT/.yieldstall.$LABEL.$$"
rs 20 "${NODES%%,*}" "mkdir -p $(for w in $(seq "$WORKERS"); do printf '%s ' "$D/$w"; done)" > /dev/null
WORKER='h=$(hostname -s); end=$((SECONDS + '"$WORK_S"')); for w in $(seq '"$WORKERS"'); do ( d='"$D"'/$w; i=0; while [ $SECONDS -lt $end ]; do : > $d/$h.$((i % 64)); rm -f $d/$h.$(((i + 32) % 64)); i=$((i + 1)); done; echo ops=$i ) & done; wait'
for n in ${NODES//,/ }; do
    rs $((WORK_S + 15)) "$n" "timeout $((WORK_S + 5)) bash -c '$WORKER'; echo work_rc=\$?" > "$OUT/${n}_work.txt" &
done
wait
for n in ${NODES//,/ }; do
    echo "  $n workload: $(grep -c '^ops=' "$OUT/${n}_work.txt") worker(s), $(awk -F= '/^ops=/{s+=$2} END{print s+0}' "$OUT/${n}_work.txt") create/unlink pairs, $(grep '^work_rc=' "$OUT/${n}_work.txt")"
done
exposed=""; fail=""
for n in ${NODES//,/ }; do
    v=$(rs 20 "$n" "echo 0 > $P/dbg_yield_scan_hold_us; cat $P/ag_bast_stall_iters $P/ag_yield_scan_overlap_n $P/ag_yield_scan_n $P/ag_yield_drain_n $P/dbg_yield_scan_hold_us 2>/dev/null | tr '\n' ' '")
    set -- $v
    [ "$#" = 5 ] || { echo "LAP yield_stall_global ABORT: $n's parameters unreadable after the workload: '$v'"; exit 2; }
    echo "  $n after the workload: ag_bast_stall_iters=$1 (prep loaded ${LOADED[$n]}) ag_yield_scan_overlap_n=$2 ag_yield_scan_n=$3 ag_yield_drain_n=$4 hold back to $5"
    [ "$2" -gt 0 ] && exposed="$exposed $n($2 of $3)"
    [ "$1" = "${LOADED[$n]}" ] || fail="$fail $n reads ag_bast_stall_iters=$1, prep loaded ${LOADED[$n]};"
done
rs 30 "${NODES%%,*}" "rm -rf $D" > /dev/null
[ -n "$exposed" ] && echo "EXPOSED: yield scans overlapped on:$exposed"
if [ -n "$fail" ]; then
    echo "LAP yield_stall_global FAIL label=$LABEL:$fail evidence=$OUT"; exit 1
fi
echo "LAP yield_stall_global PASS label=$LABEL: every node's ag_bast_stall_iters reads what prep loaded (overlaps:${exposed:- none}) evidence=$OUT"
exit 0
