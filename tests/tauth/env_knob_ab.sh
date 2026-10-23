#!/bin/bash
# env_knob_ab.sh — a same-binary A/B of one tests/tauth binary whose knob is
# read from the environment: blocks of runs alternate the control value and
# the fix value, so both arms meet the same host conditions in turn (a rate
# measured in one arm after the other would compare two different hours of the
# host's load as much as the two values).
#
# Usage: tests/tauth/env_knob_ab.sh <outdir> <binary> <blocks> <runs-per-block> <VAR> <control> <fix>
#   e.g. tests/tauth/env_knob_ab.sh tests/evidence/case15_handoff_ab dlm_ledger_test 6 5 DL_HANDOFF_GRACE_MS 0 1000
# Each block runs tests/tauth/repeat_test.sh with VAR=<control> then with
# VAR=<fix>; RUN_S, ARGS, PIN_CPUS and BUSY pass through to it unchanged.
# Output: <outdir>/series.txt (repeat_test's summary line per block and arm),
# each run's whole output under <outdir>/k<0|1>_blk<n>/.
set -u
out=${1:?usage: env_knob_ab.sh <outdir> <binary> <blocks> <runs-per-block> <VAR> <control> <fix>}
bin=${2:?binary}; blocks=${3:?blocks}; per=${4:?runs per block}
var=${5:?VAR}; v0=${6?control value}; v1=${7?fix value}
case "$blocks$per" in *[!0-9]*) echo "env_knob_ab: blocks and runs must be counts"; exit 2 ;; esac
case "$var" in *[!A-Za-z0-9_]*|'') echo "env_knob_ab: VAR must be a variable name: [$var]"; exit 2 ;; esac
here=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
# The binary is built here, every object it links included (make -B): built by a plain make it could
# link objects older than a header they include, which the Makefile's rules do not all list
# (D-TAUTH-TEST-OBJECTS-OMIT-INCLUDED-HEADERS-SO-A-HEADER-CHANGE-LINKS-STALE-CODE).  The binary sits
# in the tree, a frozen file of a release candidate, so the build is refused while one is qualified.
python3 "$here/../../tools/release_candidate.py" frozen "$here/$bin" > /dev/null 2>&1
[ $? = 1 ] || { echo "env_knob_ab: a release candidate freezes tests/tauth/$bin (or that could not be read); run this A/B on an unfrozen tree"; exit 2; }
make -B -C "$here" "$bin" > /dev/null || { echo "env_knob_ab: building tests/tauth/$bin failed"; exit 2; }
mkdir -p "$out" || exit 2
out=$(cd "$out" && pwd) || exit 2
echo "=== env_knob_ab $bin blocks=$blocks per=$per $var=[$v0]/[$v1] RUN_S=${RUN_S:-} PIN_CPUS=${PIN_CPUS:-} BUSY=${BUSY:-} $(date -u +%FT%TZ) ===" >> "$out/series.txt"
for b in $(seq 1 "$blocks"); do
    for k in 0 1; do
        if [ "$k" = 0 ]; then v=$v0; else v=$v1; fi
        d="$out/k${k}_blk$b"
        mkdir -p "$d" || exit 2
        env "$var=$v" OUT_DIR="$d" "$here/repeat_test.sh" "$bin" "$per" "k${k}_blk$b" >> "$out/series.txt" 2>&1
    done
done
echo "=== env_knob_ab DONE $(date -u +%FT%TZ) ===" >> "$out/series.txt"
