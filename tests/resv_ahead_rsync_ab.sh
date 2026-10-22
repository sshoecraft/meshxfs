#!/bin/bash
# tests/resv_ahead_rsync_ab.sh — one arm of the reserve-ahead A/B for
# D-TCP-LEDGER-SMALLFILE-WORKLOAD-PACE-RULE0-0349.
#
# The 8714-file rsync of tests/lone_rsync_bench.sh on node A with its peer B
# mounted: the arm in which every create's inode-number reserve is a durable
# ledger grant at the number's master (alone, a mount takes no grants and runs
# at native pace).  Before the copy the module's resv_ahead (how many free
# numbers of the allocator's current inobt record are requested ahead of the
# creates; 0 = off, the same-build control) and tauth_group_commit (whether
# concurrent ledger commits share their barrier phases) are written on both
# nodes and read back; after it, A's reserve-ahead counters and both nodes'
# P-TAUTH-STATS lines are printed.
#
# The verdict is lone_rsync_bench's own: copy wall (rsync + sync) within 2x
# native XFS measured on the same LUN, node and tree (.lrb_native.<rig>.<A>,
# made once with LRB_NATIVE=1 tests/lone_rsync_bench.sh), all 8714 files, no
# shutdown/corruption line.  An arm whose knobs did not read back is ABORT,
# and a resv_ahead arm whose requests never ran (queued 0) is VACUOUS.
#
# CAW_SPAN=0|1 (unset: not written) also sets caw_span on both nodes, whether a
# ledger page commits in one whole-page SCSI COMPARE AND WRITE where the target
# allows it (H-P6; 0 = the ticket protocol, the same-build control), zeroes
# caw_span_n there and reads both back; after the copy each node's caw_span_n
# is printed.  A CAW_SPAN=1 arm in which A made no whole-page swap is
# VACUOUS; a CAW_SPAN=0 arm in which either node made one is ABORT.
#
# derived bound: lone_rsync_bench's 120 s (umount sweep 20 + mount 15 + rsync
# bound 60 + sync + umount 20) + knob writes 2 x 15 s + counter reads 2 x 15 s
# + caw_span_n reads 2 x 15 s = 210 s; with RA_HASH_VERSION, 2 x 15 s more
# for the version reads: 240 s.
#
# RA_HASH_VERSION (1|2, unset = not checked) is the ledger routing version
# the prep formatted (MXFS_MKFS_OPTS='-H 1' or '-H 2', or mkfs's default 2):
# the arm reads the version every node's mount opened (P-TAUTH-OPEN
# hash_version=) and ABORTs on any other, so an arm never runs on the wrong
# format.
#
# usage: [CAW_SPAN=0|1] [RA_HASH_VERSION=1|2] tests/resv_ahead_rsync_ab.sh <label> <resv_ahead> <group_commit 0|1> <A> <B>
set -u
LABEL=${1:?label}; RA=${2:?resv_ahead}; GC=${3:?group_commit 0|1}
A=${4:?node A}; B=${5:?node B (stays mounted)}
CS=${CAW_SPAN:-}; HV=${RA_HASH_VERSION:-}
case $CS in ''|0|1) ;; *) echo "RESULT: ABORT label=$LABEL -- CAW_SPAN must be 0 or 1: [$CS]"; exit 2 ;; esac
case $HV in ''|1|2) ;; *) echo "RESULT: ABORT label=$LABEL -- RA_HASH_VERSION must be 1 or 2: [$HV]"; exit 2 ;; esac
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO"
SSH=tools/mxfs_sshpass.sh
P=/sys/module/mxfs/parameters
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
want=$(modinfo -F srcversion mxfs.ko)
cs_set=""; cs_get=""; cs_want=""
if [ -n "$CS" ]; then
    cs_set="echo $CS > $P/caw_span; echo 0 > $P/caw_span_n;"
    cs_get=" \$(cat $P/caw_span) \$(cat $P/caw_span_n)"
    cs_want=" $CS 0"
