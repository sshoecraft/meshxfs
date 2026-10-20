#!/bin/bash
# tests/relog_pr_release_auth.sh <A> <B> [laps] [label]
#
# D-CAW-MPATH-8NODE-REUSED-INODE-NAMED-BY-TWO-DIRENTS-NLINK-1-AFTER-SUITE,
# hypothesis H-DN4: on CAW the synthetic re-log of the release drain (the
# P146V "clean-but-unlanded" arm) is authorized for a node that holds the
# directory only SHARED, because mxfs_dlm_relog_authorized read the mode
# through the held/not-held slot query, which reports any CAW slot bit of this
# node (PR included) as EX.  On the 8/disk/caw/mpath board test23, releasing a
# PR hold of the workload's LOCK directory, re-logged its out-of-date in-core
# core over test28's newer image.
#
# Shape, per lap, on a 2-node disk/caw rig, one arm per lap:
#   1. B makes a fresh directory D/dL holding one entry (b1) and syncs.
#   2. A arms dbg_relog_force_ino for dL (the next release drain of dL on A
#      takes the P146V arm once), then lists dL: A now holds dL SHARED.
#   3. B creates dL/b2: B asks EX, A's shared hold is released and its drain
#      takes the forced arm.  (If A's quiet-age release runs first, that is
#      the same PR release drain.)
#   4. Both nodes list dL: b1 and b2.
# The switch relog_auth_granted_mode is set on both nodes for the lap's arm:
#   C (0, today's read):  A must authorize and re-log under its shared hold:
#                         P146V-FORCE, P146V-AUTH granted_mode=3 raw_mode=5,
#                         P146V-RELOG-HOLDERS.  This is the cause reached: a
#                         directory core re-logged by a node with no EX.
#   F (1, the fix):       A must refuse: P146V-FORCE, P146V-NOAUTH-REFUSE
#                         granted_mode=3, no P146V-RELOG-HOLDERS.
# A lap whose forced arm never ran (no P146V-FORCE for dL on A), ran under a
# grant other than PR (granted_mode != 3), or met a dead prior incarnation of
# a reused number on A (foreign=1: refused for that reason in either arm) is
# UNREACHED and judges nothing.  Run it on a fresh prep: the module load drops
# every cached shell, and a second run on the same load reuses the numbers the
# first run's cleanup freed while A still caches their old incarnations.
# Always: both nodes list exactly b1 b2, no shutdown/corruption line, B's
# create rc=0.
# RESULT PASS  every C lap REPRODUCED (re-log under PR) and every F lap FIXED
#              (refused), at least one of each, no check failed.
# RESULT FAIL  a C lap that refused, an F lap that re-logged, or a check.
# RESULT INCONCLUSIVE  an arm with no reached lap.
# Budget: per lap 4 ssh round trips + the release (bounded by the CAW poll,
# well under 5 s on a healthy pair) + the 2 s settle: 30 s per lap.
set -u
cd /src/mxfs || exit 1
A=${1:?shared-holder node}; B=${2:?EX-requester node}; LAPS=${3:-4}; LABEL=${4:-prauth}
SSH=tools/mxfs_sshpass.sh
MNT=${MXFS_MNT:-/mnt/shared}
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_relogprauth_$LABEL
mkdir -p "$OUT"
. "$(dirname "$0")/lib/rig.sh"
PARAMS=/sys/module/mxfs/parameters
MARK="RELOGPRAUTH-$LABEL-$$"
D=$MNT/.relogprauth_$LABEL
echo "=== relog_pr_release_auth A=$A B=$B laps=$LAPS out=$OUT $(date -u +%FT%TZ) ==="
want=$(modinfo mxfs.ko | awk '/^srcversion:/{print $2}')
for n in $A $B; do
  nsv=$(rs 15 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
  [ "$nsv" = "$want" ] || { echo "RESULT FAIL relogprauth: $n srcversion '$nsv' != tree '$want'"; exit 2; }
  rs 15 "$n" "grep -q ' $MNT mxfs ' /proc/mounts && echo mounted" | grep -q mounted || { echo "RESULT FAIL relogprauth: $MNT not mounted on $n"; exit 2; }
  rs 15 "$n" "[ -f $PARAMS/relog_auth_granted_mode ] && [ -f $PARAMS/dbg_relog_force_ino ] && echo has" | grep -q has || { echo "RESULT FAIL relogprauth: $n build has no relog_auth_granted_mode/dbg_relog_force_ino"; exit 2; }
done
# the arm's lines are debug probes: switch on exactly these formats on A
measure "$A" 20 "$OUT/dyndbg_$A.txt" '^ON=[0-9]+$' "dyndbg on $A" "c=/proc/dynamic_debug/control; for f in P146V P58-DIRPIN P56-DIRWRITE; do echo \"module mxfs format \$f +p\" > \$c; done; echo ON=\$(grep -cE '=p.*(P146V|P58-DIRPIN|P56-DIRWRITE)' \$c)"
on=$(grep -ao '^ON=[0-9]*' "$OUT/dyndbg_$A.txt" | cut -d= -f2)
[ "${on:-0}" -ge 5 ] || { echo "RESULT FAIL relogprauth: only ${on:-0} probe sites enabled on $A"; exit 2; }
keep_mode=$(rs 15 "$A" "cat $PARAMS/relog_auth_granted_mode" | tr -dc '0-9')
restore() {
  for n in $A $B; do rs 15 "$n" "echo 0 > $PARAMS/dbg_relog_force_ino; echo ${keep_mode:-1} > $PARAMS/relog_auth_granted_mode" >/dev/null; done
}
trap restore EXIT
fails=0; c_rep=0; f_fix=0; unreached=0
rs 20 "$B" "mkdir -p $D && sync" >/dev/null
for L in $(seq 1 "$LAPS"); do
  if [ $((L % 2)) = 1 ]; then arm=C; sw=0; else arm=F; sw=1; fi
  tag=lap${L}$arm; MK="$MARK-$tag"; DL=$D/d$L
  for n in $A $B; do rs 15 "$n" "echo $sw > $PARAMS/relog_auth_granted_mode; echo '$MK' > /dev/kmsg" >/dev/null; done
  value_now_into swa "$A" 15 "$OUT/rv_sw_${tag}_$A.txt" '^[01]$' "switch on $A" "cat $PARAMS/relog_auth_granted_mode"
  value_now_into swb "$B" 15 "$OUT/rv_sw_${tag}_$B.txt" '^[01]$' "switch on $B" "cat $PARAMS/relog_auth_granted_mode"
  ck "$tag: switch read back $sw on $A" "$swa" "$sw"
  ck "$tag: switch read back $sw on $B" "$swb" "$sw"
  value_now_into mk "$B" 20 "$OUT/rv_mk_$tag.txt" '^MK rc=[0-9]+$' "mkdir on $B" "mkdir $DL && touch $DL/b1 && sync; echo MK rc=\$?"
  ck "$tag: $B made dL with b1" "${mk#MK rc=}" "0"
  value_now_into ino "$B" 15 "$OUT/rv_ino_$tag.txt" '^[0-9]+$' "ino of dL on $B" "stat -c %i $DL"
  rs 15 "$A" "echo $ino > $PARAMS/dbg_relog_force_ino" >/dev/null
  value_now_into lsA "$A" 15 "$OUT/rv_lsA_$tag.txt" '^LS=.*$' "listing on $A" "echo LS=\$(ls $DL)"
  ck "$tag: $A lists b1 under its shared hold" "${lsA#LS=}" "b1"
  value_now_into cr "$B" 20 "$OUT/rv_cr_$tag.txt" '^CR rc=[0-9]+$' "create b2 on $B" "touch $DL/b2; echo CR rc=\$?"
  ck "$tag: $B created b2 (rc=0)" "${cr#CR rc=}" "0"
  sleep 2
  rs 15 "$A" "echo 0 > $PARAMS/dbg_relog_force_ino" >/dev/null
  for n in $A $B; do
    value_now_into ls "$n" 15 "$OUT/rv_ls_${tag}_$n.txt" '^LS=.*$' "listing on $n" "echo LS=\$(ls $DL)"
    ck "$tag: $n lists b1 b2" "${ls#LS=}" "b1 b2"
  done
  measure "$A" 40 "$OUT/${tag}_$A.txt" '^DMESG_END$' "the kernel log on $A from the lap marker" "dmesg | sed -n \"/$MK/,\\\$p\" | grep -a 'P146V\|P58-DIRPIN\|P56-DIRWRITE ino=$ino \|shutdown\|Corruption\|corruption'; echo DMESG_END"
  measure "$B" 40 "$OUT/${tag}_$B.txt" '^DMESG_END$' "the kernel log on $B from the lap marker" "dmesg | sed -n \"/$MK/,\\\$p\" | grep -a 'shutdown\|Corruption\|corruption'; echo DMESG_END"
  af="$OUT/${tag}_$A.txt"
  ck "$tag: no shutdown/corruption lines on $A/$B" "$(cat "$af" "$OUT/${tag}_$B.txt" | grep -ac 'shutdown\|Corruption\|corruption')" "0"
  forced=$(grep -ac "P146V-FORCE ino=$ino " "$af")
  auth=$(grep -a "P146V-AUTH ino=$ino " "$af" | tail -1)
  refuse=$(grep -a "P146V-NOAUTH-REFUSE ino=$ino " "$af" | tail -1)
  relog=$(grep -ac "P146V-RELOG-HOLDERS ino=$ino " "$af")
  gm=$(printf '%s\n%s\n' "$auth" "$refuse" | grep -ao 'granted_mode=[0-9]*' | tail -1 | cut -d= -f2)
  rawm=$(printf '%s\n%s\n' "$auth" "$refuse" | grep -ao 'raw_mode=[0-9]*' | tail -1 | cut -d= -f2)
  fgn=$(printf '%s\n%s\n' "$auth" "$refuse" | grep -ao 'foreign=[0-9]*' | tail -1 | cut -d= -f2)
  if [ "$forced" -lt 1 ] || [ "${gm:-x}" != 3 ] || [ "${fgn:-x}" != 0 ]; then
    verdict=UNREACHED; unreached=$((unreached+1))
  elif [ "$arm" = C ]; then
    if [ -n "$auth" ] && [ "$relog" -ge 1 ]; then verdict=REPRODUCED; c_rep=$((c_rep+1)); else verdict=CONTROL-REFUSED; fails=$((fails+1)); fi
  else
    if [ -n "$refuse" ] && [ "$relog" = 0 ]; then verdict=FIXED; f_fix=$((f_fix+1)); else verdict=FIX-RELOGGED; fails=$((fails+1)); fi
  fi
  echo "  RESULT $tag arm=$arm switch=$sw ino=$ino verdict=$verdict forced=$forced granted_mode=${gm:-none} raw_mode=${rawm:-none} foreign=${fgn:-none} authorized=$([ -n "$auth" ] && echo 1 || echo 0) refused=$([ -n "$refuse" ] && echo 1 || echo 0) relogs=$relog"
  grep -a "P146V\|P58-DIRPIN\|P56-DIRWRITE" "$af" | cut -c1-260 | sed 's/^/    /'
done
rs 30 "$B" "rm -rf $D" >/dev/null
echo "  INFO laps=$LAPS control_reproduced=$c_rep fix_refused=$f_fix unreached=$unreached fails=$fails evidence=$OUT"
[ "$fails" = 0 ] || { echo "RESULT FAIL relogprauth: fails=$fails control_reproduced=$c_rep fix_refused=$f_fix out=$OUT"; exit 1; }
[ "$c_rep" -ge 1 ] && [ "$f_fix" -ge 1 ] || { echo "RESULT INCONCLUSIVE relogprauth: control_reproduced=$c_rep fix_refused=$f_fix unreached=$unreached out=$OUT"; exit 3; }
echo "RESULT PASS relogprauth: control_reproduced=$c_rep (a shared holder's synthetic re-log authorized and taken) fix_refused=$f_fix (refused, no re-log) unreached=$unreached out=$OUT"
exit 0
