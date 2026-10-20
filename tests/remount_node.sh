#!/bin/bash
# tests/remount_node.sh — mount the shared LUN again, without formatting it, on
# a node a lap left unmounted, so the cold audit that follows reads the volume
# that lap left behind.
#
# Why it exists: tests/lone_rsync_bench.sh (and so every arm of
# tests/resv_ahead_rsync_ab.sh) ends its copy with node A's own umount, which
# is part of what it measures, and leaves its peer mounted.  run.sh refuses any
# test on a cluster whose marker it cannot verify live ("marker stale: <A>
# live='<srcversion>' want='<srcversion> MOUNTED'"), and the next lap's prep
# formats the LUN, so a queue that put `run.sh ... chk_clean` straight after
# such an arm audited nothing (queue p6r, 2026-10-19: the audit lap refused in
# 10 s with no RESULT line).
#
# The device is resolved by identity as the bench resolves it (tests/lib/rig.sh
# mxfs_dev_resolve: the declared LUN by its WWID, the pool allocation bound to
# MXFS_NODE_LIST on a pool rig), and the mount is the bench's own (mount -t mxfs
# <LUN> /mnt/shared) on the module the node already has loaded, so the knobs
# the lap wrote stay as they were.  A node that is already mounted is left as
# it is and reported.
#
# The node is unmounted, so the resolver has no live mount to read the device
# from, and a pool LUN whose WWID is an EUI-64 (eui.<hex>) has no wwn-0x<hex>
# link to find it by (udev names it scsi-2<hex>); MXFS_CONFIG's device is the
# fixed rig's LUN path, which a pool node does not have.  So the caller names
# the node's path with MXFS_DEV, and the resolver checks that path against the
# pool allocation's WWID before anything mounts it (queue p6a2's remounts
# ABORTed at stage=device without it, 2026-10-19).
#
# usage: MXFS_DEV=<path> MXFS_NODE_LIST=<a>,<b> tests/remount_node.sh <label> <node>
# derived bound: the VM hold 15 s + device resolution (identity query 25 s,
# mount listing 20 s) + the mount 15 s (the bench's) + the check 10 s = 85 s.
# Prints the DEVICE line, then
#   RESULT: PASS|FAIL|ABORT label=<l> node=<n> mrc=<rc> mounted=<0|1> mount_ms=<ms> dev=<path>
set -u
LABEL=${1:?label}; NODE=${2:?node}
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO"
SSH=tools/mxfs_sshpass.sh
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_remount_node_$LABEL
mkdir -p "$OUT"
. "$(dirname "$0")/lib/rig.sh"
. "$(dirname "$0")/lib/runlock.sh"
vmhold_take remount_node $(echo "$NODE ${MXFS_NODE_LIST:-}" | tr ',' ' ') || { echo "RESULT: ABORT label=$LABEL node=$NODE stage=vmhold"; exit 2; }
mxfs_dev_resolve "$NODE"; LUN=$MXFS_DEV_RESOLVED
MARK="REMOUNT-$LABEL-$$"
R=$(timeout 30 $SSH "$NODE" "echo $MARK > /dev/kmsg; if mountpoint -q /mnt/shared; then echo already=1 mrc=0 mount_ms=0; else t0=\$(date +%s%3N); timeout 15 mount -t mxfs $LUN /mnt/shared 2>&1 | tail -2; mrc=\${PIPESTATUS[0]}; echo already=0 mrc=\$mrc mount_ms=\$(( \$(date +%s%3N) - t0 )); fi; timeout 10 ls /mnt/shared > /dev/null 2>&1 && mountpoint -q /mnt/shared && echo mounted=1 || echo mounted=0" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you')
echo "$R" | sed 's/^/  | /' | tee "$OUT/remount.txt"
MRC=$(echo "$R" | grep -o 'mrc=[0-9]*' | tail -1 | cut -d= -f2)
MS=$(echo "$R" | grep -o 'mount_ms=[0-9]*' | tail -1 | cut -d= -f2)
MOUNTED=$(echo "$R" | grep -o 'mounted=[01]' | tail -1 | cut -d= -f2)
ALREADY=$(echo "$R" | grep -o 'already=[01]' | tail -1 | cut -d= -f2)
ST=PASS
[ "${MRC:-1}" = 0 ] && [ "${MOUNTED:-0}" = 1 ] || ST=FAIL
echo "RESULT: $ST label=$LABEL node=$NODE mrc=${MRC:-?} mounted=${MOUNTED:-?} already=${ALREADY:-?} mount_ms=${MS:-?} dev=$LUN evidence=$OUT"
[ "$ST" = PASS ]
