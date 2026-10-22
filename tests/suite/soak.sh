#!/bin/bash
# soak — a fixed mixed FS workload; no errors, FS stays healthy.
# Agnostic. The work is fixed, never a duration: SOAK_OPS operations (1112, the
# median op count of the 198 recorded passing runs of the old 30-second loop),
# with file sizes drawn from a fixed seed, so native XFS and MXFS do the same
# work and the row's budget is 2x what native XFS measured for it.
SUITE_TEST_NAME=soak
MNT="${1:-/mnt/shared}"; NODES="${MXFS_NODES:-1}"
OPS="${SOAK_OPS:-1112}"
RANDOM=1
W="$MNT/.suite_soak.$(hostname).$$"
rm -rf "$W" 2>/dev/null; mkdir -p "$W" || { echo "RESULT: FAIL | test=soak | nodes=$NODES | measured=setup | reason=mkdir"; exit 1; }
trap 'rm -rf "$W" 2>/dev/null' EXIT
# Pass criterion (per tests/criteria/soak): no op failures AND no kernel
# errors/fences/shutdowns in dmesg during the run. Mark the kernel log so we
# only inspect this run's window.
MARKER="MXFS_SOAK_$(date +%s)_$$"
echo "$MARKER" > /dev/kmsg 2>/dev/null
# "Free inode" takes an inode number: XFS reports "Free inode 0x85 not marked
# free" and "... has blocks allocated".  Bare, case-insensitive, it also
# matched the allocator's own diagnostics ("every free inode in this AG is
# peer-held", "all free inodes peer-held"), which failed a clean 0.89.85 run.
# "Oops" is a whole word for the same reason: case-insensitive, it matched the
# "loops=14" field of "P-IGET-CREATE-RETRIED ... rc=0" (a create that retried
# and succeeded), which failed 8/disk/caw/mpath on the 0.90.131 release build.
DPAT='Internal error|Corruption|SHUTDOWN|shutting down|Free inode (0x)?[0-9a-f]+|reservation conflict|BUG:|\bOops\b|stuck for|call trace'
t0=$(date +%s%3N); ops=0; errs=0
while [ "$ops" -lt "$OPS" ]; do
  f="$W/f$((ops % 50))"
  { head -c $(( (RANDOM * 64) + 1 )) /dev/urandom > "$f" \
      && cp "$f" "$f.cp" && cmp -s "$f" "$f.cp" && rm -f "$f.cp" \
      && mkdir -p "$W/d$((ops % 10))"; } || errs=$((errs + 1))
  ops=$((ops + 1))
done
echo ok > "$W/final" 2>/dev/null && [ "$(cat "$W/final" 2>/dev/null)" = ok ] || errs=$((errs + 1))
wall_ms=$(( $(date +%s%3N) - t0 ))
# dmesg hits since our marker — persist the matching lines for forensics
# (count/threshold unchanged; a FAIL without the lines is undiagnosable
# once the VM reboots, since virsh destroy loses the unflushed journal).
HITFILE="/root/soak_hits.$MARKER.txt"
dmesg 2>/dev/null | awk -v m="$MARKER" 'f{print} $0 ~ m{f=1}' | grep -iE "$DPAT" > "$HITFILE"
dmesg_hits=$(grep -c . "$HITFILE")
if [ "${dmesg_hits:-0}" -gt 0 ]; then
  echo "SOAK-HIT-SAMPLE ($(hostname), first 5 of $dmesg_hits):"
  head -5 "$HITFILE" | sed 's/^/  SOAK-HIT: /'
fi
st=PASS; reason=""
if [ "$errs" -gt 0 ]; then st=FAIL; reason="$errs op failures"; fi
if [ "${dmesg_hits:-0}" -gt 0 ]; then st=FAIL; reason="${reason:+$reason; }$dmesg_hits dmesg error hits"; fi
echo "RESULT: $st | test=soak | nodes=$NODES | measured=ops=$ops wall_ms=$wall_ms errs=$errs dmesg_hits=${dmesg_hits:-0} | reason=$reason"
[ "$st" = PASS ]
