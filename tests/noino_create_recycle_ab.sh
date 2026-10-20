#!/bin/bash
# tests/noino_create_recycle_ab.sh — same-build A/B of the recycle take-over
# (module knob noino_recycle_takeover), for
# D-RECYCLE-RESET-UNDER-NOINO-STRANDS-COMMITTED-DIR-CHANGE-WEDGE-SHUTDOWN, the
# branch noino_recycle_dirty_wait leaves open: a recycle that cannot wait.
#
# H-W2, written before this harness (tdr1, 4/disk/caw/mpath, test4: at 105.631125
# a mkdir took number 2097280 from the allocator, at 105.632333 a peer's BAST
# registered a no-inode release of it, and at 105.634663 the same mkdir recycled
# the number's corpse and reset its cached grant, P-RECYCLE-RESET-UNDER-NOINO
# comm=mkdir): a create, or any caller whose transaction holds items, never
# waits in xfs_iget_cache_hit (mxfs_noino_recycle_must_wait), so when it
# recycles a corpse that still owes the platter a committed change under a
# no-inode release registered before the recycle began, the recycle guard
# (H-F7) lowers the corpse's grant to NL.  The aild then drops the change
# unwritten (P119-NONEX-FLUSH-SKIP), the release's drain fence passes, and its
# unlock hands the peer a home without the change.
# PREDICTION IF TRUE: with noino_recycle_takeover=0 the owner logs
#   P-RECYCLE-RESET-UNDER-NOINO owes=1 at_start=1 for the reused number and
#   P119-NONEX-FLUSH-SKIP for it, and the peer's read through the removed
#   file's handle, answered once the release unlocks, returns the removed
#   file's bytes: the home still holds the file the owner removed and freed.
#   With =1 the owner logs P-RECYCLE-DIRTY-TAKEOVER and no reset of a dirty
#   corpse, and the peer's read never returns those bytes.
# IF FALSE: the control resets dirty corpses at_start=1 and the peer's reads
#   never return the removed file's bytes.
#
# THE SEQUENCE, iteration k, in D=/mnt/shared/ncr.<label>:
#   1. A creates d<k> and d<k>/f0 holding "old<k>": f0's number N, A caches EX;
#   2. B starts tests/handle_reopen.py hold on d<k>/f0: it takes the file's
#      handle through an O_PATH descriptor (B's lookup takes PR on N) and keeps
#      that descriptor, so B's in-core inode stays cached without the file
#      being open, then waits for a trigger;
#   3. A names N in dbg_ail_pin_ino, removes f0 (its EX request makes B release
#      its PR first) and pushes inodegc (statfs): N is freed, and its corpse is
#      reclaimable on A, still caching EX and owing the platter the removal and
#      the free.  The pin keeps it owing: an idle node's aild writes an inode
#      within milliseconds (noino_dirty_recycle_ab.sh, ndrc1/ndrc2);
#   4. A sets dbg_create_alloc_delay_ms and creates d<k>/g0 in the background:
#      the allocator takes N, the lowest free number near d<k>, and the create
#      waits NCR_CREATE_DELAY_MS before instantiating it;
#   5. NCR_TRIGGER_AFTER_MS after step 4 began, B's trigger fires: B opens the
#      handle (a cache hit on its stale in-core inode) and reads, and the read's
#      PR request BASTs A, whose in-core lookup refuses the reclaimable corpse:
#      the no-inode release registers, after the allocator's take, so the
#      allocator's own guard (noino_resv_guard) never saw it, and
#      dbg_noino_prefence_delay_ms holds it before its fence;
#   6. A waits for noino_bast_reclaimable to move, then for the create to
#      recycle the corpse (recycle_reset_noino, recycle_dirty_takeover,
#      recycle_dirty_waits or recycle_dirty_kept moves; at most
#      NCR_CREATE_DELAY_MS + 1.5 s), and clears the pin, so the release's fence,
#      held NCR_PREFENCE_MS from the BAST, never meets it.
# B's read returns once B is granted PR.  An iteration is REACHED when the
# release registered (step 6), g0 took N, and the create's recycle met the
# corpse owing the platter under it: recycle_reset_dirty moved in the control,
# recycle_dirty_takeover in the fix.  It is STALE when B read "old<k>".
# An iteration whose setup fails ends the loop (BROKE).
#
# THE GRADES
#   ABORT     prep, knob read-back, counter read or the helper failed, or the
#             loop broke before any iteration was reached
#   VACUOUS   no iteration was reached
#   knob=0    the control: CONTROL-STALE when a reached iteration's read returned
#             the removed file's bytes, CONTROL-FRESH when none did
#   knob=1    PASS when every iteration ran, no read returned the removed file's
#             bytes, every read ended (rc=ok or ESTALE) inside its budget, no
#             reset of a dirty corpse was counted (recycle_reset_dirty 0), the
#             cold audit is CLEAN, and neither node shut down, withdrew, wedged,
#             self-fenced or logged BUG/Oops/hung task in its whole kernel log
#             after the mark; FAIL otherwise
#
# Budgets (derived): prep and the cold audit are run.sh rows under their own
# manifest budgets (run.sh flips an overrun to FAIL itself, so no outer
# timeout).  Steps 1-3 are a handful of small creates, one handle lookup and one
# unlink, each a DLM round trip of milliseconds: 10 s each.  The helper's HOLD
# line: 10 s.  Step 4 is the create delay plus one create: CREATE_DELAY + 10 s.
# Step 6 waits CREATE_DELAY + 1.5 s at most.  B's read waits out the held release
# (PREFENCE from the BAST), its fence on a cluster doing nothing else (well under
# 1 s) and one re-sent request: CREATE_DELAY + PREFENCE + 15 s from the trigger.
# Counters and knob resets 20-40 s per node; the stream copy 120 s.
#
# Usage: tests/noino_create_recycle_ab.sh <label> <knob 0|1> [iters=10] [config=2/net/mesh/direct] [group=g2]
# Env:   NCR_CREATE_DELAY_MS (default 3000), NCR_PREFENCE_MS (default 5000),
#        NCR_TRIGGER_AFTER_MS (default 1000)
# Exit 0 PASS / CONTROL-*, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; KNOB=${2:?knob 0|1}; ITERS=${3:-10}
CONFIG=${4:-2/net/mesh/direct}; GROUP=${5:-g2}
CDELAY=${NCR_CREATE_DELAY_MS:-3000}
PREFENCE=${NCR_PREFENCE_MS:-5000}
TAFTER=${NCR_TRIGGER_AFTER_MS:-1000}
case "$KNOB" in 0|1) ;; *) echo "knob must be 0 or 1"; exit 2 ;; esac
for v in "$ITERS" "$CDELAY" "$PREFENCE" "$TAFTER"; do
    case "$v" in ''|*[!0-9]*) echo "iters and the NCR_*_MS settings must be whole numbers"; exit 2 ;; esac
