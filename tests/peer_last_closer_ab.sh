#!/bin/bash
# tests/peer_last_closer_ab.sh — same-build A/B of the local-unlink inactivation
# guard (module knob inact_local_epoch_guard) on a workload that makes the peer
# the last closer of every file one node unlinks, for
# D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-CORE-AFTER-CLEAN-UNMOUNT (H-F6).
#
# H-F6, written before this harness (from ng0rf1, ino 8388763, the record's one
# nlink-0 corruption): node A unlinks a file while node B holds a reference to
# it by path -- a touch by name, which publishes no open mark.  B's setattr
# then reads nlink 0 from the platter, B's iput is the last, and B frees the
# life.  A's own inactivation, queued at its unlink, takes EX only after that
# free; without the guard its local-unlink fast path trusts the in-core image,
# truncates a stale extent map, and the dead life's live core staged under
# RELFLUSH goes home at NL over B's free: an inobt-free inode with a LIVE core
# (P-FREE-LIVE-CORE, nlink 0) through a clean unmount.
# PREDICTION IF TRUE: with inact_local_epoch_guard=0 A's P-INACT-LOCAL-EPOCH
# lines read verdict=peer-freed and the cold audit finds P-FREE-LIVE-CORE; with
# =1 the same verdicts appear (inact_local_peerfreed > 0) and the audit is
# CLEAN.  IF FALSE: the control reaches peer-freed and still audits CLEAN.
#
# THE WINDOW.  On the rig A's inodegc runs within a jiffy of its unlink and B's
# lookup-to-lock gap is microseconds, so the guard's earlier A/B never reached
# its branch (inact_local_peerfreed 0 in every lap).  A loses the grant only
# while its unlinked inode is still live: from NEED_INACTIVE on, B's BAST is
# parked until A's inactivation ends.  The first version of this harness held
# A's inactivation itself and every lap was VACUOUS (hf6c: A logged
# P-NOINO-LIFECYCLE class=NEED_INACTIVE for each touched inode, then
# P-NOINO-LIFECYCLE-DONE).  ng0rf1 lost it between the unlink's commit and the
# final iput, serving B's queued EX in core.  Two test knobs hold that open on
# both nodes for the workload (read back, then 0 again before the cold audit):
# dbg_setattr_time_delay_ms holds B's touch after its lookup and before its
# first lock, so A's unlink lands inside it; dbg_unlink_live_delay_ms holds A's
# unlink after its commit with the inode still live, so B's setattr takes EX
# there, reads nlink 0 and frees before A's inactivation asks for EX.  Both
# arms run the same delays; only the guard differs.
#
# THE WORKLOAD, per iteration k in A's own directory: A writes f<k>, waits
# PLC_UNLINK_AFTER_MS, removes it, and waits PLC_GAP_MS before the next; B
# polls for the name and runs `touch -c` on it as soon as it appears, so the
# touch is asleep in its setattr delay when A's rm runs.  Each side logs one
# line per iteration (A: rm rc; B: whether it saw the name and the touch rc).
#
# THE GRADES
#   ABORT     prep, knob read-back or counter read failed
#   VACUOUS   no local-unlink inactivation found its grant lost since the
#             unlink with the peer's free on the platter (inact_local_peerfreed
#             0 on A): the window was not reached and the lap measured nothing
#   guard=0   the control: RESULT CONTROL-CORRUPT when the cold audit is
#             CORRUPT, CONTROL-CLEAN when it is CLEAN (that refutes H-F6 as a
#             cause of the shape once peerfreed > 0)
#   guard=1   PASS when the cold audit is CLEAN and neither node shut down,
#             withdrew, or logged BUG/Oops/hung task; FAIL otherwise
#
# Budgets (derived): prep and the cold audit are run.sh rows under their own
# manifest budgets (run.sh flips an overrun to FAIL itself, so no outer
# timeout).  An iteration is UNLINK_AFTER + one live-unlink delay + GAP at
# most, so the workload is bounded by ITERS x (UNLINK_AFTER + LIVE_DELAY +
# GAP) plus 60 s; counters and knob resets 20-40 s per node; the stream copy
# 120 s per node.
#
# THE SECOND A/B THIS WORKLOAD CARRIES (PLC_SANITIZE_GUARD set to 0 or 1), for
# D-CREATE-ON-ZOMBIE-SHELL-INHERITS-DEAD-LIFE-NBLOCKS.  With the guard above at 0
# every peer-freed verdict on A is followed by a reload that adopts B's free
# image (P116-ZOMBIE-ADOPT), which sets only the shell's generation and mode;
# A's next create of the number recycles that shell.  Lap q6dc1 (guard 0) put
# 'done' home with the dead f40 life's block count and no extents: B's lookups
# of it failed xfs_dinode_verify for the rest of the lap.  PLC_SANITIZE_GUARD
# sets module knob deadshell_sanitize_guard on both nodes (0 = the same-build
# control: the recycle resets only a shell that still has a mode) and zeroes and
# reads deadshell_stale_blocks (hazard), deadshell_stale_sanitized (reach) and
# create_nblocks_inherited (a create reaching xfs_inode_init with a block
# count, any path).  Its grades, on one line of their own (ZRESULT):
#   ZVACUOUS  guard 0 with deadshell_stale_blocks 0, or guard 1 with
#             deadshell_stale_sanitized 0, on A: the hazard was not offered
#   ZCONTROL  guard 0, reached: the counts and the corruption signals as found
#   ZPASS     guard 1, reached: create_nblocks_inherited 0 and no dinode verify
#             failure on either node, audit CLEAN, no node failure
#   ZFAIL     guard 1, reached, and any of those fails
# Unset, the knob keeps the module default and nothing of this is graded.
#
# THE BAST-WORKER ORDER (PLC_LASTREF_WAIT_MS > 0), for H-F6a.  In every lap of
# the delays above A's last reference is its unlink's own, so A inactivates as
# comm=rm, the truncate's ILOCK reloads the stale inode and adopts B's free
# (P116) before any truncate, and the guard=0 control audits CLEAN.  ng0rf1's
# inactivation ran on A's BAST worker instead: the work serving B's EX dropped
# A's last reference in its trailing irele, under its demoter claim, which the
# ILOCK hook admits with no reload, so the truncate ran on the dead life's map.
# PLC_LASTREF_WAIT_MS sets module knob dbg_bast_lastref_wait_ms on both nodes:
# that trailing irele, for an unlinked regular file the node removed, waits
# until the work's reference is the last (or that many ms).  Its reach, on A:
# bast_lastref_reached (the hold ended with the work's reference the last) and
# bast_ctx_peerfreed, the P-INACT-LOCAL-EPOCH verdict=peer-freed lines logged
# by a kworker; with the knob set, a lap with bast_ctx_peerfreed 0 is VACUOUS.
# Unset or 0, the knob stays 0 and the grades are the ones above.
#
# THE COPY-IN WINDOW (PLC_RELFLUSH_HOLD_MS > 0), for H-F6b.  The BAST order
# alone (lap lrc1: 19 peer-freed truncates on A's BAST worker, no reload)
# audited CLEAN: the truncate logs the dead life's core, but the
# inactivation's raw EX leaves i_dlm_mode at NL, so xfsaild's later flush is
# refused (P119-NONEX-FLUSH-SKIP) and the stale staging masked (P222).  In
# ng0rf1 xfsaild copied the core into its cluster buffer while the
# inactivation still held the RELFLUSH token (P240-COPYIN-ID, the truncate
# waiting at the AG seam).  PLC_RELFLUSH_HOLD_MS sets module knob
# dbg_inact_relflush_hold_ms on both nodes: after a local-unlink
# inactivation's truncate, with the token still set, the log is forced and the
# inode drained through the AIL (bounded by that many ms); A's count is
# inact_relflush_holds and its lines P-INACT-RELFLUSH-HOLD.  Every lap also
# counts P-DIALLOC-DISKLIVE on both nodes: an allocator finding a LIVE core on
# an inobt-free number, the in-run sign of the record's shape, which keeps
# that number out of circulation so the cold audit still sees it.
#
# B leaves its loop when the name 'done' is in the directory, read with ls -f
# (no stat): a 'done' whose core fails the verifier cannot be stat'ed, and q6dc1's
# toucher, testing it with -e, polled until its bound killed it and left the
# lap with no cold audit.
#
# Usage: tests/peer_last_closer_ab.sh <label> <guard 0|1> [iters=40] [config=2/net/mesh/direct] [group=g2]
# Env:   PLC_SETATTR_DELAY_MS (default 400), PLC_LIVE_DELAY_MS (default 1000),
#        PLC_UNLINK_AFTER_MS (default 150), PLC_GAP_MS (default 1500),
#        PLC_SANITIZE_GUARD (unset, 0 or 1; see above),
#        PLC_LASTREF_WAIT_MS (default 0 = off; see THE BAST-WORKER ORDER),
#        PLC_RELFLUSH_HOLD_MS (default 0 = off; see THE COPY-IN WINDOW)
# Exit 0 PASS / CONTROL-*, 1 FAIL, 2 ABORT, 3 VACUOUS.  With PLC_SANITIZE_GUARD
# set, a ZFAIL exits 1 whatever the first grade was.
set -u
LABEL=${1:?label}; GUARD=${2:?guard 0|1}; ITERS=${3:-40}
CONFIG=${4:-2/net/mesh/direct}; GROUP=${5:-g2}
SDELAY=${PLC_SETATTR_DELAY_MS:-400}; LDELAY=${PLC_LIVE_DELAY_MS:-1000}
UAFTER=${PLC_UNLINK_AFTER_MS:-150}; GAP=${PLC_GAP_MS:-1500}
ZGUARD=${PLC_SANITIZE_GUARD:-}; LRWAIT=${PLC_LASTREF_WAIT_MS:-0}; RHOLD=${PLC_RELFLUSH_HOLD_MS:-0}
case "$GUARD" in 0|1) ;; *) echo "guard must be 0 or 1"; exit 2 ;; esac
case "$ZGUARD" in ''|0|1) ;; *) echo "PLC_SANITIZE_GUARD must be unset, 0 or 1"; exit 2 ;; esac
for v in "$ITERS" "$SDELAY" "$LDELAY" "$UAFTER" "$GAP" "$LRWAIT" "$RHOLD"; do
    case "$v" in ''|*[!0-9]*) echo "iters and PLC_* values must be whole numbers"; exit 2 ;; esac
