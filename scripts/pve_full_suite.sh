#!/bin/bash
#
# pve_full_suite.sh <run-label> — the full Proxmox VE 9 SAN suite on
# pve9-5/6/7, which a release needs on the exact build after its last source
# change:
#
#   1. the multipath fault rows (tests/mpath/path_*.sh), each under the
#      budget the earlier passes ran it with; path_answer_lost (a swap the
#      target applied whose answer the host never heard) at its own derived
#      190 s at 2 nodes, ~200 s at 3, twice that
#   2. live migration (tests/pve_live_migrate.sh, six laps)
#   3. storage operations (tests/pve_storage_ops.sh)
#   4. HA power-cut failover (tests/pve_ha_failover.sh)
#   5. the reused-inode reproducer (tests/pve_recycled_btree_inode.sh), both
#      directions
#   6. every host's kernel log since the start mark, for Call Trace, BUG,
#      WARNING, Oops and hung tasks — read with _TRANSPORT=kernel --since, not
#      journalctl -k, which implies -b and drops the boot before a power cut
#
# The hosts must already run the build under test, mounted
# (scripts/pve_tree_install.sh, scripts/pve_mxfs_san_disk.sh join), with
# template VM 9000 on the mxfssan storage.  Never runs
# pve_mxfs_san_disk.sh up, which reformats the LUN and loses the template.
#
# Each stage writes its own output file under the evidence directory and a
# one-line verdict to stdout; the final line is SUITE: PASS only when every
# stage passed and the kernel logs are clean.
set -u
LABEL=${1:?run label}
cd "$(dirname "$0")/.." || exit 2
H1=192.168.120.213 H2=192.168.120.214 H3=192.168.120.215
HOSTS="$H1 $H2 $H3"
# the multipath map, the device every host mounts (a rejoin mount in the HA
# test fails on a single path's by-path link)
export SAN_DEV=/dev/disk/by-id/dm-uuid-mpath-23335366365663866
OUT=tests/evidence/pve_full_suite/$(date -u +%Y%m%dT%H%M%SZ)-$LABEL
mkdir -p "$OUT"
# Everything this prints is also the run's summary, suite.txt, which
# tools/release_status.py reads: its VERSION line is the release the hosts
# run (their srcversion is their own kernel's build, not this tree's .ko).
exec > >(tee "$OUT/suite.txt") 2>&1
START=$(date -u '+%Y-%m-%d %H:%M:%S')
FAIL=0
echo "=== pve_full_suite label=$LABEL out=$OUT start=${START}Z"
for h in $HOSTS; do
    echo "$h $(timeout 20 tools/mxfs_sshpass.sh $h "echo PVE-FULL-SUITE-START-$LABEL > /dev/kmsg; cat /sys/module/mxfs/version /sys/module/mxfs/srcversion; uname -r; grep mxfssan /proc/mounts | cut -d' ' -f2,3" </dev/null 2>/dev/null | tr '\n' ' ')"
done | tee "$OUT/hosts.txt"
versions=$(awk '{print $2}' "$OUT/hosts.txt" | sort -u)
[ "$(wc -w <<<"$versions")" = 1 ] || { echo "the hosts run different MeshXFS versions: $versions"; exit 1; }
echo "VERSION $versions"

verdict() {	# name rc file
    local r
    # the pve_* tests print "[hh:mm:ss] RESULT: ...", the rows "RESULT: ..."
    r=$(grep -aE '^(\[[0-9:]+\] )?RESULT' "$3" | tail -1 | cut -c1-300)
    echo "$1 rc=$2 $r"
    case "$r" in
    *PASS*) [ "$2" = 0 ] || FAIL=1 ;;
    *) FAIL=1 ;;
    esac
}

export MXFS_NODES=3 MXFS_NODE_LIST=pve9-5,pve9-6,pve9-7 \
    MXFS_MNT=/mnt/mxfssan MXFS_DEV=/dev/mapper/23335366365663866 \
    MXFS_MOUNT_OPTS=transport=caw MXFS_CONFIG=3/disk/caw/mpath
for rb in path_fabric:420 path_flap:360 path_mount_degraded:420 \
          path_fence_degraded:560 path_fenced_return:540 path_all_lost:500 \
          path_peer_withdrawn:540 path_answer_lost:400; do
    r=${rb%%:*}; b=${rb##*:}; s=$(date +%s)
    MXFS_RUN_ID=$LABEL timeout "$b" tests/mpath/$r.sh > "$OUT/$r.out" 2>&1
    rc=$?
    verdict "$r wall=$(( $(date +%s) - s ))s budget=$b" $rc "$OUT/$r.out"
done
unset MXFS_NODES MXFS_NODE_LIST MXFS_MNT MXFS_DEV MXFS_MOUNT_OPTS MXFS_CONFIG

s=$(date +%s)
PVE_PAIR="$HOSTS" MNT=/mnt/mxfssan DRBD_RES="" SRC_VMID=9000 SHARED=mxfssan \
    LAPS=6 tests/pve_live_migrate.sh > "$OUT/live_migrate.out" 2>&1
verdict "live_migrate wall=$(( $(date +%s) - s ))s" $? "$OUT/live_migrate.out"

s=$(date +%s)
PVE_HOSTS="$HOSTS" tests/pve_storage_ops.sh > "$OUT/storage_ops.out" 2>&1
verdict "storage_ops wall=$(( $(date +%s) - s ))s" $? "$OUT/storage_ops.out"

s=$(date +%s)
PVE_HOSTS="$HOSTS" tests/pve_ha_failover.sh > "$OUT/ha_failover.out" 2>&1
verdict "ha_failover wall=$(( $(date +%s) - s ))s" $? "$OUT/ha_failover.out"
grep -aE 'survivor .*OK in|bystander|declared|P163-MEMBER-GONE' \
    "$OUT/ha_failover.out" | cut -c1-200

for pr in "$H2 $H1" "$H1 $H2"; do
    s=$(date +%s)
    f="$OUT/recycled_btree_${pr// /_}.out"
    PVE_PAIR="$pr" timeout 400 tests/pve_recycled_btree_inode.sh "$LABEL" \
        > "$f" 2>&1
    verdict "recycled_btree $pr wall=$(( $(date +%s) - s ))s" $? "$f"
done

bad=0
for h in $HOSTS; do
    timeout 60 tools/mxfs_sshpass.sh $h \
        "journalctl _TRANSPORT=kernel --since '$START' --no-pager -o short-iso" \
        </dev/null > "$OUT/kern_$h.txt" 2>/dev/null
    grep -q "PVE-FULL-SUITE-START-$LABEL" "$OUT/kern_$h.txt" \
        || { echo "kernlog $h: start mark missing"; FAIL=1; }
    n=$(grep -acE 'Call Trace|BUG:|WARNING:|Oops|blocked for more than|hung_task|general protection' \
        "$OUT/kern_$h.txt")
    echo "kernlog $h lines=$(wc -l < "$OUT/kern_$h.txt") bad=$n"
    bad=$((bad + n))
done
[ "$bad" = 0 ] || FAIL=1

if [ "$FAIL" = 0 ]; then
    echo "SUITE: PASS label=$LABEL evidence=$OUT"
else
    echo "SUITE: FAIL label=$LABEL evidence=$OUT"
fi
exit $FAIL
