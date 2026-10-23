#!/bin/bash
# tests/tauth/adopted_grant_handoff_test.sh — build and run adopted_grant_handoff_test.c (a grant
# adopted between two attempts of a wait, whose page is then handed to the waiting node, must
# leave that node's lock master recording its hold after the local answer; see the test's header).
#
# The shared objects (dlm.o and the rest) are compiled from clean into a scratch directory on every
# run, with the Makefile's flags (tests/tauth/shared_objs.sh): built with `make` they kept the code
# of a header the Makefile's rules do not list, after that header changed; the test itself is
# compiled with the same flags.  The test
# binary is linked into a scratch directory outside the tree and run from there: linked in place
# it rewrote tests/tauth/adopted_grant_handoff_test, a frozen file of the release candidate, so
# every lap made the candidate it ran on INVALID
# (D-TAUTH-LAPS-RELINK-FROZEN-TEST-BINARIES-AND-INVALIDATE-THE-CANDIDATE); objects (*.o) are not
# frozen.  The log goes to tests/evidence/adopted_grant_handoff/run_<UTC>.log.
#
# Budget: four nodes in one process.  Step 2 is one acquire attempt (MXFS_LOCK_ACQUIRE_WAIT_MS,
# 1 s) plus the 4 s gap the test sets; step 6 is B's two attempts against a held EX (about 2 s
# with the lock layer's backoff); the rest is view changes and settles under a second each.  The
# run is under 12 s, bounded at 60 s.  A lap that overruns is a FAIL (rc 124), never re-run with a
# larger bound.
#
# Exit: the test's own (0 every check passed, 1 a check failed), 2 the build failed, 124 the
# bound expired.
set -u
cd "$(dirname "$0")" || exit 1
TOP=$(cd ../.. && pwd)
BIN=$(mktemp -d /tmp/mxfs_tauth_agh.XXXXXX) || { echo "RESULT ABORT: no scratch directory"; exit 2; }
trap 'rm -rf -- "$BIN"' EXIT
. ./shared_objs.sh
objs=$(tauth_shared_objs "$TOP" "$BIN/obj") || { echo "RESULT ABORT: shared objects did not build"; exit 2; }
cc -I"$TOP" -I"$TOP/include" -I"$TOP/pal" -O2 -g -std=gnu11 -Wall -c \
   -o "$BIN/adopted_grant_handoff_test.o" adopted_grant_handoff_test.c || { echo "RESULT ABORT: compile"; exit 2; }
# shellcheck disable=SC2086
cc -O2 -g -std=gnu11 -Wall -Wextra -Werror -o "$BIN/adopted_grant_handoff_test" \
   "$BIN/adopted_grant_handoff_test.o" $objs -lpthread || { echo "RESULT ABORT: link"; exit 2; }
mkdir -p ../evidence/adopted_grant_handoff
log=../evidence/adopted_grant_handoff/run_$(date -u +%Y%m%dT%H%M%SZ).log
timeout 60 "$BIN/adopted_grant_handoff_test" > "$log" 2>&1
rc=$?
grep -aE 'INFO|PASS|FAIL|RESULT|EXPOSURE|P958-ACQ|P-TAUTH-DOUBLE-GRANT|P-TAUTH-PAGE-MINE' "$log" | cut -c1-260
echo "rc=$rc log=tests/evidence/adopted_grant_handoff/$(basename "$log")"
exit $rc
