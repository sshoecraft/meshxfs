#!/bin/bash
# last_member_umount_lap.sh -- one lap of D-LAST-MEMBER-UMOUNT-AFTER-A-15K-PAGE-HANDBACK-TAKES-31S-OVER-THE-STALL-LIMIT.
#
# The defect: the last member's unmount released its locally mastered grants one at a time,
# each a ledger page commit of about 0.9 ms, so at NFILES=32000 the release-all alone took 28 s
# and A's unmount 29-32 s, over stall_limit_s (data/release_policy.json).  The fix runs those
# releases on dl_relall_threads threads (8); dl_relall_threads=1 is the old serial release, the
# control.  Measured 2026-10-23 at 32000 on E7B6958F435B9792735556D: 8 threads 9606 and 8357 ms
# (P-RELALL-WALL 6872, 6810 ms), 1 thread 29255 ms (P-RELALL-WALL 25876 ms), and 30972 and
# 31746 ms the day before.  At 32000 the serial release sits on the limit, so the lap runs 40000:
# the same release-all, a quarter more grants, which puts the serial release (about 0.8 ms a
# grant) over the limit on every lap and leaves the threaded one far under it.
#
# A lap: form the cluster (MXFS_FORCE_PREP=1 run.sh <configuration> prep_cluster, which inherits
# MXFS_EXTRA_MODARGS, so the control's dl_relall_threads=1 is loaded with the module), read the
# knob back on every node.  On a cluster of more than two, A (the first of MXFS_NODE_LIST) then
# creates the NFILES entries with every member mounted, and every member between A and B (the
# last) unmounts, one after another, so A and B are the last two members.  Then
# tests/last_member_umount_trace.sh: NFILES creates on A (a stat of each when they exist), B's
# clean unmount handing its ledger pages to A, A's unmount as the last member, sampled.
# LMU_OTHERS_FIRST=0 leaves the other members mounted, as before (A is then not the last member
# on a cluster of more than two).
#
#   EXPOSED  A's unmount ran the release-all over at least 90% of NFILES grants (P-RELALL-WALL)
#   PASS     A's unmount returned 0 in under stall_limit_s
#   FAIL     A's unmount took stall_limit_s or more, or did not return 0
#   ABORT    the pair could not be formed, the knob did not read back the same on both nodes,
#            or the trace measured nothing
#
# Bound, derived from the 2026-10-23 traces: prep_cluster 37-42 s; 40000 creates at 2.2-2.3 ms
# each, about 92 s; B's unmount 1.7-2.0 s; A's unmount at most about 36 s serial; the kernel-log
# fetch and the stack summary a few seconds: about 176 s, so a caller bounds the lap at 360 s.
# On more than two nodes the creates before the others leave (NFILES/25+60 s) and each other
# member's unmount (stall limit + 20 s) come on top, and the trace stats the entries instead of
# creating them; the caller derives that lap's bound from a precheck's wall.
#
# Usage: tests/last_member_umount_lap.sh <label> <configuration>
#        (the group's env exported: MXFS_GROUP, MXFS_MARKER, MXFS_NODE_LIST; NFILES default 40000)
# Leaves both nodes unmounted.  Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
CONFIG=${2:?configuration}
cd "$(dirname "$0")/.." || exit 2
NODES=${MXFS_NODE_LIST:?MXFS_NODE_LIST}
A=${NODES%%,*}; B=${NODES##*,}
export NFILES=${NFILES:-40000}
LIMIT_MS=$(python3 -c 'import json; print(int(json.load(open("data/release_policy.json"))["stall_limit_s"] * 1000))')
echo "LAP lmu start $(date -u +%FT%TZ) label=$LABEL at=$CONFIG A=$A B=$B nfiles=$NFILES limit_ms=$LIMIT_MS modargs=[${MXFS_EXTRA_MODARGS:-}]"
prep=$(MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" ${MXFS_GROUP:+--group "$MXFS_GROUP"} prep_cluster < /dev/null 2>&1)
rc=$?
[ "$rc" = 0 ] || { echo "LAP lmu ABORT: prep_cluster rc=$rc: $(echo "$prep" | tail -2 | tr '\n' ' ' | cut -c1-240)"; exit 2; }
IFS=, read -r -a ALL <<< "$NODES"
OTHERS=("${ALL[@]:1:${#ALL[@]}-2}")
k=
for n in "$A" "${OTHERS[@]}" "$B"; do
    v=$(timeout 20 tools/mxfs_sshpass.sh "$n" 'echo KNOB=$(cat /sys/module/mxfs/parameters/dl_relall_threads) m=$(grep -c " mxfs " /proc/mounts)' < /dev/null 2>/dev/null | grep -a '^KNOB=' | tail -1)
    echo "  KNOB $n $v"
    case "$v" in KNOB=[0-9]*' m=1') ;; *) echo "LAP lmu ABORT: $n did not read back a knob on a mounted pair ($v)"; exit 2 ;; esac
    [ -z "$k" ] || [ "$k" = "${v%% *}" ] || { echo "LAP lmu ABORT: the knob differs between the nodes ($k, ${v%% *})"; exit 2; }
    k=${v%% *}
