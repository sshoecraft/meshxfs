#!/bin/bash
# tauth_header_dep_lap.sh -- one lap of
# D-TAUTH-TEST-OBJECTS-OMIT-INCLUDED-HEADERS-SO-A-HEADER-CHANGE-LINKS-STALE-CODE.
#
# tests/tauth/Makefile's object rules listed only some of the headers each
# source includes (none for dlm_shared.o and pal_user.o, and pal/pal.h for
# none), so after a header change a plain make relinked the old objects.  The
# fix has the compiler write each object's header dependencies (-MMD -MP) and
# makes them prerequisites.
#
# The defect is in the host build, so the lap runs on the host, through the
# Makefile itself, in a scratch copy of the sources it builds from (dlm/, pal/,
# include/ and tests/tauth/, sources and the Makefile only): building in the
# tree would rewrite frozen test binaries.
#   1. make all                           (the objects and binaries, fresh)
#   2. append a marker string to pal/pal.h and another to dlm/dlm.h, each a
#      static const array kept in every object that includes the header
#   3. make all again, plain: no -B, no clean
#   4. the marks in each shared object (pal/pal.h's in dlm.o, dlm_shared.o,
#      tauth_ledger.o, tauth_store.o and pal_user.o; dlm/dlm.h's in
#      dlm_shared.o, tauth_store.o and tauth_ledger.o) and in dlm_ledger_test,
#      which links all five
#
#   EXPOSED  both headers changed after step 1 built every object
#   PASS     every object and the binary carries its header's mark
#   FAIL     an object, or the binary, still lacks a mark: linked stale
#   ABORT    a build failed or the lap overran its bound
#
# The control is TAUTH_DEPS=0 in this lap's environment, which make reads: the
# rules' own header lists alone, as before the fix, on the same Makefile.
#
# TAUTH_FIRST_NODEP=1 makes step 1 a build with TAUTH_DEPS=0, so every object
# is one the pre-fix rules built, with no .d beside it, as the objects a tree
# built before the fix holds.  Step 3 then runs with the lap's own TAUTH_DEPS:
# what it measures is the fix's other branch, which rebuilds an object that
# has no .d (tests/tauth/Makefile, the obj/%.d prerequisite with an empty
# recipe).  EXPOSED then also needs step 1 to have left no .d file.
#
# Bound, derived: measured by this lap's precheck on the tree of 2026-10-23
# (the first build compiles dlm.c and fourteen tests, 17 s; the second
# recompiles what the marks reach, 12-17 s; 30-35 s a lap; the TAUTH_FIRST_NODEP=1
# variant on 2026-10-24 recompiles all 19 objects, 18 s, 37 s a lap), twice the
# longest: 74 s.
#
# Usage: tests/tauth_header_dep_lap.sh [label]
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
LABEL=${1:-lap}
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
BOUND=${TAUTH_DEP_BOUND:-74}
T0=$(date +%s)
S=$(mktemp -d /tmp/tauth_header_dep_lap.XXXXXX) || exit 2
trap 'rm -rf -- "$S"' EXIT
abort() { echo "LAP tauth_header_dep ABORT label=$LABEL: $*"; exit 2; }
left() { echo $(( BOUND - ($(date +%s) - T0) )); }

FIRST_NODEP=${TAUTH_FIRST_NODEP:-0}
echo "LAP tauth_header_dep start $(date -u +%FT%TZ) tree=$HERE TAUTH_DEPS=${TAUTH_DEPS:-unset} TAUTH_FIRST_NODEP=$FIRST_NODEP scratch=$S"
for d in dlm pal include tests/tauth; do
    mkdir -p "$S/$d"
    rsync -a --exclude 'obj/' --include '*/' --include '*.c' --include '*.h' --include 'Makefile' --exclude '*' \
        "$HERE/$d/" "$S/$d/" || abort "copy of $d failed"
done
[ -e "$S/tests/tauth/obj" ] && abort "the scratch copy carries objects"

if [ "$FIRST_NODEP" = 1 ]; then
    TAUTH_DEPS=0 timeout "$(left)" make -s -C "$S/tests/tauth" all > "$S/make1.log" 2>&1
else
    timeout "$(left)" make -s -C "$S/tests/tauth" all > "$S/make1.log" 2>&1
