#!/bin/bash
# orphan_adopt_dead_incarn_ab.sh — D-NETMESH-MPATH-FENCED-RETURN-UNLINKED-
# BUCKET-POINTS-AT-FREE-CORE: the orphan scan must not adopt a number whose
# platter core is no longer the zombie its collect pass listed.
#
# Cause under test (read from lap frkf7's kept kernel logs and
# xfs/xfs_mxfs_join.c): the scan's collect pass reads the platter unlocked
# and lists an allocated inode with no links; a peer then frees it; this
# node's iget returns its own cached shell of that number with nlink 0, the
# reload poisons the shell (the platter names another incarnation), and the
# adopt's in-core mode/nlink test passes on the dead shell, so xfs_iunlink
# stamps a FREE inode onto this node's unlinked bucket.
#
# Shape (two mounted nodes, A the peer, B the scanner; knobs on B):
#   1. B unmounts and mounts: its mount-settle reap duty runs the orphan scan
#      about 20 s later.  dbg_orphan_scan_hold_ms parks that scan after its
#      collect pass.
#   2. A creates f and holds it open; B opens f; A unlinks f (a zombie on A's
#      bucket, open on both); B stats its descriptor (its copy reads nlink 0)
#      and closes it, keeping its shell cached.
#   3. B's scan parks with f's number among its candidates.  A closes f and
#      frees it (P82-REM on A).  B's hold is released.
#   4. Control (orphan_adopt_platter_verify=0): B adopts the number
#      (P98-ORPHAN-ADOPT ino=f) and the cold check finds a bucket pointing at
#      a FREE core.  Fix (=1): B refuses it (P98-ORPHAN-ADOPT-REFUSED ino=f),
#      no adopt of f, and the cold check reports no error.
#
# Budget (derived): prep 72-137 s measured + B remount ~10 s + setup ~10 s +
# scan at mount + 20 s + free ~5 s + scan finish ~5 s + two unmounts ~10 s +
# chk on the host image ~10 s => ~210 s; queue bound 300 s.  Every lap preps
# the pair first (run.sh <conf> --group <group> prep_cluster, a fresh format)
# and ends with it unmounted.
#
# Usage: tests/orphan_adopt_dead_incarn_ab.sh <label> <arm: control|fix> [A] [B] [group] [configuration]
set -u
LABEL=${1:?label}; ARM=${2:?arm control|fix}; A=${3:-test17}; B=${4:-test18}
GROUP=${5:-g2e}; CONF=${6:-2/net/mesh/mpath}
case "$ARM" in control) VERIFY=0 ;; fix) VERIFY=1 ;; *) echo "ABORT: arm must be control or fix"; exit 2 ;; esac
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO"
MXFS_FORCE_PREP=1 ./run.sh "$CONF" --group "$GROUP" prep_cluster > "tests/evidence/prep_oadi_${LABEL}.log" 2>&1 ||
    { echo "ABORT: prep of $CONF on $GROUP failed (tests/evidence/prep_oadi_${LABEL}.log)"; echo "RESULT: ABORT label=$LABEL stage=prep"; exit 2; }
