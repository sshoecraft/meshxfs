#!/bin/bash
# tcp_rsync_profile.sh — where a both-mounted small-file rsync's time goes on
# the 2-node TCP rig, split down to the authority ledger's page commit.
#
# For D-TCP-LEDGER-SMALLFILE-WORKLOAD-PACE-RULE0-0349: the same 8714-file
# rsync that takes 1.05x native XFS with the peer unmounted takes 7-9x with an
# idle peer mounted.  This runs ftrace's function profiler
# (tests/pve_pair_profile.sh, SLOW_TRACE=0) on both nodes for the whole of one
# tests/lone_rsync_bench.sh both-mounted pass, so the wall can be put on the
# ledger commit, the lock round trips or something else, instead of guessed.
#
# Usage: tests/tcp_rsync_profile.sh <label> [A=test1] [B=test2]
#   The group must already be prepared (2/net/mesh/direct) and both nodes
#   mounted; the bench unmounts nothing but A's peer is left mounted.
# Env: FNS overrides the profiled functions.  CAW_SPAN=0|1 writes caw_span on
#   both nodes and zeroes caw_span_n, reading both back first (ABORT when they
#   do not read back), and prints each node's caw_span_n after the bench.
# Output: tests/evidence/tcp_rsync_profile/<stamp>-<label>/ (summary.txt per
# host, the bench's RESULT line in bench.txt).  It grades nothing.
# derived bound, from each step's own timeout: profiler setup 2 x 60, the wait
# for it to arm 60 + 5, the bench 180, the closing snapshot 2 x 60 and slow-call
# reads 2 x 120 = 725 s; with CAW_SPAN, the knob writes and counter reads
# 2 x 15 + 2 x 15 more = 785 s.
set -u
LABEL=${1:?label}; A=${2:-test1}; B=${3:-test2}
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO" || exit 2
EVID=tests/evidence/tcp_rsync_profile/$(date -u +%Y%m%dT%H%M%SZ)-$LABEL
mkdir -p "$EVID"
CS=${CAW_SPAN:-}
P=/sys/module/mxfs/parameters
case $CS in ''|0|1) ;; *) echo "RESULT: ABORT label=$LABEL -- CAW_SPAN must be 0 or 1: [$CS]"; exit 2 ;; esac
if [ -n "$CS" ]; then
    for n in $A $B; do
        got=$(timeout 15 tools/mxfs_sshpass.sh "$n" "echo $CS > $P/caw_span; echo 0 > $P/caw_span_n; echo knobs \$(cat $P/caw_span) \$(cat $P/caw_span_n)" < /dev/null 2>/dev/null | grep -a '^knobs')
        echo "$n: $got" | tee -a "$EVID/knobs.txt"
        [ "$got" = "knobs $CS 0" ] || { echo "RESULT: ABORT label=$LABEL -- $n caw_span did not read back as $CS with caw_span_n=0"; exit 2; }
    done
fi
FNS=${FNS:-mxfs_tauth_ledger_commit mxfs_tauth_page_write mxfs_tauth_page_write_many mxfs_pal_bdev_flush mxfs_pal_bdev_write_fua mxfs_pal_bdev_compare_and_write mxfs_pal_bdev_compare_and_write_span mxfs_dlm_lock mxfs_v5_dlm_inode_reserve_try mxfs_v5_dlm_inode_lock mxfs_ilock_fallible mxfs_ag_dlm_lock xfs_create xfs_file_fsync xfs_log_force_seq xfs_trans_commit xfs_file_write_iter}
PVE_PAIR="$A $B" SLOW_TRACE=0 INTERVAL_S=600 FNS="$FNS" EVID="$EVID" STOP_FILE="$EVID/stop" \
    tests/pve_pair_profile.sh > "$EVID/profile.log" 2>&1 &
ppid=$!
# the profiler arms both hosts before it starts counting; give it that long
i=0; while [ $i -lt 60 ] && ! grep -aq 'profil' "$EVID/profile.log" 2>/dev/null; do sleep 1; i=$((i + 1)); done
sleep 5
MXFS_NODE_LIST="$A,$B" timeout 180 tests/lone_rsync_bench.sh "prof_$LABEL" "$A" 1 > "$EVID/bench.txt" 2>&1
echo "bench_rc=$?" >> "$EVID/bench.txt"
touch "$EVID/stop"
wait "$ppid"; echo "profile_rc=$?" >> "$EVID/bench.txt"
if [ -n "$CS" ]; then
    for n in $A $B; do
        echo "CAW_SPAN=$CS caw_span_n_$n=$(timeout 15 tools/mxfs_sshpass.sh "$n" "cat $P/caw_span_n" < /dev/null 2>/dev/null | tr -dc '0-9')" | tee -a "$EVID/bench.txt"
    done
fi
grep -a '^RESULT' "$EVID/bench.txt" | cut -c1-300
echo "evidence $EVID"
