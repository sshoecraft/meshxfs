#!/bin/bash
# reap_inactive_mount_ab.sh — same-build A/B of reap_active_gate: do the reap
# worker's grant-taking duties run inside a mount the VFS has not made active?
#
# Measured on 2/net/mesh/mpath (run 20261020T142123Z-g2d, test32's rejoin,
# D-FAILED-MOUNT-UNWIND-RACES-REAP-WORKER-FREES-AG-AND-HANGS): the worker's
# mount-settle timer fired 20 s into a mount that was still waiting on its
# peer, its unclaimed-bucket scan waited in an AG grant inside that mount, the
# mount failed, its unwind freed the AG groups under the scan's reference and
# then waited for the worker without end.
#
# Each arm: <node> unmounts (its peer stays mounted), the knobs are set on it
# (reap_active_gate=<arm>, dbg_admission_delay_ms=$HOLD_MS, which is past the
# 20 s timer, and dbg_admission_refuse=1), and it mounts: the mount is held
# before its admission commit, the timer fires inside it, and the refusal sends
# it down the unwind.  Then it mounts again with the defaults.
#
# The rules, written before the first lap:
#   both arms: the hold and the refusal fired (P-DBG-ADMISSION-DELAY,
#     P291-ADMISSION-REFUSE-INJECTED), else VACUOUS; the refused mount returned
#     inside its bound and left nothing mounted; no BUG, Oops or hung task in
#     the arm's kernel log; the remount with the defaults succeeded.
#   CONTROL (reap_active_gate=0): P-REAP-INACTIVE-RAN >= 1, the duties ran
#     inside the held mount (the cause, reproduced), else VACUOUS.
#   FIX (reap_active_gate=1): P-REAP-INACTIVE-DEFER >= 1 and no
#     P-REAP-INACTIVE-RAN.
#
# A refused mount leaves its heartbeat slot ACTIVE on purpose: its peer fences
# that incarnation and replays its slice.  A mount from the same host before
# that ends is fenced with it (the PR key is the host's; measured in lap riaa,
# fix arm: P290-AUTH-CLOSED reason=PR_CONFLICT_FENCED 7 s into the mount), so
# after each refused mount the lap waits for <peer> to log the recovery's
# completion (P-COMPLETE-RETIRE-TIMING ... why=recovery-complete) before it
# mounts again.
#
# MODE=open: the same-build A/B of freplay_redrive_ready_gate
# (D-REAP-WORKER-QUEUES-UNINITIALISED-FOREIGN-REPLAY-WORK-INSIDE-SLOW-MOUNT).
# The mount barrier notes a synthetic OPEN obligation case for unused slot 62
# and holds the mount inside xfs_mountfs for $HOLD_MS (dbg_barrier_open_hold_ms,
# past the reap worker's 20 s mount-settle timer), then takes the case back and
# the mount goes on; nothing is refused.  The fix arm runs first: the control is
# expected to queue the foreign replay work before mxfs_dlm_cache_init has
# initialised it, and a kworker calling its NULL function oopses the node, which
# is power-cycled after the lap.  Rules, written before the first lap:
#   both arms: P-DBG-BARRIER-OPEN-HOLD and P-DBG-BARRIER-OPEN-HOLD-END fired,
#     else VACUOUS.
#   FIX (gate=1): P-FREPLAY-REDRIVE-WAIT >= 1 (the re-drive met the hold), no
#     P-FREPLAY-QUEUE-UNINIT, no BUG, Oops or hung task, and the mount
#     completed (mounted=1).
#   CONTROL (gate=0): P-FREPLAY-QUEUE-UNINIT >= 1 (the cause, reproduced), else
#     VACUOUS; the BUG/Oops count is recorded, not graded.
#
# MODE=failkick: the same-build A/B of mountfs_unwind_quiesce
# (D-FAILED-MOUNT-LEAVES-DESTAGE-AND-ALLOCLIST-RETRY-WORK-QUEUED-PAST-FREE).
# dbg_mountfs_fail_kick_ms arms the destage kick and the alloc-list retry with
# $KICK_MS delay at the end of xfs_mountfs and fails the mount down its ordinary
# unwind.  The fix arm runs first: the control is expected to free the mount
# with both works still queued, and their run $KICK_MS later touches freed
# memory, so the node is power-cycled after the lap.  Rules, written before
# the first lap:
#   both arms: P-DBG-MOUNTFS-FAIL-KICK fired, else VACUOUS; the mount failed
#     and left nothing mounted, inside its bound.
#   FIX (quiesce=1): P-MOUNTFS-UNWIND-QUIESCE >= 1, no P-MOUNT-FREE-WORK-PENDING,
#     no BUG, Oops or general protection fault in the kernel log $SETTLE_S s
#     after the mount returned, and the node mounts again with the defaults
#     once its peer has recovered the failed incarnation.
#   CONTROL (quiesce=0): P-MOUNT-FREE-WORK-PENDING >= 1 (the cause,
#     reproduced), else VACUOUS; what the late run did is recorded, not graded.
#
# Usage: [MODE=refuse|open|failkick] tests/reap_inactive_mount_ab.sh <cfg> <group> <node> <peer> <tag>
#   e.g. tests/reap_inactive_mount_ab.sh 2/net/mesh/direct g2c test30 test29 riab
# <peer>, the other node of <group>, stays mounted through the lap.
#
# Budget (derived, a timeout is a failure): prep 72-137 s measured, bounded at
# 280 s.  Per arm: unmount bounded at 25 s; the held mount is its own setup
# (2-5 s measured with a peer present) + HOLD_MS (30 s) + the unwind (seconds),
# bounded at 75 s; the kernel-log capture 30 s; the peer's recovery of the
# refused incarnation is its dead-confirm window (34 s printed, bound_ms=94000)
# plus the fence and replay, waited for at most 150 s; the remount, which may
# itself wait out that barrier, bounded at 130 s.
set -u
CFG=${1:?configuration}; GROUP=${2:?rig group}; NODE=${3:?node}; PEER=${4:?peer}; TAG=${5:?tag}
cd "$(dirname "$0")/.." || exit 2
LABEL=$TAG
OUT=tests/evidence/reap_inactive_mount_ab/$TAG
mkdir -p "$OUT" || exit 2
HOLD_MS=${HOLD_MS:-30000}
MODE=${MODE:-refuse}
case $MODE in refuse) ARMS="control fix" ;; open|failkick) ARMS="fix control" ;; *) echo "MODE must be refuse, open or failkick"; exit 2 ;; esac
# failkick: the delay the injected works are armed with, and how long after
# the failed mount returns the kernel log is read (the works run KICK_MS after
# the end of xfs_mountfs; the unwind and the free take about a second)
KICK_MS=${KICK_MS:-3000}
SETTLE_S=${SETTLE_S:-6}
KNOB=/sys/module/mxfs/parameters
fails=0
vac=""
. "$(dirname "$0")/lib/rig.sh"
field(){ grep -aoE "(^| )$2=[^ ]*" "$1" | head -1 | cut -d= -f2; }
SV=$(modinfo -F srcversion mxfs.ko)
echo "=== reap_inactive_mount_ab mode=$MODE cfg=$CFG group=$GROUP node=$NODE tag=$TAG hold=${HOLD_MS}ms tree=$SV $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 timeout 280 ./run.sh "$CFG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 < /dev/null
prc=$?
echo "STAGE prep rc=$prc $(grep -am1 'prep_cluster OK\|FAIL' "$OUT/prep.log" | cut -c1-140)"
[ "$prc" = 0 ] || { echo "RESULT: ABORT label=$TAG stage=prep evidence=$OUT"; exit 2; }