done
# On more than two nodes: A creates the entries while every member is mounted, so their grants
# are mastered across the whole cluster, and then the other members leave, each a clean unmount
# bounded by the stall limit plus its ssh; the trace then finds the entries and stats them.
if [ "${LMU_OTHERS_FIRST:-1}" = 1 ] && [ "${#OTHERS[@]}" -gt 0 ]; then
    v=$(timeout $(( NFILES / 25 + 60 )) tools/mxfs_sshpass.sh "$A" "D=/mnt/shared/.lmutrace; mkdir -p \$D && i=0; s=\$(date +%s%N); while [ \$i -lt $NFILES ]; do : > \$D/f\$i || break; i=\$((i+1)); done; sync; echo CREATED=\$i ms=\$(( (\$(date +%s%N)-s)/1000000 ))" < /dev/null 2>/dev/null | grep -a '^CREATED=' | tail -1)
    echo "  CREATES on $A with ${#ALL[@]} members: $v"
    case "$v" in "CREATED=$NFILES "*) ;; *) echo "LAP lmu ABORT: A created ${v:-nothing} of $NFILES with every member mounted"; exit 2 ;; esac
    for n in "${OTHERS[@]}"; do
        v=$(timeout $(( LIMIT_MS / 1000 + 20 )) tools/mxfs_sshpass.sh "$n" "s=\$(date +%s%N); umount /mnt/shared; rc=\$?; echo OTHER_UMOUNT_RC=\$rc ms=\$(( (\$(date +%s%N)-s)/1000000 )) m=\$(grep -c ' mxfs ' /proc/mounts)" < /dev/null 2>/dev/null | grep -a '^OTHER_UMOUNT_RC=' | tail -1)
        echo "  OTHER $n $v"
        case "$v" in 'OTHER_UMOUNT_RC=0 '*' m=0') ;; *) echo "LAP lmu ABORT: $n did not leave the cluster cleanly before A and B ($v)"; exit 2 ;; esac
    done
fi
out=$(tests/last_member_umount_trace.sh "$LABEL" "$A" "$B" < /dev/null 2>&1)
echo "$out" | grep -a '^===\|^  INFO\|^ABORT\|^RESULT' | cut -c1-240
ev=$(echo "$out" | grep -ao '^RESULT: TRACED .* evidence=[^ ]*' | sed 's/.*evidence=//')
[ -n "$ev" ] && [ -f "$ev/a_kmsg.txt" ] || { echo "LAP lmu ABORT: the trace measured nothing"; exit 2; }
wall=$(grep -a 'P-RELALL-WALL' "$ev/a_kmsg.txt" | tail -1)
released=$(echo "$wall" | grep -ao 'released=[0-9]*' | head -1 | cut -d= -f2)
threads=$(echo "$wall" | grep -ao 'threads=[0-9]*' | head -1 | cut -d= -f2)
relms=$(echo "$wall" | grep -ao ' ms=[0-9]*' | head -1 | cut -d= -f2)
if [ -n "$released" ] && [ "$released" -ge $(( NFILES * 9 / 10 )) ]; then
    echo "EXPOSED: A's last-member unmount released $released grants (threads=$threads release_all_ms=$relms)"
else
    echo "  INFO not exposed: P-RELALL-WALL [${wall:-none}]"
fi
um=$(grep -a '^A_UMOUNT_RC=' "$ev/a_umount_samples.txt" | tail -1)
urc=$(echo "$um" | grep -ao 'A_UMOUNT_RC=[0-9]*' | cut -d= -f2)
ums=$(echo "$um" | grep -ao 'ms=[0-9]*' | cut -d= -f2)
[ -n "$urc" ] && [ -n "$ums" ] || { echo "LAP lmu ABORT: no A_UMOUNT_RC line in $ev"; exit 2; }
if [ "$urc" = 0 ] && [ "$ums" -lt "$LIMIT_MS" ]; then
    echo "LAP lmu PASS: A's last-member unmount took $ums ms of $LIMIT_MS (threads=$threads) evidence=$ev"
    exit 0
fi
echo "LAP lmu FAIL: A's last-member unmount rc=$urc took $ums ms, limit $LIMIT_MS (threads=$threads) evidence=$ev"
exit 1
