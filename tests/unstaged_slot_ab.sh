#!/bin/bash
# tests/unstaged_slot_ab.sh — same-build A/B of the never-staged logged-slot
# mask of the partial inode-cluster write (module knob unstaged_logged_skip),
# on a directed workload, for D-INODE-CLUSTER-PUBLISH-WITHOUT-AUTHORITY shape
# (c), hypothesis H-UB1.
#
# H-UB1 (the record, session 88): an inode item is attached to its cluster
# buffer when the inode is first logged (precommit), not when it is copied in,
# so the partial cluster write (pal/linux/xfs_buf.c
# mxfs_submit_partial_inode_write) counts a slot as logged while its bytes are
# still whatever the buffer last read for it.  When that read predates a
# peer's write of the slot, a write of another slot of the cluster puts the
# older image back over the peer's (rk5: ino 131, the peer's free gen ...163
# reverted to its unlinked gen ...162 image, 3 ms after this node's create
# claimed the number).  The fix masks a staged slot whose stage epoch is 0
# (never copied in) that the write does not flush.
# PREDICTION IF TRUE: with unstaged_logged_skip=0, X's partial write of the
# cluster carries the reused number's old live image over the peer's free:
# unstaged_logged_regressed > 0 and a P-DINO-CLOBBER regress on that slot;
# with =1 the slot is masked (unstaged_logged_prevented > 0), nothing
# regresses, and the audit is CLEAN.
#
# THE SHAPE, per iteration, X = the group's first node, Y = its second, in
# X's directory D, with s2 and f two files of one inode cluster C that holds
# neither D nor anything else the lap touches (s1, the third file of the
# setup's run, is a spare), f being X's own last life of the number N:
#   Y opens f and holds it (a local process waiting on a file in Y's /tmp, so
#     no signal file adds lock traffic), removes it and syncs: the unlink
#     lands, the free waits for Y's last close;
#   X drops its caches, which evicts its in-core copy of N's old life, so its
#     later create of N is a cache MISS: a v5 create builds a fresh core and
#     never reads the cluster (xfs_iget_cache_miss), and the fresh life's
#     stage epoch is 0.  X then touches s2: s2's cache-miss read invalidates
#     and re-reads C, so X's buffer holds N's pre-free image, and s2's change
#     is logged (attached to C, pinned);
#   Y closes f: as unlinker and last closer it frees N; its sync and AIL push
#     land the free image on the platter.  X holds no lock on N, so nothing
#     tells X's buffer.  Y then drops its caches: its reclaim of the freed
#     copy is what releases its grant on N (P975-TENURE-END-EVICT why=reclaim;
#     left to the background reclaim it comes about 5 s later), and the
#     allocator's probe of a number a peer still holds skips it and cools it
#     for 500-1000 ms;
#   X unlinks one spacer of N's inode chunk outside C that a holder process
#     on X keeps open (so it stays allocated and N stays the lowest free
#     number): the unlink's AGI read takes N's AG with a BLOCKING acquire,
#     recalling it from Y, whose free cached it.  The create's first pass only
#     try-locks each AG it owns and passes a peer-held one by, so without this
#     the create lands in the node's next owned AG;
#   X arms dbg_ail_pin_ino=N (xfsaild skips the new life's own item, so only
#     another slot's flush can write C while the new life is attached) and
#     dbg_iflush_pause_ino=s2 (xfsaild holds C locked for USL_PAUSE_MS after
#     s2's copy-in), fsyncs s2 (its change checkpointed, in the AIL) and kicks
#     xfsaild through debugfs ail_push; once the pause has fired it creates f:
#     the allocator hands back N, and the new life's first log attaches it to
#     C, waiting for the buffer lock until the pause ends (xfs_inode_item_push
#     queues the buffer for the delayed write and unlocks it; the submission
#     that follows reads the attached items).  The partial write xfsaild then
#     submits carries N's slot, attached and never copied in, with the
#     buffer's pre-free bytes: rk5's write.  Then X disarms and syncs, which
#     lands the new life's own image.
# Each iteration logs f's number, whether X's create reused it and stayed in
# N's chunk, whether Y logged its release of N, how long the spacer's unlink
# took, whether the pause fired and how long X waited for it.
# Lap uslc1 (s1 fsynced, the k<i> files in C) found only setup spacers: the
# k<i> reads and the create re-read C.  Lap uslc2 (Y freed f before X's
# re-read, the create a cache HIT on X's old copy) wrote N's slot in 17 of 20
# iterations with the platter's free image (X re-read C after Y's free) and
# with the recycled copy's stage epoch, which the dead-tenure stage mask
# (P235-EX-STALE-SKIP, stage_epoch=2 now_epoch=3) took: no never-staged slot.
# Laps uslc3 (2/net/mesh/direct) and uslc4 (2/disk/caw/mpath, the cache-miss
# shape without the two releases above) reused N in 0 of 6 iterations each:
# uslc4's creates went to AGs 8, 12, 16 (fresh chunks; Y cached AG 4 from its
# free and AG 0 from its mount), then took 132 and 133 in AG 0 with 131 and
# 132 free in the inobt and still held by Y, whose grant on 131 left at its
# background reclaim 5.3 s after the free.
#
# THE GRADES
#   ABORT     prep, srcversion, knob read-back, setup or counter read failed
#   VACUOUS   no P-UB1-UNSTAGED-SKIP line on X names a number an iteration's
#             create reused: no never-staged slot of the shape rode a cluster
#             write (the setup's spacers print such lines too; they measure
#             nothing), and the lap measured nothing
#   skip 0    CONTROL-SHOWS-CAUSE when X's unstaged_logged_regressed > 0;
#             CONTROL-NO-REGRESS otherwise
#   skip 1    PASS when X's unstaged_logged_regressed is 0, neither node logs
#             a P-DINO-CLOBBER regress or a node failure, and the cold audit
#             is CLEAN errors=0 (prevented is reported); FAIL otherwise
#
# Budgets (derived): prep and the cold audit are run.sh rows under their own
# manifest budgets (run.sh flips an overrun to FAIL itself, so no outer
# timeout).  Setup: up to 200 creates and one sync, 60 s; the spacer list and
# X's holder 20 s each.  An iteration is four ssh steps: Y's open, unlink and
# sync (an EX recall, ~1 s), 20 s; X's cache drop and touch (a cold read of C,
# ~0.5 s), 20 s; Y's close, the free, sync and AIL push (~1.5 s), its cache
# drop and at most 2 s for the release line, 30 s; X's spacer unlink (a recall
# of D and of the AG from Y, ~1 s), arming, fsync, kick, at most 2 s for the
# pause to fire, the create (held up to USL_PAUSE_MS on C's lock), disarm and
# sync (~3 s past the pause), 40 s.  Counters, knob resets 20 s per node; the
# stream copy 120 s per node.
#
# Usage: tests/unstaged_slot_ab.sh <label> <skip 0|1> [iters=20] [config=2/disk/caw/direct] [group=g2]
# Env:   USL_KICKS (default 0) files created in other clusters before the run
#        (spacers only), USL_PAUSE_MS (default 1500) how long xfsaild holds C
# Exit 0 PASS / CONTROL-*, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; SKIP=${2:?skip 0|1}; ITERS=${3:-20}
CONFIG=${4:-2/disk/caw/direct}; GROUP=${5:-g2}
KICKS=${USL_KICKS:-0}; PAUSE=${USL_PAUSE_MS:-1500}
case "$SKIP" in 0|1) ;; *) echo "skip must be 0 or 1"; exit 2 ;; esac
for v in "$ITERS" "$KICKS" "$PAUSE"; do
    case "$v" in ''|*[!0-9]*) echo "iters, USL_KICKS and USL_PAUSE_MS must be whole numbers"; exit 2 ;; esac
