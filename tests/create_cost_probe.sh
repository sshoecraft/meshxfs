#!/bin/bash
#
# create_cost_probe.sh — where one node's file creates spend their time, in
# terms the platform cannot hide: per create, the block device's reads, writes
# and flushes (/sys/block/<dev>/stat), the TCP segments sent and received
# (/proc/net/snmp), and the wall; plus where the creating thread waits,
# sampled from /proc/<pid>/stack every 10 ms.  Run on a node, against a
# mounted filesystem, with nothing else writing it.  The same run on two
# platforms says whether a create there does more I/O and messages, or the
# same I/O and messages at a higher price each.
#
# Usage: create_cost_probe.sh <dir on the mount> <block device> <count> [<kb>]
#   each create: open(O_CREAT|O_EXCL) a new name in <dir>, write <kb> KiB
#   (default 0: an empty file), fsync the file, close.  The directory is made
#   first and fsynced, so its own creation is not counted.
#
# Prints:
#   COST n=<count> wall_ms_per=<..> create_ms_p50=<..> p90=<..> reads_per=<..>
#        writes_per=<..> flushes_per=<..> tcp_out_per=<..> tcp_in_per=<..>
#   STACK <samples> <innermost frame> ... (top 12 innermost frames, and the
#        top 12 frames inside the module, of the creating thread)
set -u
dir=${1:?dir}; dev=${2:?block device}; n=${3:?count}; kb=${4:-0}
d=$(basename "$(readlink -f "$dev")")
[ -r "/sys/block/$d/stat" ] || { echo "PROBE_ERR no /sys/block/$d/stat"; exit 1; }
mkdir -p "$dir" && python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_RDONLY); os.fsync(fd)' "$dir" || exit 1
# /sys/block/<d>/stat: 1 reads, 5 writes, 15 flushes (completed requests)
blk() { awk '{print $1, $5, ($15 == "" ? 0 : $15)}' "/sys/block/$d/stat"; }
tcp() { awk '/^Tcp:/ && $2 ~ /^[0-9]/ {print $12, $11}' /proc/net/snmp; }
s=$(mktemp -d)
read -r r0 w0 f0 < <(blk); read -r o0 i0 < <(tcp)
python3 - "$dir" "$n" "$kb" > "$s/lat" <<'PY' &
import os, sys, time
d, n, kb = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = os.urandom(kb * 1024) if kb else b""
time.sleep(0.2)   # let the sampler find this thread first
for i in range(n):
    a = time.monotonic()
    fd = os.open(os.path.join(d, "c%06d" % i), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    b = time.monotonic()
    if data:
        os.write(fd, data)
    os.fsync(fd); os.close(fd)
    print("%.3f %.3f" % ((b - a) * 1000, (time.monotonic() - a) * 1000), flush=True)
PY
pid=$!
t0=$(date +%s%N)
while kill -0 "$pid" 2>/dev/null; do
    cat "/proc/$pid/stack" 2>/dev/null | tr '\n' '|' >> "$s/stacks"; echo >> "$s/stacks"
    sleep 0.01
done
wait "$pid"
t1=$(date +%s%N)
read -r r1 w1 f1 < <(blk); read -r o1 i1 < <(tcp)
awk -v n="$n" -v ms=$(( (t1 - t0) / 1000000 )) -v r=$((r1 - r0)) -v w=$((w1 - w0)) -v f=$((f1 - f0)) -v o=$((o1 - o0)) -v i=$((i1 - i0)) '
    { c[NR] = $1 } END {
    m = asort(c)
    printf "COST n=%d wall_ms_per=%.2f create_ms_p50=%.2f p90=%.2f reads_per=%.2f writes_per=%.2f flushes_per=%.2f tcp_out_per=%.2f tcp_in_per=%.2f\n",
        m, ms / n, c[int(m / 2) + 1], c[int(m * 9 / 10) + 1], r / n, w / n, f / n, o / n, i / n }' "$s/lat"
# innermost frame of each sample, and the innermost frame inside the module
awk -F'|' 'NF > 1 { f = $1; sub(/^\[<[^>]*>\] /, "", f); sub(/\+0x.*/, "", f); print f }' "$s/stacks" | sort | uniq -c | sort -rn | head -12 | sed 's/^/STACK top /'
awk -F'|' 'NF > 1 { for (k = 1; k < NF; k++) if ($k ~ /\[mxfs\]/) { f = $k; sub(/^\[<[^>]*>\] /, "", f); sub(/\+0x.*/, "", f); print f; break } }' "$s/stacks" | sort | uniq -c | sort -rn | head -12 | sed 's/^/STACK mxfs /'
echo "STACK samples=$(grep -c . "$s/stacks")"
rm -rf "$s"
