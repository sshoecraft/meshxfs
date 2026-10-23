#!/bin/bash
# rig_pool_default_resolve_lap.sh -- one lap of D-RIG-LIB-CONFIGURATION-DEFAULT-ON-A-POOL-RIG-IS-THE-FIXED-RIG-LUN:
# tests/lib/rig.sh falling back to the configuration's device on a pool pair's node with no mxfs
# mount, as tests/rig_lib_contract.sh check 13j does (the 0.90.134 dry run's presteps failed it).
#
# With no MXFS_DEV, no live mount and no /dev/disk/by-id link carrying the declared LUN's
# identifier, the resolver takes the configuration's device as its candidate and checks that
# candidate's identity against the declaration. On a pool rig the configuration names the path of
# the fixed rig LUN, which no pool node is logged in to; the device of the LUN the pool bound to
# these nodes is the allocation's dev=, which run.sh takes too. The lap declares a LUN that exists
# nowhere, so no by-id link matches and the fallback is reached, and reads which candidate the
# resolver checked from its abort.
#
#   EXPOSED  the configuration's own device path is not a block device on the node (a pool rig)
#   PASS     the resolver aborts naming the identity mismatch of the pool LUN's device
#            ("is not the declared LUN", source=configuration-default)
#   FAIL     it aborts on the configuration's path ("is not a block device"), or on anything else
#
# MXFS_RIG_POOL_DEFAULT=0 (tests/lib/rig.sh) takes the configuration's path as before the fix:
# the fix's control. The node must hold the pool LUN with no mxfs mount.
#
# Bound, derived: the resolver's own reads (rig tag over ssh 25 s bound, the pool lookup ~1 s,
# ssh queries bounded 20, 20 and 25 s) and two reads of this lap's (20 s each), each ~1 s when
# the node answers: 25+1+20+20+25+2*20 = 131 -> 140 s.
#
# Usage: tests/rig_pool_default_resolve_lap.sh <node1,node2> <group> <configuration>
# Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
set -u
cd "$(dirname "$0")/.." || exit 2
NODES=${1:?usage: rig_pool_default_resolve_lap.sh <node1,node2> <group> <configuration>}
GROUP=${2:?usage: rig_pool_default_resolve_lap.sh <node1,node2> <group> <configuration>}
CONFIG=${3:?usage: rig_pool_default_resolve_lap.sh <node1,node2> <group> <configuration>}
N=${NODES%%,*}
. tests/lib/rig.sh
OUT=tests/evidence/rig_pool_default_resolve/$(date -u +%Y%m%dT%H%M%SZ)_$N
mkdir -p "$OUT" || exit 2
LABEL=rig_pool_default_resolve
echo "INFO MXFS_RIG_POOL_DEFAULT=${MXFS_RIG_POOL_DEFAULT:-(unset)}"

path=$(python3 tools/configuration.py get "$CONFIG" device) || { echo "ABORT: $CONFIG is not a configuration"; exit 2; }
mounts=$(rs 20 "$N" "awk '\$3==\"mxfs\"' /proc/mounts | wc -l" | grep -E '^[0-9]+$' | tail -1)
there=$(rs 20 "$N" "test -b '$path' && echo BLOCK || echo ABSENT" | grep -E '^(BLOCK|ABSENT)$' | tail -1)
echo "INFO $N: $CONFIG's device $path is ${there:-unknown}; mxfs mounts=${mounts:-?}"
[ "${mounts:-x}" = 0 ] || { echo "ABORT: $N has ${mounts:-unknown} mxfs mount(s); the lap needs the no-mount path"; exit 2; }
[ "${there:-x}" = ABSENT ] && echo "EXPOSED: $CONFIG's own device path is not a block device on $N (a pool rig)"

( unset MXFS_DEV MXFS_RIG_TAG
  export MXFS_NODE_LIST=$NODES MXFS_GROUP=$GROUP MXFS_MARKER=$PWD/.cluster_marker.$GROUP.json
  export MXFS_LUN_WWID=naa.0000000000000000000000000000dead MXFS_CONFIG=$CONFIG
  mxfs_dev_resolve "$N" ) > "$OUT/resolve.txt" 2>&1
rc=$?
sed 's/^/  | /' "$OUT/resolve.txt"
abort=$(grep -a '^ABORT' "$OUT/resolve.txt" | head -1)
case $rc:$abort in
    2:*" is not the declared LUN: "*"(source=configuration-default)"*)
        echo "RIG_POOL_DEFAULT_LAP PASS $abort"; exit 0 ;;
esac
echo "RIG_POOL_DEFAULT_LAP FAIL rc=$rc ${abort:-$(tail -1 "$OUT/resolve.txt")}"
exit 1
