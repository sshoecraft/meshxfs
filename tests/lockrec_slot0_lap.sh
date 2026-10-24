#!/bin/bash
# lockrec_slot0_lap.sh -- one lap of
# D-DISKLOCK-VALIDATE-READS-CAW-SLOT-0-AND-LOGS-A-CORRUPT-LOCK-RECORD, on a rig
# pair on a COMPARE AND WRITE volume, where the defect lives.
#
# dlm/disklock.c validate_lockstate, at every disklock init (every mount), read
# the first lock-record slot at base + MXFS_DISKLOCK_HB_SIZE, which on a COMPARE
# AND WRITE volume is CAW slot 0, and when the 32-bit word at the record's flags
# offset read MXFS_DISKLOCK_FLAG_ACTIVE (1) with a magic other than the
# disklock's, logged 'disklock: corrupt lock record at slot 0'.  At that offset
# a CAW slot carries its generation, so a live slot 0 claimed once (MXCW, gen=1)
# read as a corrupt lock record.  The fix checks the heartbeat half only;
# nothing writes a lock record any more.
#
# The lap, from this tree's run.sh at CONFIG on GROUP (a disk/caw configuration):
#   1. ./run.sh prep_cluster (a fresh format: every CAW slot zero);
#   2. on the first node, bursts of BURST creates in a directory of the lap's
#      own, reading CAW slot 0 after each (tools/caw_slotdump --slot 0, the
#      kernel's own READ(16)+FUA), until it is live with gen=1 (EXPOSED) or
#      MAXBURST bursts pass (ABORT: never exposed);
#   3. the second node unmounts and mounts again, its kernel log marked first;
#   4. its kernel log from the mark.
#
#   PASS     the second node's disklock init logged no 'corrupt lock record'
#   FAIL     it logged 'corrupt lock record at slot 0' with slot 0 live, gen=1
#   ABORT    the prep failed, slot 0 never went live with gen=1, the remount
#            failed, or the lap overran its bound
#
# The control is LOCKREC_VALIDATE=1 in this lap's environment: the second node's
# dl_validate_lockrec is set to 1 for its remount (and set back after), which
# checks the lock-record half as before, on the same build.
#
# Bound, derived: prep_cluster bound 88 s (tests/live_holder_shard_lap.sh); the
# bursts are bounded by MAXBURST x (BURST creates + one slot read), measured
# by this lap's precheck and set below; the remount 45 s (tests/mpath/lib.sh's
# bound on one mount) plus 40 s for its unmount; 15 s for the log read.
#
# Usage: tests/lockrec_slot0_lap.sh <label> [config=2/disk/caw/direct] [group=g2]
#        LOCKREC_VALIDATE=1 tests/lockrec_slot0_lap.sh <label> ...   (control)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
LABEL=${1:?label}; CONFIG=${2:-2/disk/caw/direct}; GROUP=${3:-g2}
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
. "$HERE/tools/mxfs_lab.sh"
SSH="$HERE/tools/mxfs_sshpass.sh"
NREPO=/src/$(basename "$HERE")
MNT=/mnt/shared
BURST=${LOCKREC_BURST:-2000}; MAXBURST=${LOCKREC_MAXBURST:-20}
OUT=$HERE/tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_lockrec_$LABEL
mkdir -p "$OUT"
exec > >(tee -a "$OUT/lap.log") 2>&1
cd "$HERE" || exit 2
abort() { echo "LAP lockrec_slot0 ABORT label=$LABEL: $*"; exit 2; }
on() {  # on <node> <bound> <command>
    timeout "$2" "$SSH" "$(lab_addr "$1")" "$3" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you'
}

