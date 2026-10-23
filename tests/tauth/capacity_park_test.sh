#!/bin/bash
# tests/tauth/capacity_park_test.sh — build and run capacity_park_test.c
# (the user-mode A/B for dl_capacity_park, see the test's header).
#
# The shared objects (dlm.o and the rest) are compiled from clean into a
# scratch directory on every run, with the Makefile's flags
# (tests/tauth/shared_objs.sh): built with `make` they kept the code of a
# header the Makefile's rules do not list, after that header changed.  The
# test itself is compiled with the same flags, and the binary is linked into
# the scratch directory and run from there, not into the tree, where it is a
# frozen file of a release candidate.  The log goes to
# tests/evidence/capacity_park/run_<UTC>.log.
#
# Budget: the run is about 10 s (five laps of a few hundred ms each, one of
# them waiting out the 2 s park lifetime and a 1 s re-send); 60 s bound.
set -u
cd "$(dirname "$0")" || exit 1
TOP=$(cd ../.. && pwd)
BIN=$(mktemp -d /tmp/mxfs_tauth_cpk.XXXXXX) || { echo "RESULT ABORT: no scratch directory"; exit 2; }
trap 'rm -rf -- "$BIN"' EXIT
. ./shared_objs.sh
objs=$(tauth_shared_objs "$TOP" "$BIN/obj") || { echo "RESULT ABORT: shared objects did not build"; exit 2; }
cc -I"$TOP" -I"$TOP/include" -I"$TOP/pal" -O2 -g -std=gnu11 -Wall -c \
   -o "$BIN/capacity_park_test.o" capacity_park_test.c || { echo "RESULT ABORT: compile"; exit 2; }
# shellcheck disable=SC2086
cc -O2 -g -std=gnu11 -Wall -Wextra -Werror -o "$BIN/capacity_park_test" "$BIN/capacity_park_test.o" \
   $objs -lpthread || { echo "RESULT ABORT: link"; exit 2; }
mkdir -p ../evidence/capacity_park
log=../evidence/capacity_park/run_$(date -u +%Y%m%dT%H%M%SZ).log
timeout 60 "$BIN/capacity_park_test" > "$log" 2>&1
rc=$?
grep -E 'INFO|FAIL|RESULT' "$log"
echo "rc=$rc log=tests/evidence/capacity_park/$(basename "$log")"
exit $rc