done
# the pin must be gone before the release's fence starts (PREFENCE after the
# BAST, which lands after TAFTER): step 6 clears it by CREATE_DELAY + 1.5 s
[ $((CDELAY + 1500)) -lt $((TAFTER + PREFENCE)) ] \
    || { echo "NCR_CREATE_DELAY_MS + 1500 must be below NCR_TRIGGER_AFTER_MS + NCR_PREFENCE_MS (the fence would meet the pin)"; exit 2; }
[ "$TAFTER" -lt "$CDELAY" ] || { echo "NCR_TRIGGER_AFTER_MS must be below NCR_CREATE_DELAY_MS"; exit 2; }
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
read -r A B rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${A:-}" ] && [ -n "${B:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
# run.sh holds the nodes only while it runs; between its calls the workload
# below is invisible to tools/vm_pool.sh, whose idle sweep would shut them off
. tests/lib/runlock.sh
vmhold_take "noino_create_recycle_ab $LABEL" "$A" "$B" \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold $A $B"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_noino_create_recycle_$LABEL
mkdir -p "$OUT"
MARK="NOINO-CREATE-RECYCLE-$LABEL-$$"
P=/sys/module/mxfs/parameters
HELPER=/src/mxfs/tests/handle_reopen.py
DCNTS="recycle_dirty_takeover noino_takeovers recycle_reset_dirty recycle_reset_noino recycle_dirty_waits recycle_dirty_kept recycle_dirty_hazard noino_bast_reclaimable noino_recycle_redrive dialloc_resv_noino_skipped dialloc_resv_under_noino"
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
echo "=== noino_create_recycle_ab label=$LABEL knob=$KNOB iters=$ITERS create_delay_ms=$CDELAY prefence_ms=$PREFENCE trigger_after_ms=$TAFTER $CONFIG $GROUP [$A $B] build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
want=$(modinfo -F srcversion mxfs.ko)
for n in $A $B; do
    sv=$(rs 20 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT label=$LABEL -- $n runs '$sv', not the tree build $want evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "echo $KNOB > $P/noino_recycle_takeover; echo 1 > $P/noino_recycle_dirty_wait; echo $PREFENCE > $P/dbg_noino_prefence_delay_ms; echo 0 > $P/dbg_ail_pin_ino; echo 0 > $P/dbg_create_alloc_delay_ms; for c in $DCNTS; do echo 0 > $P/\$c; done; echo $MARK > /dev/kmsg; echo \$(cat $P/noino_recycle_takeover)/\$(cat $P/noino_recycle_dirty_wait)/\$(cat $P/dbg_noino_prefence_delay_ms)/\$(cat $P/noino_recycle_guard)/\$(cat $P/noino_resv_guard)/\$(cat $P/dbg_ail_pin_ino)/\$(cat $P/dbg_create_alloc_delay_ms)" | tail -1)
    [ "$got" = "$KNOB/1/$PREFENCE/1/1/0/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's noino_recycle_takeover/noino_recycle_dirty_wait/dbg_noino_prefence_delay_ms/noino_recycle_guard/noino_resv_guard/dbg_ail_pin_ino/dbg_create_alloc_delay_ms read '$got', not $KNOB/1/$PREFENCE/1/1/0/0 (is the build missing a knob?) evidence=$OUT"; exit 2; }
    rs 20 "$n" "grep -c '^def hold' $HELPER" | grep -qx 1 \
        || { echo "RESULT: ABORT label=$LABEL -- $n's $HELPER has no hold subcommand evidence=$OUT"; exit 2; }
done
# never leave the pin or the create delay set: the pin holds the node's log tail
reset_a() { rs 20 "$A" "echo 0 > $P/dbg_ail_pin_ino; echo 0 > $P/dbg_create_alloc_delay_ms; echo pin=\$(cat $P/dbg_ail_pin_ino) cdelay=\$(cat $P/dbg_create_alloc_delay_ms)" | tail -1; }
D=/mnt/shared/ncr.$LABEL
rs 30 "$A" "mkdir -p $D && sync && echo ok" | grep -q ok || { echo "RESULT: ABORT label=$LABEL stage=mkdir evidence=$OUT"; exit 2; }

WS=$(( (CDELAY + 1500) / 1000 + 10 ))
WR=$(( (CDELAY + PREFENCE) / 1000 + 15 ))
CW=$(( CDELAY / 1000 + 10 ))
reached=0; stale=0; stale_reached=0; ran=0; broke=""; readbad=0
for k in $(seq 1 "$ITERS"); do
    old=$(printf 'old%s\n' "$k" | od -An -tx1 | tr -d ' \n')
    # per-lap names (the harness's pid), so nothing is left to clear first
    trig=/run/ncr_trig.$LABEL.$$.$k; res=/run/ncr_res.$LABEL.$$.$k; ho=/run/ncr_hold.$LABEL.$$.$k
    N=$(rs 10 "$A" "mkdir $D/d$k && echo old$k > $D/d$k/f0 && stat -c %i $D/d$k/f0" | tr -dc '0-9')
    [ -n "$N" ] || { broke="iter$k-create"; echo "iter $k BROKE at the create on $A"; break; }
    hold=$(rs 15 "$B" "nohup python3 $HELPER hold $D/d$k/f0 /mnt/shared $trig $res $((WR + 30)) > $ho 2>&1 & for i in \$(seq 100); do grep -q '^HOLD' $ho && break; sleep 0.1; done; head -3 $ho")
    case "$hold" in "HOLD ino=$N "*) ;; *) broke="iter$k-hold"; echo "iter $k ino=$N BROKE at the helper on $B: '$(echo "$hold" | tr '\n' ' ' | cut -c1-300)'"; break ;; esac
    rsum="\$((\$(cat $P/recycle_reset_noino) + \$(cat $P/recycle_dirty_takeover) + \$(cat $P/recycle_dirty_waits) + \$(cat $P/recycle_dirty_kept)))"
    pre=$(rs 10 "$A" "echo $N > $P/dbg_ail_pin_ino && rm $D/d$k/f0 && stat -f $D > /dev/null && sleep 0.3 && echo c0=\$(cat $P/noino_bast_reclaimable) r0=$rsum rd0=\$(cat $P/recycle_reset_dirty) tk0=\$(cat $P/recycle_dirty_takeover)")
    c0=$(echo "$pre" | sed -n 's/.*c0=\([0-9]*\).*/\1/p'); r0=$(echo "$pre" | sed -n 's/.*r0=\([0-9]*\).*/\1/p')
    rd0=$(echo "$pre" | sed -n 's/.*rd0=\([0-9]*\).*/\1/p'); tk0=$(echo "$pre" | sed -n 's/.*tk0=\([0-9]*\).*/\1/p')
    [ -n "$c0" ] && [ -n "$r0" ] && [ -n "$rd0" ] && [ -n "$tk0" ] \
        || { broke="iter$k-remove"; echo "iter $k ino=$N BROKE at the removal on $A (reset: $(reset_a))"; break; }
    # step 4: the create, held between the allocator's take and the instantiation
    timeout $CW "$SSH" "$A" "echo $CDELAY > $P/dbg_create_alloc_delay_ms; touch $D/d$k/g0; r=\$?; echo 0 > $P/dbg_create_alloc_delay_ms; echo create_rc=\$r g0_ino=\$(stat -c %i $D/d$k/g0 2>/dev/null) g0_gen=\$(python3 $HELPER gen $D/d$k/g0 2>/dev/null)" < /dev/null > "$OUT/iter${k}_${A}_create.txt" 2>&1 & cpid=$!
    # step 5: B's read through the removed file's handle
    sleep "$(printf '%d.%03d' $((TAFTER / 1000)) $((TAFTER % 1000)))"
    rs 10 "$B" "touch $trig && echo fired" | grep -q fired || echo "iter $k WARN the trigger did not read back on $B"
    # step 6: the release registers, the create recycles the corpse, the pin goes
    arep=$(rs $WS "$A" "w=0; while [ \$(cat $P/noino_bast_reclaimable) -le $c0 ] && [ \$w -lt $((CDELAY / 10)) ]; do sleep 0.01; w=\$((w + 1)); done; c1=\$(cat $P/noino_bast_reclaimable); u=0; while [ $rsum -le $r0 ] && [ \$u -lt $(( (CDELAY + 1500) / 10 )) ]; do sleep 0.01; u=\$((u + 1)); done; echo 0 > $P/dbg_ail_pin_ino; echo bast_rounds=\$w c1=\$c1 recycle_rounds=\$u pin=\$(cat $P/dbg_ail_pin_ino) rd1=\$(cat $P/recycle_reset_dirty) tk1=\$(cat $P/recycle_dirty_takeover) takeovers=\$(cat $P/noino_takeovers) resv_skipped=\$(cat $P/dialloc_resv_noino_skipped)")
    wait $cpid
    case "$arep" in *pin=0*) ;; *) echo "iter $k WARN the pin did not read back 0 ('$(echo "$arep" | tail -1)'); reset: $(reset_a)" ;; esac
    cre=$(tail -1 "$OUT/iter${k}_${A}_create.txt")
    rres=$(rs $((WR + 5)) "$B" "i=0; while [ ! -s $res ] && [ \$i -lt $((WR * 10)) ]; do sleep 0.1; i=\$((i + 1)); done; cat $res 2>/dev/null || echo 'HANDLE-READ rc=NORESULT'")
    rres=$(echo "$rres" | grep -a '^HANDLE-READ' | tail -1); [ -n "$rres" ] || rres="HANDLE-READ rc=NORESULT"
    echo "$rres" > "$OUT/iter${k}_${B}_read.txt"
    c1=$(echo "$arep" | sed -n 's/.*c1=\([0-9]*\).*/\1/p')
    rd1=$(echo "$arep" | sed -n 's/.*rd1=\([0-9]*\).*/\1/p'); tk1=$(echo "$arep" | sed -n 's/.*tk1=\([0-9]*\).*/\1/p')
    g0=$(echo "$cre" | sed -n 's/.*g0_ino=\([0-9]*\).*/\1/p')
    bm=0; [ -n "$c1" ] && [ "$c1" -gt "$c0" ] && bm=1
    dm=0
    if [ "$KNOB" = 0 ]; then [ -n "$rd1" ] && [ "$rd1" -gt "$rd0" ] && dm=1
    else [ -n "$tk1" ] && [ "$tk1" -gt "$tk0" ] && dm=1; fi
    r=0; [ "$bm" = 1 ] && [ "$g0" = "$N" ] && [ "$dm" = 1 ] && r=1
    s=0; case "$rres" in *" data=$old"*) s=1 ;; esac
    case "$rres" in "HANDLE-READ rc=ok "*|"HANDLE-READ rc=ESTALE "*) ;; *) readbad=$((readbad + 1)) ;; esac
    reached=$((reached + r)); stale=$((stale + s)); [ "$r" = 1 ] && stale_reached=$((stale_reached + s))
    ran=$k
    echo "iter $k ino=$N $(echo "$hold" | grep '^HOLD' | cut -d' ' -f3) $(echo "$arep" | tail -1) $cre bast_moved=$bm decided=$dm $rres reached=$r stale=$s"
    case "$cre" in create_rc=0*) ;; *) broke="iter$k-reuse-create"; echo "iter $k BROKE at the reusing create on $A"; break ;; esac
