#!/bin/bash
# mpath_settings.sh — the multipath and iSCSI initiator settings the mpath
# attachment is verified with (docs/mpath-verification.md, T4).  The rig
# applies exactly this text to every node it logs in on two paths
# (tools/lun_pool.sh), and a release recommends exactly this text to a site;
# other settings are outside what was verified.
#
# The rule they satisfy: when a path is lost, I/O on it must fail over, or
# fail, in far less than MXFS's death window, after which peers declare a
# silent node dead and fence it.  A lock holder that loses a path cannot hand
# its lock back until the flush that precedes the unlock has failed over, so a
# waiter's stall is the holder's failover, plus the death window and recovery
# if the holder then dies (docs/rulings/silent-peer-death-under-the-stall-limit.md,
# 'A holder's path failover followed by its death').  With T the timescale
# below (MXFS_MPATH_TMO, seconds):
#
#   detection   NOP-Out every T s, answer due in T s           <= 2T
#   recovery    the session's recovery timeout, T s           <= 3T
#               (fast_io_fail_tmo: multipathd sets it on each iSCSI session)
#   checker     multipathd polls each path every T s
#   no paths    with every path gone, queue for 20 s of checker intervals
#               (no_path_retry 20/T) and then fail the I/O: a node that has
#               lost its storage stops, it does not hang holding its locks
#
# Usage:
#   tools/mpath_settings.sh multipath     the text of /etc/multipath/conf.d/mxfs.conf
#   tools/mpath_settings.sh iscsi         "<setting> <value>" per line, for
#                                         iscsiadm -m node --op update -n <setting> -v <value>
#   tools/mpath_settings.sh stall-bound   seconds: the longest I/O stall a single
#                                         path loss may cause (what a row fails on)
#   tools/mpath_settings.sh tmo           T in seconds, which tools/lun_pool.sh records
#                                         with each multipath binding
#
# MXFS_MPATH_POLICY (default failover) is the path grouping policy: failover
# keeps I/O on one path and the other standing by; multibus spreads it over
# every path.  MXFS_MPATH_TMO (default 2) is T; run.sh records a run made with
# it set as a variant, since it changes what a path fault costs.
#
# Why 2.  A waiter's stall when a lock holder loses a path and then dies is the
# holder's failover F, plus detection, plus recovery, and the 30 s stall limit
# has to hold for the sum (docs/rulings/silent-peer-death-under-the-stall-limit.md,
# 'A holder's path failover followed by its death': F 6 s).  At 5 the failover
# alone is up to 17.5 s (NOP-Out 5 s and its answer 5 s, the recovery timeout
# 5 s, the checker 5 s); at 2 it is up to 7 s.  Every multipath path row at 2,
# 4, 8 and 16 nodes was measured at 2 with the 12 s death window.  A target
# whose relogin opens a window in which it refuses a retained registration
# (the lab's SCST before its handoff fix) cannot run this timescale: a 4 s flap
# makes the initiator log in again, and a refused write shuts the filesystem
# down.
set -u
POLICY=${MXFS_MPATH_POLICY:-failover}
case "$POLICY" in failover|multibus) ;; *) echo "MXFS_MPATH_POLICY is failover or multibus" >&2; exit 2 ;; esac
TMO=${MXFS_MPATH_TMO:-2}
case "$TMO" in [1-9]|[1-9][0-9]) ;; *) echo "MXFS_MPATH_TMO is whole seconds, 1 to 99" >&2; exit 2 ;; esac
NO_PATH_RETRY=$(( (20 + TMO - 1) / TMO ))
case "${1:-}" in
    multipath)
        cat <<EOF
defaults {
    find_multipaths yes
    polling_interval $TMO
    max_polling_interval $TMO
}
overrides {
    path_grouping_policy $POLICY
    failback manual
    fast_io_fail_tmo $TMO
    no_path_retry $NO_PATH_RETRY
}
EOF
        ;;
    iscsi)
        cat <<EOF
node.session.timeo.replacement_timeout $TMO
node.conn[0].timeo.noop_out_interval $TMO
node.conn[0].timeo.noop_out_timeout $TMO
EOF
        ;;
    stall-bound) echo 30 ;;
    tmo) echo "$TMO" ;;
    *) sed -n '2,37p' "$0"; exit 2 ;;
esac
