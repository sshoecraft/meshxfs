#!/bin/bash
#
# fio_path_probe.sh — fio_perf laps on one rig group with every node's
# per-path block counters sampled (tests/mpath/path_io_sampler.sh), so a slow
# sequential-write run can be read path by path against a fast one
# (D-4NODE-MPATH-SEQ-WRITE-COLLAPSE).
#
# Usage: tests/mpath/fio_path_probe.sh <config> <group> <laps> <tag>
#   tests/mpath/fio_path_probe.sh 4/disk/caw/mpath g4 6 fpp1
# Preps the group once (MXFS_FORCE_PREP=1 ./run.sh <config> --group <group>
# prep_cluster), then each lap: start the sampler on every node, run
# ./run.sh <config> --group <group> fio_perf (run.sh holds the host lock and
# the row's own budget), stop the samplers, print the row's measured line.
# The same sampler runs on clyde over the disk under the pool LUNs' directory
# (partition and whole disk), so the device's own write latency can be read
# second by second against the guests' paths: the first low run showed every
# node's writes taking 60-970 ms each at 32 in flight.
# Evidence: tests/evidence/fio_path_probe_<tag>/lap<i>_<node>.txt,
# lap<i>_host.txt and lap<i>_row.log.  Launch detached (nohup setsid ... &).
set -u
cd "$(dirname "$0")/../.." || exit 2
. tests/lib/rig.sh
. tools/mxfs_lab.sh
CFG=${1:?config} G=${2:?group} LAPS=${3:?laps} TAG=${4:?tag}
OUT=tests/evidence/fio_path_probe_$TAG
mkdir -p "$OUT"
NODES=$(tools/mxfs_lab.sh group "$G") || exit 2
POOL_DIR=$(lab_need paths pool) || exit 2
POOL_PART=$(basename "$(findmnt -n -o SOURCE -T "$POOL_DIR")")
POOL_DISK=$(lsblk -n -o PKNAME "/dev/$POOL_PART" | head -1)
[ -n "$POOL_PART" ] && [ -n "$POOL_DISK" ] || { echo "no pool device under $POOL_DIR"; exit 2; }
echo "pool device: $POOL_PART on $POOL_DISK"
# the fio row's budget (120 s) plus the host lock and quiesce waits it may
# spend before starting (run.sh: up to 45 + 120 s), plus margin for its prep
SAMPLE_S=420
MXFS_FORCE_PREP=1 ./run.sh "$CFG" --group "$G" prep_cluster > "$OUT/prep.log" 2>&1
echo "prep_rc=$?"
for i in $(seq 1 "$LAPS"); do
    STOP=/run/mxfs_fpp.$TAG.$i.stop
    for n in $NODES; do
        rs 20 "$n" "rm -f $STOP; nohup setsid bash /src/mxfs/tests/mpath/path_io_sampler.sh $SAMPLE_S /src/mxfs/$OUT/lap${i}_$n.txt $STOP > /dev/null 2>&1 < /dev/null &" >/dev/null &
    done
    wait
    HSTOP=$OUT/.lap$i.host.stop
    tests/mpath/path_io_sampler.sh "$SAMPLE_S" "$OUT/lap${i}_host.txt" "$HSTOP" "^($POOL_PART|$POOL_DISK)\$" &
    hpid=$!
    ./run.sh "$CFG" --group "$G" fio_perf > "$OUT/lap${i}_row.log" 2>&1
    rc=$?
    touch "$HSTOP"
    for n in $NODES; do ( rs 15 "$n" "touch $STOP" >/dev/null 2>&1 ) & done
    wait
    wait "$hpid" 2>/dev/null
    echo "lap $i rc=$rc $(grep -a -E 'PASS|FAIL' "$OUT/lap${i}_row.log" | grep -a 'fio_perf ' | head -1 | cut -c1-300)"
done
echo "FIO_PATH_PROBE_DONE tag=$TAG"