done
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
read -r X Y rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${X:-}" ] && [ -n "${Y:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
NODES=$(tools/mxfs_lab.sh group "$GROUP")
# run.sh holds the nodes only while it runs; between its calls the workload
# below is invisible to tools/vm_pool.sh, whose idle sweep would shut them off
. tests/lib/runlock.sh
vmhold_take "unstaged_slot_ab $LABEL" $NODES \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold $NODES"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_unstaged_slot_$LABEL
mkdir -p "$OUT"
MARK="UNSTAGED-SLOT-$LABEL-$$"
P=/sys/module/mxfs/parameters
CNTS="unstaged_logged_found unstaged_logged_prevented unstaged_logged_regressed"
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
echo "=== unstaged_slot_ab label=$LABEL skip=$SKIP iters=$ITERS kicks=$KICKS $CONFIG $GROUP [$NODES] X=$X Y=$Y build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
want=$(modinfo -F srcversion mxfs.ko)
for n in $NODES; do
    sv=$(rs 20 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT label=$LABEL -- $n runs '$sv', not the tree build $want evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "echo $SKIP > $P/unstaged_logged_skip; echo 1 > $P/dino_clobber_check; for c in $CNTS; do echo 0 > $P/\$c; done; echo 0 > $P/dbg_iflush_pause_ino; echo 0 > $P/dbg_ail_pin_ino; echo $PAUSE > $P/dbg_iflush_pause_ms; echo $MARK > /dev/kmsg; echo \$(cat $P/unstaged_logged_skip)/\$(cat $P/dino_clobber_check)/\$(cat $P/unstaged_logged_found)/\$(cat $P/unstaged_logged_prevented)/\$(cat $P/unstaged_logged_regressed)/\$(cat $P/dbg_iflush_pause_ino)/\$(cat $P/dbg_ail_pin_ino)/\$(cat $P/dbg_iflush_pause_ms)/\$(ls /sys/kernel/debug/mxfs/*/ail_push 2>/dev/null | wc -l)" | tail -1)
    [ "$got" = "$SKIP/1/0/0/0/0/0/$PAUSE/1" ] || { echo "RESULT: ABORT label=$LABEL -- $n's unstaged_logged_skip/dino_clobber_check/found/prevented/regressed/dbg_iflush_pause_ino/dbg_ail_pin_ino/dbg_iflush_pause_ms/ail_push read '$got', not $SKIP/1/0/0/0/0/0/$PAUSE/1 (is the build missing a knob, or debugfs its ail_push?) evidence=$OUT"; exit 2; }
done

D=/mnt/shared/usl.$LABEL
# The k<i> files first, then s1, s2 and f: three consecutive creates in one
# inode cluster (32 numbers) that holds neither D nor any k<i> (a read of a
# k<i> re-reads its own cluster: lap uslc1 had them in f's cluster, and every
# iteration's reads refreshed the buffer); every other create stays as a
# spacer.
SETUP=$(rs 60 "$X" "mkdir -p $D && cd $D || exit 2; di=\$(stat -c %i .); kc=\" \$((di >> 5)) \"
k=1; while [ \$k -le $KICKS ]; do : > k\$k || exit 2; kc=\"\$kc\$((\$(stat -c %i k\$k) >> 5)) \"; k=\$((k + 1)); done
i=0; p1=0; p2=0
while :; do
    i=\$((i + 1)); head -c 4096 /dev/urandom > c\$i || exit 2; ci=\$(stat -c %i c\$i)
    case \"\$kc\" in *\" \$((ci >> 5)) \"*) ;; *)
        if [ \$i -ge 3 ] && [ \$((p2 >> 5)) = \$((ci >> 5)) ] && [ \$((p1 >> 5)) = \$((ci >> 5)) ]; then break; fi ;;
    esac
    p2=\$p1; p1=\$ci; [ \$i -ge 200 ] && { echo setup_failed; exit 2; }
done
mv c\$((i - 2)) s1 && mv c\$((i - 1)) s2 && mv c\$i f || exit 2
sync; echo \"setup d=\$di s1=\$(stat -c %i s1) s2=\$(stat -c %i s2) f=\$(stat -c %i f) spacers=\$((i - 3)) kclusters=[\$kc]\"" | tail -1)
echo "$SETUP" > "$OUT/setup.txt"
case "$SETUP" in "setup d="*) ;; *) echo "RESULT: ABORT label=$LABEL stage=setup ($SETUP) evidence=$OUT"; exit 2 ;; esac
echo "  $SETUP"
F0=$(echo "$SETUP" | sed -n 's/.* f=\([0-9]*\) .*/\1/p')

