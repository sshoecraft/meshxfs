#!/bin/bash
# create_pace_lap.sh -- one measured lap of D-SINGLE-WRITER-CREATE-PACE-6-TO-18MS-ON-2CAW-SO-THE-LMU-LAP-OVERRAN-360S.
#
# A single writer creating empty files in one fresh directory on 2/disk/caw/direct took 5.9-18 ms
# a create (lane g2_lmu_caw_measure_20261023T234743Z), but every run that showed it was a lap
# killed at its bound inside the create stage, so none of them completed what it was checking and
# none measured each create's own time.  This lap measures the pace to its end: it forms the pair,
# creates NFILES empty files in a fresh directory on A with each create timed on its own (bash's
# $EPOCHREALTIME around the one redirection, no fork per create), prints every 1000th create's
# running pace so a dependence on directory size shows, then lists the directory on B and requires
# every name, and reads both nodes' kernel logs after the lap's mark for a fault signature.  With
# NATIVE_DEV set (a scratch device on A, e.g. a pool LUN bound to A alone), it runs the identical
# loop on native XFS made on that device (mkfs.xfs -f, mounted at /mnt/createpace_xfs), the
# yardstick the 2x ceiling is read against.
#
#   PASS     every create returned 0, B listed all NFILES names, no fault signature on either node;
#            the lap prints the pace (mean and worst create) and max_stall_ms= the worst create
#   FAIL     a create failed, B's listing is short, a fault signature was logged, or the stage did
#            not finish inside its bound
#   ABORT    the pair could not be formed
#
# Bound, derived from the measured pace: 18.2 ms a create at its worst (test1_sample2.txt of
# 20261024T000246Z_caw_create_pace_probe), so NFILES=10000 creates take at most about 182 s;
# twice that is 364 s for the stage.  prep_cluster 37-58 s, B's listing and the kernel-log reads
# under 20 s: a caller bounds the lap at 2 x (58 + 364/2 + 20) = 520 s.  The native arm adds mkfs
# and mount (about 5 s) and the loop at local pace (0.063 ms a create on test2's root: under 2 s).
#
# Usage: [NFILES=10000] [NATIVE_DEV=/dev/sdX] tests/create_pace_lap.sh <label> <configuration>
#        (the group's env exported: MXFS_GROUP, MXFS_MARKER, MXFS_NODE_LIST)
# Leaves the pair mounted.  Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
CONFIG=${2:?configuration}
cd "$(dirname "$0")/.." || exit 2
NODES=${MXFS_NODE_LIST:?MXFS_NODE_LIST}
A=${NODES%%,*}; B=${NODES##*,}
SSH=tools/mxfs_sshpass.sh
MNT=${MXFS_MNT:-/mnt/shared}
NFILES=${NFILES:-10000}
STAGE_S=$(( NFILES * 182 / 10000 * 2 )); [ "$STAGE_S" -ge 60 ] || STAGE_S=60
. tests/lib/rig.sh
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_createpace_$LABEL
mkdir -p "$OUT"
echo "LAP create_pace start $(date -u +%FT%TZ) label=$LABEL at=$CONFIG A=$A B=$B nfiles=$NFILES stage_bound_s=$STAGE_S native=${NATIVE_DEV:-none} out=$OUT"
prep=$(MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" ${MXFS_GROUP:+--group "$MXFS_GROUP"} prep_cluster < /dev/null 2>&1)
rc=$?
[ "$rc" = 0 ] || { echo "LAP create_pace ABORT: prep_cluster rc=$rc: $(echo "$prep" | tail -2 | tr '\n' ' ' | cut -c1-240)"; exit 2; }
MARK="CREATEPACE-$LABEL-$$"
for n in "$A" "$B"; do
    v=$(rs 20 "$n" "echo '$MARK' > /dev/kmsg; echo m=\$(grep -c ' mxfs ' /proc/mounts)")
    [ "$v" = "m=1" ] || { echo "LAP create_pace ABORT: $n is not mounted after the prep ($v)"; exit 2; }
done
# the loop run on the node: each create timed alone, the running pace every 1000
LOOP='d=$1; n=$2; mkdir -p "$d" || { echo "MKDIR_FAILED"; exit 1; }; bad=0; max=0; tot=0; i=0
while [ $i -lt $n ]; do s=${EPOCHREALTIME/./}; : > "$d/f$i" || bad=$((bad+1)); e=${EPOCHREALTIME/./}; t=$((e-s)); tot=$((tot+t)); [ $t -gt $max ] && max=$t; i=$((i+1))
[ $((i % 1000)) = 0 ] && echo "PACE at=$i mean_us=$((tot/i)) worst_us=$max"; done
sync; echo "CREATED=$i failed=$bad total_us=$tot mean_us=$((tot/(i>0?i:1))) worst_us=$max"'
run_loop() {   # <node> <dir> <outfile> <bound>
    timeout "$(( $4 + 10 ))" "$SSH" "$1" "timeout $4 bash -c '$LOOP' loop '$2' $NFILES" < /dev/null 2>/dev/null | filt > "$3"
}
D=$MNT/.createpace.$LABEL.$$
run_loop "$A" "$D" "$OUT/a_creates.txt" "$STAGE_S"
grep -a '^PACE' "$OUT/a_creates.txt" | sed 's/^/  /'
res=$(grep -a '^CREATED=' "$OUT/a_creates.txt" | tail -1)
echo "  MXFS on $A: ${res:-the stage did not finish inside ${STAGE_S} s}"
listed=$(rs 60 "$B" "ls -f '$D' 2>/dev/null | grep -c '^f'")
echo "  $B lists ${listed:-?} of $NFILES"
native=""
if [ -n "${NATIVE_DEV:-}" ]; then
    rs 60 "$A" "umount /mnt/createpace_xfs 2>/dev/null; mkfs.xfs -f -q '$NATIVE_DEV' && mkdir -p /mnt/createpace_xfs && timeout 30 mount -t xfs '$NATIVE_DEV' /mnt/createpace_xfs && echo NATIVE_MOUNTED" > "$OUT/native_mount.txt"
    if grep -q NATIVE_MOUNTED "$OUT/native_mount.txt"; then
        run_loop "$A" /mnt/createpace_xfs/d "$OUT/native_creates.txt" 60
        native=$(grep -a '^CREATED=' "$OUT/native_creates.txt" | tail -1)
        rs 40 "$A" "timeout 30 umount /mnt/createpace_xfs" > /dev/null
    fi
    echo "  native XFS on $A ($NATIVE_DEV): ${native:-not measured: $(tr '\n' ' ' < "$OUT/native_mount.txt" | cut -c1-160)}"
fi
for n in "$A" "$B"; do
    rs 30 "$n" "dmesg | awk '/$MARK/{f=1} f'" > "$OUT/${n}_kmsg.txt"
done
fault=$(grep -ah 'BUG:\|Oops\|hung_task\|blocked for more than\|Shutting down filesystem\|Corruption' "$OUT/${A}_kmsg.txt" "$OUT/${B}_kmsg.txt" | head -3)
worst_us=$(echo "$res" | sed -n 's/.* worst_us=\([0-9]*\).*/\1/p')
[ -n "$worst_us" ] && echo "max_stall_ms=$(( worst_us / 1000 ))"
fail=""
[ -n "$res" ] || fail="$fail the create stage did not finish inside ${STAGE_S} s;"
case "$res" in "CREATED=$NFILES failed=0 "*|"") ;; *) fail="$fail creates on $A: $res;" ;; esac
[ "${listed:-0}" = "$NFILES" ] || fail="$fail $B listed ${listed:-none} of $NFILES;"
[ -z "$fault" ] || fail="$fail fault signature: $(echo "$fault" | tr '\n' ' ' | cut -c1-200);"
if [ -n "$fail" ]; then
    echo "LAP create_pace FAIL:$fail evidence=$OUT"; exit 1
fi
echo "LAP create_pace PASS: $res; $B listed all $NFILES${native:+; native XFS $native} evidence=$OUT"
exit 0
