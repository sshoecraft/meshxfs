#!/bin/bash
# tests/posix_multi_incarn_ab.sh <configuration> <group> <nodes-csv> [pairs] [label]
#
# posix_multi BUDGET_EXHAUSTED on the 0.90.131 release build at 8 and 16
# nodes, both transports: every rank but 1 waited at 'pm barrier count'
# while rank 1 sat in the `ls "$D"/node*_file*` that feeds its count check
# (the check's step label is set after its arguments are evaluated, so the
# watchdog names the previous step, 'pm own node1_file<FPN> exists').  On
# 0.90.130 the row passed in 4-7 s.
#
# A same-build, same-prep A/B of one module switch: per pair, arm F (switch
# at its fix value, 1) then arm C (0, the control).  Each run first boards
# PRE_ROWS (the rows the board runs before posix_multi, which leave the dead
# shells of reused numbers in rank 1's cache: on a fresh prep the row passed
# in 3 s and 13 s) and then posix_multi, both under the arm's switch.
#
#   KNOB=lookup_dir_incarn_verify   H-PM1, the 0.90.131 lookup arm.  REFUTED
#                                   (a C0 run stalled the same way).
#   KNOB=poison_revoke_idle_skip    H-PM3: the revocation queued for a
#                                   poisoned shell with no dentry and no page
#                                   cache holds the reference the lookup's
#                                   retire waits out behind the inode BAST
#                                   workqueue.  REFUTED as the cause of the
#                                   2.4 s stall (an F1 run stalled the same
#                                   way: the resolver's 200 rounds dominate);
#                                   tested again behind sametype_poison_break
#                                   with tests/recreated_dir_peer_mkdir.sh.
#   KNOB=sametype_poison_break      the same-type resolver stops reloading a
#                                   shell its reload has poisoned.
#
# PREDICTION: every F run PASSes; at least one C run fails as on the
# boards (the control must reach the stall, or the A/B proves nothing: MIXED
# with c_fail=0 is NO REACH, not support).  REFUTED if an F run stalls.
# The switch is read back on every node before and after each run (a module
# reload in between would put it back to its default and void the arm).
#
# Runs from the checkout holding this script, so a sibling (tools/sibling_sync.sh)
# boards its own build.
# Budget per run: PRE_ROWS' manifest budgets (fio_perf 120 + cache_coherency 60
# + strong_consistency 30 = 210 s, measured 51 s on the board) + run.sh setup
# and aggregation (~40 s) = 250 s; posix_multi's 30 s + ~40 s = 70 s (the
# 120 s below is its bound with 0.90.130's measured 4-7 s far inside it).
# Prep (measured 30-140 s) is bounded at 300 s.
set -u
cd "$(dirname "$0")/.." || exit 1
CFG=${1:?configuration}; G=${2:?rig group}; NODES=${3:?comma list of the group nodes}
PAIRS=${4:-2}; LABEL=${5:-pmab}
KNOB=${KNOB:-lookup_dir_incarn_verify}
PRE_ROWS=${PRE_ROWS-fio_perf cache_coherency strong_consistency}
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_pmincarn_$LABEL
mkdir -p "$OUT"
echo "=== posix_multi_incarn_ab knob=$KNOB pre=[$PRE_ROWS] cfg=$CFG group=$G nodes=$NODES pairs=$PAIRS tree=$(pwd) sv=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="
MXFS_FORCE_PREP=1 timeout 300 ./run.sh "$CFG" --group "$G" prep_cluster > "$OUT/prep.log" 2>&1
prc=$?
grep -E 'prep_cluster OK|prep OK' "$OUT/prep.log" | tail -1
[ "$prc" = 0 ] || { echo "RESULT ABORT pmincarn: prep rc=$prc ($OUT/prep.log)"; exit 2; }
fails=0; c_pass=0; c_fail=0; f_pass=0; f_fail=0
want=$(echo "$NODES" | tr ',' '\n' | grep -c .)
for p in $(seq 1 "$PAIRS"); do
  for arm in F1 C0; do
    v=1; [ "$arm" = C0 ] && v=0
    tag=p${p}_$arm
    tests/fleet_set_params.sh "$KNOB=$v" "$NODES" "$OUT/knobs_${tag}_set.txt" > /dev/null 2>&1
    if [ -n "$PRE_ROWS" ]; then
      timeout 250 ./run.sh "$CFG" --group "$G" $PRE_ROWS > "$OUT/pre_$tag.log" 2>&1
      echo "  PRE $tag rc=$? $(grep -a -E '^Total:' "$OUT/pre_$tag.log" | tail -1)"
    fi
    s=$(date +%s)
    timeout 120 ./run.sh "$CFG" --group "$G" posix_multi > "$OUT/run_$tag.log" 2>&1
    rrc=$?
    wall=$(( $(date +%s) - s ))
    tests/fleet_set_params.sh "$KNOB" "$NODES" "$OUT/knobs_${tag}_after.txt" > /dev/null 2>&1
    got=$(grep -c "$KNOB=$v\b" "$OUT/knobs_${tag}_after.txt")
    row=$(grep -a -E '^\s+(PASS|FAIL|FLAKY)\s+posix_multi' "$OUT/run_$tag.log" | tail -1 | sed 's/^ *//' | cut -c1-240)
    verdict=$(printf '%s' "$row" | awk '{print $1}')
    if [ "$got" != "$want" ]; then
      echo "  RESULT $tag VOID switch read back on $got of $want nodes"; fails=$((fails+1)); continue
    fi
    echo "  RESULT $tag $KNOB=$v rc=$rrc wall=${wall}s row=[${row:-none}]"
    case "$arm:$verdict" in
      C0:PASS) c_pass=$((c_pass+1));; C0:*) c_fail=$((c_fail+1));;
      F1:PASS) f_pass=$((f_pass+1));; F1:*) f_fail=$((f_fail+1));;
    esac
  done
done
tests/fleet_set_params.sh "$KNOB=1" "$NODES" "$OUT/knobs_restore.txt" > /dev/null 2>&1
echo "  INFO c0_pass=$c_pass c0_fail=$c_fail f1_pass=$f_pass f1_fail=$f_fail void=$fails evidence=$OUT"
[ "$fails" = 0 ] || { echo "RESULT ABORT pmincarn: $fails void run(s)"; exit 2; }
if [ "$f_fail" = 0 ] && [ "$c_fail" -gt 0 ]; then echo "RESULT SUPPORTED pmincarn: every F1 run passed, C0 failed $c_fail of $PAIRS"; exit 0; fi
if [ "$f_fail" -gt 0 ]; then echo "RESULT REFUTED pmincarn: F1 failed $f_fail of $PAIRS"; exit 1; fi
echo "RESULT NOREACH pmincarn: every run passed; the control never stalled"; exit 3
