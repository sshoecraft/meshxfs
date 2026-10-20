#!/bin/bash
# tests/recreated_dir_peer_mkdir.sh <configuration> <group> <X> <Y> [laps] [label]
#
# Directed repro for D-ALLOC-WITNESS-PEER-MKDIR-ESTALE-ON-POISONED-CACHED-DIR-4CAW,
# with an optional same-build A/B of KNOB (unset: one reach arm, no switch).
#
# Measured on 4/disk/caw/direct (alloc_witness, 0.90.131): a node removed a
# directory and recreated it on the same number; the peers' cached dentry of
# it kept their copy of the old incarnation, their mkdir under it poisoned that
# copy and was refused -116 (P240-QUAR-NSOP-REFUSE op=create), and the VFS's
# LOOKUP_REVAL retry walked the same dentry (d_revalidate approves on the
# number alone) and was refused again: mkdir failed ESTALE.
#
# Per lap, in B=/mnt/shared/rdm_<label>, X = the recreating node, Y = the peer:
#   X creates directory p<lap> and syncs, and records its number;
#   Y stats and lists B/p<lap> (its dentry, its in-core copy of that
#     incarnation and a read grant on it);
#   X removes p<lap>, syncs, waits REUSE_GAP seconds (the measured reuse came
#     10 s after the removal: the free lands at the release, not the rmdir),
#     creates p<lap> again, syncs (unless RECREATE_SYNC=0), and records its
#     number;
#   Y runs mkdir -p B/p<lap>/c (under strace when the node has it: coreutils
#     mkdir -p changes into each existing ancestor and creates the last
#     component relative to it, H-AW2) and reads its kernel log since the
#     lap's mark.
# FIRST=file: X's first p<lap> is a regular file (touch, then rm), so Y's
# cached copy is a file shell and the recreated directory on its number is a
# type flip (D-TYPEFLIP-RESOLVER-RELOADS-POISONED-SHELL-200-ROUNDS-ESTALE: the
# lookup's type-flip resolver reloads the shell its reload poisoned for 200
# rounds and fails the walk -ESTALE).  Default dir: the same-type case.
# NEWNAME=1: X recreates the directory under a NEW name n<lap> (not p<lap>),
# and Y runs mkdir -p B/n<lap>/c.  Y's dentry of the old name p<lap> is then
# never walked, so nothing revalidates and drops it, and it keeps Y's shell of
# the number's previous incarnation referenced while Y's lookup of the new
# name reaches the number (the 2/net/mesh/mpath alloc_witness shape: test18
# reached run directory ino 12140 by its new name while a dentry of the
# number's previous directory held the shell, aliases=1 inuse=1).
# HOLDCWD=1: before X removes p<lap>, a process on Y changes into it and
# sleeps there (killed at the end of the lap), so Y's dentry of the removed
# directory is IN USE when the number comes back: nothing can prune it, and
# the shell stays referenced (the rig's aliases=1 inuse=1; NEWNAME=1 alone
# left aliases=0 inuse=0 and every lap retired the shell and passed, rdmn1).
# YCACHE=cd: Y caches p<lap> by changing into it and out again, and nothing
# else: the lookup instantiates its shell from the dinode under the parent's
# lock and no operation takes a grant on p<lap> itself, so Y's shell has never
# held one (i_dlm_epoch 1).  Default stat: Y stats and lists it (a grant held
# and lost, epoch above 1).  The board's peers had cached alloc_witness from
# earlier runs; whether they had ever held its grant is not in their logs.
# YCACHE=none: Y caches nothing of p<lap>.  With NEWNAME=1 RMSYNC=0
# RECREATE_SYNC=0 the platter still holds the removed directory's dinode (X
# synced it after creating it) while X holds the new incarnation unwritten, so
# Y's lookup of n<lap> reads the dead incarnation from the platter into a fresh
# shell that has never held a grant (i_dlm_epoch 1), and the lookup's
# grant-taking verify skips epoch-1 directories (the 2/net/mesh/mpath
# alloc_witness shape: test18 had no earlier line for the shell's generation
# and no P-LKUP-DIR-INCARN line at all, cur_ep=1).
# YCACHE=eexist: Y's only contact with p<lap> is a mkdir of it that answers
# EEXIST, pathload's mutex step (mkdir LOCK): the lookup instantiates Y's
# shell and its dentry and nothing takes a grant on p<lap> (YCACHE=cd does:
# the walk's permission check took PR in rdmy1).  Measured on 2/net/mesh/mpath
# (run 20261019T182250Z-g2e): test18's dead shell of 12140 was a LOCK
# incarnation test17 made and removed within one second, with no grant of
# test18's on it logged.
# YOP=cdmk: Y runs cd P && mkdir c instead of mkdir -p P/c, so the chdir's own
# lookup is the one that meets the reused number and its result becomes the
# cwd (the 2/net/mesh/mpath fence_during_write shape: test32's mkdir lost the
# create race, its negative dentry was dropped, and mkdir -p's chdir looked the
# name up fresh and got the shell the same-type resolver had just poisoned).
# PAR=n: Y runs n-1 more mkdir -p P/c alongside the timed one, so the stale
# shell is referenced by more than one walker and the lookup's eviction of it
# cannot make it reclaimable (the type-flip resolver is reached only then).
# Any of them failing fails the lap.
# REACH: the recreated p<lap> has the removed one's number.  A lap without it
# says nothing about the defect (NOREACH).
# FAIL (per reached lap): Y's mkdir fails, or takes longer than MK_BUDGET_MS
# (the same-type resolver reloading a poisoned shell for 200 rounds took 2.4 s).
#
# ARMS: with KNOB set, KNOB=1 (the fix) then KNOB=0 (the control), LAPS each, set on both
# nodes before an arm's laps and read back after them (a module reload in
# between puts every parameter back: the arm is VOID).
#
# Budget per lap: 5 ssh round trips (~0.3 s each), a mkdir/rmdir/sync each
# (native XFS: milliseconds), REUSE_GAP: 2 + REUSE_GAP s of work; bound
# 10 + REUSE_GAP s per lap.  Prep 300 s (manifest).
set -u
cd "$(dirname "$0")/.." || exit 1
CFG=${1:?configuration}; G=${2:?rig group}; X=${3:?recreating node}; Y=${4:?peer node}
LAPS=${5:-10}; LABEL=${6:-rdm}
KNOB=${KNOB:-}
GAP=${REUSE_GAP:-2}
FIRST=${FIRST:-dir}
PAR=${PAR:-1}
PARCMD=""
[ "$PAR" -gt 1 ] && PARCMD="for i in \$(seq 2 $PAR); do ( mkdir -p \$P/c 2>&1; echo prc=\$? ) & done;"
case $FIRST in
  dir) MK1=mkdir; RM1=rmdir ;;
  file) MK1=touch; RM1="rm -f" ;;
  *) echo "FIRST must be dir or file (got $FIRST)"; exit 2 ;;
