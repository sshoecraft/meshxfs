#!/bin/bash
# drbd_rig_tag_lap.sh -- one lap of
# D-DRBD-FIO-PERF-VS-XFS-SKIPS-RIG-UNKNOWN-SO-THE-DRBD-BOARD-CANNOT-GO-GREEN, on
# the DRBD rig: scripts/drbd_rig.sh up has brought the pair up, so /dev/drbd0
# exists on NODE.
#
# fio_perf_vs_xfs picks its native-XFS yardstick by rig tag, and the tag comes
# from tools/mxfs_rig_tag.sh.  A DRBD device has no SCSI vendor of its own, so
# the resolver found none for /dev/drbd0 and the row recorded SKIP rig-unknown
# on every DRBD board, while a rig-tagged yardstick for net-mesh-drbd existed.
# The fix resolves a DRBD device through its backing disk (drbdsetup show) and
# tags it <vendor>-drbd.
#
# The lap does what a DRBD board does with the device, nothing else:
#   1. the resolution run.sh's marker_write makes at prep (run.sh:262: a fresh
#      resolve, the first node asked over ssh from this host), into a scratch
#      marker shaped as run.sh writes it (node_list, dev, rig);
#   2. tests/suite/fio_perf_vs_xfs.sh run on NODE from the tree over NFS, as the
#      suite's detectors run on the nodes, reading that marker; with no rig in
#      it the row resolves the device again, locally on the node.
#
#   EXPOSED  /dev/drbd0 on NODE is a DRBD device over a backing disk, and the
#            net-mesh-drbd yardstick on this host is rig-tagged, so a row that
#            cannot resolve the tag declines to score
#   PASS     the row scored against a -drbd rig's yardstick (its RESULT is PASS
#            or FAIL and names rig=<vendor>-drbd); a FAIL of the row's own
#            throughput threshold is a measurement, not this defect
#   FAIL     the row recorded SKIP, or prep's resolution gave no -drbd tag
#   ABORT    not exposed, an ssh or step overran its bound, or no RESULT line
#
# The control is MXFS_RIG_TAG_DRBD=0 in this lap's environment, passed to both
# resolutions: tools/mxfs_rig_tag.sh then reads a DRBD device like any other
# disk, finds no vendor and resolves nothing, as before the fix.
#
# Bounds, derived: every ssh is bounded at 25 s, the resolver's own bound for
# its node read (tools/mxfs_rig_tag.sh); the host's resolution is one such read
# plus local work, 30 s.  A lap is three node reads and one resolution; a batch
# bounds the whole lap at twice what its precheck measures.  An overrun is an
# ABORT, never a reason to raise a bound.
#
# Usage: tests/drbd_rig_tag_lap.sh <label> [node=test1] [peer=test2]
#        MXFS_RIG_TAG_DRBD=0 tests/drbd_rig_tag_lap.sh <label> ...   (control)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
LABEL=${1:?label}; NODE=${2:-test1}; PEER=${3:-test2}
DEV=/dev/drbd0; CONFIG=2/net/mesh/drbd; SHAPE=net-mesh-drbd
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
. "$HERE/tools/mxfs_lab.sh"
SSH="$HERE/tools/mxfs_sshpass.sh"
NREPO=/src/$(basename "$HERE")
SW=${MXFS_RIG_TAG_DRBD:-1}
OUTREL=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_drbdrigtag_$LABEL
OUT=$HERE/$OUTREL
mkdir -p "$OUT"
exec > >(tee -a "$OUT/lap.log") 2>&1
t0=$(date +%s%3N)
el() { echo "$(( $(date +%s%3N) - t0 )) ms"; }
nsh() {  # nsh <command>: one bounded ssh to NODE, its banner lines dropped; rc in PIPESTATUS
    timeout 25 "$SSH" "$(lab_addr "$NODE")" "$1" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'
}
echo "LAP drbd_rig_tag start $(date -u +%FT%TZ) node=$NODE peer=$PEER dev=$DEV tree=$NREPO MXFS_RIG_TAG_DRBD=${MXFS_RIG_TAG_DRBD:-unset} out=$OUT"

