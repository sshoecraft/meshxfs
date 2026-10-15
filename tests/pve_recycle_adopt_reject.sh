#!/bin/bash
# pve_recycle_adopt_reject.sh — what does a host do when it recycles a cached
# inode whose number a peer has reused, and the peer's new on-disk image is
# rejected while it is being read?  D-RECYCLE-ADOPT-IGNORES-FAILED-INODE-FROM-
# DISK-TORN-FORK: xfs_iget_recycle's adopt arm used to ignore the failed
# xfs_inode_from_disk and hand the inode out with the fork the rejection left
# (format BTREE, if_needextents set, no root), and clear its stale mark, so the
# file stayed unreadable on that host after the platter read cleanly again.
#
#   1. host A writes FILES files of EXTENTS separate 4 KiB extents each (BTREE
#      format).  A writes them: a host allocates inodes from its own AG, and
#      only A can hand the same numbers out again in step 3
#   2. host B reads every file, so B caches the inodes
#   3. host A removes them and writes FILES new BTREE files, each filled with
#      its own byte, reusing the numbers
#   4. host B arms dbg_iformat_reject_ino=~0 (reject every data-fork root the
#      recycle adopt rebuilds) and dbg_reclaim_hold (without it the shrinker
#      frees an evicted inode in the same drop_caches pass, and no lookup ever
#      finds a reclaimable shell), drops its dentry and inode caches so its
#      copies become reclaimable shells, and reads every new file
#   5. host B disarms the injection and reads and verifies every new file
#
# REFUSE sets B's recycle_adopt_fail_refuse for the run: 1 (the fix) or 0 (the
# old hand-out, for A/B).  The run counts injections (dbg_iformat_rejected),
# P-RECYCLE-ADOPT-FROMDISK-FAIL(-HANDOUT) and P-IREAD-NOROOT lines and Oops/BUG
# in B's kernel log.  Exit 0 only when every phase finished inside budget, the
# injection fired at least once (otherwise the run measured nothing), every
# file verified in step 5, and B logged no NOROOT, Oops or BUG line.
#
# Usage: tests/pve_recycle_adopt_reject.sh [label]
# Env:
#   PVE_PAIR     "<A> <B>" (required): A writes, removes and rewrites; B reads
#   REFUSE       B's recycle_adopt_fail_refuse for the run (default 1)
#   MNT          the MXFS mount on both hosts (default /mnt/mxfssan)
#   FILES        files per phase (default 40)
#   EXTENTS      4 KiB extents per BTREE file (default 64)
#   DROP_WAIT    seconds B waits between dropping its caches and reading
#                (default 1: eviction finishes after drop_caches returns)
#   PHASE_BUDGET seconds one phase may take (default 60: each phase is a few
#                thousand small writes or reads, a few seconds on native XFS)
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
LABEL=${1:-run}
read -r -a H <<<"${PVE_PAIR:?PVE_PAIR must name host A then host B}"
REFUSE=${REFUSE:-1}
MNT=${MNT:-/mnt/mxfssan}
FILES=${FILES:-40}
EXTENTS=${EXTENTS:-64}
BUDGET=${PHASE_BUDGET:-60}
DROP_WAIT=${DROP_WAIT:-1}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
D=$MNT/recycle-reject/$STAMP-$LABEL
MARK="mxfs-RECYCLE-REJECT-$STAMP-$LABEL"
EVID="$REPO/tests/evidence/pve_recycle_adopt_reject/$STAMP-$LABEL"
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

