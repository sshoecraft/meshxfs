#!/bin/bash
# open_wedged_inode.sh — D-OPEN-PROTECT-RESTART-LOOP-UNBOUNDED-AND-UNKILLABLE:
# an open whose protecting acquire is refused outright must fail, and an open
# waiting out contention must still die when it is killed.
#
# Observed (16/disk/caw/mpath path_all_lost, 0.90.123): a remounted node's
# open of an inode its new mount believed WEDGED restarted forever in
# mxfs_dlm_open_protect (state R, P95-OPEN-PROTECT-RESTART at its cap), and
# the harness's SIGKILL did not end it (next row: STRAY killed=1 left=1).
#
# Two cases on node A, each on a file B created (so A holds no cached grant
# and its open must acquire):
#   W  dbg_openprotect_wedge_ino marks the inode WEDGED at open entry.  The
#      open must return an error within OPEN_MS and leave no task behind.
#   R  dbg_openprotect_refuse_ino reads every admission as "no grant" —
#      persistent contention, which the loop is meant to keep waiting out.
#      The open must still be running after HOLD_S (the loop is live), and
#      must be gone within KILL_S of SIGKILL.
# OPEN_MS: a refused acquire is decided on the first ride, milliseconds; 1 s.
# KILL_S: a killed task leaves at its next restart lap (cond_resched per lap,
# or the 30 s demote wait); 2 s with no demote in flight.
#
# Budget: two file creates, two cases of HOLD_S + KILL_S + ssh, kernel log
# pull: ~30 s.
#
# Usage: tests/open_wedged_inode.sh <label> <A> <B>
set -u
LABEL=${1:?label}; A=${2:?node A}; B=${3:?node B}
OPEN_MS=1000; HOLD_S=3; KILL_S=2
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO"
SSH=tools/mxfs_sshpass.sh
MNT=${MXFS_MNT:-/mnt/shared}
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_owi_$LABEL
mkdir -p "$OUT"
. "$(dirname "$0")/lib/rig.sh"
fails=0
D="$MNT/.owi_$LABEL"
MARK="OWI-$LABEL-$$"
P=/sys/module/mxfs/parameters

