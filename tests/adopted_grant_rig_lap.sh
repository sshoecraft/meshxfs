#!/bin/bash
# adopted_grant_rig_lap.sh -- D-8NETMESH-SURVIVOR-SHUTDOWN-FALSE-FRESH-AG-GRANT-AFTER-TAKEOVER on
# the rig's own module: the sequence test21 ran into on 8/net/mesh/mpath, forced on one file of a
# formed cluster.
#
# WHY THIS EXISTS.  test21 waited for EX on AG 6, mastered by test24.  The grant arrived between
# two attempts of the wait and was kept for it (P958-ACQ-GRANT-ADOPTED).  A view change then
# handed AG 6's ledger page from test24 to test21 (P-TAUTH-PAGE-MINE via=frozen-msg), so the
# mirror the grant had installed became the lock master's own record of test21's EX.  The wait's
# next attempt was answered by the already-granted shortcut (P958-ACQ-LOCAL-ANSWER-END
# site=shortcut), which ended the acquisition record unclaimed: the adopted grant was handed back
# and its release unlinked that entry, so test21 held EX while its own master recorded nobody.
# The master then granted another node's EX, the ledger refused it 110 times in six seconds
# (P-TAUTH-DOUBLE-GRANT ... vs record ex=test21), and test21 shut down (P130-FALSE-FRESH).  The
# fix (dl_shortcut_claim=1, dlm/dlm.c) makes the shortcut's answer take the adopted grant.
# tests/tauth/adopted_grant_handoff_test.sh forces the sequence in four simulated nodes in one
# process; this lap forces it on the rig, so a verification is exposed at the configuration it
# clears, on the candidate's module, and graded from the nodes' own kernel logs.
#
# SHAPE.  R is a file this lap creates; A, B, C and D are nodes of the formation.
#   0. prep; each node's DLM node id from its mount's 'DLM init: node_id=' line; NCAND files are
#      created and tests/adopted_grant_node.py pick chooses R and the four nodes so that R's
#      ledger page is mastered by B under every node and by A once D has left (master = the
#      sorted node ids [page % N], dlm/dlm.c dlm_page_master_locked).
#   1. A opens R and keeps the descriptor (the open's shared lock is taken now, so A's later write
#      asks for EX alone).  C writes R with dbg_iolock_hold_ino=R: C holds EX, granted by B, for
#      HOLD_C_MS.  The platter must show R's page ACTIVE under B, or the routing was predicted
#      wrong and the lap ABORTs.
#   2. A writes R with dl_acq_gap_ino=R: its first attempt queues at B behind C, times out after
#      MXFS_LOCK_ACQUIRE_WAIT_MS (1 s, include/mxfs/mxfs_dlm.h), and A is held GAP_MS with no
#      pending entry (P958-ACQ-GAP).  C's hold outlasts that first attempt.  So A's write takes
#      about 1 s + GAP_MS + HOLD_A_MS (29.4-29.8 s at the defaults, 20000 and 8000, in
#      verification b20261024-0bf8bc): lengthening either knob crosses the 30 s stall limit.
#   3. C's hold ends and C releases: B promotes A, and the grant lands in A's gap
#      (P958-ACQ-GRANT-ADOPTED ino=R on A).  A's own one-shot iolock hold is armed now.
#   4. D unmounts cleanly while A is still in its gap: R's page moves from B to A
#      (P-TAUTH-PAGE-MINE page=<R's page> via=frozen-msg on A; ACTIVE under A on the platter).
#   5. A's next attempt is mastered on A and answered by the already-granted shortcut
#      (P958-ACQ-LOCAL-ANSWER-END ino=R site=shortcut); A's write then holds EX for HOLD_A_MS
#      (P-IOLOCK-HOLD on A).
#   6. B writes R while A holds it.  A's master must queue B behind A's EX.  With the fix the
#      wait took the adopted grant and A's table records A's EX; with dl_shortcut_claim=0 the
#      grant was handed back and its entry unlinked, so A's master grants B over A's EX and A's
#      ledger refuses that grant (P-TAUTH-DOUBLE-GRANT ... vs record ex=A).
#   7. A's hold ends and its write returns; B's write returns; A and B read the same R.
# EXPOSED  steps 3, 4 and 5 are all in A's kernel log for R and R's page.
# PASS     no P-TAUTH-DOUBLE-GRANT, P130-FALSE-FRESH, shutdown, BUG or Oops on any node; A's and
#          B's writes returned 0 and B's inside its bound; A and B read the same bytes.
# ARM=0 sets dl_shortcut_claim=0 on every node: the shortcut ends the wait unclaimed, as before
# the fix (the same-build control).  ARM=1 (default) leaves the fix on.
#
# Bounds.  Each step is bounded by what it should take: prep_cluster at 8/net/mesh/mpath measured
# 64 s (lane g8_nlink_repro_20261023T102802Z step 3), bound 130 s; every ssh read 10-30 s; the
# wait for the adoption the first attempt's 6 s plus the rest of C's hold, HOLD_C_MS + 10 s; D's
# unmount 25 s and the hand-off 15 s; the shortcut's answer the rest of A's gap, GAP_MS + 10 s;
# B's write A's hold plus a retry, HOLD_A_MS + 25 s.  The caller bounds a whole lap at twice
# what the precheck measures.
#
# Usage: tests/adopted_grant_rig_lap.sh <label> <configuration>
#        (the group's env exported: MXFS_GROUP, MXFS_MARKER, MXFS_NODE_LIST of at least 4 nodes)
# Env:   ARM (1), HOLD_C_MS (10000), GAP_MS (10000), HOLD_A_MS (8000), NCAND (128)
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS (the sequence was not reached).
set -u
LABEL=${1:?label}
CONFIG=${2:?configuration}
cd "$(dirname "$0")/.." || exit 2
HERE=$(pwd)
NREPO=/src/$(basename "$HERE")
NODES=${MXFS_NODE_LIST:?MXFS_NODE_LIST}
ARM=${ARM:-1}
HOLD_C_MS=${HOLD_C_MS:-10000}
GAP_MS=${GAP_MS:-10000}
HOLD_A_MS=${HOLD_A_MS:-8000}
NCAND=${NCAND:-128}
MNT=/mnt/shared
PARM=/sys/module/mxfs/parameters
HELPER="python3 $NREPO/tests/adopted_grant_node.py"
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_adoptgrant_$LABEL
mkdir -p "$OUT"
fails=0
. tests/lib/rig.sh
MARK="ADOPTGRANT-MARK-$LABEL-$$"
GO=/run/adoptgrant_go_$LABEL
s0=$(date +%s)
el() { echo $(( $(date +%s) - s0 )); }
field() { grep -aoE "(^| )$2=[^ ]*" "$1" | head -1 | cut -d= -f2; }
abort() { echo "  $*"; echo "RESULT: ABORT label=$LABEL stage=$STAGE wall=$(el)s evidence=$OUT"; disarm; exit 2; }
# every knob this lap arms, back to its default on every node (a later prep reloads them anyway)
disarm() {
    local n
    for n in ${NODES//,/ }; do
        rs 15 "$n" "echo 0 > $PARM/dl_acq_gap_ino; echo 0 > $PARM/dbg_iolock_hold_ino; echo 1 > $PARM/dl_shortcut_claim; rm -f $GO" > /dev/null 2>&1
    done
}
# poll <node> <seconds> <pattern>: wait until the node's kernel log since the mark has the pattern;
# prints the first matching line (empty when the wait ran out)
poll() {
    local n=$1 end=$(( $(date +%s) + $2 )) pat=$3 line
    while [ "$(date +%s)" -lt "$end" ]; do
        line=$(rs 10 "$n" "dmesg | sed -n '/$MARK/,\$p' | grep -a -m1 -E '$pat'")
        [ -n "$line" ] && { echo "$line"; return 0; }
        sleep 1
    done
    return 1
}
# wait_line <node> <seconds> <file on the node> <pattern>: until the node's file has the line
wait_line() {
    local end=$(( $(date +%s) + $2 ))
    while [ "$(date +%s)" -lt "$end" ]; do
        rs 10 "$1" "cat $3 2>/dev/null" | grep -aq "$4" && return 0
        sleep 1
    done
    return 1
}
echo "=== adopted_grant_rig_lap label=$LABEL config=$CONFIG nodes=$NODES arm=$ARM hold_c_ms=$HOLD_C_MS gap_ms=$GAP_MS hold_a_ms=$HOLD_A_MS ncand=$NCAND tree=$HERE $(date -u +%FT%TZ) ==="

# ---- 0. prep, node ids, candidates, the pick
STAGE=prep
MXFS_FORCE_PREP=1 timeout -k 5 130 ./run.sh "$CONFIG" ${MXFS_GROUP:+--group "$MXFS_GROUP"} prep_cluster < /dev/null > "$OUT/prep.log" 2>&1
prc=$?
echo "STAGE prep rc=$prc wall=$(el)s  $(grep -am1 'prep OK\|FAIL' "$OUT/prep.log" | cut -c1-140)"
[ $prc = 0 ] || abort "prep_cluster rc=$prc"
STAGE=ids
PAIRS=()
for n in ${NODES//,/ }; do
    measure "$n" 30 "$OUT/${n}_id.txt" '^ID node_id=[0-9]+ mounted=[0-9]+$' "$n's DLM node id" \
        "echo ID \$(dmesg | grep -a 'DLM init: node_id=' | tail -1 | grep -ao 'node_id=[0-9]*') mounted=\$(grep -c ' $MNT mxfs ' /proc/mounts)"
    id=$(field "$OUT/${n}_id.txt" node_id)
    [ "$(field "$OUT/${n}_id.txt" mounted)" = 1 ] || abort "$n is not mounted after the prep"
    PAIRS+=("$n=$id")
done
echo "  INFO node ids: ${PAIRS[*]}"
FIRST=${NODES%%,*}
DEV=$(rs 15 "$FIRST" "awk '\$2 == \"$MNT\" && \$3 == \"mxfs\" {print \$1}' /proc/mounts | head -1" | tr -d '\r\n')
[ -n "$DEV" ] || abort "no mxfs device on $FIRST"
STAGE=pick
D_DIR=$MNT/adoptgrant_$LABEL
measure "$FIRST" 30 "$OUT/create.txt" '^CREATED [0-9]+$' "the candidates on $FIRST" \
    "mkdir -p $D_DIR && for i in \$(seq 1 $NCAND); do printf '%4096s' x > $D_DIR/f\$i || exit 1; done; sync -f $MNT; echo CREATED \$(ls $D_DIR | wc -l)"
measure "$FIRST" 30 "$OUT/pick.txt" '^(PICK|NOPICK) ' "the pick on $FIRST" "$HELPER pick $DEV $D_DIR ${PAIRS[*]}"
grep -a '^GEOM\|^PICK\|^NOPICK' "$OUT/pick.txt" | sed 's/^/  /'
grep -aq '^PICK ' "$OUT/pick.txt" || abort "no candidate has the routing the sequence needs"
PL=$(grep -a '^PICK ' "$OUT/pick.txt")
R=$(echo "$PL" | grep -ao 'ino=[0-9]*' | cut -d= -f2)
PAGE=$(echo "$PL" | grep -ao 'page=[0-9]*' | cut -d= -f2)
F=$(echo "$PL" | grep -ao 'file=[^ ]*' | cut -d= -f2)
A=$(echo "$PL" | grep -ao ' A=[^ ]*' | cut -d= -f2); B=$(echo "$PL" | grep -ao ' B=[^ ]*' | cut -d= -f2)
C=$(echo "$PL" | grep -ao ' C=[^ ]*' | cut -d= -f2); D=$(echo "$PL" | grep -ao ' D=[^ ]*' | cut -d= -f2)
IDA=$(echo "$PL" | grep -ao 'ida=[0-9]*' | cut -d= -f2); IDB=$(echo "$PL" | grep -ao 'idb=[0-9]*' | cut -d= -f2)
echo "  INFO R=$R page=$PAGE file=$F A=$A B=$B C=$C D=$D"

STAGE=arm
for n in ${NODES//,/ }; do
    measure "$n" 15 "$OUT/${n}_arm.txt" '^ARMED claim=[0-9]+$' "the knobs on $n" \
        "echo $ARM > $PARM/dl_shortcut_claim; echo 0 > $PARM/dl_acq_gap_ino; echo 0 > $PARM/dbg_iolock_hold_ino; echo $R > $PARM/dbg_probe_ino; echo $MARK > /dev/kmsg; echo ARMED claim=\$(cat $PARM/dl_shortcut_claim)"
    ck "$n runs dl_shortcut_claim=$ARM" "$(field "$OUT/${n}_arm.txt" claim)" "$ARM"
done
[ $fails = 0 ] || abort "a knob did not read back"
rs 15 "$A" "echo 1 > $PARM/dl_local_acq_end" > /dev/null

# ---- 1. A opens R; C holds EX on it, granted by B
STAGE=step1
measure "$A" 15 "$OUT/A_open.txt" '^STARTED$' "A's writer started" \
    "rm -f $GO; nohup setsid $HELPER hold-write $F $GO A > /run/adoptgrant_a_$LABEL.out 2>&1 < /dev/null & echo STARTED"
wait_line "$A" 15 /run/adoptgrant_a_$LABEL.out '^OPENED' || abort "A did not open R in 15 s"
measure "$C" 15 "$OUT/C_start.txt" '^STARTED$' "C's held write started" \
    "echo $HOLD_C_MS > $PARM/dbg_iolock_hold_ms; echo $R > $PARM/dbg_iolock_hold_ino; nohup setsid sh -c 's=\$(date +%s%N); dd if=/dev/zero of=$F bs=4096 count=1 conv=notrunc status=none; rc=\$?; e=\$(date +%s%N); echo CDD rc=\$rc ms=\$(( (e-s)/1000000 ))' > /run/adoptgrant_c_$LABEL.out 2>&1 < /dev/null & echo STARTED"
CPARK=$(poll "$C" 15 "P-IOLOCK-HOLD ino=$R ") || abort "C never parked holding R (no P-IOLOCK-HOLD ino=$R)"
echo "  STEP1 C holds R: ${CPARK#*mxfs: }" | cut -c1-240
measure "$A" 15 "$OUT/page_b.txt" '^PAGEAUTH ' "R's page on the platter" "$HELPER page-auth $DEV $PAGE"
echo "  STEP1 $(cat "$OUT/page_b.txt")"
[ "$(field "$OUT/page_b.txt" state)" = ACTIVE ] && [ "$(field "$OUT/page_b.txt" node)" = "$IDB" ] \
    || abort "R's page is not ACTIVE under B ($IDB): the routing was predicted wrong"

# ---- 2. A writes R into the gap
STAGE=step2
rs 15 "$A" "echo $GAP_MS > $PARM/dl_acq_gap_ms; echo $R > $PARM/dl_acq_gap_ino; touch $GO" > /dev/null
tgo=$(date +%s)
echo "STAGE A's write started at +$(el)s"

# ---- 3. C releases; the grant lands in A's gap
STAGE=step3
ADOPT=$(poll "$A" $(( HOLD_C_MS / 1000 + 10 )) "P958-ACQ-GRANT-ADOPTED type=1 ino=$R ") && adopted=1 || adopted=0
[ $adopted = 1 ] && rs 15 "$A" "echo $HOLD_A_MS > $PARM/dbg_iolock_hold_ms; echo $R > $PARM/dbg_iolock_hold_ino" > /dev/null
GAPL=$(rs 10 "$A" "dmesg | sed -n '/$MARK/,\$p' | grep -a -m1 'P958-ACQ-GAP .* ino=$R '")
echo "  STEP2 ${GAPL#*mxfs: }" | cut -c1-240
echo "  STEP3 adopted=$adopted at +$(( $(date +%s) - tgo ))s after A's write: ${ADOPT#*mxfs: }" | cut -c1-260

# ---- 4. D leaves; R's page moves from B to A
STAGE=step4
handed=0
if [ $adopted = 1 ]; then
    measure "$D" 30 "$OUT/D_umount.txt" '^D_UMOUNT rc=[0-9]+ ms=[0-9]+$' "D's unmount" \
        "s=\$(date +%s%N); timeout 25 umount $MNT; rc=\$?; e=\$(date +%s%N); echo D_UMOUNT rc=\$rc ms=\$(( (e-s)/1000000 ))"
    echo "  STEP4 $(cat "$OUT/D_umount.txt") at +$(( $(date +%s) - tgo ))s"
    MINE=$(poll "$A" 15 "P-TAUTH-PAGE-MINE page=$PAGE via=frozen-msg") && handed=1
    measure "$A" 15 "$OUT/page_a.txt" '^PAGEAUTH ' "R's page on the platter after D left" "$HELPER page-auth $DEV $PAGE"
    echo "  STEP4 handed=$handed ${MINE#*mxfs: } | $(cat "$OUT/page_a.txt")" | cut -c1-260
    { [ "$(field "$OUT/page_a.txt" state)" = ACTIVE ] && [ "$(field "$OUT/page_a.txt" node)" = "$IDA" ]; } || handed=0
fi

# ---- 5. A's next attempt, answered by the shortcut; A then holds EX
STAGE=step5
local_ans=0
if [ $handed = 1 ]; then
    ANS=$(poll "$A" $(( GAP_MS / 1000 + 10 )) "P958-ACQ-LOCAL-ANSWER-END type=1 ino=$R .*site=shortcut") && local_ans=1
    AHOLD=$(poll "$A" 10 "P-IOLOCK-HOLD ino=$R ")
    echo "  STEP5 local=$local_ans at +$(( $(date +%s) - tgo ))s: ${ANS#*mxfs: }" | cut -c1-260
    echo "  STEP5 A holds: ${AHOLD#*mxfs: }" | cut -c1-200
fi
if [ $adopted = 1 ] && [ $handed = 1 ] && [ $local_ans = 1 ]; then
    echo "EXPOSED: A adopted B's grant of R between two attempts, R's page $PAGE moved to A, and the shortcut answered A's wait"
fi

# ---- 6. B writes R while A holds it
STAGE=step6
if [ $local_ans = 1 ]; then
    measure "$B" 15 "$OUT/B_start.txt" '^STARTED$' "B's write started" \
        "nohup setsid sh -c 's=\$(date +%s%N); timeout $(( HOLD_A_MS / 1000 + 25 )) dd if=/dev/zero of=$F bs=4096 count=1 conv=notrunc status=none; rc=\$?; e=\$(date +%s%N); echo BDD rc=\$rc ms=\$(( (e-s)/1000000 ))' > /run/adoptgrant_b_$LABEL.out 2>&1 < /dev/null & echo STARTED"
    wait_line "$B" $(( HOLD_A_MS / 1000 + 30 )) /run/adoptgrant_b_$LABEL.out '^BDD '
fi

# ---- 7. both writes, both reads, every node's kernel log
STAGE=collect
wait_line "$A" 30 /run/adoptgrant_a_$LABEL.out '^WROTE '
rs 10 "$A" "cat /run/adoptgrant_a_$LABEL.out" > "$OUT/A_write.txt"
rs 10 "$B" "cat /run/adoptgrant_b_$LABEL.out 2>/dev/null" > "$OUT/B_write.txt"
rs 10 "$C" "cat /run/adoptgrant_c_$LABEL.out" > "$OUT/C_write.txt"
echo "  WRITES A[$(grep -a '^WROTE' "$OUT/A_write.txt")] B[$(grep -a '^BDD' "$OUT/B_write.txt")] C[$(grep -a '^CDD' "$OUT/C_write.txt")]"
for n in "$A" "$B"; do
    rs 20 "$n" "md5sum $F | cut -d' ' -f1 | sed 's/^/DIGEST=/'" > "$OUT/${n}_digest.txt"
done
for n in ${NODES//,/ }; do
    measure "$n" 30 "$OUT/${n}_kmsg.txt" '^KMSG_END$' "$n's kernel log since the mark" \
        "dmesg | sed -n '/$MARK/,\$p' | cut -c1-600; echo KMSG_END"
done
DOUBLE=0; FRESH=0; SHUT=0; BUGS=0
for n in ${NODES//,/ }; do
    DOUBLE=$(( DOUBLE + $(cnt "$OUT/${n}_kmsg.txt" 'P-TAUTH-DOUBLE-GRANT') ))
    FRESH=$(( FRESH + $(cnt "$OUT/${n}_kmsg.txt" 'P130-FALSE-FRESH') ))
    SHUT=$(( SHUT + $(cnt "$OUT/${n}_kmsg.txt" 'xfs_do_force_shutdown\|Filesystem has been shut down\|Corruption of in-memory data') ))
    # a dynamic-debug line reads "DEBUG:", which a bare 'BUG:' also matches
    BUGS=$(( BUGS + $(cnt "$OUT/${n}_kmsg.txt" '^BUG:\|[^E]BUG:\|kernel BUG at\|Oops') ))
done
grep -a 'P958-ACQ-GRANT-CLAIMED-LOCAL\|P958-ACQ-GRANT-RELEASED\|P-TAUTH-DOUBLE-GRANT' "$OUT/${A}_kmsg.txt" \
    | grep -a "ino=$R " | sed 's/.*mxfs: /    /; s/.*tauth: /    /' | cut -c1-240 | head -6
disarm
if [ $adopted = 0 ] || [ $handed = 0 ] || [ $local_ans = 0 ]; then
    echo "  the sequence was not reached (adopted=$adopted handed=$handed local=$local_ans), so nothing here measures the shortcut"
    echo "RESULT: VACUOUS label=$LABEL stage=$STAGE wall=$(el)s evidence=$OUT"; exit 3
fi

# ---- the verdict
# a write that never returned inside its bound has no rc: graded as 'none', a FAIL, not an empty value
AMS=$(field "$OUT/A_write.txt" ms); BMS=$(grep -a '^BDD' "$OUT/B_write.txt" | grep -ao 'ms=[0-9]*' | cut -d= -f2)
ARC=$(field "$OUT/A_write.txt" rc); BRC=$(grep -a '^BDD' "$OUT/B_write.txt" | grep -ao 'rc=[0-9]*' | cut -d= -f2)
ADG=$(field "$OUT/${A}_digest.txt" DIGEST); BDG=$(field "$OUT/${B}_digest.txt" DIGEST)
echo "max_stall_ms=$(( ${AMS:-0} > ${BMS:-0} ? ${AMS:-0} : ${BMS:-0} ))"
ck "no ledger refused a conflicting grant (P-TAUTH-DOUBLE-GRANT)" "$DOUBLE" 0
ck "no false-fresh grant (P130-FALSE-FRESH)" "$FRESH" 0
ck "no node shut its filesystem down" "$SHUT" 0
ck "zero BUG / Oops" "$BUGS" 0
ck "A's write returned 0" "${ARC:-none}" 0
ck "B's write returned 0 inside its bound" "${BRC:-none}" 0
ck "A and B read the same R" "${ADG:-unread-on-A}" "${BDG:-unread-on-B}"
if [ $fails = 0 ]; then
    echo "LAP adopted_grant PASS: the shortcut took A's adopted grant of R; B's write waited for A's EX (A ${AMS} ms, B ${BMS} ms)"
else
    echo "LAP adopted_grant FAIL: $fails check(s) failed (double_grants=$DOUBLE false_fresh=$FRESH shutdowns=$SHUT)"
fi
echo "RESULT: $( [ $fails = 0 ] && echo PASS || echo FAIL ) label=$LABEL fails=$fails wall=$(el)s evidence=$OUT"
[ $fails = 0 ]