fi
rc=$?; [ "$rc" = 124 ] && abort "the first build overran the ${BOUND} s bound"
[ "$rc" = 0 ] || abort "the first build failed (rc=$rc): $(tail -3 "$S/make1.log" | tr '\n' ' ')"
ndep=$(ls "$S/tests/tauth/obj"/*.d 2>/dev/null | wc -l)
echo "STEP first build: $(ls "$S/tests/tauth/obj"/*.o | wc -l) objects, $ndep .d file(s), $(( $(date +%s) - T0 )) s"
[ "$FIRST_NODEP" = 1 ] && [ "$ndep" != 0 ] && abort "not exposed: the first build with TAUTH_DEPS=0 left $ndep .d file(s)"

# Which of the two headers each shared object's source really includes, asked
# of the compiler (-MM, the rules' own -I paths), not of any rule's list.
declare -A SRC=([dlm]=dlm/dlm.c [dlm_shared]=dlm/dlm_shared.c [tauth_ledger]=dlm/tauth_ledger.c
                [tauth_store]=dlm/tauth_store.c [pal_user]=pal/linux/user.c)
declare -A INCL
for o in "${!SRC[@]}"; do
    deps=$(cd "$S/tests/tauth" && gcc -I"$S" -I"$S/include" -I"$S/pal" -MM "$S/${SRC[$o]}" 2>&1 | tr -d '\\\n')
    INCL[$o]=""
    for h in pal/pal.h dlm/dlm.h; do
        case "$deps" in *"$S/$h"*|*"/$h "*) INCL[$o]="${INCL[$o]} $h" ;; esac
    done
    echo "STEP obj/$o.o (${SRC[$o]}) includes:${INCL[$o]:- neither}"
done

sleep 1   # a header newer than every object, whatever the filesystem's timestamp grain
nonce=$(date +%s%N)
PM="TAUTHDEPMARK-PAL-$nonce"; DM="TAUTHDEPMARK-DLM-$nonce"
mark() {  # mark <header> <name> <string>: inside the header's include guard, before its last #endif
    local at; at=$(grep -n '^#endif' "$1" | tail -1 | cut -d: -f1)
    [ -n "$at" ] || abort "$1 has no closing #endif to mark inside"
    sed -i "${at}i static const char $2[] __attribute__((used)) = \"$3\";" "$1"
}
mark "$S/pal/pal.h" tauth_dep_mark_pal "$PM"
mark "$S/dlm/dlm.h" tauth_dep_mark_dlm "$DM"
echo "EXPOSED: pal/pal.h and dlm/dlm.h changed after the first build ($PM, $DM)$([ "$FIRST_NODEP" = 1 ] && echo ", which left no object a .d")"

t1=$(date +%s)
timeout "$(left)" make -C "$S/tests/tauth" all > "$S/make2.log" 2>&1
rc=$?; [ "$rc" = 124 ] && abort "the second build overran the ${BOUND} s bound"
[ "$rc" = 0 ] || abort "the second build failed (rc=$rc): $(tail -3 "$S/make2.log" | tr '\n' ' ')"
echo "STEP second build: $(grep -c ' -c -o ' "$S/make2.log") object(s) recompiled, $(( $(date +%s) - t1 )) s"

missing=()
for o in "${!SRC[@]}"; do
    for h in pal/pal.h dlm/dlm.h; do
        case " ${INCL[$o]} " in *" $h "*) ;; *) continue ;; esac
        m=$PM; [ "$h" = dlm/dlm.h ] && m=$DM
        grep -aq "$m" "$S/tests/tauth/obj/$o.o" || missing+=("obj/$o.o includes $h and lacks its mark")
    done
done
for m in "$PM" "$DM"; do
    grep -aq "$m" "$S/tests/tauth/dlm_ledger_test" || missing+=("dlm_ledger_test lacks $m")
done
[ "$(left)" -lt 0 ] && abort "the lap overran its ${BOUND} s bound"
if [ "${#missing[@]}" -gt 0 ]; then
    echo "LAP tauth_header_dep FAIL label=$LABEL: a plain make linked stale objects: $(IFS=';'; echo "${missing[*]}")"
    exit 1
fi
echo "LAP tauth_header_dep PASS label=$LABEL: every shared object and dlm_ledger_test carries both marks ($(( $(date +%s) - T0 )) s)"
exit 0
