#!/bin/bash
# pve_reload_reject.sh — what does a host do when it reloads a live inode a
# peer changed, and the new on-disk image is rejected while it is being read?
# D-RECYCLE-ADOPT-IGNORES-FAILED-INODE-FROM-DISK-TORN-FORK, the reload site:
# mxfs_dlm_reload_inode destroys the data fork before xfs_inode_from_disk, and
# a rejected BTREE image leaves format BTREE, if_needextents set and no root
# on an inode that is in use.  This asks what each operation on it then does:
# fail cleanly, or shut the filesystem down.
#
#   1. host A writes FILE, EXTENTS separate 4 KiB extents (BTREE format)
#   2. host B reads it and keeps it open
#   3. host A appends 4 KiB, so B's copy is stale
#   4. host B arms dbg_iformat_reject_ino=<FILE's inode>, then through the
#      open descriptor does one of OP (read, write, truncate), and stats
#   5. host B disarms, reads and verifies the file, and creates a file in the
#      same directory (a shut-down filesystem refuses it)
#
# Exit 0 only when every phase finished inside budget, the injection fired,
# step 5 verified the file and the create succeeded, and B logged no NOROOT,
# shutdown, Oops or BUG line.  The armed operation may fail: the platter image
# it reloads is rejected, and P-IREAD-REJECTED (counted as refused=) is that
# refusal.  NOROOT is a torn fork nobody marked, and fails the run.
#
# Usage: tests/pve_reload_reject.sh [label]
# Env:
#   PVE_PAIR     "<A> <B>" (required)
#   OP           read | write | truncate (default read)
#   MNT          the MXFS mount on both hosts (default /mnt/mxfssan)
#   EXTENTS      4 KiB extents in the file (default 64)
#   PHASE_BUDGET seconds one phase may take (default 30: each phase is a few
#                dozen small I/Os plus the bounded reload retries)
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
LABEL=${1:-run}
read -r -a H <<<"${PVE_PAIR:?PVE_PAIR must name host A then host B}"
OP=${OP:-read}
MNT=${MNT:-/mnt/mxfssan}
EXTENTS=${EXTENTS:-64}
BUDGET=${PHASE_BUDGET:-30}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
D=$MNT/reload-reject/$STAMP-$LABEL
F=$D/f
MARK="mxfs-RELOAD-REJECT-$STAMP-$LABEL"
EVID="$REPO/tests/evidence/pve_reload_reject/$STAMP-$LABEL"
P=/sys/module/mxfs/parameters
mkdir -p "$EVID" || exit 1
bad=0

on() {  # <host> <cmd> <timeout>
    timeout "$3" "$SSHP" "$1" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'
    return "${PIPESTATUS[0]}"
}
phase() {  # <name> <host> <cmd>
    local t0 rc out
    t0=$(date +%s%N)
    out=$(on "$2" "$3" "$BUDGET"); rc=$?
    echo "$out" > "$EVID/$1.out"
    echo "$1 host=$2 rc=$rc wall_ms=$(( ($(date +%s%N) - t0) / 1000000 )) $(echo "$out" | tail -1)"
    [ "$rc" = 0 ] || bad=1
}

case "$OP" in
read)     DO='os.pread(fd, 4096, 0)' ;;
write)    DO='os.pwrite(fd, bytes([7]) * 4096, 0)' ;;
truncate) DO='os.ftruncate(fd, 8192)' ;;
*) echo "OP must be read, write or truncate"; exit 2 ;;
esac

echo "label=$LABEL file=$F op=$OP extents=$EXTENTS A=${H[0]} B=${H[1]}"
on "${H[1]}" "echo 0 > $P/dbg_iformat_reject_ino && echo 0 > $P/dbg_iformat_rejected && echo $MARK > /dev/kmsg && echo ready" 10

