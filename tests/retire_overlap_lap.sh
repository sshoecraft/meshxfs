#!/bin/bash
# retire_overlap_lap.sh -- one lap of
# D-LAST-MEMBER-UNMOUNT-LEAVES-A-DEPARTED-SLOTS-PR-KEY-UNCLASSIFIED-30S, on a rig
# pair on the TCP lock manager, where it was seen.
#
# In lap lmuc2 of a control of the last-member-unmount record, B left cleanly
# while A was already unmounting: A's heartbeat thread saw B's slot
# RETIRE_PENDING after A's PR worker had exited, could not classify B's PR key,
# logged P304-RETIRE-UNKNOWN-STALLED 30.8 s later, and A's unmount left both
# slots RETIRE_PENDING for the next mount to settle.  Open: whether anything
# waits on that -- A's unmount, or the next mount's admission.
#
# The lap, at CONFIG on GROUP, from this tree's run.sh:
#   1. prep_cluster; A creates NFILES files, so its unmount has grants to give
#      back and its teardown outlasts B's departure;
#   2. A unmounts, and B unmounts DELAY_MS later, so B's goodbye can land in
#      A's teardown after A's PR worker exited, both timed;
#   3. A mounts again, then B, each timed, each node's kernel log marked first;
#   4. A's log of step 2: B's slot seen RETIRE_PENDING with state=UNKNOWN after
#      A's PR worker exited (EXPOSED); A's and B's logs of step 3: the slots
#      settled (P304-RETIRE-COMPLETED-*), any P304-RETIRE-UNKNOWN-STALLED.
#
#   PASS     exposed, and each mount of step 3 returned inside MOUNT_BOUND_S with
#            no P304-RETIRE-UNKNOWN-STALLED in its log
#   FAIL     a mount of step 3 overran MOUNT_BOUND_S or logged the stall
#   ABORT    not exposed (the overlap did not happen), a step failed, or the
#            lap overran its bound
#
# There is no control: the lap decides whether the record is a defect at all.
#
# Bounds, derived: a mount on this rig takes 5-6 s (the fixed five-second floor,
# D-MOUNT-HAS-A-FIXED-FIVE-SECOND-FLOOR-ON-ANY-LUN, plus the join), so a mount
# that waited out the 30 s retire grace is the failure: MOUNT_BOUND_S=12, twice
# the mount.  The lap: prep 88 s, the creates (NFILES at ~150 a second on this
# rig, tests/lockrec_slot0_lap.sh's precheck) 2x, the two unmounts 2x the 38 s
# lmuc2 measured, the two mounts 2x12 s, the reads 20 s.
#
# Usage: tests/retire_overlap_lap.sh <label> [config=2/net/mesh/direct] [group=g2]
#        NFILES (8000) DELAY_MS (500)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
LABEL=${1:?label}; CONFIG=${2:-2/net/mesh/direct}; GROUP=${3:-g2}
NFILES=${NFILES:-8000}; DELAY_MS=${DELAY_MS:-500}; MOUNT_BOUND_S=12
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
. "$HERE/tools/mxfs_lab.sh"
SSH="$HERE/tools/mxfs_sshpass.sh"
MNT=/mnt/shared
OUT=$HERE/tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_retireoverlap_$LABEL
mkdir -p "$OUT"
exec > >(tee -a "$OUT/lap.log") 2>&1
cd "$HERE" || exit 2
T0=$(date +%s); BOUND=$(( 88 + 2 * NFILES / 150 + 2 * 38 + 2 * 12 + 20 ))
abort() { echo "LAP retire_overlap ABORT label=$LABEL: $*"; exit 2; }
left() { echo $(( BOUND - ($(date +%s) - T0) )); }
on() {  # on <node> <bound> <command>
    timeout "$2" "$SSH" "$(lab_addr "$1")" "$3" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'
}

