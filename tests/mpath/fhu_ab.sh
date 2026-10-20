#!/bin/bash
# tests/mpath/fhu_ab.sh — same-build A/B of the fenced-path reset: one
# tests/mpath/fenced_held_unmount.sh lap per arm, the group re-prepped before
# each (the lap fences its victim), arms in the order given so they alternate.
#
# Usage: tests/mpath/fhu_ab.sh <label> <arms> [config=2/disk/caw/mpath] [group=g2b] [X=test16] [Y=test15]
#   <arms>: comma-separated off|default, e.g. off,default,off,default
# Prints one line per lap and a RESULT line; each lap's evidence is the
# directory its RESULT line names.
set -u
LABEL=${1:?label}; ARMS=${2:?arms}; CONFIG=${3:-2/disk/caw/mpath}; GROUP=${4:-g2b}
X=${5:-test16}; Y=${6:-test15}
cd "$(dirname "$0")/../.." || exit 2
OUT=tests/evidence/fhu_ab_$LABEL
mkdir -p "$OUT"
l=0
for arm in ${ARMS//,/ }; do
    l=$(( l + 1 ))
    s=$SECONDS
    MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep_lap$l.txt" 2>&1
    prc=$?
    if [ "$prc" != 0 ]; then
        echo "lap $l arm=$arm: ABORT -- prep rc=$prc ($OUT/prep_lap$l.txt)"
        continue
    fi
    r=$(FHU_HELPER=$arm tests/mpath/fenced_held_unmount.sh "${LABEL}l$l$arm" "$X" "$Y" 2>&1 | tee "$OUT/lap$l.txt" | grep -a '^RESULT' | tail -1)
    echo "lap $l arm=$arm wall_s=$(( SECONDS - s )) ${r#RESULT: }"
done
echo "RESULT: fhu_ab label=$LABEL arms=$ARMS config=$CONFIG group=$GROUP evidence=$OUT (re-prep $GROUP before using it again)"
