#!/bin/bash
# auth_suspend_lap.sh — does a LIVE node whose beats land later than its lease,
# but inside its peers' death window, suspend and carry on, rather than shut
# down?
#
# WHY THIS EXISTS.  On a SCSI attachment the authority lease is the death window
# less MXFS_DISKLOCK_SCSI_LEASE_RESERVE_MS, and its deadline SUSPENDS the node
# instead of closing its authority (dlm/disklock.h, at that constant; ruled in
# docs/rulings/silent-peer-death-under-the-stall-limit.md, "Keeping the window
# longer than the lease").  A beat completing before revalidate_by_ms readmits
# the same incarnation.  That is what lets the death window shrink below the
# 30 s stall limit
# (D-SILENT-PEER-DEATH-TAKES-35S-TO-DETECT-SO-SURVIVORS-STALL-OVER-30S): a live
# node's landed beats were measured 15-17 s apart across a single-path failover,
# so a lease short enough for survivors to take over inside 30 s would close on
# that gap and shut a live node down.  Nothing had run the suspension yet.
#
# SHAPE:
#   1. prep the pair with dead_timeout_ms=DEAD_MS (a window of DEAD_MS, a lease
#      of DEAD_MS less 4 s) and dl_auth_suspend=SUSPEND on both nodes; the
#      mount's own "authority lease" line must say so, or the lap ABORTs.
#   2. B runs a writer: each operation writes 256 KiB with fsync and stats the
#      file, its start and end in milliseconds, 200 ms apart.
#   3. B's heartbeat thread is parked once for PARK_MS (dl_inject_hb_pause_ms).
#      The park sits at the top of the beat loop, one interval (2 s) after the
#      last beat, so the next beat is issued about PARK_MS + 2 s after it: past
#      the lease, inside the window.
#   4. EXPOSURE: B's lease ran out while it was live and writing, which B logs
#      as P290-AUTH-SUSPENDED (suspension on) or P290-AUTH-CLOSED (off).
#   5. With suspension on, B must log P290-AUTH-RESUMED and never close, every
#      operation must succeed, none may stall past the 30 s stall limit
#      (data/release_policy.json stall_limit_s), A must not declare B dead,
#      and both must still be mounted.  SUSPEND=0 is the same-build control:
#      the deadline closes B's authority and the lap fails.
#
# the budget rule (derived): prep, measured 40-44 s on g2 and g2b, bound 120 +
# premise reads 2 x 30 + the writer's span, 3 s before the park + one interval
# 2 s + PARK_MS 15 s + 8 s after = 28 s, bound 60 for its collection + journal
# reads 2 x 30 + mount checks 30 = 330 s.  Caller bound 360 s.
#
# Usage: tests/auth_suspend_lap.sh <label>
# Env:   MXFS_NODE_LIST (test1,test2), MXFS_CONFIG (2/net/mesh/direct),
#        DEAD_MS (20000), PARK_MS (15000), SUSPEND (1; 0 = the control)
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}
cd "$(dirname "$0")/.." || exit 2
export MXFS_NODE_LIST=${MXFS_NODE_LIST:-test1,test2}
export MXFS_CONFIG=${MXFS_CONFIG:-2/net/mesh/direct}
A=${MXFS_NODE_LIST%%,*}
B=${MXFS_NODE_LIST##*,}          # the node whose beat is parked
SSH=tools/mxfs_sshpass.sh
MNT=/mnt/shared
PARM=/sys/module/mxfs/parameters
DEAD_MS=${DEAD_MS:-20000}
PARK_MS=${PARK_MS:-15000}
SUSPEND=${SUSPEND:-1}
LEASE_MS=$(( DEAD_MS - 4000 ))
STALL_LIMIT_MS=$(( $(python3 -c "import json; print(json.load(open('data/release_policy.json'))['stall_limit_s'])") * 1000 ))
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_authsusp_$LABEL
mkdir -p "$OUT"
fails=0
. "$(dirname "$0")/lib/rig.sh"
MARK="AUTHSUSP-MARK-$LABEL"
echo "=== auth_suspend_lap label=$LABEL config=$MXFS_CONFIG A=$A B(parked)=$B dead_ms=$DEAD_MS lease_ms=$LEASE_MS park_ms=$PARK_MS suspend=$SUSPEND $(date -u +%FT%TZ) ==="
s0=$(date +%s)
el() { echo $(( $(date +%s) - s0 )); }
field(){ grep -aoE "(^| )$2=[^ ]*" "$1" | head -1 | cut -d= -f2; }

if [ "$(strings -a mxfs.ko | grep -c 'P290-AUTH-RESUMED')" = 0 ]; then
    echo "ABORT: mxfs.ko carries no lease suspension, so there is nothing here to measure"
    echo "RESULT: ABORT label=$LABEL stage=build evidence=$OUT"; exit 2
fi

GROUPARG=()
[ -n "${MXFS_GROUP:-}" ] && GROUPARG=(--group "$MXFS_GROUP")
MXFS_FORCE_PREP=1 MXFS_EXTRA_MODARGS="dead_timeout_ms=$DEAD_MS dl_auth_suspend=$SUSPEND" \
    timeout 120 ./run.sh "$MXFS_CONFIG" "${GROUPARG[@]}" prep_cluster > "$OUT/prep.log" 2>&1
prc=$?
echo "STAGE prep rc=$prc wall=$(el)s  $(grep -am1 'prep OK\|FAIL' "$OUT/prep.log" | cut -c1-140)"
[ $prc = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }

# ---- 1. the premise: both nodes run this window, and B's mount derived the
#         lease and the deadline from it
want_line="authority lease $LEASE_MS ms, death window $DEAD_MS ms, deadline $([ "$SUSPEND" = 1 ] && echo suspends || echo closes)"
for n in "$A" "$B"; do
    measure "$n" 30 "$OUT/${n}_premise.txt" '^PREMISE_END$' "the window and lease $n's mount runs" \
        "echo $MARK > /dev/kmsg; echo DEAD=\$(cat $PARM/dead_timeout_ms) SUSP=\$(cat $PARM/dl_auth_suspend); dmesg | grep -a 'disklock: authority lease' | tail -1 | sed 's/^/LEASE_LINE /'; grep -c ' $MNT ' /proc/mounts | sed 's/^/MOUNTED=/'; echo PREMISE_END"
    ck "$n loaded dead_timeout_ms" "$(field "$OUT/${n}_premise.txt" DEAD)" "$DEAD_MS"
    ck "$n loaded dl_auth_suspend" "$(field "$OUT/${n}_premise.txt" SUSP)" "$SUSPEND"
    ck "$n is mounted" "$(field "$OUT/${n}_premise.txt" MOUNTED)" 1
done
ck "B's mount derived the lease and deadline from the window" \
    "$(grep -ac "$want_line" "$OUT/${B}_premise.txt")" 1
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=premise evidence=$OUT"; exit 2; }

# ---- 2. B's writer, detached on B so a stalled operation cannot stall the lap
SPAN=$(( 3 + 2 + PARK_MS / 1000 + 8 ))
measure "$B" 30 "$OUT/B_writer_start.txt" '^WRITER_STARTED$' "B's writer started" \
    "d=$MNT/authsusp_$LABEL; mkdir -p \$d || exit 1; rm -f /run/authsusp_$LABEL.ops; nohup setsid bash -c 'end=\$(( \$(date +%s) + $SPAN )); i=0; while [ \$(date +%s) -lt \$end ]; do i=\$((i+1)); f=$MNT/authsusp_$LABEL/f\$((i % 8)); t0=\$(date +%s%3N); dd if=/dev/zero of=\$f bs=64k count=4 conv=fsync status=none; rc=\$?; stat -c %s \$f > /dev/null; rc2=\$?; t1=\$(date +%s%3N); echo OP \$i \$t0 \$t1 \$rc \$rc2; sleep 0.2; done; echo OPS_END' > /run/authsusp_$LABEL.ops 2>&1 < /dev/null & echo WRITER_STARTED"
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=writer evidence=$OUT"; exit 2; }
sleep 3

# ---- 3. park B's heartbeat once
measure "$B" 30 "$OUT/B_park.txt" '^PARKED=[0-9]+$' "the heartbeat park on $B" \
    "echo $PARK_MS > $PARM/dl_inject_hb_pause_ms; sleep 3; echo PARKED=\$(dmesg | sed -n '/$MARK/,\$p' | grep -ac 'P-HB-INJECT-PAUSE.*pausing')"
ck "B's heartbeat is parked" "$(field "$OUT/B_park.txt" PARKED)" 1
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=park evidence=$OUT"; exit 2; }
echo "STAGE parked at +$(el)s; the writer runs ${SPAN}s"

# ---- 4. the writer's span, then its record.  OPS_END is its last line; an
#         operation still stuck when the bound runs out leaves none.
sleep $(( SPAN - 3 ))
w=0
while :; do
    measure "$B" 30 "$OUT/B_ops.txt" '^OPSFILE_END$' "B's writer record" \
        "cat /run/authsusp_$LABEL.ops; echo OPSFILE_END"
    [ "$(cnt "$OUT/B_ops.txt" '^OPS_END$')" = 1 ] && break
    [ $w -ge 60 ] && break
    sleep 5; w=$((w+5))
done
OPS=$(cnt "$OUT/B_ops.txt" '^OP ')
OPS_BAD=$(awk '$1=="OP" && ($5!=0 || $6!=0)' "$OUT/B_ops.txt" | wc -l)
MAX_MS=$(awk '$1=="OP" { d=$4-$3; if (d>m) m=d } END { print m+0 }' "$OUT/B_ops.txt")
echo "STAGE B's writer: ops=$OPS failed=$OPS_BAD max_op_ms=$MAX_MS ended=$(cnt "$OUT/B_ops.txt" '^OPS_END$') at +$(el)s"
echo "max_stall_ms=$MAX_MS"

# ---- 5. both journals since the mark
for n in "$A" "$B"; do
    measure "$n" 30 "$OUT/${n}_kmsg.txt" '^KMSG_END$' "$n's kernel log since the mark" \
        "dmesg | sed -n '/$MARK/,\$p' | cut -c1-700; echo KMSG_END"
done
SUSP_N=$(cnt "$OUT/${B}_kmsg.txt" 'P290-AUTH-SUSPENDED node')
RES_N=$(cnt "$OUT/${B}_kmsg.txt" 'P290-AUTH-RESUMED')
CLOSED_N=$(cnt "$OUT/${B}_kmsg.txt" 'P290-AUTH-CLOSED')
grep -a 'P-HB-INJECT-PAUSE\|P290-AUTH-SUSPENDED\|P290-AUTH-RESUMED\|P290-AUTH-CLOSED\|P290-AUTH-HB-STOP\|P-HB-SLOW' "$OUT/${B}_kmsg.txt" \
    | sed 's/.*mxfs: /    /' | cut -c1-230 | head -12
if [ "$SUSP_N" = 0 ] && [ "$CLOSED_N" = 0 ]; then
    echo "  B's lease never ran out under the park, so nothing here is a measurement of the deadline"
    echo "RESULT: VACUOUS label=$LABEL stage=no-deadline wall=$(el)s evidence=$OUT"; exit 3
fi
echo "EXPOSED: B's lease ran out while B was live and writing (suspended=$SUSP_N closed=$CLOSED_N)"

# ---- 6. the verdict
ck "B never closed its authority" "$CLOSED_N" 0
ckge "B resumed the same incarnation" "$RES_N" 1
ck "B shut nothing down" "$(cnt "$OUT/${B}_kmsg.txt" 'shut down\|P290-AUTH-HB-STOP\|P277')" 0
ck "B's writer ended inside its bound" "$(cnt "$OUT/B_ops.txt" '^OPS_END$')" 1
ckge "B's writer ran" "$OPS" 10
ck "every one of B's operations succeeded" "$OPS_BAD" 0
ck "no operation of B's stalled past the stall limit" "$([ "$MAX_MS" -lt "$STALL_LIMIT_MS" ] && echo under || echo over)" under
ck "A never declared B dead" "$(cnt "$OUT/${A}_kmsg.txt" 'no longer responding\|initiating recovery')" 0
for n in "$A" "$B"; do
    measure "$n" 30 "$OUT/${n}_after.txt" '^AFTER_END$' "$n still mounted and writable" \
        "grep -c ' $MNT ' /proc/mounts | sed 's/^/MOUNTED=/'; timeout 20 sh -c 'printf after > $MNT/authsusp_$LABEL/after_$n && sync -f $MNT' && echo WROTE; echo AFTER_END"
    ck "$n is still mounted" "$(field "$OUT/${n}_after.txt" MOUNTED)" 1
    ck "$n still writes" "$(cnt "$OUT/${n}_after.txt" '^WROTE$')" 1
    ck "$n: zero BUG / Oops" "$(cnt "$OUT/${n}_kmsg.txt" 'BUG:\|Oops')" 0
done

if [ $fails = 0 ]; then
    echo "LAP auth_suspend PASS: B suspended $SUSP_N time(s) and resumed $RES_N, longest operation ${MAX_MS} ms, A declared nothing"
else
    echo "LAP auth_suspend FAIL: $fails check(s) failed (suspended=$SUSP_N resumed=$RES_N closed=$CLOSED_N max_op_ms=$MAX_MS)"
fi
echo "RESULT: $( [ $fails = 0 ] && echo PASS || echo FAIL ) label=$LABEL fails=$fails wall=$(el)s evidence=$OUT"
[ $fails = 0 ]