echo "LAP retire_overlap start $(date -u +%FT%TZ) config=$CONFIG group=$GROUP nfiles=$NFILES delay_ms=$DELAY_MS bound=${BOUND}s out=$OUT"
case "$CONFIG" in */net/mesh/*) ;; *) abort "$CONFIG is not on the TCP lock manager";; esac
read -r A B _ <<<"$(lab_group "$GROUP" 2>/dev/null)"
[ -n "$B" ] || abort "group $GROUP has fewer than two nodes in the lab file"

MXFS_FORCE_PREP=1 timeout -k 5 88 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster </dev/null > "$OUT/prep.log" 2>&1
rc=$?
[ "$rc" = 124 ] && abort "prep_cluster overran its 88 s bound"
[ "$rc" = 0 ] && grep -aq '^=== prep_cluster OK ' "$OUT/prep.log" || abort "prep_cluster did not pass (rc=$rc, $OUT/prep.log)"
DEV=$(on "$A" 10 "findmnt -no SOURCE $MNT" | tail -1)
[ -n "$DEV" ] || abort "$A has nothing mounted at $MNT"
on "$A" $(( 2 * NFILES / 150 + 10 )) "mkdir -p $MNT/ro_$LABEL && cd $MNT/ro_$LABEL && seq -f 'f%g' 1 $NFILES | xargs touch && echo CREATED \$(ls | wc -l)" > "$OUT/create.txt"
grep -aq "^CREATED $NFILES\$" "$OUT/create.txt" || abort "A did not create $NFILES files: $(tail -1 "$OUT/create.txt")"

m1="RETIRE-OVERLAP-1 $LABEL $(date +%s%N)"
for n in "$A" "$B"; do on "$n" 10 "echo '$m1' > /dev/kmsg" > /dev/null; done
on "$A" 90 "s=\$(date +%s%N); timeout 80 umount $MNT; rc=\$?; e=\$(date +%s%N); echo A_UMOUNT rc=\$rc ms=\$(( (e-s)/1000000 ))" > "$OUT/umount_a.txt" &
pa=$!
sleep "$(awk -v d="$DELAY_MS" 'BEGIN{printf "%.3f", d/1000}')"
on "$B" 90 "s=\$(date +%s%N); timeout 80 umount $MNT; rc=\$?; e=\$(date +%s%N); echo B_UMOUNT rc=\$rc ms=\$(( (e-s)/1000000 ))" > "$OUT/umount_b.txt"
wait "$pa"
echo "STEP $(cat "$OUT/umount_b.txt") $(cat "$OUT/umount_a.txt")"
grep -aq 'B_UMOUNT rc=0' "$OUT/umount_b.txt" && grep -aq 'A_UMOUNT rc=0' "$OUT/umount_a.txt" || abort "an unmount failed"

m2="RETIRE-OVERLAP-2 $LABEL $(date +%s%N)"
for n in "$A" "$B"; do on "$n" 10 "echo '$m2' > /dev/kmsg" > /dev/null; done
for n in "$A" "$B"; do
    on "$n" $(( MOUNT_BOUND_S + 30 )) "s=\$(date +%s%N); timeout $(( MOUNT_BOUND_S + 20 )) mount -t mxfs ${MXFS_MOUNT_OPTS:-} $DEV $MNT; rc=\$?; e=\$(date +%s%N); echo MOUNT_$n rc=\$rc ms=\$(( (e-s)/1000000 ))" > "$OUT/mount_$n.txt"
    echo "STEP $(cat "$OUT/mount_$n.txt")"
done

for n in "$A" "$B"; do on "$n" 20 "dmesg | sed -n '/$m1/,\$p'" > "$OUT/kmsg_$n.txt"; done
grep -aq "$m1" "$OUT/kmsg_$A.txt" || abort "$A's kernel log holds no lap mark"
sed -n "/$m1/,/$m2/p" "$OUT/kmsg_$A.txt" > "$OUT/a_teardown.txt"
pr_exit=$(grep -an 'P304-PR-WORKER exiting\|scsipr: abandoned' "$OUT/a_teardown.txt" | head -1 | cut -d: -f1)
seen=$(grep -an 'P304-RETIRE-PENDING-SEEN .*state=UNKNOWN' "$OUT/a_teardown.txt" | head -1 | cut -d: -f1)
grep -a 'P304-\|scsipr: abandoned\|P-DEPART-WORK node\|P-RELALL-LEFT node' "$OUT/a_teardown.txt" | cut -c1-200
# the record's condition: B's slot seen with its key UNKNOWN only after A's
# PR context was gone, and not settled during A's teardown
seen=$(awk -v x="${pr_exit:-999999999}" 'NR > x && /P304-RETIRE-PENDING-SEEN .*state=UNKNOWN/ {print NR; exit}' "$OUT/a_teardown.txt")
slot=$( [ -n "$seen" ] && sed -n "${seen}p" "$OUT/a_teardown.txt" | sed -n 's/.*P304-RETIRE-PENDING-SEEN slot=\([0-9]*\) .*/\1/p')
if [ -z "$seen" ] || [ -z "$pr_exit" ] || grep -aq "P304-RETIRE-COMPLETED[A-Z-]* slot=$slot " "$OUT/a_teardown.txt"; then
    abort "not exposed: A's teardown shows no departed slot seen UNKNOWN after its PR worker exited and left unsettled (PR exit line ${pr_exit:-none}, seen line ${seen:-none})"
fi
echo "EXPOSED: during A's unmount B's slot was seen RETIRE_PENDING with its PR key UNKNOWN ($(sed -n "${seen}p" "$OUT/a_teardown.txt" | cut -c1-160))"
[ "$(left)" -lt 0 ] && abort "the lap overran its ${BOUND} s bound"

bad=()
for n in "$A" "$B"; do
    ms=$(sed -n "s/^MOUNT_$n rc=0 ms=\([0-9]*\)$/\1/p" "$OUT/mount_$n.txt")
    [ -n "$ms" ] || { bad+=("$n's mount failed: $(cat "$OUT/mount_$n.txt")"); continue; }
    [ "$ms" -le $(( MOUNT_BOUND_S * 1000 )) ] || bad+=("$n's mount took $ms ms, over ${MOUNT_BOUND_S} s")
    sed -n "/$m2/,\$p" "$OUT/kmsg_$n.txt" > "$OUT/mount_kmsg_$n.txt"
    grep -a 'P304-RETIRE-COMPLETED\|P304-RETIRE-UNKNOWN-STALLED\|P304-RETIRE-PENDING-SEEN' "$OUT/mount_kmsg_$n.txt" | cut -c1-200
    grep -aq 'P304-RETIRE-UNKNOWN-STALLED' "$OUT/mount_kmsg_$n.txt" && bad+=("$n logged P304-RETIRE-UNKNOWN-STALLED after its mount")
done
on "$A" 30 "rm -rf $MNT/ro_$LABEL" > /dev/null
if [ "${#bad[@]}" -gt 0 ]; then
    echo "LAP retire_overlap FAIL label=$LABEL: $(IFS=';'; echo "${bad[*]}")"
    exit 1
fi
echo "LAP retire_overlap PASS label=$LABEL: both mounts after the overlapped departure returned inside ${MOUNT_BOUND_S} s with no unclassified-key stall ($(cat "$OUT/mount_$A.txt" "$OUT/mount_$B.txt" | tr '\n' ' '))"
exit 0
