#!/bin/bash
# tests/noino_dirty_recycle_ab.sh — same-build A/B of the dirty-corpse recycle
# wait (module knob noino_recycle_dirty_wait), for
# D-RECYCLE-RESET-UNDER-NOINO-STRANDS-COMMITTED-DIR-CHANGE-WEDGE-SHUTDOWN.
#
# H-W1, written before this harness (fxdp2, test30, directory 16777345): when the
# recycle guard (H-F7, noino_recycle_guard) lowers a reclaimable corpse's cached
# grant to NL while a no-inode release of its number is in flight and the
# corpse still holds a committed change not on the platter, the aild's flush
# skips the corpse at NL (P119-NONEX-FLUSH-SKIP) and its log item completes and
# leaves the AIL unwritten; the release's drain fence then passes and the
# unlock hands the peer a home without the change.  The node is left with the
# change in core and no grant that may write it, and its next release of the
# directory can never be proven (P228-RELBAR-DEFER, then P-INODE-WEDGE).
# PREDICTION IF TRUE: with noino_recycle_dirty_wait=0 the peer's listing taken
#   when the release unlocks shows the name the owner renamed away, and the
#   owner logs P-RECYCLE-RESET-UNDER-NOINO owes=1 and P119-NONEX-FLUSH-SKIP for
#   the directory; with =1 the owner logs P-RECYCLE-DIRTY-WAIT, the peer never
#   sees the old name, and no reset of a dirty corpse is logged.
# IF FALSE: the control resets dirty corpses (owes=1) and the peer's listings
#   are fresh anyway.
#
# NDR_ARM=takeover: the same sequence A/Bs the take-over instead (module knob
# noino_recycle_takeover, the <knob> argument; noino_recycle_dirty_wait stays 1).
# H-W2: a recycle that cannot wait -- a caller whose transaction holds items --
# resets a dirty corpse's grant under a release registered before it began,
# with H-W1's result.  The test knob dbg_recycle_nowait makes step 4's lookup
# recycle as such a caller (dbg_recycle_nowait_hits counts it), since no
# workload puts one on a dirty corpse at will (a create never meets one: the
# allocator hands a number out only once its free is on the platter).
# PREDICTION IF TRUE: with noino_recycle_takeover=0 the owner logs
#   P-RECYCLE-RESET-UNDER-NOINO owes=1 at_start=1 and P119-NONEX-FLUSH-SKIP and
#   the peer's listing holds f0; with =1 it logs P-RECYCLE-DIRTY-TAKEOVER, no
#   reset of a dirty corpse, and the listing never holds f0.
# IF FALSE: the control's injected recycles reset dirty corpses and the
#   listings are fresh anyway.
#
# THE SEQUENCE, iteration k, in D=/mnt/shared/ndr.<label>:
#   1. B creates d<k> holding f0..f3 (B caches EX on it);
#   2. A names d<k> in dbg_ail_pin_ino, renames d<k>/f0 to d<k>/g0 (its EX
#      request makes B drain d<k> home first) and drops its caches at once:
#      d<k>'s inode goes reclaimable on A still owing the platter that
#      committed rename.  The pin is what keeps it owing: the cache drop's
#      AIL push (xfs_reclaim_inodes_nr -> xfs_ail_push_all) wakes xfsaild,
#      whose CIL flush (xfsaild_push, ail_log_flush) and push write a quiet
#      node's change within milliseconds -- 0.6-8 ms after the rename in
#      ndrc2, 4.5-62 ms after an unlink in ndrc1 -- while B's request arrives
#      ~400 ms later, so without it every recycle met a clean corpse (ndrc1,
#      ndrc2, ndrf2: owes=0 on all 14 reached iterations).  fxdp2's churn kept
#      the AIL busy enough to leave its 15 ms window; an idle node leaves none;
#   3. B lists d<k> (ls -f) in the background: its PR request BASTs A, whose
#      in-core lookup refuses the reclaimable corpse, so the no-inode release
#      registers, and dbg_noino_prefence_delay_ms holds it before its fence;
#   4. A waits for its noino_bast_reclaimable counter to move (the BAST is
#      served by that release), then stats d<k>/f1 in the background: the path
#      walk recycles the corpse inside the release.  As soon as a recycle
#      counter moves (recycle_reset_noino, recycle_dirty_waits,
#      recycle_dirty_kept or recycle_dirty_takeover; at most 1 s) A clears
#      dbg_ail_pin_ino, so the
#      release's fence, held NDR_PREFENCE_MS from the BAST, never meets the
#      pin: in the fix arm the waiting recycle and the fence would otherwise
#      wait on each other.
# B's listing returns when the release has unlocked.  An iteration is REACHED
# when A's counter moved in step 4; its listing is STALE when it holds f0.
# An iteration whose create or rename fails ends the loop (BROKE): in the
# control that is the predicted aftermath of a stale unlock (fxdp2's node shut
# down 60 s after it), so the lap is graded on the iterations it ran.
#
# THE GRADES
#   ABORT     prep, knob read-back or counter read failed, or the loop broke
#             before any iteration was reached
#   VACUOUS   the arm's reach counter is 0 on A: the control met no dirty corpse
#             under a tracked release (recycle_dirty_hazard + recycle_reset_dirty),
#             the fix waited for none (recycle_dirty_waits + recycle_dirty_kept);
#             in the take-over arm the fix took no release over
#             (recycle_dirty_takeover)
#   knob=0    the control: CONTROL-STALE when a reached iteration's listing held
#             f0, CONTROL-FRESH when none did
#   knob=1    PASS when every iteration ran, no listing held f0, no reset of a
#             dirty corpse the change covers was logged (owes=1 at_start=0; in
#             the take-over arm no owes=1 reset at all and recycle_reset_dirty
#             0), the cold audit is CLEAN, and neither node shut down, withdrew,
#             wedged, self-fenced or logged BUG/Oops/hung task in its whole
#             kernel log after the mark; FAIL otherwise
#
# Budgets (derived): prep and the cold audit are run.sh rows under their own
# manifest budgets (run.sh flips an overrun to FAIL itself, so no outer
# timeout).  Steps 1 and 2 are a handful of small creates and one rename, each
# a DLM round trip of milliseconds, plus a cache drop: 10 s each.  Steps 3 and
# 4 wait out the held release (PREFENCE_MS) and then its fence on a cluster
# doing nothing else (well under 1 s), plus one acquire: PREFENCE_MS + 10 s
# each.  Counters and knob resets 20-40 s per node; the stream copy 120 s.
#
# Usage: tests/noino_dirty_recycle_ab.sh <label> <knob 0|1> [iters=10] [config=2/net/mesh/direct] [group=g2]
# Env:   NDR_PREFENCE_MS (default 2500: the pin is cleared within ~1 s of the
#        BAST, so the fence starts well after it), NDR_ARM (dirtywait, the
#        default, or takeover)
# Exit 0 PASS / CONTROL-*, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; KNOB=${2:?knob 0|1}; ITERS=${3:-10}
CONFIG=${4:-2/net/mesh/direct}; GROUP=${5:-g2}
PREFENCE=${NDR_PREFENCE_MS:-2500}
ARM=${NDR_ARM:-dirtywait}
case "$KNOB" in 0|1) ;; *) echo "knob must be 0 or 1"; exit 2 ;; esac
# noino_recycle_dirty_wait / noino_recycle_takeover / dbg_recycle_nowait
case "$ARM" in
    dirtywait) DW=$KNOB; TK=1; NW=0 ;;
    takeover)  DW=1; TK=$KNOB; NW=1 ;;
    *) echo "NDR_ARM must be dirtywait or takeover"; exit 2 ;;
