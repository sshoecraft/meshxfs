#!/bin/bash
# chk_freespace_rebuild_lap.sh -- one lap of the free-space rebuild control with
# its data case (D-CHK-FREESPACE-REBUILD-DECLARES-OWNED-BLOCKS-FREE-AGFL-LOG-AND-DATA):
# tests/chk_freespace_rebuild_controls.sh run on the first node of a rig pair
# against the pair's own pool LUN, with the tree's chk_mxfs and mkfs_mxfs as the
# node sees them (/src/mxfs/tools), so a lap measures the checker built in the
# tree at that moment.
#
# The node needs the tree's module loaded, for the lone mount that puts a
# file's blocks in an AG with no inodes, and the LUN unmounted, since it is
# formatted.  So the lap forms the pair (run.sh <config> --group <group>
# prep_cluster) when node 1's module is not the tree's build, then unmounts
# /mnt/shared on both nodes.  It leaves the LUN holding its 4 GiB volume,
# unmounted; the pair's next prep formats it again.
#
# Bound, derived: prep_cluster's own manifest budget (tests/suite/manifest,
# 300 s) when it runs; each unmount ~2 s, bounded 10 s; the node harness, its
# own sum (format 5 s, lone mount 10 s, fallocate and sync 10 s, unmount 10 s,
# eight checks at 2 s each) ~50 s, bounded at twice that, 100 s; each ssh
# connects within 5 s.  A lap with the prep: 300 + 2 * 15 + 105 + 2 * 20 = 475 s.
#
# Usage: tests/chk_freespace_rebuild_lap.sh <label> <group> <config>
# Prints the node harness's lines; its last === line is the verdict.
# Exit: the node harness's (0 PASS, 1 FAIL, 2 ABORT), 2 when the lap cannot
# start it.
set -u
LABEL=${1:?label}
GROUP=${2:?group}
CONFIG=${3:?config}
cd "$(dirname "$0")/.." || exit 2
read -r N1 N2 _ <<<"$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${N1:-}" ] && [ -n "${N2:-}" ] || { echo "ABORT: rig group $GROUP names no pair"; exit 2; }
SSH=tools/mxfs_sshpass.sh
MARKER=.cluster_marker.$GROUP.json
SV=$(modinfo -F srcversion mxfs.ko)
node_sv() { timeout 20 "$SSH" "$N1" 'cat /sys/module/mxfs/srcversion 2>/dev/null' 2>/dev/null | tr -d '\r' | tail -1; }
echo "=== chk_freespace_rebuild_lap label=$LABEL group=$GROUP ($N1 $N2) config=$CONFIG build=$SV $(date -u +%FT%TZ) ==="
nsv=$(node_sv)
if [ "$nsv" != "$SV" ]; then
    echo "  INFO $N1 has module '${nsv:-none}', the tree's is $SV: forming the pair"
    env -u MXFS_BATCH ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > /dev/null 2>&1
    nsv=$(node_sv)
    [ "$nsv" = "$SV" ] || { echo "ABORT: after the prep $N1 has module '${nsv:-none}', not $SV"; exit 2; }
fi
DEV=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("dev", ""))' "$MARKER" 2>/dev/null)
[ -n "$DEV" ] || { echo "ABORT: $MARKER names no device"; exit 2; }
for n in "$N1" "$N2"; do
    left=$(timeout 15 "$SSH" "$n" "timeout 10 umount /mnt/shared 2>/dev/null; grep -c ' /mnt/shared ' /proc/mounts" 2>/dev/null | tr -d '\r' | tail -1)
    [ "$left" = 0 ] || { echo "ABORT: /mnt/shared is still mounted on $n (${left:-no answer})"; exit 2; }
done
echo "  INFO $N1 runs the controls on $DEV (both nodes unmounted)"
timeout 105 "$SSH" "$N1" "DEV=$DEV bash /src/mxfs/tests/chk_freespace_rebuild_controls.sh $LABEL /src/mxfs/tools/chk_mxfs /src/mxfs/tools/mkfs_mxfs 512" 2>&1 | tr -d '\r'
rc=${PIPESTATUS[0]}
[ "$rc" = 124 ] && echo "=== chk_freespace_rebuild_lap $LABEL: the node harness overran its 100 s bound"
exit "$rc"
