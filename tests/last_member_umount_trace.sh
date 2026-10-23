#!/bin/bash
# last_member_umount_trace.sh -- where the last member's unmount spends its time
# (D-LAST-MEMBER-UMOUNT-AFTER-A-15K-PAGE-HANDBACK-TAKES-31S-OVER-THE-STALL-LIMIT).
#
# The shape tests/join_during_takeover.sh measured: A and B mounted; NFILES entries in one
# directory, created on A (or statted, when an earlier run left them), so each inode's grant is
# taken while both are members; B unmounts cleanly and hands its authority-ledger pages to A; A
# unmounts as the last member.  At NFILES=32000 A's unmount took 29-33 s; at 4000, 4.3-7.8 s.
#
# This runs the same three steps.  While A's unmount runs it samples that one task's kernel stack
# on A every 200 ms (/proc/<pid>/stack of the umount process) and follows A's kernel log, every
# sample and line stamped in ms from the unmount's start on A's own clock.  It prints the
# unmount's wall, each distinct innermost-mxfs-frames stack with the span of samples it covers
# (first and last ms, count), and keeps A's kernel lines of the unmount.  A sample interval of
# 200 ms puts each phase's edges within 200 ms; a stack the task does not sleep in (pure CPU)
# shows as whatever frame it is in when sampled.
#
# Bounds, derived from join_during_takeover's own: the authority NFILES/25+60 s (creates
# measured at 0.25 ms each alone; a stat of every entry when they exist); B's unmount 120 s
# (measured 40 s handing ~15k pages back); A's unmount 180 s (the slow case measured 33 s; the
# trace exists to see the slow case end); the kernel-log fetch 60 s.
#
# Usage: tests/last_member_umount_trace.sh <label> [A=test1] [B=test2]
#        (the pair formed and both mounted, the group's env exported; NFILES default 32000)
# Leaves A and B unmounted: form the pair again before the next run.
# Exit 0 traced, 2 ABORT (nothing measured).
set -u
LABEL=${1:?label}
A=${2:-test1}; B=${3:-test2}
NFILES=${NFILES:-32000}
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
MNT=${MXFS_MNT:-/mnt/shared}
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_lmutrace_$LABEL
mkdir -p "$OUT"
. "$(dirname "$0")/lib/rig.sh"
t0=$(date +%s)
el() { echo $(( $(date +%s) - t0 )); }
echo "=== last_member_umount_trace label=$LABEL A=$A B=$B nfiles=$NFILES out=$OUT $(date -u +%FT%TZ) ==="
for n in "$A" "$B"; do
    info=$(rs 20 "$n" "echo sv=\$(cat /sys/module/mxfs/srcversion) m=\$(grep -c ' mxfs ' /proc/mounts)")
    echo "  INFO $n $info"
    [[ "$info" == *"m=1"* ]] || { echo "ABORT: $n not mounted ($info)"; exit 2; }
done
D=$MNT/.lmutrace
have=$(rs 90 "$A" "ls -f '$D' 2>/dev/null | grep -c '^f'")
have=${have:-0}
cb=$(( NFILES / 25 + 60 ))
if [ "$have" -ge "$NFILES" ]; then
    measure "$A" "$cb" "$OUT/authority.txt" '^STATTED=' "A's stat of every entry" \
        "s=\$(date +%s%N); n=\$(ls -l '$D' | grep -c '^-'); e=\$(date +%s%N); echo STATTED=\$n ms=\$(( (e-s)/1000000 ))"
    grep -q "STATTED=$NFILES " "$OUT/authority.txt" || { echo "ABORT: A statted $(cat "$OUT/authority.txt") of $NFILES"; exit 2; }
else
    measure "$A" "$cb" "$OUT/authority.txt" '^CREATED=' "A's creates" \
        "mkdir -p '$D' && i=0; s=\$(date +%s%N); while [ \$i -lt $NFILES ]; do : > '$D/f'\$i || break; i=\$((i+1)); done; sync; e=\$(date +%s%N); echo CREATED=\$i ms=\$(( (e-s)/1000000 ))"
    grep -q "CREATED=$NFILES " "$OUT/authority.txt" || { echo "ABORT: A created $(cat "$OUT/authority.txt") of $NFILES"; exit 2; }