esac
for v in "$ITERS" "$PREFENCE"; do
    case "$v" in ''|*[!0-9]*) echo "iters and NDR_PREFENCE_MS must be whole numbers"; exit 2 ;; esac
done
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
read -r A B rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${A:-}" ] && [ -n "${B:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
# run.sh holds the nodes only while it runs; between its calls the workload
# below is invisible to tools/vm_pool.sh, whose idle sweep would shut them off
. tests/lib/runlock.sh
vmhold_take "noino_dirty_recycle_ab $LABEL" "$A" "$B" \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold $A $B"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_noino_dirty_recycle_$LABEL
mkdir -p "$OUT"
MARK="NOINO-DIRTY-RECYCLE-$LABEL-$$"
P=/sys/module/mxfs/parameters
DCNTS="recycle_dirty_waits recycle_dirty_wait_rounds recycle_dirty_kept recycle_waited_reset recycle_dirty_hazard recycle_reset_dirty recycle_reset_noino noino_bast_reclaimable recycle_dirty_takeover noino_takeovers dbg_recycle_nowait_hits"
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
echo "=== noino_dirty_recycle_ab label=$LABEL arm=$ARM knob=$KNOB iters=$ITERS prefence_ms=$PREFENCE $CONFIG $GROUP [$A $B] build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
want=$(modinfo -F srcversion mxfs.ko)
for n in $A $B; do
    sv=$(rs 20 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT label=$LABEL -- $n runs '$sv', not the tree build $want evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "echo $DW > $P/noino_recycle_dirty_wait; echo $TK > $P/noino_recycle_takeover; echo $NW > $P/dbg_recycle_nowait; echo $PREFENCE > $P/dbg_noino_prefence_delay_ms; echo 0 > $P/dbg_ail_pin_ino; for c in $DCNTS; do echo 0 > $P/\$c; done; echo $MARK > /dev/kmsg; echo \$(cat $P/noino_recycle_dirty_wait)/\$(cat $P/noino_recycle_takeover)/\$(cat $P/dbg_recycle_nowait)/\$(cat $P/dbg_noino_prefence_delay_ms)/\$(cat $P/noino_recycle_guard)/\$(cat $P/dbg_ail_pin_ino)" | tail -1)
    [ "$got" = "$DW/$TK/$NW/$PREFENCE/1/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's noino_recycle_dirty_wait/noino_recycle_takeover/dbg_recycle_nowait/dbg_noino_prefence_delay_ms/noino_recycle_guard/dbg_ail_pin_ino read '$got', not $DW/$TK/$NW/$PREFENCE/1/0 (is the build missing a knob?) evidence=$OUT"; exit 2; }
done
# never leave the pin set: it holds the node's log tail
unpin() { rs 20 "$A" "echo 0 > $P/dbg_ail_pin_ino; cat $P/dbg_ail_pin_ino" | tail -1; }
D=/mnt/shared/ndr.$LABEL
rs 30 "$B" "mkdir -p $D && sync && echo ok" | grep -q ok || { echo "RESULT: ABORT label=$LABEL stage=mkdir evidence=$OUT"; exit 2; }

WS=$((PREFENCE / 1000 + 10))
reached=0; stale=0; stale_reached=0; ran=0; broke=""
for k in $(seq 1 "$ITERS"); do
    dino=$(rs 10 "$B" "mkdir $D/d$k && for i in 0 1 2 3; do echo x > $D/d$k/f\$i; done && stat -c %i $D/d$k" | tr -dc '0-9')
    [ -n "$dino" ] || { broke="iter$k-create"; echo "iter $k BROKE at the create on $B"; break; }
    c0=$(rs 10 "$A" "echo $dino > $P/dbg_ail_pin_ino && mv $D/d$k/f0 $D/d$k/g0 && echo 2 > /proc/sys/vm/drop_caches && cat $P/noino_bast_reclaimable" | tr -dc '0-9')
    [ -n "$c0" ] || { broke="iter$k-rename"; echo "iter $k dir_ino=$dino BROKE at the rename on $A (unpin: $(unpin))"; break; }
    timeout $WS "$SSH" "$B" "ls -f $D/d$k" < /dev/null > "$OUT/iter${k}_${B}_ls.txt" 2> "$OUT/iter${k}_${B}_ls.err" & pl=$!
    # A: wait for the BAST to be served by the no-inode release (counter
    # moves), recycle the corpse with a path walk, and unpin the directory
    # once the recycle has decided
    rsum="\$((\$(cat $P/recycle_reset_noino) + \$(cat $P/recycle_dirty_waits) + \$(cat $P/recycle_dirty_kept) + \$(cat $P/recycle_dirty_takeover)))"
    arep=$(rs $WS "$A" "w=0; while [ \$(cat $P/noino_bast_reclaimable) -le $c0 ] && [ \$w -lt $((PREFENCE / 10)) ]; do sleep 0.01; w=\$((w + 1)); done; c1=\$(cat $P/noino_bast_reclaimable); r0=$rsum; stat -c %i $D/d$k/f1 > /dev/null & sp=\$!; u=0; while [ $rsum -le \$r0 ] && [ \$u -lt 100 ]; do sleep 0.01; u=\$((u + 1)); done; echo 0 > $P/dbg_ail_pin_ino; wait \$sp; src=\$?; echo bast_rounds=\$w c1=\$c1 recycle_rounds=\$u pin=\$(cat $P/dbg_ail_pin_ino) stat_rc=\$src waits=\$(cat $P/recycle_dirty_waits) hazard=\$(cat $P/recycle_dirty_hazard) reset_dirty=\$(cat $P/recycle_reset_dirty) kept=\$(cat $P/recycle_dirty_kept) takeover=\$(cat $P/recycle_dirty_takeover) nowait=\$(cat $P/dbg_recycle_nowait_hits)")
    wait $pl; lrc=$?
    case "$arep" in *pin=0*) ;; *) echo "iter $k WARN the pin did not read back 0 ('$(echo "$arep" | tail -1)'); unpin: $(unpin)" ;; esac
    c1=$(echo "$arep" | sed -n 's/.*c1=\([0-9]*\).*/\1/p')
    r=0; [ -n "$c1" ] && [ "$c1" -gt "$c0" ] && r=1
    s=0; grep -qx 'f0' "$OUT/iter${k}_${B}_ls.txt" && s=1
    reached=$((reached + r)); stale=$((stale + s)); [ "$r" = 1 ] && stale_reached=$((stale_reached + s))
    ran=$k
    echo "iter $k dir_ino=$dino bast_before=$c0 $(echo "$arep" | tail -1) ls_rc=$lrc names=[$(grep -v '^\.\.\?$' "$OUT/iter${k}_${B}_ls.txt" | sort | paste -sd' ')] reached=$r stale=$s"
