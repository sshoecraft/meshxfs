#!/bin/bash
# aw_fill_reserve_ab.sh — alloc_witness on a volume whose rank-2 node holds
# more free inodes in kept chunks than the witness's fill can use up.
#
# A clustered mount never releases a fully free inode chunk
# (xfs/libxfs/xfs_ialloc.c, INODE-CHUNK-KEEP), so after a suite's earlier rows
# delete their files a node's AG partition can hold thousands of free inodes.
# alloc_witness first fills the partition until a create carves a new chunk;
# with a fill bounded at 8192 creates, a partition holding more failed the row
# with "never carved a chunk" although every create succeeded (measured
# 2/net/mesh/mpath, release chain wave bL1 of 0.90.131, run
# 20261020T094530Z-g2d: AG 1 still held 7303 free inodes after the fill's 8192
# creates, about 15.5k before).
#
# This stages that state on purpose and runs the row on it:
#   1. on <node> (rank 2 of <group>), create <n> files and delete them, so its
#      affine AG keeps their chunks with every inode free;
#   2. ask the live chunk query (alloc_witness_chunk) about the middle and the
#      last staged inode (the first staged chunk can also hold the staging
#      directory or older files): each chunk must read freecount=64, else the staging
#      did not leave kept free chunks and the lap judges nothing (VACUOUS);
#   3. run `run.sh <cfg> --group <group> alloc_witness chk_clean`, its results
#      written to <board> (MXFS_CRIT; a scratch copy keeps a control off the
#      release board);
#   4. read the two ranks' witness records.
# A lap is REPRODUCED when rank 2 records the fill's "never carved" abort and
# PASSED when the row passed with coverage=PASS.
#
# Usage: tests/aw_fill_reserve_ab.sh <cfg> <group> <node> <n> <tag> <board>
#   e.g. tests/aw_fill_reserve_ab.sh 2/net/mesh/mpath g2d test32 16384 awr1 \
#            tests/evidence/aw_fill_reserve/criteria_awr1.json
# <board> '-' stops after the staging and reports its elapsed time and the
# node's capacity counters (P-TAUTH-PAGE-FULL, P-CAP-PARK, 'capacity=60', the
# dl_capacity_* counters): the staging alone is the create load that meets a
# full ledger page on net/mesh.
# Run on a prepped cluster; it neither preps nor formats.  Between laps on one
# volume, remove /mnt/shared/alloc_witness on any node to give the previous
# lap's fill inodes back to the reserve.
#
# Budget (derived): staging creates on 2/net/mesh at ~480/s (8192 in <= 17 s,
# run 20261020T094530Z-g2d) plus as many unlinks: 16384 files ~70 s, x2 =
# 140 s; the row pair is run.sh's own budgets (alloc_witness 120 s, chk_clean
# 180 s), enforced by run.sh.
set -u
cd "$(dirname "$0")/.." || exit 2
CFG=${1:?configuration}; GROUP=${2:?rig group}; NODE=${3:?rank-2 node}
N=${4:?files to stage}; TAG=${5:?lap tag}; BOARD=${6:?board file}
EV="tests/evidence/aw_fill_reserve/$TAG"
mkdir -p "$EV" || exit 2
SSH=tools/mxfs_sshpass.sh
log(){ echo "[$(date -u +%T)] $*" | tee -a "$EV/lap.log"; }

log "stage: $NODE creates and deletes $N files in /mnt/shared/aw_reserve_$TAG"
log "knobs on $NODE: $(timeout 20 "$SSH" "$NODE" 'for k in dl_capacity_nq_wouldblock dl_capacity_wait_local dl_capacity_park; do printf "%s=%s " $k "$(cat /sys/module/mxfs/parameters/$k 2>/dev/null)"; done; cat /sys/module/mxfs/srcversion' 2>/dev/null < /dev/null | tail -1)"
t0=$(date +%s)
timeout 140 "$SSH" "$NODE" "set -e; echo \$\$ > /tmp/aw_reserve_$TAG.pid; d=/mnt/shared/aw_reserve_$TAG; mkdir -p \$d; i=0; while [ \$i -lt $N ]; do : > \$d/f\$i; i=\$((i + 1)); done; sync -f /mnt/shared; echo mid_ino=\$(stat -c %i \$d/f$((N / 2))) last_ino=\$(stat -c %i \$d/f$((N - 1))); rm -rf \$d; sync -f /mnt/shared" \
    > "$EV/stage.txt" 2>&1 < /dev/null
