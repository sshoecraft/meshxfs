#!/bin/bash
# tests/sf_readdir_stale_view.sh <A> <B> [laps] [label]
#
# D-DIRVIEW-NONCONVERGE-SESS25, measured again on the 0.90.131 release build
# (8/disk/caw/direct dirent_durability, run 20261019T214738Z-g8): test11's
# `ls` of six shortform round directories still lacked three peers' entries
# after the row's 4 s settle, while rank 1 listed them and the platter held
# them (the peers' P56-DIRWRITE of ino 142 at 21:49:01-02 carried every name).
# test11 had made its own entry under EX, listed the directory under that EX
# (P212-RDRETRY-SKIP ino=142 at 21:48:46), released the EX at 21:48:56 and
# received the peers' change event (EVICT-RING-DIRMOD ino=142 reload=1); from
# 21:49:02 to 21:49:18 it logged no acquire and no reload of the directory.
#
# H-DV1 (written before any patch): a shortform directory's listing is served
# from the in-core inline fork.  xfs_file_readdir (pal/linux/xfs_file.c) takes
# ILOCK_SHARED around xfs_readdir for a LOCAL-format directory; inside it, a
# non-EX reader of a directory that has seen peer activity (dir_gen > 0, or the
# reload flag armed by the change event) asks for a reload, and the reload can
# never land under the caller's own shared hold (P212-RDRETRY-SKIP), so the
# stale fork is served and the reload re-armed.  The reload before the ILOCK
# (the P95D loop) runs only when i_dlm_stale is set.  If nothing outside
# readdir touches the directory, every listing is the stale one.
#
# Shape, per lap, on a 2-node rig (A = the reader that goes stale):
#   1. B makes a fresh directory D (shortform) and syncs.
#   2. A lists D, makes D/a1 (A holds D EX), lists D again under that EX, syncs.
#   3. B makes D/b1 D/b2 D/b3 and syncs: B takes D EX from A.
#   4. A lists D every 100 ms for 5 s: CONVERGED (ms) once it shows a1 b1 b2
#      b3; STALE if it never does.  5 s is three times the worst propagation
#      dirent_durability measured (1573 ms).
#   5. A stats D/b1 (a lookup) and lists again: whether a lookup heals it.
#   6. A's kernel log from the lap mark, lines naming D's inode.
# RESULT REPRODUCED  any lap STALE (the defect reached).
# RESULT CLEAN       every lap CONVERGED.
# Budget per lap: 4 ssh round trips + 5 s poll + log read: 15 s.
set -u
A=${1:?reader node}; B=${2:?writer node}; LAPS=${3:-10}; LABEL=${4:-sfrv}
cd "$(dirname "$0")/.." || exit 1
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_sfrv_$LABEL
mkdir -p "$OUT"
. tests/lib/rig.sh
MARK="SFRV-$LABEL-$$"
BASE=$MNT/.sfrv_$LABEL
echo "=== sf_readdir_stale_view A=$A B=$B laps=$LAPS sv=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="
want=$(modinfo -F srcversion mxfs.ko)
for n in $A $B; do
  nsv=$(rs 15 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
  [ "$nsv" = "$want" ] || { echo "RESULT ABORT sfrv: $n srcversion '$nsv' != tree '$want'"; exit 2; }
  rs 15 "$n" "grep -q ' $MNT mxfs ' /proc/mounts && echo mounted" | grep -q mounted || { echo "RESULT ABORT sfrv: $MNT not mounted on $n"; exit 2; }
done
# the arm's lines are debug probes: switch these formats on at A
measure "$A" 20 "$OUT/dyndbg_$A.txt" '^ON=[0-9]+$' "dyndbg on $A" "c=/proc/dynamic_debug/control; for f in P212-RDRETRY P95D-READDIR P63-HANDOFF P65-EPOCH P6-MIDTENURE P34F-RELOAD P-RELOAD-IDENTICAL P68-PREEVICT P60-RD P48-RD P173-RELOAD; do echo \"module mxfs format \$f +p\" > \$c; done; echo ON=\$(grep -cE '=p.*(P212-RDRETRY|P95D-READDIR)' \$c)"
on=$(grep -ao '^ON=[0-9]*' "$OUT/dyndbg_$A.txt" | cut -d= -f2)
[ "${on:-0}" -ge 2 ] || { echo "RESULT ABORT sfrv: only ${on:-0} of the P212/P95D probe sites enabled on $A"; exit 2; }
fails=0; stale=0; conv=0
rs 20 "$B" "mkdir -p $BASE && sync -f $BASE" >/dev/null
for L in $(seq 1 "$LAPS"); do
  D=$BASE/d$L; MK="$MARK-$L"
  rs 15 "$A" "echo '$MK' > /dev/kmsg" >/dev/null
  value_now_into ino "$B" 20 "$OUT/rv_mk_$L.txt" '^INO=[0-9]+$' "mkdir D on $B" "mkdir $D && sync -f $D && echo INO=\$(stat -c %i $D)"
  ino=${ino#INO=}
  value_now_into a1 "$A" 20 "$OUT/rv_a1_$L.txt" '^A1 rc=[0-9]+ ls=.*$' "a1 on $A" "ls $D >/dev/null; mkdir $D/a1; r=\$?; echo A1 rc=\$r ls=\$(ls $D | tr '\n' ' '); sync -f $D"
  value_now_into bm "$B" 20 "$OUT/rv_b_$L.txt" '^B rc=[0-9]+$' "b1-b3 on $B" "mkdir $D/b1 $D/b2 $D/b3 && sync -f $D; echo B rc=\$?"
  ck "lap$L: $B made b1 b2 b3" "${bm#B rc=}" "0"
  value_now_into poll "$A" 20 "$OUT/rv_poll_$L.txt" '^POLL .*$' "the listing poll on $A" \
    "s=\$(date +%s%3N); r=STALE; last=; for i in \$(seq 1 50); do last=\$(ls $D | tr '\n' ' '); case \"\$last\" in 'a1 b1 b2 b3 ') r=CONVERGED; break;; esac; sleep 0.1; done; e=\$(date +%s%3N); echo POLL \$r ms=\$((e-s)) last=[\$last]"
  value_now_into heal "$A" 20 "$OUT/rv_heal_$L.txt" '^HEAL .*$' "lookup then listing on $A" "stat $D/b1 >/dev/null 2>&1; s=\$?; echo HEAL stat_rc=\$s ls=[\$(ls $D | tr '\n' ' ')]"
  window_into "$OUT/kmsg_${L}_$A.txt" "$A" 30 "$MK"
  grep -aE "(ino|dp|pino|parent)=$ino\b|$MK" "$OUT/kmsg_${L}_$A.txt" > "$OUT/kmsg_${L}_${A}_d.txt"
  count_file_into p212 "$OUT/kmsg_${L}_${A}_d.txt" "P212-RDRETRY-SKIP ino=$ino "
  count_file_into p95d "$OUT/kmsg_${L}_${A}_d.txt" "P95D-READDIR-WAIT ino=$ino "
  count_file_into dirmod "$OUT/kmsg_${L}_${A}_d.txt" "EVICT-RING-DIRMOD ino=$ino "
  count_file_into sd "$OUT/kmsg_${L}_$A.txt" 'shutdown\|Corruption\|corruption'
  ck "lap$L: no shutdown/corruption line on $A" "$sd" "0"
  case $poll in
    "POLL CONVERGED"*) conv=$((conv + 1)); v=CONVERGED ;;
    *) stale=$((stale + 1)); v=STALE ;;
  esac
  echo "  LAP $L ino=$ino $v ${poll#POLL } a1=[${a1#A1 }] heal=[${heal#HEAL }] p212=$p212 p95d=$p95d dirmod=$dirmod"
done
echo "  INFO laps=$LAPS converged=$conv stale=$stale fails=$fails evidence=$OUT"
[ "$fails" -gt 0 ] && { echo "RESULT FAIL sfrv: $fails check(s) failed out=$OUT"; exit 1; }
[ "$stale" -gt 0 ] && { echo "RESULT REPRODUCED sfrv: $stale of $LAPS laps never listed the peer's entries within 5 s out=$OUT"; exit 1; }
echo "RESULT CLEAN sfrv: every lap converged out=$OUT"
