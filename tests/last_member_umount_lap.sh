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
# A lap: form the pair (MXFS_FORCE_PREP=1 run.sh <configuration> prep_cluster, which inherits
# MXFS_EXTRA_MODARGS, so the control's dl_relall_threads=1 is loaded with the module), read the
# knob back on both nodes, then tests/last_member_umount_trace.sh: NFILES creates on A, B's clean
# unmount handing its ledger pages to A, A's unmount as the last member, sampled.
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
k=
for n in "$A" "$B"; do
    v=$(timeout 20 tools/mxfs_sshpass.sh "$n" 'echo KNOB=$(cat /sys/module/mxfs/parameters/dl_relall_threads) m=$(grep -c " mxfs " /proc/mounts)' < /dev/null 2>/dev/null | grep -a '^KNOB=' | tail -1)
    echo "  KNOB $n $v"
    case "$v" in KNOB=[0-9]*' m=1') ;; *) echo "LAP lmu ABORT: $n did not read back a knob on a mounted pair ($v)"; exit 2 ;; esac
    [ -z "$k" ] || [ "$k" = "${v%% *}" ] || { echo "LAP lmu ABORT: the knob differs between the nodes ($k, ${v%% *})"; exit 2; }
    k=${v%% *}
done
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
