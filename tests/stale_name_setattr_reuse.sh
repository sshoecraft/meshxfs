#!/bin/bash
# tests/stale_name_setattr_reuse.sh — does a timestamp setattr through a name
# resolved before a peer's rm land on the NEXT file that reuses the inode
# number?
#
# Locally the answer is no by construction: the setattr's task holds a
# reference on the inode it resolved, so an rm on the same machine leaves that
# inode allocated (orphaned) until the setattr ends, and no new file can be
# given its number in between.  Across nodes nothing holds the number: a peer's
# rm frees it as soon as its own last reference goes, and the peer may create a
# new file in it at once.  When the setattr then takes the number's lock, the
# reload finds another incarnation on the platter (P103-RELOAD-REUSE-ADOPT);
# if it adopts that incarnation and the setattr proceeds, the new file's times
# are changed by an operation on a name that never referred to it.
#
# Seen with the free image (no reuse) in tests/noino_release_reuse_ab.sh lap
# nrx1: in 8 of 8 iterations Y's `touch -c f`, held by
# dbg_setattr_time_delay_ms between its lookup and its lock while X removed f
# and freed its number, returned 0 after adopting X's free image
# (P116-ZOMBIE-ADOPT, P-FREE-ADOPT-CORE comm=touch) and its times went home on
# the free core (cc 11 -> 12).  This harness asks the same question with the
# number reused before the setattr wakes.
#
# PER ITERATION k, X = the group's first node, Y = its second, in X's
# directory D:
#   X creates f and syncs;
#   Y stats f, sets dbg_setattr_time_delay_ms and starts `touch -c -m -d
#     <STAMP> f` (STAMP a date no file of the lap otherwise carries): the touch
#     resolves the name, then waits that long before taking any lock;
#   X removes f and syncs (its free lands), creates g<k>, writes 4 KiB into it
#     and syncs, and reads g<k>'s number and mtime;
#   Y's touch wakes, takes the number's EX and returns; Y syncs and pushes its
#     AIL, then drops its caches so its copy of the number goes;
#   X reads g<k>'s mtime again, through a cache drop so the reload reads the
#     platter.
# Each iteration's g<k> is new and none is removed: the allocator places a new
# inode at the free number nearest its parent, which is f's.  (Removing the
# previous g at the start of the iteration, as the first version did, left that
# number free-but-not-yet-landed when f was created, so f took the next number
# and every later g reused the old g's: snr1 reused f's number once in six.)
# An iteration counts as REUSED when g<k> got f's number, and as HIT when
# g<k>'s mtime after Y's touch reads STAMP.
#
# THE ARM (D-STALE-NAME-SETATTR's same-build A/B): SNR_POISON sets the
# module's incarn_poison_unexposed on every node, read back before the first
# iteration.  0 = control (an unexposed shell is rebuilt in place from the
# other incarnation), 1 = the fix (it is poisoned; the setattr refuses -ESTALE
# at its post-lock gate, the VFS re-walks and the removed name gives ENOENT,
# which touch -c ignores).  Unset: the build's default, read back and printed.
#
# GRADES, written before the first lap of the A/B:
#   ABORT    prep, srcversion, a knob read-back or a step failed.
#   VACUOUS  no iteration reused the number: nothing measured.
#   control (arm 0):  CONTROL-SHOWS-CAUSE when an iteration HIT and Y's log
#            carries P-RELOAD-XINCARN-ADOPT comm=touch (the in-place rebuild
#            under the touch); CONTROL-NO-HIT otherwise.
#   fix (arm 1):  PASS when iterations reused the number, none HIT, Y's log
#            carries P-RELOAD-XINCARN-POISON comm=touch (the fix met the case)
#            and no node logged a failure; FAIL when an iteration HIT or a node
#            logged a failure; NOREACH when it reused the number without ever
#            poisoning under the touch.
# The cold audit is reported, not graded.
#
# THE LOCAL-CREATE SHAPE (SNR_SHAPE=localcreate): the same question when the
# file that reuses the number is created on Y itself, the node whose touch
# holds the removed name.  Y creates f (so f's number is in an AG Y allocates
# from), Y's touch resolves f and is held, X removes f, syncs, pushes its AIL
# and drops its caches (its reclaim releases the number's grant, which the
# freeing node otherwise keeps cached and Y's allocator skips), then Y creates
# g<k>, empty, while the touch is still held, and stats the removed name f.
# When Y's create takes f's number, its iget finds the copy the touch and f's
# dentry still reference (P-CR63, reset for the create).  REUSED as above; HIT
# when g<k>'s mtime after the touch reads STAMP (the touch through the removed
# name changed Y's own new file); NAMEHIT when Y's stat of f read g<k>'s
# number (the removed name resolves to the new file).  g<k> is created without
# a write: lap snl1 wrote 4 KiB into it, and that write waited behind the inode
# rwsem the held touch owned on the very struct the create had reset, then
# stamped the current time over the touch's STAMP -- its 3 reused iterations
# graded hit=0 while Y's log showed the touch's setattr logged against g<k>
# (P2G-LOGWHO comm=touch caller=xfs_setattr_nonsize): a masked negative.
# THE ARM for this shape (the same-build A/B of
# D-LOCAL-CREATE-RESETS-HELD-STALE-COPY-IN-PLACE-REMOVED-NAME-ACTS-ON-NEW-FILE):
# SNR_HELDSKIP sets dialloc_held_skip on every node, read back before the first
# iteration, when both nodes' dialloc_held_skipped and cr63_held_reset counters
# are also zeroed; they are read after the last iteration.  0 = control (the
# allocator hands out a number whose cached copy is referenced and P-CR63
# resets that copy), 1 = the fix (the allocator skips it, P-DIALLOC-HELD-SKIP).
# Unset: the build's default, read back, graded as that arm.  GRADES for this
# shape, written before the first lap of that A/B:
#   control (arm 0):  CONTROL-SHOWS-CAUSE when an iteration HIT or NAMEHIT and
#            Y's cr63_held_reset is above 0; CONTROL-NO-HIT otherwise; VACUOUS
#            when no iteration reused the number.
#   fix (arm 1):  PASS when no iteration HIT or NAMEHIT, Y's cr63_held_reset
#            is 0, Y logged P-DIALLOC-HELD-SKIP naming the f of at least one
#            iteration, and no node logged a failure; FAIL when an iteration HIT
#            or NAMEHIT, Y's cr63_held_reset is above 0, or a node logged a
#            failure; NOREACH when the allocator never skipped an f.
# An iteration whose stat of f read f's own number is counted (name_stale),
# not graded: the removed name resolving to its own dead life.
#
# Budgets (derived): prep and the cold audit are run.sh rows under their own
# manifest budgets.  An iteration is four ssh steps: X's create and sync,
# 20 s; Y's stat and the touch's start (~0.5 s), 20 s; X's rm, sync, create,
# write and sync (~2 s), 30 s; Y's wait for the touch (the hold, SNR_DELAY_MS,
# then an EX recall from X) and its sync, push and cache drop (~1.5 s past the
# hold), the hold plus 30 s; X's re-read through a cache drop, 20 s.
#
# Usage: tests/stale_name_setattr_reuse.sh <label> [iters=6] [config=2/disk/caw/direct] [group=g2]
# Env:   SNR_DELAY_MS (default 4000) how long Y's touch holds between its
#        lookup and its lock
#        SNR_POISON (0|1, default: the build's) incarn_poison_unexposed
#        SNR_SHAPE (peer|localcreate, default peer) who creates the file that
#        reuses the number
#        SNR_HELDSKIP (0|1, default: the build's) dialloc_held_skip, the
#        localcreate shape's arm (required there; read where present otherwise)
#        SNR_OP (touch|truncate|chmod|open, default touch) the operation Y
#        holds through f: `touch -c -m -d STAMP f` held by
#        dbg_setattr_time_delay_ms; a path truncate(2) of f to 1 byte and
#        `chmod 0600 f` held by the same delay with dbg_setattr_delay_any=1
#        (the delay at the setattr's entry, so the size path's own post-lock
#        refusal and the mode path's are exercised); `cat f` held by
#        dbg_open_delay_ms between its lookup and its protecting acquire.  HIT
#        for each: g<k>'s mtime reads STAMP / its size reads 1 / its mode reads
#        600 / Y's cat output has g<k>'s cksum (the removed name opened the new
#        file).  X writes g<k> 4 KiB of random bytes, so none of these holds
#        for g<k> otherwise.  The other operations run in the peer shape only.
#        The truncate is perl's truncate on the NAME (truncate(2), which the
#        VFS retries with LOOKUP_REVAL on ESTALE), exiting with the errno it
#        got (0 done, 2 ENOENT, 116 ESTALE reaching user space).  It was
#        `truncate -c -s 1 f` in laps sotr0 and sotr1, and both measured
#        nothing: truncate(1) opens the file and then ftruncates the fd, so Y
#        held an OPEN of f across the hold, X's rm deferred the free behind it
#        (P87-OPEN-DEFER ino=f on X in every iteration) and no g could take
#        the number (reused=0 in 16 of 16 iterations).
# Exit 0 PASS/CONTROL-SHOWS-CAUSE, 1 HIT/FAIL, 2 ABORT, 3 VACUOUS/NOREACH,
# 4 CONTROL-NO-HIT.
set -u
LABEL=${1:?label}; ITERS=${2:-6}
CONFIG=${3:-2/disk/caw/direct}; GROUP=${4:-g2}
DELAY=${SNR_DELAY_MS:-4000}
POISON=${SNR_POISON:-}
HELDSKIP=${SNR_HELDSKIP:-}
SHAPE=${SNR_SHAPE:-peer}
case "$SHAPE" in peer|localcreate) ;; *) echo "SNR_SHAPE must be peer or localcreate"; exit 2 ;; esac
case "$HELDSKIP" in ''|0|1) ;; *) echo "SNR_HELDSKIP must be 0 or 1"; exit 2 ;; esac
OP=${SNR_OP:-touch}
case "$OP" in touch|truncate|chmod|open) ;; *) echo "SNR_OP must be touch, truncate, chmod or open"; exit 2 ;; esac
[ "$OP" = touch ] || [ "$SHAPE" = peer ] || { echo "SNR_OP=$OP runs in the peer shape only"; exit 2; }
STAMP='2001-02-03 04:05:06 UTC'; STAMP_S=$(date -d "$STAMP" +%s)
for v in "$ITERS" "$DELAY"; do
    case "$v" in ''|*[!0-9]*) echo "iters and SNR_DELAY_MS must be whole numbers"; exit 2 ;; esac
