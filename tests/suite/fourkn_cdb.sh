#!/bin/bash
# fourkn_cdb — the CDB unit on a 4K-native LUN (docs/4kn-support.md,
# Verification): caw_verify and fua_verify address the device in its own
# logical blocks, so a WRITE(16) with FUA and a COMPARE AND WRITE of one block
# at a known LBA land in exactly that block, whole, and in nothing next to it.
#
# On a 4096-byte LUN every SCSI command the PAL and the tools build carries
# LBA = byte offset / 4096 and NUMBER OF LOGICAL BLOCKS = length / 4096, and a
# COMPARE AND WRITE carries 2 x 4096 bytes a block.  A CDB still built in
# 512-byte units addresses the wrong block or is refused.  The known LBA is
# the transport scratch block mkfs leaves before the disklock region,
# disklock_offset / 4096 - 1, which nothing else reads or writes; its
# neighbours are the journal's last block (static while mounted) and the
# disklock region's first block (heartbeat slot 0: its record is live, its
# tail past byte 512 stays zero).
#
# PASS needs, on the mounted volume:
#   - node 1's FUA write of the block (pattern 0xab) reads back on node 2 whole:
#     fua_verify's read sees the pattern, and a direct read of the block finds
#     0xab in every byte after fua_verify's 64-byte header;
#   - node 1's COMPARE AND WRITE of the block (0xcd) succeeds, and node 2 finds
#     0xcd in all 4096 bytes, by caw_verify's read and by a direct read;
#   - caw_verify's read expecting the old pattern (0xab) fails on node 2: the
#     read check tells a block it did not write from one it did;
#   - the journal's last block is byte for byte what it was, and the disklock
#     region's first block keeps a zero tail.
#
# Derived budget (tests/suite/manifest): eleven ssh round trips at ~1 s each
# with the connect (measured on the rig: a node command over ssh 0.4-1.2 s),
# each SCSI command a millisecond on the target, the geometry read under 1 s:
# ~12 s; twice that, 24 s, rounded to 30 s.
#
# Env (run.sh hands a host row these): MXFS_NODES (2), MXFS_NODE_LIST (default
# test1,test2), MXFS_DEV, MXFS_RUN_ID.
set -u
N=${MXFS_NODES:?}
RUN=${MXFS_RUN_ID:-local}
DEV=${MXFS_DEV:?}
cd /src/mxfs || { echo "RESULT: FAIL src=test | measured=setup | reason=not-on-clyde"; exit 1; }
# shellcheck source=tests/lib/rig.sh
. tests/lib/rig.sh
NODES_CSV=${MXFS_NODE_LIST:-$(seq -f 'test%g' 1 "$N" | paste -sd,)}
N1=${NODES_CSV%%,*}
N2=${NODES_CSV##*,}
OUT=tests/evidence/board_${RUN}_fourkn_cdb
mkdir -p "$OUT"
T=/src/mxfs/tools
fails=0
why=""
measured=""
ck() {  # <what> <got> <want>
    if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"; else echo "  FAIL $1 got=$2 want=$3"; fails=$((fails + 1)); why="${why}${why:+; }$1 (got $2)"; fi
}
finish() {  # <status> [reason]
    echo "RESULT: $1 src=test | measured=${measured:-none} | reason=${2:-$why} (evidence $OUT)"
}
# byte histogram of one block read direct on node $1: "<count of byte $3 in [$4, 4096)>"
count_byte() { rs 15 "$1" "dd if=$DEV bs=4096 skip=$2 count=1 iflag=direct status=none | od -An -v -tx1 -w1 | tail -n +$(( $4 + 1 )) | grep -c '^ $3\$'"; }

[ "$N" = 2 ] && [ "$N1" != "$N2" ] || { finish FAIL "needs 2 nodes, got $N ($NODES_CSV)"; exit 1; }
for n in "$N1" "$N2"; do
    r=$(rs 15 "$n" "blockdev --getss $DEV; [ -x $T/caw_verify ] && [ -x $T/fua_verify ] && echo tools" | tr '\n' ' ')
    [ "$r" = "4096 tools " ] || { finish FAIL "$n: [$r]; this row needs $DEV of 4096-byte logical blocks and both tools"; exit 1; }
done
dloff=$(rs 20 "$N1" "$T/chk_mxfs --geometry $DEV 2>&1" | sed -n 's/.*disklock_offset=\([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$dloff" ] && [ $(( dloff % 4096 )) = 0 ] && [ "$dloff" -ge 8192 ] || { finish FAIL "no usable disklock_offset from chk_mxfs --geometry on $N1 ('$dloff')"; exit 1; }
S=$(( dloff / 4096 - 1 ))
echo "  INFO disklock_offset=$dloff: scratch block LBA $S, journal's last block $((S - 1)), disklock's first $((S + 1))"
lo_before=$(rs 15 "$N2" "dd if=$DEV bs=4096 skip=$((S - 1)) count=1 iflag=direct status=none | md5sum" | awk '{print $1}')

# FUA write on node 1, read back whole on node 2.  The kernel mark first: a
# batch lap's exposure is read from the nodes' kernel logs, and the tools log
# nothing there, so the mark is what shows the lap reached the write
rs 15 "$N1" "echo 'FOURKN-CDB-$RUN fua_verify write lba=$S pattern=ab' > /dev/kmsg; $T/fua_verify write $DEV $S ab 2>&1" > "$OUT/fua_write.txt"
ck "$N1's FUA write of block $S" "$(grep -c '^WRITE(16) FUA: lba='"$S"' pattern=0xab OK' "$OUT/fua_write.txt")" 1
rs 15 "$N2" "$T/fua_verify read $DEV $S 2>&1" > "$OUT/fua_read.txt"
ck "$N2's FUA read finds $N1's write of block $S" "$(grep -c "FUATEST pattern=0xab lba=$S " "$OUT/fua_read.txt")" 1
ck "$N2 reads 0xab in every byte of block $S after the header" "$(count_byte "$N2" "$S" ab 64)" $((4096 - 64))

# COMPARE AND WRITE on node 1, read back whole on node 2
rs 15 "$N1" "$T/caw_verify write $DEV $S cd 2>&1" > "$OUT/caw_write.txt"
ck "$N1's COMPARE AND WRITE of block $S" "$(grep -c '^\[write\] OK: post-read matches written pattern' "$OUT/caw_write.txt")" 1
ck "it ran in 4096-byte blocks" "$(grep -c "^\[write\] LBA=$S (4096-byte blocks) pattern=0xcd" "$OUT/caw_write.txt")" 1
rs 15 "$N2" "$T/caw_verify read $DEV $S cd > /dev/null 2>&1; echo rc=\$?" > "$OUT/caw_read.txt"
ck "$N2's read of block $S finds 0xcd" "$(cat "$OUT/caw_read.txt")" rc=0
ck "$N2 reads 0xcd in all 4096 bytes of block $S" "$(count_byte "$N2" "$S" cd 0)" 4096
rs 15 "$N2" "$T/caw_verify read $DEV $S ab > /dev/null 2>&1; echo rc=\$?" > "$OUT/caw_read_old.txt"
ck "$N2's read of block $S expecting the old 0xab fails" "$(grep -c '^rc=0$' "$OUT/caw_read_old.txt")" 0

# the neighbours
ck "the journal's last block (LBA $((S - 1))) is unchanged" "$(rs 15 "$N2" "dd if=$DEV bs=4096 skip=$((S - 1)) count=1 iflag=direct status=none | md5sum" | awk '{print $1}')" "$lo_before"
# Both patterns fill whole blocks, so a write that spilled into the next block
# would fill its tail; the record's own 512 bytes are live and not compared.
ck "the disklock region's first block (LBA $((S + 1))) keeps a zero tail" "$(count_byte "$N2" $((S + 1)) 00 512)" $((4096 - 512))

measured="lba=$S disklock_offset=$dloff lbs=4096"
if [ "$fails" -gt 0 ]; then finish FAIL; exit 1; fi
finish PASS "WRITE(16) FUA and COMPARE AND WRITE of LBA $S landed whole in that block and nowhere next to it"
exit 0
