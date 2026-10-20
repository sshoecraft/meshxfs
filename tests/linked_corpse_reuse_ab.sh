#!/bin/bash
# tests/linked_corpse_reuse_ab.sh — same-build A/B of the linked-copy deferral
# (module knob cr63_linked_defer) for
# D-CREATE-REUSE-OVER-PEER-FREED-LINKED-CORPSE-SHUTS-NODE-DOWN.
#
# THE SHAPE (lap iwc1, 2/disk/caw/direct, ino 141): node A creates a file and
# drops its caches, so its in-core inode is evicted while still linked; node B
# removes the file, which takes the inode's grant through A's no-inode release,
# and frees the number; A's next create near the same directory is handed that
# number by its allocator and finds A's reclaimable copy of the old life still
# reading nlink 1.  Without the deferral xfs_iget_cache_hit's P-CR63 branch
# defers only a copy with nlink 0, the linked one falls through to
# xfs_iget_check_free_state ('Free inode not marked free'), and xfs_create
# cancels a dirty transaction: the node shuts down.
#
# H-L1 (on the record before this harness): the shutdown is caused only by the
# linked copy reaching the free-state check; deferring it to the recycle path's
# platter re-read (FREE: P-RECYCLE-SANITIZE resets it and the create proceeds;
# LIVE: P-CR63-DEFER-DISKLIVE fails it as before) removes the shutdown.
#
# THE WORKLOAD.  A creates D/c in a directory of its own; then, per round, one
# step at a time from this host so each has finished before the next starts:
#   A  read D/c's number and drop caches (no sync first: a clean copy is
#      reclaimed by the drop itself, and the round would offer nothing)
#   B  rm D/c: B's lookup takes the directory and the file from A, and B frees
#      the number (its inactivation runs in the rm)
#   A  create D/c again.  The allocator takes the lowest free number of the
#      record nearest D, which is the one B just freed: nothing else in the
#      directory's chunk moved since A's previous create took it.
# A round REUSED when A's create read the number of the round before.  Whether
# A still held the old life's copy when it did is the kernel's to say:
#   reach, control   P-CR63-DEADSHELL lines on A (the fall-through itself)
#   reach, fix       cr63_linked_deferred on A (every deferral; the lines that
#                    accompany it are rate-limited, the counter is not)
#
# THE GRADES
#   ABORT     prep, knob read-back, counter read or a capture failed
#   VACUOUS   the arm's reach is 0: no create met a linked copy
#   defer=0   CONTROL-SHOWS-CAUSE when A logged P-CR63-DEADSHELL and then shut
#             down through a dirty cancel (P-CR3-CANCEL error=-117 and a shutdown
#             line); CONTROL-NO-SHUTDOWN when it fell through and A lived (that
#             refutes H-L1's mechanism for this workload)
#   defer=1   PASS when cr63_linked_deferred > 0, cr63_linked_refused 0, no
#             P-CR63-DEADSHELL, P-CR63-DEFER-DISKLIVE or P-CR3-CANCEL on either
#             node, every step succeeded, neither node shut down, withdrew or
#             logged BUG/Oops/hung task, and the cold audit is CLEAN; FAIL
#             otherwise
#
# Budgets (derived): prep and the cold audit are run.sh rows under their own
# manifest budgets (run.sh flips an overrun to FAIL; no outer timeout).  One
# step is one ssh round trip, 380-500 ms measured to test29 on 2026-10-18,
# plus one create or rm with at most three lock hand-offs and one cache drop,
# well under 1 s on this rig: STEP_S 4 is twice that sum.  A step that overruns
# it is reported (step_timeouts) and ends the workload.  Counter reads 40 s per
# node, the stream copy 120 s per node.  Caller bound, the sum of those: prep
# 300 (tests/suite/manifest) + ROUNDS x 3 x STEP_S (480 at the defaults) +
# counters 80 + chk_clean 60 (tests/criteria/TIMEOUT_BUDGETS.md) + streams 240
# = 1160 s at the defaults.
#
# Usage: tests/linked_corpse_reuse_ab.sh <label> <defer 0|1> [rounds=40] [config=2/net/mesh/direct] [group=g2c]
# Exit 0 PASS / CONTROL-*, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; DEFER=${2:?defer 0|1}; ROUNDS=${3:-40}
CONFIG=${4:-2/net/mesh/direct}; GROUP=${5:-g2c}
STEP_S=${LCR_STEP_S:-4}
case "$DEFER" in 0|1) ;; *) echo "defer must be 0 or 1"; exit 2 ;; esac
for v in "$ROUNDS" "$STEP_S"; do
    case "$v" in ''|*[!0-9]*) echo "rounds and LCR_STEP_S must be whole numbers"; exit 2 ;; esac
