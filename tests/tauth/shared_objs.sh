# tests/tauth/shared_objs.sh — sourced by the tauth lap scripts: the shared objects their tests link
# (dlm.o, dlm_shared.o, tauth_ledger.o, tauth_store.o, pal_user.o).
#
# `tauth_shared_objs <top> <outdir>` compiles them from <top>'s sources into <outdir>, from clean,
# with the flags tests/tauth/Makefile gives each, and prints their paths, one a line.  The
# Makefile's rules list some of the headers each source includes and not others (pal/pal.h, which
# all five include, is in none of them), so `make` after a change to an omitted header linked the
# objects built before the change, and a lap measured code that was not the tree under test
# (D-TAUTH-TEST-OBJECTS-OMIT-INCLUDED-HEADERS-SO-A-HEADER-CHANGE-LINKS-STALE-CODE).  Compiled from
# clean into the caller's scratch directory, every header a source includes is the tree's as it is
# now.  A clean compile of the five takes about 9 s.
#
# TAUTH_SHARED_FROM_CLEAN=0 builds them as before the fix, with `make` in <top>/tests/tauth, and
# prints the paths in its obj/: the same-build control of that record (tests/tauth_shared_objs_lap.sh).
tauth_shared_objs() {
    local top=$1 out=$2
    local cpp="-I$top -I$top/include" cflags="-O2 -g -std=gnu11 -Wall -Wextra -Werror"
    if [ "${TAUTH_SHARED_FROM_CLEAN:-1}" = 0 ]; then
        make -C "$top/tests/tauth" obj/dlm.o obj/dlm_shared.o obj/tauth_ledger.o obj/tauth_store.o \
             obj/pal_user.o > /dev/null || return 1
        printf '%s\n' "$top/tests/tauth/obj/dlm.o" "$top/tests/tauth/obj/dlm_shared.o" \
               "$top/tests/tauth/obj/tauth_ledger.o" "$top/tests/tauth/obj/tauth_store.o" \
               "$top/tests/tauth/obj/pal_user.o"
        return 0
    fi
    mkdir -p "$out" || return 1
    cc $cpp -I"$top/pal" -O2 -g -std=gnu11 -Wall -c -o "$out/dlm.o" "$top/dlm/dlm.c" || return 1
    cc $cpp -I"$top/pal" -O2 -g -std=gnu11 -Wall -c -o "$out/dlm_shared.o" "$top/dlm/dlm_shared.c" \
        || return 1
    cc $cpp $cflags -c -o "$out/tauth_ledger.o" "$top/dlm/tauth_ledger.c" || return 1
    cc $cpp $cflags -c -o "$out/tauth_store.o" "$top/dlm/tauth_store.c" || return 1
    cc $cpp -I"$top/pal" $cflags -c -o "$out/pal_user.o" "$top/pal/linux/user.c" || return 1
    printf '%s\n' "$out/dlm.o" "$out/dlm_shared.o" "$out/tauth_ledger.o" "$out/tauth_store.o" \
           "$out/pal_user.o"
}
