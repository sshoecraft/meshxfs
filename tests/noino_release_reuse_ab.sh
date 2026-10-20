#!/bin/bash
# tests/noino_release_reuse_ab.sh — same-build A/B of the no-inode release
# mark (module knob noino_release_mark_honor) on a directed workload, for
# D-INODE-CLUSTER-PUBLISH-WITHOUT-AUTHORITY shape (d), hypothesis H-NR1.
#
# H-NR1 (the record, session 96): a no-inode release that unlocks a grant an
# in-core corpse of the number still caches leaves the corpse's tenure epoch
# unchanged; when the next use of the corpse is a create, the allocator's
# reservation re-takes the grant before xfs_iget recycles the corpse, so
# mxfs_dlm_recycle_grant_check (xfs/xfs_mxfs_dir_data.c) finds the DLM's mode
# no lower than the cached one and keeps the tenure.  The previous life's
# staged image in this node's cluster buffer then reads as staged under the
# live tenure, so no dead-tenure mask and not H-UB1 applies, and a write of
# another slot of the cluster publishes it over whatever the peer wrote during
# its tenure (fw3c3: test2 put its own free image, cc 1170, back over test1's
# cc 1171 of the same free incarnation).  The fix: the release marks the
# corpse; with noino_release_mark_honor=1 the recycle that finds the mark ends
# the tenure (the epoch moves, i_dlm_stale is set).
# PREDICTION IF TRUE: with honor 0, X's partial write of the cluster carries
# the corpse's bytes over the peer's newer image: logwr_relmark_regressed > 0
# and a P-DINO-CLOBBER regress on that slot; with honor 1 no slot copied in
# before a marked recycle is written (no P-LOGWR-RELMARK-WRITTEN staged=1),
# nothing regresses, and the audit is CLEAN.
#
# THE SHAPE, per iteration, X = the group's first node, Y = its second, in
# X's directory D, with s1, s2 and f three files of one inode cluster C that
# holds neither D nor anything else the lap touches, f being X's live file of
# the number N.  X holds background and shrinker reclaim off (dbg_reclaim_hold)
# for the iterations, so the in-core copy of each number it frees stays in core
# as a corpse until a lookup or create recycles it:
#   Y stats f (its dentry and in-core copy of N's current life) and starts
#     `touch -c f` with dbg_setattr_time_delay_ms set: the touch resolves the
#     name, then waits that long before taking any lock (fw3c3's lookup loop
#     raced a peer's rm the same way, with no hold);
#   X removes f and syncs: as unlinker and last closer it frees N, its free
#     image lands, and its corpse of N stays RECLAIMABLE caching the EX the
#     free ran under;
#   Y's touch wakes and asks for N's EX: X's corpse cannot be grabbed, so X's
#     BAST takes the no-inode path, which unlocks the grant with the corpse
#     still caching EX (P-NOINO-UNLOCK-LEFT-GRANT lifecycle=RECLAIMABLE) and
#     marks it; Y's acquire reloads, adopts X's free image (P116-ZOMBIE-ADOPT,
#     P-FREE-ADOPT-CORE) and its setattr sets the times on that free core;
#   X pins s1 (dbg_ail_pin_ino=s1, which xfsaild and every cluster flush skip)
#     and touches it: C is read with N's slot still X's free image (Y's change
#     is still in Y's log), and s1's dirty log item holds C's buffer from here
#     to the create.  With no holder nothing references C once X's free of N
#     has landed, and X's create reads C again from the platter: in lap nrx3 X
#     read C at the recycle (buf_io R) and its write carried Y's image back
#     unchanged (slot 2 0:1049:12 over Y's cc 12, relmark_regressed=0 in 8 of
#     8 shaped iterations).  The pin waits for the release: a no-inode release
#     unlocks only once everything its node committed before it is on the
#     platter (mxfs_noino_drain_fence), so in lap nrx4, with s1 pinned before
#     Y's touch woke, X's fence could never finish and X shut itself down
#     (xfs_mxfs_noino.c:1127, its designed fail-closed arm);
#   Y syncs and pushes its AIL (the newer image of the free incarnation
#     lands) and drops its caches: its reclaim of the shell releases N
#     (P975-TENURE-END-EVICT why=reclaim; the harness waits up to 2 s);
#   X unlinks one spacer of N's inode chunk outside C that a holder process on
#     X keeps open (its AGI read takes N's AG with a blocking acquire) and,
#     with s1 still pinned, creates f: the allocator hands back N, its
#     reservation takes N's EX again, xfs_iget recycles the corpse
#     (P-RECYCLE-RELEASED-KEEP with honor 0, -RESET with 1), and the new life's
#     first log attaches it to C, still cached.  X then moves the pin to N
#     (xfsaild and the cluster flush skip the new life's own item, so it is
#     never copied in; s1 may flush again).  Only then does X touch s2, fsync
#     it and kick xfsaild through debugfs ail_push with
#     dbg_iflush_pause_ino=s2 (the pause counter tells the harness s2's flush
#     ran): the partial write of C for s2 carries N's slot, attached, with the
#     bytes the corpse's tenure staged.  The create must come first:
#     in lap nrx1 the flush of s2 ran before the create, the cluster merge
#     (mxfs_iflush_cluster_merge_dirs) found N's slot with nothing attached and
#     restored it from the platter (P-CLMERGE restored ... slot=2), and the
#     later write carried Y's image, not the corpse's (8 of 8 shaped
#     iterations, relmark_regressed=0).  Then X disarms and syncs, which lands
#     the new life's own image.
# Each iteration logs N, whether Y's touch was asleep in the hold when X's rm
# began and its exit code, whether Y adopted N's free image and released N,
# whether X's release of N left a marked grant and its create recycled a marked
# corpse, whether the create reused N and stayed in N's chunk, how long the
# spacer's unlink took, and whether the pause fired.
#
# THE GRADES
#   ABORT     prep, srcversion, knob read-back, setup or counter read failed
#   VACUOUS   no iteration in which Y adopted N's free image, X's no-inode
#             release of N left a marked grant, X recycled a marked corpse of
#             N and X's create reused N: the shape never formed
#   honor 0   CONTROL-SHOWS-CAUSE when X's logwr_relmark_regressed > 0;
#             CONTROL-NO-REGRESS otherwise
#   honor 1   PASS when X's logwr_relmark_regressed is 0, X logs no
#             P-LOGWR-RELMARK-WRITTEN line reading staged=1, neither node logs
#             a P-DINO-CLOBBER regress or a node failure, and the cold audit is
#             CLEAN errors=0; FAIL otherwise
#
# Budgets (derived): prep and the cold audit are run.sh rows under their own
# manifest budgets (run.sh flips an overrun to FAIL itself, so no outer
# timeout).  Setup: up to 200 creates and one sync, 60 s; the spacer list and
# X's holder 20 s each.  An iteration is six ssh steps: Y's stat and the
# touch's start (a coordinated lookup, ~0.5 s), 20 s; X's rm, sync, AIL push
# and sync (an EX recall from Y, ~2 s), 30 s; Y's wait for the touch (the
# hold, NRR_DELAY_MS, then an EX recall from X), the hold plus 40 s; X's pin
# and touch of s1 (one local transaction and C's read), 20 s; Y's sync, AIL
# push and cache drop and at most 2 s for the release line (~2.5 s), 40 s;
# X's spacer unlink (an AG recall, ~1 s), arming, fsync, kick, at
# most 2 s for the pause to fire, the create (held up to NRR_PAUSE_MS on C's
# lock), disarm and sync (~3 s past the pause), 40 s.  Counters and knob
# resets 20 s per node; the stream copy 120 s per node.
#
# Usage: tests/noino_release_reuse_ab.sh <label> <honor 0|1> [iters=8] [config=2/disk/caw/direct] [group=g2]
# Env:   NRR_DELAY_MS (default 4000) how long Y's touch holds between its
#        lookup and its lock; NRR_PAUSE_MS (default 1500) how long xfsaild
#        holds C
# Exit 0 PASS / CONTROL-*, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; HONOR=${2:?honor 0|1}; ITERS=${3:-8}
CONFIG=${4:-2/disk/caw/direct}; GROUP=${5:-g2}
DELAY=${NRR_DELAY_MS:-4000}; PAUSE=${NRR_PAUSE_MS:-1500}
case "$HONOR" in 0|1) ;; *) echo "honor must be 0 or 1"; exit 2 ;; esac
for v in "$ITERS" "$DELAY" "$PAUSE"; do
    case "$v" in ''|*[!0-9]*) echo "iters, NRR_DELAY_MS and NRR_PAUSE_MS must be whole numbers"; exit 2 ;; esac
