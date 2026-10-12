#!/bin/bash
#
# path_io_sampler.sh — runs ON a node: once a second, that node's block-layer
# counters for the multipath map and every SCSI path under it, until a stop
# file appears or the duration ends.
#
# Written for D-4NODE-MPATH-SEQ-WRITE-COLLAPSE: on 4/disk/caw/mpath fio_perf's
# sequential write sometimes reads 22-60% of its yardstick with every node's
# passes falling pass after pass, and sometimes 155-207%, on one build, group
# and LUN.  What the guest's block layer did meanwhile — how much each path
# wrote, how long its writes took, how many were in flight — separates a path
# that stalls or carries everything from a filesystem that stops issuing.
#
# Usage (on the node): path_io_sampler.sh <seconds> <outfile> <stopfile> [devre]
# Each line: <epoch ms> <dev> <writes completed> <sectors written>
#            <ms spent writing> <in flight> <ms doing io>
# for dm-* and sd* (the /proc/diskstats fields 8, 10, 11, 12, 13), after one
# "MAP" line per dm map naming the sd devices behind it.  devre replaces the
# device pattern; fio_path_probe.sh runs it on clyde with the pool LUNs' own
# disk, so the host device's write latency sits beside the guests' paths.
set -u
DUR=${1:?seconds} OUT=${2:?outfile} STOP=${3:?stopfile}
DEVRE=${4:-'^(dm-[0-9]+|sd[a-z]+)$'}
t_end=$(( $(date +%s) + DUR ))
{
    for d in /sys/block/dm-*; do
        [ -d "$d/slaves" ] || continue
        echo "MAP $(basename "$d") $(cat "$d/dm/name" 2>/dev/null) slaves=$(ls "$d/slaves" | tr '\n' ',')"
    done
    while [ "$(date +%s)" -lt "$t_end" ] && [ ! -e "$STOP" ]; do
        now=$(date +%s%3N)
        awk -v t="$now" -v re="$DEVRE" '$3 ~ re {print t, $3, $8, $10, $11, $12, $13}' /proc/diskstats
        sleep 1
    done
} > "$OUT" 2>&1
