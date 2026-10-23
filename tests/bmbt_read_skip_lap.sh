#!/bin/bash
# bmbt_read_skip_lap.sh — D-SURVIVOR-CACHE-SERVES-A-DELETED-FILES-BMBT-BLOCK-FOR-A-PEERS-NEW-FILE
# on the 2-node TCP rig: a read of an extent-tree block that the bmbt write
# chokepoint in xfs_buf_submit_bio judges as if it were a write.
#
# The chokepoint (pal/linux/xfs_buf.c, mxfs_buf_xfsaild_skip_bmbt_write) drops
# a write of an extent-tree leaf whose owner is a directory this node holds NL.
# It reads that owner from the buffer's memory, and a buffer whose XBF_DONE an
# eviction cleared still holds the previous tree's image there.  So once a
# block of a deleted file's tree is reused by a new file, and the deleted
# file's inode number has become a directory the reader holds NL, the reader's
# READ of the new file's block matched the predicate: no bio was issued, the
# old image was completed as read, and the lookup was handed the deleted
# file's leaf (P975-BMBT-LOOKUP-BAD flags=0x60, the read failing with
# EFSCORRUPTED).  Each round builds that state on purpose:
#   1. V creates 8 fragmented files (4096 single-block extents each, fsync'd)
#      in a fresh directory; W lists them and reads the head of each, so W
#      caches every leaf of their trees under its grants.
#   2. V removes the 8 files: W's grants end and the tenure-end eviction
#      clears XBF_DONE on those leaves, whose images stay in W's memory.
#   3. V creates 8 directories in the same directory, which take the freed
#      inode numbers (the round prints how many did); W lists them, so they are
#      in core on W, and V then creates a file in each, so W holds them NL.
#   4. V creates 8 new fragmented files the same way, whose leaves land on the
#      blocks the deleted trees used; W reads the head of each.
# The trigger is W's kernel line P61-CHOKEPOINT-READ (the predicate matched a
# read; printed whatever bmbt_skip_reads says).  With the fix the read is
# issued and every head returns 4096 bytes.  BMBT_SKIP_READS=1 sets the knob on
# W for the lap (restored at exit): the old behaviour, the control.
#
# Verdict per lap: FAIL when any of W's reads of a new file returned fewer than
# 4096 bytes or W logged P975-BMBT-LOOKUP-BAD; PASS otherwise.  Exposure is the
# P61-CHOKEPOINT-READ count in the lap's own W log (dmesg_W.txt).
#
# Derived bound: measured 34-35 s for ROUNDS=3 on 2/net/mesh/direct (test1,
# test2; two builds of 8 files, the reads, removals and directories take 11-12 s
# a round), so the caller bound is 15 s a round plus 30 s for the checks and
# captures: 75 s for ROUNDS=3, 330 s for ROUNDS=20.  A timeout IS a failure.
#
# The rounds above reach the matched read every round, but with the knob on
# they never failed: the readahead's buffer was freed before the synchronous
# read of the same block, which then read fresh pages.  The open-EFI laps that
# failed show that read finding the readahead's own buffer 0.4 ms later.
# BMBT_RA_HOLD_MS=<ms> sets dbg_bmbt_ra_hold_ms on W for the lap (restored at
# exit): every bmbt readahead's buffer stays referenced that long after its
# submission, so the synchronous read finds it in both arms.
#
# Usage: [ROUNDS=3] [BMBT_SKIP_READS=0|1] [BMBT_RA_HOLD_MS=0] tests/bmbt_read_skip_lap.sh <label> [W=test1] [V=test2]
# Exit 0 = PASS, 1 = FAIL, 2 = ABORT (precondition).
set -u
LABEL=${1:?label}; W=${2:-test1}; V=${3:-test2}
ROUNDS=${ROUNDS:-3}; BMBT_SKIP_READS=${BMBT_SKIP_READS:-0}; BMBT_RA_HOLD_MS=${BMBT_RA_HOLD_MS:-0}
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
MNT=${MXFS_MNT:-/mnt/shared}
P=/sys/module/mxfs/parameters
. "$(dirname "$0")/lib/rig.sh"
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_bmbtrdskip_$LABEL
mkdir -p "$OUT"
fails=0
t0=$(date +%s); el() { echo $(( $(date +%s) - t0 )); }
SV=$(modinfo mxfs.ko 2>/dev/null | sed -n 's/^srcversion: *//p')
MARK="BRS-$LABEL-$$"
echo "=== bmbt_read_skip_lap label=$LABEL W=$W V=$V rounds=$ROUNDS skip_reads=$BMBT_SKIP_READS ra_hold_ms=$BMBT_RA_HOLD_MS sv=$SV out=$OUT $(date -u +%FT%TZ) ==="