done
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
read -r A B rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${A:-}" ] && [ -n "${B:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
# run.sh holds the nodes only while it runs; between its calls the workload
# below is invisible to tools/vm_pool.sh, whose idle sweep would shut them off
. tests/lib/runlock.sh
vmhold_take "peer_last_closer_ab $LABEL" "$A" "$B" \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold $A $B"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_peer_last_closer_$LABEL
mkdir -p "$OUT"
MARK="PEER-LAST-CLOSER-$LABEL-$$"
P=/sys/module/mxfs/parameters
ICNTS="inact_local_epoch_moved inact_local_peerfreed"
ZCNTS="deadshell_stale_blocks deadshell_stale_sanitized create_nblocks_inherited"
LCNTS="bast_lastref_waits bast_lastref_reached"
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
echo "=== peer_last_closer_ab label=$LABEL guard=$GUARD iters=$ITERS setattr_delay=$SDELAY live_delay=$LDELAY unlink_after=$UAFTER gap=$GAP lastref_wait=$LRWAIT relflush_hold=$RHOLD $CONFIG $GROUP [$A $B] build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
want=$(modinfo -F srcversion mxfs.ko)
for n in $A $B; do
    sv=$(rs 20 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT label=$LABEL -- $n runs '$sv', not the tree build $want evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "echo $GUARD > $P/inact_local_epoch_guard; echo $SDELAY > $P/dbg_setattr_time_delay_ms; echo $LDELAY > $P/dbg_unlink_live_delay_ms; for c in $ICNTS; do echo 0 > $P/\$c; done; echo $MARK > /dev/kmsg; echo \$(cat $P/inact_local_epoch_guard)/\$(cat $P/dbg_setattr_time_delay_ms)/\$(cat $P/dbg_unlink_live_delay_ms)" | tail -1)
    [ "$got" = "$GUARD/$SDELAY/$LDELAY" ] || { echo "RESULT: ABORT label=$LABEL -- $n's inact_local_epoch_guard/dbg_setattr_time_delay_ms/dbg_unlink_live_delay_ms read '$got', not $GUARD/$SDELAY/$LDELAY (is the build missing a knob?) evidence=$OUT"; exit 2; }
    if [ -n "$ZGUARD" ]; then
        got=$(rs 20 "$n" "echo $ZGUARD > $P/deadshell_sanitize_guard; for c in $ZCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/deadshell_sanitize_guard)/\$(cat $P/deadshell_stale_blocks)/\$(cat $P/deadshell_stale_sanitized)/\$(cat $P/create_nblocks_inherited)" | tail -1)
        [ "$got" = "$ZGUARD/0/0/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's deadshell_sanitize_guard and its counters read '$got', not $ZGUARD/0/0/0 (is the build missing the knob?) evidence=$OUT"; exit 2; }
    fi
    if [ "$LRWAIT" != 0 ]; then
        got=$(rs 20 "$n" "echo $LRWAIT > $P/dbg_bast_lastref_wait_ms; for c in $LCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/dbg_bast_lastref_wait_ms)/\$(cat $P/bast_lastref_waits)/\$(cat $P/bast_lastref_reached)" | tail -1)
        [ "$got" = "$LRWAIT/0/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_bast_lastref_wait_ms and its counters read '$got', not $LRWAIT/0/0 (is the build missing the knob?) evidence=$OUT"; exit 2; }
    fi
    if [ "$RHOLD" != 0 ]; then
        got=$(rs 20 "$n" "echo $RHOLD > $P/dbg_inact_relflush_hold_ms; echo 0 > $P/inact_relflush_holds; echo \$(cat $P/dbg_inact_relflush_hold_ms)/\$(cat $P/inact_relflush_holds)" | tail -1)
        [ "$got" = "$RHOLD/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_inact_relflush_hold_ms and its counter read '$got', not $RHOLD/0 (is the build missing the knob?) evidence=$OUT"; exit 2; }
    fi
done
D=/mnt/shared/plc.$LABEL
rs 30 "$A" "mkdir -p $D && sync && echo ok" | grep -q ok || { echo "RESULT: ABORT label=$LABEL stage=mkdir evidence=$OUT"; exit 2; }

cat > "$OUT/unlinker.sh" <<EOF
for k in \$(seq 1 $ITERS); do
    echo "life \$k" > $D/f\$k
    sleep $(printf '%d.%03d' $((UAFTER / 1000)) $((UAFTER % 1000)))
    rm $D/f\$k; echo "iter \$k rm_rc=\$?"
    sleep $(printf '%d.%03d' $((GAP / 1000)) $((GAP % 1000)))
done
touch $D/done
echo "unlinker done iters=$ITERS"
EOF
# B touches every name the moment it first appears, whichever iteration A is
# on.  Waiting for f<k> in step with A drifted: one name missed while B was
# asleep in its setattr delay cost B the whole wait for it, and B then looked
# for names A had already removed (pwc1/pwf1: seen 9/40).
cat > "$OUT/toucher.sh" <<EOF
declare -A done_names
while ! ls -f $D 2>/dev/null | grep -qx done; do
    for f in $D/f*; do
        [ -e "\$f" ] || continue
        n=\${f##*/}
        [ -n "\${done_names[\$n]:-}" ] && continue
        done_names[\$n]=1
        touch -c "\$f" 2>/dev/null; echo "name \$n seen=1 touch_rc=\$?"
    done
    sleep 0.005
done
echo "toucher done names=\${#done_names[@]}"
EOF
WB=$((ITERS * (UAFTER + LDELAY + GAP) / 1000 + 60))
timeout $WB "$SSH" "$B" "bash -s" < "$OUT/toucher.sh" > "$OUT/${B}_toucher.out" 2>&1 & p2=$!
timeout $WB "$SSH" "$A" "bash -s" < "$OUT/unlinker.sh" > "$OUT/${A}_unlinker.out" 2>&1 & p1=$!
wait $p1; r1=$?; wait $p2; r2=$?
echo "workload rc: $A unlinker=$r1 $B toucher=$r2 (124 = overran ${WB}s)"
echo "  $A: rm ok $(grep -c 'rm_rc=0' "$OUT/${A}_unlinker.out")/$ITERS; $(tail -1 "$OUT/${A}_unlinker.out" | cut -c1-120)"
echo "  $B: seen $(grep -c 'seen=1' "$OUT/${B}_toucher.out")/$ITERS touch rc: $(grep -ao 'touch_rc=[0-9-]*' "$OUT/${B}_toucher.out" | sort | uniq -c | tr -s ' ' | paste -sd' ')"

tot_im=0; tot_ipf=0; a_pf=0; a_bpf=0; a_brl=0; tot_dl=0; a_pfh=0
declare -A nfail=()
for n in $A $B; do
    rs 40 "$n" "for c in $ICNTS $ZCNTS $LCNTS inact_relflush_holds inact_local_epoch_guard deadshell_sanitize_guard dbg_bast_lastref_wait_ms dbg_inact_relflush_hold_ms; do echo \$c=\$(cat $P/\$c 2>/dev/null); done; echo mounted=\$(grep -c ' /mnt/shared mxfs ' /proc/mounts); dmesg | sed -n '/$MARK/,\$p'" > "$OUT/${n}_kmsg.txt"
    im=$(sed -n 's/^inact_local_epoch_moved=//p' "$OUT/${n}_kmsg.txt"); ipf=$(sed -n 's/^inact_local_peerfreed=//p' "$OUT/${n}_kmsg.txt")
    ig=$(sed -n 's/^inact_local_epoch_guard=//p' "$OUT/${n}_kmsg.txt"); mnt=$(sed -n 's/^mounted=//p' "$OUT/${n}_kmsg.txt")
    [ -n "$im" ] && [ -n "$ipf" ] && [ -n "$mnt" ] || { echo "RESULT: ABORT label=$LABEL -- $n's counters did not read evidence=$OUT"; exit 2; }
    sd=$(grep -ac 'Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|BUG:\|Oops\|blocked for more than' "$OUT/${n}_kmsg.txt")
    echo "$n inact_local: guard=${ig:-?} moved=$im peerfreed=$ipf mounted=$mnt failure_lines=$sd"
    tot_im=$((tot_im + im)); tot_ipf=$((tot_ipf + ipf))
    [ "$n" = "$A" ] && a_pf=$ipf
    [ "$sd" = 0 ] && [ "$mnt" = 1 ] || nfail[$n]=1
done
for n in $A $B; do
    got=$(rs 20 "$n" "echo 0 > $P/dbg_setattr_time_delay_ms; echo 0 > $P/dbg_unlink_live_delay_ms; echo \$(cat $P/dbg_setattr_time_delay_ms)/\$(cat $P/dbg_unlink_live_delay_ms)" | tail -1)
    [ "$got" = 0/0 ] || echo "WARN $n's delay knobs read '$got' after the reset; the cold audit's unmount waits on them"
    if [ "$LRWAIT" != 0 ]; then
        got=$(rs 20 "$n" "echo 0 > $P/dbg_bast_lastref_wait_ms; cat $P/dbg_bast_lastref_wait_ms" | tail -1)
        [ "$got" = 0 ] || echo "WARN $n's dbg_bast_lastref_wait_ms read '$got' after the reset"
    fi
    if [ "$RHOLD" != 0 ]; then
        got=$(rs 20 "$n" "echo 0 > $P/dbg_inact_relflush_hold_ms; cat $P/dbg_inact_relflush_hold_ms" | tail -1)
        [ "$got" = 0 ] || echo "WARN $n's dbg_inact_relflush_hold_ms read '$got' after the reset"
    fi
done
a_lrw=$(sed -n 's/^bast_lastref_waits=//p' "$OUT/${A}_kmsg.txt"); a_lrr=$(sed -n 's/^bast_lastref_reached=//p' "$OUT/${A}_kmsg.txt")
a_rh=$(sed -n 's/^inact_relflush_holds=//p' "$OUT/${A}_kmsg.txt")

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
echo "audit P-FREE-LIVE-CORE lines: $(grep -ac 'P-FREE-LIVE-CORE' "$OUT/chk.log")"
grep -a 'P-FREE-LIVE-CORE' "$OUT/chk.log" | head -5 | cut -c1-240
# The lap's whole kernel log: the prep starts `dmesg --follow` into
# /root/dmesg.stream on every node and the next lap's prep replaces it.
for n in $A $B; do
    timeout 120 "$SSH" "$n" "gzip -c /root/dmesg.stream" < /dev/null 2>/dev/null > "$OUT/${n}_dmesg_stream.gz"
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'P-INACT-LOCAL-EPOCH \|P219-LOGGED-NO-AUTHORITY.* dlm_mode=0 stage_mode=0 .*relflush=0 demoter=0 ' > "$OUT/${n}_inact_local.txt"
    echo "$n kernel log: $OUT/${n}_dmesg_stream.gz marks=$(zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | grep -acF -- "$MARK") epoch verdicts: $(grep -ao 'verdict=[a-z-]*' "$OUT/${n}_inact_local.txt" | sort | uniq -c | tr -s ' ' | paste -sd' ') nl_staged_outside_drain=$(grep -ac 'P219-LOGGED-NO-AUTHORITY' "$OUT/${n}_inact_local.txt") peer_frees=$(zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" | grep -ac 'P9-NLEDGE from_disk')"
    # On TCP the unlinker meets ng0rf1's path only when it masters the
    # inode: the peer's release then hands EX back in its own table, with no
    # reload to adopt the peer's free (on CAW every acquire reloads).
    echo "$n master_handoffs=$(zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" | grep -ac 'P64-MASTER-HANDOFF ') zombie_adopts=$(zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" | grep -ac 'P116-ZOMBIE-ADOPT ')"
    # H-F6a's discriminator: the peer-freed verdicts by the context that ran
    # the inactivation (a kworker is the BAST work's trailing irele), and of
    # the BAST-context ones how many met a reload of the number (P116 or
    # P103-RELOAD-REUSE-ADOPT) within a second after the verdict
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'P-INACT-LOCAL-EPOCH \|P116-ZOMBIE-ADOPT \|P103-RELOAD-REUSE-ADOPT \|P-BAST-LASTREF-WAIT \|P-INACT-RELFLUSH-HOLD ' > "$OUT/${n}_bastctx.txt"
    # pfh: copy-in holds (P-INACT-RELFLUSH-HOLD) of a life this node's
    # inactivation had just judged peer-freed, i.e. the dead life's truncated
    # core drained home under the token
    read -r bpf opf brl lrl pfh <<< "$(python3 - "$OUT/${n}_bastctx.txt" <<'PY'
import re, sys
bast = {}; other = 0; reached = 0; freed = set(); pfh = 0
for line in open(sys.argv[1], errors="replace"):
    t = re.match(r"\[\s*(\d+\.\d+)\]", line)
    ts = float(t.group(1)) if t else None
    if "P-BAST-LASTREF-WAIT " in line:
        reached += " reached=1 " in line
        continue
    m = re.search(r"P-INACT-RELFLUSH-HOLD ino=(\d+) gen=(\d+) ", line)
    if m:
        pfh += (m.group(1), m.group(2)) in freed
        continue
    m = re.search(r"P-INACT-LOCAL-EPOCH ino=(\d+) gen=(\d+) .* verdict=peer-freed guard=\d comm=(\S+)", line)
    if m:
        freed.add((m.group(1), m.group(2)))
        if m.group(3).startswith("kworker"):
            bast.setdefault(m.group(1), []).append([ts, 0])
        else:
            other += 1
        continue
    m = re.search(r"(?:P116-ZOMBIE-ADOPT|P103-RELOAD-REUSE-ADOPT) ino=(\d+) ", line)
    if m and ts is not None:
        for v in bast.get(m.group(1), []):
            if v[0] is not None and 0 <= ts - v[0] <= 1.0:
                v[1] += 1
n = sum(len(v) for v in bast.values())
r = sum(1 for v in bast.values() for e in v if e[1])
print(n, other, r, reached, pfh)
PY
)"
    echo "$n inactivation context: bast_ctx_peerfreed=${bpf:-?} other_ctx_peerfreed=${opf:-?} bast_ctx_reloaded=${brl:-?} lastref_reached_lines=${lrl:-?} peerfreed_holds=${pfh:-?} ($OUT/${n}_bastctx.txt)"
    [ "$n" = "$A" ] && { a_bpf=${bpf:-0}; a_brl=${brl:-0}; a_pfh=${pfh:-0}; }
    # the copy-in window's reach, and the in-run sign of the shape
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'P-INACT-RELFLUSH-HOLD \|P-DIALLOC-DISKLIVE' > "$OUT/${n}_copyin.txt"
    dl=$(grep -ac 'P-DIALLOC-DISKLIVE' "$OUT/${n}_copyin.txt")
    echo "$n copy-in: relflush_hold_lines=$(grep -ac 'P-INACT-RELFLUSH-HOLD ' "$OUT/${n}_copyin.txt") landed=$(grep -ac 'P-INACT-RELFLUSH-HOLD .* landed=1 ' "$OUT/${n}_copyin.txt") disklive=$dl ($OUT/${n}_copyin.txt)"
    tot_dl=$((tot_dl + dl))
    # node failures from the whole log after this lap's mark: the ring read
    # after the workload keeps only what the ring still held, and a mid-lap
    # shutdown can rotate out of it (fxdp2's was in the stream only)
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|P-INODE-WEDGE \|P-SESSION-POISON\|BUG:\|Oops\|blocked for more than' > "$OUT/${n}_failures.txt"
    sds=$(wc -l < "$OUT/${n}_failures.txt")
    echo "$n stream failure lines: $sds ($OUT/${n}_failures.txt)"
    head -3 "$OUT/${n}_failures.txt" | cut -c1-300
    [ "$sds" = 0 ] || nfail[$n]=1
    if [ -n "$ZGUARD" ]; then
        zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
            | grep -a 'P-RECYCLE-DEADSHELL-STALE \|P-CREATE-NBLOCKS-INHERITED \|P-RECYCLE-SANITIZE \|Metadata corruption detected at xfs_dinode_verify\|P-SFV-FAIL ' > "$OUT/${n}_zshell.txt"
        zsb=$(sed -n 's/^deadshell_stale_blocks=//p' "$OUT/${n}_kmsg.txt"); zss=$(sed -n 's/^deadshell_stale_sanitized=//p' "$OUT/${n}_kmsg.txt")
        zci=$(sed -n 's/^create_nblocks_inherited=//p' "$OUT/${n}_kmsg.txt"); zg=$(sed -n 's/^deadshell_sanitize_guard=//p' "$OUT/${n}_kmsg.txt")
        zvf=$(grep -ac 'Metadata corruption detected at xfs_dinode_verify' "$OUT/${n}_zshell.txt")
        echo "$n zombie shell: guard=${zg:-?} stale_blocks=${zsb:-?} sanitized=${zss:-?} nblocks_inherited=${zci:-?} lines: stale=$(grep -ac 'P-RECYCLE-DEADSHELL-STALE ' "$OUT/${n}_zshell.txt") inherited=$(grep -ac 'P-CREATE-NBLOCKS-INHERITED ' "$OUT/${n}_zshell.txt") sanitize=$(grep -ac 'P-RECYCLE-SANITIZE ' "$OUT/${n}_zshell.txt") dinode_verify_fail=$zvf ($OUT/${n}_zshell.txt)"
        printf '%s %s %s %s %s\n' "$n" "${zsb:-x}" "${zss:-x}" "${zci:-x}" "$zvf" >> "$OUT/zshell_counts.txt"
    fi
