#!/bin/bash
# fsx_fail_files_node.sh -- the node-side body of tests/fsx_fail_files_lap.sh,
# run on a rig node from the tree over NFS, as root, on a mounted mxfs.
#
# It runs tests/suite/fsx.sh as the board runs it on a node (MXFS_NODES=1, its
# work directory on the mxfs mount, FSX_LOG_DIR unset so the kept files go to
# /root) while a second writer overwrites every test file of the row with
# random bytes until the row ends, so each check's next verify miscompares
# (READ BAD DATA, or a Size error when fsx shrank the file between the
# writer's stat and its write), and both end in fsx's report_failure, which
# dumps .fsxops and .fsxgood.  Then it lists what of the row's files survived
# in /root: the kept stdout log /root/fsx.<seed>.<ops>.log and fsx's own files
# in /root/fsx.<seed>.<ops>.d/ (or, with FSX_KEEP_FAIL_FILES=0, the control,
# nothing of them: fsx wrote them into the work directory the row's EXIT trap
# removes).
#
# Bound, derived: the fsx row passes in 10-13 s on a 2-node mxfs pair (board
# fsx runs of 0.90.134); a miscompare ends a check sooner.  Twice the worst is
# 26 s, plus 2 s for the writer's dd forks: 28 s.  An overrun is an ABORT.
#
# Usage (on the node): tests/fsx_fail_files_node.sh <mount> <label>
# Prints one 'NODE fsx_fail_files' verdict line; exit 0 PASS, 1 FAIL, 2 ABORT.
MNT=${1:?mount}; LABEL=${2:?label}
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
FSXSH="$HERE/suite/fsx.sh"
BOUND=28
OUT=/root/fsx_fail_files_$LABEL.row.out
TRAPLOG=/root/fsx_fail_files_$LABEL.trap.log

grep -q " $MNT mxfs " /proc/mounts || { echo "NODE fsx_fail_files ABORT: $MNT is not an mxfs mount"; exit 2; }
echo "NODE fsx_fail_files start $(date -u +%FT%TZ) host=$(hostname) mount=$MNT FSX_KEEP_FAIL_FILES=${FSX_KEEP_FAIL_FILES:-unset} FSX_WRITER_NOCREAT=${FSX_WRITER_NOCREAT:-unset}"
left0=$(ls -d "$MNT"/.suite_fsx.* 2>/dev/null | wc -l)
t0=$(date +%s%3N)
rm -f "$TRAPLOG"
FSX_TRAP_LOG=$TRAPLOG MXFS_NODES=1 timeout -k 5 "$BOUND" "$FSXSH" "$MNT" > "$OUT" 2>&1 &
row=$!

# the second writer: the row's test files are fsxfile_<ops>; fsx's own files
# carry a suffix and are left alone.  The writer runs until the row's process
# exits, and the row's EXIT trap removes the work directory inside that
# process, so a file the writer stat'ed before the trap's rm -rf unlinked it
# was created again by its dd, and the trap's rmdir left the directory on the
# mount (fxn3 at 2/net/mesh/direct: fsxfile_50000, born 4 ms after the row
# ended,
# D-FSX-FAIL-FILES-LAP-WRITER-RECREATES-A-TEST-FILE-AND-LEAVES-THE-WORK-DIRECTORY).
# So it only ever overwrites a file that exists (conv=nocreat).
# FSX_WRITER_NOCREAT=0 lets dd create the file, as before: the control.
DDCONV=notrunc,nocreat
[ "${FSX_WRITER_NOCREAT:-1}" = 0 ] && DDCONV=notrunc
writes=0
while kill -0 "$row" 2>/dev/null; do
    for f in "$MNT"/.suite_fsx."$(hostname)".*/fsxfile_*; do
        case "$f" in *'*'*|*.fsx*) continue ;; esac
        sz=$(stat -c %s "$f" 2>/dev/null) || continue
        [ "$sz" -gt 0 ] || sz=4096
        dd if=/dev/urandom of="$f" bs="$sz" count=1 conv="$DDCONV" status=none 2>/dev/null &&
            writes=$((writes + 1))
    done
    sleep 0.01