phase write "${H[0]}" "mkdir -p $D && python3 -c '
import ctypes, os
libc = ctypes.CDLL(None, use_errno=True)
fd = os.open(\"$F\", os.O_CREAT | os.O_WRONLY, 0o644)
os.pwrite(fd, bytes([5]) * ($EXTENTS * 8192), 0)
os.fsync(fd)
for k in range($EXTENTS):
    if libc.fallocate(fd, 3, ctypes.c_long(k * 8192 + 4096), ctypes.c_long(4096)):
        raise OSError(ctypes.get_errno(), \"punch\")
os.fsync(fd)
os.close(fd)
' && sync && echo ino=\$(stat -c %i $F)"
ino=$(grep -o 'ino=[0-9]*' "$EVID/write.out" | cut -d= -f2)
# B holds the file open across A's append and its own armed operation; the
# holder waits for /root/reload-go, then runs OP and reports
phase hold "${H[1]}" "rm -f /root/reload-go /root/reload-op.out; setsid nohup python3 -c '
import os, time
fd = os.open(\"$F\", os.O_RDWR)
os.pread(fd, 4096, 0)
open(\"/root/reload-held\", \"w\").close()
while not os.path.exists(\"/root/reload-go\"):
    time.sleep(0.05)
t0 = time.monotonic()
try:
    $DO
    r = \"ok\"
except OSError as e:
    r = \"errno=%d %s\" % (e.errno, e.strerror)
try:
    os.fstat(fd)
    s = \"ok\"
except OSError as e:
    s = \"errno=%d %s\" % (e.errno, e.strerror)
with open(\"/root/reload-op.out\", \"w\") as f:
    f.write(\"op=$OP result=%s fstat=%s op_ms=%d\\n\" % (r, s, (time.monotonic() - t0) * 1000))
os.close(fd)
' </dev/null >/dev/null 2>&1 & for i in \$(seq 100); do [ -e /root/reload-held ] && break; sleep 0.1; done; rm -f /root/reload-held; echo held"
phase append "${H[0]}" "python3 -c '
import os
fd = os.open(\"$F\", os.O_WRONLY)
os.pwrite(fd, bytes([5]) * 4096, $EXTENTS * 8192)
os.fsync(fd)
os.close(fd)
' && echo appended"
phase armed-op "${H[1]}" "echo $ino > $P/dbg_iformat_reject_ino && touch /root/reload-go && for i in \$(seq 250); do [ -s /root/reload-op.out ] && break; sleep 0.1; done; echo 0 > $P/dbg_iformat_reject_ino; echo injected=\$(cat $P/dbg_iformat_rejected) \$(cat /root/reload-op.out 2>/dev/null || echo op=unfinished)"
phase verify "${H[1]}" "python3 -c '
import os
with open(\"$F\", \"rb\") as f:
    data = f.read()
good = True
for k in range(len(data) // 8192):
    blk = data[k * 8192:k * 8192 + 4096]
    good = good and (blk == bytes([5]) * 4096 or (k == 0 and blk == bytes([7]) * 4096))
print(\"verify size=%d good=%d\" % (len(data), good))
' && touch $D/after && echo created"

injected=$(grep -o 'injected=[0-9]*' "$EVID/armed-op.out" | cut -d= -f2)
on "${H[1]}" "journalctl -q -o short-monotonic _TRANSPORT=kernel --since '-15min' | sed -n '/$MARK/,\$p'" 30 > "$EVID/B.kmsg"
grep -q "$MARK" "$EVID/B.kmsg" || { echo "run mark missing from B's kernel log"; bad=1; }
noroot=$(grep -c 'P-IREAD-NOROOT' "$EVID/B.kmsg")
fail=$(grep -c 'DLM inode from_disk FAILED' "$EVID/B.kmsg")
refused=$(grep -c 'P-IREAD-REJECTED' "$EVID/B.kmsg")
rebuilt=$(grep -c 'P-RELOAD-REJECTED-REBUILD' "$EVID/B.kmsg")
shut=$(grep -ciE 'shut(ting)? ?down|xfs_do_force_shutdown' "$EVID/B.kmsg")
oops=$(grep -cE 'BUG:|Oops|Call Trace' "$EVID/B.kmsg")
grep -E 'P-IREAD-NOROOT|from_disk FAILED|[Ss]hut|BUG:|Oops' "$EVID/B.kmsg" | head -10 | cut -c1-260
echo "B: injected=${injected:-?} fromdisk_failed=$fail refused=$refused rebuilt=$rebuilt noroot=$noroot shutdown=$shut oops_or_bug=$oops"

on "${H[1]}" "echo 0 > $P/dbg_iformat_reject_ino" 10
phase cleanup "${H[0]}" "rm -rf $D && echo cleaned"
[ "${injected:-0}" -gt 0 ] || { echo "no injection fired: the reload was not reached and this run measured nothing"; bad=1; }
grep -q 'good=1' "$EVID/verify.out" && grep -q created "$EVID/verify.out" || { echo "verify or create failed after disarm"; bad=1; }
[ "$noroot" = 0 ] && [ "$shut" = 0 ] && [ "$oops" = 0 ] || bad=1
[ "$bad" = 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"
echo "evidence $EVID"
exit "$bad"
