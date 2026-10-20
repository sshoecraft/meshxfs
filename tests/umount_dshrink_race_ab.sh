#!/bin/bash
# tests/umount_dshrink_race_ab.sh — does an unmount right after a directory
# reload meet the reload's deferred dcache shrink still holding its dentry?
#
# For D-UMOUNT-ROOT-DENTRY-STILL-IN-USE-DEFERRED-DIR-DCACHE-SHRINK-RACE.  Every
# completed directory reload queues a deferred dcache shrink
# (mxfs_dir_dshrink_queue, xfs/xfs_mxfs_reload.c) that igrabs the directory and
# holds a reference on its dentry while it runs; the only gate on it used to
# close in put_super, after generic_shutdown_super's dentry-tree walk.  In jwc3
# (test15) the reload umount's own stat caused queued one for the root 1 ms
# before the walk: 'BUG: Dentry {i=80,n=/} still in use (2)', root icount 3.
#
# One round, on the group's two nodes A and B, both mounted: B creates a name
# in the root directory (A's cached root is now stale), A lists the root (its
# PR acquire reloads it and queues the shrink, which the test knob
# dbg_dshrink_hold_ms keeps holding its dentry reference) and unmounts at once,
# then mounts again.  Same-build A/B, one knob between the arms:
# dshrink_umount_gate on A (0 control, 1 fix), set and read back with the hold.
#
# Measures (A's kernel log after each round's mark; A's counters at the end):
#   bug         'BUG: Dentry' / 'still in use' lines (the defect)
#   busyinodes  'Busy inodes' lines
#   warn        other 'WARNING:' / 'BUG:' / 'Oops' lines
#   hold        P-DBG-DSHRINK-HOLD lines (the shrink ran with the hold: reach)
#   at_umount   P-DSHRINK-AT-UMOUNT lines (a shrink queued or running when
#               xfs_kill_sb began: the race was there to be met)
#   counters    dshrink_at_umount, dshrink_gate_refused
#   umount/mount rc and wall, then a cold audit (run.sh chk_clean)
# Verdict, written before the first lap:
#   reach   a round with hold >= 1 and at_umount >= 1
#   control (gate 0): SHOWS THE CAUSE if a reached round has bug >= 1
#   fix (gate 1): PASS if at least one round reached and no round has bug,
#           busyinodes or warn > 0, every umount and mount returned 0 within
#           its bound, and the cold audit is CLEAN; VACUOUS with no reach;
#           FAIL otherwise
#
# Budget (derived): a clean unmount on 2/disk/caw/direct measured 0.4 s (jwc3
# test15 949.05 -> 949.45); bound twice a rounded second plus the injected
# hold: UMOUNT_BOUND_S = 2 + ceil(hold).  A lone 2-node mount measured 1.0 s
# (jwc3 test15 917.17 -> 918.21) and 4.8-5.7 s for a join elsewhere
# (tests/agbast_mount_park.sh): MOUNT_BOUND_S 12.  Prep 300 s; the cold audit
# is bounded by run.sh's own chk_clean budget.
#
# Usage: tests/umount_dshrink_race_ab.sh <label> <gate 0|1> [rounds=3] [hold_ms=1500]
#            [config=2/disk/caw/direct] [group=g2d]
set -u
LABEL=${1:?label}; GATE=${2:?gate 0|1}; ROUNDS=${3:-3}; HOLD_MS=${4:-1500}
CONFIG=${5:-2/disk/caw/direct}; GROUP=${6:-g2d}
case "$GATE" in 0|1) ;; *) echo "gate must be 0 or 1"; exit 2 ;; esac
case "$ROUNDS$HOLD_MS" in *[!0-9]*) echo "rounds and hold_ms must be whole numbers"; exit 2 ;; esac
UMOUNT_BOUND_S=$(( 2 + (HOLD_MS + 999) / 1000 ))
MOUNT_BOUND_S=${MOUNT_BOUND_S:-12}
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
read -r A B rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${A:-}" ] && [ -n "${B:-}" ] || { echo "RESULT: ABORT umount_dshrink_race label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
NODES="$A $B${rest:+ $rest}"
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_umount_dshrink_$LABEL
mkdir -p "$OUT"
rsx() { local t=$1 n=$2; shift 2; timeout "$t" $SSH "$n" "$*" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
. tests/lib/runlock.sh
vmhold_take "umount_dshrink_race $LABEL" $NODES || { echo "RESULT: ABORT umount_dshrink_race label=$LABEL -- could not hold $NODES"; exit 2; }
echo "=== umount_dshrink_race label=$LABEL gate=$GATE rounds=$ROUNDS hold_ms=$HOLD_MS $CONFIG $GROUP [$NODES] build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1
rc=$?; echo "prep_rc=$rc"
[ "$rc" = 0 ] || { echo "RESULT: ABORT umount_dshrink_race label=$LABEL -- prep failed ($OUT/prep.log)"; exit 2; }
want=$(modinfo -F srcversion mxfs.ko)
for n in $NODES; do
    sv=$(rsx 20 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT umount_dshrink_race label=$LABEL -- $n runs '$sv', not this tree's $want"; exit 2; }
done
DEV=$(rsx 15 "$A" "findmnt -no SOURCE /mnt/shared")
[ -n "$DEV" ] || { echo "RESULT: ABORT umount_dshrink_race label=$LABEL -- no mount on $A"; exit 2; }
P=/sys/module/mxfs/parameters
got=$(rsx 20 "$A" "echo $GATE > $P/dshrink_umount_gate; echo $HOLD_MS > $P/dbg_dshrink_hold_ms; echo 0 > $P/dshrink_at_umount; echo 0 > $P/dshrink_gate_refused; echo \$(cat $P/dshrink_umount_gate)/\$(cat $P/dbg_dshrink_hold_ms)/\$(cat $P/dshrink_at_umount)/\$(cat $P/dshrink_gate_refused)" | tail -1)
[ "$got" = "$GATE/$HOLD_MS/0/0" ] || { echo "RESULT: ABORT umount_dshrink_race label=$LABEL -- $A read '$got', not $GATE/$HOLD_MS/0/0 (is the build missing the knobs?)"; exit 2; }

reached=0; bugs=0; busy=0; warns=0; opfail=0
for r in $(seq 1 "$ROUNDS"); do
    M="DSHRINK-$LABEL-$r-$$"
    rsx 20 "$A" "echo $M > /dev/kmsg; ls /mnt/shared > /dev/null; echo ok" | grep -q ok \
        || { echo "RESULT: ABORT umount_dshrink_race label=$LABEL -- $A could not list the root before round $r"; exit 2; }
    rsx 20 "$B" "touch /mnt/shared/dsr.$LABEL.$r && echo ok" | grep -q ok \
        || { echo "RESULT: ABORT umount_dshrink_race label=$LABEL -- $B could not create in the root in round $r"; exit 2; }
    rsx $(( UMOUNT_BOUND_S + MOUNT_BOUND_S + 30 )) "$A" "ls /mnt/shared > /dev/null; s=\$(date +%s%N); timeout $UMOUNT_BOUND_S umount /mnt/shared; urc=\$?; e=\$(date +%s%N); echo umount_rc=\$urc ms=\$(( (e-s)/1000000 )); s=\$(date +%s%N); timeout $MOUNT_BOUND_S mount -t mxfs $DEV /mnt/shared; mrc=\$?; e=\$(date +%s%N); echo mount_rc=\$mrc mount_ms=\$(( (e-s)/1000000 )); dmesg | sed -n '/$M/,\$p' > /tmp/dsr_$LABEL.$r.txt; echo bug=\$(grep -ac 'BUG: Dentry\|still in use' /tmp/dsr_$LABEL.$r.txt) busyinodes=\$(grep -ac 'Busy inodes' /tmp/dsr_$LABEL.$r.txt) warn=\$(grep -a 'WARNING:\|BUG:\|Oops' /tmp/dsr_$LABEL.$r.txt | grep -avc 'BUG: Dentry') hold=\$(grep -ac 'P-DBG-DSHRINK-HOLD' /tmp/dsr_$LABEL.$r.txt) at_umount=\$(grep -ac 'P-DSHRINK-AT-UMOUNT' /tmp/dsr_$LABEL.$r.txt)" > "$OUT/round_$r.txt"
    rsx 30 "$A" "dmesg | sed -n '/$M/,\$p'" > "$OUT/round_${r}_${A}_kmsg.txt"
    l=$(tr '\n' ' ' < "$OUT/round_$r.txt")
    urc=$(sed -n 's/.*umount_rc=\([0-9]*\).*/\1/p' <<<"$l"); mrc=$(sed -n 's/.*mount_rc=\([0-9]*\).*/\1/p' <<<"$l")
    b=$(sed -n 's/.* bug=\([0-9]*\).*/\1/p' <<<"$l"); bi=$(sed -n 's/.*busyinodes=\([0-9]*\).*/\1/p' <<<"$l")
    w=$(sed -n 's/.* warn=\([0-9]*\).*/\1/p' <<<"$l"); h=$(sed -n 's/.* hold=\([0-9]*\).*/\1/p' <<<"$l")
    au=$(sed -n 's/.*at_umount=\([0-9]*\).*/\1/p' <<<"$l")
    echo "round $r: $l"
    [ "${urc:-1}" = 0 ] && [ "${mrc:-1}" = 0 ] || opfail=$(( opfail + 1 ))
    [ "${h:-0}" -ge 1 ] && [ "${au:-0}" -ge 1 ] && reached=$(( reached + 1 ))
    bugs=$(( bugs + ${b:-0} )); busy=$(( busy + ${bi:-0} )); warns=$(( warns + ${w:-0} ))
    # a node that did not mount again ends the rounds; the audit still runs
    [ "${mrc:-1}" = 0 ] || break
done
cnt=$(rsx 20 "$A" "echo 0 > $P/dbg_dshrink_hold_ms; echo at_umount_counter=\$(cat $P/dshrink_at_umount) gate_refused=\$(cat $P/dshrink_gate_refused) gate=\$(cat $P/dshrink_umount_gate) hold_ms=\$(cat $P/dbg_dshrink_hold_ms)")
echo "$A counters: $cnt"

./run.sh "$CONFIG" --group "$GROUP" chk_clean > "$OUT/chk.log" 2>&1
crc=$?
audit=$(grep -ao 'verdict=[A-Z]*' "$OUT/chk.log" | head -1 | cut -d= -f2)
echo "chk_clean rc=$crc audit=${audit:-NONE}"

if [ "$GATE" = 0 ]; then
    if [ "$reached" -ge 1 ] && [ "$bugs" -ge 1 ]; then v=CONTROL-SHOWS-CAUSE
    elif [ "$reached" = 0 ]; then v=VACUOUS
    else v=CONTROL-NO-CAUSE; fi
else
    if [ "$reached" = 0 ]; then v=VACUOUS
    elif [ "$bugs" = 0 ] && [ "$busy" = 0 ] && [ "$warns" = 0 ] && [ "$opfail" = 0 ] && [ "${audit:-}" = CLEAN ]; then v=PASS
    else v=FAIL; fi
fi
echo "RESULT: $v umount_dshrink_race label=$LABEL gate=$GATE rounds=$ROUNDS hold_ms=$HOLD_MS reached=$reached bug=$bugs busyinodes=$busy warn=$warns opfail=$opfail $cnt audit=${audit:-NONE} evidence=$OUT"
case "$v" in PASS|CONTROL-SHOWS-CAUSE) exit 0 ;; VACUOUS) exit 3 ;; *) exit 1 ;; esac