S2=$(echo "$SETUP" | sed -n 's/.* s2=\([0-9]*\) .*/\1/p')
[ -n "$S2" ] || { echo "RESULT: ABORT label=$LABEL stage=setup (no s2 number in '$SETUP') evidence=$OUT"; exit 2; }

# The spacers the iterations unlink: in f's inode chunk (64 numbers, so in its
# AG) and outside C, one per iteration, held open by a process on X until the
# lap ends so that none of them is freed in front of N.
rs 20 "$X" "cd $D && for n in c*; do echo \$n \$(stat -c %i \$n); done" > "$OUT/spacers.txt"
SEL=$(awk -v f="$F0" 'NF == 2 && $2 ~ /^[0-9]+$/ && int($2 / 64) == int(f / 64) && int($2 / 32) != int(f / 32) { print $1 }' "$OUT/spacers.txt" | head -n "$ITERS" | tr '\n' ' ')
nsel=$(echo $SEL | wc -w)
[ "$nsel" -ge "$ITERS" ] || { echo "RESULT: ABORT label=$LABEL stage=setup -- $nsel spacers in f's chunk outside C ($OUT/spacers.txt), $ITERS iterations need one each evidence=$OUT"; exit 2; }
XHOLD='import os, sys, time
fds = [os.open(n, os.O_RDONLY) for n in sys.argv[2:]]
mark = sys.argv[1]
os.close(os.open(mark + ".held", os.O_CREAT | os.O_WRONLY, 0o644))
while not os.path.exists(mark):
    time.sleep(0.05)
