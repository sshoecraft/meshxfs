#!/bin/bash
# tests/noino_acq_takeover_ab.sh — same-build A/B of the acquire take-over
# (module knob noino_acq_takeover), for
# D-NETMESH-MPATH-SURVIVOR-NOINO-RELFENCE-WEDGE-SHUTDOWN-WHILE-PEER-FROZEN.
#
# H-AT1, written before this harness (2/net/mesh/mpath lap r131b-9, test31): at
# 4601.8275 the allocator reserved inode 131 (a fresh EX grant), at 4601.8290
# xfs_dialloc took it, at 4601.8294 test32's BAST for 131 met this node's
# reclaimable corpse of the number and registered a no-inode release of that
# grant, and the create's xfs_iget then waited in mxfs_ilock_acquire_from_dlm
# behind the release while its transaction held AG 0's AGI, the AIL's oldest
# item (P-NOINO-WAIT-REPORT min_in_waiter_trans=1).  The release's drain fence
# cannot land a buffer the waiting create holds locked, so the wait runs out
# its 2000 rounds (~6 s); on TCP the acquire that follows goes to the master,
# and in r131b-9 the master had frozen, the fence's eight bounded pushes ran
# out and P-NOINO-RELFENCE-WEDGE shut the survivor down.
# PREDICTION IF TRUE: with noino_acq_takeover=0 the creates that meet a release
#   (noino_acq_meets > 0) wait behind it: P-NOINO-WAIT-REPORT lines with
#   min_in_waiter_trans=1 and P-NOINO-ACQ-WAIT waits of seconds, and operations
#   of the load stall that long.  With =1 every such create takes the release
#   over (noino_acq_takeovers moves, P-NOINO-ACQ-TAKEOVER, the release ending
#   P-NOINO-TAKEN-OVER without an unlock), none waits behind it, no node shuts
#   down, and the data and the audit stay clean.
# IF FALSE: with =1 a create that met a release still waits behind it
#   (P-NOINO-WAIT-REPORT min_in_waiter_trans=1), or a taken release unlocks.
#
# THE WORKLOAD: tests/mpath/pathload.py run on both nodes (the load
# path_fenced_return runs: private files, churn in a shared directory, the
# mkdir mutex), with dbg_create_alloc_delay_ms on both nodes holding every
# create between the allocator's take and its xfs_iget, which is the window the
# peer's BAST has to land in.  Nothing is frozen or faulted.
#
# THE GRADES
#   ABORT     prep, knob read-back, probe arming or a capture failed
#   VACUOUS   no acquire whose transaction held items met a release
#             (noino_acq_meets 0 on both nodes)
#   knob=0    the control: CONTROL-WAITED when any create waited behind a
#             release it held the fence's target for (a P-NOINO-WAIT-REPORT
#             with min_in_waiter_trans=1), CONTROL-NOWAIT when none did
#   knob=1    PASS when meets > 0, takeovers > 0, no P-NOINO-WAIT-REPORT with
#             min_in_waiter_trans=1, no P-NOINO-ACQ-WAIT TIMEOUT, no operation
#             of the load took 6 s or more (the wait's own bound), the load
#             reports err=0 double_grant=0 verify_fail=0, each node's
#             acknowledged files read back intact on the other node, the cold
#             audit is CLEAN, and neither node shut down, withdrew, wedged,
#             self-fenced or logged BUG/Oops/hung task after the mark; FAIL
#             otherwise
#
# Budgets (derived): prep and the cold audit are run.sh rows under their own
# manifest budgets (run.sh flips an overrun to FAIL itself, so no outer
# timeout).  Knob setting, arming and counter reads are a few sysfs writes: 20 s
# per node.  The load runs WINDOW_S; told to stop, it ends within one operation,
# and a healthy operation is milliseconds plus the create delay, so 45 s is the
# bound on its report (the same bound tests/mpath/lib.sh uses).  The cross-node
# read of a manifest is WINDOW_S of acknowledged small files: 120 s.  The stream
# copy 120 s.
#
# Usage: tests/noino_acq_takeover_ab.sh <label> <knob 0|1> [window_s=120] [config=2/net/mesh/direct] [group=g2c]
# Env:   NAT_CREATE_DELAY_MS (default 20)
# Exit 0 PASS / CONTROL-*, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; KNOB=${2:?knob 0|1}; WINDOW_S=${3:-120}
CONFIG=${4:-2/net/mesh/direct}; GROUP=${5:-g2c}
CDELAY=${NAT_CREATE_DELAY_MS:-20}
case "$KNOB" in 0|1) ;; *) echo "knob must be 0 or 1"; exit 2 ;; esac
for v in "$WINDOW_S" "$CDELAY"; do
    case "$v" in ''|*[!0-9]*) echo "window_s and NAT_CREATE_DELAY_MS must be whole numbers"; exit 2 ;; esac
