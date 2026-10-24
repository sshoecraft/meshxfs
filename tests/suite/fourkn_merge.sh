#!/bin/bash
# fourkn_merge — the merged-write row (docs/4kn-support.md, Verification): two
# nodes dirty different inodes of the same 4096-byte blocks of a 4K-native
# volume at once.  Every inode must keep its own writer's last change,
# chk_mxfs must find nothing, and the merged write's MISCOMPARE retries are
# counted, so a pass is known to have exercised them.
#
# On a 4K-native volume eight 512-byte inodes share a block and two nodes can
# hold the authority for different inodes in it.  The merged write
# (pal/linux/xfs_buf.c) reads the block past every cache, copies in only the
# slots this node owes, and swaps the block with COMPARE AND WRITE; a
# MISCOMPARE means the peer landed one of its own slots in between, and the
# block is read and merged again.  This row drives the same workload as
# tests/fourkn_merge_2node.sh on the cluster run.sh formed: node 1 creates NF
# files, so consecutive inode numbers share blocks; for ROUNDS rounds each node
# changes the mode of its half and stats the other half, a pair at a time, so
# both nodes drain the same block at once (tests/fourkn_merge_worker.sh).
#
# THE FORCED OVERLAP.  The two nodes' writes of a block rarely overlap on their
# own (0 MISCOMPAREs in ~480 merged writes a lap), and a hold that waits for
# the peer to write the held block catches it only when the peer happens to
# be writing that block: holding each node's first 8 merged blocks up to 1 s
# for the peer's swap still left one lap with none
# (D-FOURKN-MERGE-LAP-HELD-WINDOW-MISSES-THE-RETRY-IN-SOME-LAPS).  So the
# overlap is made, once a lap, at the unmount:
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
# fa must then read node 1's mode and fb node 2's.  The workload itself runs
# unheld (HOLD_N 0); HOLD_N, HOLD_MS and HOLD_PEER_MS still hold its first
# blocks as before when set.  FORCE_MS=0 leaves the overlap out: the unmounts
# are plain ones, the row's control.
#
# PASS needs:
#   - both halves ran every round with no error;
#   - with both nodes unmounted, chk_mxfs finds nothing;
#   - after both mounted again, every file reads its own writer's last mode on
#     both nodes;
#   - no merged write failed or was refused (iwr_merge_failed 0, no
#     P-IWR-MERGE-FAILED/REFUSED) and no node logged a corruption, a shutdown,
#     a BUG, an Oops or a refused block I/O;
#   - the merged write ran on both nodes (iwr_merge_blocks > 0);
#   - the forced overlap: node 1's held write of the block began, node 2's
#     swap of it landed inside the hold, and node 1's swap after it
#     miscompared and was retried; fa reads node 1's mode and fb node 2's;
#   - at least one swap miscompared and was retried (iwr_merge_miscompares on
#     both nodes together >= 1).  A lap with none, or whose forced overlap did
#     not land, did not exercise the retry: it is VACUOUS, reported as a FAIL
#     whose reason says so, never a PASS.
# It leaves the cluster mounted on both nodes, as it found it.
#
# Derived budget (tests/suite/manifest; RULE: TIMEOUTS ARE PERFORMANCE
# ASSERTIONS, NOT SAFETY NETS): infrastructure, measured on the 4K-native LUN
# (tests/evidence/20261022T154721Z_fourkn_merge_2-disk-caw-direct and
# 20261022T135408Z_fourkn_merge_2-net-mesh-direct): both unmounts 2-3 s, the
# check 1-2 s, both mounts one after the other 9-14 s, the creates 1 s, the
# arming, counter reads and log reads ~6 s: 26 s.  Workload, from what it
# should take (fourkn_merge_2node.sh's derivation): per round a node makes 32
# mode changes and 32 stats, a stat of a peer-held inode one merged write
# (~3 ms) and a mode change after it a lock round trip (~1 ms): 2.6 s for 20
# rounds, 2x that 6 s, plus 10 s of ssh connect: 16 s.  The forced overlap:
# the two settling passes, 32 stats each of a peer-held inode (~4 ms) and an
# ssh each, ~2 s; the two changes of fb, the arming and the poll, four ssh, ~3
# s; node 1's hold lasts until node 2's unmount writes fb back, an ssh and a
# change after the hold began, ~1.5 s, FORCE_MS at most.  26 + 16 + 2 + 3 + 5
# = 52 s at the defaults; the row's budget is 55 s (measured 29-31 s a lap on
# the TCP lock network, 37 s on COMPARE AND WRITE: tests/evidence/lanes/
# g2d_forced_overlap_dev_20261023T034827Z).
#
# Env (run.sh hands a host row these): MXFS_NODES (2), MXFS_NODE_LIST (default
# test1,test2), MXFS_DEV, MXFS_MNT, MXFS_RUN_ID, MXFS_MOUNT_OPTS.  ROUNDS (20),
# NF (64), FORCE_MS (5000; 0 leaves the forced overlap out), HOLD_N (0),
# HOLD_MS (20), HOLD_PEER_MS (1000).
set -u
N=${MXFS_NODES:?}
RUN=${MXFS_RUN_ID:-local}
MNT=${MXFS_MNT:-/mnt/shared}
DEV=${MXFS_DEV:?}
ROUNDS=${ROUNDS:-20}
NF=${NF:-64}
FORCE_MS=${FORCE_MS:-5000}
HOLD_N=${HOLD_N:-0}
HOLD_MS=${HOLD_MS:-20}
HOLD_PEER_MS=${HOLD_PEER_MS:-1000}
cd /src/mxfs || { echo "RESULT: FAIL src=test | measured=setup | reason=not-on-clyde"; exit 1; }
# shellcheck source=tests/lib/rig.sh
. tests/lib/rig.sh
NODES_CSV=${MXFS_NODE_LIST:-$(seq -f 'test%g' 1 "$N" | paste -sd,)}
N1=${NODES_CSV%%,*}
N2=${NODES_CSV##*,}
OUT=tests/evidence/board_${RUN}_fourkn_merge
mkdir -p "$OUT"
DIR=$MNT/fourkn_merge_$RUN
P=/sys/module/mxfs/parameters
CTRS="iwr_merge_blocks iwr_merge_miscompares iwr_merge_failed iwr_merge_empty iwr_merge_hold_landed"
HOLD_EACH=$HOLD_MS; [ "$HOLD_PEER_MS" -gt 0 ] && HOLD_EACH=$HOLD_PEER_MS
WBOUND=$(( 16 + (2 * HOLD_N * HOLD_EACH + 999) / 1000 ))
MARK="FOURKN-MERGE-$RUN"
fails=0
why=""
measured=""
ck() {  # <what> <got> <want>
    if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"; else echo "  FAIL $1 got=$2 want=$3"; fails=$((fails + 1)); why="${why}${why:+; }$1 (got $2)"; fi
}
finish() {  # <status> [reason]
    echo "RESULT: $1 src=test | measured=${measured:-none} | reason=${2:-$why} (evidence $OUT)"
}
mounted=" $N1 $N2 "
mount_one() {
    local r
    r=$(rs 120 "$1" "mkdir -p $MNT; grep -q ' $MNT ' /proc/mounts || timeout 110 mount -t mxfs ${MXFS_MOUNT_OPTS:-} $DEV $MNT; grep -q ' $MNT mxfs ' /proc/mounts && echo mount_ok")
    case $r in *mount_ok*) echo "  OK mount $1"; mounted="$mounted$1 " ;; *) echo "  FAIL mount $1: $(echo "$r" | tr '\n' '|')"; fails=$((fails + 1)); why="${why}${why:+; }$1 did not mount again" ;; esac
}
umount_one() {
    local r
    r=$(rs 60 "$1" "timeout 55 umount $MNT; grep -q ' $MNT mxfs ' /proc/mounts || echo umount_ok")
    case $r in *umount_ok*) echo "  OK umount $1"; mounted=${mounted/ $1 / } ;; *) echo "  FAIL umount $1: $(echo "$r" | tr '\n' '|')"; fails=$((fails + 1)); why="${why}${why:+; }$1 did not unmount" ;; esac
}
disarm() { local n; for n in "$N1" "$N2"; do rs 10 "$n" "echo 0 > $P/dbg_iwr_merge_hold_n; echo 0 > $P/dbg_iwr_merge_hold_peer_ms; echo 20 > $P/dbg_iwr_merge_hold_ms" >/dev/null; done; }
trap disarm EXIT

