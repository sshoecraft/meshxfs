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
#   EXPOSED  the workload ran into its bound: fourkn_merge_2node's workload wall reached the
#            worker's node-side bound (its workload bound less 3 s).  The ssh rc on that line
#            cannot say so: it is the exit of the grep that filters the client's output, 1 when
#            a killed client printed nothing and 0 when a worker printed WORKER_STOPPED.
#   PASS     on neither node is $MNT still mounted, or a fourkn_merge_worker.sh still running,
#            $SETTLE_S s after the run (fourkn_merge_2node.sh unmounts both nodes before it
#            returns, on its ABORT path too, so a mount left behind is one it could not unmount)
#   FAIL     either is so on some node, or the cleanup below ended a node's own service (the
#            main pid of ssh, systemd-journald, systemd-udevd or iscsid changed across it)
#   ABORT    the merge lap aborted before its workload (no workload INFO line)
# fuser -m is not the measure: on a directory that is no longer a mount point it counts every
# user of the root filesystem, and it misses a worker that has no file open at that instant.
# Afterwards any worker left is ended and, only while $MNT is still a mount point, any process
# on it (fuser -k) and the mount unmounted, so the next lap starts clean whatever this one
# found.  Run on a directory that was no longer a mount point, fuser -k -m SIGKILLed every user
# of each node's root filesystem, sshd and the node's daemons with it: every cleanup of a
# passing lap ended 'Connection to <node> closed by remote host'
# (D-MERGE-OVERRUN-LAP-CLEANUP-FUSER-KILLS-ROOT-FS-USERS-WHEN-NOT-MOUNTED).  MERGE_CLEANUP_GATE=0
# runs it unconditionally, as before: the control.
#
# Bounds (derived): fourkn_merge_2node.sh's own steps before the workload (preflight, insmod,
# mkfs, mounts) take under 60 s; the workload is cut at its 16 s client bound; the lap's
# unmounts, counters and chk_mxfs after it take under 130 s (its header).  So the merge run is
# bounded at 2 x (60 + 16 + 130) = 412 s here; the settle, the counts and the cleanup at 60 s
# a node, and the reads of the node's service pids either side of its cleanup 30 s each plus a
# 2 s settle.  A caller bounds the lap at 412 + 8 + 2 x 60 + 2 x (60 + 2 x 30 + 2) = 784 s.
#
# Usage: tests/merge_overrun_lap.sh <label> <dev> <node1> <node2>
# Env:   MXFS_CONFIG (as fourkn_merge_2node.sh), OVER_ROUNDS (200), SETTLE_S (8), MERGE_NODE_BOUND
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; DEV=${2:?device}; N1=${3:?node1}; N2=${4:?node2}
# the tree root holds run.sh and tools/mxfs_lab.sh both: a draft of run.sh alone beside the lap
# is not a root
HERE="$(cd "$(dirname "$0")" && while { [ ! -f run.sh ] || [ ! -f tools/mxfs_lab.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done; pwd)"
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
unmounted=0
for n in "$N1" "$N2"; do
    # the worker runs as a script, so its comm is fourkn_merge_wo; -C alone matches no ssh shell
    c=$(on "$n" "echo mounted=\$(grep -c ' $MNT ' /proc/mounts) workers=\$(ps -o pid= -C fourkn_merge_wo | wc -l); ps -o pid=,etimes=,args= -C fourkn_merge_wo | head -3" 60)
    m=$(sed -n 's/.*mounted=\([0-9]*\).*/\1/p' <<<"$c" | head -1)
    w=$(sed -n 's/.*workers=\([0-9]*\).*/\1/p' <<<"$c" | head -1)
    echo "  $n: mounted=${m:-?} workers=${w:-?} $SETTLE_S s after the merge run; $(grep -av 'mounted=' <<<"$c" | tr '\n' '|' | cut -c1-200)"
    [ -n "$m" ] && [ -n "$w" ] || { echo "LAP merge_overrun ABORT: $n's mount and worker count unreadable: $(tr '\n' '|' <<<"$c" | cut -c1-200)"; exit 2; }
    [ "$m" -gt 0 ] || [ "$w" -gt 0 ] && held=$((held + 1))
    [ "$m" = 0 ] && unmounted=$((unmounted + 1))