done
echo "$A dbg_ail_pin_ino after the loop: $(unpin)"
if [ -n "$broke" ] && [ "$reached" = 0 ]; then
    echo "RESULT: ABORT label=$LABEL stage=$broke -- the loop broke before any iteration was reached evidence=$OUT"; exit 2
fi

tot_dw=0; tot_dwr=0; tot_dk=0; tot_dwz=0; tot_dhz=0; tot_drd=0
declare -A nfail=()
for n in $A $B; do
    rs 40 "$n" "for c in $DCNTS noino_recycle_dirty_wait; do echo \$c=\$(cat $P/\$c 2>/dev/null); done; echo mounted=\$(grep -c ' /mnt/shared mxfs ' /proc/mounts)" > "$OUT/${n}_counters.txt"
    v() { sed -n "s/^$1=//p" "$OUT/${n}_counters.txt"; }
    dw=$(v recycle_dirty_waits); dwr=$(v recycle_dirty_wait_rounds); dk=$(v recycle_dirty_kept)
    dwz=$(v recycle_waited_reset); dhz=$(v recycle_dirty_hazard); drd=$(v recycle_reset_dirty); mnt=$(v mounted)
    tk=$(v recycle_dirty_takeover)
    [ -n "$dw" ] && [ -n "$dwr" ] && [ -n "$dk" ] && [ -n "$dwz" ] && [ -n "$dhz" ] && [ -n "$drd" ] && [ -n "$tk" ] && [ -n "$mnt" ] \
        || { echo "RESULT: ABORT label=$LABEL -- $n's counters did not read evidence=$OUT"; exit 2; }
    echo "$n dirtywait: knob=$(v noino_recycle_dirty_wait) waits=$dw wait_rounds=$dwr kept=$dk waited_reset=$dwz hazard=$dhz reset_dirty=$drd reset_noino=$(v recycle_reset_noino) takeover=$tk taken_over=$(v noino_takeovers) nowait_hits=$(v dbg_recycle_nowait_hits) bast_reclaimable=$(v noino_bast_reclaimable) mounted=$mnt"
    if [ "$n" = "$A" ]; then
        a_dw=$dw; a_dk=$dk; a_dhz=$dhz; a_drd=$drd; a_tk=$tk
    fi
    tot_dw=$((tot_dw + dw)); tot_dwr=$((tot_dwr + dwr)); tot_dk=$((tot_dk + dk)); tot_dwz=$((tot_dwz + dwz))
    tot_dhz=$((tot_dhz + dhz)); tot_drd=$((tot_drd + drd))
    [ "$mnt" = 1 ] || nfail[$n]=1