[ "$N" = 2 ] && [ "$N1" != "$N2" ] || { finish FAIL "needs 2 nodes, got $N ($NODES_CSV)"; exit 1; }
echo "  INFO nodes $N1 $N2 dev $DEV mnt $MNT rounds $ROUNDS files $NF hold $HOLD_N blocks, $HOLD_MS ms fixed or $HOLD_PEER_MS ms for the peer; workload bound ${WBOUND}s; forced overlap's hold ${FORCE_MS} ms at most"
for n in "$N1" "$N2"; do
    r=$(rs 15 "$n" "echo '$MARK' > /dev/kmsg; blockdev --getss $DEV; grep -c ' $MNT mxfs ' /proc/mounts; [ -w $P/dbg_iwr_merge_hold_peer_ms ] && echo knob" | tr '\n' ' ')
    case $r in
        "4096 1 knob ") ;;
        *) finish FAIL "$n: [$r]; this row needs $DEV of 4096-byte logical blocks mounted at $MNT and a module with dbg_iwr_merge_hold_peer_ms"; exit 1 ;;
    esac
done
for n in "$N1" "$N2"; do
    r=$(rs 10 "$n" "for c in $CTRS; do echo 0 > $P/\$c; done; echo $HOLD_MS > $P/dbg_iwr_merge_hold_ms; echo $HOLD_PEER_MS > $P/dbg_iwr_merge_hold_peer_ms; echo $HOLD_N > $P/dbg_iwr_merge_hold_n; cat $P/dbg_iwr_merge_hold_n $P/dbg_iwr_merge_hold_ms $P/dbg_iwr_merge_hold_peer_ms" | tr '\n' ' ')
    [ "$r" = "$HOLD_N $HOLD_MS $HOLD_PEER_MS " ] || { finish FAIL "$n did not arm the hold: [$r]"; exit 1; }
