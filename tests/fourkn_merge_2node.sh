#!/bin/bash
# fourkn_merge_2node.sh -- two nodes write inodes of the same 4096-byte blocks
# of a 4K-native volume at once: does every inode keep its own writer's last
# change, and did the merged inode-cluster write (pal/linux/xfs_buf.c,
# docs/4kn-support.md) do it?
#
# On a 4K-native volume eight 512-byte inodes share a block, and a node holds
# the authority for some of them while a peer holds the others.  A whole
# write of the block from either node's buffer would carry its stale copies of
# the other's slots; the merged write reads the block, copies in only the
# node's own slots and swaps the block with COMPARE AND WRITE, reading again
# on a MISCOMPARE.  This lap makes that happen: node 1 creates NF files, so
# consecutive inode numbers share blocks (8 to a block: ino >> 3); each node
# then changes the mode of its half of them every round and stats the other
# half, which makes the peer drain the inode it holds -- a merged write of a
# block the stat-ing node is also writing.  The files go a pair at a time, so
# both nodes drain the same block at once (tests/fourkn_merge_worker.sh).
#
# PASS needs, on the volume both nodes wrote:
#   - every file reads the mode its own writer set last, on both nodes, after
#     both unmounted and mounted again;
#   - chk_mxfs finds nothing, with both unmounted;
#   - no merged write failed or was refused (iwr_merge_failed 0 on both) and
#     no node logged a corruption, a shutdown, a BUG or an Oops;
#   - the merged write ran (iwr_merge_blocks > 0 on both);
#   - the forced overlap below landed: node 1's held write of the block began,
#     node 2's swap of it landed inside the hold, and node 1's swap after it
#     miscompared and was retried.
# A lap in which no swap miscompared (iwr_merge_miscompares 0 on both), or
# whose forced overlap did not land, did not exercise the retry, and exits
# VACUOUS rather than PASS.
#
# THE WINDOW.  Unwidened, the two nodes' writes of a block never overlapped:
# 0 MISCOMPAREs in ~480 merged writes a lap, on the TCP lock network and on
# COMPARE AND WRITE alike (tests/evidence/20261022T133714Z_fourkn_merge_2-net-mesh-direct,
# 20261022T134001Z_fourkn_merge_2-net-mesh-direct,
# 20261022T134249Z_fourkn_merge_2-disk-caw-direct).  Holding each node's first
# HOLD_N merged blocks HOLD_MS between the block's read and its swap
# (dbg_iwr_merge_hold_n, dbg_iwr_merge_hold_ms) catches the peer only when the
# peer happens to write the block inside the hold: of four laps held 64 x 20
# ms, one saw no MISCOMPARE and was VACUOUS
# (D-FOURKN-MERGE-2NODE-LAP-HOLD-CATCHES-THE-PEER-ONLY-BY-CHANCE).  So the
# overlap is made, once a lap, at the unmount, as tests/suite/fourkn_merge.sh
# makes it:
#   - each node stats the other's half, so the other writes back every inode it
#     changed;
#   - in a block holding a file of each half, node 2 changes its file (fb);
#   - node 1 is armed to hold its next merged write between the block's read
#     and its swap until the block on the device changes, FORCE_MS at most
#     (dbg_iwr_merge_hold_n 1, dbg_iwr_merge_hold_peer_ms), changes its file
#     (fa) and unmounts.  fa is the only inode node 1 has to write back, so
#     the merged write the unmount makes of fa's block is the one held;
#   - once the hold has begun (dbg_iwr_merge_hold_n back to 0), node 2 changes
#     fb again and unmounts, which writes fb's slot into that block with a swap
#     of its own: the block on the device changes under node 1's hold
#     (iwr_merge_hold_landed), node 1's swap miscompares, and its retry must
#     keep node 2's slot.
# fa must then read node 1's mode (605) and fb node 2's (606).  The workload
# runs unheld (HOLD_N 0); HOLD_N, HOLD_MS and HOLD_PEER_MS
# (dbg_iwr_merge_hold_peer_ms: wait until the peer's swap of the held block
# lands, at most that long) still hold its first blocks when set.  FORCE_MS=0
# leaves the overlap out and the unmounts are plain ones: with HOLD_N=64 it is
# the lap as it was before the forced overlap, its control.
#
# Bounds, from what each step should take: insmod 30 s, mkfs 300 s, mount and
# umount as tests/fourkn_mount_probe.sh (120 s, 60 s); the 64 creates 10 s of
# ssh connect plus well under a second.  The workload: per round a node makes
# 32 mode changes and 32 stats; a stat of an inode the peer holds costs the
# peer's drain, one merged write (a FUA read and a COMPARE AND WRITE, two
# round trips to the target, ~1 ms each on the rig) plus the lock's messages,
# so ~3 ms, and a mode change after the peer's stat a lock round trip, ~1 ms:
# ~130 ms a round, 2.6 s for 20 rounds, 2x that is 6 s, plus 10 s of ssh
# connect: 16 s.  Measured unwidened: 5.9-7.9 s of workload a node.  Each held
# block can keep a worker of either node waiting its HOLD_MS, so the bound
# adds 2 x HOLD_N x HOLD_MS, or 2 x HOLD_N x HOLD_PEER_MS for holds that wait
# for the peer.  The bound is enforced on the node as well as on the ssh
# client: the worker runs under `timeout --foreground` 3 s short of it, so it
# stops itself after the step in hand (WORKER_STOPPED) while the client still
# waits.  Bounding the client alone left an overrun worker running on the
# node, holding the mount, and every following lap aborted at its unmount
# before insmod (tests/evidence/lanes/g2d_a14_merge2node_20261023T204131Z,
# laps 30-45 and 47-48).  The forced overlap: the two settling passes 30 s each (32
# stats of a peer-held inode, ~4 ms each, and an ssh), the changes of fb and
# fa 15 s each, the poll for the hold 10 s, node 1's unmount 60 s, during which
# node 2's change and unmount 60 s, the counters 10 s.  chk_mxfs of a 20 GiB
# 4K-native volume over iSCSI 60 s.
#
# Usage: [MXFS_CONFIG=<configuration>] [ROUNDS=20] [NF=64] [FORCE_MS=5000] [HOLD_N=0] [HOLD_MS=20] [HOLD_PEER_MS=0] tests/fourkn_merge_2node.sh <dev> <node1> <node2>
# The module is loaded with the rig's parameters, as tests/setup/prep_node.sh
# loads it for MXFS_CONFIG's transport (2/net/mesh/direct, the TCP lock
# network, when unset; 2/disk/caw/direct for COMPARE AND WRITE): the transport
# and the target's durability-domain declaration (tests/lib/rig.sh
# mxfs_rig_modargs), log_repeat_limit=0 and dyndbg=+p, and MXFS_EXTRA_MODARGS.
# A bare insmod without them left target_cache_protected=0, and the first mount was refused
# (P-DOMAIN-REFUSED: fua_disable=1 with target_cache_protected=0), so each is
# read back from /sys/module/mxfs/parameters before anything is formatted.
# The module is copied to the node and loaded only when its md5 matches the
# tree's, as the prep does: the .ko is relinked in place on the NFS export.
# The host preflight (scripts/clyde_preflight.sh) gates the lap, as run.sh's
# does.  The LUN is reformatted.  The lap's own log is $OUT/lap.log.
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/tools/mxfs_lab.sh"
. "$HERE/tests/lib/rig.sh"
SSH="$HERE/tools/mxfs_sshpass.sh"
DEV=${1:?device}; N1=${2:?node1}; N2=${3:?node2}
MXFS_CONFIG=${MXFS_CONFIG:-2/net/mesh/direct}
RIGARGS=$(mxfs_rig_modargs) || { echo "ABORT the rig's module arguments for $MXFS_CONFIG cannot be derived (tests/lib/rig.sh mxfs_rig_modargs)"; exit 2; }
FT=$(sed -n 's/.*force_transport=\([01]\).*/\1/p' <<<"$RIGARGS")
[ -n "$FT" ] || { echo "ABORT no force_transport in the rig's module arguments [$RIGARGS]"; exit 2; }
MODARGS="$RIGARGS log_repeat_limit=0 dyndbg=+p ${MXFS_EXTRA_MODARGS:-}"
KOMD5=$(md5sum < "$HERE/mxfs.ko" | cut -d' ' -f1)
ROUNDS=${ROUNDS:-20}
NF=${NF:-64}
FORCE_MS=${FORCE_MS:-5000}
HOLD_N=${HOLD_N:-0}
HOLD_MS=${HOLD_MS:-20}
HOLD_PEER_MS=${HOLD_PEER_MS:-0}
HOLD_EACH=$HOLD_MS; [ "$HOLD_PEER_MS" -gt 0 ] && HOLD_EACH=$HOLD_PEER_MS
WBOUND=$(( 16 + (2 * HOLD_N * HOLD_EACH + 999) / 1000 ))
NREPO=/src/$(basename "$HERE")
MNT=/mnt/fourkn
DIR=$MNT/merge
P=/sys/module/mxfs/parameters
CTRS="iwr_merge_blocks iwr_merge_miscompares iwr_merge_failed iwr_merge_empty iwr_merge_hold_landed"
SV=$(modinfo -F srcversion "$HERE/mxfs.ko")
MARK="FOURKN-MERGE-$(date -u +%Y%m%dT%H%M%SZ)"
OUT=$HERE/tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_fourkn_merge_$(tr / - <<<"$MXFS_CONFIG")
mkdir -p "$OUT"
exec > >(tee -a "$OUT/lap.log") 2>&1
fails=0
on() { timeout "$3" "$SSH" "$(lab_addr "$1")" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'; }
step() { echo "$(date -u +%FT%TZ) $*"; }
ck() { if [ "$2" = "$3" ]; then step "PASS $1 ($2)"; else step "FAIL $1 got=$2 want=$3"; fails=$((fails+1)); fi; }
abort() { step "ABORT $*"; for n in $mounted; do on "$n" "timeout 55 umount $MNT" 60 >/dev/null; done; exit 2; }
mounted=""
mount_both() {
    for n in "$N1" "$N2"; do
        r=$(on "$n" "mkdir -p $MNT; timeout 110 mount -t mxfs $DEV $MNT; echo mount_rc=\$?" 120)
        case $r in *mount_rc=0*) step "OK mount $n"; mounted="$mounted $n" ;; *) abort "mount $n: $(echo "$r" | tr '\n' '|')" ;; esac
    done
}
umount_all() {
    for n in $mounted; do
        r=$(on "$n" "timeout 55 umount $MNT; echo umount_rc=\$?" 60)
        case $r in *umount_rc=0*) step "OK umount $n" ;; *) step "FAIL umount $n: $(echo "$r" | tr '\n' '|')"; fails=$((fails+1)) ;; esac
    done
    mounted=""
}