done
for n in $A $B; do
    got=$(rs 20 "$n" "echo 0 > $P/dbg_noino_prefence_delay_ms; echo 0 > $P/dbg_recycle_nowait; echo \$(cat $P/dbg_noino_prefence_delay_ms)/\$(cat $P/dbg_recycle_nowait)" | tail -1)
    [ "$got" = 0/0 ] || echo "WARN $n's dbg_noino_prefence_delay_ms/dbg_recycle_nowait read '$got' after the reset; the cold audit's unmount waits on the first"
done

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
# The lap's whole kernel log: the prep starts `dmesg --follow` into
# /root/dmesg.stream on every node and the next lap's prep replaces it.
dcov=0; dunc=0
for n in $A $B; do
    timeout 120 "$SSH" "$n" "gzip -c /root/dmesg.stream" < /dev/null 2>/dev/null > "$OUT/${n}_dmesg_stream.gz"
    echo "$n kernel log: $OUT/${n}_dmesg_stream.gz marks=$(zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | grep -acF -- "$MARK")"
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|P-INODE-WEDGE \|P-SESSION-POISON\|BUG:\|Oops\|blocked for more than' > "$OUT/${n}_failures.txt"
    sds=$(wc -l < "$OUT/${n}_failures.txt")
    echo "$n stream failure lines: $sds ($OUT/${n}_failures.txt)"
    head -3 "$OUT/${n}_failures.txt" | cut -c1-300
    [ "$sds" = 0 ] || nfail[$n]=1
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'P-RECYCLE-DIRTY-WAIT \|P-RECYCLE-DIRTY-KEEP \|P-RECYCLE-DIRTY-TAKEOVER \|P-NOINO-TAKEN-OVER \|P-NOINO-LIVE-SKIP \|P-RECYCLE-WAITED \|P-RECYCLE-RESET-UNDER-NOINO \|P-NOINO-RECLAIMABLE \|P119-NONEX-FLUSH-SKIP \|P56-NL-LOGGED-DIR-SKIP \|P383-HOME-VS-OWED \|P228-RELBAR-DEFER \|P-NOINO-ACQ-WAIT \|P-INODE-WEDGE ' > "$OUT/${n}_dirtywait.txt"
    c=$(grep -a 'P-RECYCLE-RESET-UNDER-NOINO ' "$OUT/${n}_dirtywait.txt" | grep -ac ' owes=1 at_start=0 ')
    u=$(grep -a 'P-RECYCLE-RESET-UNDER-NOINO ' "$OUT/${n}_dirtywait.txt" | grep -ac ' owes=1 at_start=1 ')
    dcov=$((dcov + c)); dunc=$((dunc + u))
    echo "$n lines: wait=$(grep -ac 'P-RECYCLE-DIRTY-WAIT ' "$OUT/${n}_dirtywait.txt") keep=$(grep -ac 'P-RECYCLE-DIRTY-KEEP ' "$OUT/${n}_dirtywait.txt") takeover=$(grep -ac 'P-RECYCLE-DIRTY-TAKEOVER ' "$OUT/${n}_dirtywait.txt") taken_over=$(grep -ac 'P-NOINO-TAKEN-OVER ' "$OUT/${n}_dirtywait.txt") live_skip=$(grep -ac 'P-NOINO-LIVE-SKIP ' "$OUT/${n}_dirtywait.txt") waited=$(grep -ac 'P-RECYCLE-WAITED ' "$OUT/${n}_dirtywait.txt") reset=$(grep -ac 'P-RECYCLE-RESET-UNDER-NOINO ' "$OUT/${n}_dirtywait.txt") reset_owes_at_start0=$c reset_owes_at_start1=$u reclaimable_bast=$(grep -ac 'P-NOINO-RECLAIMABLE ' "$OUT/${n}_dirtywait.txt") p119=$(grep -ac 'P119-NONEX-FLUSH-SKIP ' "$OUT/${n}_dirtywait.txt") p56nl=$(grep -ac 'P56-NL-LOGGED-DIR-SKIP ' "$OUT/${n}_dirtywait.txt") relbar_defer=$(grep -ac 'P228-RELBAR-DEFER ' "$OUT/${n}_dirtywait.txt") wedge=$(grep -ac 'P-INODE-WEDGE ' "$OUT/${n}_dirtywait.txt")"
    grep -a -m4 'P-RECYCLE-DIRTY-WAIT \|P-RECYCLE-DIRTY-TAKEOVER \|P-NOINO-TAKEN-OVER \|P-RECYCLE-WAITED \|P-RECYCLE-RESET-UNDER-NOINO \|P119-NONEX-FLUSH-SKIP ' "$OUT/${n}_dirtywait.txt" | cut -c1-300
