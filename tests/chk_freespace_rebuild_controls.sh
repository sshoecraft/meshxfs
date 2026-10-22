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
# more holds neither inodes nor the log.  The data case needs a mounted volume
# and is not run here.
#
# Bounds: the format through the loop device is mkfs_layout_identity.py's own
# (LOSETUP_S, MKFS_S).  A check of a 20 GiB 4K-native image took 0.25 s
# (2026-10-22, tests/chk_4kn_controls.sh); each chk_mxfs run here, on a 4 GiB
# image, is bounded at 2x that rounded up to the whole second timeout(1) takes,
# 1 s, plus 1 s for the cold read of the record regions: 2 s.
#
# Usage: tests/chk_freespace_rebuild_controls.sh <label> [CHK=tools/chk_mxfs] [MKFS=tools/mkfs_mxfs] [SECTOR=512]
# The image is written under ${TMPDIR:-/tmp}; it is removed on PASS and kept
# on FAIL.  Exit 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
CHK=${2:-tools/chk_mxfs}
MKFS=${3:-tools/mkfs_mxfs}
SECTOR=${4:-512}
cd "$(dirname "$0")/.." || exit 2
W=$(mktemp -d "${TMPDIR:-/tmp}/chkfsr_${LABEL}_XXXXXX") || exit 2
IMG=$W/fs4g.img
fails=0
ck() { if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"; else echo "  FAIL $1 got=$2 want=$3"; fails=$((fails+1)); fi; }
be32() { od -An -tu4 --endian=big -j "$1" -N4 "$IMG" | tr -d ' \n'; }
be64() { od -An -tu8 --endian=big -j "$1" -N8 "$IMG" | tr -d ' \n'; }
u8() { od -An -tu1 -j "$1" -N1 "$IMG" | tr -d ' \n'; }
chk() { timeout 2 "$CHK" "$@" "$IMG"; }
# every [start count] record of the BNO leaf at byte $1, one per line
recs() { local n i; n=$(od -An -tu2 --endian=big -j $(($1 + 6)) -N2 "$IMG" | tr -d ' \n')
    for ((i = 0; i < n; i++)); do echo "$(be32 $(($1 + 0x38 + i * 8))) $(be32 $(($1 + 0x3C + i * 8)))"; done; }

echo "=== chk_freespace_rebuild_controls label=$LABEL chk=$CHK mkfs=$MKFS sector=$SECTOR image=$IMG $(date -u +%FT%TZ) ==="
tests/mkfs_layout_identity.py image "$MKFS" "$IMG" 4096 "$SECTOR" > "$W/format.txt" 2>&1 || {
    echo "ABORT: the format failed: $(tail -3 "$W/format.txt" | tr '\n' ' ')"; exit 2; }
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

ran=0 others=0
for ((ag = 0; ag < AGC; ag++)); do
    base=$((XO + ag * AGB * 4096))
    agf=$((base + SECTOR))
    agi=$((base + 2 * SECTOR))
    [ "$(be32 $((agi + 0x10)))" = 0 ] || continue          # AGI count: inodes here
    ran=$((ran + 1))
    [ "$ag" = "$LOGAG" ] || others=$((others + 1))
    what="AG $ag ($([ "$ag" = "$LOGAG" ] && echo "the log's AG" || echo "no inodes, no log"))"
    bno=$((base + $(be32 $((agf + 0x10))) * 4096))
    want=$(recs "$bno" | tr '\n' ';')
    wfree=$(be32 $((agf + 0x34))) wlong=$(be32 $((agf + 0x38)))
    echo "  INFO $what: mkfs's BNO records [$want] freeblks $wfree longest $wlong"
    printf '\x5a' | dd of="$IMG" bs=1 seek="$bno" conv=notrunc status=none
    chk > "$W/damaged.$ag.txt" 2>&1; rc=$?
    ck "$what: the broken BNO root fails the check" "$rc" 4
    ck "$what: the check names its BNO btree" "$([ "$(grep -c "AG $ag BNO btree" "$W/damaged.$ag.txt")" -ge 1 ] && echo named || echo none)" named
    chk -y > "$W/repair.$ag.txt" 2>&1
    ck "$what: -y rebuilt its free-space btrees" "$(grep -c "REPAIRED: AG $ag BNO/CNT btrees rebuilt" "$W/repair.$ag.txt")" 1
    bno=$((base + $(be32 $((agf + 0x10))) * 4096))
    ck "$what: the rebuilt BNO records are mkfs's" "$(recs "$bno" | tr '\n' ';')" "$want"
    ck "$what: freeblks is mkfs's" "$(be32 $((agf + 0x34)))" "$wfree"
    ck "$what: longest is mkfs's" "$(be32 $((agf + 0x38)))" "$wlong"
    chk > "$W/after.$ag.txt" 2>&1; rc=$?
    ck "$what: the repaired volume checks clean" "$rc" 0
done
ck "the log's AG had no inodes and was rebuilt" "$([ "$(be32 $((XO + LOGAG * AGB * 4096 + 2 * SECTOR + 0x10)))" = 0 ] && echo yes || echo no)" yes
ck "an AG with neither inodes nor the log was rebuilt" "$([ "$others" -ge 1 ] && echo yes || echo no)" yes

echo "=== chk_freespace_rebuild_controls $LABEL: AGs=$ran fails=$fails out=$W $(date -u +%FT%TZ) ==="
if [ "$fails" -eq 0 ]; then
    rm -f "$IMG" "$IMG.random" "$IMG.mkfs.txt"
    exit 0
fi
exit 1