fi
echo "  INFO the authority: $(cat "$OUT/authority.txt") at +$(el)s"
measure "$B" 120 "$OUT/b_umount.txt" '^B_UMOUNT_RC=' "B's unmount" \
    "s=\$(date +%s%N); umount $MNT; rc=\$?; e=\$(date +%s%N); echo B_UMOUNT_RC=\$rc ms=\$(( (e-s)/1000000 ))"
echo "  INFO B unmounted first: $(cat "$OUT/b_umount.txt") at +$(el)s"
grep -q "B_UMOUNT_RC=0 " "$OUT/b_umount.txt" || { echo "ABORT: B's unmount did not return 0"; exit 2; }
# A's unmount, sampled.  The kernel log is followed into a file from a marker on: the module can
# print more in the unmount than the ring holds.
MARK="LMUTRACE-$LABEL-$$"
measure "$A" 190 "$OUT/a_umount_samples.txt" '^A_UMOUNT_RC=' "A's sampled unmount" \
    "echo '$MARK' > /dev/kmsg; rm -f /tmp/lmutrace_dmesg.txt; nohup sh -c 'dmesg --follow' > /tmp/lmutrace_dmesg.txt 2>&1 & f=\$!; s=\$(date +%s%N); echo START_NS=\$s; umount $MNT & p=\$!; while [ -d /proc/\$p ]; do echo \"T \$(( (\$(date +%s%N)-s)/1000000 ))\"; cat /proc/\$p/stack 2>/dev/null; sleep 0.2; done; wait \$p; rc=\$?; e=\$(date +%s%N); kill \$f 2>/dev/null; echo A_UMOUNT_RC=\$rc ms=\$(( (e-s)/1000000 ))"
echo "  INFO A's last-member unmount: $(grep -a '^A_UMOUNT_RC=' "$OUT/a_umount_samples.txt") at +$(el)s"
start_ns=$(grep -ao '^START_NS=[0-9]*' "$OUT/a_umount_samples.txt" | cut -d= -f2)
measure "$A" 60 "$OUT/a_kmsg.txt" "$MARK" "A's kernel log of the unmount" \
    "awk '/$MARK/{f=1} f' /tmp/lmutrace_dmesg.txt"
# the stack samples by their innermost mxfs frames (up to three), with the span each covers
python3 - "$OUT/a_umount_samples.txt" <<'EOF'
import re, sys
spans, order, t, frames = {}, [], None, []
def close():
    if t is None:
        return
    mx = [f for f in frames if "[mxfs]" in f][:3]
    key = " <- ".join(mx) if mx else (" <- ".join(frames[:2]) or "(no stack: running or exited)")
    if key not in spans:
        spans[key] = [t, t, 0]
        order.append(key)
    s = spans[key]
    s[0], s[1], s[2] = min(s[0], t), max(s[1], t), s[2] + 1
for line in open(sys.argv[1], errors="replace"):
    line = line.strip()
    m = re.match(r"^T (\d+)$", line)
    if m:
        close()
        t, frames = int(m.group(1)), []
    elif line.startswith("[<"):
        frames.append(re.sub(r"^\[<[0-9a-f]+>\] ", "", line).split("+0x")[0] + (" [mxfs]" if "[mxfs]" in line else ""))
close()
print("STACKS first_ms last_ms samples frames")
for key in order:
    s = spans[key]
    print(f"STACK {s[0]:>7} {s[1]:>7} {s[2]:>4} {key}")
EOF
echo "  INFO A's kernel lines of the unmount: $(grep -ac . "$OUT/a_kmsg.txt") in $OUT/a_kmsg.txt"
echo "RESULT: TRACED label=$LABEL nfiles=$NFILES $(grep -a '^A_UMOUNT_RC=' "$OUT/a_umount_samples.txt") evidence=$OUT"
exit 0
