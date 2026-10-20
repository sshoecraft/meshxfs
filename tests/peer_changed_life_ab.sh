#!/bin/bash
# tests/peer_changed_life_ab.sh — same-build A/B of the changecount arm of the
# local-unlink inactivation guard (module knob inact_local_cc_guard) on a
# workload where a peer changes a life one node unlinked, truncates it and
# leaves it on the unlinker's bucket, for
# D-LOCAL-UNLINK-INACT-AFTER-GRANT-LOSS-WRITES-STALE-CORE-OVER-PEER-CHANGE (H-LU1).
#
# H-LU1, written on the record before this harness (from fv3c4, ino 131): an
# unlinker that lost its grant since the unlink inactivates on its BAST worker,
# whose truncate ILOCK takes no reload.  The moved-epoch arm reads the platter's
# mode and generation only, so a peer's change of the same life reads as 'ours';
# the truncate then frees the unrefreshed extent map (blocks the peer had already
# freed: P3-SKIP-DBLFREE) and logs the unrefreshed core, which a deferred free's
# drain puts home over the peer's newer image (P-DINO-CLOBBER regress).
# PREDICTION IF TRUE: with inact_local_cc_guard=0 the unlinker's peer-changed
# verdicts (P-INACT-LOCAL-EPOCH verdict=peer-changed) are followed by a truncate
# of that life with stale=1 (P3-EFREE-Q); with =1 every such verdict defers the
# free (inact_local_cc_deferred), no stale truncate, no double free and no
# regress follows, the reaper frees each deferred life, and the audit is CLEAN.
# IF FALSE: the control reaches peer-changed and no stale truncate follows.
#
# THE SHAPE, per iteration k in A's directory (A the unlinker, B the peer):
#   A writes aux/g<k> (4 KiB) and f<k> (64 KiB), each fsync'd, f<k>'s number
#     chosen so that ino % 64 is not A's unlinked bucket: B's free of f<k> then
#     finds the bucket it computes empty and f<k> no bucket's head, and skips
#     (IFREE-REVALIDATE-SKIP why=bucket-empty-peer-freeing, fv3c4's skip);
#   B opens f<k> and holds it (h<k>);
#   A opens aux/g<k> on fd 6, creates r<k>, removes f<k> in the background (the
#     unlink commits, then dbg_unlink_live_delay_ms holds the rm's reference)
#     and, once that rm's kernel stack shows the delay's msleep (the unlink has
#     committed), removes aux/g<k> in the background, so g<k> heads A's bucket
#     ahead of f<k>.  g<k> lives in a subdirectory because the VFS holds the
#     parent's lock across the live delay: a second remove in the same
#     directory waits out the first one's whole delay (lap pclc2: rm_ms 6.1 s
#     with a 3 s delay).  Testing f<k>'s name instead is no signal: the lookup
#     waits on that same parent lock and answers only after the delay (pclc2:
#     gone_rounds=1 inside a 6.1 s rm), which put g<k> behind B's free;
#   The delay holds every local unlink of a regular file, so A leaves the
#     signal files (go/h/r/c) in place: removing four per iteration cost 12 s
#     an iteration in lap pclc2;
#   B, on r<k>, waits until f<k>'s name is gone (A's unlink committed), then
#     PCL_PEER_WAIT_MS more, which takes its request past the 300 ms minimum
#     hold of A's fresh EX (mxfs_inode_mht_ms: a request inside it is served by
#     the MHT timer's work, which carries no last-reference hold: lap pclc1,
#     qsrc=9), sets f<k>'s times through its descriptor (the setattr's EX is
#     served by A's BAST work, which drains and demotes: A's grant is lost),
#     closes it and stats the name, which drops B's last reference: B's
#     inactivation holds the EX, truncates f<k> and skips the free.  A delay
#     inside B's setattr does not order it after the unlink: the unlink waits
#     for it (lap pclc2, dbg_setattr_time_delay_ms 1200: B's change landed
#     first in 10 of 12 iterations);
#   A's rm wakes and drops its reference.  dbg_bast_lastref_wait_ms has held the
#     BAST work's trailing irele until then, so the work drops A's last
#     reference and A inactivates f<k> on its BAST worker (fv3c4's context): the
#     raw EX pulls B's truncated image home and the moved-epoch arm reads it.
#   Then A waits for that inactivation, closes fd 6 and g<k> is freed.
# A logs one line per iteration (inode numbers, rm rc, waits); B one line per
# iteration (whether it saw r<k>, the setattr and close errno, stat's errno).
#
# THE GRADES
#   ABORT     prep, srcversion, knob read-back or counter read failed
#   VACUOUS   no peer-changed verdict on A (inact_local_peerchanged 0): the
#             shape was not reached and the lap measured nothing
#   guard 0   CONTROL-SHOWS-CAUSE when a peer-changed life on A was then
#             truncated on its unrefreshed map: P3-EFREE-Q of that life with
#             stale=1 (printed for AG 0 extents only), a P3-SKIP-DBLFREE on A
#             (the free of blocks the peer already freed; any AG, ratelimited),
#             or a P-DINO-CLOBBER regress naming an iteration inode;
#             CONTROL-NO-STALE-TRUNCATE otherwise (that refutes H-LU1's
#             mechanism once reached)
#   guard 1   PASS when every peer-changed verdict on A deferred
#             (inact_local_cc_deferred = inact_local_peerchanged), no
#             peer-changed life was truncated stale, A logged no
#             P3-SKIP-DBLFREE, neither node logged a P-DINO-CLOBBER regress or a
#             node failure, A's reaper ended with no entry left, and the cold
#             audit is CLEAN errors=0; FAIL otherwise
#
# Budgets (derived): prep and the cold audit are run.sh rows under their own
# manifest budgets (run.sh flips an overrun to FAIL itself, so no outer
# timeout).  An iteration: the creates and fsyncs 1 s, at most 5 s for B's h<k>,
# the live delay (PCL_LIVE_DELAY_MS), at most 5 s for the name to go, 3 s for
# the BAST-worker inactivation (fv3c4's took 309 ms with a 291 ms EX wait),
# PCL_SYNCS cache drops 0.3 s apart and 1 s for the markers: bounded by
# ITERS x (15 + LIVE/1000 + SYNCS x 0.3) + 60 s.  The settle covers the reaper's
# first retry (MXFS_REAP_FIRST_MS, 5 s), one transient-keep requeue
# (MXFS_REAP_RETRY_MS, 30 s) and 5 s for the free: 40 s.  The wait for the
# reaper's report of an empty list: two re-runs 30 s apart and 10 s, 70 s of
# wall, plus the last poll's 20 s ssh step: 90 s.  Counters and knob resets
# 20-40 s per node; the stream copy 120 s per node.
#
# Usage: tests/peer_changed_life_ab.sh <label> <guard 0|1> [iters=20] [config=2/disk/caw/direct] [group=g2]
# Env:   PCL_PEER_WAIT_MS (default 500), PCL_LIVE_DELAY_MS (default 3000),
#        PCL_LASTREF_WAIT_MS (default 4500), PCL_SYNCS (default 3),
#        PCL_SETTLE_S (default 40), PCL_REAP_WAIT_S (default 70)
# Exit 0 PASS / CONTROL-*, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; GUARD=${2:?guard 0|1}; ITERS=${3:-20}
CONFIG=${4:-2/disk/caw/direct}; GROUP=${5:-g2}
PWAIT=${PCL_PEER_WAIT_MS:-500}; LDELAY=${PCL_LIVE_DELAY_MS:-3000}
LRWAIT=${PCL_LASTREF_WAIT_MS:-4500}; SYNCS=${PCL_SYNCS:-3}; SETTLE=${PCL_SETTLE_S:-40}
REAPWAIT=${PCL_REAP_WAIT_S:-70}
case "$GUARD" in 0|1) ;; *) echo "guard must be 0 or 1"; exit 2 ;; esac
for v in "$ITERS" "$PWAIT" "$LDELAY" "$LRWAIT" "$SYNCS" "$SETTLE" "$REAPWAIT"; do
    case "$v" in ''|*[!0-9]*) echo "iters and PCL_* values must be whole numbers"; exit 2 ;; esac
