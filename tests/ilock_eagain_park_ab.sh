#!/bin/bash
# tests/ilock_eagain_park_ab.sh — same-build A/B of the inode lock classifier's
# park for an acquire whose retry budget ran out on RETRY answers (module knob
# ilock_retry_exhaust_park) for D-FORMATION-RAMP-LOCK-REQUEST-EXHAUSTS-RETRIES-EAGAIN.
#
# THE SHAPE (tests/tauth/formation_test, user mode): while nodes join a view
# one after another, a lock request spends its whole retry budget on RETRY
# answers (the view moving, a page in preparation) and the engine returns
# -EAGAIN.  In the kernel the inode lock's timeout classifier
# (xfs/xfs_mxfs_ilock.c) had no arm for -EAGAIN: it reached arm (3), "DLM inode
# lock unrecoverable", and shut the filesystem down for a cluster that was
# only reorganising.
#
# H-F2 (on the record before this harness): an -EAGAIN at the end of the
# budget parks with backoff and asks again (arm (2c), P-LKRETRY-PARK), so the
# operation completes and nothing shuts down; ilock_retry_exhaust_park 0 is the
# same-build control, the shutdown.
#
# THE INJECTION.  The ramp cannot be made to exhaust a kernel acquire's budget
# on demand, so dbg_ilock_force_eagain_ino (test only) makes the next slow-path
# acquire of one inode report -EAGAIN for all its attempts without asking the
# engine, once (P-DBG-FORCE-EAGAIN), which is exactly what the engine returns
# at the end of a spent budget.  Per round: B creates D/f<k> with a payload and
# syncs, so B holds its grant and A has never seen the inode; A arms the
# injection on its number; A reads the file, whose first acquire on A is a
# slow-path PR.  The control stops at its first round (A shuts down).
#
# THE GRADES
#   ABORT     prep, build, knob or injection read-back, a counter or a capture
#             failed
#   VACUOUS   no P-DBG-FORCE-EAGAIN on A after the mark: no read took the slow
#             path, so nothing met the arm
#   park=0    CONTROL-SHOWS-HARM when A logged "DLM inode lock unrecoverable"
#             for an injected number and shut down; CONTROL-NO-HARM otherwise
#             (another arm took the -EAGAIN, and H-F2's premise fails here)
#   park=1    PASS when every round's injection fired, each was followed by a
#             P-LKRETRY-PARK for that number, each read returned its payload,
#             ilock_retry_exhaust_parks on A is at least the rounds, no "lock
#             unrecoverable" line, neither node shut down, withdrew or logged
#             BUG/Oops/hung task, and the cold audit is CLEAN; FAIL otherwise
#
# Budgets (derived): prep and the cold audit are run.sh rows under their own
# manifest budgets (run.sh flips an overrun to FAIL; no outer timeout).  One
# step is one ssh round trip, 380-500 ms measured to test29 on 2026-10-18, plus
# one create and sync, one knob write, or one read whose acquire makes three
# injected attempts 50 ms apart and one 500 ms park before the real acquire:
# STEP_S 4 is over twice the longest.  A step that overruns it is reported
# (step_timeouts) and ends the workload.  Counter reads 40 s per node, the
# stream copy 120 s per node.  Caller bound, the sum: prep 300
# (tests/suite/manifest) + ROUNDS x 4 x STEP_S (48 at the defaults) + counters
# 80 + chk_clean with its coverage witness 210 + streams 240 = 878 s.
#
# Usage: tests/ilock_eagain_park_ab.sh <label> <park 0|1> [rounds=3] [config=2/net/mesh/direct] [group=g2c]
# Exit 0 PASS / CONTROL-*, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; PARK=${2:?park 0|1}; ROUNDS=${3:-3}
CONFIG=${4:-2/net/mesh/direct}; GROUP=${5:-g2c}
STEP_S=${IEP_STEP_S:-4}
case "$PARK" in 0|1) ;; *) echo "park must be 0 or 1"; exit 2 ;; esac
for v in "$ROUNDS" "$STEP_S"; do
    case "$v" in ''|*[!0-9]*) echo "rounds and IEP_STEP_S must be whole numbers"; exit 2 ;; esac
