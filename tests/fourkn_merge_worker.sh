#!/bin/bash
# fourkn_merge_worker.sh -- one node's half of tests/fourkn_merge_2node.sh, run
# on that node from the tree over NFS.
#
# Files f1..fNF in DIR: this node changes the mode of its own half (odd i for
# parity 1, even for 0) every round, and stats the other half, the peer's.
# A stat of a file the peer holds for writing makes the peer drain its inode,
# which on a 4K-native volume is a merged write of a block that also holds
# slots this node is changing.  Round r sets mode 6<r mod 8><4 odd | 2 even>,
# so the last round's mode is what each file must read afterwards.
#
# The files are taken a pair at a time, f(2k-1) and f(2k), whose consecutive
# inodes share a block: each node changes its own of the pair, then stats the
# peer's.  Both nodes run the same steps at once, so each stat makes the peer
# drain the same block the stat-ing node is draining for the peer's stat: two
# merged writes of one block in flight together, which is what a MISCOMPARE
# needs.  Walking the files one at a time instead put both nodes on the same
# file at each step, one changing it while the other stats it, so the two
# drains of a block came one after the other and none miscompared (0 in 478
# merged writes, tests/evidence/20261022T133714Z_fourkn_merge_2-net-mesh-direct).
#
# A SIGTERM stops it after the step in hand (scripts/drbd_rig.sh fourkn-test
# bounds it with `timeout --foreground`, which signals this shell and not the
# chmod or stat it is waiting for, and bash runs the trap once that returns),
# so a workload past its bound still leaves a known state to check: each file
# this node changed reads the mode this node last set on it.
#
# Usage: tests/fourkn_merge_worker.sh <dir> <parity 1|0> <rounds> <nfiles, even>
# Prints MODE <i> <mode> for each of its files it changed, then WORKER_DONE
# rounds= errors= wall_ms= last_mode=, or WORKER_STOPPED at=<round>:<pair>
# rounds= errors= wall_ms= when stopped.
set -u
D=${1:?dir}; P=${2:?parity}; R=${3:?rounds}; NF=${4:?nfiles}
case "$P" in 0|1) ;; *) echo "WORKER_ABORT parity must be 0 or 1"; exit 2;; esac
[ $((NF % 2)) = 0 ] || { echo "WORKER_ABORT nfiles must be even: the files are taken in pairs"; exit 2; }
tail=2; [ "$P" = 1 ] && tail=4
e=0; m=""; stop=0
declare -A last
trap 'stop=1' TERM
t0=$(date +%s%N)
for r in $(seq 1 "$R"); do
    m=6$((r % 8))$tail
    for k in $(seq 1 $((NF / 2))); do
        if [ "$P" = 1 ]; then mine=$((2 * k - 1)); theirs=$((2 * k)); else mine=$((2 * k)); theirs=$((2 * k - 1)); fi
        if chmod "$m" "$D/f$mine"; then last[$mine]=$m; else e=$((e + 1)); fi
        stat -c %a "$D/f$theirs" > /dev/null || e=$((e + 1))
        [ "$stop" = 1 ] && break 2
    done
done
wall=$(( ($(date +%s%N) - t0) / 1000000 ))
for i in "${!last[@]}"; do echo "MODE $i ${last[$i]}"; done
if [ "$stop" = 1 ]; then
    echo "WORKER_STOPPED at=$r:$k rounds=$R errors=$e wall_ms=$wall"
    exit 3
fi
echo "WORKER_DONE rounds=$R errors=$e wall_ms=$wall last_mode=$m"
