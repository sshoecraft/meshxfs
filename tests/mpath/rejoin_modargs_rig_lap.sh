#!/bin/bash
# tests/mpath/rejoin_modargs_rig_lap.sh -- one rig lap of
# D-PATH-ROW-REJOIN-DROPS-THE-LANES-MODARGS-SO-A-LANE-RUNS-MIXED-WINDOWS: a
# killed victim brought back by the path rows' own pf_boot_rejoin
# (tests/mpath/lib.sh) loads mxfs with the arguments the prep loaded on every
# other node, read back from the loaded module on the victim and a survivor.
#
# On 8/ and 16/disk/caw/mpath (lanes with MXFS_EXTRA_MODARGS=dead_timeout_ms=
# 12000) path_fence_degraded's rejoined victim ran dead_timeout_ms=0 while its
# peers ran 12000 (kmsg_test14_fromnode.gz:665, kmsg_test32_fromnode.gz:652).
# This lap runs that sequence and nothing else of the row, on the cluster the
# rig formed:
#
#   1. pf_start_gate: every node on two usable paths, every key registered
#   2. each prep argument read from /sys/module/mxfs/parameters on a survivor
#   3. the victim (the last node) killed (virsh destroy); the survivors fence
#      it: its registrations leave the target
#   4. pf_boot_rejoin: the victim boots, logs in on its paths, loads the module
#      the prep left on it, mounts
#   5. the same arguments read on the victim and the survivor again
#
#   EXPOSED  the lane loads MXFS_EXTRA_MODARGS and a survivor reads each of
#            them back: a victim loaded without the prep's arguments would read
#            the module's defaults instead
#   PASS     the victim rejoined and reads every prep argument as the survivor
#            does
#   FAIL     the victim reads one of them differently (named)
#   ABORT    the lap could not get there (start gate, fence, boot, rejoin)
#
# The arguments compared are the ones prep_node.sh and pf_rejoin_modargs give:
# force_transport, target_cache_protected, log_repeat_limit,
# target_retire_contract, and every name in MXFS_EXTRA_MODARGS.
# PF_REJOIN_PREP_ARGS=0 in the lap's environment loads what the rejoin loaded
# before the fix (tests/mpath/lib.sh pf_rejoin_modargs): the same-build
# control.
#
# Bound, derived from path_fence_degraded's measured phases at a 12 s death
# window (lanes g2b_spd_window12, g8_spd_window12, 2026-10-23): start gate
# ~10 s, fence 20-24 s after the kill, boot ~40 s, rejoin ~15 s, reads ~2 s,
# kernel-log keep ~5 s: about 95 s, 190 s at 2x.
#
# Usage: MXFS_NODES=<n> MXFS_NODE_LIST=<csv> MXFS_DEV=<mpath dev> \
#        MXFS_CONFIG=<n>/disk/caw/mpath MXFS_EXTRA_MODARGS=dead_timeout_ms=12000 \
#        tests/mpath/rejoin_modargs_rig_lap.sh
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
ROW=rejoin_modargs_rig
. "$(dirname "$0")/lib.sh"

# read_params <node> <tag>: name=value for each compared argument, from the
# loaded module, into $OUT/params_<node>_<tag>.txt
read_params() {
    local p cmd=""
    for p in $PARAMS; do cmd="$cmd echo $p=\$(cat /sys/module/mxfs/parameters/$p 2>/dev/null || echo MISSING);"; done
    rs 15 "$1" "$cmd" 2>/dev/null | grep -a '^[a-z_]*=' > "$OUT/params_$1_$2.txt"
}