echo "=== open_wedged_inode label=$LABEL A=$A B=$B out=$OUT $(date -u +%FT%TZ) ==="
want=$(modinfo mxfs.ko | awk '/^srcversion:/{print $2}')
for n in "$A" "$B"; do
    nsv=$(rs 15 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$nsv" = "$want" ] || { echo "ABORT: $n srcversion '$nsv' != tree '$want'"; echo "RESULT: ABORT label=$LABEL stage=srcversion evidence=$OUT"; exit 2; }
    rs 12 "$n" "echo '$MARK' > /dev/kmsg" >/dev/null
done
measure "$B" 30 "$OUT/create.txt" '^INOS [0-9]+ [0-9]+$' "file creation on $B" \
    "rm -rf $D; mkdir $D && echo w > $D/fw && echo r > $D/fr && sync && echo INOS \$(stat -c %i $D/fw) \$(stat -c %i $D/fr)"
ino_w=$(awk '/^INOS/ {print $2}' "$OUT/create.txt"); ino_r=$(awk '/^INOS/ {print $3}' "$OUT/create.txt")
echo "  INFO fw ino=$ino_w fr ino=$ino_r"

# case W: one line  W rc=<n> ms=<n> left=<0|1> state=<s>
measure "$A" 30 "$OUT/case_w.txt" '^W rc=[0-9]+ ms=[0-9]+ left=[01]' "case W on $A" \
    "echo $ino_w > $P/dbg_openprotect_wedge_ino; t0=\$(date +%s%3N); cat $D/fw >/dev/null 2>&1 & pid=\$!; i=0; while [ -d /proc/\$pid ] && [ \$i -lt $((OPEN_MS / 50)) ]; do sleep 0.05; i=\$((i+1)); done; if [ -d /proc/\$pid ]; then st=\$(awk '{print \$3}' /proc/\$pid/stat); kill -9 \$pid; sleep $KILL_S; left=\$([ -d /proc/\$pid ] && echo 1 || echo 0); rc=999; else wait \$pid; rc=\$?; st=-; left=0; fi; echo 0 > $P/dbg_openprotect_wedge_ino; echo \"W rc=\$rc ms=\$(( \$(date +%s%3N) - t0 )) left=\$left state=\$st\""
rc_w=$(sed -n 's/^W rc=\([0-9]*\).*/\1/p' "$OUT/case_w.txt"); ms_w=$(sed -n 's/^W .* ms=\([0-9]*\).*/\1/p' "$OUT/case_w.txt")
left_w=$(sed -n 's/^W .* left=\([01]\).*/\1/p' "$OUT/case_w.txt")
echo "  INFO case W: $(grep -a '^W ' "$OUT/case_w.txt")"
ck "W: the open of a wedged inode returned within ${OPEN_MS} ms" "$([ "$rc_w" != 999 ] && echo yes || echo no)" yes
ck "W: the open failed (a refused acquire is never a successful open)" "$([ "$rc_w" != 0 ] && [ "$rc_w" != 999 ] && echo yes || echo no)" yes
ck "W: no task left behind" "$left_w" 0

# case R: one line  R alive_after_hold=<0|1> state=<s> left_after_kill=<0|1>
measure "$A" $((HOLD_S + KILL_S + 30)) "$OUT/case_r.txt" '^R alive_after_hold=[01] ' "case R on $A" \
    "echo $ino_r > $P/dbg_openprotect_refuse_ino; cat $D/fr >/dev/null 2>&1 & pid=\$!; sleep $HOLD_S; alive=\$([ -d /proc/\$pid ] && echo 1 || echo 0); st=\$(awk '{print \$3}' /proc/\$pid/stat 2>/dev/null); kill -9 \$pid 2>/dev/null; sleep $KILL_S; left=\$([ -d /proc/\$pid ] && echo 1 || echo 0); echo 0 > $P/dbg_openprotect_refuse_ino; sleep 1; left2=\$([ -d /proc/\$pid ] && echo 1 || echo 0); echo \"R alive_after_hold=\$alive state=\${st:--} left_after_kill=\$left left_after_knob_off=\$left2\""
echo "  INFO case R: $(grep -a '^R ' "$OUT/case_r.txt")"
ck "R: the contended open was still restarting after ${HOLD_S}s (the loop was live)" "$(sed -n 's/^R alive_after_hold=\([01]\).*/\1/p' "$OUT/case_r.txt")" 1
ck "R: SIGKILL ended it within ${KILL_S}s" "$(sed -n 's/.* left_after_kill=\([01]\).*/\1/p' "$OUT/case_r.txt")" 0

for n in "$A" "$B"; do
    measure "$n" 30 "$OUT/kmsg_$n.txt" '^KMSG_END$' "the kernel log on $n from the run marker" "dmesg | sed -n '/$MARK/,\$p'; echo KMSG_END"
    ck "$n: no shutdown, BUG, oops or hung task" "$(cnt "$OUT/kmsg_$n.txt" 'P-SESSION-POISON\|force-shutdown\|Internal error\|BUG:\|Oops\|blocked for more than')" 0
done
echo "  INFO $A: P95-OPEN-WEDGE-INJECT=$(cnt "$OUT/kmsg_$A.txt" 'P95-OPEN-WEDGE-INJECT') P-INODE-WEDGE-FENCE=$(cnt "$OUT/kmsg_$A.txt" 'P-INODE-WEDGE-FENCE') P95-OPEN-REFUSED=$(cnt "$OUT/kmsg_$A.txt" 'P95-OPEN-REFUSED') P95-OPEN-KILLED=$(cnt "$OUT/kmsg_$A.txt" 'P95-OPEN-KILLED')"
ckge "W reached the wedge refusal (P-INODE-WEDGE-FENCE)" "$(cnt "$OUT/kmsg_$A.txt" 'P-INODE-WEDGE-FENCE')" 1

rs 30 "$B" "rm -rf $D" >/dev/null
echo "RESULT: $([ $fails -eq 0 ] && echo PASS || echo FAIL) label=$LABEL fails=$fails evidence=$OUT"
exit $((fails > 0))
