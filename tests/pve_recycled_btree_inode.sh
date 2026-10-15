#!/bin/bash
# pve_recycled_btree_inode.sh — does a new file on a host inherit the "extents
# not yet read" state of a peer-deleted BTREE-format file whose inode number it
# reuses?  The shape of the qemu-img oops on Proxmox (D-NEW-FILE-ON-RECYCLED-
# INODE-OOPSES-IN-BMBT-INIT-CURSOR-STALE-NEEDEXTENTS): a VM image a peer had
# deleted, then qemu-img creating a cloud-init file and ftruncating it to 4 MiB.
#
#   1. host B writes FILES files of EXTENTS separate 4 KiB extents each (the
#      whole file written, then every other block punched out), more than the
#      inode's literal area holds, so every file is BTREE format.  B writes
#      them because a host allocates inodes from its own AG: only numbers B
#      itself handed out come back to B's allocator
#   2. host A changes each file's timestamps and reads it, taking the inode
#      from B, so B's cached copy is stale
#   3. host B stats each one: B reloads the inode from the dinode, which marks
#      the data fork if_needextents=1 and reads no extent
#   4. host A removes them
#   5. host B creates FILES new files in the same directory and ftruncates each
#      to 4 MiB (open O_CREAT, then ftruncate, as qemu-img create does), then
#      writes 4 KiB into each
#
# The run reports how many new inode numbers reuse a deleted one, and greps
# host B's kernel log from the run mark for P-IREAD-NOROOT (the instrument in
# xfs_iread_extents), Oops and BUG lines.  Exit 0 only when every phase
# finished inside budget, at least one number was reused (otherwise the run
# measured nothing), and B logged no NOROOT, Oops or BUG line.
#
# Usage: tests/pve_recycled_btree_inode.sh [label]
# Env:
#   PVE_PAIR     "<A> <B>" (required): A touches and deletes, B writes, stats
#                and creates
#   MNT          the MXFS mount on both hosts (default /mnt/mxfssan)
#   FILES        files per phase (default 40)
#   EXTENTS      4 KiB extents per BTREE file (default 64)
#   PHASE_BUDGET seconds one phase may take (default 60: each phase is a few
#                thousand small writes or stats, a few seconds on native XFS)
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
LABEL=${1:-run}
read -r -a H <<<"${PVE_PAIR:?PVE_PAIR must name host A then host B}"
MNT=${MNT:-/mnt/mxfssan}
FILES=${FILES:-40}
EXTENTS=${EXTENTS:-64}
BUDGET=${PHASE_BUDGET:-60}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
D=$MNT/recycle-btree/$STAMP-$LABEL
MARK="mxfs-RECYCLE-BTREE-$STAMP-$LABEL"
EVID="$REPO/tests/evidence/pve_recycled_btree_inode/$STAMP-$LABEL"
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

echo "label=$LABEL dir=$D files=$FILES extents=$EXTENTS A=${H[0]} B=${H[1]}"
# both hosts must hold the MXFS mount: on a host without it the phases write
# into the bare mountpoint directory and measure nothing
for h in "${H[@]}"; do
    on "$h" "grep -q ' $MNT mxfs ' /proc/mounts && echo MOUNTED" 20 | grep -q MOUNTED \
        || { echo "$h does not hold $MNT as mxfs; not starting"; echo "RESULT ABORT"; exit 2; }
done
on "${H[1]}" "echo $MARK > /dev/kmsg" 10

# one python3 process per phase: thousands of dd/stat forks would time the
# shell, not the filesystem
phase write "${H[1]}" "mkdir -p $D && python3 -c '
import ctypes, os
libc = ctypes.CDLL(None, use_errno=True)
PUNCH = 0x01 | 0x02   # FALLOC_FL_KEEP_SIZE | FALLOC_FL_PUNCH_HOLE
for i in range($FILES):
    fd = os.open(\"$D/old%d\" % i, os.O_CREAT | os.O_WRONLY, 0o644)
    os.pwrite(fd, b\"x\" * ($EXTENTS * 8192), 0)
    os.fsync(fd)
    for k in range($EXTENTS):
        if libc.fallocate(fd, PUNCH, ctypes.c_long(k * 8192 + 4096), ctypes.c_long(4096)):
            raise OSError(ctypes.get_errno(), \"punch\")
    os.fsync(fd)
    os.close(fd)
' && sync && ls -i $D | sort -n | awk '{print \$1}' > /root/recycle-old.ino && echo written=\$(wc -l < /root/recycle-old.ino) frag=\$(filefrag $D/old0 | awk '{print \$2}')"
phase peer-touch "${H[0]}" "python3 -c '
import os
n = 0
for i in range($FILES):
    p = \"$D/old%d\" % i
    os.utime(p)
    with open(p, \"rb\") as f:
        n += len(f.read(4096)) > 0
print(\"touched=%d\" % n)
'"
phase peer-stat "${H[1]}" "python3 -c '
import os
n = 0
for i in range($FILES):
    st = os.stat(\"$D/old%d\" % i)
    n += st.st_size > 0
print(\"stated=%d\" % n)
'"
phase remove "${H[0]}" "rm -f $D/old* && sync && echo removed"
phase create "${H[1]}" "python3 -c '
import os
made = 0
for i in range($FILES):
    p = \"$D/new%d\" % i
    fd = os.open(p, os.O_CREAT | os.O_RDWR, 0o644)
    os.ftruncate(fd, 0)
    os.ftruncate(fd, 4 << 20)
    os.pwrite(fd, b\"y\" * 4096, 0)
    os.close(fd)
    made += 1
print(\"created=%d\" % made)
' ; rc=\$?; sync; ls -i $D | awk '/new/{print \$1}' | sort -n > /root/recycle-new.ino; exit \$rc"
on "${H[1]}" "cat /root/recycle-old.ino" 20 > "$EVID/old.ino"
on "${H[1]}" "cat /root/recycle-new.ino" 20 > "$EVID/new.ino"
reused=$(comm -12 <(sort "$EVID/old.ino") <(sort "$EVID/new.ino") | wc -l)
echo "reused=$reused of new=$(wc -l < "$EVID/new.ino") old=$(wc -l < "$EVID/old.ino")"

on "${H[1]}" "journalctl -q -o short-monotonic _TRANSPORT=kernel --since '-15min' | sed -n '/$MARK/,\$p'" 30 > "$EVID/B.kmsg"
grep -c "$MARK" "$EVID/B.kmsg" >/dev/null || { echo "run mark missing from B's kernel log"; bad=1; }
noroot=$(grep -c 'P-IREAD-NOROOT' "$EVID/B.kmsg")
oops=$(grep -cE 'BUG:|Oops' "$EVID/B.kmsg")
grep -E 'P-IREAD-NOROOT|BUG:|Oops' "$EVID/B.kmsg" | head -20
echo "B: noroot=$noroot oops_or_bug=$oops"

phase cleanup "${H[1]}" "rm -rf $D && echo cleaned"
[ "$reused" -gt 0 ] || { echo "no inode number reused: this run did not exercise the path"; bad=1; }
[ "$noroot" = 0 ] && [ "$oops" = 0 ] || bad=1
[ "$bad" = 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"
echo "evidence $EVID"
exit "$bad"