for n in $W $V; do
    info=$(rs 20 "$n" "echo sv=\$(cat /sys/module/mxfs/srcversion) ft=\$(cat $P/force_transport) m=\$(grep -c ' $MNT mxfs ' /proc/mounts) knob=\$(test -w $P/bmbt_skip_reads && echo 1 || echo 0) hold=\$(test -w $P/dbg_bmbt_ra_hold_ms && echo 1 || echo 0)" | tr -d '\n')
    echo "  INFO $n $info"
    [[ "$info" == *"sv=$SV"* ]] || { echo "ABORT: $n srcversion != tree $SV"; echo "RESULT: ABORT label=$LABEL stage=build evidence=$OUT"; exit 2; }
    [[ "$info" == *"ft=1"* ]]  || { echo "ABORT: $n not on TCP"; echo "RESULT: ABORT label=$LABEL stage=transport evidence=$OUT"; exit 2; }
    [[ "$info" == *"m=1"* ]]   || { echo "ABORT: $n not mounted"; echo "RESULT: ABORT label=$LABEL stage=mount evidence=$OUT"; exit 2; }
    [[ "$info" == *"knob=1"* ]] || { echo "ABORT: $n lacks mxfs.bmbt_skip_reads"; echo "RESULT: ABORT label=$LABEL stage=knob evidence=$OUT"; exit 2; }
    [ "$BMBT_RA_HOLD_MS" = 0 ] || [[ "$info" == *"hold=1"* ]] || { echo "ABORT: $n lacks mxfs.dbg_bmbt_ra_hold_ms"; echo "RESULT: ABORT label=$LABEL stage=knob evidence=$OUT"; exit 2; }
done

rs 15 "$W" "echo $BMBT_SKIP_READS > $P/bmbt_skip_reads" >/dev/null
value_now_into knob "$W" 15 "$OUT/rv_knob.txt" '^knob=[01]$' "bmbt_skip_reads on $W" "echo knob=\$(cat $P/bmbt_skip_reads)"
ck "W's bmbt_skip_reads is the lap's" "${knob#knob=}" "$BMBT_SKIP_READS"
if [ "$BMBT_RA_HOLD_MS" != 0 ]; then
    rs 15 "$W" "echo $BMBT_RA_HOLD_MS > $P/dbg_bmbt_ra_hold_ms" >/dev/null
    value_now_into hold "$W" 15 "$OUT/rv_hold.txt" '^hold=[0-9]+$' "dbg_bmbt_ra_hold_ms on $W" "echo hold=\$(cat $P/dbg_bmbt_ra_hold_ms)"
    ck "W's dbg_bmbt_ra_hold_ms is the lap's" "${hold#hold=}" "$BMBT_RA_HOLD_MS"
fi
for n in $W $V; do rs 12 "$n" "echo '$MARK' > /dev/kmsg" >/dev/null; done
capture() {
    rs 40 "$W" "dmesg | sed -n \"/$MARK/,\\\$p\"" > "$OUT/dmesg_W.txt" 2>/dev/null
    rs 40 "$V" "dmesg | sed -n \"/$MARK/,\\\$p\"" > "$OUT/dmesg_V.txt" 2>/dev/null
    [ "$BMBT_SKIP_READS" = 0 ] || rs 15 "$W" "echo 0 > $P/bmbt_skip_reads" >/dev/null
    [ "$BMBT_RA_HOLD_MS" = 0 ] || rs 15 "$W" "echo 0 > $P/dbg_bmbt_ra_hold_ms; sleep 1" >/dev/null
    echo "  INFO capture: W=$(wc -l < "$OUT/dmesg_W.txt") V=$(wc -l < "$OUT/dmesg_V.txt") lines (+$(el)s)"
}
trap capture EXIT
trap 'capture; exit 124' TERM

# build <dir> <prefix>: 8 fragmented files on V, each fsync'd, then the directory
build_on_v() {
    rs 90 "$V" "python3 - <<'EOF'
import os
d='$1'
for f in range(8):
    p=os.path.join(d,'$2%d'%f)
    fd=os.open(p, os.O_CREAT|os.O_WRONLY|os.O_TRUNC, 0o644)
    for i in range(4096):
        os.pwrite(fd, b'\\xa5'*4096, i*8192)
    os.fsync(fd); os.close(fd)
    print('ino %s %d'%(os.path.basename(p), os.stat(p).st_ino))
dfd=os.open(d, os.O_RDONLY); os.fsync(dfd)
print('ok')
EOF"
}
# heads <dir> <prefix>: on W, the number of the 8 files whose first 4096 bytes read whole
heads_on_w() {
    echo "for i in 0 1 2 3 4 5 6 7; do head -c 4096 $1/$2\$i | wc -c; done | grep -c '^4096\$' || [ \$? = 1 ]"
}

