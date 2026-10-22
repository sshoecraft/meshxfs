#!/bin/bash
# chk_4kn_controls.sh -- does chk_mxfs check a 4K-native volume, and does it
# find the damage that only a 4K-native layout can carry?
#
# On a volume formatted for 4096-byte logical blocks (docs/4kn-support.md)
# every XFS header is a 4096-byte sector with its CRC over the whole sector,
# and every 512-byte record unit is the head of a block of its own whose tail
# must stay zero.  A checker that reads 512 bytes at 512-byte offsets passes
# none of that: it reads the AGF at the superblock sector's tail and the
# journal slot headers in the wrong blocks.  This formats a 4K-native image
# with every outside input fixed (tests/mkfs_layout_identity.py), checks it
# clean, then plants three faults the checker must name:
#   - a nonzero byte in the tail of a disklock lock-slot block;
#   - a byte past offset 512 inside AG 1's AGF sector (outside a 512-byte CRC);
#   - a byte past offset 512 inside AG 2's AGI sector;
#   - a broken magic in AG 3's BNO root, which the repair rebuilds from the
#     layout: it must place the roots and the free extent where mkfs puts them
#     on this layout (roots at blocks 4 and 5, free space from block 12, after
#     the four header sectors, four roots and four AGFL blocks), read back from
#     the image because the checker reads no AGFL and could not tell.
# Then -y must repair all of them, a second check must be clean, and the
# planted tail byte must read zero again.
#
# Bounds: the format through the loop device is mkfs_layout_identity.py's
# own (LOSETUP_S, MKFS_S); a check of a 20 GiB 4K-native image took 0.25 s
# (2026-10-22), so each chk_mxfs run is bounded at 2x that rounded up to the
# whole second timeout(1) takes, 1 s, plus 1 s for the cold read of the
# record regions this smaller image has as many of: 2 s.
#
# Usage: tests/chk_4kn_controls.sh <label> [CHK=tools/chk_mxfs] [MKFS=tools/mkfs_mxfs]
# The image is written under ${TMPDIR:-/tmp}; it is removed on PASS and kept
# on FAIL.  Exit 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
CHK=${2:-tools/chk_mxfs}
MKFS=${3:-tools/mkfs_mxfs}
cd "$(dirname "$0")/.." || exit 2
W=$(mktemp -d "${TMPDIR:-/tmp}/chk4kn_${LABEL}_XXXXXX") || exit 2
IMG=$W/k4g.img
fails=0
ck() { if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"; else echo "  FAIL $1 got=$2 want=$3"; fails=$((fails+1)); fi; }
poke() { printf '\x5a' | dd of="$IMG" bs=1 seek="$1" conv=notrunc status=none; }
peek() { od -An -tx1 -j "$1" -N1 "$IMG" | tr -d ' \n'; }
be32() { od -An -tu4 --endian=big -j "$1" -N4 "$IMG" | tr -d ' \n'; }
chk() { timeout 2 "$CHK" "$@" "$IMG"; }

echo "=== chk_4kn_controls label=$LABEL chk=$CHK mkfs=$MKFS image=$IMG $(date -u +%FT%TZ) ==="
tests/mkfs_layout_identity.py image "$MKFS" "$IMG" 4096 4096 -L > "$W/format.txt" 2>&1 || {
    echo "ABORT: the 4K-native format failed: $(tail -3 "$W/format.txt" | tr '\n' ' ')"; exit 2; }

chk -v > "$W/clean.txt" 2>&1; rc=$?
ck "a fresh 4K-native volume checks clean" "$rc" 0
ck "the checker took its block size from the envelope" "$(grep -c 'logical block size 4096' "$W/clean.txt")" 1
ck "it checked the superblock's 4096-byte sector and log sector" "$(grep -c '^  versionnum=0x[0-9A-F]*, sectlog=12, log sector: 4096 bytes, log2 12$' "$W/clean.txt")" 1
ck "it checked the record block tails" "$(grep -c '^Record block tails ...... OK' "$W/clean.txt")" 1
DL=$(sed -n 's/^  disklock_offset=\([0-9]*\).*/\1/p' "$W/clean.txt" | head -1)
XO=$(sed -n 's/^  xfs_data_offset=\([0-9]*\).*/\1/p' "$W/clean.txt" | head -1)
AGB=$(sed -n 's/.* agblocks=\([0-9]*\),.*/\1/p' "$W/clean.txt" | head -1)
[ -n "$DL" ] && [ -n "$XO" ] && [ -n "$AGB" ] || {
    echo "ABORT: no disklock_offset/xfs_data_offset/agblocks in the verbose check (DL=$DL XO=$XO AGB=$AGB)"; exit 2; }
# mkfs puts the log in AG agcount / 2 and the root inode chunk in AG 0, so on
# four AGs AG 3 holds neither and its free-space rebuild is the layout's own
[ "$(grep -c '^XFS superblock .......... OK  (blocksize=4096, agcount=4,' "$W/clean.txt")" = 1 ] || {
    echo "ABORT: the image does not have the four AGs this lap's AG 3 rebuild assumes: $(grep '^XFS superblock' "$W/clean.txt")"; exit 2; }

# lock slot 1000 is the disklock region's unit 64 + 1000, a block of its own
TAILBLK=$((DL + (64 + 1000) * 4096))
TAIL=$((TAILBLK + 600))
AGF1=$((XO + AGB * 4096 + 4096 + 3000))
AGI2=$((XO + 2 * AGB * 4096 + 2 * 4096 + 3000))
AG3=$((XO + 3 * AGB * 4096))
BNO3=$((AG3 + 4 * 4096))
poke "$TAIL"; poke "$AGF1"; poke "$AGI2"; poke "$BNO3"
echo "  INFO planted 0x5a at $TAIL (lock slot 1000's tail), $AGF1 (AG 1 AGF +3000), $AGI2 (AG 2 AGI +3000), $BNO3 (AG 3 BNO root magic)"

chk > "$W/damaged.txt" 2>&1; rc=$?
ck "the damaged volume fails the check" "$rc" 4
ck "the nonzero tail is named at its block" "$(grep -c "disklock region: 1 block(s) with a nonzero tail, the first at byte $TAILBLK;" "$W/damaged.txt")" 1
ck "the AGF damage past byte 512 fails AG 1's AGF CRC" "$(grep -c 'AG 1: AGF CRC' "$W/damaged.txt")" 1
ck "the AGI damage past byte 512 fails AG 2's AGI CRC" "$(grep -c 'AG 2: AGI CRC' "$W/damaged.txt")" 1
ck "the broken BNO root is found in AG 3" "$([ "$(grep -c 'AG 3 BNO btree' "$W/damaged.txt")" -ge 1 ] && echo found || echo none)" found

chk -y > "$W/repair.txt" 2>&1
ck "repair zeroed the tail" "$(grep -c 'REPAIRED: disklock region: 1 block tail(s) zeroed' "$W/repair.txt")" 1
ck "the planted tail byte reads zero" "$(peek "$TAIL")" 00
LEN3=$(be32 $((AG3 + 4096 + 0x0C)))
ck "repair rebuilt AG 3's free-space btrees" "$(grep -c 'REPAIRED: AG 3 BNO/CNT btrees rebuilt' "$W/repair.txt")" 1
ck "the AGF names the BNO root at block 4" "$(be32 $((AG3 + 4096 + 0x10)))" 4
ck "the AGF names the CNT root at block 5" "$(be32 $((AG3 + 4096 + 0x14)))" 5
ck "the rebuilt free extent starts after the AGFL, at block 12" "$(be32 $((BNO3 + 0x38)))" 12
ck "it runs to the AG's end" "$(be32 $((BNO3 + 0x3C)))" $((LEN3 - 12))
chk > "$W/after.txt" 2>&1; rc=$?
ck "the repaired volume checks clean" "$rc" 0

echo "=== chk_4kn_controls $LABEL: fails=$fails out=$W $(date -u +%FT%TZ) ==="
if [ "$fails" -eq 0 ]; then
    rm -f "$IMG" "$IMG.random" "$IMG.mkfs.txt"
    exit 0
fi
exit 1
