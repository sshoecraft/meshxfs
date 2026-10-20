#!/bin/bash
# tests/chk_unlinked_dir_residue.sh — does tools/chk_mxfs grade a removed
# directory that is still open, and so still on its AGI unlinked bucket (the
# state a crash leaves behind an rmdir whose free had not run), as link-count
# errors?  D-CHK-COUNTS-UNLINKED-DIR-DOT-AND-DOTDOT-AS-LINKS-FALSE-NLINK-ERRORS.
#
# WHY.  crl8m1's cold audit (8/net/mesh/mpath) listed an empty directory on an
# unlinked bucket with nlink 0, which chk_mxfs's own orphan audit calls legal
# crash residue, and then reported 'inode 128 has nlink 4 but 5 directory
# entries name it' and 'inode 8411809 has nlink 0 but 1 directory entries name
# it': the removed directory's own '..' and '.', both dropped by the rmdir,
# counted as links.
#
# HYPOTHESIS H-CK1 (the record, written before the patch): the link-count pass
# counts an nlink-0 directory's '.' and '..'.
#
# CORRECTED AFTER LAP cud1 (graded NOT-FIXED on this file's first rules, which
# predicted an nlink error naming p1): the rmdir repoints a removed directory's
# '..' at the root when its parent is not the root (xfs/libxfs/xfs_dir2.c,
# xfs_dir_remove_child, 'Point the unlinked child directory's ".." entry to
# the root'), so cud1's frozen dinodes show d2's and p2's '..' = 128, and the
# old binary reported root 'nlink 3 but 6' (three removed directories) and each
# removed directory 'nlink 0 but 1', and nothing naming p1.  A removed
# directory's '..' therefore never dangles; every one adds a link to the root.
# The rules below are written for lap cud2 onward.
#
# WHAT IT DOES.  Preps <config> on <group> (every node mounted), unmounts every
# node but the first (A), and on A makes p1, p1/d1, p2 and p2/d2, starts one
# holder process with d1 as its working directory and one with d2, and runs
# rmdir p1/d1, rmdir p2/d2, rmdir p2.  d1 and d2 are then removed directories
# held open (nlink 0, on their buckets), each '..' repointed at the root; p2,
# removed and not held, is freed on its own schedule and may still be on its
# bucket too.  fsfreeze -f quiesces A (the log forced and the metadata written
# home), and this host reads the pool LUN's backing file, read-only, with two
# binaries: the tree's tools/chk_mxfs (OLD) and the patched binary named on the
# command line (NEW).  tools/mxfs_dinode.py prints p1, d1, p2 and d2 from the
# same frozen image, so the state each binary graded is on record.  A then
# thaws, the holders exit, A unmounts, and both binaries read the image again.
#
# THE HOST READ.  SCST serves a pool LUN from a file on this host
# (vdisk_fileio, tools/lun_pool.sh).  posix_fadvise(DONTNEED) on that file
# before each read drops every clean cached page of it, so the read sees what
# the target wrote whichever way the target writes.  The image is never written
# here.  While A is mounted its journal slice reads ACTIVE, so chk_mxfs exits 8
# ('not replayed: not a verdict') on the frozen image; that only downgrades
# superblock counters to notes (chk_mxfs.c counter_err), so the frozen reads are
# graded on their ERROR and bucket-member lines, not their exit code.
#
# VERDICT (written before lap cud2; cud1's rules predicted an error naming p1):
#   CONFIRMED-FIXED  on the frozen image both binaries list d1 and d2 as
#                    bucket members; OLD reports an nlink ERROR naming d1, one
#                    naming d2 and one naming the root; NEW reports no ERROR
#                    line at all; after the clean unmount both exit 0 with no
#                    ERROR line and no bucket member.
#   REFUTED          d1 is listed on its bucket and OLD reports no nlink ERROR
#                    naming d1 or the root.
#   NOT-FIXED        NEW reports an ERROR on the frozen image, or either binary
#                    reports an ERROR, a bucket member or a non-zero exit after
#                    the clean unmount.
#   VACUOUS          the frozen image does not list d1 on a bucket (the state
#                    was not on the platter when it was read).
#   ABORT            prep, unmount, setup or freeze failed.
# Whether p2 was freed by the time of the freeze is printed, not graded: the
# free of an unopened removed directory runs on its own schedule.
#
# Usage: tests/chk_unlinked_dir_residue.sh <label> <new-chk_mxfs> [config] [group]
#   default config 4/net/mesh/direct, group g4 (a group must have exactly the
#   configuration's node count; any count of two or more works)
# Bound: prep 300 + unmounts 60 + setup 30 + freeze 30 + four host reads 4x60
# + dinode prints 30 + thaw, holder exit and unmount 90 + capture 20 = 800 s.
# Exit 0 CONFIRMED-FIXED, 1 REFUTED / NOT-FIXED, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; NEWCHK=${2:?the patched chk_mxfs binary}
CONFIG=${3:-4/net/mesh/direct}; GROUP=${4:-g4}
cd "$(dirname "$0")/.." || exit 2
[ -x "$NEWCHK" ] || { echo "RESULT: ABORT label=$LABEL -- $NEWCHK is not an executable"; exit 2; }
OLDCHK=tools/chk_mxfs
SSH=tools/mxfs_sshpass.sh
NODES=($(tools/mxfs_lab.sh group "$GROUP"))
[ "${#NODES[@]}" -ge 2 ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has fewer than two nodes"; exit 2; }
A=${NODES[0]}
. tests/lib/runlock.sh
vmhold_take "chk_unlinked_dir_residue $LABEL" "${NODES[@]}" \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold ${NODES[*]}"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_chk_unlinked_dir_residue_$LABEL
mkdir -p "$OUT"
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
echo "=== chk_unlinked_dir_residue label=$LABEL $CONFIG $GROUP [${NODES[*]}] A=$A old=$OLDCHK new=$NEWCHK build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
# the ring survives a module reload: failures are counted after this mark only
MARK="CHK-UNLINKED-DIR-RESIDUE-$LABEL-$$"
for n in "${NODES[@]}"; do rs 20 "$n" "echo $MARK > /dev/kmsg" > /dev/null; done
csv=$(IFS=,; echo "${NODES[*]}")
IMG=$(tools/lun_pool.sh lookup --nodes "$csv" | grep -o ' img=[^ ]*' | cut -d= -f2)
[ -n "$IMG" ] && [ -r "$IMG" ] || { echo "RESULT: ABORT label=$LABEL -- no readable pool LUN image bound to [$csv] ('$IMG') evidence=$OUT"; exit 2; }
echo "pool LUN image: $IMG"

# every node but A unmounts, so A's freeze quiesces the only writer
for n in "${NODES[@]:1}"; do
    rs 60 "$n" "umount /mnt/shared; mountpoint -q /mnt/shared && echo MOUNTED || echo unmounted" > "$OUT/${n}_umount.txt" &
done
wait
for n in "${NODES[@]:1}"; do
    grep -q '^unmounted' "$OUT/${n}_umount.txt" || { echo "RESULT: ABORT label=$LABEL stage=unmount -- $n: $(cat "$OUT/${n}_umount.txt") evidence=$OUT"; exit 2; }
done

D=/mnt/shared/cud.$LABEL
rs 30 "$A" "set -e; mkdir -p $D/p1/d1 $D/p2/d2; sync
for h in 1 2; do nohup setsid sh -c \"echo \\\$\\\$ > /run/cud_$LABEL.h\$h; cd $D/p\$h/d\$h && exec sleep 600\" > /dev/null 2>&1 < /dev/null & done
sleep 1
echo ino p1=\$(stat -c %i $D/p1) d1=\$(stat -c %i $D/p1/d1) p2=\$(stat -c %i $D/p2) d2=\$(stat -c %i $D/p2/d2)
rmdir $D/p1/d1 $D/p2/d2; rmdir $D/p2; sync
for h in 1 2; do echo holder\$h pid=\$(cat /run/cud_$LABEL.h\$h) cwd_links=\$(stat -L -c %h /proc/\$(cat /run/cud_$LABEL.h\$h)/cwd); done
echo setup-ok" > "$OUT/setup.txt"
cat "$OUT/setup.txt"
grep -q '^setup-ok' "$OUT/setup.txt" || { echo "RESULT: ABORT label=$LABEL stage=setup evidence=$OUT"; exit 2; }
read -r P1 D1 P2 D2 <<< "$(sed -n 's/^ino p1=\([0-9]*\) d1=\([0-9]*\) p2=\([0-9]*\) d2=\([0-9]*\)$/\1 \2 \3 \4/p' "$OUT/setup.txt")"
[ -n "${D2:-}" ] || { echo "RESULT: ABORT label=$LABEL stage=setup -- inode numbers did not parse evidence=$OUT"; exit 2; }

# the host read: drop clean cached pages of the backing file, then check
hostchk() {  # <binary> <out file> -> exit code of the check
    python3 -c "import os,sys; fd=os.open(sys.argv[1], os.O_RDONLY); os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED); os.close(fd)" "$IMG"
    timeout 60 "$1" -v "$IMG" > "$2" 2>&1
}
grade() {  # <out file> -> "errors=N nlink_d1=N nlink_d2=N nlink_root=N nlink_p1=N member_d1=N member_d2=N members=N"
    local f=$1 root
    root=$(grep -ao 'rootino=[0-9]*' "$f" | head -1 | cut -d= -f2)
    echo "errors=$(grep -ac '^  ERROR: ' "$f") nlink_d1=$(grep -ac "ERROR: inode $D1 .*has nlink" "$f") nlink_d2=$(grep -ac "ERROR: inode $D2 .*has nlink" "$f") nlink_root=$(grep -ac "ERROR: inode ${root:-128} .*has nlink" "$f") nlink_p1=$(grep -ac "ERROR: inode $P1 .*has nlink" "$f") member_d1=$(grep -ac "unlinked bucket [0-9]*: member ino=$D1 " "$f") member_d2=$(grep -ac "unlinked bucket [0-9]*: member ino=$D2 " "$f") members=$(grep -ac 'unlinked bucket [0-9]*: member ino=' "$f")"
}
field() { echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

rs 30 "$A" "timeout 25 fsfreeze -f /mnt/shared && echo frozen" > "$OUT/freeze.txt"
grep -q '^frozen' "$OUT/freeze.txt" || { echo "RESULT: ABORT label=$LABEL stage=freeze -- $(cat "$OUT/freeze.txt") evidence=$OUT"; rs 30 "$A" "fsfreeze -u /mnt/shared"; exit 2; }
hostchk "$OLDCHK" "$OUT/frozen_old.txt"; rc_fo=$?
hostchk "$NEWCHK" "$OUT/frozen_new.txt"; rc_fn=$?
timeout 30 python3 tools/mxfs_dinode.py --img "$IMG" "$P1" "$D1" "$P2" "$D2" > "$OUT/frozen_dinodes.txt" 2>&1
rs 30 "$A" "timeout 25 fsfreeze -u /mnt/shared && echo thawed" > "$OUT/thaw.txt"
g_fo=$(grade "$OUT/frozen_old.txt"); g_fn=$(grade "$OUT/frozen_new.txt")
echo "frozen dinodes:"; sed 's/^/  /' "$OUT/frozen_dinodes.txt"
echo "frozen OLD rc=$rc_fo $g_fo"
grep -a '^  ERROR: ' "$OUT/frozen_old.txt" | head -6
echo "frozen NEW rc=$rc_fn $g_fn"
grep -a '^  ERROR: ' "$OUT/frozen_new.txt" | head -6
grep -q '^thawed' "$OUT/thaw.txt" || { echo "RESULT: ABORT label=$LABEL stage=thaw -- $(cat "$OUT/thaw.txt") (A left frozen) evidence=$OUT"; exit 2; }

# the holders exit, A unmounts cleanly, and both binaries read the image again
rs 90 "$A" "for h in 1 2; do kill \$(cat /run/cud_$LABEL.h\$h) 2>/dev/null; rm -f /run/cud_$LABEL.h\$h; done; sleep 2; sync; umount /mnt/shared; mountpoint -q /mnt/shared && echo MOUNTED || echo unmounted" > "$OUT/final_umount.txt"
grep -q '^unmounted' "$OUT/final_umount.txt" || { echo "RESULT: ABORT label=$LABEL stage=final-unmount -- $(cat "$OUT/final_umount.txt") evidence=$OUT"; exit 2; }
hostchk "$OLDCHK" "$OUT/clean_old.txt"; rc_co=$?
hostchk "$NEWCHK" "$OUT/clean_new.txt"; rc_cn=$?
g_co=$(grade "$OUT/clean_old.txt"); g_cn=$(grade "$OUT/clean_new.txt")
echo "clean OLD rc=$rc_co $g_co"
echo "clean NEW rc=$rc_cn $g_cn"
for n in "${NODES[@]}"; do
    rs 20 "$n" "dmesg | awk '/$MARK/ {keep = 1; next} keep' | grep -a -E 'Shutting down filesystem|P-WITHDRAW|P131-SELF-FENCE|BUG:|Oops|blocked for more than|Corruption of in-memory' | tail -5" > "$OUT/${n}_failures.txt"
done
nf=$(cat "$OUT"/*_failures.txt | grep -c .)
echo "node failure lines: $nf"

REP="p1=$P1 d1=$D1 p2=$P2 d2=$D2 frozen_old=[rc=$rc_fo $g_fo] frozen_new=[rc=$rc_fn $g_fn] clean_old=[rc=$rc_co $g_co] clean_new=[rc=$rc_cn $g_cn] node_failures=$nf"
if [ "$(field "$g_fo" member_d1)" = 0 ] || [ "$(field "$g_fn" member_d1)" = 0 ]; then
    echo "RESULT: VACUOUS chk_unlinked_dir_residue label=$LABEL $REP -- the frozen image does not list d1 on an unlinked bucket evidence=$OUT"; exit 3
fi
if [ "$(field "$g_fo" nlink_d1)" = 0 ] && [ "$(field "$g_fo" nlink_root)" = 0 ]; then
    echo "RESULT: REFUTED chk_unlinked_dir_residue label=$LABEL $REP -- OLD reports no nlink error for the removed directory or the root evidence=$OUT"; exit 1
fi
if [ "$(field "$g_fn" errors)" != 0 ] || [ "$(field "$g_co" errors)" != 0 ] || [ "$(field "$g_cn" errors)" != 0 ] \
   || [ "$(field "$g_co" members)" != 0 ] || [ "$(field "$g_cn" members)" != 0 ] || [ "$rc_co" != 0 ] || [ "$rc_cn" != 0 ] || [ "$nf" != 0 ]; then
    echo "RESULT: NOT-FIXED chk_unlinked_dir_residue label=$LABEL $REP evidence=$OUT"; exit 1
fi
if [ "$(field "$g_fo" nlink_d1)" -gt 0 ] && [ "$(field "$g_fo" nlink_root)" -gt 0 ] && [ "$(field "$g_fo" nlink_d2)" -gt 0 ] && [ "$(field "$g_fn" member_d2)" -gt 0 ]; then
    echo "RESULT: CONFIRMED-FIXED chk_unlinked_dir_residue label=$LABEL $REP evidence=$OUT"; exit 0
fi
echo "RESULT: NOT-FIXED chk_unlinked_dir_residue label=$LABEL $REP -- OLD did not report every predicted error evidence=$OUT"; exit 1
