#!/bin/bash
# nq_wouldblock_ab.sh — same-build A/B of dl_capacity_nq_wouldblock on the
# create load that meets a full ledger page on the network lock manager.
#
# Each lap preps <cfg> on <group> afresh (MXFS_FORCE_PREP=1, the tree's
# mxfs.ko, the knob set at module load through MXFS_EXTRA_MODARGS and read
# back by tests/aw_fill_reserve_ab.sh), then has <node> create and delete
# <n> files in one directory (tests/aw_fill_reserve_ab.sh with board '-').
# Laps alternate CONTROL (dl_capacity_nq_wouldblock=0: a no-queue request
# refused for a full page waits out its retry budget, as on the 0.90.131
# release candidate B0D2E3F5A70C96237681DF2) and FIX (the default, 1).
#
# The rules, written before the first lap
# (D-TCP-4NODE-NOQUEUE-TRY-WAITS-9S-ON-FULL-LEDGER-PAGE-CREATES-STALL, H-CAP-NQ3):
#   CONTROL must log 'capacity=60' no-queue failures and miss the staging's
#     140 s bound, else it reproduced nothing (VACUOUS);
#   FIX must log no 'capacity=60', count dl_capacity_nq_wouldblock_n > 0 (the
#     full page was met, else VACUOUS), and finish inside 140 s with no
#     shutdown or hung task;
#   REFUTED if a FIX lap logs a no-queue capacity=60 failure, or misses the
#     bound with the page met.
#
# Usage: tests/nq_wouldblock_ab.sh <cfg> <group> <node> <n> <tag> <laps>
#   e.g. tests/nq_wouldblock_ab.sh 2/net/mesh/mpath g2b test16 16384 nqa 4
# Results go to a scratch board (tests/evidence/nq_wouldblock_ab/<tag>/
# criteria.json) so the prep's cell stays off the release board.
#
# Budget (derived): prep 72-137 s measured, bounded at 280 s; the staging is
# bounded at 140 s inside tests/aw_fill_reserve_ab.sh; ~7 min a lap.
set -u
cd "$(dirname "$0")/.." || exit 2
CFG=${1:?configuration}; GROUP=${2:?rig group}; NODE=${3:?node}; N=${4:?files}
TAG=${5:?tag}; LAPS=${6:?laps}
EV="tests/evidence/nq_wouldblock_ab/$TAG"
mkdir -p "$EV" || exit 2
BOARD="$EV/criteria.json"
[ -f "$BOARD" ] || cp data/criteria.json "$BOARD" || exit 2
i=1
while [ "$i" -le "$LAPS" ]; do
    if [ $((i % 2)) = 1 ]; then arm=C; knob=0; else arm=F; knob=1; fi
    lap="${TAG}${arm}$(( (i + 1) / 2 ))"
    echo "[$(date -u +%T)] lap $i/$LAPS $lap dl_capacity_nq_wouldblock=$knob: prep" | tee -a "$EV/ab.log"
    MXFS_EXTRA_MODARGS="dl_capacity_nq_wouldblock=$knob" MXFS_CRIT="$BOARD" MXFS_FORCE_PREP=1 \
        timeout 280 ./run.sh "$CFG" --group "$GROUP" prep_cluster > "$EV/prep_$lap.log" 2>&1 < /dev/null
    prc=$?
    if [ "$prc" != 0 ]; then
        echo "[$(date -u +%T)] lap $lap prep rc=$prc ($EV/prep_$lap.log); stopping" | tee -a "$EV/ab.log"
        exit 1
    fi
    export MXFS_EXTRA_MODARGS="dl_capacity_nq_wouldblock=$knob"
    tests/aw_fill_reserve_ab.sh "$CFG" "$GROUP" "$NODE" "$N" "$lap" - 2>&1 | sed "s/^/  /" | tee -a "$EV/ab.log"
    unset MXFS_EXTRA_MODARGS
    i=$((i + 1))
done
echo "[$(date -u +%T)] DONE" | tee -a "$EV/ab.log"
