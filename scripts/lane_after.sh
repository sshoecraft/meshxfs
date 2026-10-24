#!/bin/bash
# lane_after.sh — a rig lane's first step: wait until another lane has ended a
# given step, so lanes start one after another's prep instead of together.
#
# Two lanes started seconds apart let one lane's pool-LUN allocation (SCST
# starts a command thread per CPU for the new device, and every node's iSCSI
# session logs in) run while the other's prep sampled the host kernel log: the
# host preflight measured ~88 lines/s against its 40 limit and refused the prep,
# as it must, and the lane spent its next three rows on refusals (g4 and g8,
# 2026-10-23).  A lane whose queue begins with this step starts its own power-up
# only after the other lane's prep has ended.
#
# The other lane is the newest tests/evidence/lanes/<name>_* directory.  The
# wait ends when its summary.log has the line for that step's end, or when the
# lane is DONE (a lane that ended without reaching the step waits for nothing).
#
# Bounded by <bound s>, which the caller derives from the steps waited for
# (a group's power-up plus its prep, as measured in their own summary lines);
# past it the step fails, and the lane goes on to its next step anyway, as every
# lane does after a failed step, so the overrun is visible in this step's rc.
#
# Usage: scripts/lane_after.sh <lane name> <step number> <bound s>
set -u
name=${1:?usage: lane_after.sh <lane name> <step number> <bound s>}
step=${2:?step number}
bound=${3:?bound in seconds}
root=$(cd "$(dirname "$0")/.." && pwd)
start=$(date +%s)
while :; do
    dir=$(ls -dt "$root/tests/evidence/lanes/${name}_"* 2>/dev/null | head -1)  # harness-lint: ok - picks the lane to wait for, not a verdict; the newest run of that name is the one meant (header)
    if [ -n "$dir" ]; then
        if grep -q " step $step end rc=" "$dir/summary.log" 2>/dev/null; then
            echo "lane_after: $(basename "$dir") ended step $step after $(( $(date +%s) - start ))s"
            exit 0
        fi
        if [ -e "$dir/DONE" ]; then
            echo "lane_after: $(basename "$dir") is DONE without a step $step end line"
            exit 0
        fi
    fi
    if [ $(( $(date +%s) - start )) -ge "$bound" ]; then
        echo "lane_after: FAIL ${dir:-no lane named $name} has not ended step $step within ${bound}s"
        exit 1
    fi
    sleep 5
done
