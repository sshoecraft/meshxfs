#!/bin/bash
# marker_size_lap.sh -- one lap of
# D-RUN-SH-MARKER-PARAMS-PASSED-AS-ONE-ARGUMENT-EMPTY-THE-MARKER-AT-8-NODES, on
# a rig group of eight or more nodes, where the defect lives.
#
# run.sh's marker_write records every node's module parameters in the cluster
# marker's `params`, about 18 KB a node.  It handed that object to jq as one
# --argjson argument, and at 8 nodes (~145 KB) the argument is past the
# kernel's limit on one argument, MAX_ARG_STRLEN = 32 pages
# (/src/linux/include/uapi/linux/binfmts.h:15), 131072 bytes on this rig: exec
# of jq failed with E2BIG after the shell's redirect had emptied the marker,
# the prep still printed 'marker updated', and every filtered row after it
# refused 'cluster is prepped for <none>'.  The fix hands it to jq on stdin.
#
# The lap, from this tree's run.sh:
#   1. MXFS_FORCE_PREP=1 ./run.sh CONFIG --group GROUP prep_cluster;
#   2. the prep's own line '--- marker params: <b> bytes for <n> node(s) ---'
#      and the marker it wrote (MXFS_MARKER, else .cluster_marker.GROUP.json).
#
#   EXPOSED  b is over 131072: an argument that size cannot be exec'd
#   PASS     the marker parses, names CONFIG, and its params hold every node
#            of the group
#   FAIL     the marker is empty or does not parse, names another
#            configuration, or its params miss a node
#   ABORT    the prep failed or overran, or printed no size line
#
# The control is MXFS_MARKER_STDIN=0 in this lap's environment, which run.sh
# inherits: marker_write passes params as --argjson, as before the fix.
#
# Bound, derived: an 8-node prep_cluster measured 91 s at 8/disk/caw/mpath and
# 71 s at 8/net/mesh/mpath (lane g8_mpathtmo2_scst6_20261024T005026Z, steps 2
# and 13), so the prep is bounded at 182 s; the marker read is local.  A batch
# bounds the lap at twice what its precheck measures.
#
# Usage: tests/marker_size_lap.sh <label> [config=8/disk/caw/mpath] [group=g8]
#        MXFS_MARKER_STDIN=0 tests/marker_size_lap.sh <label> ...   (control)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
LABEL=${1:?label}; CONFIG=${2:-8/disk/caw/mpath}; GROUP=${3:-g8}
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
. "$HERE/tools/mxfs_lab.sh"
cd "$HERE" || exit 2
LIMIT=131072
MARKER=${MXFS_MARKER:-$HERE/.cluster_marker.$GROUP.json}
OUT=$HERE/tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_markersize_$LABEL
mkdir -p "$OUT"
exec > >(tee -a "$OUT/lap.log") 2>&1
abort() { echo "LAP marker_size ABORT label=$LABEL: $*"; exit 2; }
t0=$(date +%s)

read -r -a NODES <<<"$(lab_group "$GROUP" 2>/dev/null)"
[ "${#NODES[@]}" -ge 2 ] || abort "group $GROUP names no nodes in the lab file"
echo "LAP marker_size start $(date -u +%FT%TZ) config=$CONFIG group=$GROUP nodes=${#NODES[@]} marker=$MARKER MXFS_MARKER_STDIN=${MXFS_MARKER_STDIN:-unset} out=$OUT"

MXFS_FORCE_PREP=1 timeout -k 5 182 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster </dev/null > "$OUT/prep.log" 2>&1
rc=$?
echo "STEP prep rc=$rc wall=$(( $(date +%s) - t0 )) s"
[ "$rc" = 124 ] && abort "prep_cluster overran its 182 s bound"
[ "$rc" = 0 ] && grep -aq '^=== prep_cluster OK ' "$OUT/prep.log" || abort "prep_cluster did not pass (rc=$rc, $OUT/prep.log)"
size=$(sed -n 's/^--- marker params: \([0-9]*\) bytes for \([0-9]*\) node(s) ---$/\1/p' "$OUT/prep.log" | tail -1)
[ -n "$size" ] || abort "the prep printed no 'marker params' size line"
[ "$size" -gt "$LIMIT" ] || abort "not exposed: params were $size bytes, not over $LIMIT"
echo "EXPOSED: the prep's marker params were $size bytes for ${#NODES[@]} nodes, over the $LIMIT-byte limit on one argument"

cp "$MARKER" "$OUT/marker.json" 2>/dev/null
mbytes=$(stat -c %s "$MARKER" 2>/dev/null || echo 0)
mcfg=$(jq -r '.configuration // empty' "$MARKER" 2>/dev/null)
missing=""
for n in "${NODES[@]}"; do
    jq -e --arg n "$n" '.params[$n] | type == "string"' "$MARKER" >/dev/null 2>&1 || missing="$missing $n"
done
echo "STEP marker bytes=$mbytes configuration='${mcfg:-}' missing_params=[${missing# }]"
if [ "$mcfg" = "$CONFIG" ] && [ -z "$missing" ]; then
    echo "LAP marker_size PASS label=$LABEL: the marker ($mbytes bytes) names $CONFIG and holds the params of all ${#NODES[@]} nodes"
    exit 0
fi
echo "LAP marker_size FAIL label=$LABEL: the marker is $mbytes bytes, configuration '${mcfg:-none}', params missing for [${missing# }]"
exit 1