done
case "$POISON" in ''|0|1) ;; *) echo "SNR_POISON must be 0 or 1"; exit 2 ;; esac
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
read -r X Y rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${X:-}" ] && [ -n "${Y:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
NODES=$(tools/mxfs_lab.sh group "$GROUP")
. tests/lib/runlock.sh
vmhold_take "stale_name_setattr_reuse $LABEL" $NODES \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold $NODES"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_stale_name_setattr_$LABEL
mkdir -p "$OUT"
MARK="STALE-NAME-SETATTR-$LABEL-$$"
P=/sys/module/mxfs/parameters
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
echo "=== stale_name_setattr_reuse label=$LABEL shape=$SHAPE iters=$ITERS delay_ms=$DELAY stamp='$STAMP' ($STAMP_S) $CONFIG $GROUP [$NODES] X=$X Y=$Y build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
want=$(modinfo -F srcversion mxfs.ko)
ARM=
for n in $NODES; do
    sv=$(rs 20 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT label=$LABEL -- $n runs '$sv', not the tree build $want evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "echo 0 > $P/dbg_setattr_time_delay_ms; echo $MARK > /dev/kmsg; cat $P/dbg_setattr_time_delay_ms" | tail -1)
    [ "$got" = 0 ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_setattr_time_delay_ms read '$got', not 0 evidence=$OUT"; exit 2; }
    if [ "${SNR_OP:-touch}" != touch ]; then
        z=$(rs 20 "$n" "echo 0 > $P/dbg_setattr_delay_any && echo 0 > $P/dbg_open_delay_ms && cat $P/dbg_setattr_delay_any $P/dbg_open_delay_ms" | tr '\n' ' ')
        [ "$z" = "0 0 " ] || { echo "RESULT: ABORT label=$LABEL -- $n's op delay knobs read '$z', not 0 0 evidence=$OUT"; exit 2; }
    fi
    if [ -n "$POISON" ]; then
        pv=$(rs 20 "$n" "echo $POISON > $P/incarn_poison_unexposed && cat $P/incarn_poison_unexposed" | tail -1)
    else
        pv=$(rs 20 "$n" "cat $P/incarn_poison_unexposed" | tail -1)
    fi
    case "$pv" in 0|1) ;; *) echo "RESULT: ABORT label=$LABEL -- $n's incarn_poison_unexposed read '$pv' evidence=$OUT"; exit 2 ;; esac
    [ -z "$POISON" ] || [ "$pv" = "$POISON" ] || { echo "RESULT: ABORT label=$LABEL -- $n's incarn_poison_unexposed read '$pv', not $POISON evidence=$OUT"; exit 2; }
    [ -z "$ARM" ] || [ "$ARM" = "$pv" ] || { echo "RESULT: ABORT label=$LABEL -- the nodes disagree on incarn_poison_unexposed evidence=$OUT"; exit 2; }
    ARM=$pv
    if [ -n "$HELDSKIP" ]; then
        hv=$(rs 20 "$n" "echo $HELDSKIP > $P/dialloc_held_skip && cat $P/dialloc_held_skip" | tail -1)
    else
        hv=$(rs 20 "$n" "cat $P/dialloc_held_skip 2>/dev/null" | tail -1)
    fi
    case "$hv" in
        0|1) zc=$(rs 20 "$n" "echo 0 > $P/dialloc_held_skipped && echo 0 > $P/cr63_held_reset && cat $P/dialloc_held_skipped $P/cr63_held_reset" | tr '\n' ' ')
             [ "$zc" = "0 0 " ] || { echo "RESULT: ABORT label=$LABEL -- $n's held-skip counters read '$zc' after zeroing evidence=$OUT"; exit 2; } ;;
        *) [ "$SHAPE" = peer ] || { echo "RESULT: ABORT label=$LABEL -- $n's dialloc_held_skip read '$hv' evidence=$OUT"; exit 2; }
           hv=none ;;
    esac
    [ -z "$HELDSKIP" ] || [ "$hv" = "$HELDSKIP" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dialloc_held_skip read '$hv', not $HELDSKIP evidence=$OUT"; exit 2; }
    [ -z "${HARM:-}" ] || [ "$HARM" = "$hv" ] || { echo "RESULT: ABORT label=$LABEL -- the nodes disagree on dialloc_held_skip evidence=$OUT"; exit 2; }
    HARM=$hv
    echo "  $n: srcversion=$sv incarn_poison_unexposed=$pv dialloc_held_skip=$hv"
done

D=/mnt/shared/snr.$LABEL
T=/tmp/snr_t.$LABEL
# the held operation: its command (run under sh -c on Y), its comm, and the
# knobs that hold it
case "$OP" in
    touch)    OPSH="touch -c -m -d \"$STAMP\" f"; OPCOMM=touch
              OPARM="echo $DELAY > $P/dbg_setattr_time_delay_ms" ;;
    truncate) OPSH="perl -e \"truncate(q(f), 1) or exit(0 + \\\$!)\""; OPCOMM=perl
              OPARM="echo 1 > $P/dbg_setattr_delay_any && echo $DELAY > $P/dbg_setattr_time_delay_ms" ;;
    chmod)    OPSH="chmod 0600 f"; OPCOMM=chmod
              OPARM="echo 1 > $P/dbg_setattr_delay_any && echo $DELAY > $P/dbg_setattr_time_delay_ms" ;;
    open)     OPSH="cat f > $T.out"; OPCOMM=cat
              OPARM="echo $DELAY > $P/dbg_open_delay_ms" ;;
