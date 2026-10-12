#!/bin/bash
#
# fio_host_timeline.sh — one run.sh row with the pool device sampled from
# outside it, so the host's writes can be placed against the row's own lines.
#
# Written when run.sh's in-row host sample (host_disk[...]) of a 4-node
# fio_perf peaked at 14 MiB/s while /proc/diskstats showed the pool device
# writing 13 GB over the same run.sh call: either the row's writes land
# outside the window the row samples, or the in-row sample is wrong.  This
# samples the whole call independently and prints, with UTC times, every
# second the device wrote more than MIN_MIBS, beside run.sh's output lines
# (each stamped as it arrives).
#
# Usage: tests/mpath/fio_host_timeline.sh <config> <group> <row> [<row> ...]
#   e.g. tests/mpath/fio_host_timeline.sh 4/disk/caw/mpath g4 fio_perf
# Output: tests/evidence/fio_host_timeline_<stamp>/{run.log,host.txt}; the
# summary on stdout.  run.sh owns each row's budget; the sampler's lifetime
# only bounds a call that never returns.
set -u
CFG=${1:?config}; GRP=${2:?group}; shift 2
[ $# -ge 1 ] || { echo "usage: $0 <config> <group> <row> [<row> ...]"; exit 2; }
MIN_MIBS=${MIN_MIBS:-50}
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd); cd "$REPO" || exit 1
OUT=tests/evidence/fio_host_timeline_$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT"
DEV=$(basename "$(findmnt -n -o SOURCE -T "$(tools/mxfs_lab.sh get paths pool)")")
# a whole row with its prep and host waits: the longest seen was 11 min
tests/mpath/path_io_sampler.sh 1800 "$OUT/host.txt" "$OUT/host.stop" "^${DEV}\$" > /dev/null 2>&1 &
SP=$!
s0=$(awk -v d="$DEV" '$3 == d {print $10}' /proc/diskstats)
./run.sh "$CFG" --group "$GRP" "$@" 2>&1 | while IFS= read -r l; do printf '%s %s\n' "$(date -u +%T)" "$l"; done > "$OUT/run.log"
s1=$(awk -v d="$DEV" '$3 == d {print $10}' /proc/diskstats)
: > "$OUT/host.stop"
wait "$SP"
echo "device $DEV: /proc/diskstats says $(( (s1 - s0) * 512 / 1048576 )) MiB written during the call"
echo "sampled seconds: $(grep -c "$DEV" "$OUT/host.txt"); sampled total: $(awk -v d="$DEV" '$2 == d {if (!f) f = $4; l = $4} END {print int((l - f) * 512 / 1048576)}' "$OUT/host.txt") MiB"
echo "seconds over $MIN_MIBS MiB/s (UTC, MiB/s):"
awk -v d="$DEV" -v m="$MIN_MIBS" '$2 == d {if (p) {r = ($4 - ps) * 512 / 1048576 / (($1 - pt) / 1000); if (r > m) printf "  %s %.0f\n", strftime("%H:%M:%S", int($1 / 1000), 1), r}; p = 1; pt = $1; ps = $4}' "$OUT/host.txt" | head -60
echo "run.sh lines:"
grep -aE 'writeback before|pool device|waited|marker|prep|PASS|FAIL|ABORT|===' "$OUT/run.log" | cut -c1-160
echo "evidence: $OUT"
