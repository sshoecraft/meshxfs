#!/bin/bash
# tests/lone_rsync_bench.sh — the budget rule lone-node metadata bench (sess434).
#
# One node mounts the shared LUN ALONE (dlm_caw single_node=true) and rsyncs
# /root/open-gpu-kernel-modules (659 MB, 8714 files on test1) into a fresh
# directory, then syncs.  Prints the rsync wall and the sync wall.  Used to
# measure the cost of D-0354 candidate A (0.41.0: a lone node mints real
# on-disk CAW grants) against 0.40.1 (memory-only lone grants).
#
# derived time budget: fleet umount sweep 20 s, mount 15 s, rsync (native XFS ~4 s
# for ~700 MB), sync, umount 20 s => caller bound 120 s.
#
# THE PASS LINE is twice native XFS, rsync plus sync, measured on the same LUN,
# node and tree: LRB_NATIVE=1 formats the LUN with mkfs.xfs, runs the identical
# copy and stores the wall in .lrb_native.<rig tag>.<node> (the cluster must
# be re-prepped afterwards).  The mxfs run reads it back and FAILs when the
# baseline is missing.  It used to assert only rsync <= 60 s, so a 10.9 s copy
# against a 4 s native reported PASS while missing the 2x line by a third.
#
# nodes is how many nodes the opening sweep unmounts, the first <nodes> of
# MXFS_NODE_LIST when it is set (A first, then its peer: test29,test30 on g2c)
# and of test1..testN when it is not: 2 on a 2-node group measures A alone; 1
# leaves the peer mounted (the both-mounted arm).  The sweep must never reach
# past the group it was given: another group's lap may be running on the rest.
# Each node of MXFS_NODE_LIST has its kernel log followed over the run.
#
# usage: [LRB_NATIVE=1] tests/lone_rsync_bench.sh <label> [A=test1] [nodes=32]
set -u
LABEL=${1:?label}; A=${2:-test1}; NN=${3:-32}
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO"
SSH=tools/mxfs_sshpass.sh
# the shared LUN as run.sh resolves it: MXFS_DEV overrides, /dev/sda is the
# 2-node TCP rig's default (the CAW multipath rig's is /dev/mapper/mpatha)
# the device under test by identity, not by path: the LUN this rig declares
# (data/rigs.json), verified by its WWID on the node, and the node's live mxfs
# mount when it has one; MXFS_DEV names a candidate that must be that LUN.
# mxfs_dev_resolve (tests/lib/rig.sh) ABORTs on anything else, never defaults
. "$(dirname "$0")/lib/rig.sh"
mxfs_dev_resolve "$A"; LUN=$MXFS_DEV_RESOLVED
# pool VMs nobody holds are shut off by release helpers: hold every node in use
. "$(dirname "$0")/lib/runlock.sh"
vmhold_take lone_rsync_bench $(echo "$A ${MXFS_NODE_LIST:-}" | tr ',' ' ') || { echo "RESULT: ABORT label=$LABEL stage=vmhold"; exit 2; }
SRC=/root/open-gpu-kernel-modules
# the copy must land every file of the tree it copies; the trees differ by node
# (8714 files on test1, 8137 on test29), so count it rather than assume one
WANT_FILES=$(timeout 30 $SSH "$A" "find $SRC -type f | wc -l" 2>/dev/null | grep -a '^[0-9][0-9]*$' | tail -1)
[ -n "$WANT_FILES" ] && [ "$WANT_FILES" -gt 0 ] || { echo "RESULT: ABORT label=$LABEL -- could not count the files of $SRC on $A"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_lone_rsync_bench_$LABEL
mkdir -p "$OUT"
MARK="LRB-$LABEL-$$"
echo "=== lone_rsync_bench label=$LABEL A=$A sv=$(modinfo mxfs.ko | awk '/srcversion/{print $2}') out=$OUT $(date -u +%FT%TZ) ==="
if [ -n "${MXFS_NODE_LIST:-}" ]; then
  SWEEP=$(echo "$MXFS_NODE_LIST" | tr ',' '\n' | head -n "$NN")
else
  SWEEP=$(seq -f 'test%g' 1 "$NN")
fi
for n in $SWEEP; do
  ( timeout 12 $SSH "$n" "umount /mnt/shared 2>/dev/null; mount -t mxfs | grep -c shared" > "$OUT/umount_$n.txt" 2>&1; echo "rc=$?" >> "$OUT/umount_$n.txt" ) &
done
wait
STILL=$(grep -l '^1' "$OUT"/umount_test*.txt 2>/dev/null | wc -l)
[ "$STILL" = "0" ] || { echo "RESULT: FAIL | lone_rsync_bench | precondition: $STILL node(s) still mounted"; exit 1; }
sleep 3
RIG=$(tools/mxfs_rig_tag.sh 2>/dev/null) || RIG=unknown
BASE=.lrb_native.$RIG.$A
if [ "${LRB_NATIVE:-0}" = 1 ]; then
  MOUNT="mkfs.xfs -f -q $LUN 2>&1 && mount -t xfs $LUN /mnt/shared 2>&1"
else
  MOUNT="mount -t mxfs $LUN /mnt/shared 2>&1"
fi
# Every node's kernel log over the run, followed (the ring holds about a second
# of the probes under load), so where the time went can be counted afterwards.
# --follow-new: plain --follow replays the whole ring first, and that history
# (earlier runs on the same boot) would be counted as this run's:
# kmsg_<node>.gz and census_<node>.txt, the probe tags by count.
KNODES=${MXFS_NODE_LIST:-$A}
KF=/run/lrb_kmsg.$LABEL
for n in ${KNODES//,/ }; do
  timeout 15 $SSH "$n" "rm -f $KF; nohup dmesg --follow-new < /dev/null > $KF 2>/dev/null & echo \$! > $KF.pid" >/dev/null 2>&1
done
R=$(timeout 100 $SSH "$A" "echo $MARK > /dev/kmsg; $MOUNT; mrc=\$?; echo mrc=\$mrc; [ \$mrc = 0 ] || exit 0; dmesg | sed -n '/$MARK/,\$p' | grep -ac 'single_node = true' | sed 's/^/single=/'; D=/mnt/shared/lrb_$LABEL; mkdir -p \$D; t0=\$(date +%s.%N); timeout 60 rsync -a --no-compress $SRC/ \$D/tree/ 2>&1 | tail -3; echo rsync_rc=\${PIPESTATUS[0]}; t1=\$(date +%s.%N); sync; t2=\$(date +%s.%N); echo rsync_wall=\$(echo \"\$t1 - \$t0\" | bc) sync_wall=\$(echo \"\$t2 - \$t1\" | bc); echo files=\$(find \$D/tree -type f | wc -l); dmesg | sed -n '/$MARK/,\$p' | grep -acE 'Internal error|Corruption|SHUTDOWN|P130|P131|P243|stuck for' | sed 's/^/bad=/'; t3=\$(date +%s.%N); timeout 60 umount /mnt/shared; echo urc=\$?; t4=\$(date +%s.%N); echo umount_wall=\$(echo \"\$t4 - \$t3\" | bc)" 2>/dev/null | grep -v '^Warning\|^Unauthorized\|^If you')
echo "$R" | sed 's/^/  | /' | tee "$OUT/A.txt"
for n in ${KNODES//,/ }; do
  timeout 60 $SSH "$n" "kill \$(cat $KF.pid) 2>/dev/null; gzip -c $KF > /src/$(basename "$REPO")/$OUT/kmsg_$n.gz; rm -f $KF $KF.pid" >/dev/null 2>&1
  zcat "$OUT/kmsg_$n.gz" 2>/dev/null | grep -ao 'mxfs: [A-Z][A-Z0-9_-]*' | sort | uniq -c | sort -rn | head -40 > "$OUT/census_$n.txt"
done
RW=$(echo "$R" | grep -o 'rsync_wall=[0-9.]*' | cut -d= -f2); SW=$(echo "$R" | grep -o ' sync_wall=[0-9.]*' | cut -d= -f2); UW=$(echo "$R" | grep -o 'umount_wall=[0-9.]*' | cut -d= -f2)
FILES=$(echo "$R" | grep -o 'files=[0-9]*' | cut -d= -f2); BAD=$(echo "$R" | grep -o 'bad=[0-9]*' | cut -d= -f2); MRC=$(echo "$R" | grep -o 'mrc=[0-9]*' | cut -d= -f2); RRC=$(echo "$R" | grep -o 'rsync_rc=[0-9]*' | cut -d= -f2); URC=$(echo "$R" | grep -o 'urc=[0-9]*' | cut -d= -f2)
SINGLE=$(echo "$R" | grep -o 'single=[0-9]*' | cut -d= -f2)
ST=PASS
[ "${MRC:-1}" = 0 ] && [ "${RRC:-1}" = 0 ] && [ "${URC:-1}" = 0 ] && [ "${FILES:-0}" = "$WANT_FILES" ] && [ "${BAD:-1}" = 0 ] || ST=FAIL
TOT=$(python3 -c "print(round(float('${RW:-999}') + float('${SW:-999}'), 3))")
if [ "${LRB_NATIVE:-0}" = 1 ]; then
  [ "$ST" = PASS ] && echo "$TOT" > "$BASE"
  echo "RESULT: $ST | lone_rsync_bench native | label=$LABEL rig=$RIG node=$A copy_wall=${TOT}s (rsync ${RW:-?}s + sync ${SW:-?}s) stored=$BASE files=${FILES:-?} mrc=${MRC:-?} rsync_rc=${RRC:-?} urc=${URC:-?} -- re-prep the cluster: the LUN now holds native XFS"
  [ "$ST" = PASS ]; exit
fi
NAT=$(cat "$BASE" 2>/dev/null)
if [ -z "$NAT" ]; then
  ST=FAIL; LINE="no native baseline $BASE (run once with LRB_NATIVE=1)"
else
  LINE=$(python3 -c "n=float('$NAT'); t=$TOT; print(f'copy_wall={t}s native={n}s ratio={t/n:.2f} line=2x={2*n:.3f}s')")
  python3 -c "import sys; sys.exit(0 if $TOT <= 2 * float('$NAT') else 1)" || ST=FAIL
fi
echo "RESULT: $ST | lone_rsync_bench | label=$LABEL rig=$RIG $LINE rsync_wall=${RW:-?}s sync_wall=${SW:-?}s umount_wall=${UW:-?}s files=${FILES:-?} bad=${BAD:-?} single=${SINGLE:-?} mrc=${MRC:-?} rsync_rc=${RRC:-?} urc=${URC:-?}"
[ "$ST" = PASS ]