esac
KOFF="echo 0 > $P/dbg_setattr_time_delay_ms; for k in dbg_setattr_delay_any dbg_open_delay_ms; do [ ! -e $P/\$k ] || echo 0 > $P/\$k; done"
TWAIT=$(( (DELAY / 1000 + 20) * 20 ))
reused=0; hit=0; ok=0; namehit=0; name_stale=0; fnums=""
rs 20 "$X" "mkdir -p $D && sync" > /dev/null
CF=$X; [ "$SHAPE" = peer ] || CF=$Y
for k in $(seq 1 "$ITERS"); do
    G=g$k
    x1=$(rs 20 "$CF" "cd $D || exit 2; head -c 4096 /dev/urandom > f && sync && echo \"xok1 f=\$(stat -c %i f)\"" | tail -1)
    fino=$(echo "$x1" | sed -n 's/^xok1 f=\([0-9]*\)$/\1/p')
    [ -n "$fino" ] || { echo "iter $k x1=${x1:-none}" >> "$OUT/iters.txt"; echo "  iter $k failed: x1='$x1'"; break; }
    y2=$(rs 20 "$Y" "cd $D || exit 2; rm -f $T.rc $T.out
stat f > /dev/null || { echo ystat_failed; exit 2; }
$OPARM || { echo yarm_failed; exit 2; }
nohup setsid sh -c '$OPSH; echo \$? > $T.rc' > /dev/null 2>&1 < /dev/null &
sleep 0.5; tw=none
for p in /proc/[0-9]*; do [ \"\$(cat \$p/comm 2>/dev/null)\" = $OPCOMM ] && tw=\$(cat \$p/wchan 2>/dev/null); done
[ -e $T.rc ] && { echo ytouch_early rc=\$(cat $T.rc); exit 2; }
echo \"yok2 touch_wchan=\$tw\"" | tail -1)
    case "$y2" in yok2*) ;; *) echo "iter $k f=$fino x1=$x1 y2=${y2:-none}" >> "$OUT/iters.txt"; echo "  iter $k failed: y2='$y2'"; break ;; esac
    if [ "$SHAPE" = peer ]; then
        x3=$(rs 30 "$X" "cd $D || exit 2
rm f && sync && echo 1 > /sys/kernel/debug/mxfs/*/ail_push && sleep 0.5 && sync || exit 2
head -c 4096 /dev/urandom > $G && sync || exit 2
echo \"xok3 g=\$(stat -c %i $G) cks=\$(cksum < $G | cut -d' ' -f1-2 | tr ' ' :) mtime=\$(stat -c %Y $G)\"" | tail -1)
    else
        x3r=$(rs 30 "$X" "cd $D || exit 2
rm f && sync && echo 1 > /sys/kernel/debug/mxfs/*/ail_push && sleep 0.5 && sync || exit 2
cd / && echo 2 > /proc/sys/vm/drop_caches && echo xok3r" | tail -1)
        [ "$x3r" = xok3r ] || { echo "iter $k f=$fino x1=$x1 y2=$y2 x3r=${x3r:-none}" >> "$OUT/iters.txt"; echo "  iter $k failed: x3r='$x3r'"; break; }
        x3=$(rs 30 "$Y" "cd $D || exit 2
: > $G && sync || exit 2
fn=\$(stat -c %i f 2>/dev/null) || fn=ENOENT
echo \"xok3 g=\$(stat -c %i $G) fname=\$fn mtime=\$(stat -c %Y $G)\"" | tail -1)
    fi
    gino=$(echo "$x3" | sed -n 's/^xok3 g=\([0-9]*\) .*/\1/p')
    m0=$(echo "$x3" | sed -n 's/.* mtime=\([0-9]*\)$/\1/p')
    fname=$(echo "$x3" | sed -n 's/.* fname=\([0-9A-Z]*\) .*/\1/p')
    [ -n "$gino" ] && [ -n "$m0" ] || { echo "iter $k f=$fino x1=$x1 y2=$y2 x3=${x3:-none}" >> "$OUT/iters.txt"; echo "  iter $k failed: x3='$x3'"; break; }
    [ "$SHAPE" = peer ] || [ -n "$fname" ] || { echo "iter $k f=$fino x1=$x1 y2=$y2 x3=$x3" >> "$OUT/iters.txt"; echo "  iter $k failed: no fname in x3='$x3'"; break; }
    y4=$(rs $(( DELAY / 1000 + 30 )) "$Y" "i=0; while [ ! -e $T.rc ] && [ \$i -lt $TWAIT ]; do sleep 0.05; i=\$((i + 1)); done
$KOFF
[ -e $T.rc ] || { echo ytouch_stuck; exit 2; }
trc=\$(cat $T.rc); rm -f $T.rc
ycks=none; [ ! -e $T.out ] || ycks=\$(cksum < $T.out | cut -d' ' -f1-2 | tr ' ' :); rm -f $T.out
sync && echo 1 > /sys/kernel/debug/mxfs/*/ail_push && sleep 0.5 && sync || exit 2
cd / && echo 2 > /proc/sys/vm/drop_caches
echo \"yok4 touch_rc=\$trc ycks=\$ycks\"" | tail -1)
    case "$y4" in yok4*) ;; *) echo "iter $k f=$fino x1=$x1 y2=$y2 x3=$x3 y4=${y4:-none}" >> "$OUT/iters.txt"; echo "  iter $k failed: y4='$y4'"; break ;; esac
    x5=$(rs 20 "$X" "cd / && echo 2 > /proc/sys/vm/drop_caches && cd $D && echo \"xok5 g=\$(stat -c %i $G) mode=\$(stat -c %a $G) size=\$(stat -c %s $G) mtime=\$(stat -c %Y $G)\"" | tail -1)
    m1=$(echo "$x5" | sed -n 's/.* mtime=\([0-9]*\)$/\1/p')
    a1=$(echo "$x5" | sed -n 's/.* mode=\([0-7]*\) .*/\1/p')
    s1=$(echo "$x5" | sed -n 's/.* size=\([0-9]*\) .*/\1/p')
    gcks=$(echo "$x3" | sed -n 's/.* cks=\([0-9:]*\) .*/\1/p')
    ycks=$(echo "$y4" | sed -n 's/.* ycks=\([0-9:a-z]*\)$/\1/p')
    r=0; [ "$gino" = "$fino" ] && { r=1; reused=$((reused + 1)); }
    h=0
    if [ "$r" = 1 ]; then
        case "$OP" in
            touch)    [ "${m1:-}" = "$STAMP_S" ] && h=1 ;;
            truncate) [ "${s1:-}" = 1 ] && h=1 ;;
            chmod)    [ "${a1:-}" = 600 ] && h=1 ;;
            open)     [ -n "${gcks:-}" ] && [ "${ycks:-}" = "$gcks" ] && h=1 ;;
        esac
    fi
    [ "$h" = 0 ] || hit=$((hit + 1))
    nh=0; [ "$r" = 1 ] && [ "${fname:-}" = "$gino" ] && { nh=1; namehit=$((namehit + 1)); }
    [ "$r" = 0 ] && [ "${fname:-}" = "$fino" ] && name_stale=$((name_stale + 1))
    fnums="$fnums $fino"
    echo "iter $k f=$fino x1=$x1 y2=$y2 x3=$x3 y4=$y4 x5=${x5:-none} reused=$r hit=$h namehit=$nh" >> "$OUT/iters.txt"
    [ -n "$m1" ] || { echo "  iter $k failed: x5='$x5'"; break; }
    ok=$((ok + 1))
