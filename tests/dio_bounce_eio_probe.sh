#!/bin/bash
#
# dio_bounce_eio_probe.sh — where an O_DIRECT read of an MXFS file gets EIO
# when the device reports stable writes (the bounce-read path,
# xfs_dio_read_bounce_ops in pal/linux/xfs_file.c)
#
# Ubuntu 26.04 (7.0.0-38-generic, 0.90.130) fails tests/dio_stable_writes_read.sh
# with "dd: IO error" in 0.02 s for 64 MiB and nothing in the kernel log;
# Proxmox VE's 7.0.14, which compiles the same bounce path, passes it.  A
# silent EIO in 0.02 s names no function, so this traces one read and prints
# the return value of every function under the read: the first one returning
# -5 is where the error starts.
#
# Steps on NODE, whose MXFS is mounted at MNT (the mount is cycled around each
# stable_writes flip, with the options it had, as dio_stable_writes_read.sh
# does):
#   1. a 1 MiB file written buffered and fsynced, page cache dropped
#   2. control: stable_writes=0, one 4 KiB O_DIRECT read -- must succeed, or
#      the probe is not looking at the bounce path
#   3. stable_writes=1, the same read under function_graph with
#      funcgraph-retval, graph rooted at the module's xfs_file_read_iter
#   4. stable_writes restored, mount as found, file removed
# Prints both reads' dd status, the trace's lines whose return value is
# negative (first 40), and the whole trace to the evidence directory.
#
# Budget: a 1 MiB file and two 4 KiB reads (milliseconds) plus three mount
# cycles of an idle 2-node mount (~5 s each) and the trace copy -> 60 s.
#
# Usage: tests/dio_bounce_eio_probe.sh <node> [mountpoint]
#
set -u

NODE="${1:?usage: dio_bounce_eio_probe.sh <node> [mountpoint]}"
MNT="${2:-/mnt/mxfs}"
STEP_TIMEOUT_S=60

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$HERE/tools/mxfs_sshpass.sh"
EV="$HERE/tests/evidence/dio_bounce_eio_probe/$(date +%Y%m%dT%H%M%S)"
mkdir -p "$EV"
exec > >(tee -a "$EV/run.log") 2>&1
say() { echo "[$(date +%T)] $*"; }

say "node=$NODE mnt=$MNT evidence=$EV"

timeout "$STEP_TIMEOUT_S" "$SSH" "$NODE" "bash -s" > "$EV/remote.log" 2>&1 <<EOF
set -u
MNT=$MNT
F=\$MNT/dio_bounce_eio_probe
T=/sys/kernel/tracing
line=\$(awk -v m="\$MNT" '\$2 == m' /proc/mounts)
[ -n "\$line" ] || { echo "RESULT FAIL: nothing mounted at \$MNT"; exit 1; }
src=\$(echo "\$line" | awk '{print \$1}')
fstype=\$(echo "\$line" | awk '{print \$3}')
opts=\$(echo "\$line" | awk '{print \$4}')
disk=\$(lsblk -no PKNAME "\$(readlink -f "\$src")" | head -1)
[ -n "\$disk" ] || disk=\$(basename "\$(readlink -f "\$src")")
sw=/sys/block/\$disk/queue/stable_writes
orig=\$(cat \$sw)
echo "kernel: \$(uname -r)  module srcversion: \$(cat /sys/module/mxfs/srcversion 2>/dev/null)  disk=\$disk stable_writes=\$orig"
remount() {
    timeout 15 umount "\$MNT" || { echo "RESULT FAIL: umount rc=\$?"; exit 1; }
    echo "\$1" > \$sw || { echo "RESULT FAIL: cannot write \$sw"; exit 1; }
    timeout 15 mount -t "\$fstype" -o "\$opts" "\$src" "\$MNT" || { echo "RESULT FAIL: mount rc=\$?"; exit 1; }
    echo "remounted with stable_writes=\$(cat \$sw)"
}
dread() {  # <tag>: one 4 KiB O_DIRECT read of F by dd, then the whole file by
            # a reader that page-aligns its own buffer, each after dropping the cache
    sync; echo 3 > /proc/sys/vm/drop_caches
    dd if="\$F" of=/dev/null iflag=direct bs=4096 count=1 2>&1 | head -1 | sed "s/^/\$1 dd: /"
    echo "\$1 dd_rc=\${PIPESTATUS[0]}"
    sync; echo 3 > /proc/sys/vm/drop_caches
    python3 -c '
import os, mmap, sys, hashlib
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECT)
buf = mmap.mmap(-1, 1 << 20)
h = hashlib.sha256(); n = 0
try:
    while True:
        r = os.readv(fd, [buf])
        if r <= 0: break
        h.update(buf[:r]); n += r
    print("aligned_read ok bytes=%d sha256=%s" % (n, h.hexdigest()))
except OSError as e:
    print("aligned_read FAIL after %d bytes: %s" % (n, e))
' "\$F" 2>&1 | sed "s/^/\$1 /"
}

echo "dd: \$(dd --version 2>&1 | head -1)"
head -c 1048576 /dev/urandom > "\$F" && sync "\$F" || { echo "RESULT FAIL: write"; exit 1; }
echo "want sha256=\$(sha256sum < "\$F" | cut -d' ' -f1)"
remount 0
dread control_sw0
remount 1

echo 0 > \$T/tracing_on
echo nop > \$T/current_tracer
echo > \$T/trace
grep -q '^xfs_file_read_iter' \$T/available_filter_functions \
    || { echo "RESULT FAIL: xfs_file_read_iter is not traceable"; remount "\$orig"; rm -f "\$F"; exit 1; }
echo xfs_file_read_iter > \$T/set_graph_function
echo 32 > \$T/max_graph_depth
echo function_graph > \$T/current_tracer
echo 1 > \$T/options/funcgraph-retval
echo 1 > \$T/tracing_on
dread bounce_sw1
echo 0 > \$T/tracing_on
cat \$T/trace > /root/dio_bounce_trace.txt
echo nop > \$T/current_tracer
echo > \$T/set_graph_function
echo 0 > \$T/max_graph_depth
echo "trace lines: \$(wc -l < /root/dio_bounce_trace.txt)"
echo "--- negative returns (first 40):"
grep -E 'ret=-[0-9]|ret=0xffffff|/\* ret=-' /root/dio_bounce_trace.txt | head -40
echo "--- dmesg"
dmesg | grep -v drop_caches | tail -10
remount "\$orig"
rm -f "\$F"
echo "RESULT DONE"
EOF
rc=$?
timeout 30 "$SSH" "$NODE" SCPFROM /root/dio_bounce_trace.txt "$EV/trace.txt" >/dev/null 2>&1 \
    || timeout 30 "$SSH" "$NODE" "cat /root/dio_bounce_trace.txt" > "$EV/trace.txt" 2>/dev/null
grep -v -E 'Warning: Permanently|Unauthorized access|authorized user|^$' "$EV/remote.log"
say "remote step rc=$rc trace=$EV/trace.txt ($(wc -l < "$EV/trace.txt") lines)"
exit $rc