done
bad=${#nfail[@]}
case "$audit" in
    CORRUPT*)
        # run.sh's chk.log only names the audit's own log (evidence=, a path
        # under the nodes' /src, which is this host's ~/src); the error lines
        # are there.  It is kept here as chk_audit.log.
        alog=$(grep -ao 'evidence=/src/[^ ]*chk_clean_[0-9]*node_[0-9TZ]*\.log' "$OUT/chk.log" | head -1 | sed "s#^evidence=/src/#$HOME/src/#")
        if [ -n "$alog" ] && [ -r "$alog" ]; then
            cp "$alog" "$OUT/chk_audit.log"
        else
            echo "WARN the audit log named by $OUT/chk.log ('${alog:-none named}') is not readable here; no inode can be attributed"
        fi
        grep -a 'ERROR' "$OUT/chk_audit.log" 2>/dev/null | head -8 | cut -c1-240
        inos=$(cat "$OUT/chk.log" "$OUT/chk_audit.log" 2>/dev/null | grep -ao '(ino [0-9]*)' | tr -dc '0-9\n' | sort -u | paste -sd' ')
        echo "audited inodes: ${inos:-none parsed}"
        for n in $A $B; do
            : > "$OUT/${n}_audited_inos.txt"
            for i in $inos; do
                zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | grep -a "ino=$i \|ino=$i\$" >> "$OUT/${n}_audited_inos.txt"
            done
            echo "$n audited-inode lines: $(wc -l < "$OUT/${n}_audited_inos.txt") ($OUT/${n}_audited_inos.txt)"
        done ;;
