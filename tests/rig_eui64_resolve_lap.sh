#!/bin/bash
# rig_eui64_resolve_lap.sh -- one lap of D-RIG-LIB-EUI64-LUN-ID-NORMALISED-WITH-STRAY-E-AND-NO-WWN-BYID-LINK:
# tests/lib/rig.sh resolving a pool pair's LUN on a node with no mxfs mount, the
# way a capture-gate entry that does not prep itself resolves it
# (d0980_barrier_killable, d0981_pending_victim_sweep, prep_heartbeat_writer_guard,
# chk_mounted_node_reads_platter aborted "no MXFS device basis" on 0.90.134).
#
# With no MXFS_DEV, no live mount and no MXFS_CONFIG, the resolver's only basis
# is the declared LUN found by its own identifier: the pool allocation bound to
# MXFS_NODE_LIST names the LUN's WWID, and the node's /dev/disk/by-id link for
# that WWID is the device.  The pooled SCST LUNs are EUI-64 (wwid eui.<hex>),
# which udev links as scsi-2<hex> only.
#
#   EXPOSED  the node's LUN reports an EUI-64 WWID (an NAA one resolves either way)
#   PASS     the resolver binds the node's LUN by its identifier (source=declared-wwid)
#   FAIL     it aborts, or binds anything else
#
# The node must hold the pool LUN with no mxfs mount (the state
# tests/chk_freespace_rebuild_lap.sh leaves a pair in); with a mount the
# resolver takes the mount and the lap cannot measure.
#
# Bound, derived: the resolver's own reads (rig tag over ssh 25 s bound, the
# pool lookup ~1 s, two ssh queries bounded 20 and 25 s) and two reads of this
# lap's (20 s each), each ~1 s when the node answers: 25+1+20+25+2*20 = 111 -> 120 s.
#
# Usage: tests/rig_eui64_resolve_lap.sh <node1,node2> <group>   (the allocation's node set)
# Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
set -u
cd "$(dirname "$0")/.." || exit 2
NODES=${1:?usage: rig_eui64_resolve_lap.sh <node1,node2> <group>}
GROUP=${2:?usage: rig_eui64_resolve_lap.sh <node1,node2> <group>}
N=${NODES%%,*}
. tests/lib/rig.sh
OUT=tests/evidence/rig_eui64_resolve/$(date -u +%Y%m%dT%H%M%SZ)_$N
mkdir -p "$OUT" || exit 2
LABEL=rig_eui64_resolve

wwid=$(rs 20 "$N" "cat /sys/block/sda/device/wwid" | tail -1)
mounts=$(rs 20 "$N" "awk '\$3==\"mxfs\"' /proc/mounts | wc -l" | grep -E '^[0-9]+$' | tail -1)
echo "INFO $N sda wwid='$wwid' mxfs mounts=${mounts:-?}"
[ "${mounts:-x}" = 0 ] || { echo "ABORT: $N has ${mounts:-unknown} mxfs mount(s); the lap needs the no-mount path"; exit 2; }
case $wwid in eui.*) echo "EXPOSED: $N's pool LUN is EUI-64 ($wwid)" ;; esac

( unset MXFS_DEV MXFS_CONFIG MXFS_LUN_WWID MXFS_RIG_TAG
  export MXFS_NODE_LIST=$NODES MXFS_GROUP=$GROUP MXFS_MARKER=$PWD/.cluster_marker.$GROUP.json
  mxfs_dev_resolve "$N" ) > "$OUT/resolve.txt" 2>&1
rc=$?
sed 's/^/  | /' "$OUT/resolve.txt"
line=$(grep -a "^DEVICE node=$N " "$OUT/resolve.txt" | tail -1)
case $line in
    *" source=declared-wwid "*)
        echo "RIG_EUI64_LAP PASS $line"; exit 0 ;;
esac
echo "RIG_EUI64_LAP FAIL rc=$rc ${line:-$(grep -a '^ABORT' "$OUT/resolve.txt" | head -1)}"
exit 1
