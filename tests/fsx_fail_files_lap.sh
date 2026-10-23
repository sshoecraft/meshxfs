#!/bin/bash
# fsx_fail_files_lap.sh -- one host-only lap of
# D-FSX-SH-EXIT-TRAP-REMOVES-FSX-OWN-FSXLOG-AND-FSXGOOD-WITH-THE-WORK-DIR.
#
# tests/suite/fsx.sh runs fsx on a test file in its work directory $W, where fsx
# writes its own .fsxlog, .fsxops and .fsxgood beside the file, and its EXIT trap
# removes $W however the row ends; only fsx's stdout log was kept.  The fix moves
# a failing check's three files out to the kept log's name before the trap runs.
#
# fsx is made to miscompare for certain: a second writer overwrites every test
# file of the row with random bytes, over its whole length, until the row ends,
# so each check's next verify fails: READ BAD DATA, or a Size error when fsx
# shrank the file between the writer's stat and its write.  Both end in fsx's
# report_failure, which dumps .fsxops and .fsxgood.  fsx.sh itself runs as one
# node runs it (MXFS_NODES=1), on a scratch directory of the host's tmpfs in
# place of the mount, with FSX_LOG_DIR in that scratch directory in place of
# /root so the lap needs no root; the defect is in what the row removes, not in
# the filesystem under it.  After the row the lap lists every file left in the
# scratch directory: what survived the row.
#
#   EXPOSED  the row failed both of its checks (the suite library's failed=2)
#   PASS     each failed check left its .log, .fsxlog, .fsxops and .fsxgood
#   FAIL     a failed check's fsx files were removed with the work directory
#   ABORT    the row did not fail both checks, gave no RESULT line, or overran
#
# The control is FSX_KEEP_FAIL_FILES=0 in this lap's environment, which fsx.sh
# reads: the old removal, on the same source.
#
# Bound, derived: fsx.sh's two checks (100k and 50k operations) took 2.34-2.35 s
# in three passing runs on a scratch directory of /dev/shm (tests/fsx_seed_lap.sh);
# a miscompare ends a check sooner.  Twice that is 4.7 s, plus 1 s for the
# writer's dd forks competing for the CPU: 6 s.  An overrun is an ABORT, never a
# reason to raise it.
#
# Usage: tests/fsx_fail_files_lap.sh            (fix in)
#        FSX_KEEP_FAIL_FILES=0 tests/fsx_fail_files_lap.sh   (control)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
FSXSH="$HERE/suite/fsx.sh"
BOUND=6

D=$(mktemp -d -p /dev/shm) || { echo "LAP fsx_fail_files ABORT: no scratch directory"; exit 2; }
trap 'rm -rf -- "$D"' EXIT
MNTD="$D/mnt"
LOGD="$D/logs"
mkdir -p "$MNTD" "$LOGD" || { echo "LAP fsx_fail_files ABORT: cannot make $MNTD $LOGD"; exit 2; }

echo "LAP fsx_fail_files start $(date -u +%FT%TZ) fsx.sh=$FSXSH FSX_KEEP_FAIL_FILES=${FSX_KEEP_FAIL_FILES:-unset}"
t0=$(date +%s%3N)
FSX_LOG_DIR="$LOGD" MXFS_NODES=1 timeout -k 5 "$BOUND" "$FSXSH" "$MNTD" > "$D/row.out" 2>&1 &
row=$!

# The second writer: the row's test files are fsxfile_<ops>; fsx's own files
# beside them carry a suffix and are left alone.
writes=0
while kill -0 "$row" 2>/dev/null; do
    for f in "$MNTD"/.suite_fsx.*/fsxfile_*; do
        case "$f" in *'*'*|*.fsx*) continue ;; esac
        sz=$(stat -c %s "$f" 2>/dev/null) || continue
        [ "$sz" -gt 0 ] || sz=4096
        dd if=/dev/urandom of="$f" bs="$sz" count=1 conv=notrunc status=none 2>/dev/null &&
            writes=$((writes + 1))
    done
    sleep 0.01
done
wait "$row"
rc=$?
wall=$(( $(date +%s%3N) - t0 ))

result=$(grep -a '^RESULT:' "$D/row.out" | tail -n 1)
echo "LAP fsx_fail_files row rc=$rc wall_ms=$wall writer_overwrites=$writes"
echo "LAP fsx_fail_files ${result:-no RESULT line}"
echo "LAP fsx_fail_files survived the row:"
( cd "$D" && find . -path ./row.out -prune -o -print | sort | while read -r p; do
      [ "$p" = . ] && continue
      if [ -f "$p" ]; then echo "  SURVIVED $p $(stat -c %s "$p") bytes"; else echo "  SURVIVED $p/"; fi
  done )

if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    echo "LAP fsx_fail_files ABORT: the row overran its ${BOUND} s bound (rc=$rc)"; exit 2
fi
[ -n "$result" ] || { echo "LAP fsx_fail_files ABORT: the row gave no RESULT line"; exit 2; }
failed=$(printf '%s' "$result" | sed -n 's/.*[ =]failed=\([0-9]*\).*/\1/p')
seed=$(printf '%s' "$result" | sed -n 's/.* seed=\([0-9]*\).*/\1/p')
if [ "${failed:-0}" -lt 2 ] || [ -z "$seed" ]; then
    echo "LAP fsx_fail_files ABORT: the row did not fail both checks (failed=${failed:-?} seed=${seed:-?})"; exit 2
fi
echo "EXPOSED: the fsx row failed both checks (failed=$failed seed=$seed)"

# What each failure was, from fsx's kept stdout, and how many lines of a kept
# .fsxlog that stdout does not carry: whether .fsxlog adds anything to it.
for ops in 100000 50000; do
    l="$LOGD/fsx.$seed.$ops.log"
    echo "LAP fsx_fail_files ops=$ops first failure line: $(grep -m1 -aE 'BAD|bad|short|error|Error|fail' "$l" 2>/dev/null | cut -c1-200)"
    if [ -f "$LOGD/fsx.$seed.$ops.fsxlog" ]; then
        echo "LAP fsx_fail_files ops=$ops .fsxlog lines=$(wc -l < "$LOGD/fsx.$seed.$ops.fsxlog") stdout lines=$(wc -l < "$l") .fsxlog lines not in stdout=$(comm -23 <(sort "$LOGD/fsx.$seed.$ops.fsxlog") <(sort "$l") | wc -l)"
    fi
done

missing=""
for ops in 100000 50000; do
    for s in log fsxlog fsxops fsxgood; do
        [ -s "$LOGD/fsx.$seed.$ops.$s" ] || missing="$missing fsx.$seed.$ops.$s"
    done
done
if [ -n "$missing" ]; then
    echo "LAP fsx_fail_files FAIL: removed with the row:$missing"; exit 1
fi
echo "LAP fsx_fail_files PASS: each failed check's .log, .fsxlog, .fsxops and .fsxgood survived the row"
exit 0
