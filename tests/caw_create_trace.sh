#!/bin/bash
# caw_create_trace.sh -- where a create's time goes as a directory grows, for
# D-SINGLE-WRITER-CREATE-PACE-6-TO-18MS-ON-2CAW-SO-THE-LMU-LAP-OVERRAN-360S.
#
# tests/create_pace_lap.sh measured 10000 creates at 2/disk/caw/direct: the
# running mean rose from 5.8 ms at 1000 to 9.7 ms at 10000 (each later thousand
# slower), while 2/net/mesh/direct stayed near 2.3 ms.  Its kernel-log check read
# nothing: with every debug site printing, the creates rotated its mark out of
# the node's ring.  This diagnostic keeps A's whole kernel log on A itself
# (cat /dev/kmsg into /root, no network in the path) across the same loop, so the
# module's acquire sums (P138-ACQSUM type= n= sum_ms=, every 500 acquires of a
# lock type; P138-ACQ for each over 5 ms) show which lock type's acquires grow
# with the directory.  Then it runs the loop again in a fresh directory with the
# module's debug sites off, to show what the printing itself costs.
#
#   arm 1  debug sites as prepped (dyndbg=+p), A's kernel log kept
#   arm 2  debug sites off (dynamic_debug 'module mxfs -p'), a fresh directory
# Prints each arm's PACE lines, then per lock type the acquires and their mean ms
# in each 2000-create slice of arm 1.  A measurement, not a verdict.
#
# Bounds (derived): prep 37-58 s, bound 120; each arm's 10000 creates at the
# worst measured 18.2 ms a create take 182 s, bound 2 x 182 = 364; the log copy
# and the slice counts 60.  A caller bounds it at 120 + 2 x 364 + 60 + 60 = 968 s.
#
# Usage: tests/caw_create_trace.sh <label> <configuration>
#        (the group's env exported: MXFS_GROUP, MXFS_MARKER, MXFS_NODE_LIST)
set -u
LABEL=${1:?label}
CONFIG=${2:?configuration}
cd "$(dirname "$0")" || exit 2
while [ ! -f run.sh ] && [ "$(pwd)" != / ]; do cd ..; done
[ -f run.sh ] || { echo "ABORT: no tree root above $0"; exit 2; }
NODES=${MXFS_NODE_LIST:?MXFS_NODE_LIST}
A=${NODES%%,*}
MNT=/mnt/shared
NFILES=${NFILES:-10000}
. tests/lib/rig.sh
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_cawcreatetrace_$LABEL
mkdir -p "$OUT"
echo "TRACE caw_create start $(date -u +%FT%TZ) label=$LABEL at=$CONFIG A=$A nfiles=$NFILES out=$OUT"
prep=$(MXFS_FORCE_PREP=1 timeout 120 ./run.sh "$CONFIG" ${MXFS_GROUP:+--group "$MXFS_GROUP"} prep_cluster < /dev/null 2>&1)
rc=$?
[ "$rc" = 0 ] || { echo "ABORT: prep_cluster rc=$rc: $(echo "$prep" | tail -2 | tr '\n' ' ' | cut -c1-240)"; exit 2; }
LOOP='d=$1; n=$2; mkdir -p "$d" || exit 1; bad=0; max=0; tot=0; i=0
while [ $i -lt $n ]; do s=${EPOCHREALTIME/./}; : > "$d/f$i" || bad=$((bad+1)); e=${EPOCHREALTIME/./}; t=$((e-s)); tot=$((tot+t)); [ $t -gt $max ] && max=$t; i=$((i+1))
[ $((i % 1000)) = 0 ] && echo "PACE at=$i mean_us=$((tot/i)) worst_us=$max t=${EPOCHREALTIME}"; done
sync; echo "CREATED=$i failed=$bad total_us=$tot mean_us=$((tot/(i>0?i:1))) worst_us=$max"'
KL=/root/cawcreatetrace.$LABEL.kmsg
rs 20 "$A" "rm -f $KL $KL.pid; nohup setsid sh -c 'echo \$\$ > $KL.pid; exec cat /dev/kmsg > $KL' > /dev/null 2>&1 < /dev/null & echo started" > /dev/null
sleep 1
rs 20 "$A" "echo 'mxfs-cawcreatetrace arm1 start $LABEL' > /dev/kmsg" > /dev/null
timeout 374 tools/mxfs_sshpass.sh "$A" "timeout 364 bash -c '$LOOP' loop $MNT/.cct1.$LABEL $NFILES" < /dev/null 2>/dev/null | filt > "$OUT/arm1.txt"
rs 20 "$A" "echo 'mxfs-cawcreatetrace arm1 end $LABEL' > /dev/kmsg; echo 'module mxfs -p' > /sys/kernel/debug/dynamic_debug/control" > /dev/null
timeout 374 tools/mxfs_sshpass.sh "$A" "timeout 364 bash -c '$LOOP' loop $MNT/.cct2.$LABEL $NFILES" < /dev/null 2>/dev/null | filt > "$OUT/arm2.txt"
rs 30 "$A" "echo 'module mxfs +p' > /sys/kernel/debug/dynamic_debug/control; kill \$(cat $KL.pid); sleep 1; gzip -f $KL; echo done" > /dev/null
timeout 60 tools/mxfs_sshpass.sh "$A" "cat $KL.gz" < /dev/null > "$OUT/A_kmsg.gz" 2>/dev/null
echo "arm 1 (debug sites on):"; grep -a '^PACE\|^CREATED' "$OUT/arm1.txt" | sed 's/^/  /'
echo "arm 2 (debug sites off):"; grep -a '^PACE\|^CREATED' "$OUT/arm2.txt" | sed 's/^/  /'
echo "A's kernel log: $(zcat "$OUT/A_kmsg.gz" 2>/dev/null | wc -l) lines; P138-ACQSUM by type across arm 1 (n, sum_ms, mean ms per acquire in each step):"
zcat "$OUT/A_kmsg.gz" 2>/dev/null | sed -n '/mxfs-cawcreatetrace arm1 start/,/mxfs-cawcreatetrace arm1 end/p' \
    | grep -ao 'P138-ACQSUM type=[0-9]* n=[0-9]* sum_ms=[0-9]* gt5=[0-9]*' \
    | awk '{ split($2,a,"="); split($3,b,"="); split($4,c,"="); split($5,g,"="); t=a[2];
             if (t in pn) { dn=b[2]-pn[t]; dm=c[2]-pm[t]; printf "  type=%s n=%s sum_ms=%s gt5=%s  last %d: %.2f ms each\n", t, b[2], c[2], g[2], dn, (dn ? dm/dn : 0) }
             pn[t]=b[2]; pm[t]=c[2] }' | tee "$OUT/acqsum.txt" | awk 'NR % 4 == 1' | head -60
echo "P138-ACQ (>5 ms) lines in arm 1 by type: $(zcat "$OUT/A_kmsg.gz" 2>/dev/null | sed -n '/arm1 start/,/arm1 end/p' | grep -ao 'P138-ACQ type=[0-9]*' | sort | uniq -c | tr '\n' ' ')"
echo "TRACE caw_create end $(date -u +%FT%TZ) evidence=$OUT"
