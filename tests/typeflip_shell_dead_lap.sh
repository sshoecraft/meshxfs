#!/bin/bash
# typeflip_shell_dead_lap.sh — does a lookup whose in-core shell is a dead
# incarnation read the parent again, or fail ESTALE?
#
# WHY THIS EXISTS.  D-CAW-MKDIR-LOOKUP-ESTALE-TYPEFLIP-UNRESOLVED: on
# path_mount_degraded at 2/disk/caw/mpath and 4/disk/caw/mpath the shared mutex
# directory LOCK's inode number went regular file and directory from four
# nodes; the type-flip resolver in xfs_lookup (xfs/xfs_inode.c) ended on a
# poisoned file shell while the coherent platter image was a live directory in
# a new generation.  Neither relookup term (the entry behind the inode, the
# platter contradicting the entry) held, so the lookup failed ESTALE and
# pathload's mkdir of LOCK with it.  The fix reads the parent again in that
# case too (typeflip_relookup_shell_dead, why=shell-dead).
#
# With retirement of the poisoned shell off (typeflip_poison_retire=0) the case
# arises in path_mount_degraded at 4/disk/caw/mpath on its own: 5, 11, 0 and 5
# shell-dead give-ups on one node in four runs (lane g4c_a17tf, 2026-10-24).
# pathload alone at 4/disk/caw/direct never reached it in four laps.  Both arms
# load typeflip_poison_retire=0; they differ only in
# typeflip_relookup_shell_dead (ARM=1 the fix, ARM=0 the same-build control).
#
# THE MEASURE is the module's own counters, not its probes or the workload:
# P201-RELOOKUP is ratelimited (eleven cases in 0.6 s on one node), and the VFS
# retries an ESTALE lookup once, so with the fix off five give-ups left every
# pathload operation ok.  typeflip_shell_dead_seen counts the give-ups in the
# shell-dead shape whatever the switch says, typeflip_shell_dead_relookups the
# ones that read the parent again, typeflip_estale every lookup the resolver
# failed.
#
# SHAPE: prep the cluster with both parameters (MXFS_EXTRA_MODARGS, the lane's
# own words kept), zero the three counters on every node, run the board row
# path_mount_degraded (run.sh enforces its budget), read the counters.
#   EXPOSED  some node's typeflip_shell_dead_seen >= 1
#   PASS     on every node every shell-dead give-up read the parent again
#            (relookups == seen), no shutdown, every node still mounted
#   FAIL     a shell-dead give-up that was not relooked on some node, or a
#            shutdown, or a node no longer mounted
# The row's own verdict and typeflip_estale are reported, not graded: the row
# grades many things this lap does not measure, and typeflip_estale also counts
# give-ups of other shapes.
#
# Bounds (derived): prep measured 41-95 s at 4 nodes on multipath (lane g4c),
# bound 120; the counters 20 s a node; the row's budget from data/criteria.json
# (path_mount_degraded budget_s 300, run.sh enforces it, measured 172-206 s); the reads
# 20 s a node.  At 4 nodes: 120 + 80 + 300 + 80 = 580 s; a caller bounds the lap
# at that.
#
# Usage: typeflip_shell_dead_lap.sh <label>
# Env:   MXFS_NODE_LIST (csv), MXFS_CONFIG (4/disk/caw/mpath), MXFS_GROUP,
#        ARM (1; 0 = the control), MXFS_EXTRA_MODARGS (kept, the two parameters added)
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}
cd "$(dirname "$0")" || exit 2
while { [ ! -f run.sh ] || [ ! -f tools/mxfs_lab.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done
[ -f run.sh ] || { echo "ABORT: no tree root above $0"; exit 2; }
export MXFS_NODE_LIST=${MXFS_NODE_LIST:?MXFS_NODE_LIST}
export MXFS_CONFIG=${MXFS_CONFIG:?MXFS_CONFIG}
IFS=, read -r -a NODES <<<"$MXFS_NODE_LIST"
ARM=${ARM:-1}
MNT=/mnt/shared
PARM=/sys/module/mxfs/parameters
CTRS="typeflip_shell_dead_seen typeflip_shell_dead_relookups typeflip_estale"
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_tfshell_$LABEL
mkdir -p "$OUT"
fails=0
. tests/lib/rig.sh
echo "=== typeflip_shell_dead_lap label=$LABEL config=$MXFS_CONFIG nodes=${NODES[*]} arm=$ARM $(date -u +%FT%TZ) ==="
s0=$(date +%s)
el() { echo $(( $(date +%s) - s0 )); }
field(){ grep -aoE "(^| )$2=[^ ]*" "$1" | head -1 | cut -d= -f2; }

export MXFS_EXTRA_MODARGS="${MXFS_EXTRA_MODARGS:+$MXFS_EXTRA_MODARGS }typeflip_poison_retire=0 typeflip_relookup_shell_dead=$ARM"
GROUPARG=()
[ -n "${MXFS_GROUP:-}" ] && GROUPARG=(--group "$MXFS_GROUP")
MXFS_FORCE_PREP=1 timeout 120 ./run.sh "$MXFS_CONFIG" "${GROUPARG[@]}" prep_cluster > "$OUT/prep.log" 2>&1
prc=$?
echo "STAGE prep rc=$prc wall=$(el)s modargs=[$MXFS_EXTRA_MODARGS]"
[ $prc = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=prep wall=$(el)s evidence=$OUT"; exit 2; }

# ---- 1. the premise on every node, the counters zeroed
for n in "${NODES[@]}"; do
    measure "$n" 20 "$OUT/${n}_premise.txt" '^PREMISE_END$' "$n's parameters and counters" \
        "echo RETIRE=\$(cat $PARM/typeflip_poison_retire) SHELLDEAD=\$(cat $PARM/typeflip_relookup_shell_dead); grep -c ' $MNT ' /proc/mounts | sed 's/^/MOUNTED=/'; z=0; for c in $CTRS; do echo 0 > $PARM/\$c && [ \"\$(cat $PARM/\$c)\" = 0 ] && z=\$((z+1)); done; echo ZEROED=\$z; echo PREMISE_END"
    ck "$n loaded typeflip_poison_retire=0" "$(field "$OUT/${n}_premise.txt" RETIRE)" 0
    ck "$n loaded typeflip_relookup_shell_dead=$ARM" "$(field "$OUT/${n}_premise.txt" SHELLDEAD)" "$ARM"
    ck "$n is mounted" "$(field "$OUT/${n}_premise.txt" MOUNTED)" 1
    ck "$n zeroed its three counters" "$(field "$OUT/${n}_premise.txt" ZEROED)" 3
done
[ $fails = 0 ] || { echo "RESULT: ABORT label=$LABEL stage=premise wall=$(el)s evidence=$OUT"; exit 2; }

# ---- 2. the row
./run.sh "$MXFS_CONFIG" "${GROUPARG[@]}" path_mount_degraded > "$OUT/row.log" 2>&1
rrc=$?
echo "STAGE row path_mount_degraded rc=$rrc at +$(el)s: $(grep -a 'RESULT:\|  PASS  path_mount_degraded\|  FAIL  path_mount_degraded' "$OUT/row.log" | tail -1 | cut -c1-160)"

# ---- 3. the counters and the state after it
seen_all=0
for n in "${NODES[@]}"; do
    measure "$n" 20 "$OUT/${n}_after.txt" '^AFTER_END$' "$n's counters" \
        "for c in $CTRS; do echo \$c=\$(cat $PARM/\$c); done; grep -c ' $MNT ' /proc/mounts | sed 's/^/MOUNTED=/'; dmesg | grep -ac 'Shutting down filesystem' | sed 's/^/SHUTDOWNS=/'; echo AFTER_END"
    seen=$(field "$OUT/${n}_after.txt" typeflip_shell_dead_seen)
    rel=$(field "$OUT/${n}_after.txt" typeflip_shell_dead_relookups)
    est=$(field "$OUT/${n}_after.txt" typeflip_estale)
    echo "  INFO $n: shell-dead give-ups ${seen:-?}, relooked ${rel:-?}, lookups failed ESTALE ${est:-?}"
    seen_all=$(( seen_all + ${seen:-0} ))
    ck "$n relooked every shell-dead give-up" "${rel:-}" "${seen:-x}"
    ck "$n is still mounted" "$(field "$OUT/${n}_after.txt" MOUNTED)" 1
    ck "$n shut nothing down since boot" "$(field "$OUT/${n}_after.txt" SHUTDOWNS)" 0
done

# ---- 4. the verdict
if [ "$seen_all" = 0 ]; then
    echo "  no node's resolver gave up in the shell-dead shape, so nothing here measures it"
    echo "RESULT: VACUOUS label=$LABEL fails=$fails wall=$(el)s evidence=$OUT"; exit 3
fi
echo "EXPOSED: the resolver gave up in the shell-dead shape $seen_all time(s)"
if [ $fails = 0 ]; then
    echo "LAP typeflip_shell_dead PASS: $seen_all shell-dead give-up(s), every one relooked; row rc=$rrc"
else
    echo "LAP typeflip_shell_dead FAIL: $fails check(s) failed ($seen_all shell-dead give-up(s); row rc=$rrc)"
fi
echo "RESULT: $( [ $fails = 0 ] && echo PASS || echo FAIL ) label=$LABEL fails=$fails wall=$(el)s evidence=$OUT"
[ $fails = 0 ]