echo "=== fourkn_merge_2node dev=$DEV nodes=$N1,$N2 config=$MXFS_CONFIG modargs='$MODARGS' rounds=$ROUNDS nf=$NF force_ms=$FORCE_MS out=$OUT $(date -u +%FT%TZ) ==="
"$HERE/scripts/clyde_preflight.sh" > "$OUT/preflight.txt" 2>&1 || abort "host preflight failed: $(tail -1 "$OUT/preflight.txt")"
step "OK host preflight: $(tail -1 "$OUT/preflight.txt")"
for n in "$N1" "$N2"; do
    on "$n" "echo $MARK > /dev/kmsg" 10 >/dev/null
    on "$n" "mountpoint -q /src || { mkdir -p /src; timeout 30 mount -t nfs 192.168.120.1:/src /src -o rw,vers=4.1,hard,timeo=600,retrans=2,tcp,rsize=1048576,wsize=1048576; }" 40 >/dev/null
    r=$(on "$n" "grep -q ' $MNT ' /proc/mounts && timeout 55 umount $MNT; if lsmod | grep -q '^mxfs '; then rmmod mxfs; fi; for t in 1 2 3; do cp -f $NREPO/mxfs.ko /root/mxfs.ko.fourkn && [ \"\$(md5sum < /root/mxfs.ko.fourkn | cut -d' ' -f1)\" = $KOMD5 ] && break; echo 3 > /proc/sys/vm/drop_caches; sleep 1; done; md5sum < /root/mxfs.ko.fourkn | cut -d' ' -f1; insmod /root/mxfs.ko.fourkn $MODARGS; cat /sys/module/mxfs/srcversion; blockdev --getss $DEV; cat $P/force_transport $P/target_cache_protected $P/log_repeat_limit" 30 | tr '\n' ' ')
    case $r in "$KOMD5 $SV 4096 $FT 1 0 ") step "OK insmod $n md5/srcversion/logical/force_transport/target_cache_protected/log_repeat_limit: $r" ;; *) abort "insmod $n: [$r] (want md5 $KOMD5, srcversion $SV on a 4096-byte device, force_transport=$FT target_cache_protected=1 log_repeat_limit=0)" ;; esac
