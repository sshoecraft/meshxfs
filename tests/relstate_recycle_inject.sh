#!/bin/bash
# relstate_recycle_inject.sh — D-RECYCLED-INODE-INHERITS-WEDGED-REL-STATE:
# a new in-core inode allocated in memory whose last occupant wedged must
# start ACTIVE, not refuse every lock acquire for the life of the mount.
#
# Observed (16/disk/caw/mpath path_all_lost, 0.90.123): test16 was fenced,
# its unmount wedged one inode at teardown, it remounted, and the first
# acquire on an inode the new mount had just read was refused as wedged; its
# open() restarted forever.  mxfs_dlm_inode_init never assigned
# i_mxfs_rel_state, and the slab does not zero the objects it hands out.
#
# Shape: B creates FILES files in a fresh directory (none of them cached on
# A).  A sets dbg_relstate_wedge_on_free, drops its inode cache — every inode
# it frees goes back to the slab carrying WEDGED — and clears the knob.  A
# then reads and appends to every file, so each new in-core inode it builds
# is likely to land on poisoned memory.  Every operation is bounded by
# OP_S seconds: P-ACQ-STUCK's own 15 s threshold for a lock wait that is not
# contention; a healthy cross-node acquire is milliseconds.
#
# PASS iff every read and append on A succeeds within OP_S, A's kernel log
# shows the cause reached (P-RELSTATE-RECYCLED >= 1: an inode was allocated
# in poisoned memory) and no acquire was refused as wedged
# (P-INODE-WEDGE-FENCE = 0), and neither node logged a shutdown.
#
# Budget: create FILES on B (~1 s per 100), drop caches (~1 s), FILES x 2
# ops on A (ms each, bounded OP_S), two kernel-log pulls: ~30 s at 200 files.
#
# RRI_INIT_ACTIVE=0 sets relstate_init_active=0 on A for the operations, so a
# new inode keeps a WEDGED state its memory held (the read before the fix, the
# same-build control); it is set back to 1 at the end.  Default 1.
#
# Usage: tests/relstate_recycle_inject.sh <label> <A> <B> [files]
set -u
LABEL=${1:?label}; A=${2:?node A}; B=${3:?node B}; FILES=${4:-200}
INIT_ACTIVE=${RRI_INIT_ACTIVE:-1}
case "$INIT_ACTIVE" in 0|1) ;; *) echo "RESULT: ABORT label=$LABEL stage=args RRI_INIT_ACTIVE=$INIT_ACTIVE"; exit 2 ;; esac
OP_S=15
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO"
SSH=tools/mxfs_sshpass.sh
MNT=${MXFS_MNT:-/mnt/shared}
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_rri_$LABEL
mkdir -p "$OUT"
. "$(dirname "$0")/lib/rig.sh"
fails=0
D="$MNT/.rri_$LABEL"
MARK="RRI-$LABEL-$$"
KNOB=/sys/module/mxfs/parameters/dbg_relstate_wedge_on_free
SWITCH=/sys/module/mxfs/parameters/relstate_init_active

