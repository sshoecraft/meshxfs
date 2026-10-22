#!/bin/bash
# xfs_baseline_refresh.sh — re-measure the native-XFS fio yardsticks that
# fio_perf_vs_xfs grades every MXFS board against, on one rig node and a pool
# LUN, one per release configuration.  Run it whenever the rig's VM shape
# (vCPUs, memory) or the LUN backing changes: the yardstick is only a ceiling
# for runs made on the same shape.
#
# Usage: tools/xfs_baseline_refresh.sh <evidence-tag> [node]   (node default test1)
#   EXPECT_CPUS (default 2)  the guest must report this many CPUs, or nothing runs
#   RUNS (default 5)         fio_perf runs per configuration; each field of the
#                            yardstick is the median of them
#   BLOCK_SIZE (default 512) the pool LUN's logical block size.  512 measures the
#                            direct configurations, 4096 the direct4k ones on a
#                            4K-native LUN (docs/4kn-support.md): native XFS on
#                            a 4096-byte device is a different yardstick
#   ATTACH (default lun)     drbd measures 2/net/mesh/drbd's yardstick instead:
#                            scripts/drbd_rig.sh up brings the pair of MXFS_GROUP
#                            (default g2; node must be its first node) up
#                            dual-primary on a pool LUN each, native XFS runs on
#                            /dev/drbd0 on node with its peer connected, so every
#                            write it is timed on has reached both nodes' disks,
#                            as every MXFS write on the pair does, and
#                            scripts/drbd_rig.sh down ends it.  The yardstick is
#                            named by the rig tag tools/mxfs_rig_tag.sh resolves
#                            for /dev/drbd0 (the backing array's, with -drbd)
#
# One run is not a yardstick.  The 2-vCPU capture of 0.90.39 ran native XFS
# twice on the same node, LUN and workload, once per configuration, and read
# seqW 1673 and 968 MiB/s: the device's cache-absorption regime decides a single
# sequential-write sample.  Graded against the 1673, 4/net/mesh/direct's 1150
# MiB/s failed at 68%.  The runs of every capture are kept in the evidence
# directory next to the log.
#
# The previous yardsticks are kept as .xfs_fio_baseline.<cfg>.scst-fio.json.backup.
# Each run is itself the best of fio_perf's FIO_PASSES passes (see
# tests/suite/fio_perf.sh), so the yardstick is the median of RUNS bests.
# Budget: node boot ~60 s, prep ~1 s, each fio_perf ~30 s (manifest 120 s).
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO" || exit 1
TAG="${1:?usage: xfs_baseline_refresh.sh <evidence-tag> [node]}"
NODE="${2:-test1}"
EXPECT_CPUS="${EXPECT_CPUS:-2}"
RUNS="${RUNS:-5}"
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "RUNS must be a positive integer (got '$RUNS')"; exit 2; }
BLOCK_SIZE="${BLOCK_SIZE:-512}"
ATTACH="${ATTACH:-lun}"
case "$ATTACH:$BLOCK_SIZE" in
    lun:512)  CONFIGS="net-mesh-direct disk-caw-direct" ;;
    lun:4096) CONFIGS="net-mesh-direct4k disk-caw-direct4k" ;;
    drbd:512) CONFIGS="net-mesh-drbd" ;;
    *)    echo "ATTACH must be lun (BLOCK_SIZE 512 or 4096) or drbd (512) (got '$ATTACH', '$BLOCK_SIZE')"; exit 2 ;;
esac
# the pool's SCST LUNs; a DRBD pair's tag is resolved once its device is up
RIGTAG=scst-fio
E="tests/evidence/xfs_baseline_$TAG.log"
RD="tests/evidence/xfs_baseline_${TAG}_runs"
mkdir -p "$RD"
SSH=tools/mxfs_sshpass.sh

scripts/lab_power.sh up "$NODE" >>"$E" 2>&1 || { echo "ABORT: $NODE did not come up (see $E)"; exit 3; }
cpus=$(timeout 20 "$SSH" "$NODE" nproc 2>/dev/null | tr -d '\r' | tail -1)
[ "$cpus" = "$EXPECT_CPUS" ] || { echo "ABORT: $NODE reports nproc=$cpus, want $EXPECT_CPUS"; exit 3; }
echo "=== $NODE nproc=$cpus" >>"$E"

t0=$(date +%s)
if [ "$ATTACH" = drbd ]; then
    G="${MXFS_GROUP:-g2}"
    [ "$(tools/mxfs_lab.sh group "$G" | awk '{print $1}')" = "$NODE" ] \
        || { echo "ABORT: $NODE is not the first node of rig group $G"; exit 2; }
    MXFS_GROUP=$G scripts/drbd_rig.sh up >>"$E" 2>&1 || { echo "ABORT: scripts/drbd_rig.sh up failed (see $E)"; exit 3; }
    dev=/dev/drbd0
    RIGTAG=$(MXFS_RIG_TAG= MXFS_RIG_TAG_FRESH=1 MXFS_RIG_NODE=$NODE tools/mxfs_rig_tag.sh "$dev")
    if [ -z "$RIGTAG" ]; then
        MXFS_GROUP=$G scripts/drbd_rig.sh down >>"$E" 2>&1
        echo "ABORT: tools/mxfs_rig_tag.sh resolved no rig for $dev on $NODE"; exit 3
    fi
    echo "=== rig $RIGTAG ($dev on $NODE, group $G)" >>"$E"
