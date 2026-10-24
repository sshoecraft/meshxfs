#!/bin/bash
# retire_pending_next_mount_lap.sh -- what the next mount does with a slot the last member left
# RETIRE_PENDING (D-LAST-MEMBER-UNMOUNT-LEAVES-A-DEPARTED-SLOTS-PR-KEY-UNCLASSIFIED-30S).
#
# Seen in lap lmuc2 of control b20261023-9a3afc (tests/evidence/20261023T104328Z_lmutrace_lmuc2/
# a_kmsg.txt:6470): B left cleanly, so its heartbeat slot read RETIRE_PENDING until a node with PR
# evidence proved its key gone; A, unmounting as the last member, could not classify the key and
# logged P304-RETIRE-UNKNOWN-STALLED after 30.8 s, and nothing settled the slot before A left.
# The next mount settles such a slot on its own thread (v5_mount.c, the RETIRE_PENDING loop before
# admission: ABSENT -> EMPTY, PRESENT -> WITHDRAWN, anything else holds the gate,
# P-ADMIT-RETIRE-PENDING-HELD).  Hypothesis (falsifiable): after B's clean unmount and A's
# unmount right behind it, A's next mount finds B's slot RETIRE_PENDING, settles it EMPTY from
# its own READ KEYS, and returns inside the stall limit with no P-ADMIT-RETIRE-PENDING-HELD;
# B's mount after it is likewise under the limit.
#
# A lap: form the pair (run.sh <configuration> prep_cluster, both mounted), mark both kernel
# logs, unmount B, unmount A at once, mount A, mount B, each timed on its node, then read each
# node's kernel lines after the mark.
#
#   EXPOSED  A's next mount logged that it saw B's slot RETIRE_PENDING
#            (P304-RETIRE-PENDING-SEEN ... immediate=1, or P-ADMIT-RETIRE-PENDING-HELD)
#   PASS     both mounts returned 0 under stall_limit_s and neither logged
#            P-ADMIT-RETIRE-PENDING-HELD or P304-RETIRE-UNKNOWN-STALLED
#   FAIL     a mount failed, took stall_limit_s or more, or a node held admission on the slot
#   ABORT    the pair could not be formed, or an unmount failed
#
# Bound, derived: prep_cluster 37-58 s on a 2-node pair (the 2026-10-23 laps); each unmount of an
# idle pair 1.7-2 s (B's in tests/last_member_umount_trace.sh runs), each mount 3-8 s
# (join_during_takeover's remounts); the kernel-log reads a few seconds: about 80 s, so a caller
# bounds the lap at 2x, 160 s.  The mounts and unmounts are each bounded at 60 s here, twice the
# stall limit, so a hung one ends as a FAIL with its wall.
#
# Usage: tests/retire_pending_next_mount_lap.sh <label> <configuration>
#        (the group's env exported: MXFS_GROUP, MXFS_MARKER, MXFS_NODE_LIST)
# Leaves both nodes mounted.  Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
CONFIG=${2:?configuration}
cd "$(dirname "$0")/.." || exit 2
NODES=${MXFS_NODE_LIST:?MXFS_NODE_LIST}
A=${NODES%%,*}; B=${NODES##*,}
SSH=tools/mxfs_sshpass.sh
MNT=${MXFS_MNT:-/mnt/shared}
. tests/lib/rig.sh
LIMIT_MS=$(python3 -c 'import json; print(int(json.load(open("data/release_policy.json"))["stall_limit_s"] * 1000))')
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_rpnext_$LABEL
mkdir -p "$OUT"
echo "LAP retire_pending_next_mount start $(date -u +%FT%TZ) label=$LABEL at=$CONFIG A=$A B=$B limit_ms=$LIMIT_MS out=$OUT"
prep=$(MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" ${MXFS_GROUP:+--group "$MXFS_GROUP"} prep_cluster < /dev/null 2>&1)
rc=$?
[ "$rc" = 0 ] || { echo "LAP retire_pending_next_mount ABORT: prep_cluster rc=$rc: $(echo "$prep" | tail -2 | tr '\n' ' ' | cut -c1-240)"; exit 2; }
MARKER=${MXFS_MARKER:-.cluster_marker.json}
DEV=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("dev",""))' "$MARKER" 2>/dev/null)
[ -n "$DEV" ] || { echo "LAP retire_pending_next_mount ABORT: $MARKER names no device"; exit 2; }
MARK="RPNEXT-$LABEL-$$"
for n in "$A" "$B"; do
    v=$(rs 20 "$n" "echo '$MARK' > /dev/kmsg; echo m=\$(grep -c ' mxfs ' /proc/mounts)")
    [ "$v" = "m=1" ] || { echo "LAP retire_pending_next_mount ABORT: $n is not mounted after the prep ($v)"; exit 2; }
done
timed() {   # <node> <what> -> "<WHAT>_RC=<rc> ms=<ms>"
    rs 70 "$1" "s=\$(date +%s%N); timeout 60 $2; rc=\$?; e=\$(date +%s%N); echo RC=\$rc ms=\$(( (e-s)/1000000 ))" | grep -a '^RC=' | tail -1
}
bu=$(timed "$B" "umount $MNT"); echo "  B unmount: ${bu:-no answer}"
au=$(timed "$A" "umount $MNT"); echo "  A unmount (last member, right after B): ${au:-no answer}"
case "$bu $au" in "RC=0 ms="*" RC=0 ms="*) ;; *) echo "LAP retire_pending_next_mount ABORT: an unmount did not return 0 (B: $bu, A: $au)"; exit 2 ;; esac
am=$(timed "$A" "mount -t mxfs $DEV $MNT"); echo "  A next mount: ${am:-no answer}"
bm=$(timed "$B" "mount -t mxfs $DEV $MNT"); echo "  B mount after it: ${bm:-no answer}"
for n in "$A" "$B"; do
    rs 30 "$n" "dmesg | awk '/$MARK/{f=1} f'" > "$OUT/${n}_kmsg.txt"
