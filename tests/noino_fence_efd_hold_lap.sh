#!/bin/bash
# noino_fence_efd_hold_lap.sh — does a node shut itself down when a peer's BAST
# needs a no-inode release while one of its own extent-free chains is held?
#
# WHY THIS EXISTS.  D-8CAWMPATH-SURVIVOR-SHUTS-DOWN-ON-NOINO-EFI-WEDGE-DURING-PEER-FENCE:
# on 8/disk/caw/mpath the live survivor test7 shut its filesystem down while its
# peers fenced the frozen test14.  A peer's BAST for a no-inode grant ran the
# release's drain fence (xfs/xfs_mxfs_noino.c mxfs_noino_drain_fence), the AIL
# minimum stayed at an extent-free intent whose EFD had not committed, and after
# MXFS_NOINO_STALL_TRIES (8) bounded pushes with no AG wait in flight
# (mxfs_noino_freeze_is_convoy counts only those) the fence gave up:
# P-NOINO-DRAIN-STUCK, P-NOINO-RELFENCE-WEDGE, shutdown.  What held that EFD is
# not known (H2 in the record: a seam relock behind the frozen victim).  This lap
# holds an EFD on purpose (dbg_efd_hold_ms: the EFI forced durable, the EFD
# transaction parked) while both nodes run the path rows' load, whose churn in a
# shared directory is where no-inode releases come from (a peer's create reusing
# a number this node still holds a corpse grant for; tests/noino_acq_takeover_ab.sh),
# so it shows whether an EFD chain held past the fence's stall budget shuts the
# node down, whatever holds it.
#
# History of the lap (lanes g2c_w12, g2c_w12b, 2026-10-24): stats of S's evicted
# files on R drew PR BASTs that S served in ~10 ms each without a fence, VACUOUS
# 4 of 4 (tests/evidence/20261024T082305Z_noinoefd_nfe30a and later): those were
# not no-inode releases.  With pathload's churn on both nodes (lane g2c_w12c) one
# 30 s lap in two met a no-inode release inside the hold, and that one shut S down
# (the minimum was the removed file's inode item, whose ILOCK the held chain keeps).
#
# The fix: mxfs_noino_freeze_is_convoy counts a minimum held by a local chain in
# flight (an intent item, or an inode item whose ILOCK is held) as a convoy, which
# the 45-try wall still bounds.  The control is the module parameter
# noino_convoy_chain=0 on the lap's own prep (MXFS_EXTRA_MODARGS), which excuses
# only AG waits, as before.  HOLD_MS defaults to 26000: past the fence's stall
# budget (8 bounded pushes, ~20 s), so the control still gives up inside the hold,
# and under the 30 s stall limit, so the fix-on arm's peer waiting out the held
# chain is not itself a stall failure (R's longest operation was 30909 ms at 30000).
#
# SHAPE (S = first node, R = last node of MXFS_NODE_LIST):
#   1. prep the pair; S writes a 4 MiB file F.
#   2. both nodes run tests/mpath/pathload.py in the mount, detached.
#   3. after WARM_S, S arms dbg_efd_hold_ms=HOLD_MS and removes F: its
#      inactivation logs the EFI, forces it durable and parks the EFD
#      (P-EFD-HOLD start); the load keeps committing newer items behind it.
#   4. the load runs on HOLD_MS/1000 + 30 s, then both stop.
#   EXPOSED  S logged P-EFD-HOLD start and its no-inode fence met the frozen
#            minimum (P-NOINO-DRAIN-RETRY, -CONVOY, -DRAIN-STUCK or P-AILMIN).
#   PASS     S never shut down (no P-NOINO-RELFENCE-WEDGE, P-NOINO-DRAIN-STUCK,
#            'Shutting down'), both loads ended with err=0 and double_grant=0,
#            both nodes still mounted and writing, no BUG or Oops.
#
# Bounds (derived): prep on a pair measured 53-104 s, bound 120; F's write 30;
# the load start 30 a node; WARM_S 10; the hold start 15; the run
# HOLD_MS/1000 + 30; the load's stop 45 (tests/mpath/lib.sh's bound on its
# report); reads 6 x 30.  Caller bound 2 x the precheck's wall.
#
# Usage: noino_fence_efd_hold_lap.sh <label>
# Env:   MXFS_NODE_LIST (test29,test30), MXFS_CONFIG (2/disk/caw/direct), MXFS_GROUP,
#        HOLD_MS (26000), WARM_S (10), NOINO_RING_ROTATE (0; 1 fills S's ring past the mark
#        before the hold, at most 60 s more), LAP_LOAD_STOP and LAP_LOAD_CLEAN (1; 0 the
#        controls of tests/lib/lap_load.sh), LAP_ABORT_AFTER_LOAD (0; 1 ABORTs after the warm-up)
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}
cd "$(dirname "$0")" || exit 2
HERE=$(pwd)
# the tree root holds run.sh and tests/lib/rig.sh both: a draft of run.sh alone beside the lap
# is not a root
while { [ ! -f run.sh ] || [ ! -f tests/lib/rig.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done
[ -f run.sh ] || { echo "ABORT: no tree root above $0"; exit 2; }
# the lap_bounded.py and lap_load.sh beside this lap's tests/ (a draft's own), else the tree's
LB=$HERE/../tools/lap_bounded.py
[ -f "$LB" ] || LB=tools/lap_bounded.py
LL=$HERE/lib/lap_load.sh
[ -f "$LL" ] || LL=tests/lib/lap_load.sh
NREPO=/src/$(basename "$(pwd)")
export MXFS_NODE_LIST=${MXFS_NODE_LIST:-test29,test30}
export MXFS_CONFIG=${MXFS_CONFIG:-2/disk/caw/direct}
S=${MXFS_NODE_LIST%%,*}
R=${MXFS_NODE_LIST##*,}
MNT=/mnt/shared
PARM=/sys/module/mxfs/parameters
HOLD_MS=${HOLD_MS:-26000}
WARM_S=${WARM_S:-10}
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_noinoefd_$LABEL
mkdir -p "$OUT"
fails=0
. tests/lib/rig.sh
. "$LL"
MARK="NOINOEFD-MARK-$LABEL-$$"
D=$MNT/noinoefd_$LABEL
LD=/run/noinoefd_$LABEL
echo "=== noino_fence_efd_hold_lap label=$LABEL config=$MXFS_CONFIG S=$S R=$R hold_ms=$HOLD_MS warm_s=$WARM_S $(date -u +%FT%TZ) ==="
s0=$(date +%s)
el() { echo $(( $(date +%s) - s0 )); }
field(){ grep -aoE "(^| )$2=[^ ]*" "$1" | head -1 | cut -d= -f2; }

GROUPARG=()
[ -n "${MXFS_GROUP:-}" ] && GROUPARG=(--group "$MXFS_GROUP")
MXFS_FORCE_PREP=1 python3 "$LB" 120 -- ./run.sh "$MXFS_CONFIG" "${GROUPARG[@]}" prep_cluster > "$OUT/prep.log" 2>&1
prc=$?
echo "STAGE prep rc=$prc wall=$(el)s"
[ $prc = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=prep wall=$(el)s evidence=$OUT"; exit 2; }

# ---- 0. each node's kernel log followed from before the marks
# The verdict reads S's no-inode fence lines from the kernel log.  Read from the ring after
# the run, it held nothing on either node in every lap at 2/net/mesh/direct: the network lock
# manager's debug lines rotate the mark out of the ring within the run, so a lap whose S shut
# down was graded VACUOUS on an empty read
# (D-NOINO-LAP-READS-KERNEL-LOG-AFTER-THE-MARK-ROTATED-OUT-AND-GRADES-NOTHING).  Each
# node's /dev/kmsg is followed into /root from before the marks to an end mark written after
# the run, and a read that does not hold both marks grades nothing.  NOINO_KMSG_FOLLOW=0 reads
# the ring afterwards, as before, under the same mark check: the control.
FOLLOW=${NOINO_KMSG_FOLLOW:-1}
KL=/root/noinoefd.$LABEL.$$.kmsg
stop_follow() {
    for n in "$S" "$R"; do
        rs 15 "$n" "kill \$(cat $KL.pid 2>/dev/null) 2>/dev/null; rm -f $KL $KL.pid" > /dev/null 2>&1
    done
}
# Every exit once the loads may have started ends them and removes their /run files
# (tests/lib/lap_load.sh): the lap stopped them only on its normal path, so one that ABORTed
# after starting them left them running into the next lap's prep, and no exit removed their
# logs, which filled the node's /run.
LOADS=0
lap_exit() {
    [ "$LOADS" = 1 ] && lap_load_end "$LD" "$OUT" "$S" "$R"
    [ "$FOLLOW" = 1 ] && stop_follow
}
trap lap_exit EXIT
if [ "$FOLLOW" = 1 ]; then
    for n in "$S" "$R"; do
        rs 20 "$n" "rm -f $KL $KL.pid; nohup setsid sh -c 'echo \$\$ > $KL.pid; exec cat /dev/kmsg > $KL' > /dev/null 2>&1 < /dev/null & echo started" > /dev/null
    done
fi

# ---- 1. F on S, and the marks
measure "$S" 30 "$OUT/S_setup.txt" '^SETUP_RC=[0-9]+$' "S's file F" \
    "test -w $PARM/dbg_efd_hold_ms || { echo SETUP_RC=90; exit 0; }; mkdir -p $D || { echo SETUP_RC=91; exit 0; }; dd if=/dev/urandom of=$D/F bs=1M count=4 conv=fsync status=none || { echo SETUP_RC=93; exit 0; }; echo $MARK > /dev/kmsg; echo SETUP_RC=0"
ck "S's file written" "$(field "$OUT/S_setup.txt" SETUP_RC)" 0
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=setup wall=$(el)s evidence=$OUT"; exit 2; }
rs 15 "$R" "echo $MARK > /dev/kmsg" > /dev/null 2>&1
# a follower that never started reads nothing: each node's file must hold the mark
if [ "$FOLLOW" = 1 ]; then
    for n in "$S" "$R"; do
        measure "$n" 20 "$OUT/${n}_follow.txt" '^FOLLOW_MARK=[0-9]+$' "$n's kernel-log follower" \
            "sleep 1; echo FOLLOW_MARK=\$(grep -ac '$MARK\$' $KL 2>/dev/null)"
        ck "$n's follower holds the lap's mark" "$(field "$OUT/${n}_follow.txt" FOLLOW_MARK)" 1
    done
    [ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=follow wall=$(el)s evidence=$OUT"; exit 2; }
fi

# ---- 2. the load on both nodes
LOADS=1
for n in "$S" "$R"; do
    measure "$n" 30 "$OUT/${n}_load_start.txt" '^LOAD_STARTED$' "$n's load started" \
        "rm -rf $LD; mkdir -p $LD; rm -f $LD.stop; nohup setsid python3 $NREPO/tests/mpath/pathload.py run $n $MNT $LD $LD.stop > $LD.out 2>&1 < /dev/null & echo LOAD_STARTED"
done
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=load wall=$(el)s evidence=$OUT"; exit 2; }
sleep "$WARM_S"
# TEST ONLY: LAP_ABORT_AFTER_LOAD=1 ends the lap here with its loads running, as an ABORT after
# the loads start does (tests/lap_load_end_lap.sh)
[ "${LAP_ABORT_AFTER_LOAD:-0}" = 1 ] && { echo "RESULT: ABORT label=$LABEL stage=forced wall=$(el)s evidence=$OUT"; exit 2; }

# ---- 2b. TEST ONLY: S's ring rotated past the mark before the hold
# Whether the load's lines rotate the mark out of S's ring before the hold is looked for is
# chance: no lap of the hold read's control at WARM_S=60 met it (b20261024-2e4683, lane g2_a19
# step 5: ten PASS laps, HOLD-RING-ROTATED never printed).  NOINO_RING_ROTATE=1 makes it so on
# every lap: S writes filler records to /dev/kmsg, one write each, until its ring no longer
# holds the mark (at most 400000), with /dev/kmsg's rate limit lifted for the fill and put
# back after it.  The followed log holds the filler too; the lap's reads of it are unchanged.
if [ "${NOINO_RING_ROTATE:-0}" = 1 ]; then
    measure "$S" 60 "$OUT/S_rotate.txt" '^ROTATE_MARK=[0-9]+$' "S's ring rotated past the mark" \
        "old=\$(cat /proc/sys/kernel/printk_devkmsg); echo on > /proc/sys/kernel/printk_devkmsg; exec 3>/dev/kmsg; n=0; while [ \$n -lt 400000 ] && dmesg | grep -q '$MARK\$'; do for i in \$(seq 1 5000); do echo 'NOINOEFD-FILL $LABEL' >&3; done; n=\$((n + 5000)); done; exec 3>&-; echo \$old > /proc/sys/kernel/printk_devkmsg; echo ROTATE_LINES=\$n; echo ROTATE_MARK=\$(dmesg | grep -c '$MARK\$')"
    echo "STAGE rotate lines=$(field "$OUT/S_rotate.txt" ROTATE_LINES) mark_in_ring=$(field "$OUT/S_rotate.txt" ROTATE_MARK) at +$(el)s"
    ck "S's ring no longer holds the mark after the fill" "$(field "$OUT/S_rotate.txt" ROTATE_MARK)" 0
    [ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=rotate wall=$(el)s evidence=$OUT"; exit 2; }
fi

# ---- 3. the hold, and F removed
# Whether the hold started is read from the followed log too: read from the ring after the mark
# it is empty once the load's lines have rotated the mark out, and the lap ended VACUOUS
# stage=hold on a read that held nothing (the review of P20261024-16a9f2), and that exit came
# before the whole-read check. NOINO_HOLD_FROM_FOLLOW=0 reads the hold from the ring and judges it
# before the whole-read check, as before: the control of this part (NOINO_KMSG_FOLLOW=0 implies it).
HOLD_FOLLOW=${NOINO_HOLD_FROM_FOLLOW:-1}
[ "$FOLLOW" = 1 ] || HOLD_FOLLOW=0
if [ "$HOLD_FOLLOW" = 1 ]; then HOLD_READ="awk '/$MARK\$/{f=1} f' $KL"; else HOLD_READ="dmesg | sed -n '/$MARK/,\$p'"; fi
# The look is bounded by a 15 s deadline, not a count of looks: a look at a ring the fill has
# filled takes about a second, so thirty of them overran the 30 s bound below and the control
# ABORTed (lane g2b_ringprecheck_20261024T160056Z step 3) instead of grading its empty read.
measure "$S" 30 "$OUT/S_hold.txt" '^HOLD_SEEN=[0-9]+$' "the EFD hold on $S" \
    "echo $HOLD_MS > $PARM/dbg_efd_hold_ms; nohup setsid rm -f $D/F > /dev/null 2>&1 < /dev/null & end=\$((SECONDS + 15)); n=0; while [ \$SECONDS -lt \$end ]; do n=\$($HOLD_READ | grep -ac 'P-EFD-HOLD start='); [ \$n -gt 0 ] && break; sleep 0.5; done; echo HOLD_SEEN=\$n; echo HOLD_RING_MARK=\$(dmesg | grep -c '$MARK\$')"
HOLD_SEEN=$(field "$OUT/S_hold.txt" HOLD_SEEN)
echo "STAGE hold seen=$HOLD_SEEN at +$(el)s"
# the hold read's own exposure: the ring had lost the mark by the time the hold was looked for
[ "$(field "$OUT/S_hold.txt" HOLD_RING_MARK)" = 0 ] && echo "HOLD-RING-ROTATED: $S's kernel ring no longer held the lap's mark when the hold was looked for"

# ---- 4. the run, then both loads stopped
sleep $(( HOLD_MS / 1000 + 30 ))
for n in "$S" "$R"; do
    measure "$n" 60 "$OUT/${n}_load.txt" '^LOADREC_END$' "$n's load record" \
        "touch $LD.stop; for t in \$(seq 1 45); do grep -q '^PATHLOAD ' $LD.out 2>/dev/null && break; sleep 1; done; grep '^PATHLOAD ' $LD.out; awk '{ d=\$2-\$1; if (d>m) m=d } END { print \"MAXOP_MS=\" m+0 }' $LD/ops.log; grep -c ' ERR ' $LD/ops.log | sed 's/^/ERRS=/'; echo LOADREC_END"
done
rs 15 "$S" "echo 0 > $PARM/dbg_efd_hold_ms" > /dev/null 2>&1
for n in "$S" "$R"; do
    echo "STAGE $n: $(grep -a '^PATHLOAD ' "$OUT/${n}_load.txt" | cut -c1-200) max_op_ms=$(field "$OUT/${n}_load.txt" MAXOP_MS)"
done
MAX_MS=$(for n in "$S" "$R"; do field "$OUT/${n}_load.txt" MAXOP_MS; done | sort -n | tail -1)
echo "max_stall_ms=${MAX_MS:-0}"

unread=""
for n in "$S" "$R"; do
    if [ "$FOLLOW" = 1 ]; then
        measure "$n" 30 "$OUT/${n}_kmsg.txt" '^KMSG_END$' "$n's kernel log since the mark" \
            "echo '$MARK-END' > /dev/kmsg; sleep 1; kill \$(cat $KL.pid) 2>/dev/null; awk '/$MARK\$/{f=1} f' $KL | cut -c1-700; echo KMSG_END"
    else
        measure "$n" 30 "$OUT/${n}_kmsg.txt" '^KMSG_END$' "$n's kernel log since the mark" \
            "echo '$MARK-END' > /dev/kmsg; dmesg | sed -n '/$MARK\$/,\$p' | cut -c1-700; echo KMSG_END"
    fi
    grep -aq "$MARK\$" "$OUT/${n}_kmsg.txt" && grep -aq "$MARK-END\$" "$OUT/${n}_kmsg.txt" \
        || unread="$unread $n's read holds $(grep -vac '^KMSG_END$' "$OUT/${n}_kmsg.txt") line(s) and not both the lap's marks;"
    # the read's own exposure: the ring no longer holds the lap's mark, so a read of the ring
    # afterwards cannot hold it
    ring=$(rs 20 "$n" "dmesg | grep -c '$MARK\$'")
    [ "${ring:-0}" = 0 ] && echo "RING-ROTATED: $n's kernel ring no longer holds the lap's mark"
done
[ -z "$unread" ] && echo "KMSG-WHOLE: both nodes' kernel log reads hold both of the lap's marks"
grep -a 'P-EFD-HOLD\|P-NOINO-DRAIN\|P-NOINO-CONVOY\|P-NOINO-RELFENCE\|P-AILMIN\|Shutting down\|no longer responding' "$OUT/${S}_kmsg.txt" "$OUT/${R}_kmsg.txt" \
    | sed 's/.*mxfs: /    /' | cut -c1-260 | head -20
if [ "$HOLD_FOLLOW" = 0 ] && [ "$HOLD_SEEN" != 1 ]; then
    echo "  S's EFD hold never started, so no chain was held"
    echo "RESULT: VACUOUS label=$LABEL stage=hold wall=$(el)s evidence=$OUT"; exit 3
fi
# a read that is not whole grades nothing, so it is judged before any VACUOUS exit
if [ -n "$unread" ]; then
    echo "LAP noino_fence_efd_hold FAIL: the lap read no whole kernel log, so it cannot say whether S's fence met the held chain:$unread"
    echo "RESULT: FAIL label=$LABEL stage=kmsg wall=$(el)s evidence=$OUT"; exit 1
fi
if [ "$HOLD_SEEN" != 1 ]; then
    echo "  S's EFD hold never started, so no chain was held"
    echo "RESULT: VACUOUS label=$LABEL stage=hold wall=$(el)s evidence=$OUT"; exit 3
fi
FENCE_N=$(cnt "$OUT/${S}_kmsg.txt" 'P-NOINO-DRAIN-RETRY\|P-NOINO-CONVOY\|P-NOINO-DRAIN-STUCK\|P-AILMIN')
if [ "$FENCE_N" = 0 ]; then
    echo "  S's no-inode fence never met the held chain, so nothing here measures it"
    echo "RESULT: VACUOUS label=$LABEL stage=no-fence wall=$(el)s evidence=$OUT"; exit 3
fi
echo "EXPOSED: S held an EFD for ${HOLD_MS} ms and its no-inode fence met the frozen minimum ($FENCE_N line(s))"

# ---- 5. the verdict
ck "S's fence did not give up" "$(cnt "$OUT/${S}_kmsg.txt" 'P-NOINO-DRAIN-STUCK\|P-NOINO-RELFENCE-WEDGE')" 0
ck "S shut nothing down" "$(cnt "$OUT/${S}_kmsg.txt" 'Shutting down filesystem')" 0
for n in "$S" "$R"; do
    ck "$n's load reported" "$(cnt "$OUT/${n}_load.txt" '^PATHLOAD ')" 1
    ck "$n's load: no operation failed" "$(field "$OUT/${n}_load.txt" ERRS)" 0
    # A load that printed no report has no double_grant field: the check above has already
    # failed it, and judging the empty field ABORTed the lap, which lost the verdict of every
    # lap whose S shut down (D-NOINO-LAP-ABORTS-ON-AN-EMPTY-FIELD-WHEN-S-SHUTS-DOWN).
    # NOINO_LAP_JUDGE_MISSING=1 judges it anyway, as before: the control.
    if [ "$(cnt "$OUT/${n}_load.txt" '^PATHLOAD ')" = 1 ] || [ "${NOINO_LAP_JUDGE_MISSING:-0}" = 1 ]; then
        ck "$n's load: no double grant" "$(field "$OUT/${n}_load.txt" double_grant)" 0
    else
        echo "  INFO $n's load printed no report, so its double grants are not read (failed above)"
    fi
    measure "$n" 30 "$OUT/${n}_after.txt" '^AFTER_END$' "$n still mounted and writable" \
        "grep -c ' $MNT ' /proc/mounts | sed 's/^/MOUNTED=/'; timeout 20 sh -c 'printf after > $D/after_$n && sync -f $MNT' && echo WROTE; echo AFTER_END"
    ck "$n is still mounted" "$(field "$OUT/${n}_after.txt" MOUNTED)" 1
    ck "$n still writes" "$(cnt "$OUT/${n}_after.txt" '^WROTE$')" 1
    # a dynamic-debug line reads "DEBUG:", which a bare 'BUG:' also matches
    ck "$n: zero BUG / Oops" "$(cnt "$OUT/${n}_kmsg.txt" '^BUG:\|[^E]BUG:\|kernel BUG at\|Oops')" 0
done

if [ $fails = 0 ]; then
    echo "LAP noino_fence_efd_hold PASS: S held an EFD ${HOLD_MS} ms under load through no-inode releases and stayed up; longest operation ${MAX_MS} ms"
else
    echo "LAP noino_fence_efd_hold FAIL: $fails check(s) failed (max_op_ms=${MAX_MS:-0})"
fi
echo "RESULT: $( [ $fails = 0 ] && echo PASS || echo FAIL ) label=$LABEL fails=$fails wall=$(el)s evidence=$OUT"
[ $fails = 0 ]
