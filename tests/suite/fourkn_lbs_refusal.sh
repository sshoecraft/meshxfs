#!/bin/bash
# fourkn_lbs_refusal — a device of 1024- or 2048-byte logical blocks is
# refused at format and at mount, and each refusal names the size
# (docs/4kn-support.md, Open).  A volume is laid out for 512- or 4096-byte
# logical blocks only; on any other size the envelope read would report no
# more than a bad magic, so both refusals must say what is wrong.
#
# On node 1, for each size S in 1024 and 2048, over a throwaway image on the
# node's own disk (never the shared LUN):
#   - mkfs.mxfs on a loop device of S-byte sectors exits non-zero and says the
#     device "has S-byte logical blocks";
#   - an image formatted on a 512-byte loop device (mkfs must succeed there:
#     the control), attached again with S-byte sectors, is refused by the
#     mount, which fails and logs "has S-byte logical blocks ... refusing
#     mount", and leaves nothing mounted.
# The module is the one loaded for the cluster run.sh formed, so the refusal
# graded is the build's.  The node keeps its shared mount throughout; the
# refusal comes before the volume's envelope is read, so nothing touches it.
#
# Derived budget (tests/suite/manifest): five ssh round trips at ~1 s with the
# connect, each mkfs of a 2 GiB image under 1 s, each refused mount under
# 1 s: ~10 s; twice that, 20 s.
#
# Env (run.sh hands a host row these): MXFS_NODES, MXFS_NODE_LIST (default
# test1..testN), MXFS_RUN_ID.
set -u
N=${MXFS_NODES:?}
RUN=${MXFS_RUN_ID:-local}
cd /src/mxfs || { echo "RESULT: FAIL src=test | measured=setup | reason=not-on-clyde"; exit 1; }
# shellcheck source=tests/lib/rig.sh
. tests/lib/rig.sh
NODES_CSV=${MXFS_NODE_LIST:-$(seq -f 'test%g' 1 "$N" | paste -sd,)}
N1=${NODES_CSV%%,*}
OUT=tests/evidence/board_${RUN}_fourkn_lbs_refusal
mkdir -p "$OUT"
IMG=/root/lbs_refusal.img
MNT=/mnt/lbs_refusal
MARK="LBS-REFUSAL-$RUN"
fails=0
why=""
ck() {  # <what> <got> <want>
    if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"; else echo "  FAIL $1 got=$2 want=$3"; fails=$((fails + 1)); why="${why}${why:+; }$1 (got $2)"; fi
}
finish() {  # <status> [reason]
    echo "RESULT: $1 src=test | measured=sizes=1024,2048 | reason=${2:-$why} (evidence $OUT)"
}
cleanup() { rs 20 "$N1" "umount $MNT 2>/dev/null; for l in \$(losetup -j $IMG | cut -d: -f1); do losetup -d \$l; done; rm -f $IMG" >/dev/null; }
trap cleanup EXIT

r=$(rs 15 "$N1" "echo '$MARK' > /dev/kmsg; [ -d /sys/module/mxfs ] && cat /sys/module/mxfs/srcversion")
[ -n "$r" ] || { finish FAIL "$N1 has no mxfs module loaded"; exit 1; }
echo "  INFO $N1 module srcversion $r"
cleanup
for S in 1024 2048; do
    rs 30 "$N1" "truncate -s 2G $IMG && l=\$(losetup --sector-size $S -f --show $IMG) && echo LOOP \$l \$(blockdev --getss \$l) && /src/mxfs/tools/mkfs_mxfs -f \$l 2>&1 | tail -3; echo MKFS_RC=\${PIPESTATUS[0]}; losetup -d \$l" > "$OUT/mkfs_$S.txt"
    ck "the loop device has $S-byte sectors" "$(awk '$1 == "LOOP" {print $3}' "$OUT/mkfs_$S.txt")" "$S"
    ck "mkfs.mxfs refuses a device of $S-byte logical blocks" "$(grep -c '^MKFS_RC=0$' "$OUT/mkfs_$S.txt")" 0
    ck "mkfs.mxfs's refusal names $S-byte logical blocks" "$(grep -ac "has $S-byte logical blocks" "$OUT/mkfs_$S.txt")" 1
    rs 60 "$N1" "rm -f $IMG; truncate -s 2G $IMG && l=\$(losetup --sector-size 512 -f --show $IMG) && /src/mxfs/tools/mkfs_mxfs -f \$l > /dev/null 2>&1; echo MKFS512_RC=\$?; losetup -d \$l
        l=\$(losetup --sector-size $S -f --show $IMG) && echo LOOP \$l \$(blockdev --getss \$l)
        mkdir -p $MNT; timeout 30 mount -t mxfs \$l $MNT; echo MOUNT_RC=\$?
        grep -c ' $MNT ' /proc/mounts; losetup -d \$l; rm -f $IMG" > "$OUT/mount_$S.txt"
    ck "the control: a 512-byte loop device formats" "$(grep -c '^MKFS512_RC=0$' "$OUT/mount_$S.txt")" 1
    ck "the image is attached again with $S-byte sectors" "$(awk '$1 == "LOOP" {print $3}' "$OUT/mount_$S.txt")" "$S"
    ck "the mount of a device of $S-byte logical blocks fails" "$(grep -c '^MOUNT_RC=0$' "$OUT/mount_$S.txt")" 0
    ck "nothing is left mounted at $MNT" "$(tail -1 "$OUT/mount_$S.txt" | tr -dc '0-9')" 0
done
rs 15 "$N1" "dmesg | sed -n '/$MARK/,\$p'" > "$OUT/dmesg_$N1.txt"
ck "$N1's kernel ring still holds the row's mark" "$(head -1 "$OUT/dmesg_$N1.txt" | grep -ac "$MARK")" 1
for S in 1024 2048; do
    ck "the mount's refusal names $S-byte logical blocks" "$(grep -ac "has $S-byte logical blocks; this version mounts devices with 512- or 4096-byte logical blocks only; refusing mount" "$OUT/dmesg_$N1.txt")" 1
done
ck "no BUG, Oops or shutdown on $N1" "$(grep -acE 'BUG:|Oops|Shutting down filesystem' "$OUT/dmesg_$N1.txt")" 0
if [ "$fails" -gt 0 ]; then finish FAIL; exit 1; fi
finish PASS "mkfs.mxfs and the mount each refused 1024- and 2048-byte logical blocks, naming the size"
exit 0
