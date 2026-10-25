#!/bin/bash
# sb_cover_fence_lap.sh — does a fenced node whose log fails during its periodic log cover still
# let go of its mount?
#
# WHY THIS EXISTS.  D-SELF-FENCED-VICTIM-HOLDS-SB-BUFFER-AND-ITS-MXFS-NEVER-RELEASES-AT-TEARDOWN:
# test3 on 4/net/mesh/direct, its PR key removed out of band, shut down on a log error and ended
# the lap with its superblock buffer lock stuck (P-BUFLOCK-STUCK ops=xfs_sb, lock taken at
# __xfs_trans_getsb, waiter xfs_buf_item_unpin on a highpri kworker, pin=0); its mount never
# released and run.sh's next teardown had to power-cycle it.  Hypothesis H-SFV2: the clustered
# log cover (mxfs_sb_runtime_cover, xfs/xfs_log.c) keeps the superblock buffer locked across its
# synchronous commit; when that commit's iclog write fails, the shutdown runs the iclog's
# callbacks before it wakes the commit, and the aborted checkpoint's unpin waits for the lock the
# sleeping commit holds.  The fix commits the cover unheld and re-locks the buffer for the home
# write; module parameter sb_cover_hold=1 holds it as before: the same-build control.
#
# SHAPE (V = first node, P = last node of MXFS_NODE_LIST):
#   1. a forced prep; V's log worker period at its minimum (syncd_centisecs=100, so V covers its
#      log about every second while it is idle), sb_cover_hold=$COVER_HOLD on V, and V's cover
#      lines (P-SB-RUNTIME-COVER-BEGIN / P-SB-RUNTIME-COVER) enabled; each node's /dev/kmsg
#      followed into /root from before the lap's mark.
#   2. V runs a trickle writer: one small file rewritten every 2 s, so V's log keeps going idle
#      and needing a cover; the writer runs under a node-side deadline, so it ends by itself
#      even if the lap cannot reach V again.
#   3. V's heartbeat is paused (dl_inject_hb_pause_ms), so V does not learn of its fence from
#      its own heartbeat, and then (INJECT=preempt, the default) P removes V's key out of band,
#      or (INJECT=hbpause) P's own fence after the death window removes it.  V's next write is
#      refused and its log shuts down.
#   4. once V has logged its log-error shutdown (or SHUT_S passed), V's writer stops and the lap
#      unmounts V with a bound of the 30 s stall limit (data/release_policy.json).
#   EXPOSED  V's log-error shutdown came while a cover was in its commit: the last
#            P-SB-RUNTIME-COVER-BEGIN before V's 'shut down due to log error' line has no
#            P-SB-RUNTIME-COVER line between them.
#   PASS     V's umount returned within 30 s with the mount gone from /proc/mounts, and V logged
#            no P-BUFLOCK-STUCK for the superblock buffer (ops=xfs_sb); no BUG or Oops on any node.
#   FAIL     V's umount did not return, or the mount stayed, or V logged P-BUFLOCK-STUCK
#            ops=xfs_sb, or a BUG/Oops.
#   VACUOUS  V logged no log-error shutdown within SHUT_S, or it came with no cover in its commit.
# At every exit each node is unmounted; a node still holding the mount is reported LEFT-WEDGED,
# the stacks of its D-state tasks and its umount are kept as <node>_wedged_stacks.txt (the
# instrument H-SFV2 is falsified by: no log worker in mxfs_sb_runtime_cover ->
# xlog_wait_on_iclog, no kworker in xfs_buf_item_unpin -> xfs_buf_lock), and it is power-cycled.
#
# Bounds (derived): prep on a pair 53-104 s, at 4 nodes 41-53 s measured, bound 120; keys 30; the
# followers 30 a node, one after another (each takes about 2 s); V's switches 20; the writer's
# start 30; WARM_S 8 and its read 20; the pause 30 and the injection 30; SHUT_S 30 (the cover
# period 1 s plus the death window 12 s for INJECT=hbpause, doubled and rounded up) + 10; V's
# umount 40; the reads 30 a node; the release 30 a node at once, a wedged node's stacks 30 and
# power cycle 112 (destroy, then lab_power's up, measured 45-56 s, doubled).  At 4 nodes
# 120+30+120+20+30+28+60+40+3+40+120+30+30+112 = 783; at 2 nodes 663.  Caller bound 2 x the
# precheck's wall.
#
# Usage: sb_cover_fence_lap.sh <label>
# Env:   MXFS_NODE_LIST (test17,test18), MXFS_CONFIG (2/net/mesh/direct), MXFS_GROUP,
#        COVER_HOLD (0: the fix; 1: held across the commit, as before), INJECT (preempt|hbpause,
#        preempt), WARM_S (8), SHUT_S (30), HB_PAUSE_MS (60000)
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}
cd "$(dirname "$0")" || exit 2
HERE=$(pwd)
while { [ ! -f run.sh ] || [ ! -f tests/lib/rig.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done
[ -f run.sh ] || { echo "ABORT: no tree root above $0"; exit 2; }
LB=$HERE/../tools/lap_bounded.py
[ -f "$LB" ] || LB=tools/lap_bounded.py
export MXFS_NODE_LIST=${MXFS_NODE_LIST:-test17,test18}
export MXFS_CONFIG=${MXFS_CONFIG:-2/net/mesh/direct}
V=${MXFS_NODE_LIST%%,*}
P=${MXFS_NODE_LIST##*,}
IFS=, read -r -a NODES <<< "$MXFS_NODE_LIST"
MNT=/mnt/shared
PARM=/sys/module/mxfs/parameters
COVER_HOLD=${COVER_HOLD:-0}
INJECT=${INJECT:-preempt}
WARM_S=${WARM_S:-8}
SHUT_S=${SHUT_S:-30}
HB_PAUSE_MS=${HB_PAUSE_MS:-60000}
case $COVER_HOLD in 0|1) ;; *) echo "COVER_HOLD must be 0 or 1"; exit 2;; esac
case $INJECT in preempt|hbpause) ;; *) echo "INJECT must be preempt or hbpause"; exit 2;; esac
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_sbcover_$LABEL
mkdir -p "$OUT"
fails=0
. tests/lib/rig.sh
MARK="SBCOVER-MARK-$LABEL-$$"
KL=/root/sbcover.$LABEL.$$.kmsg
WR=/root/sbcover.$LABEL.$$.writer
KS="awk '/$MARK\$/{f=1} f' $KL"
echo "=== sb_cover_fence_lap label=$LABEL config=$MXFS_CONFIG V=$V P=$P cover_hold=$COVER_HOLD inject=$INJECT $(date -u +%FT%TZ) ==="
s0=$(date +%s)
el() { echo $(( $(date +%s) - s0 )); }
field(){ grep -aoE "(^| )$2=[^ ]*" "$1" | head -1 | cut -d= -f2; }