done
[ "$LRWAIT" -gt "$LDELAY" ] || { echo "PCL_LASTREF_WAIT_MS must exceed PCL_LIVE_DELAY_MS: the BAST work must still hold its reference when the rm drops its own"; exit 2; }
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
read -r A B rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${A:-}" ] && [ -n "${B:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
# run.sh holds the nodes only while it runs; between its calls the workload
# below is invisible to tools/vm_pool.sh, whose idle sweep would shut them off
. tests/lib/runlock.sh
vmhold_take "peer_changed_life_ab $LABEL" "$A" "$B" \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold $A $B"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_peer_changed_life_$LABEL
mkdir -p "$OUT"
MARK="PEER-CHANGED-LIFE-$LABEL-$$"
P=/sys/module/mxfs/parameters
CNTS="inact_local_epoch_moved inact_local_peerfreed inact_local_peerchanged inact_local_cc_deferred bast_lastref_waits bast_lastref_reached"
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
echo "=== peer_changed_life_ab label=$LABEL guard=$GUARD iters=$ITERS peer_wait=$PWAIT live_delay=$LDELAY lastref_wait=$LRWAIT syncs=$SYNCS settle_s=$SETTLE $CONFIG $GROUP [$A $B] build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
want=$(modinfo -F srcversion mxfs.ko)
for n in $A $B; do
    sv=$(rs 20 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT label=$LABEL -- $n runs '$sv', not the tree build $want evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "echo $GUARD > $P/inact_local_cc_guard; echo 0 > $P/dbg_setattr_time_delay_ms; echo $LDELAY > $P/dbg_unlink_live_delay_ms; echo $LRWAIT > $P/dbg_bast_lastref_wait_ms; for c in $CNTS; do echo 0 > $P/\$c; done; echo $MARK > /dev/kmsg; echo \$(cat $P/inact_local_cc_guard)/\$(cat $P/inact_local_epoch_guard)/\$(cat $P/dbg_setattr_time_delay_ms)/\$(cat $P/dbg_unlink_live_delay_ms)/\$(cat $P/dbg_bast_lastref_wait_ms)" | tail -1)
    [ "$got" = "$GUARD/1/0/$LDELAY/$LRWAIT" ] || { echo "RESULT: ABORT label=$LABEL -- $n's inact_local_cc_guard/inact_local_epoch_guard/dbg_setattr_time_delay_ms/dbg_unlink_live_delay_ms/dbg_bast_lastref_wait_ms read '$got', not $GUARD/1/0/$LDELAY/$LRWAIT (is the build missing a knob?) evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "cd $P && for c in $CNTS; do printf '%s=%s ' \$c \"\$(cat \$c 2>/dev/null)\"; done; echo" | tail -1)
    for kv in $got; do
        case "$kv" in *=0) ;; *) echo "RESULT: ABORT label=$LABEL -- $n's counter $kv did not reset to 0 evidence=$OUT"; exit 2 ;; esac
    done
