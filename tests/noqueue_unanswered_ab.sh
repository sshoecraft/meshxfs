#!/bin/bash
# tests/noqueue_unanswered_ab.sh — same-build A/B of the answer a no-queue lock
# request gives when its master never answers (module knob
# dl_noqueue_unanswered_wouldblock), for
# D-NETMESH-SURVIVOR-ILOCK-HELD-ACROSS-DEAD-MASTER-AG-RETRY-PINS-AIL-131S and
# D-RECOVERY-FLUSH-WAITS-ON-AIL-PINNED-BY-ILOCK-HOLDER-WAITING-ON-DEAD-MASTER.
#
# THE INCIDENT (0.90.53, 8/net/mesh/mpath path_all_lost): a survivor's rename
# held the ILOCKs of two inodes while the no-queue request of its AG
# pre-acquire, toward a victim that had withdrawn with its connections up,
# timed out and was re-sent 60 times, 1 s each.  xfsaild could not push those
# inodes (P129-CLSKIP ILOCK_NOWAIT_FAIL), the replayer's post-replay flush
# waits for the whole AIL to empty, and every survivor stalled ~131 s until the
# rename's budget ran out.
#
# THE STAGING, on three nodes: A (node 1, the lowest slot and so the elected
# replayer), B, and the victim C.
#  1. B makes K directories (new directories go round the AGs) with a source
#     and a target file in each, so A caches none of their AGs.  C makes a
#     file F of its own in an AG none of B's targets use and keeps its grant.
#  2. A drops every LOCK_REQ it sends for the home AG of one target
#     (dl_drop_lockreq_ag): to A that master now answers nothing, as the
#     withdrawn victim did.  A touches the target's directory, so that inode's
#     item is dirty in A's log, and renames the source over the target: an
#     existing target's home AG is the rename's one mandatory pre-acquire.  A
#     drop count above 0 three seconds later proves the request left for a
#     remote master and was not answered; a candidate whose count stays 0
#     (A could decide it alone) is passed over for the next.
#  3. C withdraws (tests/mxfs_shutdown.sh: its log unflushed, the node up).  A
#     replays C's slice and then flushes its own dirty state, which waits for
#     the AIL, before the recovery completes.  B then appends to F, which needs
#     the grant C held: the append returns when the recovery has completed.
#
# ARMS (one build, the knob read back on A before the stimulus)
#   wouldblock=1  production: the rename's request answers would-block after
#                 one unanswered attempt and the rename hands its inode locks
#                 off (it waits for the AG holding nothing)
#   wouldblock=0  the control: the request is re-sent for its whole budget with
#                 the inode locks held, as in the incident
#
# MEASURED
#   b_wait_s   C's withdraw to B's append returning: what a survivor waits
#   flush_s    A's post-replay flush ('peer joined -- flushing') to the
#              recovery's next stage (P234-RECOV-STAGE 3->4), from A's log
#   ls_s       how long A's own listing of the target's directory waited while
#              the rename was in flight: the rename's ILOCK hold
#   longest_mv_s, mv_tries  the longest single rename attempt and how many the
#              loop made (the control re-issues a rename that gave up)
#   and A's xfsaild skips of a locked inode (P129-CLSKIP), its AIL-stuck line
#   (P128-AILSTUCK), the would-block line (P-ACQ-NOQUEUE-UNANSWERED) and the
#   re-sends (P36-RETRY) for the dropped AG
#
# THE GRADES
#   VACUOUS  no candidate's request was dropped, or A logged no post-replay
#            flush: the cycle was not staged and the lap measured nothing
#   wouldblock=0  CONTROL-REACHED when the flush waited on the rename
#                 (P129-CLSKIP or P128-AILSTUCK on A while the rename re-sent,
#                 and b_wait_s past the control bound), else CONTROL-NOT-REACHED
#   wouldblock=1  PASS when P-ACQ-NOQUEUE-UNANSWERED fired for the dropped AG,
#                 b_wait_s is within the recovery bound, no node but C shut
#                 down, and the cold audit is CLEAN
#
# Budgets (derived).  A voluntary death on TCP is fenced and replayed within
# ~30 s (path_fenced_return fenced_s=35 at 8 nodes); the flush waits at most
# the control's retry budget (60 attempts, ~1 s each).  RECOVERY_BOUND_S=45
# grades the production arm; CONTROL_BOUND_S=50 is what the control must pass
# to have reproduced the wait; the watch ends at WATCH_S=130 (60 s budget +
# 30 s recovery + 40 s margin).  The prep and the audit run under their own
# run.sh budgets.
#
# Usage: tests/noqueue_unanswered_ab.sh <label> <wouldblock 0|1> [config=3/net/mesh/direct] [group=g3b]
# Exit 0 PASS / CONTROL-*, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; ARM=${2:?wouldblock 0|1}
CONFIG=${3:-3/net/mesh/direct}; GROUP=${4:-g3b}
case "$ARM" in 0|1) ;; *) echo "wouldblock must be 0 or 1"; exit 2 ;; esac
K=${NQU_DIRS:-12}
RECOVERY_BOUND_S=45; CONTROL_BOUND_S=50; WATCH_S=130
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
read -r A B C rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${A:-}" ] && [ -n "${B:-}" ] && [ -n "${C:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no three nodes"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_nqu_$LABEL
mkdir -p "$OUT"
MARK="NQU-$LABEL-$$"
P=/sys/module/mxfs/parameters
MNT=/mnt/shared
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
el() { echo $(( $(date +%s) - T0 )); }
T0=$(date +%s)
echo "=== noqueue_unanswered_ab label=$LABEL wouldblock=$ARM $CONFIG $GROUP [A=$A B=$B C=$C] build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="
. tests/lib/runlock.sh
vmhold_take noqueue_unanswered_ab "$A" "$B" "$C" || { echo "RESULT: ABORT label=$LABEL stage=hold"; exit 2; }

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
want=$(modinfo -F srcversion mxfs.ko)
for n in $A $B $C; do
    sv=$(rs 20 "$n" "cat $P/../srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT label=$LABEL -- $n runs '$sv', not the tree build $want evidence=$OUT"; exit 2; }
done
got=$(rs 20 "$A" "echo $ARM > $P/dl_noqueue_unanswered_wouldblock; echo 0 > $P/dl_drop_lockreq_ag; cat $P/dl_noqueue_unanswered_wouldblock" | tail -1)
[ "$got" = "$ARM" ] || { echo "RESULT: ABORT label=$LABEL -- $A's dl_noqueue_unanswered_wouldblock read '$got', not $ARM (is the build missing the knob?) evidence=$OUT"; exit 2; }
for n in $A $B $C; do rs 15 "$n" "echo $MARK > /dev/kmsg"; done

# the AG of an inode number: ino >> (agblklog + inopblog), read from the
# superblock of the group's LUN image on this host
img=$(tools/lun_pool.sh lookup --nodes "$A,$B,$C" | sed -n 's/.* img=\([^ ]*\).*/\1/p')
xoff=$([ -n "$img" ] && timeout 30 tools/chk_mxfs -v "$img" 2>/dev/null | grep -m1 -o 'xfs_data_offset=[0-9]*' | cut -d= -f2)
SHIFT=$([ -n "$xoff" ] && python3 - "$img" "$xoff" <<'PY'
import sys
f = open(sys.argv[1], "rb"); f.seek(int(sys.argv[2])); sb = f.read(512)
print(sb[0x7B] + sb[0x7C] if sb[:4] == b"MXSB" else "")
PY
)
[ -n "$SHIFT" ] || { echo "RESULT: ABORT label=$LABEL stage=geometry -- no AG shift from img='$img' xfs_data_offset='$xoff' evidence=$OUT"; exit 2; }
echo "STAGE geometry: img=$img agino bits=$SHIFT"

# 1. B's directories, each with a source and a target
D=$MNT/nqu.$LABEL
rs 60 "$B" "mkdir -p $D && for k in \$(seq 1 $K); do mkdir $D/d\$k && echo src > $D/d\$k/src && echo tgt > $D/d\$k/tgt; done; sync; for k in \$(seq 1 $K); do echo d\$k \$(stat -c %i $D/d\$k/tgt); done" > "$OUT/targets.txt"
[ "$(grep -c '^d[0-9]' "$OUT/targets.txt")" = "$K" ] || { echo "RESULT: ABORT label=$LABEL stage=staging -- B made $(grep -c '^d[0-9]' "$OUT/targets.txt") of $K directories evidence=$OUT"; exit 2; }
awk -v s="$SHIFT" '{printf "%s %s ag=%d\n", $1, $2, int($2 / 2^s)}' "$OUT/targets.txt" > "$OUT/targets_ag.txt"
echo "STAGE targets: $(awk '{print $3}' "$OUT/targets_ag.txt" | sort | uniq -c | tr '\n' ' ')"

# C's own file, in an AG no target uses, so C's slice holds nothing of the AG
# the drop will name and A's replay of it needs nothing that A drops
TAGS=" $(awk '{print $3}' "$OUT/targets_ag.txt" | sed 's/ag=//' | sort -u | tr '\n' ' ')"
F=""
for j in $(seq 1 16); do
    ino=$(rs 30 "$C" "mkdir -p $D/c$j && echo c > $D/c$j/F && sync && stat -c %i $D/c$j/F" | tail -1 | tr -dc '0-9')
    [ -n "$ino" ] || continue
    ag=$(( ino >> SHIFT ))
    case "$TAGS " in *" $ag "*) continue ;; esac
    F=$D/c$j/F; echo "STAGE C's file: $F ino=$ino ag=$ag"; break