echo "=== relstate_recycle_inject label=$LABEL A=$A B=$B files=$FILES out=$OUT $(date -u +%FT%TZ) ==="
want=$(modinfo mxfs.ko | awk '/^srcversion:/{print $2}')
for n in "$A" "$B"; do
    nsv=$(rs 15 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$nsv" = "$want" ] || { echo "ABORT: $n srcversion '$nsv' != tree '$want'"; echo "RESULT: ABORT label=$LABEL stage=srcversion evidence=$OUT"; exit 2; }
    rs 12 "$n" "echo '$MARK' > /dev/kmsg" >/dev/null
done

measure "$B" 60 "$OUT/create.txt" '^CREATED [0-9]+$' "file creation on $B" \
    "rm -rf $D; mkdir $D && for i in \$(seq 1 $FILES); do echo seed-\$i > $D/f\$i || break; done; sync; echo CREATED \$(ls $D | wc -l)"
ck "$B created every file" "$(awk '/^CREATED/ {print $2}' "$OUT/create.txt")" "$FILES"

# A caches every file first: the drop below can only poison memory A's own
# inodes occupied.  Then knob on, drop A's inode cache, and hold the knob
# across RECLAIM_S: evict only marks an inode reclaimable, and XFS frees it
# from its reclaim worker (xfs_syncd_centisecs / 6 = 5 s by default).  The
# slab's active count before and after shows the frees landed inside the
# window.
RECLAIM_S=8
measure "$A" 60 "$OUT/cache.txt" '^CACHED [0-9]+$' "caching the files on $A" \
    "n=0; for i in \$(seq 1 $FILES); do cat $D/f\$i >/dev/null && n=\$((n+1)); done; echo CACHED \$n"
ck "$A read every file before the poisoning" "$(awk '/^CACHED/ {print $2}' "$OUT/cache.txt")" "$FILES"
measure "$A" $((RECLAIM_S + 30)) "$OUT/poison.txt" '^KNOB_AFTER [0-9]+$' "poisoning on $A" \
    "act() { awk '\$1 == \"mxfs_inode\" {print \$2}' /proc/slabinfo; }; echo SLAB_BEFORE \$(act); echo 1 > $KNOB && sync && echo 2 > /proc/sys/vm/drop_caches; echo KNOB_SET_RC \$?; sleep $RECLAIM_S; echo 2 > /proc/sys/vm/drop_caches; sleep 1; echo SLAB_AFTER \$(act); echo 0 > $KNOB; echo KNOB_AFTER \$(cat $KNOB)"
ck "$A's knob was set and the drop ran" "$(awk '/^KNOB_SET_RC/ {print $2}' "$OUT/poison.txt")" 0
ck "$A's knob is off again" "$(awk '/^KNOB_AFTER/ {print $2}' "$OUT/poison.txt")" 0
sb=$(awk '/^SLAB_BEFORE/ {print $2}' "$OUT/poison.txt"); sa=$(awk '/^SLAB_AFTER/ {print $2}' "$OUT/poison.txt")
echo "  INFO $A mxfs_inode active objects before=$sb after=$sa"
ckge "$A freed inodes while the knob was on (active objects fell)" "$(( ${sb:-0} - ${sa:-0} ))" 1

got=$(rs 12 "$A" "echo $INIT_ACTIVE > $SWITCH && cat $SWITCH" | tr -dc '0-9')
ck "$A's relstate_init_active reads $INIT_ACTIVE for the operations" "$got" "$INIT_ACTIVE"

# one line per file: f<i> read_rc=<n> append_rc=<n> ms=<n>
rs $(( FILES * OP_S * 2 + 30 )) "$A" "for i in \$(seq 1 $FILES); do t0=\$(date +%s%3N); timeout -s KILL $OP_S cat $D/f\$i >/dev/null 2>&1; r=\$?; timeout -s KILL $OP_S sh -c 'echo more >> $D/f'\$i 2>/dev/null; w=\$?; echo \"f\$i read_rc=\$r append_rc=\$w ms=\$(( \$(date +%s%3N) - t0 ))\"; done; echo OPS_DONE" > "$OUT/ops.txt"
ck "$A's operation loop finished" "$(grep -ac '^OPS_DONE$' "$OUT/ops.txt")" 1
ck "$A read every file" "$(grep -ac 'read_rc=0 ' "$OUT/ops.txt")" "$FILES"
ck "$A appended to every file" "$(grep -ac 'append_rc=0 ' "$OUT/ops.txt")" "$FILES"
echo "  INFO $A max op pair ms=$(sed -n 's/.* ms=//p' "$OUT/ops.txt" | sort -n | tail -1)"
grep -a -v 'read_rc=0 append_rc=0' "$OUT/ops.txt" | grep -a '^f' | head -3 | sed 's/^/    /'
rs 12 "$A" "echo 1 > $SWITCH" >/dev/null

for n in "$A" "$B"; do
    measure "$n" 30 "$OUT/kmsg_$n.txt" '^KMSG_END$' "the kernel log on $n from the run marker" "dmesg | sed -n '/$MARK/,\$p'; echo KMSG_END"
    grep -aq "$MARK" "$OUT/kmsg_$n.txt" || { echo "ABORT: $n's kernel log no longer holds the run marker"; echo "RESULT: ABORT label=$LABEL stage=kmsg-rotated node=$n evidence=$OUT"; exit 2; }
    ck "$n: no shutdown, BUG, oops or hung task" "$(cnt "$OUT/kmsg_$n.txt" 'P-SESSION-POISON\|force-shutdown\|Internal error\|BUG:\|Oops\|blocked for more than')" 0
done
recyc=$(cnt "$OUT/kmsg_$A.txt" 'P-RELSTATE-RECYCLED')
fence=$(cnt "$OUT/kmsg_$A.txt" 'P-INODE-WEDGE-FENCE')
echo "  INFO $A P-RELSTATE-RECYCLED=$recyc P-INODE-WEDGE-FENCE=$fence"
[ "$recyc" -ge 1 ] 2>/dev/null && echo "EXPOSED: $A allocated $recyc new inode(s) in memory whose last occupant wedged"
ckge "$A allocated an inode in poisoned memory (the cause was reached)" "$recyc" 1
ck "$A refused no acquire as wedged" "$fence" 0

rs 30 "$A" "rm -rf $D" >/dev/null
echo "RESULT: $([ $fails -eq 0 ] && echo PASS || echo FAIL) label=$LABEL recycled=$recyc wedge_fence=$fence fails=$fails evidence=$OUT"
exit $((fails > 0))