done

# the files, from node 1, and the blocks their inodes share
rs 15 "$N1" "mkdir -p $DIR && for i in \$(seq 1 $NF); do : > $DIR/f\$i; done && sync && for i in \$(seq 1 $NF); do echo \$i \$(stat -c %i $DIR/f\$i); done" > "$OUT/inodes.txt"
[ "$(grep -cE '^[0-9]+ [0-9]+$' "$OUT/inodes.txt")" = "$NF" ] || { finish FAIL "$N1 made $(grep -cE '^[0-9]+ [0-9]+$' "$OUT/inodes.txt")/$NF files"; exit 1; }
shared=$(awk '{b = int($2 / 8); p[b] = p[b] " " ($1 % 2)} END {n = 0; for (b in p) if (p[b] ~ / 0/ && p[b] ~ / 1/) n++; print n}' "$OUT/inodes.txt")
echo "  INFO $NF files in $(awk '{print int($2 / 8)}' "$OUT/inodes.txt" | sort -u | wc -l) inode blocks, $shared of them holding both nodes' files"
[ "$shared" -ge 1 ] || { finish FAIL "no inode block holds files of both halves"; exit 1; }

# both halves at once, each with its own output and exit code
t0=$(date +%s%N)
# The worker is bounded on its node 3 s inside the ssh client's bound, so a
# workload that overruns stops itself (WORKER_STOPPED) and lets the mount go
# before the client gives up; bounded on the client alone it went on running
# with $MNT open after the row had ended, and the next unmount failed 'target is
# busy' (D-FOURKN-MERGE-SUITE-ROW-WORKER-BOUNDED-ONLY-ON-THE-SSH-CLIENT).
# FOURKN_MERGE_NODE_BOUND=0 bounds the client alone, as before: the control.
NODEBOUND="timeout --foreground $((WBOUND - 3)) "
[ "${FOURKN_MERGE_NODE_BOUND:-1}" = 0 ] && NODEBOUND=""
echo "  INFO the worker's node-side bound: ${NODEBOUND:-none (FOURKN_MERGE_NODE_BOUND=0)}"
rs "$WBOUND" "$N1" "$NODEBOUND/src/mxfs/tests/fourkn_merge_worker.sh $DIR 1 $ROUNDS $NF" > "$OUT/w1.txt" & p1=$!
rs "$WBOUND" "$N2" "$NODEBOUND/src/mxfs/tests/fourkn_merge_worker.sh $DIR 0 $ROUNDS $NF" > "$OUT/w2.txt" & p2=$!
wait $p1; rc1=$?; wait $p2; rc2=$?
wall=$(( ($(date +%s%N) - t0) / 1000000 ))
echo "  INFO workload wall $wall ms; $N1 rc=$rc1 $(grep -a WORKER "$OUT/w1.txt" | tail -1); $N2 rc=$rc2 $(grep -a WORKER "$OUT/w2.txt" | tail -1)"
ck "$N1's half ran every round with no error" "$(grep -c "^WORKER_DONE rounds=$ROUNDS errors=0 " "$OUT/w1.txt")" 1
ck "$N2's half ran every round with no error" "$(grep -c "^WORKER_DONE rounds=$ROUNDS errors=0 " "$OUT/w2.txt")" 1
m1=6$((ROUNDS % 8))4; m2=6$((ROUNDS % 8))2