done
rs 20 "$Y" "$KOFF; rm -f $T.rc $T.out" > /dev/null
echo "  iterations ok=$ok of $ITERS reused=$reused hit=$hit namehit=$namehit name_stale=$name_stale ($OUT/iters.txt)"
declare -A hs_cnt=() cr_cnt=()
if [ "$HARM" != none ]; then
    for n in $NODES; do
        c=$(rs 20 "$n" "cat $P/dialloc_held_skipped $P/cr63_held_reset" | tr '\n' ' ')
        read -r hs_cnt[$n] cr_cnt[$n] <<< "$c"
        echo "  $n: dialloc_held_skipped=${hs_cnt[$n]:-unread} cr63_held_reset=${cr_cnt[$n]:-unread}"
    done
fi

declare -A nfail=()
for n in $NODES; do
    timeout 120 "$SSH" "$n" "gzip -c /root/dmesg.stream" < /dev/null 2>/dev/null > "$OUT/${n}_dmesg_stream.gz"
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" > "$OUT/${n}_lap.txt"
    grep -a 'Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|P-INODE-WEDGE \|P-SESSION-POISON\|BUG:\|Oops\|blocked for more than' "$OUT/${n}_lap.txt" > "$OUT/${n}_failures.txt"
    sds=$(wc -l < "$OUT/${n}_failures.txt")
    [ "$sds" = 0 ] || nfail[$n]=1
    grep -a 'P103-RELOAD-REUSE-ADOPT \|P116-ZOMBIE-ADOPT \|P-FREE-ADOPT-CORE \|INCARN\|P240-QUAR-NSOP-REFUSE \|P-INACT-POISONED-SKIP \|P-CR63\|P-RESET-CLEARS-POISON \|P-REVOKE-REINCARNATED \|P-DIALLOC-HELD-SKIP ' "$OUT/${n}_lap.txt" > "$OUT/${n}_adopt.txt"
    echo "$n kernel log: lines_after_mark=$(wc -l < "$OUT/${n}_lap.txt") failure_lines=$sds reuse_adopt=$(grep -ac 'P103-RELOAD-REUSE-ADOPT ' "$OUT/${n}_adopt.txt") zombie_adopt=$(grep -ac 'P116-ZOMBIE-ADOPT ' "$OUT/${n}_adopt.txt") xincarn_adopt=$(grep -ac 'P-RELOAD-XINCARN-ADOPT ' "$OUT/${n}_adopt.txt") xincarn_poison=$(grep -ac 'P-RELOAD-XINCARN-POISON ' "$OUT/${n}_adopt.txt") locked_refuse=$(grep -ac 'P-INCARN-LOCKED-REFUSE ' "$OUT/${n}_adopt.txt") nsop_refuse=$(grep -ac 'P240-QUAR-NSOP-REFUSE ' "$OUT/${n}_adopt.txt") inact_skip=$(grep -ac 'P-INACT-POISONED-SKIP ' "$OUT/${n}_adopt.txt") cr63=$(grep -ac 'P-CR63' "$OUT/${n}_adopt.txt") cr63_held=$(grep -ac 'P-CR63-HELD ' "$OUT/${n}_adopt.txt") held_skip=$(grep -ac 'P-DIALLOC-HELD-SKIP ' "$OUT/${n}_adopt.txt") reset_clears=$(grep -ac 'P-RESET-CLEARS-POISON ' "$OUT/${n}_adopt.txt") ($OUT/${n}_adopt.txt)"
    grep -a 'P-RELOAD-XINCARN-ADOPT \|P-RELOAD-XINCARN-POISON ' "$OUT/${n}_adopt.txt" | head -3 | cut -c1-300