done
D=/mnt/shared/pcl.$LABEL
rs 30 "$A" "mkdir -p $D/aux && sync && echo ok" | grep -q ok || { echo "RESULT: ABORT label=$LABEL stage=mkdir evidence=$OUT"; exit 2; }

# A's own unlinked bucket, from the P82-ADD line of a remove of a file it holds
# open (capped at 300 a module load; the prep has just reloaded the module).  B
# computes ino % 64 for a number it did not unlink, so f<k> must avoid A's
# bucket, the one bucket that is not empty while B frees.
cat > "$OUT/unlinker.sh" <<EOF
D=$D
head -c 4096 /dev/urandom > \$D/cal || { echo "unlinker calibration create_failed"; touch \$D/done; exit 2; }
ci=\$(stat -c %i \$D/cal); exec 4< \$D/cal; rm \$D/cal; exec 4<&-
BK=\$(dmesg | grep -a "P82-ADD ino=\$ci " | tail -1 | sed -n 's/.* bucket=\([0-9]*\) .*/\1/p')
[ -n "\$BK" ] || { echo "unlinker calibration: no P82-ADD line for ino \$ci"; touch \$D/done; exit 2; }
echo "unlinker bucket=\$BK (P82-ADD of ino \$ci)"
ok=0; noack=0; fill=0
for k in \$(seq 1 $ITERS); do
    tc=\$(date +%s%N)
    head -c 4096 /dev/urandom > \$D/aux/g\$k && sync -d \$D/aux/g\$k || { echo "iter \$k create_failed"; break; }
    m=0
    while :; do
        head -c 65536 /dev/urandom > \$D/f\$k && sync -d \$D/f\$k || { echo "iter \$k create_failed"; break 2; }
        fi=\$(stat -c %i \$D/f\$k)
        [ \$((fi % 64)) != "\$BK" ] && break
        m=\$((m + 1)); fill=\$((fill + 1)); mv \$D/f\$k \$D/x\$fill
    done
    gi=\$(stat -c %i \$D/aux/g\$k)
    touch \$D/go\$k
    w=0
    until [ -e \$D/h\$k ] || [ \$w -ge 100 ]; do sleep 0.05; w=\$((w + 1)); done
    if [ ! -e \$D/h\$k ]; then
        noack=\$((noack + 1)); echo "iter \$k f=\$fi g=\$gi noack"
        rm -f \$D/f\$k \$D/aux/g\$k \$D/go\$k; continue
    fi
    exec 6< \$D/aux/g\$k
    touch \$D/r\$k
    t0=\$(date +%s%N)
    rm \$D/f\$k & pf=\$!
    w2=0
    until grep -q msleep /proc/\$pf/stack 2>/dev/null || [ \$w2 -ge 100 ]; do sleep 0.02; w2=\$((w2 + 1)); done
    ts=\$(date +%s%N)
    rm \$D/aux/g\$k & pg=\$!
    wait \$pf; rf=\$?; wait \$pg; rg=\$?
    t1=\$(date +%s%N)
    sleep 3
    exec 6<&-
    s=0
    while [ \$s -lt $SYNCS ]; do sleep 0.3; echo 2 > /proc/sys/vm/drop_caches; s=\$((s + 1)); done
    ok=\$((ok + 1))
    echo "iter \$k f=\$fi g=\$gi f_misses=\$m rm_f=\$rf rm_g=\$rg ack_rounds=\$w slp_rounds=\$w2 slp_ms=\$(( (ts - t0) / 1000000 )) rm_ms=\$(( (t1 - t0) / 1000000 )) iter_ms=\$(( (\$(date +%s%N) - tc) / 1000000 ))"
