#!/bin/bash
# One lap of D-MKFS-PRINTS-GIB-LABELLED-GB: does mkfs.mxfs label the sizes it prints in the
# binary units it computes them in?
#
# human_size in tools/mkfs_mxfs.c divides by 1024^3, 1024^2 and 1024 and printed the results as
# GB, MB and KB, so a 2 GiB device read '2.00 GB'. The fix prints GiB, MiB and KiB. The label is
# printed, never written to the volume.
#
# The lap formats a 2048 MiB loop image of 512-byte sectors through tests/mkfs_layout_identity.py
# image (the release's own way of running mkfs on the host) and reads what mkfs printed:
#
#     EXPOSED  the print holds the device's size, 2.00 in a gigabyte-scale unit (the GiB branch
#              of human_size was taken)
#     PASS     every size printed carries GiB, MiB or KiB, and none carries GB, MB or KB
#     FAIL     a size labelled GB, MB or KB
#
# The fix arm runs the candidate's tools/mkfs_mxfs. MKFS_LABEL_REVERT=1 is the control: the same
# tools/mkfs_mxfs.c with only human_size's three labels put back to GB, MB and KB, built with
# tools/Makefile's flags into the lap's scratch directory; the lap prints the revert's diff and its
# sha256 as the variant.
#
# Bound, measured: the fix arm 0.24 s a lap (the format itself 0.1 s), the control 0.99-1.03 s
# (its gcc of mkfs_mxfs.c); twice the slower, 3 s. The format is bounded at 2 s inside it.
#
# Usage: tests/mkfs_size_label_lap.sh
# Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/..
# a draft under tests/evidence/drafts/tree/tests runs against the tree it sits in
while [ ! -f "$ROOT/tools/mkfs_mxfs.c" ] || [ ! -f "$ROOT/VERSION" ]; do
    [ "$ROOT" = / ] && { echo "RESULT: ABORT no tree root above $HERE"; exit 2; }
    ROOT=$(cd "$ROOT/.." && pwd)
done
cd "$ROOT" || exit 2
D=$(mktemp -d "${TMPDIR:-/tmp}/mkfs_size_label.XXXXXX") || exit 2
trap 'sudo -n rm -rf -- "$D"' EXIT
MKFS=$ROOT/tools/mkfs_mxfs
echo "INFO MKFS_LABEL_REVERT=${MKFS_LABEL_REVERT:-(unset)}"
if [ "${MKFS_LABEL_REVERT:-0}" = 1 ]; then
    cp tools/mkfs_mxfs.c "$D/mkfs_mxfs.c"
    s=$(grep -n '^static const char \*human_size' "$D/mkfs_mxfs.c" | cut -d: -f1)
    [ -n "$s" ] || { echo "RESULT: ABORT no human_size in tools/mkfs_mxfs.c"; exit 2; }
    sed -i "$s,$((s + 12))s/ GiB\"/ GB\"/; $s,$((s + 12))s/ MiB\"/ MB\"/; $s,$((s + 12))s/ KiB\"/ KB\"/" "$D/mkfs_mxfs.c"
    diff -u --label a/tools/mkfs_mxfs.c --label b/tools/mkfs_mxfs.c tools/mkfs_mxfs.c "$D/mkfs_mxfs.c" > "$D/revert.diff"
    [ "$(grep -c '^+ .*snprintf' "$D/revert.diff")" = 3 ] \
        || { echo "RESULT: ABORT the revert did not change exactly human_size's three labels"; cat "$D/revert.diff"; exit 2; }
    cat "$D/revert.diff"
    echo "VARIANT: label-revert sha256=$(sha256sum < "$D/revert.diff" | cut -d' ' -f1)"
    IFS=. read -r MA MI PA < VERSION
    # -Itools: the copy sits outside tools/, and mkfs_mxfs.c includes headers beside it
    gcc -Wall -Wextra -O2 -Iinclude -Itools -DMXFS_VERSION_MAJOR="$MA" -DMXFS_VERSION_MINOR="$MI" \
        -DMXFS_VERSION_PATCH="$PA" -o "$D/mkfs_mxfs" "$D/mkfs_mxfs.c" \
        || { echo "RESULT: ABORT the control build failed"; exit 2; }
    MKFS=$D/mkfs_mxfs
fi
timeout 2 python3 tests/mkfs_layout_identity.py image "$MKFS" "$D/img" 2048 512
rc=$?
[ "$rc" = 0 ] && [ -s "$D/img.mkfs.txt" ] || { echo "RESULT: ABORT the format did not complete (rc=$rc)"; exit 2; }
echo "--- what mkfs printed"
cat "$D/img.mkfs.txt"
echo "---"
if ! grep -qE '(^|[^0-9.])2\.00 Gi?B' "$D/img.mkfs.txt"; then
    echo "RESULT: ABORT the print holds no 2.00 GB or GiB size: the GiB branch was not reached"
    exit 2
fi
echo "EXPOSED: mkfs printed the 2048 MiB device's size in a gigabyte-scale unit"
bad=$(grep -oE '[0-9]+\.[0-9]+ [KMG]B([^a-zA-Z]|$)' "$D/img.mkfs.txt" | sort | uniq -c | tr '\n' ' ')
good=$(grep -cE '[0-9]+\.[0-9]+ [KMG]iB' "$D/img.mkfs.txt")
if [ -n "$bad" ]; then
    echo "LAP mkfs_size_label FAIL: sizes labelled in decimal units for binary values: $bad"
    exit 1
fi
if [ "$good" -lt 1 ]; then
    echo "LAP mkfs_size_label FAIL: no size labelled GiB, MiB or KiB"
    exit 1
fi
echo "LAP mkfs_size_label PASS: $good line(s) of sizes, every one labelled GiB, MiB or KiB"
exit 0