done
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
read -r A B rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${A:-}" ] && [ -n "${B:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
# run.sh holds the nodes only while it runs; between its calls the workload
# below is invisible to tools/vm_pool.sh, whose idle sweep would shut them off
. tests/lib/runlock.sh
vmhold_take "linked_corpse_reuse_ab $LABEL" "$A" "$B" \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold $A $B"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_linked_corpse_reuse_$LABEL
mkdir -p "$OUT"
MARK="LINKED-CORPSE-REUSE-$LABEL-$$"
P=/sys/module/mxfs/parameters
CNTS="cr63_linked_deferred cr63_linked_refused"
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you\|^$'; }
echo "=== linked_corpse_reuse_ab label=$LABEL defer=$DEFER rounds=$ROUNDS step_s=$STEP_S $CONFIG $GROUP [$A $B] build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
want=$(modinfo -F srcversion mxfs.ko)
for n in $A $B; do
    sv=$(rs 20 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT label=$LABEL -- $n runs '$sv', not the tree build $want evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "echo $DEFER > $P/cr63_linked_defer; for c in $CNTS; do echo 0 > $P/\$c; done; echo $MARK > /dev/kmsg; echo \$(cat $P/cr63_linked_defer)/\$(cat $P/cr63_linked_deferred)/\$(cat $P/cr63_linked_refused)" | tail -1)
    [ "$got" = "$DEFER/0/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's cr63_linked_defer and its counters read '$got', not $DEFER/0/0 (is the build missing the knob?) evidence=$OUT"; exit 2; }
done
D=/mnt/shared/lcr.$LABEL
first=$(rs 30 "$A" "mkdir -p $D && : > $D/c && stat -c %i $D/c")
case "$first" in ''|*[!0-9]*) echo "RESULT: ABORT label=$LABEL stage=mkdir ($A read '$first') evidence=$OUT"; exit 2 ;; esac

# One line per round: round, the number A dropped, B's rm rc, A's create rc and
# the number it read.  Anything else a step prints is kept beside it.
prev=$first; reused=0; steps_bad=0; step_timeouts=0; done_rounds=0
for k in $(seq 1 "$ROUNDS"); do
    o=$(timeout "$STEP_S" "$SSH" "$A" "x=\$(stat -c %i $D/c) && echo 2 > /proc/sys/vm/drop_caches && echo drop_ok=\$x" < /dev/null 2>&1); r1=$?
    echo "round $k A_drop rc=$r1 $(echo "$o" | grep -a 'drop_ok=' | tail -1)" >> "$OUT/rounds.txt"
    echo "$o" | grep -av 'drop_ok=\|^Warning\|^Unauthorized\|^If you\|^$' | sed "s/^/round $k A_drop: /" >> "$OUT/steps_other.txt"
    o=$(timeout "$STEP_S" "$SSH" "$B" "rm $D/c && echo rm_ok" < /dev/null 2>&1); r2=$?
    echo "$o" | grep -av 'rm_ok\|^Warning\|^Unauthorized\|^If you\|^$' | sed "s/^/round $k B_rm: /" >> "$OUT/steps_other.txt"
    o=$(timeout "$STEP_S" "$SSH" "$A" ": > $D/c && echo create_ok=\$(stat -c %i $D/c)" < /dev/null 2>&1); r3=$?
    echo "$o" | grep -av 'create_ok=\|^Warning\|^Unauthorized\|^If you\|^$' | sed "s/^/round $k A_create: /" >> "$OUT/steps_other.txt"
    now=$(echo "$o" | sed -n 's/.*create_ok=\([0-9]*\).*/\1/p' | tail -1)
    hit=0; [ -n "$now" ] && [ "$now" = "$prev" ] && hit=1
    echo "round $k prev=$prev B_rm rc=$r2 A_create rc=$r3 now=${now:--} reused=$hit" >> "$OUT/rounds.txt"
    done_rounds=$k
    for r in $r1 $r2 $r3; do [ "$r" = 124 ] && step_timeouts=$((step_timeouts + 1)); done
    if [ "$r1" != 0 ] || [ "$r2" != 0 ] || [ "$r3" != 0 ] || [ -z "$now" ]; then
        steps_bad=$((steps_bad + 1)); break
    fi
    reused=$((reused + hit)); prev=$now
done
echo "workload: rounds=$done_rounds/$ROUNDS reused=$reused steps_bad=$steps_bad step_timeouts=$step_timeouts ($OUT/rounds.txt)"
tail -n 2 "$OUT/rounds.txt" | sed 's/^/  /'

declare -A nfail=()
for n in $A $B; do
    rs 40 "$n" "for c in $CNTS cr63_linked_defer; do echo \$c=\$(cat $P/\$c 2>/dev/null); done; echo mounted=\$(grep -c ' /mnt/shared mxfs ' /proc/mounts)" > "$OUT/${n}_counters.txt"
    mnt=$(sed -n 's/^mounted=//p' "$OUT/${n}_counters.txt"); dfr=$(sed -n 's/^cr63_linked_deferred=//p' "$OUT/${n}_counters.txt")
    [ -n "$mnt" ] && [ -n "$dfr" ] || { echo "RESULT: ABORT label=$LABEL -- $n's counters did not read evidence=$OUT"; exit 2; }
    echo "$n counters: $(tr '\n' ' ' < "$OUT/${n}_counters.txt")"
    [ "$mnt" = 1 ] || nfail[$n]=1