done
touch \$D/done
echo "unlinker done iters=$ITERS ok=\$ok noack=\$noack fill=\$fill bucket=\$BK"
EOF
# B leaves its loop when the name 'done' is in the directory, read with ls -f
# (no stat), as tests/peer_last_closer_ab.sh's toucher does.
cat > "$OUT/peer.sh" <<EOF
D=$D
k=1; held=0; fails=0
while ! ls -f \$D 2>/dev/null | grep -qx done; do
    if ! ls -f \$D 2>/dev/null | grep -qx "go\$k"; then sleep 0.02; continue; fi
    python3 - \$D \$k $PWAIT <<'PY'
import errno, os, sys, time
d, k, pwait = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    fd = os.open("%s/f%s" % (d, k), os.O_RDONLY)
except OSError as e:
    print("peer iter %s open_failed errno=%d" % (k, e.errno)); sys.exit(1)
open("%s/h%s" % (d, k), "w").close()
end = time.time() + 10
while not os.path.exists("%s/r%s" % (d, k)) and time.time() < end:
    time.sleep(0.01)
seen = os.path.exists("%s/r%s" % (d, k))
# the unlink has committed once the name is gone from the directory
t0 = time.time(); end = t0 + 10
while ("f%s" % k) in os.listdir(d) and time.time() < end:
    time.sleep(0.01)
gone_ms = (time.time() - t0) * 1000
time.sleep(pwait / 1000.0)
t = time.time(); urc = 0
try:
    os.utime(fd)
except OSError as e:
    urc = e.errno
