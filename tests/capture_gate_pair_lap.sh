#!/bin/bash
# capture_gate_pair_lap.sh -- one lap of D-CAPTURE-GATE-ENTRIES-INHERIT-THE-CLUSTER-STATE-AN-EARLIER-FAULT-LEFT.
#
# tests/capture_fault_gate.sh runs its entries back to back.  An injected fault or an entry's own
# kill arm can leave a node unmounted, destroyed or without its module, and the next entry that
# does not prep itself then aborted on that before its first measurement: the 0.90.134 gate read
# 13 entries BROKEN that way (prep_heartbeat_writer_guard, d0980, d0981 and
# chk_mounted_node_reads_platter found no live mount on test1).  The fix: the gate checks the pair
# before every lap and forms it again when it is not formed (pair_ready).
#
# The lap leaves the pair as those entries found it, test1 unmounted, then runs the gate's healthy
# lap of prep_heartbeat_writer_guard, an entry that does not prep itself and resolves its device
# through test1's live mount.  GATE_PAIR_RESTORE passes through: 0 is the gate's own switch back to
# no check, the control.
#
#   EXPOSED  test1 held no mxfs mount when the gate started (the entry would start on a pair an
#            earlier lap left broken)
#   PASS     the gate's lap of the entry was OK (the pair was formed again first)
#   FAIL     the entry was BROKEN
#   ABORT    test1 could not be unmounted, or the gate ended without grading the entry
#
# Bound, derived: test1's unmount 60 s; the gate's restore (the nodes are up, so the ssh wait ends at
# once; prep_cluster measured 37-43 s a restore) plus the entry's own 60 s healthy timeout and the
# gate's checks (~20 s): about 125 s.  Bounded at 240 s.  The pair is left as the entry leaves it
# (test1 unmounted): the next lap starts broken again by construction.
#
# Usage: tests/capture_gate_pair_lap.sh <label>   (the g2 pair, its group's env exported)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
cd "$(dirname "$0")/.." || exit 2
MNT=${MXFS_MOUNT:-/mnt/shared}
um=$(timeout 60 tools/mxfs_sshpass.sh test1 "grep -q ' $MNT mxfs ' /proc/mounts && umount $MNT; echo m=\$(grep -c ' $MNT mxfs ' /proc/mounts)" < /dev/null 2>/dev/null | grep -a '^m=' | tail -1)
[ "$um" = "m=0" ] || { echo "LAP gate_pair ABORT: test1 could not be left unmounted ($um)"; exit 2; }
echo "EXPOSED: test1 holds no mxfs mount as the gate starts (restore=${GATE_PAIR_RESTORE:-1})"
out=$(timeout 230 tests/capture_fault_gate.sh "$LABEL" --healthy-only --only prep_heartbeat_writer_guard < /dev/null 2>&1)
echo "$out" | grep -a '^PAIR\|^GATE\|^RESULT\|^ABORT' | cut -c1-300
line=$(echo "$out" | grep -a '^GATE prep_heartbeat_writer_guard healthy:' | tail -1)
case "$line" in
    *'-> OK') echo "LAP gate_pair PASS: the entry's lap was OK on a pair the gate formed again"; exit 0 ;;
    *'-> BROKEN') echo "LAP gate_pair FAIL: the entry was BROKEN on the pair an earlier lap left"; exit 1 ;;
esac
echo "LAP gate_pair ABORT: the gate graded no lap of the entry"
exit 2