done
bad=${#nfail[@]}

REP="arm=$ARM knob=$KNOB iters=$ITERS ran=$ran broke=${broke:-no} prefence_ms=$PREFENCE reached=$reached stale=$stale stale_reached=$stale_reached a_waits=${a_dw:-?} a_kept=${a_dk:-?} a_takeover=${a_tk:-?} a_hazard=${a_dhz:-?} a_reset_dirty=${a_drd:-?} waited_reset=$tot_dwz reset_owes_covered=$dcov reset_owes_uncovered=$dunc"
if [ "$KNOB" = 0 ]; then
    [ $((a_dhz + a_drd)) -gt 0 ] || { echo "RESULT: VACUOUS noino_dirty_recycle_ab label=$LABEL $REP audit=$audit node_failures=$bad -- no recycle on $A met a dirty corpse under a tracked in-flight release (the control did not reach the case) evidence=$OUT"; exit 3; }
    v=CONTROL-FRESH; [ "$stale" -gt 0 ] && v=CONTROL-STALE
    echo "RESULT: $v noino_dirty_recycle_ab label=$LABEL $REP audit=$audit node_failures=$bad evidence=$OUT"; exit 0
fi
if [ "$ARM" = takeover ]; then
    reach=$a_tk; resets=$((dcov + dunc + a_drd))
else
    reach=$((a_dw + a_dk)); resets=$dcov
fi
[ "$reach" -gt 0 ] || { echo "RESULT: VACUOUS noino_dirty_recycle_ab label=$LABEL $REP audit=$audit node_failures=$bad -- no recycle on $A waited for, kept the grant of, or took over the release of a dirty corpse under a tracked in-flight release (the fix did not reach the case) evidence=$OUT"; exit 3; }
case "$audit" in CLEAN*) aok=1 ;; *) aok=0 ;; esac
if [ -z "$broke" ] && [ "$stale" = 0 ] && [ "$resets" = 0 ] && [ "$aok" = 1 ] && [ "$bad" = 0 ]; then
    echo "RESULT: PASS noino_dirty_recycle_ab label=$LABEL $REP audit=$audit evidence=$OUT"; exit 0
fi
echo "RESULT: FAIL noino_dirty_recycle_ab label=$LABEL $REP audit=$audit node_failures=$bad evidence=$OUT"; exit 1
