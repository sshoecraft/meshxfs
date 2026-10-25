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
#        shutdown V's filesystem is shut down under its load (XFS_IOC_GOINGDOWN,
#                 NOLOGFLUSH), so V declares a voluntary death (P-WITHDRAW, its
#                 heartbeat stopped, P163-WITHDRAW-STAMP) and a peer fences it on
#                 the stamp: the incident's order.  test21 shut down first (a
#                 metadata read failed in a transaction, 19:56:11), its key was
#                 gone 3 s later, and its 31,510 refused publishes began 5 s after
#                 that (tests/evidence/flood_test21_20261022T200054Z/
#                 test21_kernlog_boot.gz, decompressed lines 819048-819197); the
#                 preempt and pause arms withdraw V through P277 or the lease
#                 instead, and reached nothing at 2 or 8 nodes
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
# GRADE=certify grades whether the survivors prove V's exclusion at all after an
# out-of-band removal of its key (INJECT=preempt: a plain PREEMPT, no MXFS fence
# behind it) at 3 nodes or more
# (D-OUT-OF-BAND-KEY-REMOVAL-AT-3-PLUS-NODES-FENCE-SERIES-STALLS-SURVIVORS-126S):
# the prover found the key absent with no successor named and no sole-survivor
# gate, re-drove 22 times over 126 s into RECOVERY_BLOCKED, and survivor
# operations stalled the whole time.  The fix (module parameter pr_surrender,
# dlm/v5_mount.c v5_pr_surrender_tick): V, once nothing of it can write,
# registers its key again, so the prover's re-drive finds it and certifies with
# PREEMPT AND ABORT.  SURRENDER, when set, is written to V's pr_surrender before
# the injection (1, the fix; 0, as before: the control); unset, the module's
# default.  OBS_S must cover the death window, the fence and its re-drives.
#   EXPOSED  V found its own key gone (P277) and a survivor fenced V
#            (P236-FENCEKIND): the out-of-band removal reached a fence.  Whether
#            that fence met the key absent (P-PR-FENCE-ABSENT) is printed, not
#            graded: the fix registers the key again before the fence reads it,
#            so the fence meets it present, and an exposure that required the
#            absent read graded every lap of the fix VACUOUS (attempt 21, c21e1
#            and c21q1).
#   PASS     a survivor certified V's fence (P236-FENCE-CERTIFIED), none declared
#            the recovery blocked (P238-FENCE-BLOCKED), and no survivor
#            operation took over the 30 s stall limit; no BUG or Oops.
#   VACUOUS  V never found its key gone, or no survivor fenced V.
#
# Bounds (derived): prep on a pair measured 53-104 s, bound 120; the load start
# 30 a node; WARM_S 10; the injection 30 (ssh) or the pause's arm 12; OBS_S 40
# (hbpause: the 12 s death window, the fence and replay, measured under 25 s on a
# pair, then 15 s of P's load on); the loads' stop 60; reads 30 each; the
# release of every node at the end (below) 30 a node at once, and for a node that
# does not release its stacks 30 and a power cycle 112 (destroy, then
# lab_power's up, measured 45-56 s inside run.sh's teardown, doubled).  Caller
# bound 2 x the precheck's wall.
#
# EVERY NODE RELEASED AT THE END.  This lap's faults can leave a node whose mxfs
# will not let go: the self-fenced victim (P-BUFLOCK-STUCK on its superblock
# buffer, D-SELF-FENCED-VICTIM-HOLDS-SB-BUFFER-AND-ITS-MXFS-NEVER-RELEASES-AT-TEARDOWN)
# or survivors the recovery-blocked control arm parks.  Left to the next lap's
# prep, run.sh's teardown power-cycled them inside that prep's 120 s bound and
# the next lap ended INCOMPLETE
# (D-FLEDGER-LAP-PREP-BOUND-LEAVES-NO-ROOM-FOR-THE-PREVIOUS-LAPS-WEDGED-NODES).
# So every exit unmounts each node, and a node whose mount is still in
# /proc/mounts afterwards (or that does not answer) is reported EXPOSED-WEDGE and
# LEFT-WEDGED, its D-state tasks' stacks and its umount's stack are kept as
# <node>_wedged_stacks.txt, and it is power-cycled here.  FLEDGER_RELEASE_END=0
# makes the same release attempt and keeps the same stacks but leaves a node it
# could not free for the next prep, as before: the control.  FLEDGER_END_PREP=1
# (row lap:fledger_release) then runs the next lap's prep at the lap's end under
# the same 120 s bound and grades it: 'LAP fledger_release PASS|FAIL'; exposure
# is an EXPOSED-WEDGE line.  After a failed end prep, graded, the lap forms the
# cluster again under 300 s so the batch's next lap starts on a formed cluster.
# That adds 120 s to the bound, and 300 more after a failed end prep.
#
# Usage: fenced_ledger_rig_lap.sh <label>
# Env:   MXFS_NODE_LIST (test17,test18), MXFS_CONFIG (2/net/mesh/direct), MXFS_GROUP,
#        INJECT (preempt|hbpause|shutdown, preempt), PARK (1), WARM_S (10), OBS_S (40),
#        HB_PAUSE_MS (45000), GRACE_S (5), LATE_S (15), GRADE (ledger|reason|
#        survivors, ledger), FENCED_ERRNO (unset), RESEND_REDECIDE (unset),
#        RBLK_DENY_RESEND (unset), VERDICT_S (200), SURRENDER (unset; GRADE=certify), LAP_LOAD_STOP and LAP_LOAD_CLEAN (1; 0 the
#        controls of tests/lib/lap_load.sh), LAP_ABORT_AFTER_LOAD (0; 1 ABORTs after the warm-up),
#        FLEDGER_RELEASE_END (1; 0 the control), FLEDGER_END_PREP (0; 1 grades the next prep)
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}
cd "$(dirname "$0")" || exit 2
HERE=$(pwd)
# the tree root holds run.sh and tests/lib/rig.sh both: a draft of this lap run from a copy of
# tests/ alone finds the tree's own tools
while { [ ! -f run.sh ] || [ ! -f tests/lib/rig.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done
[ -f run.sh ] || { echo "ABORT: no tree root above $0"; exit 2; }
# the lap_bounded.py beside this lap's tests/ (a draft's own), else the tree's
LB=$HERE/../tools/lap_bounded.py
[ -f "$LB" ] || LB=tools/lap_bounded.py
LL=$HERE/lib/lap_load.sh
[ -f "$LL" ] || LL=tests/lib/lap_load.sh
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
SURRENDER=${SURRENDER:-}
case $INJECT in preempt|hbpause|shutdown) ;; *) echo "INJECT must be preempt, hbpause or shutdown"; exit 2;; esac
case $GRADE in ledger|reason|survivors|certify) ;; *) echo "GRADE must be ledger, reason, survivors or certify"; exit 2;; esac
for v in "$FENCED_ERRNO" "$RESEND_REDECIDE" "$RBLK_DENY_RESEND" "$SURRENDER"; do
    case $v in ''|0|1) ;; *) echo "FENCED_ERRNO, RESEND_REDECIDE, RBLK_DENY_RESEND and SURRENDER must be 0 or 1"; exit 2;; esac
