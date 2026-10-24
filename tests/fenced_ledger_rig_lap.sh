#!/bin/bash
# fenced_ledger_rig_lap.sh — does a node whose authority over the LUN has closed
# keep writing ledger pages its peers still ask it for, on a real target?
#
# WHY THIS EXISTS.  D-SELF-FENCED-NODE-LEDGER-PUBLISHER-RETRIES-FOREVER-ON-RESERVATION-CONFLICT:
# test21 on 8/net/mesh/mpath, its filesystem shut down and its PR key gone, kept
# its mount and its peers kept routing to it; each request on a page it held
# activated the page, the target refused the write (P-TAUTH-PUBLISH-FAIL rc=-52,
# one 'Reservation conflict' on the host each), and the page's FREEZE_REQ /
# FROZEN hand-offs activated it again: 31,510 refused publishes in five minutes,
# until the node was powered off.  The fix parks a page request and answers no
# hand-off on a node whose authority is closed (dl_auth_closed_park, dlm/dlm.c
# dlm_page_ensure_mine and the hand-off handler).  Its in-process harness
# (tests/tauth/fenced_node_ledger_test.sh) has a store that never refuses a
# write, so it never met the refused-write loop; this lap runs the module on the
# rig against the target.
#
# SHAPE (V = first node, P = last node of MXFS_NODE_LIST):
#   1. prep the pair; both run tests/mpath/pathload.py in the mount for WARM_S,
#      so V holds ledger pages P's operations need.
#   2. V's dl_auth_closed_park is set to PARK at run time (1, the fix; 0, as
#      before: the control) and P-TAUTH-PAGE-AUTH-CLOSED's debug line is
#      enabled on V.
#   3. the injection closes V's authority while P still names it:
#        preempt  P removes V's key out of band (plain PREEMPT, as a false-death
#                 fence does; tests/fence_live_node.sh's preempt mode)
#        hbpause  V's heartbeat pauses HB_PAUSE_MS (dl_inject_hb_pause_ms) while
#                 its data path runs: P expires it and fences it with its own
#                 PREEMPT AND ABORT, and V finds its key gone
#   4. P's load runs on OBS_S, then both loads stop.
#   EXPOSED  V logged P290-AUTH-CLOSED and, after it, a peer's page request or
#            hand-off reached V's ledger (P-TAUTH-PUBLISH-FAIL,
#            P-TAUTH-FROZEN-NOT-CONSUMED, P-TAUTH-PAGE-AUTH-CLOSED or
#            P-TAUTH-HANDOFF-AUTH-CLOSED).
#   PASS     V refused no ledger publish later than GRACE_S after its closure
#            (no P-TAUTH-PUBLISH-FAIL), the target logged no 'Reservation
#            conflict' from V's initiator from TP + LATE_S to the window's end,
#            P's load had no operation over the 30 s stall limit
#            (data/release_policy.json), and neither node logged BUG or Oops.
#
# GRADE=reason grades why V shut down instead
# (D-FENCED-NODE-INODE-LOCK-EIO-SHUTS-DOWN-AS-IN-CORE-CORRUPTION): the target's
# refusal of V's ledger writes came up to the inode lock as -EIO and V shut down
# as in-core corruption.  FENCED_ERRNO, when set, is written to V's
# dl_failstop_fenced_errno with the park switch (1, the fix: the refused grants
# answer -ESHUTDOWN; 0, as before: the control); unset, the module's default.
#   EXPOSED  V shut down (a 'Corruption of in-memory data' line, or 'Fenced by
#            the cluster' / P131-SELF-FENCE) after its ledger fail-stopped on a
#            refused write (P-TAUTH-FAILSTOP).
#   PASS     no 'Corruption of in-memory data' line on V, and no BUG or Oops.
#   VACUOUS  V's ledger never fail-stopped, so no refused grant reached a lock.
#
# GRADE=survivors grades what the survivors' operations do once V's recovery
# is declared RECOVERY_BLOCKED
# (D-8NETMESH-RECOVERY-BLOCKED-LEAVES-QUEUED-SURVIVOR-ACQUIRES-PARKED-FOREVER).
# At 3 nodes or more an out-of-band preempt leaves the prover unable to prove
# exclusion (the key absent, no ledger entry naming a successor, the prover not
# the sole member), and after its bounded series the recovery is BLOCKED; a wait
# queued at a master behind an older conflicting waiter that was then removed
# was kept on every re-send and never granted.  RESEND_REDECIDE and
# RBLK_DENY_RESEND, when set, are written to every node's dl_resend_redecide and
# dl_rblk_deny_resend before the injection (1, the fix; 0, as before: the
# control of each part); unset, the module's defaults.
#   EXPOSED  the verdict reached P (P238-FENCE-BLOCKED or -IMPORTED in its
#            followed log) within VERDICT_S of the injection.
#   PASS     every survivor's load stopped and reported within the stop window,
#            and no survivor operation that started after the verdict reached P
#            took over the 30 s stall limit, with an error or without; no BUG or
#            Oops.  (The stall from the death to the verdict, the fence's
#            bounded series, is printed, not graded here.)
#   VACUOUS  no verdict within VERDICT_S.
#
# Bounds (derived): prep on a pair measured 53-104 s, bound 120; the load start
# 30 a node; WARM_S 10; the injection 30 (ssh) or the pause's arm 12; OBS_S 40
# (hbpause: the 12 s death window, the fence and replay, measured under 25 s on a
# pair, then 15 s of P's load on); the loads' stop 60; reads 30 each.  Caller
# bound 2 x the precheck's wall.
#
# Usage: fenced_ledger_rig_lap.sh <label>
# Env:   MXFS_NODE_LIST (test17,test18), MXFS_CONFIG (2/net/mesh/direct), MXFS_GROUP,
#        INJECT (preempt|hbpause, preempt), PARK (1), WARM_S (10), OBS_S (40),
#        HB_PAUSE_MS (45000), GRACE_S (5), LATE_S (15), GRADE (ledger|reason|
#        survivors, ledger), FENCED_ERRNO (unset), RESEND_REDECIDE (unset),
#        RBLK_DENY_RESEND (unset), VERDICT_S (200)
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}
cd "$(dirname "$0")" || exit 2
# the tree root holds run.sh and tests/lib/rig.sh both: a draft of this lap run from a copy of
# tests/ alone finds the tree's own tools
while { [ ! -f run.sh ] || [ ! -f tests/lib/rig.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done
[ -f run.sh ] || { echo "ABORT: no tree root above $0"; exit 2; }
NREPO=/src/$(basename "$(pwd)")
export MXFS_NODE_LIST=${MXFS_NODE_LIST:-test17,test18}
export MXFS_CONFIG=${MXFS_CONFIG:-2/net/mesh/direct}
V=${MXFS_NODE_LIST%%,*}
P=${MXFS_NODE_LIST##*,}
# every node runs the load and has its log followed; V is fenced, P preempts it, and the others
# (at 3 nodes or more) are survivors that did not do the fencing
IFS=, read -r -a NODES <<< "$MXFS_NODE_LIST"
SURV=("${NODES[@]:1}")
MNT=/mnt/shared
PARM=/sys/module/mxfs/parameters
INJECT=${INJECT:-preempt}
PARK=${PARK:-1}
WARM_S=${WARM_S:-10}
OBS_S=${OBS_S:-40}
HB_PAUSE_MS=${HB_PAUSE_MS:-45000}
GRACE_S=${GRACE_S:-5}
LATE_S=${LATE_S:-15}
GRADE=${GRADE:-ledger}
FENCED_ERRNO=${FENCED_ERRNO:-}
RESEND_REDECIDE=${RESEND_REDECIDE:-}
RBLK_DENY_RESEND=${RBLK_DENY_RESEND:-}
VERDICT_S=${VERDICT_S:-200}
case $INJECT in preempt|hbpause) ;; *) echo "INJECT must be preempt or hbpause"; exit 2;; esac
case $GRADE in ledger|reason|survivors) ;; *) echo "GRADE must be ledger, reason or survivors"; exit 2;; esac
for v in "$FENCED_ERRNO" "$RESEND_REDECIDE" "$RBLK_DENY_RESEND"; do
    case $v in ''|0|1) ;; *) echo "FENCED_ERRNO, RESEND_REDECIDE and RBLK_DENY_RESEND must be 0 or 1"; exit 2;; esac