fi
for s in $CONFIGS; do
    [ -e ".xfs_fio_baseline.$s.$RIGTAG.json" ] &&
        mv ".xfs_fio_baseline.$s.$RIGTAG.json" ".xfs_fio_baseline.$s.$RIGTAG.json.backup"
done
{
    if [ "$ATTACH" = lun ]; then
        line=$(tools/lun_pool.sh alloc --owner $$ --what "yardstick capture $TAG" --size 20G \
            --block-size "$BLOCK_SIZE" "$NODE")
        echo "$line"
        dev=$(sed -n 's/.* dev=\([^ ]*\).*/\1/p' <<<"$line")
    fi
    # 1/xfs with no MXFS_DEV formats run.sh's default device, the node's own
    # boot disk: never run without the LUN the pool bound.
    [ -n "$dev" ] || { echo "ABORT: the pool bound no LUN to $NODE"; exit 3; }
    # The node the LUN was bound to, not run.sh's default test1: a capture on
    # another node ran on whatever LUN that node held, or on no node at all.
    # 1/xfs is one node and no rig group: run.sh refuses it with MXFS_GROUP set,
    # which a caller driving a DRBD pair (MXFS_GROUP names the pair) exports
    MXFS_NODE_LIST=$NODE MXFS_DEV=$dev env -u MXFS_GROUP -u MXFS_MARKER ./run.sh 1/xfs prep_cluster; echo "=== rc=$? prep 1/xfs"
    for s in $CONFIGS; do
        for ((i = 1; i <= RUNS; i++)); do
            # The node writes its run to its own /tmp and the host fetches it:
            # tests/evidence is a link to /mxfs/evidence, a directory only the
            # host has, so a node writing through /src/mxfs/tests/evidence wrote
            # nothing (fio_perf's write of it is silent), and a capture of 10
            # runs that all passed kept 0 of them.
            nodefile=/tmp/xfs_baseline_${TAG}_$s.run$i.json
            MXFS_NODE_LIST=$NODE MXFS_DEV=$dev MXFS_TEST_ENV="XFS_BASELINE=$nodefile" \
                env -u MXFS_GROUP -u MXFS_MARKER ./run.sh 1/xfs fio_perf
            echo "=== rc=$? fio_perf 1/xfs -> $s run $i/$RUNS"
            # only the JSON line: a login banner must never reach the yardstick
            timeout 20 "$SSH" "$NODE" cat "$nodefile" 2>/dev/null | grep '^{' >"$RD/$s.run$i.json"
            [ -s "$RD/$s.run$i.json" ] || echo "=== run $i of $s: no $nodefile on $NODE"
        done
    done
    if [ "$ATTACH" = drbd ]; then
        MXFS_GROUP=$G scripts/drbd_rig.sh down; echo "=== rc=$? drbd_rig down"
    fi
} >>"$E" 2>&1
# The median of the runs goes into the yardstick the boards read.
for s in $CONFIGS; do
    for ((i = 1; i <= RUNS; i++)); do
        cat "$RD/$s.run$i.json" 2>/dev/null
        echo
    done | python3 -c '
import json, statistics, sys
runs = [json.loads(l) for l in sys.stdin if l.strip()]
want = int(sys.argv[1])
if len(runs) != want:
    sys.exit("%s: %d of %d runs wrote a baseline" % (sys.argv[2], len(runs), want))
out = {}
for k, f in (("seq_write_1m", "bw_mib"), ("seq_read_1m", "bw_mib"),
             ("rand_write_4k", "iops"), ("rand_read_4k", "iops")):
    out[k] = {f: int(statistics.median(r[k][f] for r in runs))}
    print("%s %s %s runs=%s median=%d" % (sys.argv[2], k, f,
          ",".join(str(r[k][f]) for r in runs), out[k][f]), file=sys.stderr)
out["size"] = runs[0].get("size", "")
out["runs"] = want
json.dump(out, open(sys.argv[3], "w"), separators=(",", ":"))
' "$RUNS" "$s" ".xfs_fio_baseline.$s.$RIGTAG.json" 2>&1 | tee -a "$E"
done
echo "wall=$(( $(date +%s) - t0 ))s nproc=$cpus"
grep -aE '^=== rc|^=== rig|POOL_LUN|  (PASS|FAIL|TIMEOUT)' "$E" | cut -c1-160
rc=0
for s in $CONFIGS; do
    new=$(cat ".xfs_fio_baseline.$s.$RIGTAG.json" 2>/dev/null || sudo -n cat ".xfs_fio_baseline.$s.$RIGTAG.json" 2>/dev/null)
    [ -n "$new" ] || rc=1
    echo "$s ($RIGTAG) new: ${new:-MISSING}"
    echo "$s ($RIGTAG) old: $(cat ".xfs_fio_baseline.$s.$RIGTAG.json.backup" 2>/dev/null || sudo -n cat ".xfs_fio_baseline.$s.$RIGTAG.json.backup" 2>/dev/null)"
done
exit $rc
