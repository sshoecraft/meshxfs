#!/bin/bash
# tests/agbast_mount_park.sh — do simultaneous mounts hear each other's AG
# blocking notifications while they are still inside xfs_mountfs?
#
# For D-AG-BAST-DROPPED-DURING-MOUNTFS-NO-CALLBACK-HOLDER-KEEPS-AG-FOR-THE-MOUNT.
# A mount's untrusted root lookup takes AG 0 inside xfs_mountfs and keeps it
# cached; the AG handler is installed only after xfs_mountfs returns, so a
# peer's notification arriving in between was dropped, and every other mount
# needing AG 0 waited out the holder's whole mount phase plus the master's
# ~10 s re-send.  0.90.20 parks such a notification and replays it when the
# handler is installed (v5_bast_dispatch / v5_bast_replay).
#
# One lap: every node unmounts (in parallel), then every node mounts at the
# same instant; each mount's wall is measured on the node.  At the next
# unmount each node prints what its mount phase parked
# (P-BAST-PARK-STATS arrivals= replayed= overflow= left=), so a lap's stats are
# read from the unmount that follows it.
#
# Verdict per lap: every mount returns 0 within MOUNT_BOUND_S; overflow=0 and
# left=0 on every node.  replayed_ag>0 on some node (an AG notification parked
# during that node's mount phase and handed over at installation) is what
# shows a lap exercised this record's path (a lap with none says nothing about
# it and is counted VACUOUS, not passed).
#
# Budget (derived): a lone join measures 4.8-5.7 s (postboot laps, D-POSTBOOT);
# four joins at once should each finish within twice that: MOUNT_BOUND_S=12.
# Unmount 40 s bound.  Prep 300 s.
#
# Usage: tests/agbast_mount_park.sh <label> <laps> [group=g4b] [config=4/net/mesh/direct]
set -u
LABEL=${1:?label}; LAPS=${2:?laps}; GROUP=${3:-g4b}; CONFIG=${4:-4/net/mesh/direct}
MOUNT_BOUND_S=${MOUNT_BOUND_S:-12}
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
NODES=$(tools/mxfs_lab.sh group "$GROUP") || exit 2
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_agbast_park_$LABEL
mkdir -p "$OUT"
rsx() { local t=$1 n=$2; shift 2; timeout "$t" $SSH "$n" "$*" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
. tests/lib/runlock.sh
vmhold_take agbast_mount_park $NODES || { echo "RESULT: ABORT agbast_mount_park $LABEL -- could not hold $NODES"; exit 2; }

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1
rc=$?; echo "prep_rc=$rc"
[ "$rc" = 0 ] || { echo "RESULT: ABORT agbast_mount_park $LABEL -- prep failed ($OUT/prep.log)"; exit 2; }
set -- $NODES
DEV=$(rsx 15 "$1" "findmnt -no SOURCE /mnt/shared")
[ -n "$DEV" ] || { echo "RESULT: ABORT agbast_mount_park $LABEL -- no mount on $1"; exit 2; }
# P34-ACQ-SLOW (an inode lock acquire of a second or more, dynamic debug, off
# by default) on every node: a mount whose root acquire waited out the
# master's re-send period (~10 s, D-ON-THE-TCP-TRANSPORT-A-NODE-MOUNTING-WHILE-ITS)
# instead of the first notification fails the lap at ROOT_WAIT_BOUND_MS
ROOT_WAIT_BOUND_MS=${ROOT_WAIT_BOUND_MS:-5000}
for n in $NODES; do
    d=$(rsx 20 "$n" "echo 'module mxfs format \"P34-ACQ-SLOW\" +p' > /proc/dynamic_debug/control; grep -c '=p .*P34-ACQ-SLOW' /proc/dynamic_debug/control")
    [ "${d:-0}" -ge 1 ] || { echo "RESULT: ABORT agbast_mount_park $LABEL -- could not enable P34-ACQ-SLOW on $n"; exit 2; }
done

# umount_all <tag>: every node unmounts at once; then each node's newest
# P-BAST-PARK-STATS line (printed by that unmount) into stats_<tag>.txt
umount_all() {
    local n
    for n in $NODES; do
        rsx 60 "$n" "echo AGBP-$LABEL-$1 > /dev/kmsg; s=\$(date +%s%N); timeout 40 umount /mnt/shared; rc=\$?; e=\$(date +%s%N); echo umount_rc=\$rc ms=\$(( (e-s)/1000000 )); dmesg | sed -n '/AGBP-$LABEL-$1/,\$p' | grep -a 'P-BAST-PARK-STATS' | tail -1" > "$OUT/umount_${1}_$n.txt" &
    done
    wait
    for n in $NODES; do echo "$n $(tr '\n' ' ' < "$OUT/umount_${1}_$n.txt")"; done > "$OUT/stats_$1.txt"
}

fails=0; vac=0
umount_all l0
for l in $(seq 1 "$LAPS"); do
    # every node starts its mount at the same wall-clock instant
    at=$(( $(date +%s) + 3 ))
    for n in $NODES; do
        rsx 90 "$n" "echo AGBM-$LABEL-$l > /dev/kmsg; while [ \$(date +%s) -lt $at ]; do sleep 0.05; done; s=\$(date +%s%N); timeout 60 mount -t mxfs $DEV /mnt/shared; rc=\$?; e=\$(date +%s%N); echo mount_rc=\$rc ms=\$(( (e-s)/1000000 )); echo rootwait_ms=\$(dmesg | sed -n '/AGBM-$LABEL-$l/,\$p' | grep -a 'P34-ACQ-SLOW ino=128 ' | sed -n 's/.*dur_ms=\([0-9]*\).*/\1/p' | sort -n | tail -1)" > "$OUT/mount_l${l}_$n.txt" &
    done
    wait
    umount_all "l$l"
    bad=0; arr=0; line=""
    for n in $NODES; do
        m=$(cat "$OUT/mount_l${l}_$n.txt")
        st=$(grep -a "^$n " "$OUT/stats_l$l.txt")
        mrc=$(sed -n 's/.*mount_rc=\([0-9]*\).*/\1/p' <<<"$m"); mms=$(sed -n 's/.*ms=\([0-9]*\).*/\1/p' <<<"$m")
        a=$(sed -n 's/.*replayed_ag=\([0-9]*\).*/\1/p' <<<"$st"); o=$(sed -n 's/.*overflow=\([0-9]*\).*/\1/p' <<<"$st"); lf=$(sed -n 's/.*left=\([0-9]*\).*/\1/p' <<<"$st")
        rw=$(sed -n 's/.*rootwait_ms=\([0-9]*\).*/\1/p' <<<"$m")
        rp=$(sed -n 's/.* replayed=\([0-9]*\).*/\1/p' <<<"$st")
        line+="$n rc=${mrc:-?} ms=${mms:-?} root_wait_ms=${rw:-<1000} ag_replayed=${a:-?} other_replayed=$(( ${rp:-0} - ${a:-0} )) $(grep -o 'arrivals=[0-9]*' <<<"$st") overflow=${o:-?} left=${lf:-?}; "
        { [ "${mrc:-1}" = 0 ] && [ -n "$mms" ] && [ "$mms" -le $(( MOUNT_BOUND_S * 1000 )) ] && [ "${o:-x}" = 0 ] && [ "${lf:-x}" = 0 ] &&
          [ "${rw:-0}" -le "$ROOT_WAIT_BOUND_MS" ]; } || bad=1
        arr=$(( arr + ${a:-0} ))
    done
    if [ "$bad" = 1 ]; then v=FAIL; fails=$(( fails + 1 )); elif [ "$arr" = 0 ]; then v=VACUOUS; vac=$(( vac + 1 )); else v=PASS; fi
    echo "lap $l $v: $line"
done
# leave the group mounted for whoever is next
for n in $NODES; do rsx 90 "$n" "timeout 60 mount -t mxfs $DEV /mnt/shared; echo rc=\$?" > "$OUT/remount_$n.txt" & done; wait
echo "RESULT: agbast_mount_park label=$LABEL laps=$LAPS fails=$fails vacuous=$vac evidence=$OUT"
[ "$fails" = 0 ]