u_ms = (time.time() - t) * 1000
xrc = 0
try:
    os.close(fd)
except OSError as e:
    xrc = e.errno
src = 0
try:
    os.stat("%s/f%s" % (d, k))
except OSError as e:
    src = e.errno
try:
    open("%s/c%s" % (d, k), "w").close()
except OSError:
    pass
print("peer iter %s r_seen=%d gone_ms=%.0f utime_errno=%d utime_ms=%.0f close_errno=%d stat_errno=%d" % (k, int(seen), gone_ms, urc, u_ms, xrc, src))
PY
    if [ \$? = 0 ]; then held=\$((held + 1)); else fails=\$((fails + 1)); fi
    k=\$((k + 1))
done
echo "peer done held=\$held open_failed=\$fails"
EOF
WB=$((ITERS * (15 + LDELAY / 1000 + (SYNCS * 300 + 999) / 1000) + 60))
echo "workload bound ${WB}s"
timeout $((WB + 10)) "$SSH" "$B" "bash -s" < "$OUT/peer.sh" > "$OUT/${B}_peer.out" 2>&1 & p2=$!
timeout $WB "$SSH" "$A" "bash -s" < "$OUT/unlinker.sh" > "$OUT/${A}_unlinker.out" 2>&1; r1=$?
# an unlinker that died leaves no 'done'; B leaves on it either way
rs 20 "$A" "touch $D/done" > /dev/null
wait $p2; r2=$?
okn=$(grep -a '^unlinker done ' "$OUT/${A}_unlinker.out" | grep -o ' ok=[0-9]*' | cut -d= -f2)
echo "workload rc: $A unlinker=$r1 $B peer=$r2 (124 = overran)"
echo "  $A: $(grep -a '^unlinker bucket\|^unlinker done' "$OUT/${A}_unlinker.out" | paste -sd' ' | cut -c1-200)"
echo "  $B: $(tail -1 "$OUT/${B}_peer.out" | cut -c1-120); utime errno: $(grep -ao 'utime_errno=[0-9]*' "$OUT/${B}_peer.out" | sort | uniq -c | tr -s ' ' | paste -sd' ') stat errno: $(grep -ao 'stat_errno=[0-9]*' "$OUT/${B}_peer.out" | sort | uniq -c | tr -s ' ' | paste -sd' ')"
# the iteration inodes, for the per-life grading below
grep -ao '^iter [0-9]* f=[0-9]*' "$OUT/${A}_unlinker.out" | sed 's/.* f=//' > "$OUT/f_inos.txt"

# the reaper's first retry and one requeue (see the budget above)
sleep "$SETTLE"
# Then the reaper's own report that it is empty.  Its exit line counts an
# entry whose inactivation that pass has just started (xfs/xfs_mxfs_evict.c
# mxfs_reap_worker requeues the entry before its xfs_irele, and
# mxfs_defer_reap_done retires it when the free commits), so 'entries=1'
# followed by that entry's P89-REAP-DONE is a reaper that finished without
# saying so.  It runs again MXFS_REAP_RETRY_MS (30 s) after an exit that left
# entries, and that pass reports the count.  Laps pct2, pca4 and pct4 read
# FAIL on reap_last_entries=1 alone: each counted entry's DONE line came
# 10 ms after the exit line, and the re-run fell after the stream copy.  Wait
# for an exit line after the mark that reads entries=0, at most PCL_REAP_WAIT_S
# (two re-runs and 10 s).
rw0=$SECONDS
while :; do
    re=$(rs 20 "$A" "sed -n '/$MARK/,\$p' /root/dmesg.stream | grep -a 'P89-REAP-DUTY duty=exit' | tail -1 | grep -ao 'entries=[0-9-]*'" | tail -1)
    case "$re" in ''|entries=0) break ;; esac
    [ $((SECONDS - rw0)) -ge "$REAPWAIT" ] && break
    sleep 5
