#!/bin/bash
# marker_params_lap.sh -- one lap of
# D-RUN-SH-MARKER-NEVER-READS-LOADED-PARAMS-SO-ROWS-SKIP-PREP-ON-LEFTOVER-KNOBS,
# on a rig pair, where the defect lives.
#
# run.sh's filtered run reuses a formed cluster when its marker matches
# (marker_matches), and the live half of that match (marker_live_ok) read only
# each node's srcversion and whether the mount was up, never the module
# parameters the node runs; so after a row left a knob written on a node, every
# later filtered row skipped prep on a cluster other than the one prepped.  The
# fix records each node's writable parameters in the marker at prep and has
# marker_live_ok compare them live, so the row refuses instead.
#
# The lap, from this tree's run.sh at CONFIG on GROUP:
#   1. ./run.sh prep_cluster (a fresh marker from this tree);
#   2. a filtered row (precond_readiness) on the untouched pair: it must reuse
#      the cluster ('skipping prep'), or the fix refuses a cluster nothing
#      changed and the lap ABORTs -- this is what proves no parameter moves by
#      itself between prep and a row;
#   3. writes watch_ino on the second node, the knob tests/suite/crash_consistency.sh,
#      dir_reuse_coherency.sh and fence_during_write.sh arm and never restore,
#      and reads it back (EXPOSED when it differs from the prepped value);
#   4. the same filtered row again;
#   5. restores watch_ino.
#
#   PASS     step 4 refused the cluster, naming watch_ino on that node
#   FAIL     step 4 printed 'skipping prep' and ran on the leftover knob
#   ABORT    the prep failed, step 2 did not reuse the cluster, the knob did not
#            take, step 4 gave neither answer, or the lap overran its bound
#
# The control is MXFS_MARKER_PARAMS=0 in this lap's environment, passed to
# run.sh: marker_live_ok then matches on srcversion and mount alone, the
# pre-fix code, on the same source.
#
# Bound, derived from the precheck on g2 (2026-10-23, 2/net/mesh/direct): the
# whole lap took 82-89 s (prep_cluster 29-35 s, each filtered precond_readiness
# run 22 s from run.sh's start to its verdict), so 2x the lap, 178 s; each step
# also stops at 2x its own measure: prep 88 s (38-58 s measured on the same rig
# by tests/live_holder_shard_lap.sh, whose bound this is), each row 44 s, each
# knob write 10 s.  An overrun is an ABORT, never a reason to raise it.
#
# Usage: tests/marker_params_lap.sh <label> [config=2/net/mesh/direct] [group=g2]
#        MXFS_MARKER_PARAMS=0 tests/marker_params_lap.sh <label> ...   (control)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
LABEL=${1:?label}; CONFIG=${2:-2/net/mesh/direct}; GROUP=${3:-g2}
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
. "$HERE/tools/mxfs_lab.sh"
SSH="$HERE/tools/mxfs_sshpass.sh"
OUT=$HERE/tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_markerparams_$LABEL
mkdir -p "$OUT"
exec > >(tee -a "$OUT/lap.log") 2>&1
cd "$HERE" || exit 2
T0=$(date +%s); BOUND=178
left() { echo $(( BOUND - ($(date +%s) - T0) )); }
abort() { echo "LAP marker_params ABORT label=$LABEL: $*"; exit 2; }

echo "LAP marker_params start $(date -u +%FT%TZ) config=$CONFIG group=$GROUP tree=$HERE MXFS_MARKER_PARAMS=${MXFS_MARKER_PARAMS:-unset} out=$OUT"
NODE=$(lab_group "$GROUP" 2>/dev/null | awk '{print $2}')
[ -n "$NODE" ] || abort "group $GROUP has no second node in the lab file"
knob() {  # knob <value|''>: write watch_ino on NODE when a value is given; print what it reads
    timeout 10 "$SSH" "$(lab_addr "$NODE")" "${1:+echo $1 > /sys/module/mxfs/parameters/watch_ino; }cat /sys/module/mxfs/parameters/watch_ino" \
        </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$' | tail -1
}

MXFS_FORCE_PREP=1 timeout -k 5 88 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster </dev/null > "$OUT/prep.log" 2>&1
rc=$?
[ "$rc" = 124 ] && abort "prep_cluster overran its 88 s bound"
grep -aq '^=== prep_cluster OK ' "$OUT/prep.log" || abort "prep_cluster did not pass (rc=$rc, $OUT/prep.log)"

timeout -k 5 44 ./run.sh "$CONFIG" --group "$GROUP" precond_readiness </dev/null > "$OUT/row1.log" 2>&1
rc=$?
grep -aq 'skipping prep' "$OUT/row1.log" \
    || abort "the untouched pair was not reused (rc=$rc): $(grep -a 'marker stale\|ERROR' "$OUT/row1.log" | head -3 | tr '\n' ' ')"
echo "STEP untouched pair reused: $(grep -a 'skipping prep' "$OUT/row1.log")"

prepped=$(knob "")
[ -n "$prepped" ] || abort "watch_ino unreadable on $NODE"
want=$(( prepped + 4242 ))
got=$(knob "$want")
[ "$got" = "$want" ] || abort "watch_ino on $NODE read '$got' after writing $want"
echo "EXPOSED: watch_ino on $NODE is $got, prepped $prepped"

timeout -k 5 44 ./run.sh "$CONFIG" --group "$GROUP" precond_readiness </dev/null > "$OUT/row2.log" 2>&1
rc2=$?
restored=$(knob "$prepped")
echo "STEP watch_ino restored on $NODE: $restored"
[ "$rc2" = 124 ] && abort "the second filtered row overran its 44 s bound"
[ "$(left)" -lt 0 ] && abort "the lap overran its ${BOUND} s bound"
if grep -aq 'skipping prep' "$OUT/row2.log"; then
    echo "LAP marker_params FAIL label=$LABEL: the row reused the cluster with watch_ino=$want on $NODE ($(grep -a 'skipping prep' "$OUT/row2.log"))"
    exit 1
fi
if grep -aq "marker stale: $NODE runs module parameters" "$OUT/row2.log" && grep -aq "live: *watch_ino=$want" "$OUT/row2.log"; then
    echo "LAP marker_params PASS label=$LABEL: the row refused the cluster: $(grep -a 'marker stale\|live: *watch_ino' "$OUT/row2.log" | tr -s ' ' | tr '\n' ' ')"
    exit 0
fi
abort "the second row neither reused nor refused naming watch_ino (rc=$rc2): $(tail -3 "$OUT/row2.log" | tr '\n' ' ')"