done
r=$(on "$N1" "$NREPO/tools/mkfs_mxfs -f $DEV 2>&1 | tail -2; echo mkfs_rc=\${PIPESTATUS[0]}" 300)
case $r in *mkfs_rc=0*) step "OK mkfs on $N1" ;; *) abort "mkfs on $N1: $(echo "$r" | tr '\n' '|')" ;; esac
mount_both
for n in "$N1" "$N2"; do
    r=$(on "$n" "for c in $CTRS; do echo 0 > $P/\$c; done; echo $HOLD_MS > $P/dbg_iwr_merge_hold_ms; echo $HOLD_PEER_MS > $P/dbg_iwr_merge_hold_peer_ms; echo $HOLD_N > $P/dbg_iwr_merge_hold_n; cat $P/dbg_iwr_merge_hold_n $P/dbg_iwr_merge_hold_ms $P/dbg_iwr_merge_hold_peer_ms" 10 | tr '\n' ' ')
    [ "$r" = "$HOLD_N $HOLD_MS $HOLD_PEER_MS " ] || abort "$n did not arm the hold: [$r] (want $HOLD_N blocks, $HOLD_MS ms fixed, $HOLD_PEER_MS ms waiting for the peer)"
done
if [ "$HOLD_PEER_MS" -gt 0 ]; then
    step "INFO each node holds its first $HOLD_N merged blocks between read and swap until the peer's swap lands, at most $HOLD_PEER_MS ms; workload bound ${WBOUND}s"