done
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
read -r A B rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${A:-}" ] && [ -n "${B:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
# run.sh holds the nodes only while it runs; between its calls the workload
# below is invisible to tools/vm_pool.sh, whose idle sweep would shut them off
. tests/lib/runlock.sh
vmhold_take "ilock_eagain_park_ab $LABEL" "$A" "$B" \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold $A $B"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_ilock_eagain_park_$LABEL
mkdir -p "$OUT"
MARK="ILOCK-EAGAIN-PARK-$LABEL-$$"
P=/sys/module/mxfs/parameters
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you\|^$'; }
echo "=== ilock_eagain_park_ab label=$LABEL park=$PARK rounds=$ROUNDS step_s=$STEP_S $CONFIG $GROUP [$A $B] build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
want=$(modinfo -F srcversion mxfs.ko)
for n in $A $B; do
    sv=$(rs 20 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT label=$LABEL -- $n runs '$sv', not the tree build $want evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "echo $PARK > $P/ilock_retry_exhaust_park; echo 0 > $P/ilock_retry_exhaust_parks; echo 0 > $P/dbg_ilock_force_eagain_ino; echo $MARK > /dev/kmsg; echo \$(cat $P/ilock_retry_exhaust_park)/\$(cat $P/ilock_retry_exhaust_parks)/\$(cat $P/dbg_ilock_force_eagain_ino)" | tail -1)
    [ "$got" = "$PARK/0/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's ilock_retry_exhaust_park, its counter and the injection read '$got', not $PARK/0/0 (is the build missing the H-F2 knobs?) evidence=$OUT"; exit 2; }
done
D=/mnt/shared/iep.$LABEL
mk=$(rs 30 "$B" "mkdir -p $D && echo mk_ok")
[ "$mk" = mk_ok ] || { echo "RESULT: ABORT label=$LABEL stage=mkdir ($B read '$mk') evidence=$OUT"; exit 2; }

# One line per round: the number, the injection's read-back before and after
# the read, the read's rc and whether it returned the payload.
injected=""; reads_ok=0; steps_bad=0; step_timeouts=0; done_rounds=0
for k in $(seq 1 "$ROUNDS"); do
    o=$(timeout "$STEP_S" "$SSH" "$B" "echo iep-$LABEL-$k > $D/f$k && sync && echo ino=\$(stat -c %i $D/f$k)" < /dev/null 2>&1); r1=$?
    ino=$(echo "$o" | sed -n 's/^ino=\([0-9]*\)$/\1/p' | tail -1)
    o=$(timeout "$STEP_S" "$SSH" "$A" "echo ${ino:-0} > $P/dbg_ilock_force_eagain_ino && echo armed=\$(cat $P/dbg_ilock_force_eagain_ino)" < /dev/null 2>&1); r2=$?
    armed=$(echo "$o" | sed -n 's/^armed=\([0-9]*\)$/\1/p' | tail -1)
    o=$(timeout "$STEP_S" "$SSH" "$A" "cat $D/f$k" < /dev/null 2>&1); r3=$?
    payload=$(echo "$o" | grep -a "^iep-$LABEL-$k\$" | tail -1)
    o=$(timeout "$STEP_S" "$SSH" "$A" "echo left=\$(cat $P/dbg_ilock_force_eagain_ino)" < /dev/null 2>&1); r4=$?
    left=$(echo "$o" | sed -n 's/^left=\([0-9]*\)$/\1/p' | tail -1)
    ok=0; [ "$r3" = 0 ] && [ -n "$payload" ] && ok=1
    echo "round $k ino=${ino:--} create_rc=$r1 arm_rc=$r2 armed=${armed:--} read_rc=$r3 payload_ok=$ok left=${left:--} left_rc=$r4" >> "$OUT/rounds.txt"
    done_rounds=$k
    for r in $r1 $r2 $r3 $r4; do [ "$r" = 124 ] && step_timeouts=$((step_timeouts + 1)); done
    [ -n "$ino" ] && injected="$injected $ino"
    if [ "$r1" != 0 ] || [ "$r2" != 0 ] || [ -z "$ino" ] || [ "$armed" != "$ino" ]; then
        steps_bad=$((steps_bad + 1)); break
    fi
    reads_ok=$((reads_ok + ok))
    # the control's first read shuts A down; nothing after it is a round
    [ "$ok" = 1 ] || { steps_bad=$((steps_bad + 1)); break; }
done
echo "workload: rounds=$done_rounds/$ROUNDS reads_ok=$reads_ok steps_bad=$steps_bad step_timeouts=$step_timeouts injected=[${injected# }] ($OUT/rounds.txt)"
sed 's/^/  /' "$OUT/rounds.txt"

declare -A nfail=()
for n in $A $B; do
    rs 40 "$n" "for c in ilock_retry_exhaust_park ilock_retry_exhaust_parks dbg_ilock_force_eagain_ino; do echo \$c=\$(cat $P/\$c 2>/dev/null); done; echo mounted=\$(grep -c ' /mnt/shared mxfs ' /proc/mounts)" > "$OUT/${n}_counters.txt"
    mnt=$(sed -n 's/^mounted=//p' "$OUT/${n}_counters.txt"); pk=$(sed -n 's/^ilock_retry_exhaust_parks=//p' "$OUT/${n}_counters.txt")
    [ -n "$mnt" ] && [ -n "$pk" ] || { echo "RESULT: ABORT label=$LABEL -- $n's counters did not read evidence=$OUT"; exit 2; }
    echo "$n counters: $(tr '\n' ' ' < "$OUT/${n}_counters.txt")"
    [ "$mnt" = 1 ] || nfail[$n]=1
done
a_parks=$(sed -n 's/^ilock_retry_exhaust_parks=//p' "$OUT/${A}_counters.txt")

# The cold audit needs both mounts; a shut-down node has none, and run.sh
# refuses the audit for it (no verdict, not a CLEAN one)
since=$(date -u +%FT%TZ)
MXFS_SNAPSHOT_DIR=${MXFS_SNAPSHOT_DIR:-/mxfs/snapshots} ./run.sh "$CONFIG" --group "$GROUP" chk_clean > "$OUT/chk.log" 2>&1
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
# /root/dmesg.stream on every node.  Node failures are read from it after this
# lap's mark, never from the ring, which a shutdown can rotate out of.
for n in $A $B; do
    timeout 120 "$SSH" "$n" "gzip -c /root/dmesg.stream" < /dev/null 2>/dev/null > "$OUT/${n}_dmesg_stream.gz"
    marks=$(zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | grep -acF -- "$MARK")
    [ "${marks:-0}" -ge 1 ] || { echo "RESULT: ABORT label=$LABEL -- $n's kernel stream holds no lap mark ($OUT/${n}_dmesg_stream.gz) evidence=$OUT"; exit 2; }
    zcat "$OUT/${n}_dmesg_stream.gz" | sed -n "/$MARK/,\$p" \
        | grep -a 'P-DBG-FORCE-EAGAIN\|P-LKRETRY-\|DLM inode lock unrecoverable' > "$OUT/${n}_eagain.txt"
    zcat "$OUT/${n}_dmesg_stream.gz" | sed -n "/$MARK/,\$p" \
        | grep -a 'Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|P-INODE-WEDGE \|P-SESSION-POISON\|BUG:\|Oops\|blocked for more than' > "$OUT/${n}_failures.txt"
    sds=$(wc -l < "$OUT/${n}_failures.txt")
    echo "$n kernel log: marks=$marks force_eagain=$(grep -ac 'P-DBG-FORCE-EAGAIN' "$OUT/${n}_eagain.txt") park=$(grep -ac 'P-LKRETRY-PARK' "$OUT/${n}_eagain.txt") unrecoverable=$(grep -ac 'DLM inode lock unrecoverable' "$OUT/${n}_eagain.txt") failure_lines=$sds ($OUT/${n}_eagain.txt, $OUT/${n}_failures.txt)"
    head -3 "$OUT/${n}_failures.txt" | cut -c1-300
    [ "$sds" = 0 ] || nfail[$n]=1
done
fired=0; parked=0; unrec=0
for ino in $injected; do
    grep -aq "P-DBG-FORCE-EAGAIN ino=$ino " "$OUT/${A}_eagain.txt" && fired=$((fired + 1))
    grep -aq "P-LKRETRY-PARK ino=$ino " "$OUT/${A}_eagain.txt" && parked=$((parked + 1))
    grep -aq "DLM inode lock unrecoverable: ino=$ino " "$OUT/${A}_eagain.txt" && unrec=$((unrec + 1))
done
unrec_any=$(cat "$OUT/${A}_eagain.txt" "$OUT/${B}_eagain.txt" | grep -ac 'DLM inode lock unrecoverable')
bad=${#nfail[@]}
REP="park=$PARK rounds=$done_rounds/$ROUNDS fired=$fired parked=$parked unrecoverable=$unrec unrecoverable_any=$unrec_any reads_ok=$reads_ok a_parks=$a_parks steps_bad=$steps_bad step_timeouts=$step_timeouts audit=$audit node_failures=$bad"
if [ "$fired" = 0 ]; then
    echo "RESULT: VACUOUS ilock_eagain_park_ab label=$LABEL $REP -- no read on $A took the slow path the injection waits on evidence=$OUT"; exit 3
fi
if [ "$PARK" = 0 ]; then
    if [ "$unrec" -gt 0 ] && [ -n "${nfail[$A]:-}" ]; then
        echo "RESULT: CONTROL-SHOWS-HARM ilock_eagain_park_ab label=$LABEL $REP evidence=$OUT"; exit 0
    fi
    echo "RESULT: CONTROL-NO-HARM ilock_eagain_park_ab label=$LABEL $REP evidence=$OUT"; exit 0
fi
case "$audit" in CLEAN*) aok=1 ;; *) aok=0 ;; esac
if [ "$aok" = 1 ] && [ "$bad" = 0 ] && [ "$done_rounds" = "$ROUNDS" ] && [ "$fired" = "$ROUNDS" ] \
   && [ "$parked" = "$ROUNDS" ] && [ "$reads_ok" = "$ROUNDS" ] && [ "${a_parks:-0}" -ge "$ROUNDS" ] \
   && [ "$unrec_any" = 0 ] && [ "$steps_bad" = 0 ]; then
    echo "RESULT: PASS ilock_eagain_park_ab label=$LABEL $REP evidence=$OUT"; exit 0
fi
echo "RESULT: FAIL ilock_eagain_park_ab label=$LABEL $REP evidence=$OUT"; exit 1