SSH=tools/mxfs_sshpass.sh
. "$(dirname "$0")/lib/rig.sh"
export MXFS_NODE_LIST=${MXFS_NODE_LIST:-"$A $B"}
mxfs_dev_resolve "$A"; DEV=$MXFS_DEV_RESOLVED
MNT=${MXFS_MNT:-/mnt/shared}
# the oracle's image, resolved while the pair is mounted: unmounted, a pool
# LUN has no device basis left to match it by
HOST_IMG=$(tools/mxfs_host_image.sh "$A") || { echo "$HOST_IMG"; echo "RESULT: ABORT label=$LABEL stage=device"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_orphanadopt_${LABEL}
mkdir -p "$OUT"
fails=0
P=/sys/module/mxfs/parameters
cnt() { rs 20 "$1" "dmesg | sed -n \"/$MARK/,\\\$p\" | grep -ac '$2'" | tr -dc '0-9'; }
t0=$(date +%s)

echo "=== orphan_adopt_dead_incarn_ab label=$LABEL arm=$ARM A=$A B=$B out=$OUT $(date -u +%FT%TZ) ==="
want=$(modinfo mxfs.ko | awk '/^srcversion:/{print $2}')
for n in $A $B; do
    nsv=$(rs 15 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$nsv" = "$want" ] || { echo "ABORT: $n srcversion '$nsv' != tree '$want'"; echo "RESULT: ABORT label=$LABEL stage=build evidence=$OUT"; exit 2; }
done
MARK="OADI-$LABEL-$$"
for n in $A $B; do rs 12 "$n" "echo '$MARK' > /dev/kmsg" >/dev/null; done
# MXFS_OADI_POISON=0 also turns the reload's unexposed-shell poison off on B
# (incarn_poison_unexposed, new in 0.90.131), the reload of 0.90.130: the arm
# that tests whether the poison is what made the in-core test unsafe
POISON=${MXFS_OADI_POISON:-1}
value_now_into kv "$B" 20 "$OUT/knobs_$B.txt" '^verify=' "the knobs on $B" "echo $VERIFY > $P/orphan_adopt_platter_verify && echo $POISON > $P/incarn_poison_unexposed && echo 60000 > $P/dbg_orphan_scan_hold_ms && echo verify=\$(cat $P/orphan_adopt_platter_verify) hold=\$(cat $P/dbg_orphan_scan_hold_ms) poison=\$(cat $P/incarn_poison_unexposed) refused=\$(cat $P/orphan_adopt_refused_n)"
echo "  INFO $B: $kv"
ck "$B knobs set (verify=$VERIFY, hold armed)" "$(printf '%s' "$kv" | grep -o 'verify=[0-9]* hold=[0-9]*')" "verify=$VERIFY hold=60000"
refused0=$(printf '%s' "$kv" | sed -n 's/.*refused=\([0-9]*\).*/\1/p')

# 1. B remounts: a fresh mount-settle scan ~20 s from now
value_now_into rv1 "$B" 60 "$OUT/rv1.txt" '^rc=' "B umount" "timeout 45 umount $MNT; echo rc=\$?"; rv1=$(printf '%s\n' "$rv1" | sed -n 's/^rc=//p')
ck "B=$B unmounted" "$rv1" "0"
value_now_into rv2 "$B" 120 "$OUT/rv2.txt" '^rc=' "B mount" "timeout 90 mount -t mxfs $DEV $MNT; echo rc=\$?"; rv2=$(printf '%s\n' "$rv2" | sed -n 's/^rc=//p')
ck "B=$B mounted again" "$rv2" "0"
tm=$(date +%s)

# 2. the zombie, open on both, and B's cached nlink-0 copy
D="$MNT/.oadi_$LABEL"
value_now_into ino "$A" 30 "$OUT/ino.txt" '^[0-9]+$' "f's inode on A" "mkdir -p $D && dd if=/dev/urandom of=$D/f bs=4096 count=1 2>/dev/null && sync && stat -c %i $D/f"
echo "  INFO f ino=$ino"
hold_into() { value_now_into "$1" "$2" 20 "$OUT/hold_$2.txt" '^[0-9]+$' "the holder pid on $2" "nohup setsid sh -c 'echo \$\$ > /tmp/oadi_hold.pid; exec 3<$D/f; exec sleep 300' >/dev/null 2>&1 & sleep 1; cat /tmp/oadi_hold.pid"; }
hold_into pa "$A"; hold_into pb "$B"
ck "holders armed ($A pid=$pa, $B pid=$pb)" "$([ -n "$pa" ] && [ -n "$pb" ] && echo ok || echo none)" "ok"
value_now_into rv3 "$A" 30 "$OUT/rv3.txt" '^rc=' "A unlink" "rm -f $D/f && sync && echo rc=0 || echo rc=1"; rv3=$(printf '%s\n' "$rv3" | sed -n 's/^rc=//p')
ck "A unlinked f" "$rv3" "0"
value_now_into bl "$B" 20 "$OUT/b_fstat.txt" '^links=' "B's view of f" "echo links=\$(stat -L -c %h /proc/$pb/fd/3 2>/dev/null)"
echo "  INFO $B fstat: $bl"
ck "B's copy of f reads nlink 0" "$bl" "links=0"
rs 15 "$B" "kill $pb 2>/dev/null; true" >/dev/null
sleep 1
el=$(( $(date +%s) - tm ))
echo "  INFO setup done ${el}s after B's mount"
MARK2="OADI2-$LABEL-$$"
for n in $A $B; do rs 12 "$n" "echo '$MARK2' > /dev/kmsg" >/dev/null; done

# 3. B's scan parks after collecting; A frees f; release
i=0; h=0
while [ $i -lt 40 ]; do
    h=$(rs 20 "$B" "dmesg | sed -n \"/$MARK2/,\\\$p\" | grep -ac 'P98-ORPHAN-SCAN-HOLD cand='" | tr -dc '0-9')
    [ "${h:-0}" -ge 1 ] && break
    sleep 1; i=$((i+1))
done
ck "B's orphan scan parked after the setup (P98-ORPHAN-SCAN-HOLD)" "$([ "${h:-0}" -ge 1 ] && echo yes || echo no)" "yes"
rs 15 "$A" "kill $pa 2>/dev/null; true" >/dev/null
i=0; fr=0
while [ $i -lt 20 ]; do
    fr=$(rs 20 "$A" "dmesg | sed -n \"/$MARK2/,\\\$p\" | grep -ac 'P82-REM ino=$ino '" | tr -dc '0-9')
    [ "${fr:-0}" -ge 1 ] && break
    sleep 1; i=$((i+1))
done
ck "A freed f after the collect pass (P82-REM ino=$ino)" "$([ "${fr:-0}" -ge 1 ] && echo yes || echo no)" "yes"
rs 15 "$B" "echo 0 > $P/dbg_orphan_scan_hold_ms" >/dev/null
i=0; dn=0
while [ $i -lt 30 ]; do
    dn=$(rs 20 "$B" "dmesg | sed -n \"/$MARK2/,\\\$p\" | grep -ac 'P98-ORPHAN-SCAN-DONE'" | tr -dc '0-9')
    [ "${dn:-0}" -ge 1 ] && break
    sleep 1; i=$((i+1))
done
ck "B's orphan scan finished (P98-ORPHAN-SCAN-DONE)" "$([ "${dn:-0}" -ge 1 ] && echo yes || echo no)" "yes"
sleep 2

# 4. what B did with f's number
window_into "$OUT/b_window.txt" "$B" 20 "$MARK2"
adopt=$(grep -ac "P98-ORPHAN-ADOPT ino=$ino " "$OUT/b_window.txt")
refuse=$(grep -ac "P98-ORPHAN-ADOPT-REFUSED ino=$ino " "$OUT/b_window.txt")
poison=$(grep -aEc "P-RELOAD-XINCARN-POISON ino=$ino |P977-RELOAD-EXPOSED-MISMATCH ino=$ino " "$OUT/b_window.txt")
echo "  INFO $B on ino $ino: adopt=$adopt refused=$refuse poisoned=$poison"
grep -aE "ino=$ino[ ]" "$OUT/b_window.txt" | grep -aE 'P98-|POISON|RECYCLE' | head -8 | cut -c1-260 | sed 's/^/    /'
refused1=$(rs 15 "$B" "cat $P/orphan_adopt_refused_n" | tr -dc '0-9')
echo "  INFO orphan_adopt_refused_n $refused0 -> $refused1"
if [ "$ARM" = control ]; then
    ck "control: B adopted the freed number (reach: P98-ORPHAN-ADOPT ino=$ino)" "$([ "$adopt" -ge 1 ] && echo yes || echo no)" "yes"
else
    ck "fix: B refused the freed number (P98-ORPHAN-ADOPT-REFUSED ino=$ino)" "$([ "$refuse" -ge 1 ] && echo yes || echo no)" "yes"
    ck "fix: B did not adopt it" "$adopt" "0"
fi
for n in $A $B; do measure "$n" 20 "$OUT/dmesg_$n.txt" '^DMESG_END$' "the kernel log on $n from the lap marker" "dmesg | sed -n \"/$MARK/,\\\$p\"; echo DMESG_END"; ck "zero splats on $n" "$(grep -aEc 'BUG:|Oops|blocked for more than|Shutting down filesystem' "$OUT/dmesg_$n.txt")" "0"; done

# 5. the platter, cold
for n in $A $B; do
    ( timeout 90 $SSH "$n" "if grep -q ' $MNT mxfs ' /proc/mounts; then timeout 60 umount $MNT; echo rc=\$?; else echo rc=0; fi" 2>/dev/null | filt | tail -1 > "$OUT/um_$n.txt" ) &
done
wait
ck "pair unmounted for the oracle" "$(grep -L 'rc=0' "$OUT"/um_*.txt 2>/dev/null | wc -l)" "0"
timeout 120 tools/chk_mxfs -v "$HOST_IMG" > "$OUT/chk.txt" 2>&1; chkrc=$?
[ "$chkrc" != 124 ] || { echo "ABORT: chk_mxfs ran out its 120 s bound"; echo "RESULT: ABORT label=$LABEL stage=capture evidence=$OUT"; exit 2; }
capture_require "$OUT/chk.txt" 'unlinked buckets|bucketed zombies' "chk_mxfs -v on the backing image"
freecore=$(grep -ac 'has a FREE core' "$OUT/chk.txt")
errs=$(grep -ac 'ERROR' "$OUT/chk.txt")
echo "  INFO chk rc=$chkrc FREE-core=$freecore ERROR-lines=$errs"
grep -a 'ERROR' "$OUT/chk.txt" | head -4 | cut -c1-220 | sed 's/^/    /'
if [ "$ARM" = control ]; then
    ck "control: the cold check finds the bucket on a FREE core" "$([ "$freecore" -ge 1 ] && echo yes || echo no)" "yes"
else
    ck "fix: chk_mxfs reports no ERROR" "$errs" "0"
fi
echo "=== orphan_adopt_dead_incarn_ab $LABEL arm=$ARM: fails=$fails total=$(( $(date +%s) - t0 ))s out=$OUT ==="
echo "RESULT: $([ "$fails" -eq 0 ] && echo PASS || echo FAIL) label=$LABEL arm=$ARM adopt=$adopt refused=$refuse freecore=$freecore errors=$errs evidence=$OUT"
echo "NOTE: the pair is unmounted — prep before further rig work."
[ "$fails" -eq 0 ]