else
    step "INFO each node holds its first $HOLD_N merged blocks $HOLD_MS ms between read and swap; workload bound ${WBOUND}s"
fi

# the files, from node 1, and the blocks their inodes share
on "$N1" "mkdir -p $DIR && for i in \$(seq 1 $NF); do : > $DIR/f\$i; done && sync && for i in \$(seq 1 $NF); do echo \$i \$(stat -c %i $DIR/f\$i); done" 15 > "$OUT/inodes.txt"
[ "$(grep -cE '^[0-9]+ [0-9]+$' "$OUT/inodes.txt")" = "$NF" ] || abort "node 1 made $(grep -cE '^[0-9]+ [0-9]+$' "$OUT/inodes.txt")/$NF files: $(tail -2 "$OUT/inodes.txt" | tr '\n' '|')"
shared=$(awk '{b = int($2 / 8); p[b] = p[b] " " ($1 % 2)} END {n = 0; for (b in p) if (p[b] ~ / 0/ && p[b] ~ / 1/) n++; print n}' "$OUT/inodes.txt")
step "INFO $NF files in $(awk '{print int($2 / 8)}' "$OUT/inodes.txt" | sort -u | wc -l) inode blocks, $shared of them holding both nodes' files"
[ "$shared" -ge 1 ] || abort "no inode block holds files of both halves; the lap cannot make the nodes share a block"

