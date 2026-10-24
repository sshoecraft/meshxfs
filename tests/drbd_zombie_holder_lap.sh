#!/bin/bash
# drbd_zombie_holder_lap.sh -- one batch lap of
# D-BATCH-LAP-SUBREAPER-ZOMBIE-LUN-HOLDER-READ-LIVE-ABORTS-EVERY-THIRD-VOTE-LAP, on the DRBD rig
# (g2).
#
# scripts/drbd_rig.sh holds each node's pool LUN with a holder process of its own and kills it in
# its EXIT trap.  Run through tools/batch_lap.py, whose lap runner is a child subreaper that reaps
# orphans only when the lap ends, the killed holder stays a zombie, and tools/lun_pool.sh
# owner_live read the zombie's /proc start time as a live owner: the lap's next drbd_rig.sh step
# was refused its own node ("test1 is held by lun06's allocation").  The fix reads a zombie (or
# dying) owner as gone; LUN_POOL_ZOMBIE_DEAD=0 in the lap's environment reads it as live, as
# before the fix: the same-build control.
#
# A lap: scripts/drbd_rig.sh down, up (DRBD dual-primary on two fresh pool LUNs), then the
# owner's state in /proc for each node's allocation, then scripts/drbd_rig.sh mxfs (adopts the
# allocations up left), then down.
#   EXPOSED  up's holder for a node is a zombie when mxfs asks for that node: the trigger
#   PASS     mxfs adopted both nodes' LUNs and ran to the end (rc 0)
#   FAIL     mxfs was refused a node as held by another allocation (the defect)
#   ABORT    the pair could not be built, or mxfs failed for another reason
# Exposure needs the subreaper: run outside tools/batch_lap.py (or with
# MXFS_BATCH_LAP_KILLTREE=0) the holder goes to init and is reaped at once, and the lap is not
# exposed.
#
# Bound: up measured about 140 s on the third_vote laps that run the same down/up with
# DRBD_RIG_NO_BASELINE=1 (b20261023-242a48: 164-168 s a lap through up and a refused mxfs), mxfs
# ~25 s, down ~3 s (tests/evidence/lanes/g2_a16_followup_20261024T015355Z/summary.log steps 12
# and 15).  About 3.5 min a lap; each drbd_rig.sh step carries its own bounds, and a caller bounds
# the lap at twice what the precheck measures.
#
# Usage: tests/drbd_zombie_holder_lap.sh <label>   (MXFS_GROUP: the DRBD rig's group, default g2)
#        LUN_POOL_ZOMBIE_DEAD=0 tests/drbd_zombie_holder_lap.sh <label>   (control)
# Exit 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
cd "$(dirname "$0")/.." || exit 2
export MXFS_GROUP=${MXFS_GROUP:-g2}
export DRBD_RIG_NO_BASELINE=1
export LUN_POOL_ZOMBIE_DEAD=${LUN_POOL_ZOMBIE_DEAD:-1}
echo "LAP drbd_zombie_holder start $(date -u +%FT%TZ) label=$LABEL group=$MXFS_GROUP LUN_POOL_ZOMBIE_DEAD=$LUN_POOL_ZOMBIE_DEAD"
scripts/drbd_rig.sh down > /dev/null 2>&1
out=$(scripts/drbd_rig.sh up 2>&1)
rc=$?
[ "$rc" = 0 ] || { echo "LAP drbd_zombie_holder ABORT: drbd_rig.sh up rc=$rc: $(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-240)"; scripts/drbd_rig.sh down > /dev/null 2>&1; exit 2; }

# --- the trigger: each node's allocation is owned by up's holder; read its state in /proc
# (field 3 of /proc/<pid>/stat only, never cmdline)
zombies=""
for n in $(scripts/drbd_rig.sh status 2>/dev/null | sed -n 's/^ *nodes: *//p' | tr ',' ' '); do :; done
for n in test1 test2; do
    [ "$MXFS_GROUP" = g2 ] || break
    line=$(tools/lun_pool.sh lookup --nodes "$n" 2>/dev/null)
    pid=$(sed -n 's/.* owner=\([0-9]*\).*/\1/p' <<<"$line")
    st=""
    [ -n "$pid" ] && { s=$(cat "/proc/$pid/stat" 2>/dev/null); s=${s##*) }; st=${s%% *}; }
    echo "STEP $n: ${line:-no allocation} holder_state=${st:-gone}"
    [ "$st" = Z ] && zombies="$zombies $n($pid)"
done
[ -n "$zombies" ] && echo "EXPOSED: up's holder is a zombie when mxfs asks for its node:$zombies"

out=$(scripts/drbd_rig.sh mxfs 2>&1)
rc=$?
scripts/drbd_rig.sh down > /dev/null 2>&1
if [ "$rc" = 0 ]; then
    echo "LAP drbd_zombie_holder PASS label=$LABEL: drbd_rig.sh mxfs adopted both nodes' LUNs after up (zombie holders:${zombies:- none})"; exit 0
fi
held=$(echo "$out" | grep -a -m1 "is held by lun[0-9]*'s allocation" | cut -c1-240)
if [ -n "$held" ]; then
    echo "LAP drbd_zombie_holder FAIL label=$LABEL: drbd_rig.sh mxfs rc=$rc was refused its node: $held"; exit 1
fi
echo "LAP drbd_zombie_holder ABORT label=$LABEL: drbd_rig.sh mxfs rc=$rc for another reason: $(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-240)"
exit 2
