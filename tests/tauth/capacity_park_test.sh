#!/bin/bash
# tests/tauth/capacity_park_test.sh — build and run capacity_park_test.c
# (the user-mode A/B for dl_capacity_park, see the test's header).
#
# The shared objects are the ones the Makefile builds for the mesh tests
# (making local_page_full_test brings obj/dlm.o and the rest up to date with
# the tree); the test itself is compiled with the same flags.  The log goes
# to tests/evidence/capacity_park/run_<UTC>.log.
#
# Budget: the run is about 10 s (five laps of a few hundred ms each, one of
# them waiting out the 2 s park lifetime and a 1 s re-send); 60 s bound.
set -u
cd "$(dirname "$0")" || exit 1
TOP=$(cd ../.. && pwd)
make local_page_full_test > /dev/null || { echo "RESULT ABORT: shared objects did not build"; exit 2; }
cc -I"$TOP" -I"$TOP/include" -I"$TOP/pal" -O2 -g -std=gnu11 -Wall -c \
   -o obj/capacity_park_test.o capacity_park_test.c || { echo "RESULT ABORT: compile"; exit 2; }
cc -O2 -g -std=gnu11 -Wall -Wextra -Werror -o capacity_park_test obj/capacity_park_test.o \
   obj/dlm.o obj/dlm_shared.o obj/tauth_ledger.o obj/tauth_store.o obj/pal_user.o -lpthread \
   || { echo "RESULT ABORT: link"; exit 2; }
mkdir -p ../evidence/capacity_park
log=../evidence/capacity_park/run_$(date -u +%Y%m%dT%H%M%SZ).log
timeout 60 ./capacity_park_test > "$log" 2>&1
rc=$?
grep -E 'INFO|FAIL|RESULT' "$log"
echo "rc=$rc log=tests/evidence/capacity_park/$(basename "$log")"
exit $rc
