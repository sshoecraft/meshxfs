#!/bin/bash
# module_load_stall.sh — how long loading mxfs.ko keeps a CPU from running
# anything else, with the module as built and with its debug info stripped.
#
# WHY.  DRBD drops its link when the peer's PingAck is 0.5 s late, and loading
# the module on a DRBD node with the link up has fenced the peer (2026-10-15:
# 'loading out-of-tree module' at 33.645 s, 'meta connection shut down by peer'
# at 34.652 s, the module's init line at 34.746 s).  This measures the stall
# itself, with no DRBD and nothing fenced: one probe per CPU, each a busy loop
# recording the longest gap between two of its own iterations, runs while the
# module is loaded and unloaded ROUNDS times per variant.
#
# Usage: tests/module_load_stall.sh <node> [rounds]     (default 3)
#   Run from clyde; the node must have no MXFS mounted.  Prints, per variant
#   and round, the load wall time and the longest gap any CPU saw.
set -u
NODE=${1:?node}
ROUNDS=${2:-3}
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSH="$REPO/tools/mxfs_sshpass.sh"

timeout 60 "$SSH" "$NODE" SCP "$REPO/mxfs.ko" /root/mls_full.ko </dev/null >/dev/null 2>&1 \
    || { echo "FAIL: copy mxfs.ko to $NODE"; exit 1; }
timeout 600 "$SSH" "$NODE" "
grep -q ' /mnt/shared mxfs ' /proc/mounts && { echo 'FAIL: mxfs is mounted'; exit 1; }
lsmod | grep -q '^mxfs ' && { rmmod mxfs || { echo 'FAIL: rmmod'; exit 1; }; }
modprobe libcrc32c 2>/dev/null
strip --strip-debug -o /root/mls_strip.ko /root/mls_full.ko || { echo 'FAIL: strip'; exit 1; }
echo SIZES full=\$(stat -c %s /root/mls_full.ko) stripped=\$(stat -c %s /root/mls_strip.ko) cpus=\$(nproc)
cat > /root/mls_probe.py <<'PY'
import os, sys, time
cpu, out = int(sys.argv[1]), sys.argv[2]
os.sched_setaffinity(0, {cpu})
worst, last, end = 0.0, time.monotonic(), time.monotonic() + float(sys.argv[3])
while True:
    now = time.monotonic()
    if now - last > worst:
        worst = now - last
    last = now
    if now > end:
        break
open(out, 'w').write('%.3f\n' % (worst * 1000))
PY
for v in full strip; do
    for r in \$(seq 1 $ROUNDS); do
        pids=''
        for c in \$(seq 0 \$((\$(nproc) - 1))); do python3 /root/mls_probe.py \$c /root/mls_gap.\$c 6 & pids=\"\$pids \$!\"; done
        sleep 1.5
        t0=\$(date +%s%N); insmod /root/mls_\$v.ko force_transport=1; rc=\$?; t1=\$(date +%s%N)
        wait \$pids
        rmmod mxfs 2>/dev/null
        echo \"RESULT variant=\$v round=\$r insmod_rc=\$rc insmod_ms=\$(( (t1 - t0) / 1000000 )) max_gap_ms=\$(sort -n /root/mls_gap.* | tail -1) per_cpu_ms=\$(cat /root/mls_gap.* | tr '\n' ',')\"
        sleep 2
    done
done
rm -f /root/mls_full.ko /root/mls_strip.ko /root/mls_gap.* /root/mls_probe.py
" </dev/null 2>/dev/null | grep -a -E '^(SIZES|RESULT|FAIL)'