done
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_fledger_$LABEL
mkdir -p "$OUT"
fails=0
. tests/lib/rig.sh
. "$LL"
MARK="FLEDGER-MARK-$LABEL-$$"
LD=/run/fledger_$LABEL
KL=/root/fledger.$LABEL.$$.kmsg
# The follower's `cat /dev/kmsg` starts at the oldest record still in the ring, so $KL begins with
# the lines of earlier laps of the same boot; a wait that read the whole file found an earlier
# lap's P238-FENCE-BLOCKED at once (attempt 21, f21s1: P's first match at 629.8 s, its mark at
# 759.1 s), stamped the verdict at the injection and graded the fence series as stall after it.
# Every wait on a line reads from this lap's mark on.  FLEDGER_KL_SINCE_MARK=0 reads the whole
# file, as before: the control.
if [ "${FLEDGER_KL_SINCE_MARK:-1}" = 0 ]; then
    KS="cat $KL"
else
    KS="awk '/$MARK\$/{f=1} f' $KL"
fi
echo "=== fenced_ledger_rig_lap label=$LABEL config=$MXFS_CONFIG V=$V P=$P inject=$INJECT park=$PARK grade=$GRADE fenced_errno=${FENCED_ERRNO:-default} resend_redecide=${RESEND_REDECIDE:-default} rblk_deny_resend=${RBLK_DENY_RESEND:-default} obs_s=$OBS_S $(date -u +%FT%TZ) ==="
s0=$(date +%s)
el() { echo $(( $(date +%s) - s0 )); }
field(){ grep -aoE "(^| )$2=[^ ]*" "$1" | head -1 | cut -d= -f2; }
# a count in a kernel-log file from the first line matching $2 onward
cnt_after() { awk -v a="$2" -v p="$3" 'index($0, a) { f = 1 } f && $0 ~ p { n++ } END { print n + 0 }' "$1"; }

