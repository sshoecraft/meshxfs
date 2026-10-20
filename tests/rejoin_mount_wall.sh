#!/bin/bash
# tests/rejoin_mount_wall.sh — how long does a mount take while its peer stays
# mounted, and does it wait on the peer's cached grant of the root directory?
#
# For D-ON-THE-TCP-TRANSPORT-A-NODE-MOUNTING-WHILE-ITS: on the TCP lock
# network a node mounting while its peer is up waited a full blocking-
# notification period (~10 s) for its EX on the root inode (ino 128), which the
# peer held cached at PR: P34-ACQ-SLOW ino=128 dur_ms=10288.
#
# One lap: the peer has worked in the root (a stat and a listing, so it holds
# the root cached), the rejoiner unmounts, then mounts; its mount wall is
# measured on the node and its kernel log from the lap's mark is searched for
# P34-ACQ-SLOW / P-LKTIMEOUT-HOLDER on ino=128.
#
# Budget (derived): a lone mount measures 4.8-5.7 s; a mount beside a mounted
# peer must stay within twice that, MOUNT_BOUND_S=12, and no slow root acquire.
#
# Usage: tests/rejoin_mount_wall.sh <label> <laps> [group=g2] [config=2/net/mesh/direct]
set -u
LABEL=${1:?label}; LAPS=${2:?laps}; GROUP=${3:-g2}; CONFIG=${4:-2/net/mesh/direct}
MOUNT_BOUND_S=${MOUNT_BOUND_S:-12}
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
set -- $(tools/mxfs_lab.sh group "$GROUP")
[ $# -ge 2 ] || { echo "group $GROUP has fewer than 2 nodes"; exit 2; }
P=$1; eval "R=\${$#}"              # P stays mounted, R rejoins
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_rejoin_mount_$LABEL
mkdir -p "$OUT"
rsx() { local t=$1 n=$2; shift 2; timeout "$t" $SSH "$n" "$*" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
. tests/lib/runlock.sh
vmhold_take rejoin_mount_wall "$@" || { echo "RESULT: ABORT rejoin_mount_wall $LABEL -- could not hold $*"; exit 2; }
MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1
rc=$?; echo "prep_rc=$rc"
[ "$rc" = 0 ] || { echo "RESULT: ABORT rejoin_mount_wall $LABEL -- prep failed ($OUT/prep.log)"; exit 2; }
DEV=$(rsx 15 "$R" "findmnt -no SOURCE /mnt/shared")
[ -n "$DEV" ] || { echo "RESULT: ABORT rejoin_mount_wall $LABEL -- no mount on $R"; exit 2; }
# P34-ACQ-SLOW is a dynamic-debug probe, off by default: turn its one call
# site on in the rejoiner's module (reloaded by the prep) and check it took,
# or a slow root acquire would pass unseen
dd=$(rsx 20 "$R" "echo 'module mxfs format \"P34-ACQ-SLOW\" +p' > /proc/dynamic_debug/control; grep -c '=p .*P34-ACQ-SLOW' /proc/dynamic_debug/control")
[ "${dd:-0}" -ge 1 ] || { echo "RESULT: ABORT rejoin_mount_wall $LABEL -- could not enable P34-ACQ-SLOW on $R (got '${dd:-}')"; exit 2; }
# the witness that a lap exercised the record's path: the PEER receiving a
# blocking notification on the root (P-DIRBAST ino=128, also dynamic debug)
# while the rejoiner mounts.  A lap without one is VACUOUS, not a pass.
dp=$(rsx 20 "$P" "echo 'module mxfs format \"P-DIRBAST\" +p' > /proc/dynamic_debug/control; grep -c '=p .*P-DIRBAST' /proc/dynamic_debug/control")
[ "${dp:-0}" -ge 1 ] || { echo "RESULT: ABORT rejoin_mount_wall $LABEL -- could not enable P-DIRBAST on $P (got '${dp:-}')"; exit 2; }
rsx 30 "$P" "mkdir -p /mnt/shared/rmw && for i in \$(seq 1 20); do echo \$i > /mnt/shared/rmw/f\$i; done; sync; echo ok" > "$OUT/seed.txt"

fails=0; vac=0
for l in $(seq 1 "$LAPS"); do
    m="RMW-$LABEL-$l"
    rsx 30 "$P" "echo $m > /dev/kmsg; stat /mnt/shared >/dev/null; ls /mnt/shared /mnt/shared/rmw >/dev/null; echo ok" > "$OUT/peer_touch_$l.txt"
    rsx 60 "$R" "timeout 40 umount /mnt/shared; echo umount_rc=\$?" > "$OUT/umount_$l.txt"
    rsx 90 "$R" "echo $m > /dev/kmsg; s=\$(date +%s%N); timeout 60 mount -t mxfs $DEV /mnt/shared; rc=\$?; e=\$(date +%s%N); echo mount_rc=\$rc ms=\$(( (e-s)/1000000 )); ls /mnt/shared/rmw | wc -l; dmesg | sed -n '/$m/,\$p' | grep -a 'P34-ACQ-SLOW\|P-LKTIMEOUT-HOLDER' | grep -a 'ino=128 ' | head -5" > "$OUT/mount_$l.txt"
    mrc=$(sed -n 's/.*mount_rc=\([0-9]*\).*/\1/p' "$OUT/mount_$l.txt"); ms=$(sed -n 's/.*ms=\([0-9]*\).*/\1/p' "$OUT/mount_$l.txt")
    slow=$(grep -ac 'P34-ACQ-SLOW\|P-LKTIMEOUT-HOLDER' "$OUT/mount_$l.txt")
    rb=$(rsx 20 "$P" "dmesg | sed -n '/$m/,\$p' | grep -ac 'P-DIRBAST ino=128 '")
    v=PASS
    if ! { [ "${mrc:-1}" = 0 ] && [ -n "$ms" ] && [ "$ms" -le $(( MOUNT_BOUND_S * 1000 )) ] && [ "$slow" = 0 ]; }; then
        v=FAIL; fails=$(( fails + 1 ))
    elif [ "${rb:-0}" = 0 ]; then
        v=VACUOUS; vac=$(( vac + 1 ))
    fi
    echo "lap $l $v: $R umount $(grep -o 'umount_rc=[0-9]*' "$OUT/umount_$l.txt") mount_rc=${mrc:-?} ms=${ms:-?} slow_root_lines=$slow $(grep -a 'P34-ACQ-SLOW' "$OUT/mount_$l.txt" | head -1 | grep -o 'dur_ms=[0-9]*') peer_root_basts=${rb:-?}"
done
echo "RESULT: rejoin_mount_wall label=$LABEL laps=$LAPS fails=$fails vacuous=$vac evidence=$OUT"
[ "$fails" = 0 ]
