#!/bin/bash
# late_register_hold_lap.sh — one lap of
# D-LATE-PATH-REGISTER-TIMED-OUT-MAY-EXECUTE-AFTER-A-FENCE-AND-RESTORE-THE-KEY.
#
# A path that was down when a node mounted is registered later by the
# late-path fill (mxfs_pal_scsi_pr_fill_paths).  A REGISTER whose outcome the
# node never learns can still execute at the target after a peer's PREEMPT AND
# ABORT and put the fenced key back on that nexus; the fill then takes the path
# offline, which keeps the node's later requests off it, but a write multipath
# had already sent down the path behind the REGISTER would execute with the key
# registered again.  The fix holds the late path to the fill's own commands
# (scsi_device_quiesce, power-management requests only) from before the
# REGISTER until its outcome is known; pr_fill_hold=0 sends the REGISTER down a
# path multipath may be writing through, as before: the control.
#
# What the lap measures is the cause, not the consequence: how many commands
# the node dispatches down the late path while a REGISTER on it is unresolved.
# A REGISTER held at the target past a fence is not reproduced; the module's
# TEST ONLY knob dbg_pr_fill_outstanding_ms keeps the REGISTER the fill just
# issued unresolved for OUT_MS after it returns, and prints
# P-DBG-PR-FILL-OUTSTANDING with requests_sent, the path's iorequest_cnt
# delta across that time (scsi_dispatch_cmd counts every command dispatched
# down the path, so the fill's own sleeping thread adds none).
#
# The steps are path_mount_degraded's 1-3 (tests/mpath/path_mount_degraded.sh)
# with a load on the victim: the victim (last node) unmounts, its path a is
# taken down and failed, it mounts on path b alone, its load starts, the knob
# is armed, path a is restored, and the lap waits for the fill's line.  It then
# waits for path a to be usable, stops the load, checks the target holds the
# victim's key on both paths, and unmounts and mounts the victim on both paths,
# so the next lap starts from the same pair.
#
#   EXPOSED  the fill's REGISTER was held unresolved OUT_MS while the victim's
#            load completed operations through the map (requests had a path to
#            take), for longer than multipathd needs to reinstate a path
#   PASS     held=1, writes_done=0 and requests_sent=0, the victim's key on
#            both paths afterwards, the load clean and within the stall bound
#   FAIL     writes_done > 0 (writes the node sent down the late path while
#            its REGISTER was unresolved: the hazard), or requests_sent > 0
#            (any command, a path checker's TEST UNIT READY included)
# The module prints writes_done from the path's disk statistics, which count
# what multipath clones onto it; a lap that cannot read them is UNMEASURED.
#
# LRH_ARM is written to every node's pr_fill_hold once its log is followed
# (PF_KNOBS): 1 is the fix, 0 the control.  pr_fill_bounded=1 on both arms
# (the hold applies only to a bounded fill).
#
# Usage, on a formed multipath pair, with the environment run.sh hands a path
# row (MXFS_NODES, MXFS_NODE_LIST, MXFS_CONFIG, MXFS_DEV when not mpatha):
#   tests/late_register_hold_lap.sh <label> <arm>
# Env: LRH_OUT_MS (15000), LRH_FILL_S (20).
# Bound, derived: BOUND_S below.
# Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
set -u
cd "$(dirname "$0")/.." || { echo "UNMEASURED: no tree"; exit 2; }
OUT_MS=${LRH_OUT_MS:-15000}
FILL_S=${LRH_FILL_S:-20}
if [ "${1:-}" = --row ]; then
    ROW=late_register_hold
    # shellcheck source=tests/mpath/lib.sh
    . tests/mpath/lib.sh
    PF_KNOBS="pr_fill_bounded=1 pr_fill_hold=${LRH_ARM:?}"
    pf_start_gate
    um() {  # <tag>: the victim's unmount, bounded
        measure "$V" 70 "$OUT/umount_$1.txt" '^UMOUNT_RC=[0-9]+ ms=[0-9]+ mounted=[01]$' "the victim's unmount ($1)" \
            "s=\$(date +%s%3N); timeout 60 umount $MNT; rc=\$?; e=\$(date +%s%3N); grep -q ' $MNT mxfs ' /proc/mounts && m=1 || m=0; echo UMOUNT_RC=\$rc ms=\$((e-s)) mounted=\$m"
        echo "  INFO $1: $(grep -a '^UMOUNT_RC=' "$OUT/umount_$1.txt" | head -1)"
    }
    mo() {  # <tag>: the victim's mount, bounded
        measure "$V" 70 "$OUT/mount_$1.txt" '^MOUNT_RC=[0-9]+ ms=[0-9]+ mounted=[01]$' "the victim's mount ($1)" \
            "s=\$(date +%s%3N); timeout 60 mount -t mxfs $MOPT $DEV $MNT; rc=\$?; e=\$(date +%s%3N); grep -q ' $MNT mxfs ' /proc/mounts && m=1 || m=0; echo MOUNT_RC=\$rc ms=\$((e-s)) mounted=\$m"
        echo "  INFO $1: $(grep -a '^MOUNT_RC=' "$OUT/mount_$1.txt" | head -1)"
    }
    wait_failed() {  # <tag>: until the victim sees 1 usable path, bound 40 s
        local s=$SECONDS u
        while [ $((SECONDS - s)) -lt 40 ]; do
            state "$V" "$1"; u=$(usable "$OUT/state_${V}_$1.txt")
            [ "${u:-2}" = 1 ] && { echo $((SECONDS - s)); return 0; }
            sleep 2
        done
        echo 999
    }
    # multipathd's checker interval: the window must outlast it, or the
    # control has no reinstated path to send anything down
    pi=$(rs 15 "$V" "multipathd show config 2>/dev/null | sed -n 's/^[[:space:]]*polling_interval[[:space:]]\\+\\([0-9]\\+\\).*/\\1/p' | head -1" 2>/dev/null | tr -dc '0-9')
    echo "  INFO $V polling_interval=${pi:-unread} s, outstanding window ${OUT_MS} ms, pr_fill_hold=$LRH_ARM"
    [ -n "$pi" ] && [ $(( pi * 1000 * 2 )) -lt "$OUT_MS" ] \
        || { echo "UNMEASURED: the window (${OUT_MS} ms) is not over twice multipathd's checker interval (${pi:-unread} s)"; exit 2; }

    um leave_two_paths
    grep -q '^UMOUNT_RC=0 .*mounted=0' "$OUT/umount_leave_two_paths.txt" || { echo "UNMEASURED: the victim did not unmount"; exit 2; }
    link "$V" a down
    fa=$(wait_failed a_failed)
    [ "$fa" != 999 ] || { link "$V" a up; echo "UNMEASURED: multipathd did not fail the victim's path a in 40 s"; exit 2; }
    mo join_one_path
    grep -q '^MOUNT_RC=0 .*mounted=1' "$OUT/mount_join_one_path.txt" || { link "$V" a up; echo "UNMEASURED: the victim did not mount on one path"; exit 2; }
    keys joined1
    k1=$(grep -c . "$OUT/keys_joined1.txt")
    echo "  INFO keys with the victim mounted on one path: $k1 (want $(( 2 * N - 1 )))"
    [ "$k1" = $(( 2 * N - 1 )) ] || { link "$V" a up; echo "UNMEASURED: the victim's one-path mount left $k1 keys at the target, not $(( 2 * N - 1 ))"; exit 2; }

    PF_WARM_S=5 pf_load_start "$V"
    got=$(rs 15 "$V" "echo $OUT_MS > /sys/module/mxfs/parameters/dbg_pr_fill_outstanding_ms && cat /sys/module/mxfs/parameters/dbg_pr_fill_outstanding_ms" 2>/dev/null | tr -dc '0-9')
    ck "the victim took dbg_pr_fill_outstanding_ms=$OUT_MS" "${got:-unread}" "$OUT_MS"
    [ "$fails" = 0 ] || { link "$V" a up; finish FAIL "stage=knob"; exit 1; }

    link "$V" a up
    # the session's relogin (up to 20 s at the 5 s path timescale), the fill's
    # next tick (0.5 s), the window, and 10 s of slack
    s=$SECONDS; line=""
    while [ $((SECONDS - s)) -le $(( 30 + OUT_MS / 1000 )) ]; do
        line=$(rs 15 "$V" "sed -n '/$PFMARK/,\$p' $KFILE | grep -a 'P-DBG-PR-FILL-OUTSTANDING' | tail -1" 2>/dev/null)
        [ -n "$line" ] && break
        sleep 1
    done
    t1=$(now_ms)
    [ -n "$line" ] || { echo "UNMEASURED: no P-DBG-PR-FILL-OUTSTANDING line in $(( 30 + OUT_MS / 1000 )) s after path a came back"; exit 2; }
    echo "  KMSG $(sed 's/.*mxfs: //' <<<"$line" | cut -c1-240)"
    sent=$(sed -n 's/.* requests_sent=\(-\?[0-9]*\).*/\1/p' <<<"$line")
    wdone=$(sed -n 's/.* writes_done=\(-\?[0-9]*\).*/\1/p' <<<"$line")
    [ -n "$wdone" ] && [ "$wdone" -ge 0 ] \
        || { echo "UNMEASURED: the module could not read the late path's write count (writes_done=${wdone:-?})"; exit 2; }
    held=$(sed -n 's/.* held=\([01]\) .*/\1/p' <<<"$line")
    rrc=$(sed -n 's/.* register_rc=\(-\?[0-9]*\) .*/\1/p' <<<"$line")
    # the window ended at most 1 s before the line was read
    pf_window outstanding $(( t1 - 1000 - OUT_MS )) $(( t1 - 1000 )) "$V"
    win=$(awk '$1 == "outstanding"' "$OUT/stalls.txt" | sed -n 's/.*completed_in_window=\([0-9]*\).*/\1/p' | tail -1)
    [ "${win:-0}" -gt 0 ] && [ "$rrc" = 0 ] \
        || { echo "UNMEASURED: the window held no load to route (completed_in_window=${win:-?}) or the REGISTER did not answer GOOD (register_rc=${rrc:-?})"; exit 2; }
    echo "EXPOSED: the fill's REGISTER was held unresolved ${OUT_MS} ms (over twice the ${pi} s checker interval) while $V's load completed $win operations through the map"

    ra=$(wait_usable "$V" a_back)
    [ "$ra" != 999 ] || echo "  INFO multipathd did not reinstate path a in 60 s after the window"
    pf_load_stop "$V"
    s=$SECONDS; filled=""
    while [ $((SECONDS - s)) -le "$FILL_S" ]; do
        keys fill
        [ "$(grep -c . "$OUT/keys_fill.txt")" = $(( 2 * N )) ] && { filled=$((SECONDS - s)); break; }
        sleep 1
    done
    ck "the target holds the victim's key on both paths after the window" "$([ -n "$filled" ] && echo yes || echo no)" yes
    ck "the late path was held while its REGISTER was unresolved (held)" "${held:-?}" 1
    ck "no write of the node completed on the late path while its REGISTER was unresolved (writes_done)" "$wdone" 0
    ck "the node dispatched nothing down the late path while its REGISTER was unresolved (requests_sent)" "${sent:-?}" 0

    um leave_after
    mo rejoin_two_paths
    keys rejoined
    echo "  INFO keys after the victim's remount on two paths: $(grep -c . "$OUT/keys_rejoined.txt") (want $(( 2 * N )))"
    if [ "$fails" = 0 ]; then
        trap kmsg_stop EXIT
        echo "LAP late_register_hold PASS nothing was dispatched down the late path in the ${OUT_MS} ms its REGISTER was held unresolved"
        exit 0
    fi
    echo "LAP late_register_hold FAIL $fails check(s): writes_done=$wdone requests_sent=${sent:-?} held=${held:-?} ($why)"
    exit 1