# the counters, before the unmount's own flushes add to them; the hold is
# disarmed first, and what it had left says how many blocks it held
for n in "$N1" "$N2"; do
    rs 10 "$n" "echo dbg_iwr_merge_hold_left=\$(cat $P/dbg_iwr_merge_hold_n); echo 0 > $P/dbg_iwr_merge_hold_n; echo 0 > $P/dbg_iwr_merge_hold_peer_ms; for c in $CTRS; do echo \$c=\$(cat $P/\$c); done" > "$OUT/ctr_$n.txt"
    echo "  INFO $n after the workload: $(tr '\n' ' ' < "$OUT/ctr_$n.txt")"
done

# THE FORCED OVERLAP (header): a block holding a file of each half
read -r fa fb fblk <<< "$(awk '{b = int($2 / 8); if ($1 % 2) { if (!(b in o)) o[b] = $1 } else if (!(b in e)) e[b] = $1}
                              END {for (b in o) if (b in e) {print o[b], e[b], b; exit}}' "$OUT/inodes.txt")"
forced=off
if [ "$FORCE_MS" -gt 0 ]; then
    forced=missed
    # each node stats the other's half, so the other writes back every inode it changed
    s1=$(rs 30 "$N1" "for i in \$(seq 2 2 $NF); do stat -c %a $DIR/f\$i > /dev/null || exit 1; done; echo settled")
    s2=$(rs 30 "$N2" "for i in \$(seq 1 2 $NF); do stat -c %a $DIR/f\$i > /dev/null || exit 1; done; echo settled")
    ck "both nodes wrote back the inodes they changed (each stat'ed the other's half)" "$s1 $s2" "settled settled"
    ck "$N2 took f$fb for writing" "$(rs 15 "$N2" "chmod 607 $DIR/f$fb && echo ok")" ok
    before=$(rs 15 "$N1" "echo \$(cat $P/iwr_merge_miscompares) \$(cat $P/iwr_merge_hold_landed); echo $FORCE_MS > $P/dbg_iwr_merge_hold_peer_ms; echo 1 > $P/dbg_iwr_merge_hold_n; chmod 605 $DIR/f$fa || echo chmod_failed")
    ck "$N1 changed f$fa armed" "$(grep -c chmod_failed <<< "$before")" 0
    before=$(head -1 <<< "$before")
    echo "  INFO forced overlap in inode block $fblk: f$fa ($N1) and f$fb ($N2); $N1 armed, miscompares and hold_landed before: $before"
    rs 60 "$N1" "timeout 55 umount $MNT; grep -q ' $MNT mxfs ' /proc/mounts || echo umount_ok" > "$OUT/force_umount_$N1.txt" & pu=$!
    began=$(rs 10 "$N1" "for i in \$(seq 1 60); do [ \$(cat $P/dbg_iwr_merge_hold_n) = 0 ] && { echo began; break; }; sleep 0.05; done")
    rs 60 "$N2" "chmod 606 $DIR/f$fb || echo chmod_failed; timeout 55 umount $MNT; grep -q ' $MNT mxfs ' /proc/mounts || echo umount_ok" > "$OUT/force_umount_$N2.txt"
    wait $pu
    after=$(rs 10 "$N1" "echo \$(cat $P/iwr_merge_miscompares) \$(cat $P/iwr_merge_hold_landed); echo 0 > $P/dbg_iwr_merge_hold_n; echo 0 > $P/dbg_iwr_merge_hold_peer_ms")
    echo "  INFO forced overlap: hold ${began:-never began}; $N1 miscompares and hold_landed after: $after"
    for n in "$N2" "$N1"; do
        case $(cat "$OUT/force_umount_$n.txt") in
            *chmod_failed*) echo "  FAIL $n's change of its file in the forced overlap"; fails=$((fails + 1)); why="${why}${why:+; }$n could not change its forced-overlap file" ;;
        esac
        case $(cat "$OUT/force_umount_$n.txt") in
            *umount_ok*) echo "  OK umount $n"; mounted=${mounted/ $n / } ;;
            *) echo "  FAIL umount $n: $(tr '\n' '|' < "$OUT/force_umount_$n.txt")"; fails=$((fails + 1)); why="${why}${why:+; }$n did not unmount" ;;
        esac
    done
    read -r c0 l0 <<< "$before"; read -r c1 l1 <<< "$after"
    if [ "$began" = began ] && [ "$(( ${l1:-0} - ${l0:-0} ))" -ge 1 ] && [ "$(( ${c1:-0} - ${c0:-0} ))" -ge 1 ]; then
        forced=landed
    fi
else
    umount_one "$N2"; umount_one "$N1"
