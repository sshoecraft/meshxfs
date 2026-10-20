#!/bin/bash
# module_load_profile.sh — where loading mxfs.ko spends its time, by the
# function_graph tracer on one guest.
#
# WHY.  tests/module_load_stall.sh measures that a load keeps one CPU from
# running anything else for ~0.93 s (D-MODULE-LOAD-HOLDS-A-CPU-930MS-PAST-
# DRBD-PING-TIMEOUT), with or without debug info, but not where.  This times
# every call inside load_module (the finit_module path, which also runs the
# module's own init through do_init_module) that lasts at least THRESH_US,
# down to DEPTH levels below load_module, so the stretch can be named:
# relocation, alternatives/ftrace patching, kallsyms, sysfs for the module's
# parameters, or the module's init.
#
# The tracer adds its own cost to every traced call, so the durations it
# prints are upper bounds; compare them with each other and with the stall
# harness's wall, not with an untraced load.  The debug-stripped module is
# loaded (the stall is the same with or without debug info).
#
# Usage: tests/module_load_profile.sh <node> [depth=4] [thresh_us=5000]
#   Run from clyde; the node must have no MXFS mounted.  Prints the trace's
#   timed lines (function and duration) and the load's wall time.  The
#   tracer is reset to nop, threshold 0, depth 0 and no graph filter after.
# Budget: copy 60 s + strip and one traced insmod/rmmod well under 60 s on a
# 2-vCPU guest (an untraced load measured 1.1-1.3 s).
set -u
NODE=${1:?node}
DEPTH=${2:-4}
THRESH=${3:-5000}
case "$DEPTH$THRESH" in *[!0-9]*) echo "FAIL: depth and thresh_us must be whole numbers"; exit 2 ;; esac
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSH="$REPO/tools/mxfs_sshpass.sh"

timeout 60 "$SSH" "$NODE" SCP "$REPO/mxfs.ko" /root/mlp_full.ko </dev/null >/dev/null 2>&1 \
    || { echo "FAIL: copy mxfs.ko to $NODE"; exit 1; }
timeout 120 "$SSH" "$NODE" "
grep -q ' /mnt/shared mxfs ' /proc/mounts && { echo 'FAIL: mxfs is mounted'; exit 1; }
lsmod | grep -q '^mxfs ' && { rmmod mxfs || { echo 'FAIL: rmmod'; exit 1; }; }
modprobe libcrc32c 2>/dev/null
strip --strip-debug -o /root/mlp.ko /root/mlp_full.ko || { echo 'FAIL: strip'; exit 1; }
T=/sys/kernel/tracing; [ -e \$T/current_tracer ] || T=/sys/kernel/debug/tracing
[ -e \$T/current_tracer ] || { echo 'FAIL: no tracefs'; exit 1; }
grep -qx load_module \$T/available_filter_functions || { echo 'FAIL: load_module is not traceable on this kernel'; exit 1; }
reset() { echo 0 > \$T/tracing_on; echo nop > \$T/current_tracer; echo 0 > \$T/tracing_thresh; echo 0 > \$T/max_graph_depth; echo > \$T/set_graph_function; echo > \$T/trace; }
reset
echo $THRESH > \$T/tracing_thresh
echo $DEPTH > \$T/max_graph_depth
echo load_module > \$T/set_graph_function
echo function_graph > \$T/current_tracer
echo 1 > \$T/tracing_on
t0=\$(date +%s%N); insmod /root/mlp.ko force_transport=1; rc=\$?; t1=\$(date +%s%N)
echo 0 > \$T/tracing_on
grep -v '^#' \$T/trace > /root/mlp.trace
lsmod | grep -q '^mxfs ' && rmmod mxfs
reset
echo \"LOAD kernel=\$(uname -r) cpus=\$(nproc) size=\$(stat -c %s /root/mlp.ko) depth=$DEPTH thresh_us=$THRESH insmod_rc=\$rc insmod_ms=\$(( (t1 - t0) / 1000000 )) trace_lines=\$(wc -l < /root/mlp.trace)\"
sed 's/^/TRACE /' /root/mlp.trace
rm -f /root/mlp_full.ko /root/mlp.ko /root/mlp.trace
" </dev/null 2>/dev/null | grep -a -E '^(LOAD|TRACE|FAIL)'
