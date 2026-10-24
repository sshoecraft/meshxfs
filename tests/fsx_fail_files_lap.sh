#!/bin/bash
# fsx_fail_files_lap.sh -- one lap of
# D-FSX-SH-EXIT-TRAP-REMOVES-FSX-OWN-FSXLOG-AND-FSXGOOD-WITH-THE-WORK-DIR, on a
# rig node, where the defect lives.
#
# tests/suite/fsx.sh runs fsx on a test file in its work directory $W on the
# mxfs mount, and fsx wrote its own .fsxlog, .fsxops and .fsxgood beside that
# file; the row's EXIT trap removes $W however the row ends, so only fsx's
# stdout log (in /root) was kept.  The fix has fsx write them from the start
# with its own -P into /root/fsx.<seed>.<ops>.d/, off the mount.
#
# The lap runs tests/fsx_fail_files_node.sh on NODE over ssh, from the tree
# over NFS: the row as a node runs it (work directory on the mxfs mount,
# FSX_LOG_DIR unset, so the kept files go to /root), with a second writer that
# makes both checks miscompare for certain, then a listing of what survived in
# /root.  It needs a formed pair (the mount at MNT on NODE).
#
#   EXPOSED  the row failed both of its checks on the mxfs mount
#   PASS     each failed check left its .log and its .fsxlog, .fsxops, .fsxgood
#   FAIL     a failed check's fsx files were removed with the work directory
#   ABORT    the row did not fail both checks, gave no RESULT line, or overran
#
# The control is FSX_KEEP_FAIL_FILES=0 in this lap's environment, passed to the
# node: fsx.sh then runs fsx without -P, as before, on the same source.  The
# old lap ran on the host's /dev/shm, where the old fix's move was a rename
# within one filesystem: it never measured the row on a node
# (data/reviews/P20261023-b32dc8.md).
#
# Bound, derived: the node body's own 28 s (the fsx row's worst passing wall on
# mxfs, 13 s, twice, plus 2 s for the writer) plus 10 s for the ssh connect and
# the listing: 38 s.  An overrun is an ABORT, never a reason to raise it.
#
# Usage: tests/fsx_fail_files_lap.sh <label> [node=test1] [mount=/mnt/shared]
#        FSX_KEEP_FAIL_FILES=0 tests/fsx_fail_files_lap.sh <label> ...   (control)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
LABEL=${1:?label}; NODE=${2:-test1}; MNT=${3:-/mnt/shared}
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
. "$HERE/tools/mxfs_lab.sh"
SSH="$HERE/tools/mxfs_sshpass.sh"
NREPO=/src/$(basename "$HERE")
BOUND=38
OUT=$HERE/tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_fsxfail_$LABEL
mkdir -p "$OUT"
exec > >(tee -a "$OUT/lap.log") 2>&1

echo "LAP fsx_fail_files start $(date -u +%FT%TZ) node=$NODE mount=$MNT tree=$NREPO FSX_KEEP_FAIL_FILES=${FSX_KEEP_FAIL_FILES:-unset} out=$OUT"
keep=""; [ -n "${FSX_KEEP_FAIL_FILES:-}" ] && keep="FSX_KEEP_FAIL_FILES=$FSX_KEEP_FAIL_FILES "
timeout "$BOUND" "$SSH" "$(lab_addr "$NODE")" "${keep}$NREPO/tests/fsx_fail_files_node.sh $MNT $LABEL; echo node_rc=\$?" \
    </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$' > "$OUT/node.txt"
rc=${PIPESTATUS[0]}
cat "$OUT/node.txt"
[ "$rc" = 124 ] && { echo "LAP fsx_fail_files ABORT: the lap overran its ${BOUND} s bound"; exit 2; }
nrc=$(sed -n 's/^node_rc=\([0-9]*\)$/\1/p' "$OUT/node.txt" | tail -1)
case "$nrc" in
    0) echo "LAP fsx_fail_files PASS label=$LABEL node=$NODE: $(grep -a '^NODE fsx_fail_files PASS' "$OUT/node.txt" | cut -c27-)"; exit 0 ;;
    1) echo "LAP fsx_fail_files FAIL label=$LABEL node=$NODE: $(grep -a '^NODE fsx_fail_files FAIL' "$OUT/node.txt" | cut -c27-)"; exit 1 ;;
    *) echo "LAP fsx_fail_files ABORT label=$LABEL node=$NODE: node_rc=${nrc:-none} (ssh rc=$rc)"; exit 2 ;;
esac
