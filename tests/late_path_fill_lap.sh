#!/bin/bash
# late_path_fill_lap.sh — one lap of
# D-MPATH-MOUNT-DEGRADED-12S-WINDOW-REGISTRATION-MISSING-AND-SHUTDOWNS.
#
# A path that is down when a node mounts gets no registration of the node's
# key then; the late-path fill (v5_pr_fill_tick, mxfs_pal_scsi_pr_fill_paths)
# registers it once it answers.  The fill ran only with 15 s of the authority
# lease left, and a 12 s death window gives an 8 s lease, so it never ran: the
# path came back unregistered, multipath sent writes down it, the target
# refused them, and path_mount_degraded failed at 2 and 4 nodes.
#
# The lap is path_mount_degraded's steps 1-3 (tests/mpath/path_mount_degraded.sh)
# on a formed multipath pair whose module carries a death window under 19 s,
# with no load on the victim: the victim (last node) unmounts, its path a is
# taken down and failed, it mounts on path b alone, path a is restored and
# reinstated, and the lap waits FILL_S for the target to hold the victim's key
# on both paths.  It then unmounts the victim and mounts it again on both
# paths, so the next lap starts from the same pair.
#
#   EXPOSED  the victim mounted registered on one path only (2N-1 keys at the
#            target), with a lease under the 15 s the earlier admission needed
#   PASS     the target holds 2N keys within FILL_S of path a's reinstatement
#   FAIL     it does not
#
# LPF_ARM is written to every node's pr_fill_bounded once its log is followed
# (PF_KNOBS): 1 is the fix, 0 the earlier admission (the control).
#
# Usage, on a formed multipath pair, with the environment run.sh hands a path
# row (MXFS_NODES, MXFS_NODE_LIST, MXFS_CONFIG, MXFS_DEV when not mpatha):
#   tests/late_path_fill_lap.sh <label> <arm>
# Bound, derived: BOUND_S below.
# Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
set -u
cd "$(dirname "$0")/.." || { echo "UNMEASURED: no tree"; exit 2; }
FILL_S=${LPF_FILL_S:-20}
if [ "${1:-}" = --row ]; then
    ROW=late_path_fill
    # shellcheck source=tests/mpath/lib.sh
    . tests/mpath/lib.sh
    PF_KNOBS="pr_fill_bounded=${LPF_ARM:?}"
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
    dt=$(rs 15 "$V" "cat /sys/module/mxfs/parameters/dead_timeout_ms" 2>/dev/null | tr -dc '0-9')
    echo "  INFO $V dead_timeout_ms=${dt:-unread} pr_fill_bounded=$LPF_ARM"
    [ -n "$dt" ] && [ "$dt" -gt 0 ] && [ "$dt" -lt 19000 ] \
        || { echo "UNMEASURED: the victim's death window (${dt:-unread} ms) leaves a lease of 15 s or more, which the earlier admission also fills"; exit 2; }

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
    echo "EXPOSED: $V mounted registered on one path ($k1 of $(( 2 * N )) keys) with a $(( dt - 4000 )) ms lease, under the 15 s the earlier admission needed"

    link "$V" a up
    ra=$(wait_usable "$V" a_back)
    [ "$ra" != 999 ] || { echo "UNMEASURED: multipathd did not reinstate path a in 60 s"; exit 2; }
    s=$SECONDS; filled=""
    while [ $((SECONDS - s)) -le "$FILL_S" ]; do
        keys fill
        [ "$(grep -c . "$OUT/keys_fill.txt")" = $(( 2 * N )) ] && { filled=$((SECONDS - s)); break; }
        sleep 1
    done
    # dmesg --follow writes the whole ring before it follows, so only the lines
    # after this row's mark are this lap's
    rs 15 "$V" "sed -n '/$PFMARK/,\$p' $KFILE | grep -a 'P-PR-PATH-FILL\|P-PR-PATH-QUARANT\|P-PR-FILL-FENCED\|P277-RESV-CONFLICT\|P-WITHDRAW' | tail -6" > "$OUT/fill_lines.txt" 2>/dev/null
    sed 's/^/  KMSG /' "$OUT/fill_lines.txt"
    k2=$(grep -c . "$OUT/keys_fill.txt")

    um leave_after
    mo rejoin_two_paths
    keys rejoined
    echo "  INFO keys after the victim's remount on two paths: $(grep -c . "$OUT/keys_rejoined.txt") (want $(( 2 * N )))"
    if [ -n "$filled" ]; then
        trap kmsg_stop EXIT
        echo "LAP late_fill PASS the target held the victim's key on both paths ${filled}s after path a was reinstated (${ra}s)"
        exit 0
    fi
    echo "LAP late_fill FAIL the target held $k2 keys, not $(( 2 * N )), ${FILL_S}s after the victim's path a was reinstated (${ra}s)"
    exit 1
fi
label=${1:?usage: tests/late_path_fill_lap.sh <label> <arm>}
arm=${2:?usage: tests/late_path_fill_lap.sh <label> <arm>}
: "${MXFS_NODES:?}" "${MXFS_NODE_LIST:?}"
# The start gate ~12 s at 2 nodes; the unmount ~1 s; path a failed by
# multipathd in up to 20 s at the 5 s path timescale (40 s bound); the mount
# ~5 s; path a reinstated in up to 20 s; FILL_S; the unmount and the two-path
# mount ~10 s; the EXIT trap's copies ~2 s.  About 90 s at 2 nodes: twice
# that, plus 12 s for each node past two at the gate.
BOUND_S=$(( 180 + FILL_S + 12 * (MXFS_NODES - 2) ))
run_id="${label}_$(date -u +%Y%m%dT%H%M%SZ)"
LPF_ARM=$arm MXFS_RUN_ID=$run_id timeout "$BOUND_S" "$0" --row
rc=$?
[ "$rc" = 124 ] && echo "UNMEASURED: the lap ran out its ${BOUND_S}s bound"
exit "$rc"