done
SVCS="ssh systemd-journald systemd-udevd iscsid"
svcpids() { on "$1" "echo SVCPIDS \$(systemctl show -p MainPID --value $SVCS 2>/dev/null | tr '\n' ' ')" 30 | grep -a '^SVCPIDS ' | tail -1; }
GATE="grep -q ' $MNT ' /proc/mounts && "
[ "${MERGE_CLEANUP_GATE:-1}" = 0 ] && GATE=""
killed=0
for n in "$N1" "$N2"; do
    before=$(svcpids "$n")
    on "$n" "kill \$(ps -o pid= -C fourkn_merge_wo) 2>/dev/null; sleep 1; ${GATE}{ fuser -k -m $MNT >/dev/null 2>&1; sleep 2; }; grep -q ' $MNT ' /proc/mounts && timeout 55 umount $MNT; grep -c ' $MNT ' /proc/mounts" 60 > "$OUT/cleanup_$n.txt"
    sleep 2
    after=$(svcpids "$n")
    echo "  $n: cleanup $(tr '\n' '|' < "$OUT/cleanup_$n.txt" | cut -c1-120); main pids of $SVCS: before [${before#SVCPIDS }] after [${after#SVCPIDS }]"
    [ -n "$before" ] || { echo "LAP merge_overrun ABORT: $n's service pids unreadable before the cleanup"; exit 2; }
    # unreadable after it is the same harm: the cleanup took the node's ssh down with the rest
    [ "$before" = "$after" ] || killed=$((killed + 1))
done
# the cleanup is graded on every lap, VACUOUS ones too: it runs whether or not the workload overran
echo "CLEANUP: $unmounted node(s) had $MNT no longer mounted when the cleanup ran"
if [ "$killed" != 0 ]; then
    echo "LAP merge_overrun FAIL: the cleanup ended a service on $killed node(s) (a main pid of $SVCS changed across it)"
    exit 1
fi
wl=$(grep -a 'INFO workload wall' "$OUT/merge.txt" | tail -1)
echo "  merge run rc=$mrc: ${wl:-no workload line}"
[ -n "$wl" ] || { echo "LAP merge_overrun ABORT: the merge lap ended before its workload: $(grep -a 'ABORT' "$OUT/merge.txt" | tail -1 | cut -c1-200)"; exit 2; }
wall=$(sed -n 's/.*INFO workload wall \([0-9]*\) ms.*/\1/p' <<<"$wl")
wb=$(grep -a 'workload bound [0-9]*s' "$OUT/merge.txt" | tail -1 | sed -n 's/.*workload bound \([0-9]*\)s.*/\1/p')
[ -n "$wall" ] && [ -n "$wb" ] || { echo "LAP merge_overrun ABORT: no workload wall or bound in the merge lap's output"; exit 2; }
if [ "$wall" -lt $(( (wb - 3) * 1000 )) ]; then
    echo "LAP merge_overrun VACUOUS: the workload took $wall ms, short of the worker's node-side bound $(( wb - 3 )) s, so nothing overran"
    exit 3
fi
echo "EXPOSED: the workload ran $wall ms against a node-side bound of $(( wb - 3 )) s and a client bound of $wb s ($wl)"
if [ "$held" = 0 ]; then
    echo "LAP merge_overrun PASS: neither node had $MNT mounted or a worker running $SETTLE_S s after the overrun"
    exit 0
fi
echo "LAP merge_overrun FAIL: $held node(s) still had $MNT mounted or a worker running $SETTLE_S s after the overrun"
exit 1
