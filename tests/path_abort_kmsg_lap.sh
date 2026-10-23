#!/bin/bash
# path_abort_kmsg_lap.sh — one lap of
# D-PATH-ROW-ABORT-KEEPS-NO-KERNEL-LOG-SO-A-HUNG-REJOIN-LEAVES-NO-EVIDENCE.
#
# A path row (tests/mpath/lib.sh) follows every node's kernel log into /run on
# the node and copies it into the row's evidence when the row does not pass.
# A row that ABORTed -- a capture that did not complete in its bound, which
# capture_require (tests/lib/rig.sh) ends with exit 2 without counting a
# failure -- left $fails at 0, so the EXIT trap's kmsg_keep copied nothing:
# the rejoin remount that hung on 16/net/mesh/mpath path_all_lost left no
# node's kernel log, and the power-down that followed destroyed the only copy.
#
# The lap runs the path rows' own start (pf_start_gate: the starting-state
# gate, then a follower of every node's kernel log) and then one capture that
# cannot complete in its bound, a remote `sleep 8` measured with a 2 s bound,
# so the row ABORTs at stage=capture with every follower running, as the hung
# remount's did.
#
#   EXPOSED  the row printed 'RESULT: ABORT ... stage=capture'
#   PASS     every node's kernel log is in the row's evidence (kmsg_<node>_fromnode.gz)
#   FAIL     a node's is not
#
# PF_KEEP_ON_ABORT=0 in the environment keeps the logs only of a row with a
# counted failure, as before the fix: the control.
#
# Usage, on a formed multipath pair, with the environment run.sh hands a path
# row (MXFS_NODES, MXFS_NODE_LIST, MXFS_CONFIG, MXFS_DEV when not mpatha):
#   tests/path_abort_kmsg_lap.sh <label>
# Bound, derived: BOUND_S below.
# Exit: 0 PASS, 1 FAIL, 2 the lap could not measure.
set -u
cd /src/mxfs || { echo "UNMEASURED: no /src/mxfs"; exit 2; }
if [ "${1:-}" = --row ]; then
    ROW=path_abort_kmsg
    # shellcheck source=tests/mpath/lib.sh
    . tests/mpath/lib.sh
    pf_start_gate
    measure "$W" 2 "$OUT/abort_probe.txt" '^ABORT-PROBE done$' "a capture that cannot complete in its 2 s bound" \
        "sleep 8; echo ABORT-PROBE done"
    echo "UNMEASURED: the capture completed inside its bound"
    exit 3
fi
label=${1:?usage: tests/path_abort_kmsg_lap.sh <label>}
: "${MXFS_NODES:?}" "${MXFS_NODE_LIST:?}"
# The start gate reads each node's stray loads one node after another (rs 60
# each, ~1 s when the node answers), then every node's paths and the target's
# keys (~3 s), then starts the followers (~2 s); the capture's 2 s bound; the
# EXIT trap's copies run at once on every node (rs 90 each, ~2 s for a log of
# a few MB) and its follower stop (rs 15).  2 nodes: ~12 s measured, 4 x that.
BOUND_S=$(( 20 + 12 * MXFS_NODES ))
run_id="${label}_$(date -u +%Y%m%dT%H%M%SZ)"
out=tests/evidence/board_${run_id}_path_abort_kmsg
row_log=$(mktemp)
MXFS_RUN_ID=$run_id timeout "$BOUND_S" "$0" --row > "$row_log" 2>&1
rc=$?
sed 's/^/  row: /' "$row_log"
if ! grep -q '^RESULT: ABORT .*stage=capture' "$row_log"; then
    echo "UNMEASURED: the row did not ABORT at its capture (rc=$rc)"
    rm -f "$row_log"
    exit 2
fi
rm -f "$row_log"
echo "EXPOSED: the row ABORTed at stage=capture with every node's kernel log followed (evidence $out)"
missing=""
for n in ${MXFS_NODE_LIST//,/ }; do
    [ -s "$out/kmsg_${n}_fromnode.gz" ] || missing="$missing $n"
done
if [ -n "$missing" ]; then
    echo "FAIL: the ABORTed row kept no kernel log of:$missing"
    exit 1
fi
echo "PASS: the ABORTed row kept every node's kernel log ($(ls "$out" | grep -c '^kmsg_.*_fromnode\.gz$') in $out)"
exit 0