esac

ZEXIT=0
if [ -n "$ZGUARD" ]; then
    # columns: node stale_blocks sanitized nblocks_inherited dinode_verify_fail
    read -r _ za_sb za_ss _ _ <<< "$(grep "^$A " "$OUT/zshell_counts.txt" 2>/dev/null)"
    zinh=$(awk '{s += ($4 ~ /^[0-9]+$/ ? $4 : 0)} END {print s + 0}' "$OUT/zshell_counts.txt" 2>/dev/null)
    zvf=$(awk '{s += $5} END {print s + 0}' "$OUT/zshell_counts.txt" 2>/dev/null)
    znbm=$(cat "$OUT/chk.log" "$OUT/chk_audit.log" 2>/dev/null | grep -ac 'P-NBLOCKS-MISMATCH')
    ZREP="sanitize_guard=$ZGUARD a_stale_blocks=${za_sb:-?} a_sanitized=${za_ss:-?} nblocks_inherited=$zinh dinode_verify_fail=$zvf audit_nblocks_mismatch=$znbm audit=$audit node_failures=$bad"
    case "${za_sb:-x}${za_ss:-x}" in *[!0-9]*) za_sb=x ;; esac
    case "$ZGUARD/${za_sb}/${za_ss:-x}" in
        */x/*) zv=ZABORT; ZEXIT=2 ;;
        0/0/*|1/*/0) zv=ZVACUOUS ;;
        0/*) zv=ZCONTROL ;;
        *)  case "$audit" in CLEAN*) zaok=1 ;; *) zaok=0 ;; esac
            if [ "$zinh" = 0 ] && [ "$zvf" = 0 ] && [ "$zaok" = 1 ] && [ "$bad" = 0 ]; then
                zv=ZPASS
            else
                zv=ZFAIL; ZEXIT=1
            fi ;;
    esac
    echo "ZRESULT: $zv label=$LABEL $ZREP evidence=$OUT"
fi
REP="guard=$GUARD iters=$ITERS setattr_delay=$SDELAY live_delay=$LDELAY inact_moved=$tot_im inact_peerfreed=$tot_ipf unlinker_peerfreed=$a_pf"
[ "$LRWAIT" != 0 ] && REP="$REP lastref_wait=$LRWAIT lastref_waits=${a_lrw:-?} lastref_reached=${a_lrr:-?} bast_ctx_peerfreed=$a_bpf bast_ctx_reloaded=$a_brl"
[ "$RHOLD" != 0 ] && REP="$REP relflush_hold=$RHOLD relflush_holds=${a_rh:-?} peerfreed_holds=$a_pfh"
REP="$REP disklive=$tot_dl"
if [ "$a_pf" = 0 ]; then
    echo "RESULT: VACUOUS peer_last_closer_ab label=$LABEL $REP audit=$audit node_failures=$bad -- no local-unlink inactivation on $A found the peer's free on the platter evidence=$OUT"; exit 3
fi
if [ "$LRWAIT" != 0 ] && [ "$a_bpf" = 0 ]; then
    echo "RESULT: VACUOUS peer_last_closer_ab label=$LABEL $REP audit=$audit node_failures=$bad -- no peer-freed inactivation on $A ran on its BAST worker evidence=$OUT"; exit 3
fi
# the control's truncate of a peer-freed life is what the copy-in window
# drains; the fix arm skips that truncate by design, so its reach is the above
if [ "$RHOLD" != 0 ] && [ "$GUARD" = 0 ] && [ "$a_pfh" = 0 ]; then
    echo "RESULT: VACUOUS peer_last_closer_ab label=$LABEL $REP audit=$audit node_failures=$bad -- no peer-freed truncate on $A was drained under the token evidence=$OUT"; exit 3
fi
if [ "$GUARD" = 0 ]; then
    case "$audit" in CORRUPT*) v=CONTROL-CORRUPT ;; CLEAN*) v=CONTROL-CLEAN ;; *) v=CONTROL-NO-AUDIT ;; esac
    echo "RESULT: $v peer_last_closer_ab label=$LABEL $REP audit=$audit node_failures=$bad evidence=$OUT"; exit $ZEXIT
fi
case "$audit" in CLEAN*) aok=1 ;; *) aok=0 ;; esac
# a live core found on an inobt-free number during the lap is the shape even
# when a later life of the number hid it from the audit
if [ "$aok" = 1 ] && [ "$bad" = 0 ] && [ "$tot_dl" = 0 ]; then
    echo "RESULT: PASS peer_last_closer_ab label=$LABEL $REP audit=$audit evidence=$OUT"; exit $ZEXIT
fi
echo "RESULT: FAIL peer_last_closer_ab label=$LABEL $REP audit=$audit node_failures=$bad evidence=$OUT"; exit 1
