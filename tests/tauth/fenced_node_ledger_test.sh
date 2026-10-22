#!/bin/bash
# tests/tauth/fenced_node_ledger_test.sh — build and run fenced_node_ledger_test.c (a node whose
# authority over the LUN has closed must write no ledger page; see the test's header).
#
# The shared objects are the ones the Makefile builds for the mesh tests (making
# local_page_full_test brings obj/dlm.o and the rest up to date with the tree); the test itself
# is compiled with the same flags.  The log goes to
# tests/evidence/fenced_node_ledger/run_<UTC>.log.
#
# Budget: four nodes in one process, each phase a few hundred ms: two view changes waited on
# for up to 3 s each, three requests a master never answers with a grant, each three retries of
# the lock layer's 100 ms backoff, and the rest under a second; the run is under 10 s, bounded
# at 60 s.  A lap that overruns is a FAIL (rc 124), never re-run with a larger bound.
#
# Exit: the test's own (0 every check passed, 1 a check failed), 2 the build failed, 124 the
# bound expired.
set -u
cd "$(dirname "$0")" || exit 1
TOP=$(cd ../.. && pwd)
make local_page_full_test > /dev/null || { echo "RESULT ABORT: shared objects did not build"; exit 2; }
cc -I"$TOP" -I"$TOP/include" -I"$TOP/pal" -O2 -g -std=gnu11 -Wall -c \
   -o obj/fenced_node_ledger_test.o fenced_node_ledger_test.c || { echo "RESULT ABORT: compile"; exit 2; }
cc -O2 -g -std=gnu11 -Wall -Wextra -Werror -o fenced_node_ledger_test obj/fenced_node_ledger_test.o \
   obj/dlm.o obj/dlm_shared.o obj/tauth_ledger.o obj/tauth_store.o obj/pal_user.o -lpthread \
   || { echo "RESULT ABORT: link"; exit 2; }
mkdir -p ../evidence/fenced_node_ledger
log=../evidence/fenced_node_ledger/run_$(date -u +%Y%m%dT%H%M%SZ).log
timeout 60 ./fenced_node_ledger_test > "$log" 2>&1
rc=$?
grep -aE 'INFO|PASS|FAIL|RESULT' "$log"
echo "rc=$rc log=tests/evidence/fenced_node_ledger/$(basename "$log")"
exit $rc
