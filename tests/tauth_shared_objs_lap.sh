#!/bin/bash
# tauth_shared_objs_lap.sh -- one lap of
# D-TAUTH-TEST-OBJECTS-OMIT-INCLUDED-HEADERS-SO-A-HEADER-CHANGE-LINKS-STALE-CODE: the tauth lap
# scripts link five shared objects (dlm.o, dlm_shared.o, tauth_ledger.o, tauth_store.o, pal_user.o),
# built by tests/tauth/shared_objs.sh.  Built with `make` in tests/tauth they kept the code of a
# header the Makefile's rules do not list, after that header changed, so a lap measured code that
# was not the tree under test.
#
# The lap copies the sources the objects compile from (dlm/, include/, pal/, and tests/tauth/'s
# Makefile and sources) into a scratch directory, builds the objects there with the tree's
# tests/tauth/shared_objs.sh, then appends to the copy's pal/pal.h -- included by all five sources
# and listed by none of the Makefile's rules -- a definition carrying a mark unique to the lap,
# builds again, and reads the mark in each object the second build produced.  The tree is not
# touched.
#
#   PASS  every object carries the mark: each was compiled from the header as it now is
#   FAIL  an object lacks it: it was linked as built before the header changed (named)
#   ABORT the copy or a build failed
#
# Exposure: on every lap the header changes after a build of the objects (EXPOSED: line).
# TAUTH_SHARED_FROM_CLEAN passes through to the helper: 0 is its own same-build control, `make` in
# the copy's tests/tauth.
#
# Bound, derived: two clean builds of the five objects (8.8 s measured) and the copy (under 2 s):
# about 20 s; bounded at 60 s.
#
# Usage: tests/tauth_shared_objs_lap.sh   (host only)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
cd "$(dirname "$0")/.." || exit 2
ROOT=$(pwd)
S=$(mktemp -d /tmp/mxfs_tauth_objlap.XXXXXX) || { echo "LAP tauth_objs ABORT: no scratch directory"; exit 2; }
trap 'rm -rf -- "$S"' EXIT
mark="TAUTHLAP-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
echo "LAP tauth_objs start $(date -u +%FT%TZ) from_clean=${TAUTH_SHARED_FROM_CLEAN:-1} mark=$mark"
mkdir -p "$S/top/tests" || exit 2
rsync -a --exclude '*.o' "$ROOT/dlm" "$ROOT/include" "$ROOT/pal" "$S/top/" \
  && rsync -a --exclude 'obj/' --include '*/' --include 'Makefile' --include '*.c' --include '*.h' \
           --exclude '*' "$ROOT/tests/tauth" "$S/top/tests/" \
  || { echo "LAP tauth_objs ABORT: the copy failed"; exit 2; }
. "$ROOT/tests/tauth/shared_objs.sh"
tauth_shared_objs "$S/top" "$S/out1" > "$S/first.txt" 2> "$S/first.err" \
  || { echo "LAP tauth_objs ABORT: the first build failed: $(tail -3 "$S/first.err" | tr '\n' ' ')"; exit 2; }
# make compares modification times: the header must be newer than every object
sleep 1
cat >> "$S/top/pal/pal.h" <<EOF
#ifndef MXFS_TAUTH_LAP_MARK
#define MXFS_TAUTH_LAP_MARK
static const char mxfs_tauth_lap_mark[] __attribute__((used)) = "$mark";
#endif
EOF
echo "EXPOSED: header-changed pal/pal.h after the first build of $(grep -c . "$S/first.txt") objects"
tauth_shared_objs "$S/top" "$S/out2" > "$S/second.txt" 2> "$S/second.err" \
  || { echo "LAP tauth_objs ABORT: the second build failed: $(tail -3 "$S/second.err" | tr '\n' ' ')"; exit 2; }
n=0; stale=""
while read -r obj; do
    [ -n "$obj" ] || continue
    n=$((n + 1))
    grep -aqF "$mark" "$obj" || stale="$stale ${obj##*/}"
done < "$S/second.txt"
if [ "$n" -ne 5 ]; then
    echo "LAP tauth_objs ABORT: the second build named $n objects, not 5"
    exit 2
fi
if [ -z "$stale" ]; then
    echo "LAP tauth_objs PASS: all $n objects carry the mark: compiled from pal/pal.h as it now is"
    exit 0
fi
echo "LAP tauth_objs FAIL: built before pal/pal.h changed and linked as they were:${stale}"
exit 1