# both halves at once, each with its own output and exit code
t0=$(date +%s%N)
# MERGE_NODE_BOUND=0 bounds the ssh client alone, as before the fix: the control
# of D-FOURKN-MERGE-LAP-OVERRUN-LEAVES-ITS-WORKER-HOLDING-THE-MOUNT
NODEBOUND="timeout --foreground $((WBOUND - 3)) "
[ "${MERGE_NODE_BOUND:-1}" = 0 ] && NODEBOUND=""
step "INFO the worker's node-side bound: ${NODEBOUND:-none (MERGE_NODE_BOUND=0)}"
on "$N1" "$NODEBOUND$NREPO/tests/fourkn_merge_worker.sh $DIR 1 $ROUNDS $NF" "$WBOUND" > "$OUT/w1.txt" & p1=$!
on "$N2" "$NODEBOUND$NREPO/tests/fourkn_merge_worker.sh $DIR 0 $ROUNDS $NF" "$WBOUND" > "$OUT/w2.txt" & p2=$!
wait $p1; rc1=$?; wait $p2; rc2=$?
step "INFO workload wall $(( ($(date +%s%N) - t0) / 1000000 )) ms; $N1: rc=$rc1 $(grep -a WORKER "$OUT/w1.txt" | tail -1); $N2: rc=$rc2 $(grep -a WORKER "$OUT/w2.txt" | tail -1)"
ck "$N1's half ran to its end with no error" "$(grep -c "^WORKER_DONE rounds=$ROUNDS errors=0 " "$OUT/w1.txt")" 1
ck "$N2's half ran to its end with no error" "$(grep -c "^WORKER_DONE rounds=$ROUNDS errors=0 " "$OUT/w2.txt")" 1
m1=6$((ROUNDS % 8))4; m2=6$((ROUNDS % 8))2
# Each worker prints the mode it last set on each of its files (MODE <i> <mode>), also when its
# bound stopped it mid-round; the mode check reads those, so a stopped workload is still checked
# against what was written. Graded against the last round's modes alone, every file of a stopped
# worker read wrong and the lap looked like lost setattrs
# (D-FOURKN-MERGE-WORKLOAD-OVERRAN-16S-WHEN-EVERY-CAW-TOOK-TWICE-AS-LONG, b20261024-f31760).
# MERGE_MODES_FROM_WORKER=0 expects the last round's modes, as before: the control.
cat "$OUT/w1.txt" "$OUT/w2.txt" | awk '$1 == "MODE" && NF == 3 {print $2, $3}' > "$OUT/modes_written.txt"
[ "${MERGE_MODES_FROM_WORKER:-1}" = 0 ] && : > "$OUT/modes_written.txt"
step "INFO $(wc -l < "$OUT/modes_written.txt") file mode(s) as the workers last set them (MERGE_MODES_FROM_WORKER=${MERGE_MODES_FROM_WORKER:-1})"

# the counters, before the unmount's own flushes add to them; the hold is
# disarmed first, and what it had left says how many blocks it held
for n in "$N1" "$N2"; do
    on "$n" "echo dbg_iwr_merge_hold_left=\$(cat $P/dbg_iwr_merge_hold_n); echo 0 > $P/dbg_iwr_merge_hold_n; echo 0 > $P/dbg_iwr_merge_hold_peer_ms; for c in $CTRS; do echo \$c=\$(cat $P/\$c); done" 10 > "$OUT/ctr_$n.txt"
    step "INFO $n after the workload: $(tr '\n' ' ' < "$OUT/ctr_$n.txt")"
done

# THE FORCED OVERLAP (header): a block holding a file of each half
read -r fa fb fblk <<< "$(awk '{b = int($2 / 8); if ($1 % 2) { if (!(b in o)) o[b] = $1 } else if (!(b in e)) e[b] = $1}
                              END {for (b in o) if (b in e) {print o[b], e[b], b; exit}}' "$OUT/inodes.txt")"