fi
for n in $A $B; do
    got=$(rs 15 "$n" "cat $P/../srcversion; echo $RA > $P/resv_ahead; echo $GC > $P/tauth_group_commit; $cs_set for k in resv_ahead_queued resv_ahead_granted resv_ahead_denied resv_ahead_err resv_ahead_consumed resv_ahead_capped; do echo 0 > $P/\$k; done; echo knobs \$(cat $P/resv_ahead) \$(cat $P/tauth_group_commit)$cs_get" | tr '\r' ' ')
    echo "$n: $got"
    echo "$got" | grep -q "^$want" || { echo "RESULT: ABORT label=$LABEL -- $n does not run this tree's build $want"; exit 2; }
    echo "$got" | grep -q "knobs $RA $GC$cs_want\$" || { echo "RESULT: ABORT label=$LABEL -- $n knobs did not read back as resv_ahead=$RA tauth_group_commit=$GC${CS:+ caw_span=$CS caw_span_n=0}"; exit 2; }
    if [ -n "$HV" ]; then
        hv=$(rs 15 "$n" "dmesg | grep -a 'P-TAUTH-OPEN npages=' | tail -1 | grep -o 'hash_version=[0-9]*'")
        echo "$n ledger: ${hv:-no P-TAUTH-OPEN line}"
        [ "$hv" = "hash_version=$HV" ] || { echo "RESULT: ABORT label=$LABEL -- $n's mount opened the ledger as '${hv:-unknown}', not hash_version=$HV (was the prep formatted for it?)"; exit 2; }
    fi
done
# harness-lint: ok - taken only to be compared with the newest directory after the bench
ev0=$(ls -td tests/evidence/*_lone_rsync_bench_"$LABEL" 2>/dev/null | head -1)
out=$(MXFS_NODE_LIST=$A,$B tests/lone_rsync_bench.sh "$LABEL" "$A" 1 2>&1)
echo "$out"
res=$(echo "$out" | grep -a '^RESULT' | tail -1)
cnt=$(rs 15 "$A" "for k in resv_ahead_queued resv_ahead_granted resv_ahead_denied resv_ahead_err resv_ahead_consumed resv_ahead_capped; do echo \$k=\$(cat $P/\$k); done" | tr '\n' ' ')
echo "COUNTERS $A: $cnt"
# harness-lint: ok - refused below when it is the directory that was newest before the bench
ev=$(ls -td tests/evidence/*_lone_rsync_bench_"$LABEL" 2>/dev/null | head -1)
[ "$ev" != "$ev0" ] || { echo "STATS: the bench left no evidence directory for $LABEL; a previous run's is not read"; ev=""; }
for n in $A $B; do
    [ -n "$ev" ] && zcat "$ev/kmsg_$n.gz" 2>/dev/null | grep -a 'P-TAUTH-STATS' | tail -1 | sed "s/^/STATS $n: /" | cut -c1-400
done
csn=""
if [ -n "$CS" ]; then
    declare -A spn=()
    for n in $A $B; do
        spn[$n]=$(rs 15 "$n" "cat $P/caw_span_n" | tr -dc '0-9')
        csn="$csn caw_span_n_$n=${spn[$n]:-unread}"
    done
    echo "CAW_SPAN=$CS:$csn"
    if [ "$CS" = 1 ] && [ "${spn[$A]:-0}" = 0 ]; then
        echo "RESULT: VACUOUS label=$LABEL resv_ahead=$RA group_commit=$GC caw_span=$CS$csn -- $A made no whole-page COMPARE AND WRITE; $res"
        exit 3
    fi
    if [ "$CS" = 0 ] && { [ "${spn[$A]:-unread}" != 0 ] || [ "${spn[$B]:-unread}" != 0 ]; }; then
        echo "RESULT: ABORT label=$LABEL resv_ahead=$RA group_commit=$GC caw_span=$CS$csn -- the control made whole-page swaps or its counter was unread; $res"
        exit 2
    fi
    csn=" caw_span=$CS$csn"
fi
q=$(echo "$cnt" | grep -o 'resv_ahead_queued=[0-9]*' | cut -d= -f2)
if [ "$RA" != 0 ] && [ "${q:-0}" = 0 ]; then
    echo "RESULT: VACUOUS label=$LABEL resv_ahead=$RA group_commit=$GC$csn -- no reserve-ahead request was queued; $res"
    exit 3
fi
echo "$res" | sed "s/^RESULT: \([A-Z]*\) /RESULT: \1 resv_ahead=$RA group_commit=$GC$csn hash_version=${HV:-unchecked} $(echo "$cnt" | tr -s ' ') /"
echo "$res" | grep -q '^RESULT: PASS'