done
wait "$row"
rc=$?
wall=$(( $(date +%s%3N) - t0 ))

result=$(grep -a '^RESULT:' "$OUT" | tail -n 1)
echo "NODE fsx_fail_files row rc=$rc wall_ms=$wall writer_overwrites=$writes"
echo "NODE fsx_fail_files ${result:-no RESULT line}"
if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    echo "NODE fsx_fail_files ABORT: the row overran its ${BOUND} s bound (rc=$rc)"; exit 2
fi
[ -n "$result" ] || { echo "NODE fsx_fail_files ABORT: the row gave no RESULT line"; exit 2; }
failed=$(printf '%s' "$result" | sed -n 's/.*[ =]failed=\([0-9]*\).*/\1/p')
seed=$(printf '%s' "$result" | sed -n 's/.* seed=\([0-9]*\).*/\1/p')
if [ "${failed:-0}" -lt 2 ] || [ -z "$seed" ]; then
    echo "NODE fsx_fail_files ABORT: the row did not fail both checks (failed=${failed:-?} seed=${seed:-?})"; exit 2
fi
left=$(ls -d "$MNT"/.suite_fsx."$(hostname)".* 2>/dev/null | wc -l)
echo "EXPOSED: the fsx row failed both checks on the mxfs mount (failed=$failed seed=$seed), work directories left on the mount: $left"
# what the row's EXIT trap's rm did (removed names, errors, exit status), and
# each work directory left with every name in it and its birth, so a leftover
# says whether a name the trap removed was created again after it
echo "NODE fsx_fail_files trap log ($TRAPLOG): $(grep -c '^removed' "$TRAPLOG" 2>/dev/null) removed"
grep -av '^removed' "$TRAPLOG" 2>/dev/null | sed 's/^/  TRAP /'
grep -a '^removed .*fsxfile_[0-9]*.$' "$TRAPLOG" 2>/dev/null | sed 's/^/  TRAP /'
for d in "$MNT"/.suite_fsx."$(hostname)".*; do
    [ -e "$d" ] || continue
    stat -c "  LEFT DIR %n birth=%w" "$d"
    for f in "$d"/* "$d"/.[!.]*; do
        [ -e "$f" ] && stat -c "  LEFT FILE %n size=%s birth=%w" "$f"
    done
done
echo "NODE fsx_fail_files survived in /root:"
ls -la /root/fsx."$seed".* /root/fsx."$seed".*.d/ 2>/dev/null | sed 's/^/  /'

missing=""
for ops in 100000 50000; do
    [ -s "/root/fsx.$seed.$ops.log" ] || missing="$missing fsx.$seed.$ops.log"
    # .fsxgood is the image the file should hold, written at the file's size:
    # a check that miscompares on its first operation, while the file is still
    # empty, leaves an empty one (precheck fpre1: a 606-byte log, a 0-byte
    # .fsxgood), so it is required to exist, the other two to be non-empty
    for s in fsxlog fsxops; do
        [ -s "/root/fsx.$seed.$ops.d/fsxfile_$ops.$s" ] || missing="$missing fsx.$seed.$ops.d/fsxfile_$ops.$s"
    done
    [ -e "/root/fsx.$seed.$ops.d/fsxfile_$ops.fsxgood" ] || missing="$missing fsx.$seed.$ops.d/fsxfile_$ops.fsxgood"
done
if [ -n "$missing" ]; then
    echo "NODE fsx_fail_files FAIL: removed with the row:$missing"; exit 1
fi
# a work directory the row's trap did not remove is this lap's own failure
# (D-FSX-FAIL-FILES-LAP-WRITER-RECREATES-A-TEST-FILE-AND-LEAVES-THE-WORK-DIRECTORY);
# directories already on the mount before the row are not this lap's
if [ "$left" -gt "$left0" ]; then
    echo "NODE fsx_fail_files FAIL: the row's work directory was left on the mount ($left0 before the row, $left after)"; exit 1
fi
echo "NODE fsx_fail_files PASS: each failed check's log and its .fsxlog, .fsxops and .fsxgood survived the row in /root"
exit 0