done
[ -n "$F" ] || { echo "RESULT: ABORT label=$LABEL stage=staging -- C found no AG outside the targets' ($TAGS ) evidence=$OUT"; exit 2; }

# 2. a rename on A whose mandatory AG answers nothing
CHOSEN=""
while read -r dk ino agf; do
    ag=${agf#ag=}
    rs 15 "$A" "echo $(( ag + 1 )) > $P/dl_drop_lockreq_ag"
    tr0=$(date +%s.%N)
    # the control's rename gives up when its budget runs out; the loop issues
    # it again at once, so the inode locks are held whenever the flush comes.
    # The production rename does not return until the drop is released.
    timeout $(( WATCH_S + 180 )) "$SSH" "$A" "rm -f /run/nqu.stop; while [ ! -e /run/nqu.stop ]; do touch $D/$dk; t0=\$(date +%s.%N); mv $D/$dk/src $D/$dk/tgt; rc=\$?; echo MV_RC=\$rc T0=\$t0 T1=\$(date +%s.%N); [ \$rc = 0 ] && break; done" < /dev/null > "$OUT/mv_$dk.txt" 2>&1 & mvpid=$!
    sleep 3
    n=$(rs 15 "$A" "cat $P/dl_drop_lockreq_n" | tr -dc '0-9')
    if [ "${n:-0}" -gt 0 ] && kill -0 $mvpid 2>/dev/null; then
        CHOSEN=$dk; CAG=$ag; echo "STAGE $A's rename of $D/$dk/src over tgt (ino $ino, ag $ag) is waiting on a dropped request (drops=$n)"
        break
    fi
    rs 15 "$A" "echo 0 > $P/dl_drop_lockreq_ag; touch /run/nqu.stop"
    wait $mvpid
    echo "STAGE candidate $dk (ag $ag) passed over: drops=${n:-?} $(cat "$OUT/mv_$dk.txt" | tr '\n' ' ' | cut -c1-80)"
done < "$OUT/targets_ag.txt"
[ -n "$CHOSEN" ] || { echo "RESULT: VACUOUS label=$LABEL wouldblock=$ARM -- no target's AG request left A for a remote master evidence=$OUT"; exit 3; }
# A's own listing of the directory: it needs the ILOCK the rename holds
timeout $(( WATCH_S + 60 )) "$SSH" "$A" "t0=\$(date +%s.%N); ls $D/$CHOSEN > /dev/null; echo LS_RC=\$? T0=\$t0 T1=\$(date +%s.%N)" < /dev/null > "$OUT/ls_A.txt" 2>&1 & lspid=$!

# 3. C withdraws; B appends to C's file
tw=$(date +%s.%N)
timeout 30 tests/mxfs_shutdown.sh "$C" "$MNT" 2 < /dev/null > "$OUT/withdraw_$C.txt" 2>&1
echo "STAGE $C withdrew at +$(el)s: $(tail -1 "$OUT/withdraw_$C.txt" | cut -c1-80)"
timeout "$WATCH_S" "$SSH" "$B" "echo b >> $F && sync $F && echo APPEND_RC=0" < /dev/null > "$OUT/append_B.txt" 2>&1
arc=$?
b_wait=$(awk -v a="$tw" -v b="$(date +%s.%N)" 'BEGIN {printf "%d", b - a}')
echo "STAGE $B's append to $F returned rc=$arc after ${b_wait}s ($(tr '\n' ' ' < "$OUT/append_B.txt" | cut -c1-80))"

# release the dropped AG; the rename and the listing finish
rs 15 "$A" "echo 0 > $P/dl_drop_lockreq_ag; touch /run/nqu.stop"
wait $mvpid; wait $lspid
span() { awk '/T0=/ {for (i = 1; i <= NF; i++) {if ($i ~ /^T0=/) a = substr($i, 4); if ($i ~ /^T1=/) b = substr($i, 4)} if (b - a > m) m = b - a} END {if (m != "") printf "%.1f", m}' "$1"; }
mv_s=$(span "$OUT/mv_$CHOSEN.txt"); ls_s=$(span "$OUT/ls_A.txt")
MV_TRIES=$(grep -c 'MV_RC=' "$OUT/mv_$CHOSEN.txt")
echo "STAGE rename: tries=$MV_TRIES longest=${mv_s:-none}s last=$(tail -1 "$OUT/mv_$CHOSEN.txt" | cut -c1-40)  listing: ${ls_s:-none}s"

# 4. the logs, then the audit
for n in $A $B $C; do
    rs 60 "$n" "dmesg | sed -n '/$MARK/,\$p'" > "$OUT/kmsg_$n.txt"
done
KA=$OUT/kmsg_$A.txt
fl=$(grep -a -m1 'peer joined -- flushing' "$KA" | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p')
st=$(grep -a 'P234-RECOV-STAGE' "$KA" | grep -a -m1 '3->4' | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p')
flush_s=$([ -n "$fl" ] && [ -n "$st" ] && awk -v a="$fl" -v b="$st" 'BEGIN {printf "%.1f", b - a}')
CLSKIP=$(grep -ac 'P129-CLSKIP' "$KA"); AILSTUCK=$(grep -ac 'P128-AILSTUCK' "$KA")
UNANS=$(grep -a 'P-ACQ-NOQUEUE-UNANSWERED' "$KA" | grep -ac "type=3 .* ag=$CAG ")
RETRY=$(grep -a 'P36-RETRY' "$KA" | grep -ac "type=3 ag=$CAG ")
DROPS=$(rs 15 "$A" "cat $P/dl_drop_lockreq_n" | tr -dc '0-9')
bad=0
for n in $A $B; do
    s=$(grep -ac 'Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|BUG:\|Oops\|blocked for more than' "$OUT/kmsg_$n.txt")
    [ "$s" = 0 ] || bad=$((bad + 1)); echo "  $n failure_lines=$s"
done
echo "--- chosen=$CHOSEN ag=$CAG b_wait_s=$b_wait append_rc=$arc flush_s=${flush_s:-none} flush_line=${fl:-none} stage34=${st:-none} ls_s=${ls_s:-none} longest_mv_s=${mv_s:-none} mv_tries=$MV_TRIES clskip=$CLSKIP ailstuck=$AILSTUCK unanswered=$UNANS retries=$RETRY drops=${DROPS:-?} survivors_failed=$bad"

for n in $A $B; do rs 130 "$n" "umount $MNT; echo UMOUNT_RC=\$?" > "$OUT/umount_$n.txt"; done
timeout 60 sudo virsh -c qemu:///system destroy "$C" > "$OUT/destroy_$C.txt" 2>&1
audit=$(timeout 180 tools/chk_mxfs -v "$img" > "$OUT/chk.txt" 2>&1; echo rc=$?)
errs=$(grep -ac '^ERROR' "$OUT/chk.txt")
echo "cold audit: $audit errors=$errs ($OUT/chk.txt)"
timeout 240 tools/vm_pool.sh up "$C" > "$OUT/up_$C.txt" 2>&1

if [ -z "$fl" ]; then
    echo "RESULT: VACUOUS label=$LABEL wouldblock=$ARM -- $A logged no post-replay flush evidence=$OUT"; exit 3
fi
if [ "$ARM" = 0 ]; then
    v=CONTROL-NOT-REACHED
    [ $(( CLSKIP + AILSTUCK )) -gt 0 ] && [ "$b_wait" -gt "$CONTROL_BOUND_S" ] && v=CONTROL-REACHED
    echo "RESULT: $v label=$LABEL wouldblock=0 b_wait_s=$b_wait flush_s=${flush_s:-none} ls_s=${ls_s:-none} clskip=$CLSKIP ailstuck=$AILSTUCK retries=$RETRY audit=$audit errors=$errs evidence=$OUT"; exit 0
fi
if [ "$UNANS" -gt 0 ] && [ "$arc" = 0 ] && [ "$b_wait" -le "$RECOVERY_BOUND_S" ] && [ "$bad" = 0 ] && [ "$audit" = rc=0 ] && [ "$errs" = 0 ]; then
    echo "RESULT: PASS label=$LABEL wouldblock=1 b_wait_s=$b_wait flush_s=${flush_s:-none} ls_s=${ls_s:-none} unanswered=$UNANS clskip=$CLSKIP audit=$audit evidence=$OUT"; exit 0
fi
echo "RESULT: FAIL label=$LABEL wouldblock=1 b_wait_s=$b_wait append_rc=$arc flush_s=${flush_s:-none} unanswered=$UNANS survivors_failed=$bad audit=$audit errors=$errs evidence=$OUT"; exit 1
