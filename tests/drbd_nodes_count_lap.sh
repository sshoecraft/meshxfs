#!/bin/bash
# drbd_nodes_count_lap.sh -- one lap of
# D-MXFS-NODES-COUNT-TO-RUN-SH-NAMES-TO-DRBD-RIG-LANE-ABORTS-EVERY-DRBD-LAP.
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
#   EXPOSED  MXFS_NODES held a bare number when drbd_rig.sh selected its pair
#   PASS     the status names both g2 nodes, test1 and test2, and nothing refused
#   FAIL     drbd_rig.sh refused the pair ('has N nodes'), or the status names
#            another pair than test1 and test2
#   ABORT    the status overran its bound or printed no node line
#
# The control is DRBD_RIG_NODES_COUNT=0 in this lap's environment, which
# drbd_rig.sh inherits: a bare number is taken as a node name, as before the fix.
#
# Bound, derived: 'status' is a pool listing on the host and one ssh round to each
# node with its own 20 s cap (step_status, 'both status ... 20'), so the lap is
# bounded at 25 s, the ssh cap and the listing; the precheck took 11 s with the g2
# pair powered off.  A batch bounds the lap at twice what its precheck measures.
#
# Usage: tests/drbd_nodes_count_lap.sh <label>
#        DRBD_RIG_NODES_COUNT=0 tests/drbd_nodes_count_lap.sh <label>   (control)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT="$REPO/tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_drbdnodes_$LABEL"
mkdir -p "$OUT" || exit 2
BOUND=25
echo "LAP drbd_nodes_count start $(date -u +%FT%TZ) DRBD_RIG_NODES_COUNT=${DRBD_RIG_NODES_COUNT:-unset} out=$OUT" | tee "$OUT/lap.log"
abort() { echo "LAP drbd_nodes_count ABORT label=$LABEL: $*" | tee -a "$OUT/lap.log"; exit 2; }

export MXFS_NODES=2 MXFS_GROUP=g2
echo "EXPOSED: MXFS_NODES=$MXFS_NODES, a bare number, when drbd_rig.sh selects its pair" | tee -a "$OUT/lap.log"
t0=$(date +%s)
timeout -k 5 "$BOUND" "$REPO/scripts/drbd_rig.sh" status < /dev/null > "$OUT/status.txt" 2>&1
rc=$?
echo "STEP status rc=$rc wall=$(( $(date +%s) - t0 )) s" | tee -a "$OUT/lap.log"
[ "$rc" = 124 ] && abort "drbd_rig.sh status overran its ${BOUND} s bound"

if grep -q 'DRBD dual-primary is exactly two' "$OUT/status.txt"; then
    echo "LAP drbd_nodes_count FAIL label=$LABEL: drbd_rig.sh refused the pair: $(grep -m1 'exactly two' "$OUT/status.txt")" | tee -a "$OUT/lap.log"
    exit 1
fi
named=$(grep -oE '^test[0-9]+:' "$OUT/status.txt" | tr -d ':' | sort -u | tr '\n' ' ')
[ -n "$named" ] || abort "the status printed no '<node>:' line (rc=$rc)"
if [ "$named" = "test1 test2 " ]; then
    echo "LAP drbd_nodes_count PASS label=$LABEL: the status names the g2 pair: $named" | tee -a "$OUT/lap.log"
    exit 0
fi
echo "LAP drbd_nodes_count FAIL label=$LABEL: the status names '$named', not test1 test2" | tee -a "$OUT/lap.log"
exit 1