fi
for n in "$N1" "$N2"; do
    rs 10 "$n" "for c in $CTRS; do echo \$c=\$(cat $P/\$c); done" > "$OUT/ctr_${n}_end.txt"
done
if [ -z "${mounted// /}" ]; then
    rs 60 "$N1" "/src/mxfs/tools/chk_mxfs $DEV > /tmp/fourkn_merge_chk.txt 2>&1; echo chk_rc=\$?; grep -a 'ERROR\|Record block tails\|^XFS superblock' /tmp/fourkn_merge_chk.txt | head -8" > "$OUT/chk.txt"
    ck "chk_mxfs finds nothing on the volume both nodes wrote" "$(grep -c '^chk_rc=0$' "$OUT/chk.txt")" 1
fi
mount_one "$N1"; mount_one "$N2"
for n in "$N1" "$N2"; do
    rs 30 "$n" "echo 3 > /proc/sys/vm/drop_caches; for i in \$(seq 1 $NF); do echo \$i \$(stat -c %a $DIR/f\$i); done" > "$OUT/modes_$n.txt"
    fa_want=$m1; fb_want=$m2; [ "$FORCE_MS" -gt 0 ] && { fa_want=605; fb_want=606; }
    bad=$(awk -v a="$m1" -v b="$m2" -v fa="$fa" -v fb="$fb" -v wa="$fa_want" -v wb="$fb_want" \
              '{w = ($1 == fa) ? wa : ($1 == fb) ? wb : ($1 % 2) ? a : b; if ($2 != w) n++} END {print n + 0}' "$OUT/modes_$n.txt")
    ck "every file reads its own writer's last mode on $n ($m1 odd, $m2 even, f$fa $fa_want, f$fb $fb_want)" "$(grep -cE '^[0-9]+ [0-9]+$' "$OUT/modes_$n.txt"):$bad" "$NF:0"
done
rs 30 "$N1" "rm -rf $DIR" >/dev/null

for n in "$N1" "$N2"; do
    rs 30 "$n" "dmesg | sed -n '/$MARK/,\$p'" > "$OUT/dmesg_$n.txt"
    # every log check below counts lines after the mark: a ring that rolled
    # past it would hand them nothing to find
    ck "$n's kernel ring still holds the row's mark" "$(head -1 "$OUT/dmesg_$n.txt" | grep -ac "$MARK")" 1
    ck "no merged write failed or was refused on $n" "$(grep -ac 'P-IWR-MERGE-FAILED\|P-IWR-MERGE-REFUSED' "$OUT/dmesg_$n.txt")" 0
    ck "no corruption, shutdown, BUG, Oops or refused block I/O on $n" "$(grep -acE 'BUG:|Oops|Shutting down filesystem|Corruption|corruption detected|P-LBS-REFUSED' "$OUT/dmesg_$n.txt")" 0
    ck "the merged write ran on $n" "$(awk -F= '$1 == "iwr_merge_blocks" {print ($2 > 0) ? "yes" : "no"}' "$OUT/ctr_${n}_end.txt")" yes
    ck "iwr_merge_failed is 0 on $n" "$(awk -F= '$1 == "iwr_merge_failed" {print $2}' "$OUT/ctr_${n}_end.txt")" 0
done
sum() { cat "$OUT"/ctr_*_end.txt | awk -F= -v k="$1" '$1 == k {s += $2} END {print s + 0}'; }
mis=$(sum iwr_merge_miscompares)
landed=$(sum iwr_merge_hold_landed)
blocks=$(sum iwr_merge_blocks)
measured="miscompares=$mis hold_landed=$landed merged_blocks=$blocks workload_ms=$wall hold=${HOLD_N}x${HOLD_PEER_MS}ms forced=$forced"
echo "  INFO $measured"
# the counts in node 1's kernel log too: a batch lap's exposure is read from
# the nodes' kernel logs, and the merged write counts its retries without
# logging them
rs 10 "$N1" "echo '$MARK counted $measured' > /dev/kmsg" >/dev/null
if [ "$fails" -gt 0 ]; then finish FAIL; exit 1; fi
if [ "$forced" = missed ]; then
    finish FAIL "VACUOUS: the forced overlap did not land (hold ${began:-never began}; $N1 miscompares and hold_landed $before -> $after), so the row did not exercise the merged write's retry by construction"
    exit 1
fi
if [ "$mis" -lt 1 ]; then
    finish FAIL "VACUOUS: no swap miscompared in $blocks merged writes (hold_landed=$landed), so the row did not exercise the merged write's retry"
    exit 1
fi
finish PASS "every inode kept its writer's last change; $mis MISCOMPARE(s) retried"
exit 0