forced=off
if [ "$FORCE_MS" -gt 0 ]; then
    forced=missed
    # each node stats the other's half, so the other writes back every inode it changed
    s1=$(on "$N1" "for i in \$(seq 2 2 $NF); do stat -c %a $DIR/f\$i > /dev/null || exit 1; done; echo settled" 30)
    s2=$(on "$N2" "for i in \$(seq 1 2 $NF); do stat -c %a $DIR/f\$i > /dev/null || exit 1; done; echo settled" 30)
    ck "both nodes wrote back the inodes they changed (each stat'ed the other's half)" "$s1 $s2" "settled settled"
    ck "$N2 took f$fb for writing" "$(on "$N2" "chmod 607 $DIR/f$fb && echo ok" 15)" ok
    before=$(on "$N1" "echo \$(cat $P/iwr_merge_miscompares) \$(cat $P/iwr_merge_hold_landed); echo $FORCE_MS > $P/dbg_iwr_merge_hold_peer_ms; echo 1 > $P/dbg_iwr_merge_hold_n; chmod 605 $DIR/f$fa || echo chmod_failed" 15)
    ck "$N1 changed f$fa armed" "$(grep -c chmod_failed <<< "$before")" 0
    before=$(head -1 <<< "$before")
    step "INFO forced overlap in inode block $fblk: f$fa ($N1) and f$fb ($N2); $N1 armed, miscompares and hold_landed before: $before"
    on "$N1" "timeout 55 umount $MNT; echo umount_rc=\$?" 60 > "$OUT/force_umount_$N1.txt" & pu=$!
    began=$(on "$N1" "for i in \$(seq 1 60); do [ \$(cat $P/dbg_iwr_merge_hold_n) = 0 ] && { echo began; break; }; sleep 0.05; done" 10)
    on "$N2" "chmod 606 $DIR/f$fb || echo chmod_failed; timeout 55 umount $MNT; echo umount_rc=\$?" 60 > "$OUT/force_umount_$N2.txt"
    wait $pu
    after=$(on "$N1" "echo \$(cat $P/iwr_merge_miscompares) \$(cat $P/iwr_merge_hold_landed); echo 0 > $P/dbg_iwr_merge_hold_n; echo 0 > $P/dbg_iwr_merge_hold_peer_ms" 10)
    step "INFO forced overlap: hold ${began:-never began}; $N1 miscompares and hold_landed after: $after"
    for n in "$N2" "$N1"; do
        case $(cat "$OUT/force_umount_$n.txt") in
            *chmod_failed*) step "FAIL $n's change of its file in the forced overlap"; fails=$((fails+1)) ;;
        esac
        case $(cat "$OUT/force_umount_$n.txt") in
            *umount_rc=0*) step "OK umount $n" ;;
            *) step "FAIL umount $n: $(tr '\n' '|' < "$OUT/force_umount_$n.txt")"; fails=$((fails+1)) ;;
        esac
    done
    mounted=""
    read -r c0 l0 <<< "$before"; read -r c1 l1 <<< "$after"
    if [ "$began" = began ] && [ "$(( ${l1:-0} - ${l0:-0} ))" -ge 1 ] && [ "$(( ${c1:-0} - ${c0:-0} ))" -ge 1 ]; then
        forced=landed
    fi
else
    umount_all
fi
for n in "$N1" "$N2"; do
    on "$n" "for c in $CTRS; do echo \$c=\$(cat $P/\$c); done" 10 > "$OUT/ctr_${n}_end.txt"
    step "INFO $n after the unmount: $(tr '\n' ' ' < "$OUT/ctr_${n}_end.txt")"
done

r=$(on "$N1" "$NREPO/tools/chk_mxfs $DEV > /tmp/fourkn_merge_chk.txt 2>&1; echo chk_rc=\$?; grep -a 'ERROR\|Record block tails\|^XFS superblock' /tmp/fourkn_merge_chk.txt | head -8" 60)
echo "$r" > "$OUT/chk.txt"
ck "chk_mxfs finds nothing on the volume both nodes wrote" "$(grep -c '^chk_rc=0$' "$OUT/chk.txt")" 1

