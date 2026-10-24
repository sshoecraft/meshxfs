#!/bin/bash
# tauth_make_goal_lap.sh -- one lap of
# D-TAUTH-MAKEFILE-DEFAULT-GOAL-IS-ONE-OBJECT-AND-CLEAN-MISSES-TWO-BINARIES.
#
# tests/tauth/Makefile's first rule is an object, so a plain 'make' built that
# one object and the documented 'make -C tests/tauth && ./tauth_test' ran
# whatever tauth_test was already there; 'all' omitted seal_barrier_test and
# 'clean' omitted it and local_page_full_test.  The fix makes 'all' the default
# goal and names every binary in all and clean.
#
# The defect is in the host build, so the lap runs on the host, through the
# Makefile, in a scratch copy of the sources it builds from (dlm/, pal/,
# include/ and tests/tauth/, sources and the Makefile only, no binary):
#   1. a plain 'make' (no target);
#   2. every binary of the Makefile's 'test' line and seal_barrier_test must
#      exist, built by step 1;
#   3. 'make all': every one of them must exist;
#   4. 'make clean': none of them, and no obj/, may remain.
#
#   EXPOSED  step 1 ran a plain make in a copy holding no binary
#   PASS     steps 1 and 3 built every binary and step 4 removed every one
#   FAIL     a binary was not built by the plain make or by make all, or
#            survived the clean
#   ABORT    a make failed or the lap overran its bound
#
# The control is TAUTH_GOAL_ALL=0 in this lap's environment, which make reads:
# the first rule's object as the goal and the old lists, on the same Makefile.
#
# Bound, derived: the full build measured 17 s in tests/tauth_header_dep_lap.sh's
# precheck, the clean under 1 s, the copy under 1 s: twice that, 40 s.
#
# Usage: tests/tauth_make_goal_lap.sh [label]
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
LABEL=${1:-lap}
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
BOUND=40
T0=$(date +%s)
S=$(mktemp -d /tmp/tauth_make_goal_lap.XXXXXX) || exit 2
trap 'rm -rf -- "$S"' EXIT
abort() { echo "LAP tauth_make_goal ABORT label=$LABEL: $*"; exit 2; }
left() { echo $(( BOUND - ($(date +%s) - T0) )); }
BINS="tauth_test ledger_test dlm_ledger_test formation_test concurrent_release_test unowned_page_test
      bootstrap_race_test view_format_test stale_image_release_test group_commit_test
      own_release_resync_test local_page_full_test seal_barrier_test"

echo "LAP tauth_make_goal start $(date -u +%FT%TZ) tree=$HERE TAUTH_GOAL_ALL=${TAUTH_GOAL_ALL:-unset} scratch=$S"
for d in dlm pal include tests/tauth; do
    mkdir -p "$S/$d"
    rsync -a --exclude 'obj/' --include '*/' --include '*.c' --include '*.h' --include 'Makefile' --exclude '*' \
        "$HERE/$d/" "$S/$d/" || abort "copy of $d failed"
done
for b in $BINS; do [ -e "$S/tests/tauth/$b" ] && abort "the scratch copy carries $b"; done
echo "EXPOSED: a plain make in a copy of tests/tauth holding no binary"

timeout "$(left)" make -s -C "$S/tests/tauth" > "$S/make.log" 2>&1
rc=$?; [ "$rc" = 124 ] && abort "the plain make overran the ${BOUND} s bound"
[ "$rc" = 0 ] || abort "the plain make failed (rc=$rc): $(tail -3 "$S/make.log" | tr '\n' ' ')"
unbuilt=(); for b in $BINS; do [ -x "$S/tests/tauth/$b" ] || unbuilt+=("$b"); done
echo "STEP plain make: $(( 13 - ${#unbuilt[@]} )) of 13 binaries built, $(ls "$S/tests/tauth/obj"/*.o 2>/dev/null | wc -l) objects"

timeout "$(left)" make -s -C "$S/tests/tauth" all > "$S/all.log" 2>&1
rc=$?; [ "$rc" = 124 ] && abort "make all overran the ${BOUND} s bound"
[ "$rc" = 0 ] || abort "make all failed (rc=$rc): $(tail -3 "$S/all.log" | tr '\n' ' ')"
noall=(); for b in $BINS; do [ -x "$S/tests/tauth/$b" ] || noall+=("$b"); done
echo "STEP make all: $(( 13 - ${#noall[@]} )) of 13 binaries present"

timeout "$(left)" make -s -C "$S/tests/tauth" clean > "$S/clean.log" 2>&1
rc=$?; [ "$rc" = 124 ] && abort "make clean overran the ${BOUND} s bound"
[ "$rc" = 0 ] || abort "make clean failed (rc=$rc): $(tail -3 "$S/clean.log" | tr '\n' ' ')"
kept=(); for b in $BINS; do [ -e "$S/tests/tauth/$b" ] && kept+=("$b"); done
[ -e "$S/tests/tauth/obj" ] && kept+=("obj/")
echo "STEP make clean: ${#kept[@]} left"
[ "$(left)" -lt 0 ] && abort "the lap overran its ${BOUND} s bound"
if [ "${#unbuilt[@]}" -gt 0 ] || [ "${#noall[@]}" -gt 0 ] || [ "${#kept[@]}" -gt 0 ]; then
    echo "LAP tauth_make_goal FAIL label=$LABEL: not built by a plain make: ${unbuilt[*]:-none}; not built by make all: ${noall[*]:-none}; left by make clean: ${kept[*]:-none}"
    exit 1
fi
echo "LAP tauth_make_goal PASS label=$LABEL: a plain make built all 13 binaries and make clean removed them ($(( $(date +%s) - T0 )) s)"
exit 0
