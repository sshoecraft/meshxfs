#!/bin/bash
# formation_unspent_ab.sh — the same-build A/B of dl_retry_view_unspent
# (dlm/dlm.c: a RETRY answer that follows a change of the view does not spend
# the acquire's retry budget) in formation_test, the 12-node join ramp where a
# node's first request after its join ran out its budget and returned -EAGAIN
# (D-FORMATION-RAMP-LOCK-REQUEST-EXHAUSTS-RETRIES-EAGAIN).
#
# One binary, one knob between the arms: formation_test's fourth argument sets
# the knob, so both arms run the same build.  Blocks of runs alternate between
# the arms (0 first, then 1), so a drift in the host's load during the series
# falls on both alike instead of on whichever arm ran later.  Every block runs
# under tests/tauth/repeat_test.sh with the contention the failures were
# measured under (PIN_CPUS=54,55 BUSY=4 unless set otherwise).
#
# Usage: tests/tauth/formation_unspent_ab.sh <outdir> <blocks> <runs-per-block> <budget>...
#   e.g. tests/tauth/formation_unspent_ab.sh tests/evidence/formation_unspent_ab 5 10 10 3
# Output: <outdir>/series.txt, one repeat_test.sh summary line per block, and
# each block's run outputs in <outdir>/b<budget>_k<knob>_blk<n>/.  The per-arm
# tally (failed runs, failed requests by rc with their 'lock request failed'
# fields, INFO view_unspent_n) is read from those outputs afterwards.
set -u
out=${1:?usage: formation_unspent_ab.sh <outdir> <blocks> <runs-per-block> <budget>...}
blocks=${2:?blocks}
per=${3:?runs per block}
shift 3
[ $# -gt 0 ] || { echo "formation_unspent_ab: name at least one budget"; exit 2; }
case "$blocks$per" in *[!0-9]*) echo "formation_unspent_ab: blocks and runs must be counts"; exit 2 ;; esac
here=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
mkdir -p "$out" || exit 2
out=$(cd "$out" && pwd) || exit 2
# The binary is built here, every object it links included (make -B): built by a plain make it could
# link objects older than a header they include, which the Makefile's rules do not all list
# (D-TAUTH-TEST-OBJECTS-OMIT-INCLUDED-HEADERS-SO-A-HEADER-CHANGE-LINKS-STALE-CODE).  The binary sits
# in the tree, a frozen file of a release candidate, so the build is refused while one is qualified.
python3 "$here/../../tools/release_candidate.py" frozen "$here/formation_test" > /dev/null 2>&1
[ $? = 1 ] || { echo "formation_unspent_ab: a release candidate freezes tests/tauth/formation_test (or that could not be read); run this A/B on an unfrozen tree"; exit 2; }
make -B -C "$here" formation_test > /dev/null || { echo "formation_unspent_ab: building tests/tauth/formation_test failed"; exit 2; }
export PIN_CPUS=${PIN_CPUS:-54,55} BUSY=${BUSY:-4}
# what follows the budget on each arm's command line: by default the
# view_unspent knob, 0 for arm k0 and 1 for arm k1; another knob's A/B names
# both arms in full, e.g. ARM_ARGS0='1 0' ARM_ARGS1='1 1000' for
# handoff_grace_ms with view_unspent at its default
a0=${ARM_ARGS0:-0}; a1=${ARM_ARGS1:-1}
echo "=== formation_unspent_ab blocks=$blocks per=$per budgets=$* arm_args=[$a0]/[$a1] PIN_CPUS=$PIN_CPUS BUSY=$BUSY $(date -u +%FT%TZ) ===" >> "$out/series.txt"
for budget in "$@"; do
    for b in $(seq 1 "$blocks"); do
        for k in 0 1; do
            d="$out/b${budget}_k${k}_blk$b"
            mkdir -p "$d" || exit 2
            if [ "$k" = 0 ]; then a=$a0; else a=$a1; fi
            ARGS="40 1500 $budget $a" OUT_DIR="$d" "$here/repeat_test.sh" formation_test "$per" "b${budget}_k${k}_blk$b" >> "$out/series.txt" 2>&1
        done
    done
done
echo "=== formation_unspent_ab DONE $(date -u +%FT%TZ) ===" >> "$out/series.txt"
