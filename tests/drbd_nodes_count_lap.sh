#!/bin/bash
# drbd_nodes_count_lap.sh -- one lap of
# D-MXFS-NODES-COUNT-TO-RUN-SH-NAMES-TO-DRBD-RIG-LANE-ABORTS-EVERY-DRBD-LAP and of
# D-DRBD-WRITE-BOUND-ARM-IGNORES-MXFS-GROUP-AND-ADDRESSES-TEST3-TEST4.
#
# run.sh gives every row MXFS_NODES as a node count, and a lane queue exports it
# for the laps that read it (tests/path_abort_kmsg_lap.sh).  scripts/drbd_rig.sh
# read the same variable as the pair's node names, so in such a lane it took '2'
# as a node, formed group nodes-2 with one node and refused 'DRBD dual-primary is
# exactly two': every DRBD lap of lane g2_a16_20261024T010135Z aborted unexposed.
# The fix takes a bare number as a count and uses the group.
#
# The lap, from this tree:
#   MXFS_NODES=2 MXFS_GROUP=g2 scripts/drbd_rig.sh status
# the same node selection every subcommand runs first (scripts/drbd_rig.sh, before
# its case on the subcommand), then 'status' prints one '<node>: ...' line per node
# of the pair it selected, whether or not that node answers its ssh (step_status),
# so the selection is read on the host where it is made; the g2 pair need not be up.
#
#   EXPOSED  MXFS_NODES held a bare number, and MXFS_GROUP named g2, when
#            drbd_rig.sh and the arm selected their pairs; and, on a line of its
#            own, MXFS_NODES unset with MXFS_GROUP=g2 when the arm selected again
#   PASS     the status names both g2 nodes, test1 and test2, and nothing refused;
#            and tests/drbd_write_bound_arm.sh's own resolution of the same
#            environment selects the same g2 pair, test1 test2, with MXFS_NODES a
#            bare number and with it unset
#   FAIL     drbd_rig.sh refused the pair ('has N nodes'), or the status names
#            another pair than test1 and test2, or the arm selected another pair
#   ABORT    the status overran its bound or printed no node line
#
# Each fix has its own control, set in this lap's environment, which drbd_rig.sh
# and the arm inherit:
#   DRBD_RIG_NODES_COUNT=0  a bare number is taken as a node name, as before the
#                           first fix (drbd_rig.sh refuses a one-node pair)
#   DRBD_ARM_GROUP=0        the arm takes test3 test4 whatever the group, as before
#                           the second fix (the arm selects test3 test4)
#
# Bound, derived: 'status' is a pool listing on the host and one ssh round to each
# node with its own 20 s cap (step_status, 'both status ... 20'), so the status is
# bounded at 25 s, the ssh cap and the listing; the arm's resolution at 5 s (it
# stops before touching any node); 30 s in all.  Prechecks: 11 s with the g2 pair
# powered off (status alone), 1.4-1.9 s with both parts on 2026-10-24.
#
# Usage: tests/drbd_nodes_count_lap.sh <label>
#        DRBD_RIG_NODES_COUNT=0 tests/drbd_nodes_count_lap.sh <label>   (control, count)
#        DRBD_ARM_GROUP=0 tests/drbd_nodes_count_lap.sh <label>         (control, arm)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT="$REPO/tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_drbdnodes_$LABEL"
mkdir -p "$OUT" || exit 2
BOUND=25
echo "LAP drbd_nodes_count start $(date -u +%FT%TZ) DRBD_RIG_NODES_COUNT=${DRBD_RIG_NODES_COUNT:-unset} DRBD_ARM_GROUP=${DRBD_ARM_GROUP:-unset} out=$OUT" | tee "$OUT/lap.log"
abort() { echo "LAP drbd_nodes_count ABORT label=$LABEL: $*" | tee -a "$OUT/lap.log"; exit 2; }