done
a_dfr=$(sed -n 's/^cr63_linked_deferred=//p' "$OUT/${A}_counters.txt")
a_ref=$(sed -n 's/^cr63_linked_refused=//p' "$OUT/${A}_counters.txt")
b_dfr=$(sed -n 's/^cr63_linked_deferred=//p' "$OUT/${B}_counters.txt")

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
# lap's mark, never from the ring, which a mid-lap shutdown can rotate out of.
tot_cancel=0; tot_disklive=0; tot_fall=0
for n in $A $B; do
    timeout 120 "$SSH" "$n" "gzip -c /root/dmesg.stream" < /dev/null 2>/dev/null > "$OUT/${n}_dmesg_stream.gz"
    marks=$(zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | grep -acF -- "$MARK")
    [ "${marks:-0}" -ge 1 ] || { echo "RESULT: ABORT label=$LABEL -- $n's kernel stream holds no lap mark ($OUT/${n}_dmesg_stream.gz) evidence=$OUT"; exit 2; }
    zcat "$OUT/${n}_dmesg_stream.gz" | sed -n "/$MARK/,\$p" \
        | grep -a 'P-CR63-\|P-CR62 \|P-CR3-CANCEL\|P-RECYCLE-SANITIZE \|P-NOINO-UNLOCK-LEFT-GRANT\|P-NOINO-RECLAIMABLE\|Free inode .* not marked free' > "$OUT/${n}_cr63.txt"
    zcat "$OUT/${n}_dmesg_stream.gz" | sed -n "/$MARK/,\$p" \
        | grep -a 'Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|P-INODE-WEDGE \|P-SESSION-POISON\|BUG:\|Oops\|blocked for more than' > "$OUT/${n}_failures.txt"
    fall=$(grep -ac 'P-CR63-DEADSHELL ino=' "$OUT/${n}_cr63.txt")
    dlink=$(grep -ac 'P-CR63-DEADSHELL-DEFER-LINKED ' "$OUT/${n}_cr63.txt")
    cancel=$(grep -ac 'P-CR3-CANCEL' "$OUT/${n}_cr63.txt")
    disklive=$(grep -ac 'P-CR63-DEFER-DISKLIVE' "$OUT/${n}_cr63.txt")
    sds=$(wc -l < "$OUT/${n}_failures.txt")
    echo "$n kernel log: marks=$marks fallthrough=$fall defer_linked_lines=$dlink sanitize_lines=$(grep -ac 'P-RECYCLE-SANITIZE ' "$OUT/${n}_cr63.txt") disklive=$disklive cancels=$cancel left_grant_reclaimable=$(grep -ac 'P-NOINO-UNLOCK-LEFT-GRANT .*lifecycle=RECLAIMABLE' "$OUT/${n}_cr63.txt") failure_lines=$sds ($OUT/${n}_cr63.txt, $OUT/${n}_failures.txt)"
    head -3 "$OUT/${n}_failures.txt" | cut -c1-300
    [ "$sds" = 0 ] || nfail[$n]=1
    tot_cancel=$((tot_cancel + cancel)); tot_disklive=$((tot_disklive + disklive)); tot_fall=$((tot_fall + fall))
    [ "$n" = "$A" ] && a_fall=$fall
done
bad=${#nfail[@]}
REP="defer=$DEFER rounds=$done_rounds/$ROUNDS reused=$reused a_deferred=$a_dfr a_refused=$a_ref b_deferred=$b_dfr fallthrough=$tot_fall cancels=$tot_cancel disklive=$tot_disklive steps_bad=$steps_bad step_timeouts=$step_timeouts audit=$audit node_failures=$bad"
if [ "$DEFER" = 0 ]; then
    if [ "$a_fall" = 0 ]; then
        echo "RESULT: VACUOUS linked_corpse_reuse_ab label=$LABEL $REP -- no create on $A met a linked copy evidence=$OUT"; exit 3
    fi
    if [ "$tot_cancel" -gt 0 ] && [ -n "${nfail[$A]:-}" ]; then
        echo "RESULT: CONTROL-SHOWS-CAUSE linked_corpse_reuse_ab label=$LABEL $REP evidence=$OUT"; exit 0
    fi
    echo "RESULT: CONTROL-NO-SHUTDOWN linked_corpse_reuse_ab label=$LABEL $REP evidence=$OUT"; exit 0
fi
if [ "$a_dfr" = 0 ]; then
    echo "RESULT: VACUOUS linked_corpse_reuse_ab label=$LABEL $REP -- no create on $A deferred a linked copy evidence=$OUT"; exit 3
fi
case "$audit" in CLEAN*) aok=1 ;; *) aok=0 ;; esac
if [ "$aok" = 1 ] && [ "$bad" = 0 ] && [ "$a_ref" = 0 ] && [ "$tot_fall" = 0 ] && [ "$tot_cancel" = 0 ] \
   && [ "$tot_disklive" = 0 ] && [ "$steps_bad" = 0 ]; then
    echo "RESULT: PASS linked_corpse_reuse_ab label=$LABEL $REP evidence=$OUT"; exit 0
fi
echo "RESULT: FAIL linked_corpse_reuse_ab label=$LABEL $REP evidence=$OUT"; exit 1
