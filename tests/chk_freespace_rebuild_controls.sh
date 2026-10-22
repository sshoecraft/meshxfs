#!/bin/bash
# chk_freespace_rebuild_controls.sh -- does chk_mxfs rebuild an AG's damaged
# free-space btrees with only the blocks nothing owns
# (D-CHK-FREESPACE-REBUILD-DECLARES-OWNED-BLOCKS-FREE-AGFL-LOG-AND-DATA)?
#
# A repair that rebuilds the BNO and CNT btrees of an AG with no inodes used
# to declare one free extent from a fixed block to the AG's end.  Three kinds
# of block the AG still owns fall inside that: the AGFL's blocks, the internal
# log (mkfs puts it in AG agcount / 2, and no inode chunk goes there on a fresh
# volume), and the data of files whose inodes live in other AGs.  The
# allocator then hands any of them to a second owner.
#
# On a freshly formatted volume the free space mkfs wrote is exactly the blocks
# nothing owns, so the oracle is that free space itself.  For every AG with no
# inodes this records the AG's BNO records, freeblks and longest, breaks the
# BNO root's magic, and requires:
#   - the check to fail and name the AG's BNO btree;
#   - -y to rebuild the AG's trees;
#   - the rebuilt BNO records to be exactly the ones mkfs wrote, and the AGF's
#     freeblks and longest to be mkfs's again, so no AGFL or log block, root or
#     header is free;
#   - a check after it to be clean.
# The log AG is one of them; at 4 GiB the volume has four AGs, so at least one
# more holds neither inodes nor the log.
#
# The data case needs a mounted volume, so it runs on a rig node over a LUN
# (DEV=<block device>; a loop device cannot be mounted, it has no COMPARE AND
# WRITE): mkfs caps the volume at the same 4 GiB (-d 4G), the node mounts it
# alone with the module the cluster's prep loaded, and fallocates one file in
# the root directory, whose inode is in AG 0, larger than AG 0's free space, so
# its extents spill into AGs with no inodes.  After the unmount the oracle is
# the free space the kernel wrote, read just before each break; an AG that
# holds such a file's blocks is rebuilt like the others and must come back
# with exactly that free space, not its blocks.
#
# Bounds: the format through the loop device is mkfs_layout_identity.py's own
# (LOSETUP_S, MKFS_S).  A check of a 20 GiB 4K-native image took 0.25 s
# (2026-10-22, tests/chk_4kn_controls.sh); each chk_mxfs run here, on a 4 GiB
# image, is bounded at 2x that rounded up to the whole second timeout(1) takes,
# 1 s, plus 1 s for the cold read of the record regions: 2 s.  On a LUN: mkfs
# of a 4 GiB volume (it zeroes the 64 MiB journal) ~2 s, bounded 5 s; a lone
# mount ~3 s and an unmount ~2 s (lone_mount_create.sh), bounded 10 s each; the
# fallocate of 1.5 GiB of unwritten extents and its sync ~1 s, bounded 5 s.
#
# Usage: [DEV=<block device>] tests/chk_freespace_rebuild_controls.sh <label> [CHK=tools/chk_mxfs] [MKFS=tools/mkfs_mxfs] [SECTOR=512]
# The image is written under ${TMPDIR:-/tmp}; it is removed on PASS and kept
# on FAIL.  With DEV, the device is formatted and left as the lap leaves it.
# Exit 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
CHK=${2:-tools/chk_mxfs}
MKFS=${3:-tools/mkfs_mxfs}
SECTOR=${4:-512}
DEV=${DEV:-}
SPILL_MIB=${SPILL_MIB:-1536}
cd "$(dirname "$0")/.." || exit 2
W=$(mktemp -d "${TMPDIR:-/tmp}/chkfsr_${LABEL}_XXXXXX") || exit 2
IMG=${DEV:-$W/fs4g.img}
MNT=/mnt/chkfsr_$LABEL
fails=0
ck() { if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"; else echo "  FAIL $1 got=$2 want=$3"; fails=$((fails+1)); fi; }
# On a LUN the reads below go through the device's page cache, which neither
# the kernel's writes while it was mounted nor chk_mxfs's repair update: drop
# it before reading what one of them wrote.
fresh() { [ -z "$DEV" ] || blockdev --flushbufs "$DEV"; }
be32() { od -An -tu4 --endian=big -j "$1" -N4 "$IMG" | tr -d ' \n'; }
be64() { od -An -tu8 --endian=big -j "$1" -N8 "$IMG" | tr -d ' \n'; }
u8() { od -An -tu1 -j "$1" -N1 "$IMG" | tr -d ' \n'; }
chk() { timeout 2 "$CHK" "$@" "$IMG"; }
# every [start count] record of the BNO leaf at byte $1, one per line
recs() { local n i; n=$(od -An -tu2 --endian=big -j $(($1 + 6)) -N2 "$IMG" | tr -d ' \n')
    for ((i = 0; i < n; i++)); do echo "$(be32 $(($1 + 0x38 + i * 8))) $(be32 $(($1 + 0x3C + i * 8)))"; done; }

echo "=== chk_freespace_rebuild_controls label=$LABEL chk=$CHK mkfs=$MKFS sector=$SECTOR image=$IMG $(date -u +%FT%TZ) ==="
if [ -n "$DEV" ]; then
    [ -b "$DEV" ] || { echo "ABORT: $DEV is not a block device"; exit 2; }
    [ -r /sys/module/mxfs/srcversion ] || { echo "ABORT: no mxfs module is loaded on $(hostname)"; exit 2; }
    awk -v d="$(readlink -f "$DEV")" '$1 == d' /proc/mounts | grep -q . && { echo "ABORT: $DEV is mounted"; exit 2; }
    echo "  INFO $(hostname): module $(cat /sys/module/mxfs/srcversion), $DEV of $(blockdev --getss "$DEV")-byte blocks"
    timeout 5 "$MKFS" -f -d 4G "$DEV" > "$W/format.txt" 2>&1 || {
        echo "ABORT: the format failed: $(tail -3 "$W/format.txt" | tr '\n' ' ')"; exit 2; }
    fresh
else
    tests/mkfs_layout_identity.py image "$MKFS" "$IMG" 4096 "$SECTOR" > "$W/format.txt" 2>&1 || {
        echo "ABORT: the format failed: $(tail -3 "$W/format.txt" | tr '\n' ' ')"; exit 2; }
fi
chk -v > "$W/clean.txt" 2>&1; rc=$?
ck "a fresh volume checks clean" "$rc" 0
XO=$(sed -n 's/^  xfs_data_offset=\([0-9]*\).*/\1/p' "$W/clean.txt" | head -1)
[ -n "$XO" ] || { echo "ABORT: no xfs_data_offset in the verbose check"; exit 2; }
AGB=$(be32 $((XO + 0x54)))
AGC=$(be32 $((XO + 0x58)))
LOGSTART=$(be64 $((XO + 0x30)))
LOGBLOCKS=$(be32 $((XO + 0x60)))
AGBLKLOG=$(u8 $((XO + 0x7C)))
LOGAG=$((LOGSTART >> AGBLKLOG))
echo "  INFO agcount=$AGC agblocks=$AGB log: fsb $LOGSTART, $LOGBLOCKS blocks, AG $LOGAG block $((LOGSTART & ((1 << AGBLKLOG) - 1)))"
[ "$AGC" -ge 3 ] || { echo "ABORT: $AGC AGs; this lap needs one with neither inodes nor the log"; exit 2; }

declare -A FRESH
if [ -n "$DEV" ]; then
    for ((ag = 0; ag < AGC; ag++)); do FRESH[$ag]=$(be32 $((XO + ag * AGB * 4096 + SECTOR + 0x34))); done
    mkdir -p "$MNT"
    timeout 10 mount -t mxfs "$DEV" "$MNT" > "$W/mount.txt" 2>&1 || {
        echo "ABORT: the lone mount of $DEV failed: $(tail -3 "$W/mount.txt" | tr '\n' ' ')"; exit 2; }
    timeout 5 fallocate -l "${SPILL_MIB}M" "$MNT/spill" && timeout 5 sync; frc=$?
    ino=$(stat -c %i "$MNT/spill" 2>/dev/null)
    timeout 10 umount "$MNT"; urc=$?
    ck "a ${SPILL_MIB} MiB file was allocated in the root directory (fallocate, sync)" "$frc" 0
    ck "the volume unmounts" "$urc" 0
    [ "$urc" = 0 ] || { echo "ABORT: $DEV is still mounted at $MNT"; exit 2; }
    fresh
    echo "  INFO the file is inode $ino (AG $(( ino >> ($(u8 $((XO + 0x7B))) + AGBLKLOG) ))); AG 0 had ${FRESH[0]} free blocks, the file is $((SPILL_MIB * 256)) blocks"
    chk > "$W/spilled.txt" 2>&1; rc=$?
    ck "the volume holding the file checks clean" "$rc" 0
fi

ran=0 others=0 holds=0
for ((ag = 0; ag < AGC; ag++)); do
    base=$((XO + ag * AGB * 4096))
    agf=$((base + SECTOR))
    agi=$((base + 2 * SECTOR))
    [ "$(be32 $((agi + 0x10)))" = 0 ] || continue          # AGI count: inodes here
    ran=$((ran + 1))
    [ "$ag" = "$LOGAG" ] || others=$((others + 1))
    what="AG $ag ($([ "$ag" = "$LOGAG" ] && echo "the log's AG" || echo "no inodes, no log")"
    bno=$((base + $(be32 $((agf + 0x10))) * 4096))
    want=$(recs "$bno" | tr '\n' ';')
    wfree=$(be32 $((agf + 0x34))) wlong=$(be32 $((agf + 0x38)))
    # less free space than mkfs left it: the blocks of a file whose inode is in
    # AG 0, the only AG with inodes
    if [ -n "$DEV" ] && [ "$wfree" -lt "${FRESH[$ag]}" ]; then
        holds=$((holds + 1))
        what="$what, holding $(( FRESH[$ag] - wfree )) blocks of a file whose inode is in another AG"
    fi
    what="$what)"
    echo "  INFO $what: BNO records before the break [$want] freeblks $wfree longest $wlong"
    printf '\x5a' | dd of="$IMG" bs=1 seek="$bno" conv=notrunc,fsync status=none
    chk > "$W/damaged.$ag.txt" 2>&1; rc=$?
    ck "$what: the broken BNO root fails the check" "$rc" 4
    ck "$what: the check names its BNO btree" "$([ "$(grep -c "AG $ag BNO btree" "$W/damaged.$ag.txt")" -ge 1 ] && echo named || echo none)" named
    chk -y > "$W/repair.$ag.txt" 2>&1
    ck "$what: -y rebuilt its free-space btrees" "$(grep -c "REPAIRED: AG $ag BNO/CNT btrees rebuilt" "$W/repair.$ag.txt")" 1
    fresh
    bno=$((base + $(be32 $((agf + 0x10))) * 4096))
    ck "$what: the rebuilt BNO records are the ones before the break" "$(recs "$bno" | tr '\n' ';')" "$want"
    ck "$what: freeblks is as before the break" "$(be32 $((agf + 0x34)))" "$wfree"
    ck "$what: longest is as before the break" "$(be32 $((agf + 0x38)))" "$wlong"
    chk > "$W/after.$ag.txt" 2>&1; rc=$?
    ck "$what: the repaired volume checks clean" "$rc" 0
done
ck "the log's AG had no inodes and was rebuilt" "$([ "$(be32 $((XO + LOGAG * AGB * 4096 + 2 * SECTOR + 0x10)))" = 0 ] && echo yes || echo no)" yes
ck "an AG with neither inodes nor the log was rebuilt" "$([ "$others" -ge 1 ] && echo yes || echo no)" yes
[ -z "$DEV" ] || ck "an AG holding the blocks of a file whose inode is in another AG was rebuilt" "$([ "$holds" -ge 1 ] && echo yes || echo no)" yes

echo "=== chk_freespace_rebuild_controls $LABEL: AGs=$ran holding_data=${holds} fails=$fails out=$W $(date -u +%FT%TZ) ==="
if [ "$fails" -eq 0 ]; then
    [ -n "$DEV" ] || rm -f "$IMG" "$IMG.random" "$IMG.mkfs.txt"
    exit 0
fi
exit 1
