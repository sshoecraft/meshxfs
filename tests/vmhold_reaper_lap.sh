#!/bin/bash
# vmhold_reaper_lap.sh -- does a batch lap keep its VMs up against the reaper
# run.sh leaves behind (D-BATCH-LAP-HOLDS-NO-VM-SO-RUN-SH-REAPER-POWERS-ITS-NODES-OFF-MID-LAP)?
#
# run.sh starts `tools/vm_pool.sh release --after <its pid> <its nodes>` (run.sh
# :378): once that run.sh exits, every one of those nodes that nobody holds for
# the whole grace (600 s) is shut off.  A lane forms its pair with
# `run.sh prep_cluster` and then runs a batch's laps through
# tools/harness_batch.py and tools/batch_lap.py, which held nothing, so 600 s
# after the prep both nodes were shut off under the lap that was running
# (test1/test2 at 01:06:06Z on 2026-10-23, lap 4 of control b20261022-e9be03;
# laps 5-10 found no module).
#
# This lap starts that same reaper on <node>, after a process that exits at
# once and with a grace of GRACE s (30), while the lap itself runs inside
# tools/batch_lap.py with MXFS_NODE_LIST=<node>.  With batch_lap.py holding the
# lap's VMs the reaper finds <node> held and leaves it running: PASS.  Without
# the hold (MXFS_BATCH_LAP_HOLD=0) it shuts <node> off: FAIL.  The node must be
# one nothing else uses; a lap that finds it off starts it first.
#
# Bound (RULE: TIMEOUTS ARE PERFORMANCE ASSERTIONS, NOT SAFETY NETS): starting
# the node when a lap before left it off, one node through
# scripts/lab_power.sh up, 30-45 s as the lanes measured it (lanes/*/summary.log
# 'lab_power.sh up'); the reaper's grace, 30 s; its shutdown of one node, ACPI,
# 2-10 s measured (lab_power destroys past 90 s); the state reads, 2 s: 87 s,
# and 2x that is the caller's bound, 174 s.  Without the fix a lap takes about
# 40 s, with it about 2 s, plus the start when the node was off.
#
# Usage: MXFS_NODE_LIST=<node> tests/vmhold_reaper_lap.sh <node>
# Exit 0 PASS, 1 FAIL, 2 ABORT.
set -u
NODE=${1:?node}
GRACE=${GRACE:-30}
cd "$(dirname "$0")/.." || exit 2
VIRSH="sudo virsh -c qemu:///system"
state() { timeout 20 $VIRSH domstate "$NODE" 2>/dev/null | head -1; }

echo "LAP vmhold_reaper start $(date -u +%FT%TZ) node=$NODE grace=${GRACE}s hold=${MXFS_BATCH_LAP_HOLD:-1} node_list=${MXFS_NODE_LIST:-}"
if [ "$(state)" != running ]; then
    timeout 100 tools/vm_pool.sh up "$NODE" > /dev/null 2>&1
    [ "$(state)" = running ] || { echo "LAP vmhold_reaper ABORT: $NODE could not be started"; exit 2; }
    echo "  INFO $NODE was off and was started"
fi
said=$(mktemp)
sleep 1 &
gone=$!
timeout $((GRACE + 100)) tools/vm_pool.sh release --after "$gone" --grace "$GRACE" "$NODE" < /dev/null > "$said" 2>&1 &
reaper=$!
echo "EXPOSED: the reaper of a run.sh that exited is watching $NODE (running), grace ${GRACE}s"
wait "$reaper"; rrc=$?
st=$(state)
echo "  INFO the reaper ended rc=$rrc: [$(tr '\n' ' ' < "$said" | cut -c1-240)]; $NODE is ${st:-of unknown state}"
rm -f "$said"
if [ "$st" = running ]; then
    echo "LAP vmhold_reaper PASS: $NODE stayed running through the reaper's ${GRACE}s grace"
    exit 0
fi
echo "LAP vmhold_reaper FAIL: the reaper shut $NODE off while the lap ran (state ${st:-unknown})"
exit 1