total_short=0
for r in $(seq 1 "$ROUNDS"); do
    D=$MNT/.brs_${LABEL}_$r
    rs 20 "$V" "rm -rf $D; mkdir -p $D && sync" >/dev/null
    build_on_v "$D" f > "$OUT/build_f_$r.txt"
    grep -q '^ok$' "$OUT/build_f_$r.txt" || { echo "ABORT: round $r V build of f* failed: $(tail -2 "$OUT/build_f_$r.txt")"; echo "RESULT: ABORT label=$LABEL stage=build-f evidence=$OUT"; exit 2; }
    measure "$W" 60 "$OUT/rv_fread_$r.txt" '^[0-9]+$' "round $r W read of f*" "$(heads_on_w "$D" f)"
    fread=$(tr -dc '0-9' < "$OUT/rv_fread_$r.txt")
    rs 60 "$V" "rm -f $D/f[0-7] && sync" >/dev/null
    measure "$V" 30 "$OUT/rv_dirs_$r.txt" '^ino ' "round $r V mkdir of e*" "for i in 0 1 2 3 4 5 6 7; do mkdir $D/e\$i && echo ino e\$i \$(stat -c %i $D/e\$i); done; sync"
    reused=$(awk 'NR==FNR{if($1=="ino")f[$3]=1; next} $1=="ino" && ($3 in f){c++} END{print c+0}' "$OUT/build_f_$r.txt" "$OUT/rv_dirs_$r.txt")
    measure "$W" 30 "$OUT/rv_wls_$r.txt" '^[0-9]+$' "round $r W listing of e*" "ls -l $D | grep -c ' e[0-7]\$' || [ \$? = 1 ]"
    rs 30 "$V" "for i in 0 1 2 3 4 5 6 7; do touch $D/e\$i/x; done; sync" >/dev/null
    build_on_v "$D" g > "$OUT/build_g_$r.txt"
    grep -q '^ok$' "$OUT/build_g_$r.txt" || { echo "ABORT: round $r V build of g* failed: $(tail -2 "$OUT/build_g_$r.txt")"; echo "RESULT: ABORT label=$LABEL stage=build-g evidence=$OUT"; exit 2; }
    measure "$W" 60 "$OUT/rv_gread_$r.txt" '^[0-9]+$' "round $r W read of g*" "$(heads_on_w "$D" g)"
    gread=$(tr -dc '0-9' < "$OUT/rv_gread_$r.txt")
    total_short=$((total_short + 8 - gread))
    echo "  INFO round $r: W read f*=$fread/8 before the removal; directories on freed inode numbers=$reused/8; W listed e*=$(tr -dc '0-9' < "$OUT/rv_wls_$r.txt"); W read g*=$gread/8 (+$(el)s)"
    ck "round $r: W read the 8 f* files before their removal" "$fread" "8"
done

capture; trap - EXIT
matched=$(grep -ac 'P61-CHOKEPOINT-READ ' "$OUT/dmesg_W.txt")
skipped=$(grep -a 'P61-CHOKEPOINT-READ ' "$OUT/dmesg_W.txt" | grep -ac 'skipped, the old image')
bad=$(grep -ac 'P975-BMBT-LOOKUP-BAD' "$OUT/dmesg_W.txt")
shut=$(grep -ac 'Shutting down filesystem\|BUG:\|Oops' "$OUT/dmesg_W.txt")
held=$(grep -ac 'P-BMBT-RA-HOLD ' "$OUT/dmesg_W.txt")
echo "  INFO W kernel log: P61-CHOKEPOINT-READ=$matched (skipped=$skipped) P975-BMBT-LOOKUP-BAD=$bad shutdown_or_oops=$shut readahead_holds=$held"
echo "LAP bmbt_read_skip exposed: matched_reads=$matched"
ck "W read every new file's head whole (short reads)" "$total_short" "0"
ck "W logged no P975-BMBT-LOOKUP-BAD" "$bad" "0"
ck "W logged no shutdown, BUG or Oops" "$shut" "0"
[ "$BMBT_SKIP_READS" = 0 ] && ck "no read was skipped with the fix in" "$skipped" "0"
if [ "$fails" -gt 0 ]; then
    echo "RESULT: FAIL label=$LABEL fails=$fails matched=$matched skipped=$skipped bad=$bad short=$total_short wall=$(el)s evidence=$OUT"; exit 1
fi
echo "RESULT: PASS label=$LABEL matched=$matched skipped=$skipped bad=$bad short=$total_short wall=$(el)s evidence=$OUT"
exit 0