done
cd "$(dirname "$0")/.." || exit 2
REPO=$(pwd); NREPO=/src/$(basename "$REPO")
SSH=tools/mxfs_sshpass.sh
read -r A B rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${A:-}" ] && [ -n "${B:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
. tests/lib/runlock.sh
vmhold_take "noino_acq_takeover_ab $LABEL" "$A" "$B" \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold $A $B"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_noino_acq_takeover_$LABEL
mkdir -p "$OUT"
MARK="NOINO-ACQ-TAKEOVER-$LABEL-$$"
P=/sys/module/mxfs/parameters
MNT=/mnt/shared
STOP=/run/nat_stop.$LABEL.$$
CNTS="noino_acq_meets noino_acq_takeovers noino_fence_taken noino_takeovers noino_bast_reclaimable dialloc_resv_noino_skipped dialloc_resv_under_noino recycle_reset_noino"
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
want=$(modinfo -F srcversion mxfs.ko)
echo "=== noino_acq_takeover_ab label=$LABEL knob=$KNOB window_s=$WINDOW_S create_delay_ms=$CDELAY $CONFIG $GROUP [$A $B] build=$want repo=$NREPO out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
for n in $A $B; do
    sv=$(rs 20 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT label=$LABEL -- $n runs '$sv', not this checkout's build $want evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "echo $KNOB > $P/noino_acq_takeover; echo 0 > $P/dbg_create_alloc_delay_ms; for c in $CNTS; do echo 0 > $P/\$c; done; c=/proc/dynamic_debug/control; echo 'module mxfs format P-NOINO-ACQ-WAIT +p' > \$c; echo $MARK > /dev/kmsg; echo \$(cat $P/noino_acq_takeover)/\$(cat $P/noino_recycle_takeover)/\$(cat $P/noino_resv_guard)/\$(cat $P/noino_bast_dedup)/\$(grep -c '=p.*P-NOINO-ACQ-WAIT' \$c)" | tail -1)
    [ "$got" = "$KNOB/1/1/1/1" ] || { echo "RESULT: ABORT label=$LABEL -- $n's noino_acq_takeover/noino_recycle_takeover/noino_resv_guard/noino_bast_dedup/armed P-NOINO-ACQ-WAIT read '$got', not $KNOB/1/1/1/1 evidence=$OUT"; exit 2; }
done
set_delay() { for n in $A $B; do rs 20 "$n" "echo $1 > $P/dbg_create_alloc_delay_ms; cat $P/dbg_create_alloc_delay_ms" | tail -1; done | tr '\n' ' '; }
trap 'set_delay 0 > /dev/null; for n in $A $B; do rs 10 "$n" "touch $STOP" > /dev/null; done' EXIT
echo "create delay set: $(set_delay "$CDELAY")"

for n in $A $B; do
    mkdir -p "$OUT/load_$n"
    rs 20 "$n" "rm -f $STOP; PATHLOAD_VERIFY=1 nohup setsid python3 $NREPO/tests/mpath/pathload.py run $n $MNT $NREPO/$OUT/load_$n $STOP > $NREPO/$OUT/load_$n/run.out 2>&1 < /dev/null &" > /dev/null
done
sleep "$WINDOW_S"
for n in $A $B; do rs 10 "$n" "touch $STOP" > /dev/null; done
for n in $A $B; do
    i=0; while [ $i -lt 45 ] && ! grep -aq '^PATHLOAD ' "$OUT/load_$n/run.out" 2>/dev/null; do sleep 1; i=$((i + 1)); done
done
echo "create delay cleared: $(set_delay 0)"
trap - EXIT

lbad=0; maxop=0; long=0
for n in $A $B; do
    pl=$(grep -a '^PATHLOAD ' "$OUT/load_$n/run.out" 2>/dev/null | tail -1)
    echo "$n load: ${pl:-NO PATHLOAD LINE (an operation did not end within 45 s of the stop)}"
    e=$(sed -n 's/.* err=\([0-9]*\).*/\1/p' <<<"$pl"); dg=$(sed -n 's/.*double_grant=\([0-9]*\).*/\1/p' <<<"$pl"); vf=$(sed -n 's/.*verify_fail=\([0-9]*\).*/\1/p' <<<"$pl")
    [ "${e:-x}" = 0 ] && [ "${dg:-x}" = 0 ] && [ "${vf:-x}" = 0 ] || lbad=$((lbad + 1))
    read -r m l <<< "$(python3 - "$OUT/load_$n/ops.log" <<'PY'
import sys
mx = 0; lg = 0
for line in open(sys.argv[1], errors="replace"):
    f = line.split()
    if len(f) < 4 or not f[0].isdigit() or not f[1].isdigit():
        continue
    d = int(f[1]) - int(f[0])
    mx = max(mx, d)
    lg += d >= 6000
print(mx, lg)
PY
)"
    echo "$n ops: max_ms=${m:-?} at_or_over_6000ms=${l:-?}"
    [ -n "${m:-}" ] && [ "$m" -gt "$maxop" ] && maxop=$m
    long=$((long + ${l:-1}))
done
vbad=0
for pair in "$A $B" "$B $A"; do
    read -r src dst <<< "$pair"
    vr=$(rs 120 "$dst" "python3 $NREPO/tests/mpath/pathload.py verify $NREPO/$OUT/load_$src/manifest" | tail -1)
    echo "$src's acknowledged files read on $dst: $vr"
    case "$vr" in "VERIFY files="*" bad=0 missing=0 "*) ;; *) vbad=$((vbad + 1)) ;; esac