mount_both
for n in "$N1" "$N2"; do
    on "$n" "echo 3 > /proc/sys/vm/drop_caches; for i in \$(seq 1 $NF); do echo \$i \$(stat -c %a $DIR/f\$i); done" 30 > "$OUT/modes_$n.txt"
    if [ "$FORCE_MS" -gt 0 ]; then
        bad=$(awk -v a="$m1" -v b="$m2" -v fa="$fa" -v fb="$fb" -v sf="$OUT/modes_written.txt" \
                  'BEGIN {while ((getline l < sf) > 0) {split(l, p, " "); set[p[1]] = p[2]}}
                   {w = ($1 == fa) ? 605 : ($1 == fb) ? 606 : ($1 in set) ? set[$1] : ($1 % 2) ? a : b; if ($2 != w) n++} END {print n + 0}' \
                  "$OUT/modes_$n.txt")
        ck "every file reads its own writer's last mode on $n (as each worker last set it, else $m1 odd, $m2 even; f$fa 605, f$fb 606)" "$(grep -cE '^[0-9]+ [0-9]+$' "$OUT/modes_$n.txt"):$bad" "$NF:0"
    else
        bad=$(awk -v a="$m1" -v b="$m2" -v sf="$OUT/modes_written.txt" \
                  'BEGIN {while ((getline l < sf) > 0) {split(l, p, " "); set[p[1]] = p[2]}}
                   {w = ($1 in set) ? set[$1] : ($1 % 2) ? a : b; if ($2 != w) n++} END {print n + 0}' \
                  "$OUT/modes_$n.txt")
        ck "every file reads its own writer's last mode on $n (as each worker last set it, else $m1 odd, $m2 even)" "$(grep -cE '^[0-9]+ [0-9]+$' "$OUT/modes_$n.txt"):$bad" "$NF:0"
    fi
done
umount_all

for n in "$N1" "$N2"; do
    on "$n" "dmesg | sed -n '/$MARK/,\$p'" 30 > "$OUT/dmesg_$n.txt"
    # every log check below counts lines after the mark: a ring that rolled
    # past it would hand them nothing to find
    [ "$(head -1 "$OUT/dmesg_$n.txt" | grep -ac "$MARK")" = 1 ] || abort "$n's kernel ring no longer holds the lap's mark $MARK ($(wc -l < "$OUT/dmesg_$n.txt") lines captured): the log checks would read nothing"
    ck "no merged write failed or was refused on $n" "$(grep -ac 'P-IWR-MERGE-FAILED\|P-IWR-MERGE-REFUSED' "$OUT/dmesg_$n.txt")" 0
    ck "no corruption, shutdown, BUG or Oops on $n" "$(grep -acE 'BUG:|Oops|Shutting down filesystem|Corruption|corruption detected|P-LBS-REFUSED' "$OUT/dmesg_$n.txt")" 0
    ck "the merged write ran on $n" "$(awk -F= '$1 == "iwr_merge_blocks" {print ($2 > 0) ? "yes" : "no"}' "$OUT/ctr_${n}_end.txt")" yes
    ck "iwr_merge_failed is 0 on $n" "$(awk -F= '$1 == "iwr_merge_failed" {print $2}' "$OUT/ctr_${n}_end.txt")" 0
done
mis=$(cat "$OUT"/ctr_*_end.txt | awk -F= '$1 == "iwr_merge_miscompares" {s += $2} END {print s + 0}')
step "INFO MISCOMPARE retries, both nodes: $mis"
echo "=== fourkn_merge_2node: fails=$fails miscompares=$mis forced=$forced out=$OUT $(date -u +%FT%TZ) ==="
[ "$fails" -eq 0 ] || exit 1
[ "$forced" != missed ] || { step "VACUOUS the forced overlap did not land (hold ${began:-never began}; $N1 miscompares and hold_landed $before -> $after): the lap did not exercise the merged write's retry"; exit 3; }
[ "$mis" -ge 1 ] || { step "VACUOUS no swap miscompared: the lap did not exercise the merged write's retry"; exit 3; }
exit 0
