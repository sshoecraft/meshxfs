#!/bin/bash
# rig_tag_dev_host_lap.sh -- one lap of D-RIG-TAG-READS-THE-DEV-HOSTS-OWN-DISK-FOR-A-NODE-DEVICE-PATH:
# tools/mxfs_rig_tag.sh run on the dev host for a NODE's device path that the
# dev host also has, the way run.sh's prep runs it when a harness re-preps a
# pair with the path the node's live mount shows (/dev/sda).
#
# The truth is what the node itself reads for that path: its SCSI vendor, the
# way the resolver's own probe reads it (the disk under a partition or a
# multipath map).  The lap is exposed when the dev host's own device at the same
# path has another vendor (clyde's /dev/sda is its ATA boot disk): only then can
# a resolver that reads the path locally on the dev host give the wrong rig.
#
#   PASS  the tag is the node's vendor
#   FAIL  the tag is anything else (the dev host's own disk, or nothing)
#
# Bound, derived: the resolver makes one ssh call bounded 25 s by itself, and
# this lap two more reads of ~1 s each, bounded 20 s; 25 + 2 * 20 = 65 s.
#
# Usage: tests/rig_tag_dev_host_lap.sh <node> [device]   (device default /dev/sda)
# Exit: 0 PASS, 1 FAIL, 2 the lap could not measure (node unreachable, no device).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
NODE=${1:?usage: rig_tag_dev_host_lap.sh <node> [device]}
DEV=${2:-/dev/sda}

sanitise() {  # as tools/mxfs_rig_tag.sh renders a vendor into a tag
    printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | tr -s ' _' '-' | tr -cd 'a-z0-9-'
}

local_b=$(basename "$(readlink -f "$DEV" 2>/dev/null)")
local_vendor=$(cat "/sys/block/$local_b/device/vendor" 2>/dev/null)
node_vendor=$(timeout 20 "$REPO/tools/mxfs_sshpass.sh" "$NODE" \
    "b=\$(basename \$(readlink -f $DEV)); [ -r /sys/block/\$b/device/vendor ] || b=\$(echo \$b | sed 's/[0-9]*\$//'); cat /sys/block/\$b/device/vendor" \
    2>/dev/null < /dev/null | tail -1)
want=$(sanitise "$node_vendor")
[ -n "$want" ] || { echo "ABORT: $NODE reports no SCSI vendor for $DEV"; exit 2; }
echo "INFO dev host $DEV vendor='$local_vendor'; $NODE $DEV vendor='$node_vendor'"
[ -n "$local_vendor" ] && [ "$(sanitise "$local_vendor")" != "$want" ] \
    && echo "EXPOSED: the dev host's own $DEV is another array ('$local_vendor') than $NODE's"

tag=$(MXFS_MARKER=/dev/null MXFS_RIG_TAG_FRESH=1 MXFS_RIG_NODE="$NODE" MXFS_DEV="$DEV" \
      timeout 30 "$REPO/tools/mxfs_rig_tag.sh" 2>/dev/null < /dev/null)
rc=$?
echo "INFO tools/mxfs_rig_tag.sh for $NODE:$DEV -> '$tag' (rc=$rc)"
if [ "$tag" = "$want" ]; then
    echo "RIG_TAG_LAP PASS tag=$tag is $NODE's array"
    exit 0
fi
echo "RIG_TAG_LAP FAIL tag='$tag' wanted '$want' ($NODE's array)"
exit 1