done
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_fledger_$LABEL
mkdir -p "$OUT"
fails=0
. tests/lib/rig.sh
MARK="FLEDGER-MARK-$LABEL-$$"
LD=/run/fledger_$LABEL
KL=/root/fledger.$LABEL.$$.kmsg
echo "=== fenced_ledger_rig_lap label=$LABEL config=$MXFS_CONFIG V=$V P=$P inject=$INJECT park=$PARK grade=$GRADE fenced_errno=${FENCED_ERRNO:-default} resend_redecide=${RESEND_REDECIDE:-default} rblk_deny_resend=${RBLK_DENY_RESEND:-default} obs_s=$OBS_S $(date -u +%FT%TZ) ==="
s0=$(date +%s)
el() { echo $(( $(date +%s) - s0 )); }
field(){ grep -aoE "(^| )$2=[^ ]*" "$1" | head -1 | cut -d= -f2; }
# a count in a kernel-log file from the first line matching $2 onward
cnt_after() { awk -v a="$2" -v p="$3" 'index($0, a) { f = 1 } f && $0 ~ p { n++ } END { print n + 0 }' "$1"; }

GROUPARG=()
[ -n "${MXFS_GROUP:-}" ] && GROUPARG=(--group "$MXFS_GROUP")
MXFS_FORCE_PREP=1 timeout 120 ./run.sh "$MXFS_CONFIG" "${GROUPARG[@]}" prep_cluster > "$OUT/prep.log" 2>&1
prc=$?
echo "STAGE prep rc=$prc wall=$(el)s"
[ $prc = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=prep wall=$(el)s evidence=$OUT"; exit 2; }
mxfs_dev_resolve "$P"; DEV=$MXFS_DEV_RESOLVED

stop_all() {
    for n in "${NODES[@]}"; do
        rs 15 "$n" "touch $LD.stop; kill \$(cat $KL.pid 2>/dev/null) 2>/dev/null; rm -f $KL.pid; echo 1 > $PARM/dl_auth_closed_park 2>/dev/null; echo 0 > $PARM/dl_inject_hb_pause_ms 2>/dev/null" > /dev/null 2>&1
    done
}
trap stop_all EXIT

# ---- 1. keys, from the target's own registrant list: which key each initiator holds
measure "$P" 30 "$OUT/full_status_before.txt" '^PRIN_END$' "the registrants before the injection" \
    "sg_persist --in --read-full-status $DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo PRIN_END"
keyof() { awk -v n="$1-mxfs-node" '/Key=/ { k = $0; sub(/.*Key=/, "", k); sub(/[^0-9a-fx].*/, "", k) } index($0, n) && k != "" { print k; exit }' "$OUT/full_status_before.txt"; }
VKEY=$(keyof "$V"); PKEY=$(keyof "$P")
echo "STAGE keys V=$V key=${VKEY:-?} P=$P key=${PKEY:-?}"
[ -n "$VKEY" ] && [ -n "$PKEY" ] || { echo "ABORT: the target lists no key for $V or $P"; echo "RESULT: ABORT label=$LABEL stage=keys wall=$(el)s evidence=$OUT"; exit 2; }

# each node's /dev/kmsg followed into /root from before the mark (raw records: the grace check
# below reads their microsecond stamps); the network lock manager's debug lines rotate a mark out
# of the ring within a run, so the ring read afterwards would hold nothing
for n in "${NODES[@]}"; do
    measure "$n" 30 "$OUT/${n}_follow.txt" '^FOLLOW=[0-9]+$' "$n's kernel-log follower" \
        "rm -f $KL $KL.pid; nohup setsid sh -c 'echo \$\$ > $KL.pid; exec cat /dev/kmsg > $KL' > /dev/null 2>&1 < /dev/null & sleep 1; echo $MARK > /dev/kmsg; sleep 1; echo FOLLOW=\$(grep -ac '$MARK\$' $KL)"
    ck "$n's follower holds the mark" "$(field "$OUT/${n}_follow.txt" FOLLOW)" 1
done
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=follow wall=$(el)s evidence=$OUT"; exit 2; }

# ---- 2. the load on both nodes
for n in "${NODES[@]}"; do
    measure "$n" 30 "$OUT/${n}_load_start.txt" '^LOAD_STARTED$' "$n's load started" \
        "rm -rf $LD; mkdir -p $LD; rm -f $LD.stop; nohup setsid python3 $NREPO/tests/mpath/pathload.py run $n $MNT $LD $LD.stop > $LD.out 2>&1 < /dev/null & echo LOAD_STARTED"
done
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=load wall=$(el)s evidence=$OUT"; exit 2; }
sleep "$WARM_S"

# ---- 3. the park switch on V, then the injection
measure "$V" 20 "$OUT/V_park.txt" '^PARK=[0-9]+$' "V's park switch" \
    "echo $PARK > $PARM/dl_auth_closed_park; echo 'format \"P-TAUTH-PAGE-AUTH-CLOSED\" +p' > /sys/kernel/debug/dynamic_debug/control 2>/dev/null; echo PARK=\$(cat $PARM/dl_auth_closed_park)"
ck "V's dl_auth_closed_park reads back" "$(field "$OUT/V_park.txt" PARK)" "$PARK"
if [ -n "$FENCED_ERRNO" ]; then
    measure "$V" 20 "$OUT/V_errno.txt" '^FERRNO=' "V's fail-stop errno switch" \
        "echo $FENCED_ERRNO > $PARM/dl_failstop_fenced_errno; echo FERRNO=\$(cat $PARM/dl_failstop_fenced_errno 2>/dev/null || echo absent)"
    ck "V's dl_failstop_fenced_errno reads back" "$(field "$OUT/V_errno.txt" FERRNO)" "$FENCED_ERRNO"
fi
for pair in "dl_resend_redecide=$RESEND_REDECIDE" "dl_rblk_deny_resend=$RBLK_DENY_RESEND"; do
    pn=${pair%%=*}; pv=${pair#*=}
    [ -n "$pv" ] || continue
    for n in "${NODES[@]}"; do
        measure "$n" 20 "$OUT/${n}_$pn.txt" '^PARAM=' "$n's $pn" \
            "echo $pv > $PARM/$pn; echo PARAM=\$(cat $PARM/$pn 2>/dev/null || echo absent)"
        ck "$n's $pn reads back" "$(field "$OUT/${n}_$pn.txt" PARAM)" "$pv"
    done
done
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=park wall=$(el)s evidence=$OUT"; exit 2; }
TP=$(date -u +%FT%T.%3NZ); tp=$(date +%s)
if [ "$INJECT" = preempt ]; then
    # --prout-type is mandatory (SCST answers ILLEGAL REQUEST without it); 7 = WE-AR, the type
    # MXFS reserves with
    measure "$P" 30 "$OUT/inject.txt" '^INJECT_RC=[0-9]+$' "P's preempt of V's key" \
        "sg_persist --out --preempt --prout-type=7 --param-rk=$PKEY --param-sark=$VKEY $DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo INJECT_RC=\${PIPESTATUS[0]}"
else
    measure "$V" 30 "$OUT/inject.txt" '^INJECT_RC=[0-9]+$' "V's heartbeat pause" \
        "echo $HB_PAUSE_MS > $PARM/dl_inject_hb_pause_ms || { echo INJECT_RC=1; exit 0; }; for i in 1 2 3 4 5 6; do sleep 2; grep -aq P-HB-INJECT-PAUSE $KL && break; done; grep -a P-HB-INJECT-PAUSE $KL | tail -1 | cut -c1-200; grep -aq P-HB-INJECT-PAUSE $KL && echo INJECT_RC=0 || echo INJECT_RC=2"
fi
echo "STAGE inject $INJECT at $TP rc=$(field "$OUT/inject.txt" INJECT_RC)"
ck "the injection took" "$(field "$OUT/inject.txt" INJECT_RC)" 0
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=inject wall=$(el)s evidence=$OUT"; exit 2; }

# ---- 3b. survivors: the RECOVERY_BLOCKED verdict, as P's followed log shows it (its own
# declaration if P is the prover, the import otherwise); its time on P's clock in ms
TVMS=0
if [ "$GRADE" = survivors ]; then
    measure "$P" $(( VERDICT_S + 20 )) "$OUT/verdict.txt" '^VERDICT=' "the RECOVERY_BLOCKED verdict on P" \
        "for i in \$(seq 1 $(( VERDICT_S / 2 ))); do grep -aq 'P238-FENCE-BLOCKED' $KL && break; sleep 2; done; grep -a 'P238-FENCE-BLOCKED' $KL | head -1 | cut -c1-220; grep -aq 'P238-FENCE-BLOCKED' $KL && echo VERDICT=\$(date +%s%3N) || echo VERDICT=none"
    TVMS=$(field "$OUT/verdict.txt" VERDICT)
    echo "STAGE verdict on P: ${TVMS:-none} at +$(el)s"
    case $TVMS in ''|none) TVMS=0 ;; esac
fi

# ---- 4. P's load runs on, then both stop
sleep "$OBS_S"
TE=$(date -u +%FT%T.%3NZ)
for n in "${NODES[@]}"; do
    measure "$n" 60 "$OUT/${n}_load.txt" '^LOADREC_END$' "$n's load record" \
        "touch $LD.stop; for t in \$(seq 1 45); do grep -q '^PATHLOAD ' $LD.out 2>/dev/null && break; sleep 1; done; grep '^PATHLOAD ' $LD.out; awk '{ d=\$2-\$1; if (d>m) m=d } END { print \"MAXOP_MS=\" m+0 }' $LD/ops.log; awk -v tv=$TVMS 'tv > 0 && \$2 >= tv { s = \$1 < tv ? tv : \$1; d = \$2 - s; if (d > m) m = d } END { print \"MAXOP_AFTER_MS=\" m+0 }' $LD/ops.log; grep -c ' ERR ' $LD/ops.log | sed 's/^/ERRS=/'; echo LOADREC_END"
done
measure "$P" 30 "$OUT/full_status_after.txt" '^PRIN_END$' "the registrants after the window" \
    "sg_persist --in --read-full-status $DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo PRIN_END"
for n in "${NODES[@]}"; do
    measure "$n" 30 "$OUT/${n}_kmsg.txt" '^KMSG_END$' "$n's kernel log since the mark" \
        "echo '$MARK-END' > /dev/kmsg; sleep 1; kill \$(cat $KL.pid) 2>/dev/null; awk '/$MARK\$/{f=1} f' $KL | cut -c1-700; echo KMSG_END"
    grep -aq "$MARK\$" "$OUT/${n}_kmsg.txt" && grep -aq "$MARK-END\$" "$OUT/${n}_kmsg.txt" \
        || { echo "LAP fenced_ledger FAIL: $n's kernel log read does not hold both of the lap's marks"; echo "RESULT: FAIL label=$LABEL stage=kmsg wall=$(el)s evidence=$OUT"; exit 1; }
done
# the target's refusals of V's commands, from the host's own kernel log
journalctl -k -o short-iso-precise --since "$TP" --until "$TE" 2>/dev/null \
    | grep -a "Reservation conflict.*${V}-mxfs-node" > "$OUT/host_conflicts_V.txt"
TL=$(date -u -d "@$(( tp + LATE_S ))" +%FT%TZ)
CONF_ALL=$(grep -ac . "$OUT/host_conflicts_V.txt")
CONF_LATE=$(journalctl -k --since "$TL" --until "$TE" 2>/dev/null | grep -ac "Reservation conflict.*${V}-mxfs-node")
MAX_MS=$(for n in "${SURV[@]}"; do field "$OUT/${n}_load.txt" MAXOP_MS; done | sort -n | tail -1)
echo "max_stall_ms=${MAX_MS:-0}"

# ---- 4b. why V shut down.  A node fenced off the LUN is shut down as fenced; one that shut
# down as in-core corruption had its refused ledger writes come up as EIO
# (D-FENCED-NODE-INODE-LOCK-EIO-SHUTS-DOWN-AS-IN-CORE-CORRUPTION).  Judged before any VACUOUS
# exit: it needs only V's fence.
CORRUPT=$(cnt "$OUT/${V}_kmsg.txt" 'Corruption of in-memory data')
FENCEDSD=$(cnt "$OUT/${V}_kmsg.txt" 'Fenced by the cluster\|P131-SELF-FENCE')
echo "SHUTDOWN-REASON: V corrupt_incore=$CORRUPT fenced=$FENCEDSD"
if [ "$CORRUPT" -gt 0 ]; then
    echo "REASON FAIL: $V was fenced and shut down as in-core corruption ($CORRUPT line(s))"
elif [ "$FENCEDSD" -gt 0 ]; then
    echo "REASON PASS: $V was fenced and shut down as fenced"
else
    echo "REASON VACUOUS: $V logged no shutdown"
fi
if [ "$GRADE" = reason ]; then
    FSTOP=$(cnt "$OUT/${V}_kmsg.txt" 'P-TAUTH-FAILSTOP')
    grep -a 'P-TAUTH-FAILSTOP\|DLM inode lock unrecoverable\|Corruption of in-memory data\|Fenced by the cluster' "$OUT/${V}_kmsg.txt" | sed 's/.*mxfs: /    /' | cut -c1-240 | head -6
    for n in "${NODES[@]}"; do
        ck "$n: zero BUG / Oops" "$(cnt "$OUT/${n}_kmsg.txt" '^BUG:\|[^E]BUG:\|kernel BUG at\|Oops')" 0
    done
    if [ "$CORRUPT" -gt 0 ]; then
        echo "EXPOSED: V's ledger fail-stopped ($FSTOP line(s)) and V shut down"
        echo "LAP fenced_ledger_reason FAIL: $V was fenced and shut down as in-core corruption"
        echo "RESULT: FAIL label=$LABEL fails=$((fails+1)) wall=$(el)s evidence=$OUT"; exit 1
    fi
    if [ "$FSTOP" = 0 ] || [ "$FENCEDSD" = 0 ]; then
        echo "  V's ledger fail-stopped $FSTOP time(s) and V logged $FENCEDSD fenced shutdown line(s): no refused grant was graded"
        echo "RESULT: VACUOUS label=$LABEL stage=no-failstop wall=$(el)s evidence=$OUT"; exit 3
    fi
    echo "EXPOSED: V's ledger fail-stopped ($FSTOP line(s)) and V shut down"
    if [ $fails = 0 ]; then
        echo "LAP fenced_ledger_reason PASS: $V was fenced and shut down as fenced, not as in-core corruption"
    else
        echo "LAP fenced_ledger_reason FAIL: $fails check(s) failed"
    fi
    echo "RESULT: $( [ $fails = 0 ] && echo PASS || echo FAIL ) label=$LABEL fails=$fails wall=$(el)s evidence=$OUT"
    [ $fails = 0 ]; exit
fi
if [ "$GRADE" = survivors ]; then
    grep -a 'P238-FENCE-BLOCKED\|P240-QUAR-PARK\|P240-RBLK-EIO-ABORT\|P958-ACQ-RETX-REDECIDE' "$OUT/${P}_kmsg.txt" | sed 's/.*mxfs: /    /' | cut -c1-220 | head -6
    for n in "${NODES[@]}"; do
        ck "$n: zero BUG / Oops" "$(cnt "$OUT/${n}_kmsg.txt" '^BUG:\|[^E]BUG:\|kernel BUG at\|Oops')" 0
    done
    if [ "$TVMS" = 0 ]; then
        echo "  no RECOVERY_BLOCKED verdict reached $P within ${VERDICT_S}s of the injection"
        echo "RESULT: VACUOUS label=$LABEL stage=no-verdict wall=$(el)s evidence=$OUT"; exit 3
    fi
    echo "EXPOSED: V's recovery was declared RECOVERY_BLOCKED and the verdict reached $P"
    for n in "${SURV[@]}"; do
        ck "$n's load stopped and reported" "$(cnt "$OUT/${n}_load.txt" '^PATHLOAD ')" 1
        after=$(field "$OUT/${n}_load.txt" MAXOP_AFTER_MS)
        echo "  INFO $n: longest operation ${after:-?} ms after the verdict, $(field "$OUT/${n}_load.txt" MAXOP_MS) ms in all (the fence's series included), errors $(field "$OUT/${n}_load.txt" ERRS)"
        if [ -n "$after" ] && [ "$after" -le 30000 ]; then echo "  PASS $n: no operation took over 30 s after the verdict"
        else echo "  FAIL $n: an operation took ${after:-?} ms after the verdict, over the 30 s stall limit"; fails=$((fails+1)); fi
    done
    if [ $fails = 0 ]; then
        echo "LAP fenced_ledger_survivors PASS: after RECOVERY_BLOCKED every survivor's operations ended within 30 s, with an error or without"
    else
        echo "LAP fenced_ledger_survivors FAIL: $fails check(s) failed"
    fi
    echo "RESULT: $( [ $fails = 0 ] && echo PASS || echo FAIL ) label=$LABEL fails=$fails wall=$(el)s evidence=$OUT"
    [ $fails = 0 ]; exit
fi

# ---- 5. what reached V after its authority closed
VK=$OUT/${V}_kmsg.txt
CLOSED=$(cnt "$VK" 'P290-AUTH-CLOSED')
PUB=$(cnt_after "$VK" 'P290-AUTH-CLOSED' 'P-TAUTH-PUBLISH-FAIL')
FROZ=$(cnt_after "$VK" 'P290-AUTH-CLOSED' 'P-TAUTH-FROZEN-NOT-CONSUMED')
PAGEP=$(cnt_after "$VK" 'P290-AUTH-CLOSED' 'P-TAUTH-PAGE-AUTH-CLOSED')
HANDP=$(cnt_after "$VK" 'P290-AUTH-CLOSED' 'P-TAUTH-HANDOFF-AUTH-CLOSED')
echo "STAGE V: auth_closed=$CLOSED after it: publish_fail=$PUB frozen_not_consumed=$FROZ page_parked=$PAGEP handoff_refused=$HANDP; target conflicts from V: $CONF_ALL in the window, $CONF_LATE after +${LATE_S}s"
grep -a 'P290-AUTH-CLOSED\|P277-FENCED-SELF-WITHDRAW\|P131-SELF-FENCE\|Shutting down\|P-HB-INJECT-PAUSE' "$VK" | sed 's/.*mxfs: /    /' | cut -c1-240 | head -8
if [ "$CLOSED" = 0 ]; then
    echo "  V's authority never closed, so nothing here measures what reaches a closed node"
    echo "RESULT: VACUOUS label=$LABEL stage=no-close wall=$(el)s evidence=$OUT"; exit 3
fi
REACHED=$(( PUB + FROZ + PAGEP + HANDP ))
if [ "$REACHED" = 0 ]; then
    echo "  no page request or hand-off reached V's ledger after its authority closed"
    echo "RESULT: VACUOUS label=$LABEL stage=no-request wall=$(el)s evidence=$OUT"; exit 3
fi
echo "EXPOSED: V's authority closed and $REACHED page request(s) or hand-off(s) reached its ledger after it"

# ---- 6. the verdict
# a publish already in flight at the closure is refused once; one GRACE_S or more after it is
# the loop
CLOSE_T=$(awk '/P290-AUTH-CLOSED/ { split($1, a, ","); print a[3]; exit }' "$VK")
PUB_LATE=$(awk -v c="$CLOSE_T" -v g="$GRACE_S" '/P-TAUTH-PUBLISH-FAIL/ { split($1, a, ","); if (c != "" && a[3] - c > g * 1000000) n++ } END { print n + 0 }' "$VK")
ck "V refused no ledger publish ${GRACE_S}s or more after its closure" "$PUB_LATE" 0
ck "the target refused no command of V's from +${LATE_S}s to the window's end" "$CONF_LATE" 0
for n in "${SURV[@]}"; do ck "$n's load reported" "$(cnt "$OUT/${n}_load.txt" '^PATHLOAD ')" 1; done
if [ "${MAX_MS:-0}" -le 30000 ] 2>/dev/null; then echo "  PASS the survivors' longest operation ${MAX_MS} ms is within the 30 s stall limit"; else echo "  FAIL the survivors' longest operation ${MAX_MS:-?} ms is over the 30 s stall limit"; fails=$((fails+1)); fi
for n in "${NODES[@]}"; do
    # a dynamic-debug line reads "DEBUG:", which a bare 'BUG:' also matches
    ck "$n: zero BUG / Oops" "$(cnt "$OUT/${n}_kmsg.txt" '^BUG:\|[^E]BUG:\|kernel BUG at\|Oops')" 0
done

if [ $fails = 0 ]; then
    echo "LAP fenced_ledger PASS: V's authority closed under P's load and V wrote no ledger page after it; P's longest operation ${MAX_MS} ms"
else
    echo "LAP fenced_ledger FAIL: $fails check(s) failed (publish_fail_late=$PUB_LATE conflicts_late=$CONF_LATE max_op_ms=${MAX_MS:-0})"
fi
echo "RESULT: $( [ $fails = 0 ] && echo PASS || echo FAIL ) label=$LABEL fails=$fails wall=$(el)s evidence=$OUT"
[ $fails = 0 ]