for fd in fds:
    os.close(fd)
os.unlink(mark + ".held")'
XH=/tmp/usl_x.$LABEL
xh=$(rs 20 "$X" "cd $D || exit 2; rm -f $XH $XH.held
nohup setsid python3 -c '$XHOLD' $XH $SEL > /dev/null 2>&1 < /dev/null &
i=0; while [ ! -e $XH.held ] && [ \$i -lt 100 ]; do sleep 0.05; i=\$((i + 1)); done
[ -e $XH.held ] && echo xhold_ok" | tail -1)
xhold_end() {
    rs 20 "$X" "touch $XH; i=0; while [ -e $XH.held ] && [ \$i -lt 100 ]; do sleep 0.05; i=\$((i + 1)); done; [ -e $XH.held ] && echo xhold_stuck; rm -f $XH" | tail -1
}
[ "$xh" = xhold_ok ] || { xhold_end > /dev/null; echo "RESULT: ABORT label=$LABEL stage=setup -- X's spacer holder did not start ('$xh') evidence=$OUT"; exit 2; }
echo "  spacers held on $X: $SEL"

# The iterations, driven from here one ssh step at a time: no signal file on
# the shared filesystem, so no lock traffic but the shape's own.  Y's holder
# opens f, marks /tmp/usl_c.<label>.held, and closes when /tmp/usl_c.<label>
# appears, removing the mark.
HOLD='import os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
mark = sys.argv[2] + sys.argv[3]
os.close(os.open(mark, os.O_CREAT | os.O_WRONLY, 0o644))
while not os.path.exists(sys.argv[2]):
    time.sleep(0.02)
os.close(fd)
os.unlink(mark)'
C=/tmp/usl_c.$LABEL
reuse=0; ok=0; fired=0; released=0; prevf=$F0
for k in $(seq 1 "$ITERS"); do
    SPC=$(echo $SEL | cut -d' ' -f"$k")
    REL="P975-TENURE-END-EVICT ino=$prevf why=reclaim"
    y1=$(rs 20 "$Y" "cd $D || exit 2; rm -f $C $C.held
nohup setsid python3 -c '$HOLD' f $C .held > /dev/null 2>&1 < /dev/null &
i=0; while [ ! -e $C.held ] && [ \$i -lt 100 ]; do sleep 0.05; i=\$((i + 1)); done
[ -e $C.held ] || { echo yhold_failed; exit 2; }
rm f && sync && echo yok1" | tail -1)
    x2=$(rs 20 "$X" "cd / && echo 2 > /proc/sys/vm/drop_caches && cd $D && touch s2 && echo xok2" | tail -1)
    y3=$(rs 30 "$Y" "touch $C; i=0; while [ -e $C.held ] && [ \$i -lt 100 ]; do sleep 0.05; i=\$((i + 1)); done
[ -e $C.held ] && { echo yclose_failed; exit 2; }
sync && echo 1 > /sys/kernel/debug/mxfs/*/ail_push && sleep 0.5 && sync && rm -f $C || exit 2
r0=\$(dmesg | grep -c '$REL'); echo 2 > /proc/sys/vm/drop_caches
i=0; while [ \$(dmesg | grep -c '$REL') -le \$r0 ] && [ \$i -lt 40 ]; do sleep 0.05; i=\$((i + 1)); done
echo \"yok3 released=\$(( \$(dmesg | grep -c '$REL') - r0 ))\"" | tail -1)
    x4=$(rs 40 "$X" "cd $D || exit 2
u0=\$(date +%s%N); rm $SPC; rrc=\$?; u1=\$(date +%s%N)
echo $prevf > $P/dbg_ail_pin_ino; echo 0 > $P/dbg_iflush_pause_n; echo $S2 > $P/dbg_iflush_pause_ino
touch s2 && sync s2 && echo 1 > /sys/kernel/debug/mxfs/*/ail_push
i=0; while [ \$(cat $P/dbg_iflush_pause_n) -lt 1 ] && [ \$i -lt 40 ]; do sleep 0.05; i=\$((i + 1)); done
pn=\$(cat $P/dbg_iflush_pause_n)
t0=\$(date +%s%N); head -c 4096 /dev/urandom > f; crc=\$?; t1=\$(date +%s%N)
fi=\$(stat -c %i f 2>/dev/null)
echo 0 > $P/dbg_iflush_pause_ino; echo 0 > $P/dbg_ail_pin_ino
sync; echo \"xok4 f=\$fi pause_n=\$pn wait_rounds=\$i create_rc=\$crc create_ms=\$(( (t1 - t0) / 1000000 )) spacer=$SPC rm_rc=\$rrc rm_ms=\$(( (u1 - u0) / 1000000 ))\"" | tail -1)
    fi=$(echo "$x4" | sed -n 's/^xok4 f=\([0-9]*\) .*/\1/p')
    pn=$(echo "$x4" | sed -n 's/.* pause_n=\([0-9]*\) .*/\1/p')
    rrc=$(echo "$x4" | sed -n 's/.* rm_rc=\([0-9]*\) .*/\1/p')
    yr=$(echo "$y3" | sed -n 's/^yok3 released=\([0-9]*\)$/\1/p')
    r=0; [ -n "$fi" ] && [ "$fi" = "$prevf" ] && { r=1; reuse=$((reuse + 1)); }
    same=0; [ -n "$fi" ] && [ $((fi / 64)) = $((prevf / 64)) ] && same=1
    [ "${pn:-0}" -ge 1 ] && fired=$((fired + 1))
    [ "${yr:-0}" -ge 1 ] && released=$((released + 1))
    echo "iter $k n=$prevf y1=${y1:-none} x2=${x2:-none} y3=${y3:-none} x4=${x4:-none} reused=$r same_chunk=$same" >> "$OUT/iters.txt"
    [ "$y1" = yok1 ] && [ "$x2" = xok2 ] && [ -n "$yr" ] && [ -n "$fi" ] && [ "$rrc" = 0 ] || { echo "  iter $k failed: y1='$y1' x2='$x2' y3='$y3' x4='$x4'"; break; }
    ok=$((ok + 1)); prevf=$fi
done
rs 20 "$Y" "touch $C" > /dev/null
xe=$(xhold_end); [ -n "$xe" ] && echo "WARN X's spacer holder: $xe"
echo "  iterations ok=$ok of $ITERS reused=$reuse released=$released pause_fired=$fired ($OUT/iters.txt)"

declare -A cnt=() nfail=()
for n in $NODES; do
    cnt[$n]=$(rs 20 "$n" "cd $P && for c in $CNTS; do printf '%s=%s ' \$c \"\$(cat \$c 2>/dev/null || echo ?)\"; done; echo mounted=\$(grep -c ' /mnt/shared mxfs ' /proc/mounts)" | tail -1)
    echo "${cnt[$n]}" > "$OUT/${n}_counters.txt"
    echo "$n counters: ${cnt[$n]}"
    got=$(rs 20 "$n" "echo 1 > $P/unstaged_logged_skip; echo 0 > $P/dino_clobber_check; echo 0 > $P/dbg_iflush_pause_ino; echo 0 > $P/dbg_ail_pin_ino; echo \$(cat $P/unstaged_logged_skip)/\$(cat $P/dino_clobber_check)/\$(cat $P/dbg_iflush_pause_ino)/\$(cat $P/dbg_ail_pin_ino)" | tail -1)
    [ "$got" = 1/0/0/0 ] || echo "WARN $n's unstaged_logged_skip/dino_clobber_check/dbg_iflush_pause_ino/dbg_ail_pin_ino read '$got' after the reset, not 1/0/0/0"
done
cget() { printf '%s\n' "${cnt[$1]}" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

# Each node's whole kernel log after the mark: the prep starts `dmesg --follow`
# into /root/dmesg.stream on every node and the next lap's prep replaces it.
regl=0
for n in $NODES; do
    timeout 120 "$SSH" "$n" "gzip -c /root/dmesg.stream" < /dev/null 2>/dev/null > "$OUT/${n}_dmesg_stream.gz"
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" > "$OUT/${n}_lap.txt"
    echo "$n kernel log: $OUT/${n}_dmesg_stream.gz marks=$(grep -acF -- "$MARK" "$OUT/${n}_lap.txt") lines_after_mark=$(wc -l < "$OUT/${n}_lap.txt")"
    grep -a 'Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|P-INODE-WEDGE \|P-SESSION-POISON\|BUG:\|Oops\|blocked for more than' "$OUT/${n}_lap.txt" > "$OUT/${n}_failures.txt"
    sds=$(wc -l < "$OUT/${n}_failures.txt")
    echo "$n stream failure lines: $sds ($OUT/${n}_failures.txt)"
    head -3 "$OUT/${n}_failures.txt" | cut -c1-300
    mnt=$(cget "$n" mounted)
    [ "$sds" = 0 ] && [ "${mnt:-0}" = 1 ] || nfail[$n]=1
    grep -a 'P-UB1-UNSTAGED-SKIP \|P-DINO-CLOBBER' "$OUT/${n}_lap.txt" > "$OUT/${n}_ub1.txt"
    rn=$(grep -ac 'P-DINO-CLOBBER#[0-9]* .* regress=[1-9]' "$OUT/${n}_ub1.txt")
    echo "$n ub1 lines: $(grep -ac 'P-UB1-UNSTAGED-SKIP ' "$OUT/${n}_ub1.txt") (masked=1: $(grep -ac 'P-UB1-UNSTAGED-SKIP .* masked=1 ' "$OUT/${n}_ub1.txt")) clobber regress lines: $rn ($OUT/${n}_ub1.txt)"
    grep -a 'P-UB1-UNSTAGED-SKIP ' "$OUT/${n}_ub1.txt" | head -2 | cut -c1-330
    regl=$((regl + rn))
done
# Reach: X's P-UB1 lines that name a number an iteration's create reused (the
# setup's own creates print P-UB1 lines for spacers, which measure nothing).
reach=$(python3 - "$OUT/${X}_ub1.txt" "$OUT/iters.txt" <<'PY'
import re, sys
nums = set()
for l in open(sys.argv[2]):
    m = re.search(r" n=(\d+) .* reused=1", l)
    if m:
        nums.add(m.group(1))
n = 0
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"P-UB1-UNSTAGED-SKIP .* ino=(\d+) ", l)
    if m and m.group(1) in nums:
        n += 1
print(n)
PY
)
echo "$X P-UB1 lines naming a reused iteration number: $reach"

since=$(date -u +%FT%TZ)
./run.sh "$CONFIG" --group "$GROUP" chk_clean > "$OUT/chk.log" 2>&1
audit=$(python3 - data/criteria.json "$CONFIG" "$since" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
for e in d["criteria"]:
    if e.get("id") == "chk_clean":
        cell = (e.get("per_config") or {}).get(sys.argv[2]) or {}
        if str(cell.get("iso", "")) < sys.argv[3]:
            print("STALE"); break
        m = re.search(r"verdict=([A-Z]+).*?errors=(\d+)", str(cell.get("measured", "")))
        print("%s errors=%s" % m.groups() if m else "NONE")
        break
else:
    print("NONE")
PY
)
echo "cold audit: $audit ($OUT/chk.log)"

bad=${#nfail[@]}
fnd=$(cget "$X" unstaged_logged_found); prv=$(cget "$X" unstaged_logged_prevented); rgr=$(cget "$X" unstaged_logged_regressed)
case "${fnd:-x}${prv:-x}${rgr:-x}" in *[!0-9]*) echo "RESULT: ABORT unstaged_slot_ab label=$LABEL -- $X's counters did not read (${cnt[$X]}) evidence=$OUT"; exit 2 ;; esac
REP="skip=$SKIP iters=$ITERS ok=$ok reused=$reuse released=$released pause_fired=$fired reach=${reach:-?} found=$fnd prevented=$prv regressed=$rgr y_counters=[$(cget "$Y" unstaged_logged_found)/$(cget "$Y" unstaged_logged_prevented)/$(cget "$Y" unstaged_logged_regressed)] clobber_regress_lines=$regl node_failures=$bad audit=$audit"
case "${reach:-0}" in ''|0|*[!0-9]*)
    echo "RESULT: VACUOUS unstaged_slot_ab label=$LABEL $REP -- no never-staged logged slot of a reused iteration number rode a cluster write on $X evidence=$OUT"; exit 3 ;;
esac
if [ "$SKIP" = 0 ]; then
    if [ "$rgr" -gt 0 ]; then v=CONTROL-SHOWS-CAUSE; else v=CONTROL-NO-REGRESS; fi
    echo "RESULT: $v unstaged_slot_ab label=$LABEL $REP evidence=$OUT"; exit 0
fi
case "$audit" in CLEAN*errors=0) aok=1 ;; *) aok=0 ;; esac
if [ "$rgr" = 0 ] && [ "$regl" = 0 ] && [ "$bad" = 0 ] && [ "$aok" = 1 ]; then
    echo "RESULT: PASS unstaged_slot_ab label=$LABEL $REP evidence=$OUT"; exit 0
fi
echo "RESULT: FAIL unstaged_slot_ab label=$LABEL $REP evidence=$OUT"; exit 1
