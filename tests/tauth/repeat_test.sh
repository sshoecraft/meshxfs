#!/bin/bash
# repeat_test.sh — run one tests/tauth binary N times in a row and count its
# failures, so an intermittent result has a rate instead of an anecdote.
#
# The binaries are timing-sensitive simulations (formation_test forms a
# 12-node cluster on a 40 ms ramp); one pass or one failure says little, and
# two binaries built from different sources can only be compared by rate.
# Runs are sequential: two at once would compete for the CPU and change the
# timing being measured.
#
# Usage: tests/tauth/repeat_test.sh <binary> [N] [label]
#        N defaults to 20; each run is bounded at RUN_S seconds (default 120)
#        ARGS, if set, is passed to every run (formation_test: "<ramp_ms> <run_ms> [budget]")
#        PIN_CPUS, if set, is a taskset CPU list every run is confined to
#        BUSY=K (default 0, needs PIN_CPUS) keeps K busy loops on those same
#        CPUs for the whole series, so the runs compete for them: formation_test's
#        budget failures came under CPU contention and not without it, so a rate
#        that means anything states the contention it was measured under
# Output: one line per failed run (its rc and the first lines naming fails=),
#         then "<label>: F of N failed in S s".  Each run's whole output is
#         kept in OUT_DIR (default: a fresh mktemp -d), named in the last line.
set -u
bin=${1:?usage: repeat_test.sh <binary> [N] [label]}
n=${2:-20}
label=${3:-$(basename "$bin")}
RUN_S=${RUN_S:-120}
ARGS=${ARGS:-}
PIN_CPUS=${PIN_CPUS:-}
BUSY=${BUSY:-0}
OUT_DIR=${OUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/repeat_test.XXXXXX")}
# made absolute before the cd below: a relative OUT_DIR then named a directory
# under tests/tauth that did not exist, every run's output write failed, and
# the series reported "40 of 40 failed in 0s" with no run started
mkdir -p "$OUT_DIR" && OUT_DIR=$(cd "$OUT_DIR" && pwd) || { echo "repeat_test: cannot use OUT_DIR=$OUT_DIR"; exit 2; }
cd "$(dirname -- "${BASH_SOURCE[0]}")" || exit 2
[ -x "$bin" ] || { echo "repeat_test: $bin is not an executable here"; exit 2; }
case $BUSY in ''|*[!0-9]*) echo "repeat_test: BUSY must be a count: [$BUSY]"; exit 2 ;; esac
if [ "$BUSY" -gt 0 ] && [ -z "$PIN_CPUS" ]; then
    echo "repeat_test: BUSY needs PIN_CPUS (busy loops anywhere else contend with nothing the runs use)"
    exit 2
fi
pin=()
if [ -n "$PIN_CPUS" ]; then
    taskset -c "$PIN_CPUS" true || { echo "repeat_test: taskset refuses PIN_CPUS=$PIN_CPUS"; exit 2; }
    pin=(taskset -c "$PIN_CPUS")
fi
# The loops are this shell's own children, pinned by pid and stopped by pid.
busy_pids=()
stop_busy() { [ "${#busy_pids[@]}" -gt 0 ] && kill "${busy_pids[@]}" 2> /dev/null; busy_pids=(); }
trap stop_busy EXIT
spin() { while :; do :; done; }
for k in $(seq 1 "$BUSY"); do
    spin &
    busy_pids+=("$!")
    taskset -cp "$PIN_CPUS" "$!" > /dev/null || { echo "repeat_test: could not pin busy loop $k"; exit 2; }
done
t0=$(date +%s)
f=0
for i in $(seq 1 "$n"); do
    out="$OUT_DIR/run$i.out"
    # shellcheck disable=SC2086  # ARGS is a word list by design
    timeout "$RUN_S" "${pin[@]}" "./$(basename "$bin")" $ARGS > "$out" 2>&1
    rc=$?
    if [ "$rc" != 0 ]; then
        f=$((f + 1))
        echo "run $i rc=$rc $(grep -a 'fails=[1-9]' "$out" | head -n 2 | cut -c1-160 | tr '\n' ' ')"
    fi
done
stop_busy
echo "$label: $f of $n failed in $(( $(date +%s) - t0 ))s (ARGS='$ARGS' PIN_CPUS='$PIN_CPUS' BUSY=$BUSY; outputs in $OUT_DIR)"
