#!/bin/bash
# control_precheck.sh -- does a lap tell the fix in from the fix out, before a control batch of it
# is declared?
#
# A control batch (tools/harness_batch.py control) is recorded in the defect queue and closed
# whatever its laps show. When the lap does not measure the defect, every lap passes with the fix
# out, and the record carries a closed control that bounds nothing (b20261022-ec8648: a probe
# handed the configuration on its command line, where tools/criteria.py sets MXFS_OWN_RIG
# itself). This runs the lap once with the fix in and once with it taken out, and exits 0 only
# when the first passed and the second failed, so an unattended lane declares the control only
# after its lap has been shown to measure.
#
#   tools/control_precheck.sh <fix.diff> [--rebuild CMD] -- <lap command> [args...]
#
# The lap's verdict is its exit status: 0 PASS, 1 FAIL, anything else measured nothing. The fix is
# taken out by applying DIFF in reverse (patch -p1, as harness_batch.py does) and put back on any
# exit, a signal included; every file it touches must hash as it did before, or this exits 3.
# --rebuild CMD runs CMD (through the shell, in the tree) after the fix is taken out and again
# after it is put back, for a fix in a compiled tool.
#
# Nothing here is bounded itself: the lap bounds itself, and patch and the hashes take
# milliseconds.
#
# Exit: 0 the lap passed with the fix and failed without it; 1 it did not tell them apart (the
# two verdicts are printed); 2 a usage error or the fix does not come out cleanly; 3 the tree could
# not be restored.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO" || exit 2
DIFF=${1:?usage: control_precheck.sh <fix.diff> [--rebuild CMD] -- <lap command>}
shift
REBUILD=
[ "${1:-}" = --rebuild ] && { REBUILD=$2; shift 2; }
[ "${1:-}" = -- ] || { echo "control_precheck: the lap command follows --"; exit 2; }
shift
[ $# -gt 0 ] || { echo "control_precheck: name the lap command after --"; exit 2; }
[ -f "$DIFF" ] || { echo "control_precheck: no diff at $DIFF"; exit 2; }
patch -p1 -R --dry-run -s -i "$DIFF" > /dev/null || { echo "control_precheck: the fix does not come out cleanly"; exit 2; }

FILES=$(sed -n 's|^+++ b/\([^[:space:]]*\).*|\1|p' "$DIFF")
hashes() { for f in $FILES; do sha256sum "$f"; done; }
BEFORE=$(hashes)
OUT=0
restore() {
    [ "$OUT" = 1 ] || return 0
    patch -p1 -s --no-backup-if-mismatch -i "$DIFF" || { echo "control_precheck: RESTORE FAILED: apply $DIFF by hand"; exit 3; }
    OUT=0
    [ "$(hashes)" = "$BEFORE" ] || { echo "control_precheck: RESTORE MISMATCH: $FILES differ from before"; exit 3; }
    [ -z "$REBUILD" ] || bash -c "$REBUILD" > /dev/null 2>&1 || { echo "control_precheck: the rebuild with the fix back in failed"; exit 3; }
    echo "control_precheck: the fix is back in ($FILES hash as before)"
}
trap 'restore; exit 2' INT TERM HUP

echo "=== control_precheck: $* with the fix in ==="
"$@"; fixed=$?
echo "=== control_precheck: the fix in -> rc=$fixed ==="
patch -p1 -R -s --no-backup-if-mismatch -i "$DIFF" || { echo "control_precheck: taking the fix out failed"; exit 2; }
OUT=1
if [ -n "$REBUILD" ] && ! bash -c "$REBUILD" > /dev/null 2>&1; then
    restore
    echo "control_precheck: the rebuild with the fix out failed"; exit 2
fi
echo "=== control_precheck: $* with the fix out ==="
"$@"; reverted=$?
echo "=== control_precheck: the fix out -> rc=$reverted ==="
restore
if [ "$fixed" = 0 ] && [ "$reverted" = 1 ]; then
    echo "CONTROL_PRECHECK OK the lap passed with the fix in and failed with it out"
    exit 0
fi
echo "CONTROL_PRECHECK NO the lap gave rc=$fixed with the fix in and rc=$reverted with it out: it does not measure the defect"
exit 1