done
echo "$A pin and create delay after the loop: $(reset_a)"
if [ -n "$broke" ] && [ "$reached" = 0 ]; then
    echo "RESULT: ABORT label=$LABEL stage=$broke -- the loop broke before any iteration was reached evidence=$OUT"; exit 2
fi

declare -A nfail=()
for n in $A $B; do
    rs 40 "$n" "for c in $DCNTS noino_recycle_takeover; do echo \$c=\$(cat $P/\$c 2>/dev/null); done; echo mounted=\$(grep -c ' /mnt/shared mxfs ' /proc/mounts)" > "$OUT/${n}_counters.txt"
    v() { sed -n "s/^$1=//p" "$OUT/${n}_counters.txt"; }
    tk=$(v recycle_dirty_takeover); nt=$(v noino_takeovers); rd=$(v recycle_reset_dirty); mnt=$(v mounted)
    [ -n "$tk" ] && [ -n "$nt" ] && [ -n "$rd" ] && [ -n "$mnt" ] \
        || { echo "RESULT: ABORT label=$LABEL -- $n's counters did not read evidence=$OUT"; exit 2; }
    echo "$n takeover: knob=$(v noino_recycle_takeover) recycle_dirty_takeover=$tk noino_takeovers=$nt recycle_reset_dirty=$rd recycle_reset_noino=$(v recycle_reset_noino) dirty_waits=$(v recycle_dirty_waits) dirty_kept=$(v recycle_dirty_kept) hazard=$(v recycle_dirty_hazard) bast_reclaimable=$(v noino_bast_reclaimable) redrive=$(v noino_recycle_redrive) resv_skipped=$(v dialloc_resv_noino_skipped) resv_under=$(v dialloc_resv_under_noino) mounted=$mnt"
    if [ "$n" = "$A" ]; then a_tk=$tk; a_nt=$nt; a_rd=$rd; fi
    [ "$mnt" = 1 ] || nfail[$n]=1
