#!/bin/bash
# tests/reused_corpse_lookup_enoent.sh <configuration> <group> <X> <Y> [laps] [label]
#
# Directed repro for D-POSIX-MULTI-RANK1-COUNT-125-OF-128-AFTER-CREATE-DONE-BARRIER:
# a node that freed a peer's files keeps their in-core copies as reclaimable
# corpses caching the EX its frees ran under; the peer then creates new files
# on the same numbers, the no-inode release on the freeing node unlocks that
# grant (P-NOINO-UNLOCK-LEFT-GRANT lifecycle=RECLAIMABLE), and the freeing
# node's lookups of the new names fail -ENOENT (P26-IGET-FAIL err=-2): its
# cache hit on the mode-0 corpse ends in xfs_iget_check_free_state, and the
# lookup's ladder (P12-IGETMISS-RELOAD, P13-VISNUDGE x8) never re-reads it.
# Measured on 8/disk/caw/direct (posix_multi rank 1 counted 125 of 128).
#
# Per lap, in D=/mnt/shared/rcl_<label>/<lap>, X = the freeing node, Y = the
# creating node:
#   Y creates f1..fN and syncs, and records their numbers (ls -i);
#   X lists D with stat (ls -l: its in-core copy of each), removes f1..fN and
#     syncs: X frees the numbers, the corpses stay in core (dbg_reclaim_hold=1
#     on X holds background and shrinker reclaim off for the run);
#   Y creates g1..gN and syncs, and records their numbers;
#   X counts `ls D/g*` (stat of each name through the lookup), reads every g
#     file back (a reload that brought back a freed incarnation would show
#     other bytes) and reads its kernel log since the lap's mark.
# REACH: the numbers g and f share (Y's allocator handing back what X freed).
# A lap with reach 0 says nothing about the defect and is reported as such.
# FAIL (per lap): X counts fewer than N, reads any g file back wrong, or
# logs P26-IGET-FAIL err=-2.
#
# ARMS="<k=v> <k=v> ..." module settings, one arm each, set on both nodes
# before the arm's laps and read back after them (a module reload in between
# puts every parameter back to its default: the arm is VOID).
#
# Budget: per lap 4 ssh round trips of creates/removes of N=32 files with a
# sync each (native XFS: well under 1 s) + X's listing (32 lookups) + log
# reads: measured ~1 s of work and ~0.3 s per ssh; 10 s per lap is the bound.
# Prep 300 s (manifest).
set -u
cd "$(dirname "$0")/.." || exit 1
CFG=${1:?configuration}; G=${2:?rig group}; X=${3:?freeing node}; Y=${4:?creating node}
LAPS=${5:-10}; LABEL=${6:-rcl}
N=${RCL_N:-32}
ARMS=${ARMS:-"lookup_dir_incarn_verify=0 lookup_dir_incarn_verify=1"}
SSH=tools/mxfs_sshpass.sh
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_rcl_$LABEL
mkdir -p "$OUT"
echo "=== reused_corpse_lookup_enoent cfg=$CFG group=$G X=$X Y=$Y laps=$LAPS n=$N arms=[$ARMS] tree=$(pwd) sv=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="
MXFS_FORCE_PREP=1 timeout 300 ./run.sh "$CFG" --group "$G" prep_cluster > "$OUT/prep.log" 2>&1
prc=$?
[ "$prc" = 0 ] || { echo "RESULT ABORT rcl: prep rc=$prc ($OUT/prep.log)"; exit 2; }
B=/mnt/shared/rcl_${LABEL}
timeout 20 $SSH "$X" "mkdir -p $B && sync -f $B" > /dev/null 2>&1
tests/fleet_set_params.sh "dbg_reclaim_hold=1" "$X" "$OUT/hold_set.txt" > /dev/null 2>&1
void=0; lap_fail=0; lap_pass=0; noreach=0; lapno=0
for arm in $ARMS; do
  k=${arm%%=*}
  tests/fleet_set_params.sh "$arm" "$X,$Y" "$OUT/knobs_${arm}_set.txt" > /dev/null 2>&1
  a_fail=0; a_pass=0; a_noreach=0
  for l in $(seq 1 "$LAPS"); do
    lapno=$((lapno + 1))
    D=$B/$lapno
    mark="RCL-MARK-${LABEL}-${lapno}"
    timeout 10 $SSH "$Y" "mkdir -p $D && for i in \$(seq 1 $N); do echo f\$i > $D/f\$i; done && sync -f $D && ls -i $D | awk '{print \$1}' | sort -n | tr '\n' ' '" \
        > "$OUT/lap${lapno}_f.txt" 2>/dev/null
    timeout 10 $SSH "$X" "echo $mark > /dev/kmsg; ls -l $D > /dev/null && rm -f $D/f* && sync -f $D" > /dev/null 2>&1
    timeout 10 $SSH "$Y" "for i in \$(seq 1 $N); do echo g\$i > $D/g\$i; done && sync -f $D && ls -i $D | awk '{print \$1}' | sort -n | tr '\n' ' '" \
        > "$OUT/lap${lapno}_g.txt" 2>/dev/null
    xs=$(timeout 10 $SSH "$X" "ls $D/g* 2>/dev/null | wc -l; bad=0; for i in \$(seq 1 $N); do [ \"\$(cat $D/g\$i 2>/dev/null)\" = g\$i ] || bad=\$((bad+1)); done; echo \$bad; dmesg | awk -v m='$mark' 'index(\$0, m) { s = 1; next } s' > /tmp/rcl_kmsg_${lapno}.txt; grep -c 'P26-IGET-FAIL' /tmp/rcl_kmsg_${lapno}.txt; grep -c 'P-NOINO-UNLOCK-LEFT-GRANT ino=.*lifecycle=RECLAIMABLE' /tmp/rcl_kmsg_${lapno}.txt; cat /tmp/rcl_kmsg_${lapno}.txt" 2>/dev/null)
    printf '%s\n' "$xs" | tail -n +5 > "$OUT/lap${lapno}_x_kmsg.txt"
    cnt=$(printf '%s\n' "$xs" | sed -n 1p); badc=$(printf '%s\n' "$xs" | sed -n 2p)
    igf=$(printf '%s\n' "$xs" | sed -n 3p); ulg=$(printf '%s\n' "$xs" | sed -n 4p)
    reach=$(comm -12 <(tr ' ' '\n' < "$OUT/lap${lapno}_f.txt" | grep . | sort) \
                     <(tr ' ' '\n' < "$OUT/lap${lapno}_g.txt" | grep . | sort) | grep -c .)
    v=PASS
    if [ "${cnt:-0}" != "$N" ] || [ "${igf:-0}" != 0 ] || [ "${badc:-1}" != 0 ]; then v=FAIL; fi
    [ "$reach" = 0 ] && [ "$v" = PASS ] && v=NOREACH
    echo "  LAP $lapno arm=$arm reach=$reach x_count=${cnt:-?}/$N x_bad_content=${badc:-?} p26_iget_fail=${igf:-?} noino_left_grant_reclaimable=${ulg:-?} verdict=$v"
    case $v in PASS) a_pass=$((a_pass+1));; FAIL) a_fail=$((a_fail+1));; NOREACH) a_noreach=$((a_noreach+1));; esac
  done
  tests/fleet_set_params.sh "$k dbg_reclaim_hold" "$X,$Y" "$OUT/knobs_${arm}_after.txt" > /dev/null 2>&1
  got=$(grep -c "$arm\b" "$OUT/knobs_${arm}_after.txt")
  if [ "$got" != 2 ]; then
    echo "  ARM $arm VOID: switch read back on $got of 2 nodes"; void=$((void+1))
  else
    echo "  ARM $arm pass=$a_pass fail=$a_fail noreach=$a_noreach"
  fi
  lap_fail=$((lap_fail + a_fail)); lap_pass=$((lap_pass + a_pass)); noreach=$((noreach + a_noreach))
done
tests/fleet_set_params.sh "dbg_reclaim_hold=0" "$X" "$OUT/hold_restore.txt" > /dev/null 2>&1
echo "  INFO pass=$lap_pass fail=$lap_fail noreach=$noreach void=$void evidence=$OUT"
[ "$void" = 0 ] || { echo "RESULT ABORT rcl: $void void arm(s)"; exit 2; }
[ "$lap_fail" -gt 0 ] && { echo "RESULT REPRODUCED rcl: $lap_fail lap(s) failed"; exit 1; }
[ "$lap_pass" -gt 0 ] && { echo "RESULT CLEAN rcl: every reached lap passed"; exit 0; }
echo "RESULT NOREACH rcl: no lap reused a freed number"; exit 3