# write FILES BTREE files named <prefix>N, file N filled with byte (N % 251) + 1
writer() {  # <prefix>
    echo "mkdir -p $D && python3 -c '
import ctypes, os
libc = ctypes.CDLL(None, use_errno=True)
PUNCH = 0x01 | 0x02   # FALLOC_FL_KEEP_SIZE | FALLOC_FL_PUNCH_HOLE
for i in range($FILES):
    fd = os.open(\"$D/$1%d\" % i, os.O_CREAT | os.O_WRONLY, 0o644)
    os.pwrite(fd, bytes([i % 251 + 1]) * ($EXTENTS * 8192), 0)
    os.fsync(fd)
    for k in range($EXTENTS):
        if libc.fallocate(fd, PUNCH, ctypes.c_long(k * 8192 + 4096), ctypes.c_long(4096)):
            raise OSError(ctypes.get_errno(), \"punch\")
    os.fsync(fd)
    os.close(fd)
' && sync && ls -i $D | awk '/$1/{print \$1}' | sort -n > /root/recycle-$1.ino && echo written=\$(wc -l < /root/recycle-$1.ino) frag=\$(filefrag $D/${1}0 | awk '{print \$2}')"
}
# read every file <prefix>N; verify=1 also checks each written block's byte
reader() {  # <prefix> <verify>
    echo "python3 -c '
import os, time
ok = err = wrong = 0
errs = {}
slowest = 0.0
for i in range($FILES):
    p = \"$D/$1%d\" % i
    t0 = time.monotonic()
    try:
        with open(p, \"rb\") as f:
            data = f.read()
        if $2:
            want = i % 251 + 1
            good = len(data) == ($EXTENTS * 8192 - 4096) or len(data) == $EXTENTS * 8192
            for k in range($EXTENTS):
                blk = data[k * 8192:k * 8192 + 4096]
                good = good and blk == bytes([want]) * 4096
            if not good:
                wrong += 1
                continue
        ok += 1
    except OSError as e:
        err += 1
        errs[e.strerror] = errs.get(e.strerror, 0) + 1
    slowest = max(slowest, time.monotonic() - t0)
print(\"ok=%d err=%d wrong=%d errs=%s slowest_ms=%d\" % (ok, err, wrong, errs, slowest * 1000))
'"
}

echo "label=$LABEL dir=$D files=$FILES extents=$EXTENTS refuse=$REFUSE A=${H[0]} B=${H[1]}"
on "${H[1]}" "echo 0 > $P/dbg_iformat_reject_ino && echo 0 > $P/dbg_iformat_rejected && echo $REFUSE > $P/recycle_adopt_fail_refuse && echo refuse=\$(cat $P/recycle_adopt_fail_refuse) && echo $MARK > /dev/kmsg" 10

phase write-old "${H[0]}" "$(writer old)"
phase read-old "${H[1]}" "$(reader old 1)"
phase rewrite "${H[0]}" "rm -f $D/old* && sync && $(writer new)"
phase read-armed "${H[1]}" "echo 1 > $P/dbg_reclaim_hold && echo 18446744073709551615 > $P/dbg_iformat_reject_ino && sync && echo 2 > /proc/sys/vm/drop_caches && sleep $DROP_WAIT && $(reader new 0); rc=\$?; echo 0 > $P/dbg_iformat_reject_ino; echo 0 > $P/dbg_reclaim_hold; echo injected=\$(cat $P/dbg_iformat_rejected); exit \$rc"
phase read-clean "${H[1]}" "$(reader new 1)"

on "${H[0]}" "cat /root/recycle-old.ino" 20 > "$EVID/old.ino"
on "${H[0]}" "cat /root/recycle-new.ino" 20 > "$EVID/new.ino"
reused=$(comm -12 <(sort "$EVID/old.ino") <(sort "$EVID/new.ino") | wc -l)
injected=$(grep -o 'injected=[0-9]*' "$EVID/read-armed.out" | cut -d= -f2)
clean=$(tail -1 "$EVID/read-clean.out")
echo "reused=$reused of new=$(wc -l < "$EVID/new.ino") injected=${injected:-?} read-clean: $clean"

on "${H[1]}" "journalctl -q -o short-monotonic _TRANSPORT=kernel --since '-15min' | sed -n '/$MARK/,\$p'" 30 > "$EVID/B.kmsg"
grep -q "$MARK" "$EVID/B.kmsg" || { echo "run mark missing from B's kernel log"; bad=1; }
refused=$(grep -c 'P-RECYCLE-ADOPT-FROMDISK-FAIL ' "$EVID/B.kmsg")
handout=$(grep -c 'P-RECYCLE-ADOPT-FROMDISK-FAIL-HANDOUT' "$EVID/B.kmsg")
noroot=$(grep -c 'P-IREAD-NOROOT' "$EVID/B.kmsg")
oops=$(grep -cE 'BUG:|Oops|Call Trace' "$EVID/B.kmsg")
grep -E 'P-IREAD-NOROOT|BUG:|Oops' "$EVID/B.kmsg" | head -10
echo "B: refused=$refused handout=$handout noroot=$noroot oops_or_bug=$oops"

on "${H[1]}" "echo 1 > $P/recycle_adopt_fail_refuse; echo 0 > $P/dbg_iformat_reject_ino; echo 0 > $P/dbg_reclaim_hold" 10
phase cleanup "${H[0]}" "rm -rf $D && echo cleaned"
[ "${injected:-0}" -gt 0 ] || { echo "no injection fired: the recycle adopt was not reached and this run measured nothing"; bad=1; }
echo "$clean" | grep -q "^ok=$FILES err=0 wrong=0 " || { echo "read-clean did not verify every file"; bad=1; }
[ "$noroot" = 0 ] && [ "$oops" = 0 ] || bad=1
[ "$bad" = 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"
echo "evidence $EVID"
exit "$bad"