done
for n in $A $B; do
    got=$(rs 20 "$n" "echo 0 > $P/dbg_noino_prefence_delay_ms; echo 0 > $P/dbg_create_alloc_delay_ms; echo 0 > $P/dbg_ail_pin_ino; echo \$(cat $P/dbg_noino_prefence_delay_ms)/\$(cat $P/dbg_create_alloc_delay_ms)/\$(cat $P/dbg_ail_pin_ino)" | tail -1)
    [ "$got" = 0/0/0 ] || echo "WARN $n's dbg_noino_prefence_delay_ms/dbg_create_alloc_delay_ms/dbg_ail_pin_ino read '$got' after the reset; the cold audit's unmount waits on them"
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
dunc=0
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
        | grep -a 'P-RECYCLE-DIRTY-TAKEOVER \|P-NOINO-TAKEN-OVER \|P-RECYCLE-RESET-UNDER-NOINO \|P-RECYCLE-DIRTY-WAIT \|P-RECYCLE-DIRTY-KEEP \|P-NOINO-LIVE-SKIP \|P-NOINO-RECLAIMABLE \|P119-NONEX-FLUSH-SKIP \|P56-NL-LOGGED-DIR-SKIP \|P383-HOME-VS-OWED \|P228-RELBAR-DEFER \|P-NOINO-UNLOCK-UNDRAINED \|P-NOINO-UNLOCK-LEFT-GRANT \|P-NOINO-STALE-RELEASE \|P-DIALLOC-NOINO-SKIP \|P-DIALLOC-RESV-UNDER-NOINO \|P-INODE-WEDGE ' > "$OUT/${n}_takeover.txt"
    u=$(grep -a 'P-RECYCLE-RESET-UNDER-NOINO ' "$OUT/${n}_takeover.txt" | grep -ac ' owes=1 ')
    dunc=$((dunc + u))
    echo "$n lines: takeover=$(grep -ac 'P-RECYCLE-DIRTY-TAKEOVER ' "$OUT/${n}_takeover.txt") taken_over=$(grep -ac 'P-NOINO-TAKEN-OVER ' "$OUT/${n}_takeover.txt") live_skip=$(grep -ac 'P-NOINO-LIVE-SKIP ' "$OUT/${n}_takeover.txt") reset=$(grep -ac 'P-RECYCLE-RESET-UNDER-NOINO ' "$OUT/${n}_takeover.txt") reset_owes=$u p119=$(grep -ac 'P119-NONEX-FLUSH-SKIP ' "$OUT/${n}_takeover.txt") undrained=$(grep -ac 'P-NOINO-UNLOCK-UNDRAINED ' "$OUT/${n}_takeover.txt") left_grant=$(grep -ac 'P-NOINO-UNLOCK-LEFT-GRANT ' "$OUT/${n}_takeover.txt") relbar_defer=$(grep -ac 'P228-RELBAR-DEFER ' "$OUT/${n}_takeover.txt") wedge=$(grep -ac 'P-INODE-WEDGE ' "$OUT/${n}_takeover.txt")"
    grep -a -m6 'P-RECYCLE-DIRTY-TAKEOVER \|P-NOINO-TAKEN-OVER \|P-RECYCLE-RESET-UNDER-NOINO \|P119-NONEX-FLUSH-SKIP \|P-NOINO-LIVE-SKIP ' "$OUT/${n}_takeover.txt" | cut -c1-300