GROUPARG=()
[ -n "${MXFS_GROUP:-}" ] && GROUPARG=(--group "$MXFS_GROUP")
MXFS_FORCE_PREP=1 python3 "$LB" 120 -- ./run.sh "$MXFS_CONFIG" "${GROUPARG[@]}" prep_cluster > "$OUT/prep.log" 2>&1
prc=$?
echo "STAGE prep rc=$prc wall=$(el)s"
[ $prc = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=prep wall=$(el)s evidence=$OUT"; exit 2; }
mxfs_dev_resolve "$P"; DEV=$MXFS_DEV_RESOLVED

# Once the loads may have started, every exit also waits for them to end and removes their /run
# files (tests/lib/lap_load.sh): no exit removed them, and fifteen laps filled a node's /run.
LOADS=0
stop_all() {
    for n in "${NODES[@]}"; do
        rs 15 "$n" "touch $LD.stop; kill \$(cat $KL.pid 2>/dev/null) 2>/dev/null; rm -f $KL.pid; echo 1 > $PARM/dl_auth_closed_park 2>/dev/null; echo 0 > $PARM/dl_inject_hb_pause_ms 2>/dev/null" > /dev/null 2>&1
    done
    [ "$LOADS" = 1 ] && lap_load_end "$LD" "$OUT" "${NODES[@]}"
    release_all
    [ "${FLEDGER_END_PREP:-0}" = 1 ] && end_prep
}
# Every node's mount released (fuser -km, umount, umount -f: what run.sh's teardown does first),
# and with the fix a node that still holds it captured and power-cycled (header).  The release
# attempt runs in both arms, so a node it cannot free is the same measurement in each: printed
# EXPOSED-WEDGE.  FLEDGER_RELEASE_END=0 leaves such a node for the next prep, as before.
release_all() {
    local n wedged=()
    for n in "${NODES[@]}"; do
        ( rs 30 "$n" "if grep -q ' $MNT ' /proc/mounts; then fuser -km $MNT >/dev/null 2>&1; sleep 1; umount $MNT 2>/dev/null || timeout 20 umount -f $MNT 2>/dev/null; fi; grep -q ' $MNT ' /proc/mounts && echo REL_HELD || echo REL_OK" > "$OUT/${n}_release.txt" 2>&1 ) &
    done
    wait
    for n in "${NODES[@]}"; do
        grep -q '^REL_OK$' "$OUT/${n}_release.txt" 2>/dev/null || wedged+=("$n")
    done
    [ "${#wedged[@]}" = 0 ] && { echo "  INFO every node released its mount at the lap's end"; return 0; }
    for n in "${wedged[@]}"; do
        echo "EXPOSED-WEDGE: $n did not release $MNT at the lap's end ($(tr '\n' ' ' < "$OUT/${n}_release.txt" | cut -c1-120))"
    done
    # the wedged node's stacks, read-only, in both arms (the instrument of H-SFV1/H-SFV2)
    for n in "${wedged[@]}"; do
        rs 30 "$n" "echo w > /proc/sysrq-trigger 2>/dev/null; for p in /proc/[0-9]*; do s=\$(awk '{print \$3}' \$p/stat 2>/dev/null); [ \"\$s\" = D ] || [ \"\$(cat \$p/comm 2>/dev/null)\" = umount ] || continue; echo \"== \${p#/proc/} \$(cat \$p/comm 2>/dev/null) state=\$s\"; cat \$p/stack 2>/dev/null; done; dmesg | tail -150" > "$OUT/${n}_wedged_stacks.txt" 2>&1
    done
    [ "${FLEDGER_RELEASE_END:-1}" = 0 ] && { echo "  INFO left for the next prep (FLEDGER_RELEASE_END=0): ${wedged[*]}"; return 0; }
    for n in "${wedged[@]}"; do
        echo "  LEFT-WEDGED: $n did not release $MNT at the lap's end ($(tr '\n' ' ' < "$OUT/${n}_release.txt" | cut -c1-120))"
        ( timeout 20 virsh -c qemu:///system destroy "$n" > /dev/null 2>&1; timeout 92 scripts/lab_power.sh up "$n" > "$OUT/${n}_power_cycle.txt" 2>&1; echo "  INFO $n power-cycled at the lap's end rc=$?" ) &
    done
    wait
}
# FLEDGER_END_PREP=1 (the row lap:fledger_release): the next lap's prep, run here under the same
# 120 s bound as every lap's own, so the lap grades what the record's failure was, a prep that a
# previous lap's wedged node made overrun.  It runs after the release (and, with the fix, after
# the power cycle), so in the control arm its teardown meets the node the lap left.
end_prep() {
    local rc t
    t=$(date +%s)
    MXFS_FORCE_PREP=1 python3 "$LB" 120 -- ./run.sh "$MXFS_CONFIG" "${GROUPARG[@]}" prep_cluster > "$OUT/end_prep.log" 2>&1
    rc=$?
    if [ "$rc" = 0 ]; then
        echo "LAP fledger_release PASS: the next prep formed the cluster in $(( $(date +%s) - t )) s of its 120 s bound"
    else
        echo "LAP fledger_release FAIL: the next prep rc=$rc after $(( $(date +%s) - t )) s of its 120 s bound ($(tail -2 "$OUT/end_prep.log" | tr '\n' ' ' | cut -c1-160))"
        # graded; now form the cluster again under the 300 s a forced prep is given elsewhere, so
        # the batch's next lap does not start on what the overrun left
        MXFS_FORCE_PREP=1 python3 "$LB" 300 -- ./run.sh "$MXFS_CONFIG" "${GROUPARG[@]}" prep_cluster > "$OUT/end_prep_repair.log" 2>&1
        echo "  INFO the cluster formed again after the graded prep: rc=$? ($(tail -1 "$OUT/end_prep_repair.log" | cut -c1-120))"
    fi
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
LOADS=1
for n in "${NODES[@]}"; do
    measure "$n" 30 "$OUT/${n}_load_start.txt" '^LOAD_STARTED$' "$n's load started" \
        "rm -rf $LD; mkdir -p $LD; rm -f $LD.stop; nohup setsid python3 $NREPO/tests/mpath/pathload.py run $n $MNT $LD $LD.stop > $LD.out 2>&1 < /dev/null & echo LOAD_STARTED"
done
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=load wall=$(el)s evidence=$OUT"; exit 2; }
sleep "$WARM_S"
# TEST ONLY: LAP_ABORT_AFTER_LOAD=1 ends the lap here with its loads running, as an ABORT after
# the loads start does (tests/lap_load_end_lap.sh)
[ "${LAP_ABORT_AFTER_LOAD:-0}" = 1 ] && { echo "RESULT: ABORT label=$LABEL stage=forced wall=$(el)s evidence=$OUT"; exit 2; }

# ---- 3. the park switch on V, then the injection
measure "$V" 20 "$OUT/V_park.txt" '^PARK=[0-9]+$' "V's park switch" \
    "echo $PARK > $PARM/dl_auth_closed_park; echo 'format \"P-TAUTH-PAGE-AUTH-CLOSED\" +p' > /sys/kernel/debug/dynamic_debug/control 2>/dev/null; echo PARK=\$(cat $PARM/dl_auth_closed_park)"
ck "V's dl_auth_closed_park reads back" "$(field "$OUT/V_park.txt" PARK)" "$PARK"
if [ -n "$FENCED_ERRNO" ]; then
    measure "$V" 20 "$OUT/V_errno.txt" '^FERRNO=' "V's fail-stop errno switch" \
        "echo $FENCED_ERRNO > $PARM/dl_failstop_fenced_errno; echo FERRNO=\$(cat $PARM/dl_failstop_fenced_errno 2>/dev/null || echo absent)"
    ck "V's dl_failstop_fenced_errno reads back" "$(field "$OUT/V_errno.txt" FERRNO)" "$FENCED_ERRNO"
fi
if [ -n "$SURRENDER" ]; then
    measure "$V" 20 "$OUT/V_surrender.txt" '^SURRENDER=' "V's surrender switch" \
        "echo $SURRENDER > $PARM/pr_surrender; echo SURRENDER=\$(cat $PARM/pr_surrender 2>/dev/null || echo absent)"
    ck "V's pr_surrender reads back" "$(field "$OUT/V_surrender.txt" SURRENDER)" "$SURRENDER"
fi
if [ "$GRADE" = certify ]; then
    # the prover's absent-key line is a debug one
    for n in "${NODES[@]}"; do
        rs 15 "$n" "echo 'format \"P-PR-FENCE-ABSENT\" +p' > /sys/kernel/debug/dynamic_debug/control 2>/dev/null" > /dev/null 2>&1
    done
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
elif [ "$INJECT" = shutdown ]; then
    # 0x8004587d = XFS_IOC_GOINGDOWN, flag 2 = NOLOGFLUSH (tests/d379b_dirty_depart_peer_fence.sh:83)
    measure "$V" 30 "$OUT/inject.txt" '^INJECT_RC=[0-9]+$' "V's filesystem shutdown" \
        "python3 -c \"import fcntl, os, struct; d = os.open('$MNT', os.O_RDONLY); fcntl.ioctl(d, 0x8004587d, struct.pack('I', 2)); os.close(d)\" && echo INJECT_RC=0 || echo INJECT_RC=1; sleep 2; $KS | grep -a 'P-WITHDRAW\|P163-WITHDRAW-STAMP' | tail -2 | cut -c1-200"
else
    measure "$V" 30 "$OUT/inject.txt" '^INJECT_RC=[0-9]+$' "V's heartbeat pause" \
        "echo $HB_PAUSE_MS > $PARM/dl_inject_hb_pause_ms || { echo INJECT_RC=1; exit 0; }; for i in 1 2 3 4 5 6; do sleep 2; $KS | grep -aq P-HB-INJECT-PAUSE && break; done; $KS | grep -a P-HB-INJECT-PAUSE | tail -1 | cut -c1-200; $KS | grep -aq P-HB-INJECT-PAUSE && echo INJECT_RC=0 || echo INJECT_RC=2"
fi
echo "STAGE inject $INJECT at $TP rc=$(field "$OUT/inject.txt" INJECT_RC)"
ck "the injection took" "$(field "$OUT/inject.txt" INJECT_RC)" 0
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=inject wall=$(el)s evidence=$OUT"; exit 2; }

# ---- 3b. survivors: the RECOVERY_BLOCKED verdict, as P's followed log shows it (its own
# declaration if P is the prover, the import otherwise); its time on P's clock in ms
TVMS=0
if [ "$GRADE" = survivors ]; then
    measure "$P" $(( VERDICT_S + 20 )) "$OUT/verdict.txt" '^VERDICT=' "the RECOVERY_BLOCKED verdict on P" \
        "for i in \$(seq 1 $(( VERDICT_S / 2 ))); do $KS | grep -aq 'P238-FENCE-BLOCKED' && break; sleep 2; done; $KS | grep -a 'P238-FENCE-BLOCKED' | head -1 | cut -c1-220; $KS | grep -aq 'P238-FENCE-BLOCKED' && echo VERDICT=\$(date +%s%3N) || echo VERDICT=none"
    TVMS=$(field "$OUT/verdict.txt" VERDICT)
    echo "STAGE verdict on P: ${TVMS:-none} at +$(el)s"
    case $TVMS in ''|none) TVMS=0 ;; esac
    # what an earlier lap of this boot left in P's followed file before this lap's mark
    measure "$P" 20 "$OUT/verdict_source.txt" '^PRE_MARK_P238=[0-9]+$' "P's verdict lines from before the mark" \
        "awk '/$MARK\$/{exit} /P238-FENCE-BLOCKED/{n++} END{print \"PRE_MARK_P238=\" n+0}' $KL"
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
    # The verdict's source, for D-FLEDGER-LAP-VERDICT-WAIT-READS-AN-EARLIER-LAPS-P238-FROM-BEFORE-ITS-MARK:
    # exposed when an earlier lap's verdict precedes the mark in P's followed file; the line the
    # wait took must then be in this lap's own log, the since-mark copy.  Graded apart from the
    # survivors' verdict below.
    PRE=$(field "$OUT/verdict_source.txt" PRE_MARK_P238)
    VL=$(grep -a 'P238-FENCE-BLOCKED' "$OUT/verdict.txt" | head -1 | cut -c1-120)
    if [ "${PRE:-0}" -gt 0 ]; then
        echo "SINCEMARK-EXPOSED: $PRE P238-FENCE-BLOCKED line(s) of earlier laps precede this lap's mark in $P's followed log"
        if [ -n "$VL" ] && grep -aqF -- "$VL" "$OUT/${P}_kmsg.txt"; then
            echo "LAP verdict_source PASS: the verdict the lap waited on is in its own log"
        else
            echo "LAP verdict_source FAIL: the verdict the lap waited on is not in this lap's log: ${VL:-none}"
        fi
    else
        echo "LAP verdict_source VACUOUS: no earlier lap's verdict precedes this lap's mark in $P's followed log"
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

if [ "$GRADE" = certify ]; then
    VGONE=$(cnt "$OUT/${V}_kmsg.txt" 'P277-PR-FULLSTATUS own key .* ABSENT\|P277-PR-READKEYS own key .* absent')
    SURR=$(cnt "$OUT/${V}_kmsg.txt" 'P-PR-SURRENDER ')
    ABSENT=0; CERT=0; BLOCKED=0; FENCED=0
    for n in "${SURV[@]}"; do
        ABSENT=$(( ABSENT + $(cnt "$OUT/${n}_kmsg.txt" 'P-PR-FENCE-ABSENT') ))
        FENCED=$(( FENCED + $(cnt "$OUT/${n}_kmsg.txt" 'P236-FENCEKIND') ))
        CERT=$(( CERT + $(cnt "$OUT/${n}_kmsg.txt" 'P236-FENCE-CERTIFIED') ))
        BLOCKED=$(( BLOCKED + $(cnt "$OUT/${n}_kmsg.txt" 'P238-FENCE-BLOCKED') ))
    done
    echo "STAGE certify: V key_gone=$VGONE surrender_lines=$SURR; survivors fenced=$FENCED fence_absent=$ABSENT certified=$CERT blocked=$BLOCKED"
    grep -a 'P-PR-SURRENDER\|P277-PR-FULLSTATUS\|P131-SELF-FENCE' "$OUT/${V}_kmsg.txt" | sed 's/.*mxfs: /    /' | cut -c1-220 | head -6
    for n in "${SURV[@]}"; do
        grep -a 'P236-FENCE-CERTIFIED\|P238-FENCE-BLOCKED\|P236-FENCEKIND' "$OUT/${n}_kmsg.txt" | sed "s/.*mxfs: /    $n: /" | cut -c1-220 | head -3
    done
    for n in "${NODES[@]}"; do
        ck "$n: zero BUG / Oops" "$(cnt "$OUT/${n}_kmsg.txt" '^BUG:\|[^E]BUG:\|kernel BUG at\|Oops')" 0
    done
    if [ "$VGONE" = 0 ] || [ "$FENCED" = 0 ]; then
        echo "  V found its key gone $VGONE time(s) and the survivors fenced V $FENCED time(s): the out-of-band removal never reached a fence"
        echo "RESULT: VACUOUS label=$LABEL stage=no-fence wall=$(el)s evidence=$OUT"; exit 3
    fi
    echo "EXPOSED: V found its key gone and the survivors fenced V ($FENCED fence line(s), $ABSENT of them met the key absent)"
    if [ "$CERT" -gt 0 ]; then echo "  PASS a survivor certified V's fence ($CERT line(s))"
    else echo "  FAIL no survivor certified V's fence within the window"; fails=$((fails+1)); fi
    if [ "$BLOCKED" = 0 ]; then echo "  PASS no survivor declared V's recovery blocked"
    else echo "  FAIL a survivor declared V's recovery blocked ($BLOCKED line(s))"; fails=$((fails+1)); fi
    if [ "${MAX_MS:-0}" -le 30000 ] 2>/dev/null; then echo "  PASS the survivors' longest operation ${MAX_MS} ms is within the 30 s stall limit"
    else echo "  FAIL the survivors' longest operation ${MAX_MS:-?} ms is over the 30 s stall limit"; fails=$((fails+1)); fi
    for n in "${SURV[@]}"; do ck "$n's load reported" "$(cnt "$OUT/${n}_load.txt" '^PATHLOAD ')" 1; done
    if [ $fails = 0 ]; then
        echo "LAP fenced_ledger_certify PASS: V's key left out of band and the survivors proved its exclusion; longest survivor operation ${MAX_MS} ms"
    else
        echo "LAP fenced_ledger_certify FAIL: $fails check(s) failed (certified=$CERT blocked=$BLOCKED max_op_ms=${MAX_MS:-0})"
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