main() {
[ "$N" -ge 2 ] || { echo "LAP rejoin_modargs_rig ABORT: needs 2 nodes, got $N"; exit 2; }
[ -n "${MXFS_EXTRA_MODARGS:-}" ] || { echo "LAP rejoin_modargs_rig ABORT: MXFS_EXTRA_MODARGS is empty: a rejoin without the prep's arguments would read like one with them"; exit 2; }
echo "INFO PF_REJOIN_PREP_ARGS=${PF_REJOIN_PREP_ARGS:-(unset)} MXFS_CONFIG=${MXFS_CONFIG:-?} MXFS_EXTRA_MODARGS=$MXFS_EXTRA_MODARGS nodes=$NODES_CSV victim=$V survivor=$W"
PARAMS="force_transport target_cache_protected log_repeat_limit target_retire_contract"
for kv in $MXFS_EXTRA_MODARGS; do PARAMS="$PARAMS ${kv%%=*}"; done
PF_DEATH=1
OTHERS=$(for n in $NODES; do [ "$n" = "$V" ] || printf '%s ' "$n"; done)
pf_start_gate

# 2. the reference: what the prep loaded on a survivor
read_params "$W" before
echo "INFO $W before: $(tr '\n' ' ' < "$OUT/params_${W}_before.txt")"
miss=0
for kv in $MXFS_EXTRA_MODARGS; do
    got=$(sed -n "s/^${kv%%=*}=//p" "$OUT/params_${W}_before.txt")
    [ "$got" = "${kv#*=}" ] || { miss=1; echo "INFO $W reads ${kv%%=*}=${got:-unread}, the lane loads ${kv#*=}"; }
done
[ "$miss" = 0 ] || { echo "LAP rejoin_modargs_rig ABORT: the survivor does not read the lane's MXFS_EXTRA_MODARGS back; the prep did not load them"; exit 2; }
echo "EXPOSED: $W reads the lane's $MXFS_EXTRA_MODARGS back; a victim loaded without the prep's arguments would read the module's defaults"

# 3. the victim dies and is fenced
timeout 60 $VIRSH destroy "$V" >/dev/null 2>&1
echo "  INFO $V killed at $(date -u +%T)"
LOAD_NODES=$OTHERS
tf=$(pf_wait_keys $(( 2 * (N - 1) )) 110 fenced)
[ "$tf" -lt 111 ] || { echo "LAP rejoin_modargs_rig ABORT: the survivors did not fence $V within 110 s"; exit 2; }
echo "  INFO $V fenced ${tf}s after the kill"

# 4. the rejoin, as path_fence_degraded does it
pf_boot_rejoin "$V" rejoin
[ "$fails" = 0 ] || { echo "LAP rejoin_modargs_rig ABORT: $V did not rejoin (evidence $OUT)"; exit 2; }
LOAD_NODES=$NODES

# 5. what the victim loaded, against the survivor
read_params "$V" after
read_params "$W" after
echo "INFO $V after: $(tr '\n' ' ' < "$OUT/params_${V}_after.txt")"
echo "INFO $W after: $(tr '\n' ' ' < "$OUT/params_${W}_after.txt")"
[ "$(grep -c . "$OUT/params_${V}_after.txt")" = "$(echo $PARAMS | wc -w)" ] \
    || { echo "LAP rejoin_modargs_rig ABORT: $V's parameters could not be read"; exit 2; }
diff=$(awk -F= 'FNR == NR { w[$1] = substr($0, length($1) + 2); next }
                { v = substr($0, length($1) + 2); if (!($1 in w) || w[$1] != v) printf "%s%s=%s (survivor %s)", (n++ ? ", " : ""), $1, v, ($1 in w ? w[$1] : "unread") }' \
            "$OUT/params_${W}_after.txt" "$OUT/params_${V}_after.txt")
if [ -n "$diff" ]; then
    echo "LAP rejoin_modargs_rig FAIL: the rejoined victim $V loaded other arguments than the survivor $W: $diff"
    exit 1
fi
echo "LAP rejoin_modargs_rig PASS: the rejoined victim $V reads every prep argument as $W does ($(echo $PARAMS | wc -w): $PARAMS)"
exit 0
}
main 2>&1 | tee "$OUT/row.log"
exit "${PIPESTATUS[0]}"