fi
label=${1:?usage: tests/late_register_hold_lap.sh <label> <arm>}
arm=${2:?usage: tests/late_register_hold_lap.sh <label> <arm>}
: "${MXFS_NODES:?}" "${MXFS_NODE_LIST:?}"
# The start gate ~12 s at 2 nodes; the unmount ~1 s; path a failed by
# multipathd in up to 20 s; the mount ~5 s; the load's start, clock reads and
# 5 s warm-up ~10 s; the relogin up to 20 s, the window, then the load's
# window read ~3 s; path a reinstated in up to 20 s; the load's stop ~5 s;
# FILL_S; the unmount and the two-path mount ~10 s; the EXIT trap's copies
# ~2 s.  About 110 s plus the window at 2 nodes: twice that, plus 12 s for
# each node past two at the gate.
BOUND_S=$(( 2 * (110 + ${LRH_OUT_MS:-15000} / 1000) + FILL_S + 12 * (MXFS_NODES - 2) ))
run_id="${label}_$(date -u +%Y%m%dT%H%M%SZ)"
LRH_ARM=$arm MXFS_RUN_ID=$run_id timeout "$BOUND_S" "$0" --row
rc=$?
[ "$rc" = 124 ] && echo "UNMEASURED: the lap ran out its ${BOUND_S}s bound"
exit "$rc"