done
bad=${#nfail[@]}

REP="knob=$KNOB iters=$ITERS ran=$ran broke=${broke:-no} create_delay_ms=$CDELAY prefence_ms=$PREFENCE reached=$reached stale=$stale stale_reached=$stale_reached read_bad=$readbad a_takeover=${a_tk:-?} a_taken_over=${a_nt:-?} a_reset_dirty=${a_rd:-?} reset_owes_lines=$dunc"
[ "$reached" -gt 0 ] || { echo "RESULT: VACUOUS noino_create_recycle_ab label=$LABEL $REP audit=$audit node_failures=$bad -- no iteration was reached: no create recycled a corpse owing the platter under a release registered before it evidence=$OUT"; exit 3; }
if [ "$KNOB" = 0 ]; then
    v=CONTROL-FRESH; [ "$stale_reached" -gt 0 ] && v=CONTROL-STALE
    echo "RESULT: $v noino_create_recycle_ab label=$LABEL $REP audit=$audit node_failures=$bad evidence=$OUT"; exit 0
fi
case "$audit" in CLEAN*) aok=1 ;; *) aok=0 ;; esac
if [ -z "$broke" ] && [ "$stale" = 0 ] && [ "$readbad" = 0 ] && [ "${a_rd:-1}" = 0 ] && [ "$aok" = 1 ] && [ "$bad" = 0 ]; then
    echo "RESULT: PASS noino_create_recycle_ab label=$LABEL $REP audit=$audit evidence=$OUT"; exit 0
fi
echo "RESULT: FAIL noino_create_recycle_ab label=$LABEL $REP audit=$audit node_failures=$bad evidence=$OUT"; exit 1