GROUPARG=()
[ -n "${MXFS_GROUP:-}" ] && GROUPARG=(--group "$MXFS_GROUP")
MXFS_FORCE_PREP=1 python3 "$LB" 120 -- ./run.sh "$MXFS_CONFIG" "${GROUPARG[@]}" prep_cluster > "$OUT/prep.log" 2>&1
prc=$?
echo "STAGE prep rc=$prc wall=$(el)s"
[ $prc = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=prep wall=$(el)s evidence=$OUT"; exit 2; }
mxfs_dev_resolve "$P"; DEV=$MXFS_DEV_RESOLVED

# every exit: V's writer and pause stopped, the followers ended, every node released (header)
stop_all() {
    local n wedged=()
    rs 15 "$V" "touch $WR.stop; echo 0 > $PARM/dl_inject_hb_pause_ms 2>/dev/null" > /dev/null 2>&1
    for n in "${NODES[@]}"; do
        rs 15 "$n" "kill \$(cat $KL.pid 2>/dev/null) 2>/dev/null; rm -f $KL.pid" > /dev/null 2>&1
    done
    for n in "${NODES[@]}"; do
        ( rs 30 "$n" "if grep -q ' $MNT ' /proc/mounts; then fuser -km $MNT >/dev/null 2>&1; sleep 1; timeout 20 umount $MNT 2>/dev/null; fi; grep -q ' $MNT ' /proc/mounts && echo REL_HELD || echo REL_OK" > "$OUT/${n}_release.txt" 2>&1 ) &
    done
    wait
    for n in "${NODES[@]}"; do
        grep -q '^REL_OK$' "$OUT/${n}_release.txt" 2>/dev/null || wedged+=("$n")
    done
    [ "${#wedged[@]}" = 0 ] && { echo "  INFO every node released its mount at the lap's end"; return 0; }
    for n in "${wedged[@]}"; do
        echo "  LEFT-WEDGED: $n did not release $MNT at the lap's end ($(tr '\n' ' ' < "$OUT/${n}_release.txt" | cut -c1-120))"
        rs 30 "$n" "echo w > /proc/sysrq-trigger 2>/dev/null; for p in /proc/[0-9]*; do s=\$(awk '{print \$3}' \$p/stat 2>/dev/null); [ \"\$s\" = D ] || [ \"\$(cat \$p/comm 2>/dev/null)\" = umount ] || continue; echo \"== \${p#/proc/} \$(cat \$p/comm 2>/dev/null) state=\$s\"; cat \$p/stack 2>/dev/null; done; dmesg | tail -150" > "$OUT/${n}_wedged_stacks.txt" 2>&1
        ( timeout 20 virsh -c qemu:///system destroy "$n" > /dev/null 2>&1; timeout 92 scripts/lab_power.sh up "$n" > "$OUT/${n}_power_cycle.txt" 2>&1; echo "  INFO $n power-cycled at the lap's end rc=$?" ) &
    done
    wait
}
trap stop_all EXIT

# ---- 1. keys, followers, V's switches
measure "$P" 30 "$OUT/full_status_before.txt" '^PRIN_END$' "the registrants before the injection" \
    "sg_persist --in --read-full-status $DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo PRIN_END"
keyof() { awk -v n="$1-mxfs-node" '/Key=/ { k = $0; sub(/.*Key=/, "", k); sub(/[^0-9a-fx].*/, "", k) } index($0, n) && k != "" { print k; exit }' "$OUT/full_status_before.txt"; }
VKEY=$(keyof "$V"); PKEY=$(keyof "$P")
echo "STAGE keys V=$V key=${VKEY:-?} P=$P key=${PKEY:-?}"
[ -n "$VKEY" ] && [ -n "$PKEY" ] || { echo "ABORT: the target lists no key for $V or $P"; echo "RESULT: ABORT label=$LABEL stage=keys wall=$(el)s evidence=$OUT"; exit 2; }
for n in "${NODES[@]}"; do
    measure "$n" 30 "$OUT/${n}_follow.txt" '^FOLLOW=[0-9]+$' "$n's kernel-log follower" \
        "rm -f $KL $KL.pid; nohup setsid sh -c 'echo \$\$ > $KL.pid; exec cat /dev/kmsg > $KL' > /dev/null 2>&1 < /dev/null & sleep 1; echo $MARK > /dev/kmsg; sleep 1; echo FOLLOW=\$(grep -ac '$MARK\$' $KL)"
    ck "$n's follower holds the mark" "$(field "$OUT/${n}_follow.txt" FOLLOW)" 1
done
measure "$V" 20 "$OUT/V_switches.txt" '^HOLD=' "V's cover switches" \
    "echo 100 > $PARM/syncd_centisecs; echo $COVER_HOLD > $PARM/sb_cover_hold; echo 'format \"P-SB-RUNTIME-COVER\" +p' > /sys/kernel/debug/dynamic_debug/control 2>/dev/null; echo SYNCD=\$(cat $PARM/syncd_centisecs 2>/dev/null || echo absent); echo HOLD=\$(cat $PARM/sb_cover_hold 2>/dev/null || echo absent)"
ck "V's syncd_centisecs reads back" "$(field "$OUT/V_switches.txt" SYNCD)" 100
ck "V's sb_cover_hold reads back" "$(field "$OUT/V_switches.txt" HOLD)" "$COVER_HOLD"
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=switches wall=$(el)s evidence=$OUT"; exit 2; }

# ---- 2. V's trickle writer, under a node-side deadline of the lap's own bound
measure "$V" 30 "$OUT/V_writer.txt" '^WRITER_STARTED$' "V's trickle writer" \
    "rm -f $WR.stop; nohup setsid timeout 783 sh -c 'i=0; while [ ! -e $WR.stop ]; do i=\$((i+1)); echo \$i > $MNT/sbcover_$LABEL.\$((i % 4)) 2>/dev/null; sleep 2; done' > /dev/null 2>&1 < /dev/null & echo WRITER_STARTED"
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=writer wall=$(el)s evidence=$OUT"; exit 2; }
sleep "$WARM_S"
measure "$V" 20 "$OUT/V_covers_warm.txt" '^COVERS=[0-9]+$' "V's covers in the warm-up" \
    "echo COVERS=\$($KS | grep -ac 'P-SB-RUNTIME-COVER-BEGIN')"
echo "STAGE warm covers=$(field "$OUT/V_covers_warm.txt" COVERS)"

# ---- 3. V's heartbeat paused, then the key removed
measure "$V" 30 "$OUT/V_pause.txt" '^PAUSE_RC=[0-9]+$' "V's heartbeat pause" \
    "echo $HB_PAUSE_MS > $PARM/dl_inject_hb_pause_ms || { echo PAUSE_RC=1; exit 0; }; for i in 1 2 3 4 5 6; do sleep 1; $KS | grep -aq P-HB-INJECT-PAUSE && break; done; $KS | grep -a P-HB-INJECT-PAUSE | tail -1 | cut -c1-200; $KS | grep -aq P-HB-INJECT-PAUSE && echo PAUSE_RC=0 || echo PAUSE_RC=2"
ck "V's heartbeat paused" "$(field "$OUT/V_pause.txt" PAUSE_RC)" 0
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=pause wall=$(el)s evidence=$OUT"; exit 2; }
TP=$(date -u +%FT%T.%3NZ)
if [ "$INJECT" = preempt ]; then
    measure "$P" 30 "$OUT/inject.txt" '^INJECT_RC=[0-9]+$' "P's preempt of V's key" \
        "sg_persist --out --preempt --prout-type=7 --param-rk=$PKEY --param-sark=$VKEY $DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo INJECT_RC=\${PIPESTATUS[0]}"
    ck "the preempt took" "$(field "$OUT/inject.txt" INJECT_RC)" 0
    [ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=inject wall=$(el)s evidence=$OUT"; exit 2; }
fi
echo "STAGE inject $INJECT at $TP"

# ---- 4. V's log-error shutdown, then V's writer stopped and its umount
measure "$V" $(( SHUT_S + 10 )) "$OUT/V_shutdown.txt" '^SHUT=' "V's log-error shutdown" \
    "for i in \$(seq 1 $SHUT_S); do $KS | grep -aq 'shut down due to log error' && break; sleep 1; done; $KS | grep -a 'shut down due to log error' | head -1 | cut -c1-200; $KS | grep -aq 'shut down due to log error' && echo SHUT=1 || echo SHUT=0"
SHUT=$(field "$OUT/V_shutdown.txt" SHUT)
echo "STAGE V's log-error shutdown=${SHUT:-?} at +$(el)s"
rs 15 "$V" "touch $WR.stop" > /dev/null 2>&1
sleep 3
# not measure(): an umount that never returns is this lap's FAIL, not a capture ABORT.  The
# command prints UMOUNT_START before the umount, so a capture holding it and no UMOUNT_END is an
# umount that did not return within the bound (a timeout(1) cannot end a task in D state); one
# without UMOUNT_START never reached V.
rsx 40 "$V" "fuser -km $MNT > /dev/null 2>&1; sleep 1; echo UMOUNT_START; t0=\$(date +%s%3N); timeout 30 umount $MNT; echo UMOUNT_RC=\$?; echo UMOUNT_MS=\$(( \$(date +%s%3N) - t0 )); grep -q ' $MNT ' /proc/mounts && echo MOUNTED=1 || echo MOUNTED=0; echo UMOUNT_END" > "$OUT/V_umount.txt"
if grep -aq '^UMOUNT_END$' "$OUT/V_umount.txt"; then
    URC=$(field "$OUT/V_umount.txt" UMOUNT_RC); UMS=$(field "$OUT/V_umount.txt" UMOUNT_MS); MOUNTED=$(field "$OUT/V_umount.txt" MOUNTED)
elif grep -aq '^UMOUNT_START$' "$OUT/V_umount.txt"; then
    URC=hung; UMS=">40000"; MOUNTED=1
else
    echo "ABORT: V's umount was never started ($(tr '\n' ' ' < "$OUT/V_umount.txt" | cut -c1-160))"
    echo "RESULT: ABORT label=$LABEL stage=umount wall=$(el)s evidence=$OUT"; exit 2
fi
echo "STAGE V's umount rc=${URC:-?} ms=${UMS:-?} still_mounted=${MOUNTED:-?}"

# ---- the kernel logs since the mark
for n in "${NODES[@]}"; do
    measure "$n" 30 "$OUT/${n}_kmsg.txt" '^KMSG_END$' "$n's kernel log since the mark" \
        "echo '$MARK-END' > /dev/kmsg; sleep 1; kill \$(cat $KL.pid) 2>/dev/null; awk '/$MARK\$/{f=1} f' $KL | cut -c1-700; echo KMSG_END"
done
for n in "${NODES[@]}"; do
    grep -aq "$MARK\$" "$OUT/${n}_kmsg.txt" && grep -aq "$MARK-END\$" "$OUT/${n}_kmsg.txt" \
        || { echo "LAP sb_cover_fence FAIL: $n's kernel log read does not hold both of the lap's marks"; echo "RESULT: FAIL label=$LABEL stage=kmsg wall=$(el)s evidence=$OUT"; exit 1; }
done
VK=$OUT/${V}_kmsg.txt
STUCK=$(grep -ac 'P-BUFLOCK-STUCK .*ops=xfs_sb ' "$VK")
grep -a 'P-SB-RUNTIME-COVER\|shut down due to log error\|P-BUFLOCK-STUCK\|P131-SELF-FENCE\|P277' "$VK" | sed 's/.*mxfs: /    /' | cut -c1-200 | tail -12
for n in "${NODES[@]}"; do
    ck "$n: zero BUG / Oops" "$(cnt "$OUT/${n}_kmsg.txt" '^BUG:\|[^E]BUG:\|kernel BUG at\|Oops')" 0
done

if [ "${SHUT:-0}" != 1 ]; then
    echo "  V logged no log-error shutdown within ${SHUT_S} s of the injection"
    echo "RESULT: VACUOUS label=$LABEL stage=no-log-error wall=$(el)s evidence=$OUT"; exit 3
fi
# the cover in its commit when the log failed: the last BEGIN before the shutdown line, and no
# cover line ending it between them
INFLIGHT=$(awk '/P-SB-RUNTIME-COVER-BEGIN/ { b = 1; next } /P-SB-RUNTIME-COVER / { b = 0; next } /shut down due to log error/ { print b + 0; exit }' "$VK")
echo "STAGE cover in its commit at the shutdown=${INFLIGHT:-?} buflock_stuck_sb=$STUCK"
if [ "${INFLIGHT:-0}" != 1 ]; then
    if [ "$STUCK" -gt 0 ] || [ "${MOUNTED:-1}" != 0 ]; then
        echo "LAP sb_cover_fence FAIL: V did not let go of its mount (umount rc=${URC:-?}, still mounted=${MOUNTED:-?}, P-BUFLOCK-STUCK xfs_sb=$STUCK) though no cover was in its commit at the shutdown"
        echo "RESULT: FAIL label=$LABEL fails=$((fails+1)) wall=$(el)s evidence=$OUT"; exit 1
    fi
    echo "  V's log failed with no cover in its commit"
    echo "RESULT: VACUOUS label=$LABEL stage=cover-not-in-commit wall=$(el)s evidence=$OUT"; exit 3
fi
echo "EXPOSED: V's log failed while its cover was in its synchronous commit (cover_hold=$COVER_HOLD)"
ck "V's umount returned" "${URC:-x}" 0
ck "V's mount is gone" "${MOUNTED:-x}" 0
ck "V logged no stuck superblock buffer lock" "$STUCK" 0
if [ $fails = 0 ]; then
    echo "LAP sb_cover_fence PASS: V let go of its mount in ${UMS:-?} ms after its log failed during its cover's commit"
else
    echo "LAP sb_cover_fence FAIL: $fails check(s) failed (umount rc=${URC:-?} ms=${UMS:-?}, still mounted=${MOUNTED:-?}, P-BUFLOCK-STUCK xfs_sb=$STUCK)"
fi
echo "RESULT: $( [ $fails = 0 ] && echo PASS || echo FAIL ) label=$LABEL fails=$fails wall=$(el)s evidence=$OUT"
[ $fails = 0 ]