measure "$NODE" 20 "$OUT/ident.txt" '^IDENT ' "the device and build on $NODE" \
    "echo IDENT sv=\$(cat /sys/module/mxfs/srcversion) dev=\$(awk '\$2==\"$MNT\" && \$3==\"mxfs\"{print \$1}' /proc/mounts)"
DEV=$(field "$OUT/ident.txt" dev)
ck "$NODE runs the tree's build" "$(field "$OUT/ident.txt" sv)" "$SV"
[ -n "$DEV" ] || { echo "ABORT: $NODE has no mxfs mount at $MNT after the prep"; echo "RESULT: ABORT label=$TAG stage=device evidence=$OUT"; exit 2; }
echo "STAGE device $DEV"

for arm in $ARMS; do
    case $arm in control) gate=0 ;; fix) gate=1 ;; esac
    if [ "$MODE" = open ]; then
        M=$OUT/$arm
        mkdir -p "$M"
        MARK="RIA-$TAG-$arm"
        measure "$NODE" 40 "$M/umount.txt" '^UMOUNT ' "the unmount of $NODE for arm $arm" \
            "rc=0; grep -q ' $MNT ' /proc/mounts && { timeout 25 umount $MNT || rc=\$?; }
             echo UMOUNT rc=\$rc still=\$(grep -c ' $MNT ' /proc/mounts)"
        ck "[$arm] $NODE unmounted" "$(field "$M/umount.txt" still)" 0
        [ "$(field "$M/umount.txt" still)" = 0 ] || { echo "RESULT: ABORT label=$TAG stage=umount:$arm evidence=$OUT"; exit 2; }
        measure "$NODE" 20 "$M/knobs.txt" '^KNOBS ' "the knob arming on $NODE for arm $arm" \
            "echo $MARK > /dev/kmsg
             echo $gate > $KNOB/freplay_redrive_ready_gate
             echo $HOLD_MS > $KNOB/dbg_barrier_open_hold_ms
             echo KNOBS gate=\$(cat $KNOB/freplay_redrive_ready_gate) hold=\$(cat $KNOB/dbg_barrier_open_hold_ms)"
        ck "[$arm] freplay_redrive_ready_gate reads back" "$(field "$M/knobs.txt" gate)" "$gate"
        ck "[$arm] the hold is armed" "$(field "$M/knobs.txt" hold)" "$HOLD_MS"
        # the mount: its own setup (2-5 s with a peer present) + HOLD_MS +
        # the rest of the mount (seconds), bounded at 75 s
        rsx 90 "$NODE" "s=\$(date +%s); rc=0; timeout 75 mount -t mxfs $DEV $MNT || rc=\$?
             echo MOUNT rc=\$rc secs=\$(( \$(date +%s) - s )) mounted=\$(grep -c ' $MNT ' /proc/mounts)" > "$M/mount.txt"
        measure "$NODE" 30 "$M/kmsg.txt" '^KMSG_END$' "the kernel log of arm $arm on $NODE" \
            "dmesg | sed -n '/$MARK/,\$p'; echo KMSG_END"
        hold=$(cnt "$M/kmsg.txt" 'P-DBG-BARRIER-OPEN-HOLD slot')
        hend=$(cnt "$M/kmsg.txt" 'P-DBG-BARRIER-OPEN-HOLD-END')
        wait_n=$(cnt "$M/kmsg.txt" 'P-FREPLAY-REDRIVE-WAIT')
        uninit=$(cnt "$M/kmsg.txt" 'P-FREPLAY-QUEUE-UNINIT')
        bad=$(cnt "$M/kmsg.txt" 'BUG:\|Oops\|blocked for more than\|xg_ref')
        echo "  STAGE [$arm] mount rc=$(field "$M/mount.txt" rc) secs=$(field "$M/mount.txt" secs) mounted=$(field "$M/mount.txt" mounted) hold=$hold hold_end=$hend redrive_wait=$wait_n queue_uninit=$uninit bad=$bad"
        [ "$hold" -ge 1 ] && [ "$hend" -ge 1 ] || vac="$vac [$arm] the barrier hold never fired (hold=$hold end=$hend)"
        if [ "$arm" = fix ]; then
            ckge "[fix] the re-drive waited for the replay work to be initialised" "$wait_n" 1
            ck "[fix] nothing queued the uninitialised work" "$uninit" 0
            ck "[fix] no BUG, Oops, hung task or AG reference assert" "$bad" 0
            ck "[fix] the held mount completed" "$(field "$M/mount.txt" mounted)" 1
        else
            [ "$uninit" -ge 1 ] || vac="$vac [control] nothing queued the uninitialised work, so the cause was not reached"
            echo "  STAGE [control] BUG/Oops lines after the queue: $bad (recorded, not graded)"
        fi
        continue
    fi
    if [ "$MODE" = failkick ]; then
        M=$OUT/$arm
        mkdir -p "$M"
        MARK="RIA-$TAG-$arm"
        measure "$NODE" 40 "$M/umount.txt" '^UMOUNT ' "the unmount of $NODE for arm $arm" \
            "rc=0; grep -q ' $MNT ' /proc/mounts && { timeout 25 umount $MNT || rc=\$?; }
             echo UMOUNT rc=\$rc still=\$(grep -c ' $MNT ' /proc/mounts)"
        ck "[$arm] $NODE unmounted" "$(field "$M/umount.txt" still)" 0
        [ "$(field "$M/umount.txt" still)" = 0 ] || { echo "RESULT: ABORT label=$TAG stage=umount:$arm evidence=$OUT"; exit 2; }
        rs 20 "$PEER" "echo $MARK > /dev/kmsg" >/dev/null
        measure "$NODE" 20 "$M/knobs.txt" '^KNOBS ' "the knob arming on $NODE for arm $arm" \
            "echo $MARK > /dev/kmsg
             echo $gate > $KNOB/mountfs_unwind_quiesce
             echo $KICK_MS > $KNOB/dbg_mountfs_fail_kick_ms
             echo KNOBS gate=\$(cat $KNOB/mountfs_unwind_quiesce) kick=\$(cat $KNOB/dbg_mountfs_fail_kick_ms)"
        ck "[$arm] mountfs_unwind_quiesce reads back" "$(field "$M/knobs.txt" gate)" "$gate"
        ck "[$arm] the failing kick is armed" "$(field "$M/knobs.txt" kick)" "$KICK_MS"
        # the mount: its own setup (2-5 s with a peer present) + the unwind
        # (seconds), bounded at 75 s; a mount stuck in D state is the hang
        rsx 90 "$NODE" "s=\$(date +%s); rc=0; timeout 75 mount -t mxfs $DEV $MNT || rc=\$?
             echo MOUNT rc=\$rc secs=\$(( \$(date +%s) - s )) mounted=\$(grep -c ' $MNT ' /proc/mounts)" > "$M/mount.txt"
        if grep -qa "^$RS_STATUS_TAG .* rc=124 " "$M/mount.txt"; then
            echo "  FAIL [$arm] the failing mount did not return inside 90 s (a hang)"; fails=$((fails+1))
        else
            capture_require "$M/mount.txt" '^MOUNT ' "the failing mount on $NODE for arm $arm"
            ck "[$arm] the failed mount left nothing mounted" "$(field "$M/mount.txt" mounted)" 0
        fi
        sleep "$SETTLE_S"
        measure "$NODE" 30 "$M/kmsg.txt" '^KMSG_END$' "the kernel log of arm $arm on $NODE" \
            "dmesg | sed -n '/$MARK/,\$p'; echo KMSG_END"
        kick=$(cnt "$M/kmsg.txt" 'P-DBG-MOUNTFS-FAIL-KICK')
        quiesce=$(cnt "$M/kmsg.txt" 'P-MOUNTFS-UNWIND-QUIESCE')
        pending=$(cnt "$M/kmsg.txt" 'P-MOUNT-FREE-WORK-PENDING')
        bad=$(cnt "$M/kmsg.txt" 'BUG:\|Oops\|general protection\|blocked for more than\|xg_ref')
        echo "  STAGE [$arm] mount rc=$(field "$M/mount.txt" rc) secs=$(field "$M/mount.txt" secs) kick=$kick quiesce=$quiesce free_pending=$pending bad=$bad"
        [ "$kick" -ge 1 ] || vac="$vac [$arm] the failing kick never fired"
        if [ "$arm" = fix ]; then
            ckge "[fix] the unwind cancelled the delayed works" "$quiesce" 1
            ck "[fix] the mount was not freed with a work still queued" "$pending" 0
            ck "[fix] no BUG, Oops, general protection fault or hung task" "$bad" 0
            w=0; rec=0
            while [ $w -lt 150 ]; do
                rec=$(rs 20 "$PEER" "dmesg | sed -n '/$MARK/,\$p' | grep -ac 'why=recovery-complete'" | tail -1)
                [ "${rec:-0}" -ge 1 ] 2>/dev/null && break
                sleep 5; w=$((w + 5))
            done
            echo "  STAGE [fix] $PEER recovery completions=${rec:-0} after ${w}s (recorded)"
            measure "$NODE" 150 "$M/remount.txt" '^REMOUNT ' "the remount with the defaults on $NODE" \
                "echo 1 > $KNOB/mountfs_unwind_quiesce; echo 0 > $KNOB/dbg_mountfs_fail_kick_ms
                 rc=0; grep -q ' $MNT ' /proc/mounts || { timeout 130 mount -t mxfs $DEV $MNT || rc=\$?; }
                 echo REMOUNT rc=\$rc mounted=\$(grep -c ' $MNT ' /proc/mounts)"
            ck "[fix] $NODE mounts again with the defaults" "$(field "$M/remount.txt" mounted)" 1
        else
            [ "$pending" -ge 1 ] || vac="$vac [control] the mount was not freed with a work queued, so the cause was not reached"
            echo "  STAGE [control] BUG/Oops/GPF lines after the free: $bad (recorded, not graded)"
            # the late run: past KICK_MS the queued works run on the freed
            # mount; read once more, recorded, not graded (the node may not
            # answer, and its console then holds what it printed)
            sleep $(( KICK_MS / 1000 + 5 - SETTLE_S ))
            rs 30 "$NODE" "dmesg | sed -n '/$MARK/,\$p'; echo KMSG_END" > "$M/kmsg_late.txt" 2>&1
            echo "  STAGE [control] late read: rc_lines=$(grep -c . "$M/kmsg_late.txt") bad=$(cnt "$M/kmsg_late.txt" 'BUG:\|Oops\|general protection\|blocked for more than\|xg_ref') (recorded, not graded)"
        fi
        continue
    fi
    M=$OUT/$arm
    mkdir -p "$M"
    MARK="RIA-$TAG-$arm"
    measure "$NODE" 40 "$M/umount.txt" '^UMOUNT ' "the unmount of $NODE for arm $arm" \
        "rc=0; grep -q ' $MNT ' /proc/mounts && { timeout 25 umount $MNT || rc=\$?; }
         echo UMOUNT rc=\$rc still=\$(grep -c ' $MNT ' /proc/mounts)"
    ck "[$arm] $NODE unmounted" "$(field "$M/umount.txt" still)" 0
    [ "$(field "$M/umount.txt" still)" = 0 ] || { echo "RESULT: ABORT label=$TAG stage=umount:$arm evidence=$OUT"; exit 2; }
    rs 20 "$PEER" "echo $MARK > /dev/kmsg" >/dev/null
    measure "$NODE" 20 "$M/knobs.txt" '^KNOBS ' "the knob arming on $NODE for arm $arm" \
        "echo $MARK > /dev/kmsg
         echo $gate > $KNOB/reap_active_gate
         echo $HOLD_MS > $KNOB/dbg_admission_delay_ms
         echo 1 > $KNOB/dbg_admission_refuse
         echo KNOBS gate=\$(cat $KNOB/reap_active_gate) hold=\$(cat $KNOB/dbg_admission_delay_ms) refuse=\$(cat $KNOB/dbg_admission_refuse)"
    ck "[$arm] reap_active_gate reads back" "$(field "$M/knobs.txt" gate)" "$gate"
    ck "[$arm] the hold is armed" "$(field "$M/knobs.txt" hold)" "$HOLD_MS"
    ck "[$arm] the refusal is armed" "$(field "$M/knobs.txt" refuse)" 1

    # a mount stuck in D state outlives the node's own timeout, so the bound
    # that judges it is this capture's: rc=124 here is the hang, a FAIL
    rsx 90 "$NODE" "s=\$(date +%s); rc=0; timeout 75 mount -t mxfs $DEV $MNT || rc=\$?
         echo MOUNT rc=\$rc secs=\$(( \$(date +%s) - s )) mounted=\$(grep -c ' $MNT ' /proc/mounts)" > "$M/mount.txt"
    if grep -qa "^$RS_STATUS_TAG .* rc=124 " "$M/mount.txt"; then
        echo "  FAIL [$arm] the refused mount did not return inside 90 s (a hang)"; fails=$((fails+1))
    else
        capture_require "$M/mount.txt" '^MOUNT ' "the held, refused mount on $NODE for arm $arm"
        echo "  STAGE [$arm] mount rc=$(field "$M/mount.txt" rc) secs=$(field "$M/mount.txt" secs) mounted=$(field "$M/mount.txt" mounted)"
        ck "[$arm] the refused mount left nothing mounted" "$(field "$M/mount.txt" mounted)" 0
    fi

    measure "$NODE" 30 "$M/kmsg.txt" '^KMSG_END$' "the kernel log of arm $arm on $NODE" \
        "dmesg | sed -n '/$MARK/,\$p'; echo KMSG_END"
    delay=$(cnt "$M/kmsg.txt" 'P-DBG-ADMISSION-DELAY')
    inj=$(cnt "$M/kmsg.txt" 'P291-ADMISSION-REFUSE-INJECTED')
    ran=$(cnt "$M/kmsg.txt" 'P-REAP-INACTIVE-RAN')
    defer=$(cnt "$M/kmsg.txt" 'P-REAP-INACTIVE-DEFER')
    bad=$(cnt "$M/kmsg.txt" 'BUG:\|Oops\|blocked for more than\|xg_ref')
    echo "  STAGE [$arm] delay=$delay injected=$inj inactive_ran=$ran inactive_defer=$defer bad=$bad"
    if [ "$delay" = 0 ] || [ "$inj" = 0 ]; then
        vac="$vac [$arm] the hold or the refusal never fired (delay=$delay injected=$inj)"
    fi
    ck "[$arm] no BUG, Oops, hung task or AG reference assert" "$bad" 0
    if [ "$arm" = control ]; then
        [ "$ran" -ge 1 ] || vac="$vac [control] no reap duty ran inside the held mount, so the cause was not reached"
    else
        ckge "[fix] the duties waited for the mount to be active" "$defer" 1
        ck "[fix] no duty ran inside the held mount" "$ran" 0
    fi

    w=0; rec=0
    while [ $w -lt 150 ]; do
        rec=$(rs 20 "$PEER" "dmesg | sed -n '/$MARK/,\$p' | grep -ac 'why=recovery-complete'" | tail -1)
        [ "${rec:-0}" -ge 1 ] 2>/dev/null && break
        sleep 5; w=$((w + 5))
    done
    echo "  STAGE [$arm] $PEER recovered the refused incarnation: completions=${rec:-0} after ${w}s"
    ckge "[$arm] $PEER completed the recovery of the refused mount's slot inside 150 s" "${rec:-0}" 1
    measure "$NODE" 150 "$M/remount.txt" '^REMOUNT ' "the remount with the defaults on $NODE" \
        "echo 1 > $KNOB/reap_active_gate; echo 0 > $KNOB/dbg_admission_delay_ms; echo 0 > $KNOB/dbg_admission_refuse
         rc=0; grep -q ' $MNT ' /proc/mounts || { timeout 130 mount -t mxfs $DEV $MNT || rc=\$?; }
         echo REMOUNT rc=\$rc mounted=\$(grep -c ' $MNT ' /proc/mounts)"
    ck "[$arm] $NODE mounts again with the defaults" "$(field "$M/remount.txt" mounted)" 1
done

if [ "$MODE" = open ] || [ "$MODE" = failkick ]; then
    # the control arm queued work on memory it did not own (open: a zeroed
    # work_struct; failkick: works of a freed mount): the node is power-cycled
    # so the next run starts on a sound kernel
    echo "STAGE power-cycle $NODE: $(scripts/lab_power.sh down "$NODE" > "$OUT/power_down.txt" 2>&1; echo down_rc=$?) $(scripts/lab_power.sh up "$NODE" > "$OUT/power_up.txt" 2>&1; echo up_rc=$?)"
fi
if [ -n "$vac" ]; then
    echo "  VACUOUS:$vac"
    echo "RESULT: VACUOUS label=$TAG fails=$fails evidence=$OUT"; exit 3
fi
echo "RESULT: $( [ $fails = 0 ] && echo PASS || echo FAIL ) label=$TAG fails=$fails evidence=$OUT"
[ $fails = 0 ]