# --- exposure: the device is DRBD over a backing disk, and the yardstick is tagged
nsh "readlink -f $DEV; drbdsetup show" > "$OUT/node_drbd.txt"
[ "${PIPESTATUS[0]}" = 124 ] && { echo "LAP drbd_rig_tag ABORT: the exposure read on $NODE overran 25 s"; exit 2; }
real=$(head -1 "$OUT/node_drbd.txt")
minor=$(basename "$real" | sed -n 's/^drbd\([0-9][0-9]*\)$/\1/p')
disk=$(awk -v m="$minor" '$1 == "device" && $2 == "minor" { gsub(/;/, "", $3); cur = $3 }
    $1 == "disk" && $2 ~ /^"\// && cur == m { gsub(/[";]/, "", $2); print $2; exit }' "$OUT/node_drbd.txt")
tagged=$(ls "$HERE"/.xfs_fio_baseline.$SHAPE.*.json 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')
if [ -z "$minor" ] || [ -z "$disk" ] || [ -z "$tagged" ]; then
    echo "LAP drbd_rig_tag ABORT: not exposed ($DEV on $NODE is '${real:-nothing}', minor='$minor', backing disk='$disk'; tagged $SHAPE yardsticks: '${tagged:-none}'); is the DRBD pair up (scripts/drbd_rig.sh up)?"
    exit 2
fi
echo "EXPOSED: $DEV on $NODE is DRBD minor $minor over $disk, and the $SHAPE yardstick is rig-tagged ($tagged)"

# --- 1. prep's resolution, as run.sh marker_write makes it ------------------
tag=$(MXFS_RIG_TAG_FRESH=1 MXFS_RIG_NODE="$NODE" MXFS_DEV="$DEV" MXFS_MARKER="$OUT/no_marker.json" \
      MXFS_RIG_TAG_DRBD="$SW" timeout 30 env -u MXFS_RIG_TAG "$HERE/tools/mxfs_rig_tag.sh" "$DEV" 2>/dev/null)
trc=$?
[ "$trc" = 124 ] && { echo "LAP drbd_rig_tag ABORT: prep's resolution overran 30 s"; exit 2; }
echo "STEP prep resolution rc=$trc tag='${tag}' at +$(el)"
python3 - "$OUT/marker.json" "$NODE,$PEER" "$DEV" "$tag" <<'PY'
import json, sys
json.dump({"node_list": sys.argv[2], "dev": sys.argv[3], "rig": sys.argv[4]}, open(sys.argv[1], "w"))
PY

# --- 2. the row on the node, reading that marker ----------------------------
nsh "cd $NREPO && MXFS_CONFIG=$CONFIG MXFS_NODES=2 MXFS_MARKER=$NREPO/$OUTREL/marker.json MXFS_RIG_TAG_DRBD=$SW env -u MXFS_RIG_TAG -u MXFS_DEV -u XFS_BASELINE bash tests/suite/fio_perf_vs_xfs.sh; echo row_rc=\$?" > "$OUT/row.txt"
[ "${PIPESTATUS[0]}" = 124 ] && { echo "LAP drbd_rig_tag ABORT: the row on $NODE overran 25 s"; exit 2; }
cat "$OUT/row.txt"
res=$(grep -a '^RESULT: ' "$OUT/row.txt" | tail -1)
echo "STEP row on $NODE at +$(el)"
[ -n "$res" ] || { echo "LAP drbd_rig_tag ABORT label=$LABEL: the row printed no RESULT line"; exit 2; }
status=$(printf '%s' "$res" | awk '{print $2}')
rowrig=$(printf '%s' "$res" | sed -n 's/.*[ (]rig=\([a-z0-9-]*\).*/\1/p')
case "$status:$rowrig:$tag" in
    PASS:*-drbd:*-drbd|FAIL:*-drbd:*-drbd)
        echo "LAP drbd_rig_tag PASS label=$LABEL: prep resolved $DEV to '$tag' and the row scored against rig=$rowrig ($status) in $(el)"; exit 0 ;;
    SKIP:*)
        echo "LAP drbd_rig_tag FAIL label=$LABEL: the row declined to score ($(printf '%s' "$res" | sed -n 's/.*| measured=\([^|]*\) |.*/\1/p' | tr -d ' ')); prep's resolution gave '${tag:-nothing}'"; exit 1 ;;
    *)
        echo "LAP drbd_rig_tag FAIL label=$LABEL: row status=$status rig='${rowrig:-none}', prep's resolution '${tag:-nothing}': not scored against a -drbd rig"; exit 1 ;;
esac