done
# the held operation runs on Y: its in-place rebuild (control) or its poison
# (fix); the touch_ names are kept for the touch-era readers, and count the
# held operation's comm whatever it is
y_adopt_touch=$(grep -a 'P-RELOAD-XINCARN-ADOPT ' "$OUT/${Y}_adopt.txt" | grep -ac " comm=$OPCOMM ")
y_poison_touch=$(grep -a 'P-RELOAD-XINCARN-POISON ' "$OUT/${Y}_adopt.txt" | grep -ac " comm=$OPCOMM ")
# iterations whose removed f the allocator on Y skipped as held (the fix met
# the case)
y_held_skip_f=0
for fi in $fnums; do
    grep -a 'P-DIALLOC-HELD-SKIP ' "$OUT/${Y}_adopt.txt" | grep -q " ino=$fi " && y_held_skip_f=$((y_held_skip_f + 1))
done
trc=$(grep -o 'touch_rc=[0-9]*' "$OUT/iters.txt" | sort | uniq -c | awk '{printf "%s%s:%s", (NR>1?",":""), $2, $1}')

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
REP="shape=$SHAPE op=$OP arm=$ARM heldskip=$HARM iters=$ITERS ok=$ok reused=$reused hit=$hit namehit=$namehit name_stale=$name_stale touch_rc=${trc:-none} y_adopt_touch=$y_adopt_touch y_poison_touch=$y_poison_touch y_held_skipped=${hs_cnt[$Y]:-none} y_cr63_held_reset=${cr_cnt[$Y]:-none} y_held_skip_f=$y_held_skip_f node_failures=${#nfail[@]} audit=$audit"
if [ "$SHAPE" = localcreate ]; then
    if [ "$HARM" = 0 ]; then
        [ "$reused" -gt 0 ] || { echo "RESULT: VACUOUS stale_name_setattr_reuse label=$LABEL $REP -- no iteration reused the number evidence=$OUT"; exit 3; }
        if [ $((hit + namehit)) -gt 0 ] && [ "${cr_cnt[$Y]:-0}" -gt 0 ]; then
            echo "RESULT: CONTROL-SHOWS-CAUSE stale_name_setattr_reuse label=$LABEL $REP -- a create on this node reset the cached copy a holder of the removed name still referenced, and the holder's setattr or the name reached the new file evidence=$OUT"; exit 0
        fi
        echo "RESULT: CONTROL-NO-HIT stale_name_setattr_reuse label=$LABEL $REP evidence=$OUT"; exit 4
    fi
    [ $((hit + namehit)) -gt 0 ] && { echo "RESULT: FAIL stale_name_setattr_reuse label=$LABEL $REP -- a setattr or a lookup through the removed name reached the file this node created on its number evidence=$OUT"; exit 1; }
    [ "${cr_cnt[$Y]:-unread}" = 0 ] || { echo "RESULT: FAIL stale_name_setattr_reuse label=$LABEL $REP -- a create reset a cached copy something else referenced (or the counter was unread) evidence=$OUT"; exit 1; }
    [ "${#nfail[@]}" -gt 0 ] && { echo "RESULT: FAIL stale_name_setattr_reuse label=$LABEL $REP -- a node logged a failure evidence=$OUT"; exit 1; }
    [ "$y_held_skip_f" -gt 0 ] || { echo "RESULT: NOREACH stale_name_setattr_reuse label=$LABEL $REP -- the allocator never skipped a removed f's number evidence=$OUT"; exit 3; }
    echo "RESULT: PASS stale_name_setattr_reuse label=$LABEL $REP evidence=$OUT"; exit 0