done

declare -A nfail=()
meets=0; tks=0
for n in $A $B; do
    rs 40 "$n" "for c in $CNTS noino_acq_takeover; do echo \$c=\$(cat $P/\$c 2>/dev/null); done; echo mounted=\$(grep -c ' $MNT mxfs ' /proc/mounts)" > "$OUT/${n}_counters.txt"
    v() { sed -n "s/^$1=//p" "$OUT/${n}_counters.txt"; }
    mt=$(v noino_acq_meets); tk=$(v noino_acq_takeovers); mnt=$(v mounted)
    [ -n "$mt" ] && [ -n "$tk" ] && [ -n "$mnt" ] || { echo "RESULT: ABORT label=$LABEL -- $n's counters did not read evidence=$OUT"; exit 2; }
    echo "$n counters: $(tr '\n' ' ' < "$OUT/${n}_counters.txt")"
    meets=$((meets + mt)); tks=$((tks + tk))
    [ "$mnt" = 1 ] || nfail[$n]=1
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

wrep=0; wtime=0
for n in $A $B; do
    timeout 120 "$SSH" "$n" "gzip -c /root/dmesg.stream" < /dev/null 2>/dev/null > "$OUT/${n}_dmesg_stream.gz"
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" > "$OUT/${n}_after_mark.txt"
    mk=$(grep -acF -- "$MARK" "$OUT/${n}_after_mark.txt")
    [ "$mk" -ge 1 ] || { echo "RESULT: ABORT label=$LABEL -- $n's kernel log has no mark $MARK evidence=$OUT"; exit 2; }
    grep -a 'Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|P-INODE-WEDGE \|P-SESSION-POISON\|P-NOINO-RELFENCE-WEDGE\|BUG:\|Oops\|blocked for more than' "$OUT/${n}_after_mark.txt" > "$OUT/${n}_failures.txt"
    fl=$(wc -l < "$OUT/${n}_failures.txt")
    [ "$fl" = 0 ] || nfail[$n]=1
    wr=$(grep -a 'P-NOINO-WAIT-REPORT ' "$OUT/${n}_after_mark.txt" | grep -ac 'min_in_waiter_trans=1')
    wt=$(grep -a 'P-NOINO-ACQ-WAIT ' "$OUT/${n}_after_mark.txt" | grep -ac 'TIMEOUT')
    wrep=$((wrep + wr)); wtime=$((wtime + wt))
    echo "$n lines after the mark: failures=$fl wait_report_in_trans=$wr wait_report_all=$(grep -ac 'P-NOINO-WAIT-REPORT ' "$OUT/${n}_after_mark.txt") acq_wait=$(grep -ac 'P-NOINO-ACQ-WAIT ' "$OUT/${n}_after_mark.txt") acq_wait_timeout=$wt acq_takeover=$(grep -ac 'P-NOINO-ACQ-TAKEOVER ' "$OUT/${n}_after_mark.txt") fence_taken=$(grep -ac 'P-NOINO-FENCE-TAKEN ' "$OUT/${n}_after_mark.txt") taken_over=$(grep -ac 'P-NOINO-TAKEN-OVER ' "$OUT/${n}_after_mark.txt") live_skip=$(grep -ac 'P-NOINO-LIVE-SKIP ' "$OUT/${n}_after_mark.txt")"
    head -3 "$OUT/${n}_failures.txt" | cut -c1-300
    grep -a -m3 'P-NOINO-WAIT-REPORT \|P-NOINO-ACQ-TAKEOVER ' "$OUT/${n}_after_mark.txt" | cut -c1-400