done
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
read -r X Y rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${X:-}" ] && [ -n "${Y:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
NODES=$(tools/mxfs_lab.sh group "$GROUP")
# run.sh holds the nodes only while it runs; between its calls the workload
# below is invisible to tools/vm_pool.sh, whose idle sweep would shut them off
. tests/lib/runlock.sh
vmhold_take "noino_release_reuse_ab $LABEL" $NODES \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold $NODES"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_noino_release_reuse_$LABEL
mkdir -p "$OUT"
MARK="NOINO-RELEASE-REUSE-$LABEL-$$"
P=/sys/module/mxfs/parameters
# The iterations count probe lines in each node's `dmesg --follow` stream (the
# prep starts it into /root/dmesg.stream, flushed per record): one dmesg of the
# 16 MB ring costs 1.3 s on these nodes, and in lap nrx2 two of them before X's
# rm let Y's held touch wake first, so the shape never formed.
KL=/root/dmesg.stream
CNTS="noino_release_marked recycle_released_reset recycle_released_kept logwr_relmark_written logwr_relmark_regressed"
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
echo "=== noino_release_reuse_ab label=$LABEL honor=$HONOR iters=$ITERS delay_ms=$DELAY pause_ms=$PAUSE $CONFIG $GROUP [$NODES] X=$X Y=$Y build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
want=$(modinfo -F srcversion mxfs.ko)
for n in $NODES; do
    sv=$(rs 20 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT label=$LABEL -- $n runs '$sv', not the tree build $want evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "echo $HONOR > $P/noino_release_mark_honor; echo 1 > $P/dino_clobber_check; for c in $CNTS; do echo 0 > $P/\$c; done; echo 0 > $P/dbg_iflush_pause_ino; echo 0 > $P/dbg_ail_pin_ino; echo $PAUSE > $P/dbg_iflush_pause_ms; echo 0 > $P/dbg_reclaim_hold; echo 0 > $P/dbg_setattr_time_delay_ms; echo $MARK > /dev/kmsg; echo \$(cat $P/noino_release_mark_honor)/\$(cat $P/dino_clobber_check)/\$(for c in $CNTS; do printf %s \$(cat $P/\$c); done)/\$(cat $P/dbg_iflush_pause_ino)/\$(cat $P/dbg_ail_pin_ino)/\$(cat $P/dbg_iflush_pause_ms)/\$(cat $P/dbg_reclaim_hold)/\$(cat $P/dbg_setattr_time_delay_ms)/\$(ls /sys/kernel/debug/mxfs/*/ail_push 2>/dev/null | wc -l)" | tail -1)
    [ "$got" = "$HONOR/1/00000/0/0/$PAUSE/0/0/1" ] || { echo "RESULT: ABORT label=$LABEL -- $n's noino_release_mark_honor/dino_clobber_check/counters/dbg_iflush_pause_ino/dbg_ail_pin_ino/dbg_iflush_pause_ms/dbg_reclaim_hold/dbg_setattr_time_delay_ms/ail_push read '$got', not $HONOR/1/00000/0/0/$PAUSE/0/0/1 (is the build missing a knob, or debugfs its ail_push?) evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "i=0; while [ \"\$(grep -acF -- $MARK $KL)\" = 0 ] && [ \$i -lt 40 ]; do sleep 0.05; i=\$((i + 1)); done; grep -acF -- $MARK $KL" | tail -1)
    [ "$got" = 1 ] || { echo "RESULT: ABORT label=$LABEL -- $n's kernel-log stream $KL holds the lap mark '$got' times, not once (is the prep's dmesg --follow running?) evidence=$OUT"; exit 2; }
done

D=/mnt/shared/nrr.$LABEL
# s1, s2 and f: three consecutive creates in one inode cluster (32 numbers)
# that does not hold D; every earlier create stays as a spacer.
SETUP=$(rs 60 "$X" "mkdir -p $D && cd $D || exit 2; di=\$(stat -c %i .)
i=0; p1=0; p2=0
while :; do
    i=\$((i + 1)); head -c 4096 /dev/urandom > c\$i || exit 2; ci=\$(stat -c %i c\$i)
    if [ \$((di >> 5)) != \$((ci >> 5)) ] && [ \$i -ge 3 ] && [ \$((p2 >> 5)) = \$((ci >> 5)) ] && [ \$((p1 >> 5)) = \$((ci >> 5)) ]; then break; fi
    p2=\$p1; p1=\$ci; [ \$i -ge 200 ] && { echo setup_failed; exit 2; }
done
mv c\$((i - 2)) s1 && mv c\$((i - 1)) s2 && mv c\$i f || exit 2
sync; echo \"setup d=\$di s1=\$(stat -c %i s1) s2=\$(stat -c %i s2) f=\$(stat -c %i f) spacers=\$((i - 3))\"" | tail -1)
echo "$SETUP" > "$OUT/setup.txt"
case "$SETUP" in "setup d="*) ;; *) echo "RESULT: ABORT label=$LABEL stage=setup ($SETUP) evidence=$OUT"; exit 2 ;; esac
echo "  $SETUP"
F0=$(echo "$SETUP" | sed -n 's/.* f=\([0-9]*\) .*/\1/p')
S1=$(echo "$SETUP" | sed -n 's/.* s1=\([0-9]*\) .*/\1/p')
S2=$(echo "$SETUP" | sed -n 's/.* s2=\([0-9]*\) .*/\1/p')
[ -n "$F0" ] && [ -n "$S1" ] && [ -n "$S2" ] || { echo "RESULT: ABORT label=$LABEL stage=setup (no f, s1 or s2 number in '$SETUP') evidence=$OUT"; exit 2; }

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
XH=/tmp/nrr_x.$LABEL
xh=$(rs 20 "$X" "cd $D || exit 2; rm -f $XH $XH.held
nohup setsid python3 -c '$XHOLD' $XH $SEL > /dev/null 2>&1 < /dev/null &
i=0; while [ ! -e $XH.held ] && [ \$i -lt 100 ]; do sleep 0.05; i=\$((i + 1)); done
[ -e $XH.held ] && echo xhold_ok" | tail -1)
xhold_end() {
    rs 20 "$X" "touch $XH; i=0; while [ -e $XH.held ] && [ \$i -lt 100 ]; do sleep 0.05; i=\$((i + 1)); done; [ -e $XH.held ] && echo xhold_stuck; rm -f $XH" | tail -1
}
[ "$xh" = xhold_ok ] || { xhold_end > /dev/null; echo "RESULT: ABORT label=$LABEL stage=setup -- X's spacer holder did not start ('$xh') evidence=$OUT"; exit 2; }
echo "  spacers held on $X: $SEL"
got=$(rs 20 "$X" "echo 1 > $P/dbg_reclaim_hold; cat $P/dbg_reclaim_hold" | tail -1)
[ "$got" = 1 ] || { xhold_end > /dev/null; echo "RESULT: ABORT label=$LABEL -- $X's dbg_reclaim_hold read '$got', not 1 evidence=$OUT"; exit 2; }

# The iterations, driven from here one ssh step at a time: no signal file on
# the shared filesystem, so no lock traffic but the shape's own.  Y's touch
# runs detached and leaves its exit code in /tmp/nrr_t.<label>.rc; each node
# keeps the iteration's starting probe counts in /tmp/nrr_b.<label>.
T=/tmp/nrr_t.$LABEL; B=/tmp/nrr_b.$LABEL
TWAIT=$(( (DELAY / 1000 + 20) * 20 ))
reuse=0; ok=0; fired=0; released=0; adopted=0; leftmark=0; recycled=0; shaped=0; prevf=$F0; nums=""
for k in $(seq 1 "$ITERS"); do
    SPC=$(echo $SEL | cut -d' ' -f"$k")
    N=$prevf
    y1=$(rs 20 "$Y" "cd $D || exit 2; rm -f $T.rc
grep -ac 'P-FREE-ADOPT-CORE ino=$N ' $KL > $B
stat f > /dev/null || { echo ystat_failed; exit 2; }
echo $DELAY > $P/dbg_setattr_time_delay_ms
nohup setsid sh -c 'touch -c f; echo \$? > $T.rc' > /dev/null 2>&1 < /dev/null &
sleep 0.5; tw=none
for p in /proc/[0-9]*; do [ \"\$(cat \$p/comm 2>/dev/null)\" = touch ] && tw=\$(cat \$p/wchan 2>/dev/null); done
[ -e $T.rc ] && { echo ytouch_early rc=\$(cat $T.rc); exit 2; }
echo \"yok1 touch_wchan=\$tw\"" | tail -1)
    case "$y1" in yok1*) ;; *) echo "iter $k n=$N y1=${y1:-none}" >> "$OUT/iters.txt"; echo "  iter $k failed: y1='$y1'"; break ;; esac
    x2=$(rs 30 "$X" "cd $D || exit 2
echo \$(grep -ac 'P-NOINO-UNLOCK-LEFT-GRANT ino=$N ' $KL) \$(grep -ac 'P-RECYCLE-RELEASED-[A-Z]* ino=$N ' $KL) > $B
rm f && sync && echo 1 > /sys/kernel/debug/mxfs/*/ail_push && sleep 0.5 && sync && echo xok2" | tail -1)
    [ "$x2" = xok2 ] || { echo "iter $k n=$N y1=$y1 x2=${x2:-none}" >> "$OUT/iters.txt"; echo "  iter $k failed: y1='$y1' x2='$x2'"; break; }
    y3=$(rs $(( DELAY / 1000 + 40 )) "$Y" "i=0; while [ ! -e $T.rc ] && [ \$i -lt $TWAIT ]; do sleep 0.05; i=\$((i + 1)); done
echo 0 > $P/dbg_setattr_time_delay_ms
[ -e $T.rc ] || { echo ytouch_stuck; exit 2; }
echo \"yok3 touch_rc=\$(cat $T.rc)\"; rm -f $T.rc" | tail -1)
    case "$y3" in yok3*) ;; *) echo "iter $k n=$N y1=$y1 x2=$x2 y3=${y3:-none}" >> "$OUT/iters.txt"; echo "  iter $k failed: y1='$y1' x2='$x2' y3='$y3'"; break ;; esac
    # X's no-inode release of N is over (Y's touch has its grant), and Y's
    # change of N is still in Y's log: X takes C now, holding it from here
    x3=$(rs 20 "$X" "cd $D || exit 2
echo $S1 > $P/dbg_ail_pin_ino && touch s1 && echo xok3" | tail -1)
    [ "$x3" = xok3 ] || { echo "iter $k n=$N y1=$y1 x2=$x2 y3=$y3 x3=${x3:-none}" >> "$OUT/iters.txt"; echo "  iter $k failed: y1='$y1' x2='$x2' y3='$y3' x3='$x3'"; break; }
    y5=$(rs 40 "$Y" "sync && echo 1 > /sys/kernel/debug/mxfs/*/ail_push && sleep 0.5 && sync || exit 2
a=\$(( \$(grep -ac 'P-FREE-ADOPT-CORE ino=$N ' $KL) - \$(cat $B) ))
r0=\$(grep -ac 'P975-TENURE-END-EVICT ino=$N why=reclaim' $KL); cd / && echo 2 > /proc/sys/vm/drop_caches
i=0; while [ \$(grep -ac 'P975-TENURE-END-EVICT ino=$N why=reclaim' $KL) -le \$r0 ] && [ \$i -lt 40 ]; do sleep 0.05; i=\$((i + 1)); done
echo \"yok5 adopt=\$a released=\$(( \$(grep -ac 'P975-TENURE-END-EVICT ino=$N why=reclaim' $KL) - r0 ))\"" | tail -1)
    case "$y5" in yok5*) ;; *) echo "iter $k n=$N y1=$y1 x2=$x2 y3=$y3 x3=$x3 y5=${y5:-none}" >> "$OUT/iters.txt"; echo "  iter $k failed: y1='$y1' x2='$x2' y3='$y3' x3='$x3' y5='$y5'"; break ;; esac
    x4=$(rs 40 "$X" "cd $D || exit 2
read nl0 rr0 < $B
u0=\$(date +%s%N); rm $SPC; rrc=\$?; u1=\$(date +%s%N)
t0=\$(date +%s%N); head -c 4096 /dev/urandom > f; crc=\$?; t1=\$(date +%s%N)
echo $N > $P/dbg_ail_pin_ino
fi=\$(stat -c %i f 2>/dev/null)
echo 0 > $P/dbg_iflush_pause_n; echo $S2 > $P/dbg_iflush_pause_ino
touch s2 && sync s2 && echo 1 > /sys/kernel/debug/mxfs/*/ail_push
i=0; while [ \$(cat $P/dbg_iflush_pause_n) -lt 1 ] && [ \$i -lt 40 ]; do sleep 0.05; i=\$((i + 1)); done
pn=\$(cat $P/dbg_iflush_pause_n)
echo 0 > $P/dbg_iflush_pause_ino; echo 0 > $P/dbg_ail_pin_ino
sync
nl=\$(( \$(grep -ac 'P-NOINO-UNLOCK-LEFT-GRANT ino=$N ' $KL) - nl0 )); rr=\$(( \$(grep -ac 'P-RECYCLE-RELEASED-[A-Z]* ino=$N ' $KL) - rr0 ))
echo \"xok4 f=\$fi pause_n=\$pn wait_rounds=\$i create_rc=\$crc create_ms=\$(( (t1 - t0) / 1000000 )) left_grant=\$nl marked_recycle=\$rr spacer=$SPC rm_rc=\$rrc rm_ms=\$(( (u1 - u0) / 1000000 ))\"" | tail -1)
    fi=$(echo "$x4" | sed -n 's/^xok4 f=\([0-9]*\) .*/\1/p')
    pn=$(echo "$x4" | sed -n 's/.* pause_n=\([0-9]*\) .*/\1/p')
    rrc=$(echo "$x4" | sed -n 's/.* rm_rc=\([0-9]*\) .*/\1/p')
    nl=$(echo "$x4" | sed -n 's/.* left_grant=\([0-9]*\) .*/\1/p')
    rr=$(echo "$x4" | sed -n 's/.* marked_recycle=\([0-9]*\) .*/\1/p')
    trc=$(echo "$y3" | sed -n 's/^yok3 touch_rc=\([0-9]*\)$/\1/p')
    ya=$(echo "$y5" | sed -n 's/^yok5 adopt=\([0-9]*\) .*/\1/p')
    yr=$(echo "$y5" | sed -n 's/^yok5 .* released=\([0-9]*\)$/\1/p')
    r=0; [ -n "$fi" ] && [ "$fi" = "$N" ] && { r=1; reuse=$((reuse + 1)); }
    same=0; [ -n "$fi" ] && [ $((fi / 64)) = $((N / 64)) ] && same=1
    [ "${pn:-0}" -ge 1 ] && fired=$((fired + 1))
    [ "${yr:-0}" -ge 1 ] && released=$((released + 1))
    [ "${ya:-0}" -ge 1 ] && [ "$trc" = 0 ] && adopted=$((adopted + 1))
    [ "${nl:-0}" -ge 1 ] && leftmark=$((leftmark + 1))
    [ "${rr:-0}" -ge 1 ] && recycled=$((recycled + 1))
    # the shape: Y's touch adopted N's free image and set its times (rc 0), X's
    # release of N left a marked grant, X recycled a marked corpse of N, and
    # X's create took N
    sh=0; [ "$r" = 1 ] && [ "$trc" = 0 ] && [ "${ya:-0}" -ge 1 ] && [ "${nl:-0}" -ge 1 ] && [ "${rr:-0}" -ge 1 ] && { sh=1; shaped=$((shaped + 1)); nums="$nums $N"; }
    echo "iter $k n=$N y1=$y1 x2=$x2 y3=$y3 x3=$x3 y5=$y5 x4=${x4:-none} reused=$r same_chunk=$same shaped=$sh" >> "$OUT/iters.txt"
    [ -n "$yr" ] && [ -n "$fi" ] && [ "$rrc" = 0 ] || { echo "  iter $k failed: y1='$y1' x2='$x2' y3='$y3' x3='$x3' y5='$y5' x4='$x4'"; break; }
    ok=$((ok + 1)); prevf=$fi
done
rs 20 "$Y" "echo 0 > $P/dbg_setattr_time_delay_ms; rm -f $T.rc $B" > /dev/null
rs 20 "$X" "rm -f $B" > /dev/null
xe=$(xhold_end); [ -n "$xe" ] && echo "WARN X's spacer holder: $xe"
echo "  iterations ok=$ok of $ITERS reused=$reuse adopted=$adopted released=$released left_grant=$leftmark marked_recycle=$recycled pause_fired=$fired shaped=$shaped ($OUT/iters.txt)"

declare -A cnt=() nfail=()
for n in $NODES; do
    cnt[$n]=$(rs 20 "$n" "cd $P && for c in $CNTS; do printf '%s=%s ' \$c \"\$(cat \$c 2>/dev/null || echo ?)\"; done; echo dbg_reclaim_hold=\$(cat dbg_reclaim_hold) mounted=\$(grep -c ' /mnt/shared mxfs ' /proc/mounts)" | tail -1)
    echo "${cnt[$n]}" > "$OUT/${n}_counters.txt"
    echo "$n counters: ${cnt[$n]}"
    got=$(rs 20 "$n" "echo 1 > $P/noino_release_mark_honor; echo 0 > $P/dino_clobber_check; echo 0 > $P/dbg_iflush_pause_ino; echo 0 > $P/dbg_ail_pin_ino; echo 0 > $P/dbg_reclaim_hold; echo 0 > $P/dbg_setattr_time_delay_ms; echo \$(cat $P/noino_release_mark_honor)/\$(cat $P/dino_clobber_check)/\$(cat $P/dbg_iflush_pause_ino)/\$(cat $P/dbg_ail_pin_ino)/\$(cat $P/dbg_reclaim_hold)/\$(cat $P/dbg_setattr_time_delay_ms)" | tail -1)
    [ "$got" = 1/0/0/0/0/0 ] || echo "WARN $n's noino_release_mark_honor/dino_clobber_check/dbg_iflush_pause_ino/dbg_ail_pin_ino/dbg_reclaim_hold/dbg_setattr_time_delay_ms read '$got' after the reset, not 1/0/0/0/0/0"
done
cget() { printf '%s\n' "${cnt[$1]}" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
[ "$(cget "$X" dbg_reclaim_hold)" = 1 ] || echo "WARN $X's dbg_reclaim_hold read '$(cget "$X" dbg_reclaim_hold)' after the iterations, not 1"

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
    grep -a 'P-NOINO-UNLOCK-LEFT-GRANT \|P-RECYCLE-RELEASED-\|P-LOGWR-RELMARK-WRITTEN \|P-LOGWR-INCARN-MISMATCH \|P-DINO-CLOBBER\|P116-ZOMBIE-ADOPT \|P-FREE-ADOPT-CORE ' "$OUT/${n}_lap.txt" > "$OUT/${n}_nr1.txt"
    rn=$(grep -ac 'P-DINO-CLOBBER#[0-9]* .* regress=[1-9]' "$OUT/${n}_nr1.txt")
    echo "$n nr1 lines: left_grant=$(grep -ac 'P-NOINO-UNLOCK-LEFT-GRANT ' "$OUT/${n}_nr1.txt") keep=$(grep -ac 'P-RECYCLE-RELEASED-KEEP ' "$OUT/${n}_nr1.txt") reset=$(grep -ac 'P-RECYCLE-RELEASED-RESET ' "$OUT/${n}_nr1.txt") relmark_written=$(grep -ac 'P-LOGWR-RELMARK-WRITTEN ' "$OUT/${n}_nr1.txt") (staged=1: $(grep -ac 'P-LOGWR-RELMARK-WRITTEN .* staged=1 ' "$OUT/${n}_nr1.txt")) free_adopt=$(grep -ac 'P-FREE-ADOPT-CORE ' "$OUT/${n}_nr1.txt") clobber regress lines: $rn ($OUT/${n}_nr1.txt)"
    grep -a 'P-LOGWR-RELMARK-WRITTEN \|P-DINO-CLOBBER#[0-9]* .* regress=[1-9]' "$OUT/${n}_nr1.txt" | head -2 | cut -c1-330
    regl=$((regl + rn))
done
# Reach: X's P-LOGWR-RELMARK-WRITTEN lines that name a number of a shaped
# iteration (any other number's line is the background's, not the shape's).
reach=$(python3 - "$OUT/${X}_nr1.txt" $nums <<'PY'
import re, sys
nums = set(sys.argv[2:])
n = 0
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"P-LOGWR-RELMARK-WRITTEN .* ino=(\d+) ", l)
    if m and m.group(1) in nums:
        n += 1
print(n)
PY
)
staged1=$(grep -ac 'P-LOGWR-RELMARK-WRITTEN .* staged=1 ' "$OUT/${X}_nr1.txt")
echo "$X P-LOGWR-RELMARK-WRITTEN lines naming a shaped iteration's number: $reach (staged=1 lines, any number: $staged1)"

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
wrt=$(cget "$X" logwr_relmark_written); rgr=$(cget "$X" logwr_relmark_regressed)
mkd=$(cget "$X" noino_release_marked); rst=$(cget "$X" recycle_released_reset); kpt=$(cget "$X" recycle_released_kept)
case "${wrt:-x}${rgr:-x}${mkd:-x}${rst:-x}${kpt:-x}" in *[!0-9]*) echo "RESULT: ABORT noino_release_reuse_ab label=$LABEL -- $X's counters did not read (${cnt[$X]}) evidence=$OUT"; exit 2 ;; esac
REP="honor=$HONOR iters=$ITERS ok=$ok reused=$reuse adopted=$adopted released=$released left_grant=$leftmark marked_recycle=$recycled pause_fired=$fired shaped=$shaped reach=${reach:-?} marked=$mkd recycle_reset=$rst recycle_kept=$kpt relmark_written=$wrt relmark_regressed=$rgr staged1_lines=$staged1 clobber_regress_lines=$regl node_failures=$bad audit=$audit"
if [ "$shaped" = 0 ]; then
    echo "RESULT: VACUOUS noino_release_reuse_ab label=$LABEL $REP -- no iteration formed the shape (Y's adopt, X's marked release, X's marked recycle and X's reuse of the number) evidence=$OUT"; exit 3
fi
if [ "$HONOR" = 0 ]; then
    if [ "$rgr" -gt 0 ]; then v=CONTROL-SHOWS-CAUSE; else v=CONTROL-NO-REGRESS; fi
    echo "RESULT: $v noino_release_reuse_ab label=$LABEL $REP evidence=$OUT"; exit 0
fi
case "$audit" in CLEAN*errors=0) aok=1 ;; *) aok=0 ;; esac
if [ "$rgr" = 0 ] && [ "$staged1" = 0 ] && [ "$regl" = 0 ] && [ "$bad" = 0 ] && [ "$aok" = 1 ]; then
    echo "RESULT: PASS noino_release_reuse_ab label=$LABEL $REP evidence=$OUT"; exit 0
fi
echo "RESULT: FAIL noino_release_reuse_ab label=$LABEL $REP evidence=$OUT"; exit 1
