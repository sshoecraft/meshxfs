#!/bin/bash
# dirshard_release_land_ab.sh — same-build A/B for
# D-DIRSHARD-REUSE-PEER-READDIR-EUCLEAN-ON-CAW-AT-4-NODES: the directory lock's
# release fence lands the parent's sharded-directory manifest block
# (dirshard_release_land=1) or does not (=0, the old fence).
#
# Usage: tests/dirshard_release_land_ab.sh <label> <knob 0|1> <rounds> [group=g4] [config=4/disk/caw/direct]
#   Preps the group with mkfs_mxfs -D (once), writes dirshard_release_land on
#   every node and reads it back, then runs tests/dirshard_reuse_peer_list.sh
#   (10 laps) on three rotating creator/peer pairs per round.  Each pair run's
#   verdict is one line; afterwards every node's kernel log is saved and its
#   P-DIRSHARD-BLK-OWNER / -CORRUPT / -REL-MBLK lines counted.
# Budgets: prep 300 s (measured 65-118 s), each pair run 150 s (the
# workload's own derived bound).
set -u
LABEL=${1:?label}; KNOB=${2:?knob 0|1}; ROUNDS=${3:?rounds}
GROUP=${4:-g4}; CONFIG=${5:-4/disk/caw/direct}
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO" || exit 2
SSH=tools/mxfs_sshpass.sh
NODES=$(tools/mxfs_lab.sh group "$GROUP") || exit 2
set -- $NODES
[ $# -ge 3 ] || { echo "group $GROUP has fewer than 3 nodes"; exit 2; }
A=$1; B=$2; C=$3; D=${4:-$2}
# pool VMs nobody holds are shut off by release helpers mid-round: hold the
# group for the whole A/B (a lap whose node went down measures nothing)
. tests/lib/runlock.sh
vmhold_take dirshard_release_land_ab $NODES || { echo "ABORT: could not hold $NODES"; exit 2; }
export MXFS_NODE_LIST=$(echo $NODES | tr ' ' ',') MXFS_MKFS_OPTS=-D
OUT=tests/evidence/dsland_$LABEL
mkdir -p "$OUT"
MXFS_FORCE_PREP=1 timeout 300 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1
echo "prep_rc=$?"
for n in $NODES; do
    got=$(timeout 15 $SSH "$n" "echo $KNOB > /sys/module/mxfs/parameters/dirshard_release_land && cat /sys/module/mxfs/parameters/dirshard_release_land" 2>/dev/null | tr -d '\r' | tail -1)
    echo "knob $n want=$KNOB got=$got"
    [ "$got" = "$KNOB" ] || { echo "ABORT: $n did not take dirshard_release_land=$KNOB"; exit 2; }
done
pass=0; fail=0
for ((r = 1; r <= ROUNDS; r++)); do
    for p in "$A $B" "$C $D" "$A $C"; do
        log="$OUT/r${r}_${p// /_}.log"
        timeout 150 tests/dirshard_reuse_peer_list.sh $p 10 > "$log" 2>&1
        rc=$?
        [ "$rc" = 0 ] && pass=$((pass + 1)) || fail=$((fail + 1))
        echo "round=$r pair=$p rc=$rc $(grep -a '^VERDICT' "$log" | cut -c1-120)"
    done
done
# Each pair run clears the kernel log at its start (dirshard_reuse_peer_list.sh)
# and prints every node's marker counts at its end, so the counts are summed
# from the pair logs; a dmesg read here would hold the last run only.
# A pair run with no marker line (a node unreachable, the run killed by its
# bound) measured nothing and is counted apart, never as a pass or a fail.
corrupt=0; void=0
for log in "$OUT"/r*_*.log; do
    if ! grep -aq ' markers: ' "$log"; then void=$((void + 1)); continue; fi
    for c in $(grep -a ' markers: ' "$log" | grep -o 'P-DIRSHARD-CORRUPT=[0-9]*' | cut -d= -f2); do
        corrupt=$((corrupt + c))
    done
done
echo "RESULT label=$LABEL knob=$KNOB pair_runs_pass=$pass pair_runs_fail=$fail void_runs=$void corrupt_markers=$corrupt"