done
echo "reaper report: last exit ${re:-none} after $((SECONDS - rw0))s of the ${REAPWAIT}s wait"
declare -A cnt=() nfail=()
for n in $A $B; do
    cnt[$n]=$(rs 20 "$n" "cd $P && for c in $CNTS; do printf '%s=%s ' \$c \"\$(cat \$c 2>/dev/null || echo ?)\"; done; echo mounted=\$(grep -c ' /mnt/shared mxfs ' /proc/mounts)" | tail -1)
    echo "${cnt[$n]}" > "$OUT/${n}_counters.txt"
    echo "$n counters: ${cnt[$n]}"
done
cget() { printf '%s\n' "${cnt[$1]}" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
for n in $A $B; do
    got=$(rs 20 "$n" "echo 0 > $P/dbg_setattr_time_delay_ms; echo 0 > $P/dbg_unlink_live_delay_ms; echo 0 > $P/dbg_bast_lastref_wait_ms; echo \$(cat $P/dbg_setattr_time_delay_ms)/\$(cat $P/dbg_unlink_live_delay_ms)/\$(cat $P/dbg_bast_lastref_wait_ms)" | tail -1)
    [ "$got" = 0/0/0 ] || echo "WARN $n's delay knobs read '$got' after the reset; the cold audit's unmount waits on them"
done

# Each node's whole kernel log after the mark: the prep starts `dmesg --follow`
# into /root/dmesg.stream on every node and the next lap's prep replaces it.
for n in $A $B; do
    timeout 120 "$SSH" "$n" "gzip -c /root/dmesg.stream" < /dev/null 2>/dev/null > "$OUT/${n}_dmesg_stream.gz"
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" > "$OUT/${n}_lap.txt"
    echo "$n kernel log: $OUT/${n}_dmesg_stream.gz marks=$(grep -acF -- "$MARK" "$OUT/${n}_lap.txt") lines_after_mark=$(wc -l < "$OUT/${n}_lap.txt")"
    grep -a 'Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|P-INODE-WEDGE \|P-SESSION-POISON\|BUG:\|Oops\|blocked for more than' "$OUT/${n}_lap.txt" > "$OUT/${n}_failures.txt"
    sds=$(wc -l < "$OUT/${n}_failures.txt")
    echo "$n stream failure lines: $sds ($OUT/${n}_failures.txt)"
    head -3 "$OUT/${n}_failures.txt" | cut -c1-300
    mnt=$(cget "$n" mounted)
    [ "$sds" = 0 ] && [ "${mnt:-0}" = 1 ] || nfail[$n]=1
    grep -a 'P-INACT-LOCAL-EPOCH \|P3-EFREE-Q \|P3-SKIP-DBLFREE \|P-DINO-CLOBBER#\|IFREE-REVALIDATE-SKIP \|P89-REAP-DUTY duty=exit \|P88-REAP-RETRY \|P89-REAP-DONE \|P-BAST-LASTREF-WAIT ' "$OUT/${n}_lap.txt" > "$OUT/${n}_hlu1.txt"
done
# Per node: the epoch verdicts; on A the peer-changed lives by context, the
# stale truncates of those lives (P3-EFREE-Q of the same ino and gen with
# stale=1 after the verdict), the double frees skipped, the regresses that name
# an iteration inode, the peer's bucket-empty skips, and the reaper's last
# entry count.
declare -A G=()
for n in $A $B; do
    G[$n]=$(python3 - "$OUT/${n}_hlu1.txt" "$OUT/f_inos.txt" <<'PY'
import re, sys
fino = set(l.strip() for l in open(sys.argv[2]) if l.strip())
verd = {}; pc = {}; pc_kw = 0; stale_tr = 0; dbl = 0; reg = 0; reg_f = 0
skip_pf = 0; reap_last = "none"; deferred_lines = 0
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r"P-INACT-LOCAL-EPOCH ino=(\d+) gen=(\d+) .* verdict=([a-z-]+) .*comm=(\S+)", line)
    if m:
        verd[m.group(3)] = verd.get(m.group(3), 0) + 1
        if m.group(3) == "peer-changed":
            pc[(m.group(1), m.group(2))] = True
            pc_kw += m.group(4).startswith("kworker")
            deferred_lines += "free deferred to the reaper" in line
        continue
    m = re.search(r"P3-EFREE-Q ino=(\d+) gen=(\d+) dlm_mode=\d+ stale=1 ", line)
    if m and (m.group(1), m.group(2)) in pc:
        stale_tr += 1
        continue
    if "P3-SKIP-DBLFREE " in line:
        dbl += 1
        continue
    m = re.search(r"P-DINO-CLOBBER#\d+ .* regress=(\d+) ", line)
    if m and int(m.group(1)) > 0:
        reg += 1
        if any(re.search(r"\bino=%s " % i, line) for i in fino):
            reg_f += 1
        continue
    if "IFREE-REVALIDATE-SKIP " in line and "why=bucket-empty-peer-freeing" in line:
        skip_pf += 1
        continue
    m = re.search(r"P89-REAP-DUTY duty=exit .* entries=(-?\d+)", line)
    if m:
        reap_last = m.group(1)
print("verdicts=%s peer_changed_lives=%d pc_kworker=%d pc_deferred_lines=%d stale_truncates=%d dblfree_skips=%d regress_lines=%d regress_f=%d peer_bucket_skips=%d reap_last_entries=%s" % (
    ",".join("%s:%d" % kv for kv in sorted(verd.items())) or "none",
    len(pc), pc_kw, deferred_lines, stale_tr, dbl, reg, reg_f, skip_pf, reap_last))
PY
)
    echo "$n hlu1: ${G[$n]} ($OUT/${n}_hlu1.txt)"
