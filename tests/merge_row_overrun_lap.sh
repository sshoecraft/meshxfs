#!/bin/bash
# merge_row_overrun_lap.sh -- one lap of D-FOURKN-MERGE-SUITE-ROW-WORKER-BOUNDED-ONLY-ON-THE-SSH-CLIENT.
#
# tests/suite/fourkn_merge.sh, the board's merged-write row on a 4K-native volume, ran each
# node's tests/fourkn_merge_worker.sh bounded only on the ssh client, as tests/fourkn_merge_2node.sh
# did before its node-side bound: a workload that overran the client's bound left the worker
# running on the node with the mount open after the row had ended.  The fix runs the worker under
# `timeout --foreground` 3 s inside the client's bound (tests/suite/fourkn_merge.sh:155-165), so it
# stops itself (WORKER_STOPPED) while the client still waits.  FOURKN_MERGE_NODE_BOUND=0 bounds the
# client alone, as before: the control (set it for the whole lap).
#
# SHAPE: one run of the row script itself, with the environment run.sh hands a host row
# (run.sh run_host: MXFS_NODES, MXFS_NODE_LIST, MXFS_DEV, MXFS_MNT, MXFS_RUN_ID), on a pair formed
# on a 4096-byte LUN and mounted at $MNT, with ROUNDS=$OVER_ROUNDS (default 200).  The row's
# derivation puts 20 rounds at about 2.6 s, so 200 rounds take well past its 16 s workload bound
# and the bound fires.  The row is run directly, not through run.sh, so the overrun this lap forces
# records no board run.  Then, $SETTLE_S (default 8) seconds after the row returns, each node's
# workers (comm fourkn_merge_wo) are counted.
#   EXPOSED  the workload ran into its bound: the row's workload wall reached the worker's
#            node-side bound (its workload bound less 3 s)
#   PASS     no fourkn_merge_worker.sh runs on either node $SETTLE_S s after the row
#   FAIL     one still runs on some node
#   ABORT    the row ended before its workload (no workload INFO line), or a count is unreadable
#   VACUOUS  the workload ended inside the node-side bound, so nothing overran
# Afterwards any worker left is ended and a node that no longer has $MNT mounted mounts it again,
# so the next lap finds the pair as the row expects it.  No fuser: on a directory that is not a
# mount point it counts, and kills, every user of the root filesystem
# (D-MERGE-OVERRUN-LAP-CLEANUP-FUSER-KILLS-ROOT-FS-USERS-WHEN-NOT-MOUNTED).
#
# Bounds (derived): the row's budget is 55 s at the defaults (tests/suite/fourkn_merge.sh header),
# and with the workload cut at the same 16 s client bound the row is no longer, so it is bounded
# at 2 x 55 = 110 s here; the settle 8 s; the counts 20 s a node; the cleanup 60 s a node (a kill,
# a mount of up to 55 s).  A caller bounds the lap at 110 + 8 + 2 x 20 + 2 x 60 = 278 s.
#
# Usage: tests/merge_row_overrun_lap.sh <label> <dev> <node1> <node2>
# Env:   OVER_ROUNDS (200), SETTLE_S (8), MNT (/mnt/shared), MXFS_MOUNT_OPTS, FOURKN_MERGE_NODE_BOUND
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; DEV=${2:?device}; N1=${3:?node1}; N2=${4:?node2}
# the tree root holds run.sh and tools/mxfs_lab.sh both: a draft of run.sh alone beside the lap
# is not a root
HERE="$(cd "$(dirname "$0")" && while { [ ! -f run.sh ] || [ ! -f tools/mxfs_lab.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done; pwd)"
[ -f "$HERE/run.sh" ] || { echo "ABORT: no tree root above $0"; exit 2; }
. "$HERE/tools/mxfs_lab.sh"
SSH="$HERE/tools/mxfs_sshpass.sh"
MNT=${MNT:-/mnt/shared}
OVER_ROUNDS=${OVER_ROUNDS:-200}
SETTLE_S=${SETTLE_S:-8}
OUT=$HERE/tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_mergerowoverrun_$LABEL
mkdir -p "$OUT"
on() { timeout "$3" "$SSH" "$(lab_addr "$1")" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'; }
echo "LAP merge_row_overrun start $(date -u +%FT%TZ) label=$LABEL dev=$DEV nodes=$N1,$N2 mnt=$MNT rounds=$OVER_ROUNDS settle_s=$SETTLE_S FOURKN_MERGE_NODE_BOUND=${FOURKN_MERGE_NODE_BOUND:-(unset)} out=$OUT"

MXFS_NODES=2 MXFS_NODE_LIST="$N1,$N2" MXFS_DEV="$DEV" MXFS_MNT="$MNT" MXFS_RUN_ID="mro_$LABEL" \
    ROUNDS=$OVER_ROUNDS timeout --kill-after=5 110 bash "$HERE/tests/suite/fourkn_merge.sh" > "$OUT/row.txt" 2>&1
rrc=$?
sleep "$SETTLE_S"
held=0
for n in "$N1" "$N2"; do
    # the worker runs as a script, so its comm is fourkn_merge_wo; -C alone matches no ssh shell
    c=$(on "$n" "echo workers=\$(ps -o pid= -C fourkn_merge_wo | wc -l); ps -o pid=,etimes=,args= -C fourkn_merge_wo | head -3" 20)
    w=$(sed -n 's/.*workers=\([0-9]*\).*/\1/p' <<<"$c" | head -1)
    echo "  $n: workers=${w:-?} $SETTLE_S s after the row; $(grep -av 'workers=' <<<"$c" | tr '\n' '|' | cut -c1-200)"
    [ -n "$w" ] || { echo "LAP merge_row_overrun ABORT: $n's worker count unreadable: $(tr '\n' '|' <<<"$c" | cut -c1-200)"; exit 2; }
    [ "$w" -gt 0 ] && held=$((held + 1))
done
for n in "$N1" "$N2"; do
    on "$n" "kill \$(ps -o pid= -C fourkn_merge_wo) 2>/dev/null; sleep 1; grep -q ' $MNT mxfs ' /proc/mounts || timeout 55 mount -t mxfs ${MXFS_MOUNT_OPTS:-} $DEV $MNT; echo mounted=\$(grep -c ' $MNT mxfs ' /proc/mounts)" 60 > "$OUT/cleanup_$n.txt"
    echo "  $n: cleanup $(tr '\n' '|' < "$OUT/cleanup_$n.txt" | cut -c1-120)"
done
res=$(grep -a '^RESULT:' "$OUT/row.txt" | tail -1)
wl=$(grep -a 'INFO workload wall' "$OUT/row.txt" | tail -1)
echo "  row rc=$rrc: ${res:-no RESULT line}"
echo "  ${wl:-no workload line}"
[ -n "$wl" ] || { echo "LAP merge_row_overrun ABORT: the row ended before its workload: ${res:-$(tail -1 "$OUT/row.txt" | cut -c1-200)}"; exit 2; }
wall=$(sed -n 's/.*INFO workload wall \([0-9]*\) ms.*/\1/p' <<<"$wl")
wb=$(grep -a 'workload bound [0-9]*s' "$OUT/row.txt" | tail -1 | sed -n 's/.*workload bound \([0-9]*\)s.*/\1/p')
[ -n "$wall" ] && [ -n "$wb" ] || { echo "LAP merge_row_overrun ABORT: no workload wall or bound in the row's output"; exit 2; }
if [ "$wall" -lt $(( (wb - 3) * 1000 )) ]; then
    echo "LAP merge_row_overrun VACUOUS: the workload took $wall ms, short of the worker's node-side bound $(( wb - 3 )) s, so nothing overran"
    exit 3
fi
echo "EXPOSED: the row's workload ran $wall ms against a node-side bound of $(( wb - 3 )) s and a client bound of $wb s"
if [ "$held" = 0 ]; then
    echo "LAP merge_row_overrun PASS: no worker ran on either node $SETTLE_S s after the row's overrun"
    exit 0
fi
echo "LAP merge_row_overrun FAIL: a worker still ran on $held node(s) $SETTLE_S s after the row's overrun"
exit 1