fi
[ "$reused" -gt 0 ] || { echo "RESULT: VACUOUS stale_name_setattr_reuse label=$LABEL $REP -- no iteration reused the number evidence=$OUT"; exit 3; }
if [ "$ARM" = 0 ]; then
    if [ "$hit" -gt 0 ] && [ "$y_adopt_touch" -gt 0 ]; then
        echo "RESULT: CONTROL-SHOWS-CAUSE stale_name_setattr_reuse label=$LABEL $REP -- a setattr through a removed name changed the file that reused its number, after its acquire rebuilt the shell in place evidence=$OUT"; exit 0
    fi
    echo "RESULT: CONTROL-NO-HIT stale_name_setattr_reuse label=$LABEL $REP evidence=$OUT"; exit 4
fi
[ "$hit" -gt 0 ] && { echo "RESULT: FAIL stale_name_setattr_reuse label=$LABEL $REP -- a setattr through a removed name changed the file that reused its number evidence=$OUT"; exit 1; }
[ "${#nfail[@]}" -gt 0 ] && { echo "RESULT: FAIL stale_name_setattr_reuse label=$LABEL $REP -- a node logged a failure evidence=$OUT"; exit 1; }
[ "$y_poison_touch" -gt 0 ] || { echo "RESULT: NOREACH stale_name_setattr_reuse label=$LABEL $REP -- the number was reused but no poison under the held $OP evidence=$OUT"; exit 3; }
echo "RESULT: PASS stale_name_setattr_reuse label=$LABEL $REP evidence=$OUT"; exit 0
