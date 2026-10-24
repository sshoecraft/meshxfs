#!/bin/bash
# peer_window_lap.sh — does a node with a short death window wait out a silent
# peer whose own window, and so its lease, is longer?
#
# WHY THIS EXISTS.  A node's authority lease is derived from its own death
# window, and the window outlasts the lease so that a node whose beats stopped
# landing has stopped writing before any peer declares it dead.  Each node
# declared on its own window and none published it, so on 8/disk/caw/mpath with
# test14 on the default window (a 30 s lease) and test7-test13 on a 12 s one,
# the 12 s nodes declared test14 dead 12.3 s after last seeing its stamp change
# (D-SURVIVOR-DECLARES-A-PEER-DEAD-ON-ITS-OWN-WINDOW-INSIDE-THE-PEERS-LONGER-LEASE).
# Every node now publishes its window in its heartbeat record's identity block,
# and a peer is declared only after the longer of the two windows
# (dlm/disklock.c, hb_dead_threshold_for).
#
# SHAPE:
#   1. prep the pair, both nodes on the default window.
#   2. B (last node) unmounts, takes dead_timeout_ms=LONG_MS, and mounts again;
#      then A (first node) unmounts, takes dead_timeout_ms=SHORT_MS and
#      dl_peer_window=ARM, and mounts again: each mount's "authority lease" line
#      must name its window, or the lap ABORTs.  Both windows are set here, at
#      run time, and not by the prep: a pair prepped with extra module arguments
#      is recorded as a variant, and a verification counts no variant lap
#      (tools/batch_lap.py env_variant).
#   3. B (last node) runs a writer, and its heartbeat thread is parked once for
#      PARK_MS (dl_inject_hb_pause_ms): its next beat lands about PARK_MS + 2 s
#      after the last, longer than A's window and inside B's own lease.
#   4. EXPOSURE: A's own window ran out on B's stamp, which A logs as
#      P-HB-PEER-WINDOW (held to B's window) or as its declaration of B.
#   5. PASS: A did not declare B; B never closed its authority; every one of
#      B's operations succeeded; both still mounted.  ARM=0 is the same-build
#      control: A holds B to its own window and declares it.
#
# the budget rule (derived): prep, measured 40-44 s on a pair, bound 120 + B's
# and A's unmount and mount ~6 s each, bound 70 each + premise reads 2 x 30 +
# the writer's span, 3 s before the park + one interval 2 s + PARK_MS 16 s + 8 s
# after = 29 s, bound 60 for its collection + journal reads 2 x 30 + mount checks
# 2 x 30 = 500 s.  Caller bound 520 s.
#
# Usage: tests/peer_window_lap.sh <label>
# Env:   MXFS_NODE_LIST (test1,test2), MXFS_CONFIG (2/disk/caw/direct),
#        SHORT_MS (12000), LONG_MS (34000, B's window), PARK_MS (16000),
#        ARM (1; 0 = the control)
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}
cd "$(dirname "$0")/.." || exit 2
export MXFS_NODE_LIST=${MXFS_NODE_LIST:-test1,test2}
export MXFS_CONFIG=${MXFS_CONFIG:-2/disk/caw/direct}
A=${MXFS_NODE_LIST%%,*}          # the short window
B=${MXFS_NODE_LIST##*,}          # the default window, its beat parked
MNT=/mnt/shared
PARM=/sys/module/mxfs/parameters
SHORT_MS=${SHORT_MS:-12000}
LONG_MS=${LONG_MS:-34000}
PARK_MS=${PARK_MS:-16000}
ARM=${ARM:-1}
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_peerwin_$LABEL
mkdir -p "$OUT"
fails=0
. "$(dirname "$0")/lib/rig.sh"
MARK="PEERWIN-MARK-$LABEL"
echo "=== peer_window_lap label=$LABEL config=$MXFS_CONFIG A(short)=$A B(parked)=$B short_ms=$SHORT_MS long_ms=$LONG_MS park_ms=$PARK_MS arm=$ARM $(date -u +%FT%TZ) ==="
s0=$(date +%s)
el() { echo $(( $(date +%s) - s0 )); }
field(){ grep -aoE "(^| )$2=[^ ]*" "$1" | head -1 | cut -d= -f2; }

if [ "$(strings -a mxfs.ko | grep -c 'P-HB-PEER-WINDOW')" = 0 ]; then
    echo "ABORT: mxfs.ko publishes no death window, so there is nothing here to measure"
    echo "RESULT: ABORT label=$LABEL stage=build evidence=$OUT"; exit 2
fi

GROUPARG=()
[ -n "${MXFS_GROUP:-}" ] && GROUPARG=(--group "$MXFS_GROUP")
MXFS_FORCE_PREP=1 timeout 120 ./run.sh "$MXFS_CONFIG" "${GROUPARG[@]}" prep_cluster > "$OUT/prep.log" 2>&1
prc=$?
echo "STAGE prep rc=$prc wall=$(el)s  $(grep -am1 'prep OK\|FAIL' "$OUT/prep.log" | cut -c1-140)"
[ $prc = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }

# ---- 2. B on the long window, then A alone on the short one
DEV=$(rs 15 "$A" "awk '\$2 == \"$MNT\" && \$3 == \"mxfs\" {print \$1}' /proc/mounts | head -1" 2>/dev/null | tr -d '\r\n')
[ -n "$DEV" ] || { echo "RESULT: ABORT label=$LABEL stage=device evidence=$OUT"; exit 2; }
BDEV=$(rs 15 "$B" "awk '\$2 == \"$MNT\" && \$3 == \"mxfs\" {print \$1}' /proc/mounts | head -1" 2>/dev/null | tr -d '\r\n')
[ -n "$BDEV" ] || { echo "RESULT: ABORT label=$LABEL stage=device evidence=$OUT"; exit 2; }
measure "$B" 70 "$OUT/B_remount.txt" '^REMOUNT_RC=[0-9]+$' "B's remount on the long window" \
    "timeout 30 umount $MNT || { echo REMOUNT_RC=91; exit 0; }; echo $LONG_MS > $PARM/dead_timeout_ms; timeout 30 mount -t mxfs $BDEV $MNT; echo REMOUNT_RC=\$?"
ck "B remounted" "$(field "$OUT/B_remount.txt" REMOUNT_RC)" 0
measure "$A" 70 "$OUT/A_remount.txt" '^REMOUNT_RC=[0-9]+$' "A's remount on the short window" \
    "timeout 30 umount $MNT || { echo REMOUNT_RC=91; exit 0; }; echo $SHORT_MS > $PARM/dead_timeout_ms; echo $ARM > $PARM/dl_peer_window; echo $MARK > /dev/kmsg; timeout 30 mount -t mxfs $DEV $MNT; echo REMOUNT_RC=\$?"
ck "A remounted" "$(field "$OUT/A_remount.txt" REMOUNT_RC)" 0
for n in "$A" "$B"; do
    measure "$n" 30 "$OUT/${n}_premise.txt" '^PREMISE_END$' "the window $n's mount runs" \
        "echo $MARK > /dev/kmsg; echo DEAD=\$(cat $PARM/dead_timeout_ms) PW=\$(cat $PARM/dl_peer_window); dmesg | grep -a 'disklock: authority lease' | tail -1 | sed 's/^/LEASE_LINE /'; grep -c ' $MNT ' /proc/mounts | sed 's/^/MOUNTED=/'; echo PREMISE_END"
    ck "$n is mounted" "$(field "$OUT/${n}_premise.txt" MOUNTED)" 1
done
ck "A runs the short window" "$(field "$OUT/${A}_premise.txt" DEAD)" "$SHORT_MS"
ck "A loaded dl_peer_window" "$(field "$OUT/${A}_premise.txt" PW)" "$ARM"
ck "A's mount derived its lease from the short window" \
    "$(grep -ac "authority lease $(( SHORT_MS - 4000 )) ms, death window $SHORT_MS ms" "$OUT/${A}_premise.txt")" 1
# B runs LONG_MS, set at its remount above.  Since the default window became
# 12 s, a B on the default runs A's window and the lap measures nothing; a lane
# gave B 34 s through MXFS_EXTRA_MODARGS at the prep, which made every lap a
# variant that no verification counts.  B's mount must derive a window longer
# than A's.
ck "B runs the long window" "$(field "$OUT/${B}_premise.txt" DEAD)" "$LONG_MS"
B_WIN=$(grep -aoE 'death window [0-9]+ ms' "$OUT/${B}_premise.txt" | tail -1 | grep -oE '[0-9]+')
ck "B's mount runs a longer window than A's ($SHORT_MS ms)" "$([ "${B_WIN:-0}" -gt "$SHORT_MS" ] && echo 1 || echo 0)" 1
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=premise evidence=$OUT"; exit 2; }

# ---- 3. B's writer, detached on B, and the park
SPAN=$(( 3 + 2 + PARK_MS / 1000 + 8 ))
measure "$B" 30 "$OUT/B_writer_start.txt" '^WRITER_STARTED$' "B's writer started" \
    "d=$MNT/peerwin_$LABEL; mkdir -p \$d || exit 1; rm -f /run/peerwin_$LABEL.ops; nohup setsid bash -c 'end=\$(( \$(date +%s) + $SPAN )); i=0; while [ \$(date +%s) -lt \$end ]; do i=\$((i+1)); f=$MNT/peerwin_$LABEL/f\$((i % 8)); t0=\$(date +%s%3N); dd if=/dev/zero of=\$f bs=64k count=4 conv=fsync status=none; rc=\$?; stat -c %s \$f > /dev/null; rc2=\$?; t1=\$(date +%s%3N); echo OP \$i \$t0 \$t1 \$rc \$rc2; sleep 0.2; done; echo OPS_END' > /run/peerwin_$LABEL.ops 2>&1 < /dev/null & echo WRITER_STARTED"
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=writer evidence=$OUT"; exit 2; }
sleep 3
measure "$B" 30 "$OUT/B_park.txt" '^PARKED=[0-9]+$' "the heartbeat park on $B" \
    "echo $PARK_MS > $PARM/dl_inject_hb_pause_ms; sleep 3; echo PARKED=\$(dmesg | sed -n '/$MARK/,\$p' | grep -ac 'P-HB-INJECT-PAUSE.*pausing')"
ck "B's heartbeat is parked" "$(field "$OUT/B_park.txt" PARKED)" 1
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=park evidence=$OUT"; exit 2; }
echo "STAGE parked at +$(el)s; the writer runs ${SPAN}s"

# ---- 4. the writer's span, then its record
sleep $(( SPAN - 3 ))
w=0
while :; do
    measure "$B" 30 "$OUT/B_ops.txt" '^OPSFILE_END$' "B's writer record" \
        "cat /run/peerwin_$LABEL.ops; echo OPSFILE_END"
    [ "$(cnt "$OUT/B_ops.txt" '^OPS_END$')" = 1 ] && break
    [ $w -ge 60 ] && break
    sleep 5; w=$((w+5))
done
OPS=$(cnt "$OUT/B_ops.txt" '^OP ')
OPS_BAD=$(awk '$1=="OP" && ($5!=0 || $6!=0)' "$OUT/B_ops.txt" | wc -l)
MAX_MS=$(awk '$1=="OP" { d=$4-$3; if (d>m) m=d } END { print m+0 }' "$OUT/B_ops.txt")
echo "STAGE B's writer: ops=$OPS failed=$OPS_BAD max_op_ms=$MAX_MS ended=$(cnt "$OUT/B_ops.txt" '^OPS_END$') at +$(el)s"
echo "max_stall_ms=$MAX_MS"

for n in "$A" "$B"; do
    measure "$n" 30 "$OUT/${n}_kmsg.txt" '^KMSG_END$' "$n's kernel log since the mark" \
        "dmesg | sed -n '/$MARK/,\$p' | cut -c1-700; echo KMSG_END"
done
HELD_N=$(cnt "$OUT/${A}_kmsg.txt" 'P-HB-PEER-WINDOW')
DECL_N=$(cnt "$OUT/${A}_kmsg.txt" 'no longer responding')
grep -a 'P-HB-PEER-WINDOW\|no longer responding\|P-HB-INJECT-PAUSE\|P290-AUTH' "$OUT/${A}_kmsg.txt" "$OUT/${B}_kmsg.txt" \
    | sed 's/.*mxfs: /    /' | cut -c1-260 | head -12
if [ "$HELD_N" = 0 ] && [ "$DECL_N" = 0 ]; then
    echo "  A's own window never ran out on B's stamp, so nothing here measures the declaration"
    echo "RESULT: VACUOUS label=$LABEL stage=no-window wall=$(el)s evidence=$OUT"; exit 3
fi
echo "EXPOSED: A's own ${SHORT_MS} ms window ran out on B's parked stamp (held=$HELD_N declared=$DECL_N)"

# ---- 5. the verdict
ck "A never declared B dead" "$DECL_N" 0
ck "B never closed its authority" "$(cnt "$OUT/${B}_kmsg.txt" 'P290-AUTH-CLOSED')" 0
ck "B shut nothing down" "$(cnt "$OUT/${B}_kmsg.txt" 'shut down\|P290-AUTH-HB-STOP\|P277')" 0
ck "B's writer ended inside its bound" "$(cnt "$OUT/B_ops.txt" '^OPS_END$')" 1
ckge "B's writer ran" "$OPS" 10
ck "every one of B's operations succeeded" "$OPS_BAD" 0
for n in "$A" "$B"; do
    measure "$n" 30 "$OUT/${n}_after.txt" '^AFTER_END$' "$n still mounted and writable" \
        "grep -c ' $MNT ' /proc/mounts | sed 's/^/MOUNTED=/'; timeout 20 sh -c 'printf after > $MNT/peerwin_$LABEL/after_$n && sync -f $MNT' && echo WROTE; echo AFTER_END"
    ck "$n is still mounted" "$(field "$OUT/${n}_after.txt" MOUNTED)" 1
    ck "$n still writes" "$(cnt "$OUT/${n}_after.txt" '^WROTE$')" 1
    # a dynamic-debug line reads "DEBUG:", which a bare 'BUG:' also matches
    ck "$n: zero BUG / Oops" "$(cnt "$OUT/${n}_kmsg.txt" '^BUG:\|[^E]BUG:\|kernel BUG at\|Oops')" 0
done
# A and B back on the default window for whatever runs next (a later prep reloads both)
rs 15 "$A" "echo 0 > $PARM/dead_timeout_ms; echo 1 > $PARM/dl_peer_window" > /dev/null 2>&1
rs 15 "$B" "echo 0 > $PARM/dead_timeout_ms" > /dev/null 2>&1

if [ $fails = 0 ]; then
    echo "LAP peer_window PASS: A held B to B's window ($HELD_N), declared nothing; B's longest operation ${MAX_MS} ms"
else
    echo "LAP peer_window FAIL: $fails check(s) failed (held=$HELD_N declared=$DECL_N ops_failed=$OPS_BAD max_op_ms=$MAX_MS)"
fi
echo "RESULT: $( [ $fails = 0 ] && echo PASS || echo FAIL ) label=$LABEL fails=$fails wall=$(el)s evidence=$OUT"
[ $fails = 0 ]