export MXFS_NODES=2 MXFS_GROUP=g2
echo "EXPOSED: MXFS_NODES=$MXFS_NODES, a bare number, and MXFS_GROUP=$MXFS_GROUP when drbd_rig.sh and the arm select their pairs" | tee -a "$OUT/lap.log"
t0=$(date +%s)
timeout -k 5 "$BOUND" "$REPO/scripts/drbd_rig.sh" status < /dev/null > "$OUT/status.txt" 2>&1
rc=$?
echo "STEP status rc=$rc wall=$(( $(date +%s) - t0 )) s" | tee -a "$OUT/lap.log"
[ "$rc" = 124 ] && abort "drbd_rig.sh status overran its ${BOUND} s bound"

wrong=""
named=$(grep -oE '^test[0-9]+:' "$OUT/status.txt" | tr -d ':' | sort -u | tr '\n' ' ')
if grep -q 'DRBD dual-primary is exactly two' "$OUT/status.txt"; then
    wrong="drbd_rig.sh refused the pair: $(grep -m1 'exactly two' "$OUT/status.txt")"
elif [ -z "$named" ]; then
    abort "the status printed no '<node>:' line (rc=$rc)"
elif [ "$named" = "test1 test2 " ]; then
    echo "INFO drbd_rig.sh: the status names the g2 pair: $named" | tee -a "$OUT/lap.log"
else
    wrong="the status names '$named', not test1 test2"
fi
# The same node resolution in tests/drbd_write_bound_arm.sh, which read MXFS_NODES
# as names too and, with no pair named, took test3 test4 whatever MXFS_GROUP was;
# DRBD_ARM_PRINT_NODES=1 stops it right after the resolution, so no module or
# node is touched.  It must select the g2 pair, as drbd_rig.sh does.
arm=$(DRBD_ARM_PRINT_NODES=1 timeout 5 "$REPO/tests/drbd_write_bound_arm.sh" "$LABEL" /nonexistent < /dev/null 2>&1)
echo "STEP arm rc=$? $arm" | tee -a "$OUT/lap.log"
case "$arm" in
    "DRBD_ARM_NODES test1 test2") echo "INFO drbd_write_bound_arm.sh: the g2 pair: test1 test2" | tee -a "$OUT/lap.log" ;;
    DRBD_ARM_NODES*) wrong="${wrong:+$wrong; }drbd_write_bound_arm.sh selected '${arm#DRBD_ARM_NODES }', not test1 test2" ;;
    *) abort "drbd_write_bound_arm.sh printed no DRBD_ARM_NODES line: ${arm:0:200}" ;;
esac
# The arm's other trigger: with MXFS_NODES unset it took its default pair, test3 test4,
# whatever MXFS_GROUP was, as with a bare count.  Its resolution is run again with the
# variable unset, and must select the g2 pair too.
echo "EXPOSED: MXFS_NODES unset, and MXFS_GROUP=$MXFS_GROUP when the arm selects its pair" | tee -a "$OUT/lap.log"
arm=$(env -u MXFS_NODES DRBD_ARM_PRINT_NODES=1 timeout 5 "$REPO/tests/drbd_write_bound_arm.sh" "$LABEL" /nonexistent < /dev/null 2>&1)
echo "STEP arm_unset rc=$? $arm" | tee -a "$OUT/lap.log"
case "$arm" in
    "DRBD_ARM_NODES test1 test2") echo "INFO drbd_write_bound_arm.sh with MXFS_NODES unset: the g2 pair: test1 test2" | tee -a "$OUT/lap.log" ;;
    DRBD_ARM_NODES*) wrong="${wrong:+$wrong; }drbd_write_bound_arm.sh with MXFS_NODES unset selected '${arm#DRBD_ARM_NODES }', not test1 test2" ;;
    *) abort "drbd_write_bound_arm.sh with MXFS_NODES unset printed no DRBD_ARM_NODES line: ${arm:0:200}" ;;
esac
if [ -z "$wrong" ]; then
    echo "LAP drbd_nodes_count PASS label=$LABEL: a bare MXFS_NODES with MXFS_GROUP=g2 selected the g2 pair in drbd_rig.sh and in drbd_write_bound_arm.sh, and MXFS_NODES unset did in drbd_write_bound_arm.sh" | tee -a "$OUT/lap.log"
    exit 0
fi
echo "LAP drbd_nodes_count FAIL label=$LABEL: $wrong" | tee -a "$OUT/lap.log"
exit 1
