#!/bin/bash
# caw_create_stacks.sh -- where a single writer's create waits, for
# D-SINGLE-WRITER-CREATE-PACE-6-TO-18MS-ON-2CAW-SO-THE-LMU-LAP-OVERRAN-360S.
#
# tests/caw_create_trace.sh measured 10000 creates at 2/disk/caw/direct
# (lane g2b_w13_20261024T094101Z): 4.8 ms a create with the module's debug sites off,
# 5.7 ms with them on, while the 10000 lock acquires of the creates summed to 2.07 s of
# the 57 s (P138-ACQSUM type=3, about 0.2 ms each).  So nearly all of a create's time is
# outside the lock acquire.  Native XFS on the rig creates in 0.063 ms.
#
# Hypothesis H-CP1 (falsifiable): the creating task spends most of each create blocked in
# the kernel on synchronous device I/O that the create's commit or lock path issues (a log
# force, a FUA write or a coherent re-read), not on the CPU.  This samples the creating
# task's kernel stack (/proc/<pid>/stack of the loop's own shell, a PID in hand, read on
# the node) every 5 ms through NFILES creates in a fresh directory, with the module's debug
# sites off, and tallies the samples by their top frames.  REFUTED if most samples show no
# kernel stack (the task on the CPU in user space) or a stack with no I/O wait in it.
#
# Bounds (derived): prep 37-58 s, bound 120; NFILES=3000 creates at the 5.7 ms measured
# with sampling's added load take about 17 s, bound 2 x 17 = 34, rounded to the loop's own
# timeout 40; the tally on the node a few seconds, 20; the copy 20.  A caller bounds it at
# 120 + 40 + 10 + 20 + 20 + 20 = 230 s.
#
# Usage: tests/caw_create_stacks.sh <label> <configuration>
#        (the group's env exported: MXFS_GROUP, MXFS_MARKER, MXFS_NODE_LIST)
set -u
LABEL=${1:?label}
CONFIG=${2:?configuration}
cd "$(dirname "$0")" || exit 2
while [ ! -f run.sh ] && [ "$(pwd)" != / ]; do cd ..; done
[ -f run.sh ] || { echo "ABORT: no tree root above $0"; exit 2; }
NODES=${MXFS_NODE_LIST:?MXFS_NODE_LIST}
A=${NODES%%,*}
MNT=/mnt/shared
NFILES=${NFILES:-3000}
. tests/lib/rig.sh
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_cawcreatestacks_$LABEL
mkdir -p "$OUT"
echo "TRACE caw_create_stacks start $(date -u +%FT%TZ) label=$LABEL at=$CONFIG A=$A nfiles=$NFILES out=$OUT"
prep=$(MXFS_FORCE_PREP=1 timeout 120 ./run.sh "$CONFIG" ${MXFS_GROUP:+--group "$MXFS_GROUP"} prep_cluster < /dev/null 2>&1)
rc=$?
[ "$rc" = 0 ] || { echo "ABORT: prep_cluster rc=$rc: $(echo "$prep" | tail -2 | tr '\n' ' ' | cut -c1-240)"; exit 2; }
ST=/root/cawcreatestacks.$LABEL
# On the node: the loop in a subshell of its own (its PID is $!, and its creates are
# builtins, so no other task does them), the sampler reading that PID's kernel stack.
NODE='d=$1; n=$2; st=$3; mkdir -p "$d" || exit 1
echo "module mxfs -p" > /sys/kernel/debug/dynamic_debug/control
s=${EPOCHREALTIME/./}
( i=0; while [ $i -lt $n ]; do : > "$d/f$i"; i=$((i+1)); done ) &
p=$!
k=0; while [ -d /proc/$p ]; do cat /proc/$p/stack 2>/dev/null; echo "--- $k"; k=$((k+1)); sleep 0.005; done > "$st"
wait $p
e=${EPOCHREALTIME/./}
echo "module mxfs +p" > /sys/kernel/debug/dynamic_debug/control
echo "CREATED n=$n wall_us=$((e-s)) mean_us=$(( (e-s)/n )) samples=$k"'
timeout 50 tools/mxfs_sshpass.sh "$A" "timeout 40 bash -c '$NODE' node $MNT/.ccs.$LABEL $NFILES $ST" < /dev/null 2>/dev/null | filt > "$OUT/loop.txt"
cat "$OUT/loop.txt" | sed 's/^/  /'
# The tally: each sample is the lines up to its '--- k'; its signature is its top six
# frames, offsets stripped.  An empty sample is a task with no kernel stack to show.
TALLY='awk '"'"'
/^--- / { n++; if (sig == "") e++; else c[sig]++; sig=""; d=0; next }
{ f=$2; sub(/\+0x.*/, "", f); if (d < 6) sig = sig (d ? " < " : "") f; d++ }
END { printf "SAMPLES %d empty %d\n", n, e; for (s in c) printf "%6d %5.1f%% %s\n", c[s], 100*c[s]/(n?n:1), s }'"'"' '"$ST"' | sort -k1,1nr | head -25'
rs 20 "$A" "$TALLY" > "$OUT/tally.txt"
grep -a '^SAMPLES' "$OUT/tally.txt" | sed 's/^/  /'
grep -av '^SAMPLES' "$OUT/tally.txt" | sort -k1,1nr | sed 's/^/  /'
timeout 20 tools/mxfs_sshpass.sh "$A" "gzip -c $ST; rm -f $ST" < /dev/null > "$OUT/stacks.gz" 2>/dev/null
echo "TRACE caw_create_stacks end $(date -u +%FT%TZ) evidence=$OUT"
