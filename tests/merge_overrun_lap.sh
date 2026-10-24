#!/bin/bash
# merge_overrun_lap.sh -- one lap of D-FOURKN-MERGE-LAP-OVERRUN-LEAVES-ITS-WORKER-HOLDING-THE-MOUNT.
#
# tests/fourkn_merge_2node.sh bounded each node's workload (tests/fourkn_merge_worker.sh, run
# over ssh) only on the ssh client.  When the workload overran, the client gave up, but the
# worker went on running on the node, holding the mount, and every following lap aborted at
# its unmount before insmod (lane g2d_a14_merge2node_20261023T204131Z, laps 30-45 and 47-48).
# The fix runs the worker under `timeout --foreground` 3 s short of the client's bound, so it
# stops itself (WORKER_STOPPED) while the client still waits.  MERGE_NODE_BOUND=0 bounds the
# client alone, as before: the control (set it for the whole lap).
#
# SHAPE: one run of fourkn_merge_2node.sh with ROUNDS=$OVER_ROUNDS (default 200), which at the
# measured 6-8 s per 20 rounds (its header) takes 60-80 s against a workload bound of 16 s, so
# the client's bound always fires.  Then, $SETTLE_S (default 8) seconds after that run returns,
# each node's processes on the lap's mount (fuser -m) are counted.
#   EXPOSED  a worker's client bound fired: fourkn_merge_2node's workload INFO line shows rc=124
#   PASS     no process holds /mnt/fourkn on either node $SETTLE_S s after the run
#   FAIL     a process still holds it on some node
#   ABORT    the merge lap aborted before its workload (no workload INFO line)
# Afterwards any process left on the mount is ended (fuser -k) and the mount unmounted, so the
# next lap starts clean whatever this one found.
#
# Bounds (derived): fourkn_merge_2node.sh's own steps before the workload (preflight, insmod,
# mkfs, mounts) take under 60 s; the workload is cut at its 16 s client bound; the lap's
# unmounts, counters and chk_mxfs after it take under 130 s (its header).  So the merge run is
# bounded at 2 x (60 + 16 + 130) = 412 s here; the settle, the counts and the cleanup at 60 s
# a node.  A caller bounds the lap at 412 + 8 + 2 x 60 + 2 x 60 = 660 s.
#
# Usage: tests/merge_overrun_lap.sh <label> <dev> <node1> <node2>
# Env:   MXFS_CONFIG (as fourkn_merge_2node.sh), OVER_ROUNDS (200), SETTLE_S (8), MERGE_NODE_BOUND
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; DEV=${2:?device}; N1=${3:?node1}; N2=${4:?node2}
HERE="$(cd "$(dirname "$0")" && while [ ! -f run.sh ] && [ "$(pwd)" != / ]; do cd ..; done; pwd)"
[ -f "$HERE/run.sh" ] || { echo "ABORT: no tree root above $0"; exit 2; }
. "$HERE/tools/mxfs_lab.sh"
SSH="$HERE/tools/mxfs_sshpass.sh"
MNT=/mnt/fourkn
OVER_ROUNDS=${OVER_ROUNDS:-200}
SETTLE_S=${SETTLE_S:-8}
OUT=$HERE/tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_mergeoverrun_$LABEL
mkdir -p "$OUT"
on() { timeout "$3" "$SSH" "$(lab_addr "$1")" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'; }
echo "LAP merge_overrun start $(date -u +%FT%TZ) label=$LABEL dev=$DEV nodes=$N1,$N2 rounds=$OVER_ROUNDS settle_s=$SETTLE_S MERGE_NODE_BOUND=${MERGE_NODE_BOUND:-(unset)} out=$OUT"

ROUNDS=$OVER_ROUNDS timeout 412 "$HERE/tests/fourkn_merge_2node.sh" "$DEV" "$N1" "$N2" > "$OUT/merge.txt" 2>&1
mrc=$?
sleep "$SETTLE_S"
held=0
for n in "$N1" "$N2"; do
    c=$(on "$n" "fuser -m $MNT 2>/dev/null | wc -w; ps -o pid=,etimes=,args= -C bash -C fourkn_merge_wo 2>/dev/null | grep -a fourkn_merge_worker | head -3" 60)
    k=$(head -1 <<<"$c" | tr -dc 0-9)
    echo "  $n: ${k:-?} process(es) on $MNT $SETTLE_S s after the merge run; $(tail -n +2 <<<"$c" | tr '\n' '|' | cut -c1-200)"
    [ "${k:-0}" -gt 0 ] && held=$((held + 1))
done
for n in "$N1" "$N2"; do
    on "$n" "fuser -k -m $MNT >/dev/null 2>&1; sleep 2; grep -q ' $MNT ' /proc/mounts && timeout 55 umount $MNT; grep -c ' $MNT ' /proc/mounts" 60 > "$OUT/cleanup_$n.txt"
done
wl=$(grep -a 'INFO workload wall' "$OUT/merge.txt" | tail -1)
echo "  merge run rc=$mrc: ${wl:-no workload line}"
[ -n "$wl" ] || { echo "LAP merge_overrun ABORT: the merge lap ended before its workload: $(grep -a 'ABORT' "$OUT/merge.txt" | tail -1 | cut -c1-200)"; exit 2; }
if ! grep -q 'rc=124' <<<"$wl"; then
    echo "LAP merge_overrun VACUOUS: no worker's client bound fired, so nothing overran"
    exit 3
fi
echo "EXPOSED: a worker's client bound fired ($wl)"
if [ "$held" = 0 ]; then
    echo "LAP merge_overrun PASS: no process held $MNT on either node $SETTLE_S s after the overrun"
    exit 0
fi
echo "LAP merge_overrun FAIL: $held node(s) still had a process on $MNT $SETTLE_S s after the overrun"
exit 1