done
bad=${#nfail[@]}

REP="knob=$KNOB window_s=$WINDOW_S create_delay_ms=$CDELAY meets=$meets takeovers=$tks wait_report_in_trans=$wrep acq_wait_timeout=$wtime max_op_ms=$maxop ops_6s=$long load_bad=$lbad verify_bad=$vbad"
[ "$meets" -gt 0 ] || { echo "RESULT: VACUOUS noino_acq_takeover_ab label=$LABEL $REP audit=$audit node_failures=$bad -- no acquire holding transaction items met a no-inode release evidence=$OUT"; exit 3; }
if [ "$KNOB" = 0 ]; then
    v=CONTROL-NOWAIT; [ "$wrep" -gt 0 ] && v=CONTROL-WAITED
    echo "RESULT: $v noino_acq_takeover_ab label=$LABEL $REP audit=$audit node_failures=$bad evidence=$OUT"; exit 0
fi
case "$audit" in CLEAN*) aok=1 ;; *) aok=0 ;; esac
if [ "$tks" -gt 0 ] && [ "$wrep" = 0 ] && [ "$wtime" = 0 ] && [ "$long" = 0 ] && [ "$lbad" = 0 ] && [ "$vbad" = 0 ] && [ "$aok" = 1 ] && [ "$bad" = 0 ]; then
    echo "RESULT: PASS noino_acq_takeover_ab label=$LABEL $REP audit=$audit evidence=$OUT"; exit 0
fi
echo "RESULT: FAIL noino_acq_takeover_ab label=$LABEL $REP audit=$audit node_failures=$bad evidence=$OUT"; exit 1