done
gv() { printf '%s\n' "${G[$1]}" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

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
a_pc=$(cget "$A" inact_local_peerchanged); a_cd=$(cget "$A" inact_local_cc_deferred)
a_lrr=$(cget "$A" bast_lastref_reached)
case "${a_pc:-x}${a_cd:-x}" in *[!0-9]*) echo "RESULT: ABORT peer_changed_life_ab label=$LABEL -- $A's counters did not read (${cnt[$A]}) evidence=$OUT"; exit 2 ;; esac
st=$(gv "$A" stale_truncates); dbl=$(gv "$A" dblfree_skips); rl=$(gv "$A" reap_last_entries)
regf=$(( $(gv "$A" regress_f) + $(gv "$B" regress_f) )); rega=$(( $(gv "$A" regress_lines) + $(gv "$B" regress_lines) ))
REP="guard=$GUARD iters=$ITERS ok=${okn:-?} peer_wait=$PWAIT live_delay=$LDELAY lastref_wait=$LRWAIT peerchanged=$a_pc cc_deferred=$a_cd lastref_reached=${a_lrr:-?} pc_kworker=$(gv "$A" pc_kworker) stale_truncates=$st dblfree_skips=$dbl regress_lines=$rega regress_f=$regf peer_bucket_skips=$(gv "$B" peer_bucket_skips) reap_last_entries=$rl a_verdicts=$(gv "$A" verdicts) node_failures=$bad audit=$audit"
if [ "$a_pc" = 0 ]; then
    echo "RESULT: VACUOUS peer_changed_life_ab label=$LABEL $REP -- no local-unlink inactivation on $A found a peer's change of the life on the platter evidence=$OUT"; exit 3
fi
if [ "$GUARD" = 0 ]; then
    if [ $((st + dbl + regf)) -gt 0 ]; then v=CONTROL-SHOWS-CAUSE; else v=CONTROL-NO-STALE-TRUNCATE; fi
    echo "RESULT: $v peer_changed_life_ab label=$LABEL $REP evidence=$OUT"; exit 0
fi
case "$audit" in CLEAN*errors=0) aok=1 ;; *) aok=0 ;; esac
if [ "$a_cd" = "$a_pc" ] && [ "$st" = 0 ] && [ "$dbl" = 0 ] && [ "$rega" = 0 ] && [ "$bad" = 0 ] && [ "$rl" = 0 ] && [ "$aok" = 1 ]; then
    echo "RESULT: PASS peer_changed_life_ab label=$LABEL $REP evidence=$OUT"; exit 0
fi
echo "RESULT: FAIL peer_changed_life_ab label=$LABEL $REP evidence=$OUT"; exit 1