echo "LAP lockrec_slot0 start $(date -u +%FT%TZ) config=$CONFIG group=$GROUP tree=$NREPO LOCKREC_VALIDATE=${LOCKREC_VALIDATE:-unset} burst=$BURST maxburst=$MAXBURST out=$OUT"
case "$CONFIG" in */disk/caw/*) ;; *) abort "$CONFIG is not a COMPARE AND WRITE configuration";; esac
read -r A B _ <<<"$(lab_group "$GROUP" 2>/dev/null)"
[ -n "$B" ] || abort "group $GROUP has fewer than two nodes in the lab file"

MXFS_FORCE_PREP=1 timeout -k 5 88 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster </dev/null > "$OUT/prep.log" 2>&1
rc=$?
[ "$rc" = 124 ] && abort "prep_cluster overran its 88 s bound"
[ "$rc" = 0 ] && grep -aq '^=== prep_cluster OK ' "$OUT/prep.log" || abort "prep_cluster did not pass (rc=$rc, $OUT/prep.log)"
DEV=$(on "$A" 10 "findmnt -no SOURCE $MNT" | tail -1)
[ -n "$DEV" ] || abort "$A has nothing mounted at $MNT"

slot0=""; n=0; t0=$(date +%s)
while [ "$n" -lt "$MAXBURST" ]; do
    n=$((n + 1))
    on "$A" 60 "mkdir -p $MNT/lockrec_$LABEL && cd $MNT/lockrec_$LABEL && seq -f 'b${n}_%g' 1 $BURST | xargs touch" > /dev/null
    slot0=$(on "$A" 10 "$NREPO/tools/caw_slotdump $DEV --slot 0" | grep -a '^slot=0 ' | tail -1)
    echo "STEP burst $n ($((n * BURST)) creates, $(( $(date +%s) - t0 )) s): ${slot0:-slot 0 unread}"
    case "$slot0" in *"magic=0x4d584357 "*" gen=1") break ;; esac
    slot0=""
done
[ -n "$slot0" ] || abort "CAW slot 0 never went live with gen=1 in $MAXBURST bursts of $BURST creates"
echo "EXPOSED: CAW slot 0 is live with gen=1 ($slot0) before $B's remount"

[ "${LOCKREC_VALIDATE:-}" = 1 ] && on "$B" 10 "echo 1 > /sys/module/mxfs/parameters/dl_validate_lockrec"
mark="LOCKREC-LAP $LABEL $(date +%s%N)"
on "$B" 100 "echo '$mark' > /dev/kmsg; timeout 40 umount $MNT; u=\$?; timeout 45 mount -t mxfs ${MXFS_MOUNT_OPTS:-} $DEV $MNT; m=\$?; echo REMOUNT umount_rc=\$u mount_rc=\$m; grep -q ' $MNT mxfs ' /proc/mounts && echo MOUNTED" > "$OUT/remount.txt"
[ "${LOCKREC_VALIDATE:-}" = 1 ] && on "$B" 10 "echo 0 > /sys/module/mxfs/parameters/dl_validate_lockrec"
cat "$OUT/remount.txt"
grep -aq '^MOUNTED' "$OUT/remount.txt" || abort "$B is not mounted after its remount: $(grep -a REMOUNT "$OUT/remount.txt")"
on "$B" 15 "dmesg | sed -n '/$mark/,\$p'" > "$OUT/kmsg_$B.txt"
grep -aq "$mark" "$OUT/kmsg_$B.txt" || abort "$B's kernel log holds no lap mark"
grep -a 'disklock: corrupt\|lockstate validation' "$OUT/kmsg_$B.txt"
on "$A" 30 "rm -rf $MNT/lockrec_$LABEL" > /dev/null
if grep -aq 'disklock: corrupt lock record at slot 0' "$OUT/kmsg_$B.txt"; then
    echo "LAP lockrec_slot0 FAIL label=$LABEL: $B's mount logged '$(grep -a 'disklock: corrupt lock record' "$OUT/kmsg_$B.txt" | head -1 | sed 's/^\[[^]]*\] //')' over a live slot 0 ($slot0)"
    exit 1
fi
echo "LAP lockrec_slot0 PASS label=$LABEL: $B's disklock init logged no corrupt lock record over a live slot 0 ($slot0)"
exit 0