src=$?
el=$(( $(date +%s) - t0 ))
grep -a 'mid_ino=' "$EV/stage.txt" | tee -a "$EV/lap.log"
counts=$(timeout 30 "$SSH" "$NODE" "printf 'files=%s page_full=%s cap_park=%s cap60=%s nq_wouldblock_n=%s wait_local_n=%s shutdown=%s hung=%s' \$(ls /mnt/shared/aw_reserve_$TAG 2>/dev/null | wc -l) \$(dmesg | grep -c P-TAUTH-PAGE-FULL) \$(dmesg | grep -c 'P-CAP-PARK ') \$(dmesg | grep -c 'capacity=60') \$(cat /sys/module/mxfs/parameters/dl_capacity_nq_wouldblock_n) \$(cat /sys/module/mxfs/parameters/dl_capacity_wait_local_n) \$(dmesg | grep -c 'Shutting down filesystem') \$(dmesg | grep -c 'blocked for more than')" 2>/dev/null < /dev/null | tail -1)
log "stage elapsed_s=$el rc=$src $counts"
if [ "$src" != 0 ]; then
    timeout 20 "$SSH" "$NODE" "kill \$(cat /tmp/aw_reserve_$TAG.pid) 2>/dev/null" < /dev/null > /dev/null 2>&1
    log "RESULT: ABORT staging rc=$src elapsed_s=$el ($EV/stage.txt)"
    exit 1
fi
if [ "$BOARD" = - ]; then
    log "RESULT: STAGED elapsed_s=$el"
    exit 0
fi
mid=$(grep -ao 'mid_ino=[0-9]*' "$EV/stage.txt" | cut -d= -f2)
last=$(grep -ao 'last_ino=[0-9]*' "$EV/stage.txt" | cut -d= -f2)
vac=0
for ino in $mid $last; do
    q=$(timeout 30 "$SSH" "$NODE" "f=\$(ls /sys/kernel/debug/mxfs/*/alloc_witness_chunk | head -1); echo $ino > \$f; cat \$f" 2>/dev/null < /dev/null | grep -a 'freecount=')
    log "chunk of $ino: $q"
    case "$q" in *" freecount=64"*|"freecount=64"*) ;; *) vac=1 ;; esac
done
[ "$vac" = 0 ] || { log "RESULT: VACUOUS the staged chunks do not all read fully free"; exit 1; }

log "row: run.sh $CFG --group $GROUP alloc_witness chk_clean (MXFS_CRIT=$BOARD)"
MXFS_CRIT="$BOARD" ./run.sh "$CFG" --group "$GROUP" alloc_witness chk_clean > "$EV/run.log" 2>&1 < /dev/null
rrc=$?
grep -aE '^\s+(PASS|FAIL|ABORTED|BLOCKED|SKIP)\s+(alloc_witness|chk_clean)' "$EV/run.log" | cut -c1-260 | tee -a "$EV/lap.log"
run=$(grep -aoE '20[0-9]{6}T[0-9]{6}Z-'"$GROUP" "$EV/run.log" | head -1)
for r in tests/evidence/alloc_witness/"$run"/rank*.txt; do
    [ -f "$r" ] || continue
    log "$(basename "$r"): $(grep -aE '^(FILL|ABORT)' "$r" | cut -c1-220 | tr '\n' ' ')"
done
if grep -aq 'never carved a chunk' tests/evidence/alloc_witness/"$run"/rank2.txt 2>/dev/null; then
    log "RESULT: REPRODUCED run=$run rc=$rrc"
elif grep -aE '^\s+PASS\s+alloc_witness' "$EV/run.log" | grep -q 'coverage=PASS'; then
    log "RESULT: PASSED run=$run rc=$rrc"
else
    log "RESULT: OTHER run=$run rc=$rrc (read $EV/run.log)"
fi