esac
# The peer's mkdir -p is a per-name operation; its budget is posix_multi's
# per-name share of its 25 s report budget for 128 names (195 ms).
MK_BUDGET_MS=${MK_BUDGET_MS:-195}
# RECREATE_SYNC=0: X does not sync after recreating P, so the new
# incarnation's dinode is still only in X's log when Y walks P (the board's
# race: test4 revalidated alloc_witness against a platter rank 1 had not
# written yet, and mkdir -p's cwd became the dead incarnation).
RSYNC="sync -f /mnt/shared/rdm_${LABEL} &&"; [ "${RECREATE_SYNC:-1}" = 0 ] && RSYNC=""
# RMSYNC=0: X does not sync after removing P either, so the free stays in X's
# log with the grant cached (the board's test3: P128-INACT-DEFER 'freed
# dinode undestaged; keeping grant cached') when X recreates P on the number.
RMS="sync -f /mnt/shared/rdm_${LABEL} &&"; [ "${RMSYNC:-1}" = 0 ] && RMS=""
SSH=tools/mxfs_sshpass.sh
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_rdm_$LABEL
mkdir -p "$OUT"
LB=$((10 + GAP))
echo "=== recreated_dir_peer_mkdir cfg=$CFG group=$G X=$X Y=$Y laps=$LAPS knob=$KNOB first=$FIRST par=$PAR newname=${NEWNAME:-0} holdcwd=${HOLDCWD:-0} ycache=${YCACHE:-stat} yop=${YOP:-mkdirp} gap=${GAP}s recreate_sync=${RECREATE_SYNC:-1} rm_sync=${RMSYNC:-1} tree=$(pwd) sv=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="
MXFS_FORCE_PREP=1 timeout 300 ./run.sh "$CFG" --group "$G" prep_cluster > "$OUT/prep.log" 2>&1
prc=$?
[ "$prc" = 0 ] || { echo "RESULT ABORT rdm: prep rc=$prc ($OUT/prep.log)"; exit 2; }
B=/mnt/shared/rdm_${LABEL}
timeout 20 $SSH "$X" "mkdir -p $B && sync -f $B" > /dev/null 2>&1
void=0; f_fail=0; f_pass=0; c_fail=0; c_pass=0; noreach=0; lapno=0
VALS="1 0"; [ -n "$KNOB" ] || VALS=none
for v in $VALS; do
  [ -n "$KNOB" ] && tests/fleet_set_params.sh "$KNOB=$v" "$X,$Y" "$OUT/knobs_${v}_set.txt" > /dev/null 2>&1
  for l in $(seq 1 "$LAPS"); do
    lapno=$((lapno + 1))
    P=$B/p$lapno
    mark="RDM-MARK-${LABEL}-${lapno}"
    i1=$(timeout $LB $SSH "$X" "$MK1 $P && sync -f $B && stat -c %i $P" 2>/dev/null | tail -1)
    YC="stat $P > /dev/null; ls $P > /dev/null; ls -l $B > /dev/null"
    [ "${YCACHE:-stat}" = cd ] && YC="cd $P && cd /"
    [ "${YCACHE:-stat}" = none ] && YC=":"
    [ "${YCACHE:-stat}" = eexist ] && YC="mkdir $P 2>/dev/null; true"
    timeout $LB $SSH "$Y" "echo $mark > /dev/kmsg; $YC" > /dev/null 2>&1
    # the cwd holder lives 3 lap bounds at most, and is killed below
    [ "${HOLDCWD:-0}" = 1 ] && timeout $LB $SSH "$Y" "cd $P && nohup setsid sleep $((3 * LB)) > /dev/null 2>&1 < /dev/null & echo \$! > /tmp/rdm_hold_${lapno}.pid" > /dev/null 2>&1
    Q=$P; [ "${NEWNAME:-0}" = 1 ] && Q=$B/n$lapno
    i2=$(timeout $LB $SSH "$X" "$RM1 $P && $RMS sleep $GAP && mkdir $Q && $RSYNC stat -c %i $Q" 2>/dev/null | tail -1)
    P=$Q
    YMK="mkdir -p $P/c"; [ "${YOP:-mkdirp}" = cdmk ] && YMK="sh -c 'cd $P && mkdir c'"
    ys=$(timeout $LB $SSH "$Y" "P=$P; $PARCMD t0=\$(date +%s%N); if command -v strace > /dev/null; then strace -f -e trace=chdir,fchdir,mkdir,mkdirat,openat,newfstatat -o /tmp/rdm_strace_${lapno}.txt $YMK 2>&1; else $YMK 2>&1; fi; echo rc=\$?; echo mk_ms=\$(( (\$(date +%s%N) - t0) / 1000000 )); wait; cat /tmp/rdm_strace_${lapno}.txt 2>/dev/null | grep -E 'mkdir|chdir|ESTALE' | sed 's/^/STRACE /'; dmesg | awk -v m='$mark' 'index(\$0, m) { s = 1; next } s' > /tmp/rdm_kmsg_${lapno}.txt; echo p240=\$(grep -c 'P240-QUAR-NSOP-REFUSE' /tmp/rdm_kmsg_${lapno}.txt) drop=\$(grep -c 'P-DREVAL-DIR-INCARN ' /tmp/rdm_kmsg_${lapno}.txt) poison=\$(grep -c 'P-RELOAD-XINCARN-POISON' /tmp/rdm_kmsg_${lapno}.txt); cat /tmp/rdm_kmsg_${lapno}.txt" 2>/dev/null)
    printf '%s\n' "$ys" > "$OUT/lap${lapno}_y.txt"
    [ "${HOLDCWD:-0}" = 1 ] && timeout $LB $SSH "$Y" "kill \$(cat /tmp/rdm_hold_${lapno}.pid) 2>/dev/null" > /dev/null 2>&1
    rc=$(printf '%s\n' "$ys" | grep -o '^rc=[0-9]*' | head -1 | cut -d= -f2)
    pbad=$(printf '%s\n' "$ys" | grep -c '^prc=[1-9]')
    [ "$pbad" -gt 0 ] && [ "${rc:-1}" = 0 ] && rc=1
    mk=$(printf '%s\n' "$ys" | grep -o '^mk_ms=[0-9]*' | head -1 | cut -d= -f2)
    p95c=$(printf '%s\n' "$ys" | grep -c 'P95C-SAMETYPE-WAIT')
    tf=$(printf '%s\n' "$ys" | grep -c 'P95-TYPEFLIP-RELOAD')
    tfr=$(printf '%s\n' "$ys" | grep -c 'P95-TYPEFLIP-POISON-RETIRE')
    p201=$(printf '%s\n' "$ys" | grep -c 'P201-TYPEFLIP-UNRESOLVED-FAIL')
    err=$(printf '%s\n' "$ys" | grep -m1 '^mkdir:' | cut -c1-160)
    cnts=$(printf '%s\n' "$ys" | grep -m1 '^p240=')
    verdict=PASS; [ "${rc:-1}" = 0 ] && [ "${mk:-999999}" -le "$MK_BUDGET_MS" ] || verdict=FAIL
    if [ -z "$i1" ] || [ "$i1" != "$i2" ]; then
      [ "$verdict" = PASS ] && verdict=NOREACH
    fi
    echo "  LAP $lapno ${KNOB:-switch}=$v ino_before=${i1:-?} ino_after=${i2:-?} mkdir_rc=${rc:-?} par_fail=${pbad:-0} mk_ms=${mk:-?} p95c=$p95c tf_reload=$tf tf_retire=$tfr p201=$p201 ${cnts} verdict=$verdict ${err:+err=[$err]}"
    case "$v:$verdict" in
      1:PASS) f_pass=$((f_pass+1));; 1:FAIL) f_fail=$((f_fail+1));;
      0:PASS|none:PASS) c_pass=$((c_pass+1));; 0:FAIL|none:FAIL) c_fail=$((c_fail+1));;
      *:NOREACH) noreach=$((noreach+1));;
    esac
  done
  [ -n "$KNOB" ] || continue
  tests/fleet_set_params.sh "$KNOB" "$X,$Y" "$OUT/knobs_${v}_after.txt" > /dev/null 2>&1
  got=$(grep -c "$KNOB=$v\b" "$OUT/knobs_${v}_after.txt")
  [ "$got" = 2 ] || { echo "  ARM $KNOB=$v VOID: read back on $got of 2 nodes"; void=$((void+1)); }
done
[ -n "$KNOB" ] && tests/fleet_set_params.sh "$KNOB=1" "$X,$Y" "$OUT/knobs_restore.txt" > /dev/null 2>&1
echo "  INFO f_pass=$f_pass f_fail=$f_fail c_pass=$c_pass c_fail=$c_fail noreach=$noreach void=$void evidence=$OUT"
[ "$void" = 0 ] || { echo "RESULT ABORT rdm: $void void arm(s)"; exit 2; }
[ "$f_fail" -gt 0 ] && { echo "RESULT REFUTED rdm: fix arm failed $f_fail reached lap(s)"; exit 1; }
[ -z "$KNOB" ] && [ "$c_fail" -gt 0 ] && { echo "RESULT REPRODUCED rdm: $c_fail reached lap(s) failed"; exit 1; }
[ "$c_fail" -gt 0 ] && { echo "RESULT SUPPORTED rdm: control failed $c_fail, fix passed $f_pass reached lap(s)"; exit 0; }
echo "RESULT NOREACH rdm: the control never failed (reached control laps: $c_pass)"; exit 3
