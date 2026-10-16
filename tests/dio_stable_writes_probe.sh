#!/bin/bash
#
# dio_stable_writes_probe.sh — what a read of a freshly written MXFS file
# returns, and where it came from.
#
# tests/dio_stable_writes_read.sh fails on Debian 12 (6.1) with a checksum
# mismatch and nothing else.  The first run of this probe found every read
# wrong the same way (buffered and O_DIRECT, stable_writes 1 and 0, and a
# control file never written under stable writes): the file's first 1 MiB
# (4 KiB blocks 0-255) read back as other, nonzero bytes, identical in two
# different files; the other 63 MiB matched.
#
# This run writes STAMPED data: every 4 KiB block carries the run, the file
# and its own block number, so a wrong block names where its bytes came from
# (another file, another offset, an earlier run, or none: old disk contents).
# Cases, each a new file on the mount as it is (no remount, no stable_writes
# change), written with dd and fsync, page cache dropped, read back buffered:
#   bs1m      dd bs=1M        (the failing write)
#   bs4k      dd bs=4K
#   bs1m_2nd  dd bs=1M again, a second file while the first still exists
# For each: blocks that differ, the stamps found in them, and the file's
# extent map (filefrag -v: filesystem blocks, so files can be compared with
# each other, not with device offsets).
#
# Budget: three 64 MiB writes and reads on a pool LUN (native XFS ~1 s each)
# plus generating the stamped source -> 120 s for the remote step.
#
# Usage: tests/dio_stable_writes_probe.sh <node> [mountpoint] [size_mb]
#
set -u

NODE="${1:?usage: dio_stable_writes_probe.sh <node> [mountpoint] [size_mb]}"
MNT="${2:-/mnt/mxfs}"
SIZE_MB="${3:-64}"
STEP_TIMEOUT_S=120

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$HERE/tools/mxfs_sshpass.sh"
RUN=$(date +%H%M%S)
EV="$HERE/tests/evidence/dio_stable_writes_probe/$(date +%Y%m%dT%H%M%S)"
mkdir -p "$EV"
exec > >(tee -a "$EV/run.log") 2>&1
say() { echo "[$(date +%T)] $*"; }

say "node=$NODE mnt=$MNT size=${SIZE_MB}MiB run=$RUN evidence=$EV"

timeout "$STEP_TIMEOUT_S" "$SSH" "$NODE" "bash -s" <<EOF
set -u
MNT=$MNT
SIZE_MB=$SIZE_MB
RUN=$RUN
grep -q " \$MNT mxfs " /proc/mounts || { echo "RESULT FAIL: nothing mounted at \$MNT"; exit 1; }
echo "kernel: \$(uname -r)  module srcversion: \$(cat /sys/module/mxfs/srcversion 2>/dev/null)"
W=/root/dio_swp
mkdir -p \$W
NB=\$((SIZE_MB * 256))
# stamped <file-tag> -> SIZE_MB of 4 KiB blocks, each "RUN=.. FILE=.. BLK=.." padded with '.'
stamped() {
    awk -v run="\$RUN" -v f="\$1" -v n=\$NB 'BEGIN {
        pad = sprintf("%4000s", ""); gsub(/ /, ".", pad)
        for (b = 0; b < n; b++) { s = sprintf("RUN=%s FILE=%s BLK=%07d ", run, f, b); printf "%s", substr(s pad, 1, 4095); printf "\n" } }'
}
check() {  # <tag> <file on mxfs>
    local t=\$1 f=\$2
    sync; echo 3 > /proc/sys/vm/drop_caches
    dd if="\$f" bs=1M status=none > \$W/\$t.read
    if cmp -s \$W/\$t.src \$W/\$t.read; then echo "\$t: MATCH"; else
        echo "\$t: MISMATCH, differing 4 KiB blocks (ranges):"
        cmp -l \$W/\$t.src \$W/\$t.read 2>/dev/null | awk '{b=int((\$1-1)/4096); if (b!=last) {print b; last=b}}' \
            | awk 'NR==1{s=\$1;p=\$1;next} \$1==p+1{p=\$1;next} {print "    " s "-" p; s=\$1; p=\$1} END{if (NR) print "    " s "-" p}' | head -20
        echo "  stamps found in the first differing blocks:"
        for b in \$(cmp -l \$W/\$t.src \$W/\$t.read 2>/dev/null | awk '{b=int((\$1-1)/4096); if (b!=last) {print b; last=b}}' | awk 'NR<=3 || NR%64==0' | head -8); do
            echo "    blk \$b: \$(dd if=\$W/\$t.read bs=4096 skip=\$b count=1 status=none | head -c 40 | tr -c '[:print:]' '?')"
        done
    fi
    echo "  extents of \$t:"; filefrag -v "\$f" 2>&1 | sed -n '4,12p' | sed 's/^/    /'
}
dmesg -C
stamped bs1m > \$W/bs1m.src
dd if=\$W/bs1m.src of=\$MNT/swp_bs1m bs=1M conv=fsync status=none; check bs1m \$MNT/swp_bs1m
stamped bs4k > \$W/bs4k.src
dd if=\$W/bs4k.src of=\$MNT/swp_bs4k bs=4K conv=fsync status=none; check bs4k \$MNT/swp_bs4k
stamped bs1m_2nd > \$W/bs1m_2nd.src
dd if=\$W/bs1m_2nd.src of=\$MNT/swp_bs1m_2nd bs=1M conv=fsync status=none; check bs1m_2nd \$MNT/swp_bs1m_2nd
echo "--- dmesg"; dmesg | grep -v drop_caches | tail -20
rm -f \$MNT/swp_bs1m \$MNT/swp_bs4k \$MNT/swp_bs1m_2nd
rm -rf /root/dio_swp
echo "RESULT DONE"
EOF
rc=$?
say "remote step rc=$rc"
exit $rc