done
grep -a 'P304-RETIRE\|P-ADMIT-RETIRE\|admission-settled' "$OUT/${A}_kmsg.txt" "$OUT/${B}_kmsg.txt" | cut -c1-260 | sed 's/^/  KMSG /'
if grep -aq 'P304-RETIRE-PENDING-SEEN.*immediate=1\|P-ADMIT-RETIRE-PENDING-HELD' "$OUT/${A}_kmsg.txt"; then
    echo "EXPOSED: A's next mount saw a slot left RETIRE_PENDING by the departures"
else
    echo "  INFO not exposed: A's next mount logged no RETIRE_PENDING slot"
fi
fail=""
for m in "A:$am" "B:$bm"; do
    who=${m%%:*}; v=${m#*:}
    r=$(echo "$v" | sed -n 's/^RC=\([0-9]*\) .*/\1/p'); ms=$(echo "$v" | sed -n 's/.* ms=\([0-9]*\)$/\1/p')
    [ "$r" = 0 ] && [ -n "$ms" ] && [ "$ms" -lt "$LIMIT_MS" ] || fail="$fail $who's mount ${v:-gave no answer};"
done
for n in "$A" "$B"; do
    c=$(grep -ac 'P-ADMIT-RETIRE-PENDING-HELD\|P304-RETIRE-UNKNOWN-STALLED' "$OUT/${n}_kmsg.txt")
    [ "$c" = 0 ] || fail="$fail $n held admission or could not classify the slot ($c line(s));"
done
echo "max_stall_ms=$(printf '%s\n%s\n' "$am" "$bm" | sed -n 's/.* ms=\([0-9]*\)$/\1/p' | sort -n | tail -1)"
if [ -n "$fail" ]; then
    echo "LAP retire_pending_next_mount FAIL:$fail evidence=$OUT"; exit 1
fi
echo "LAP retire_pending_next_mount PASS: A's mount $am, B's $bm, no slot held admission evidence=$OUT"
exit 0
