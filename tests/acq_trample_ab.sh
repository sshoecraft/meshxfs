#!/bin/bash
# acq_trample_ab.sh — D-CC-16NODE-SYNCED-CREATE-NAME-LOST-INODE-DISCONNECTED:
# a release that aborts while this node's acquire is in flight must leave the
# inode ACQUIRING.
#
# Cause under test (read from the 0.90.132 chain's kernel logs, run
# 20261021T042939Z-g16, test14, directory 83901385): crash_consistency's
# `md5sum f | awk > f.md5` runs md5sum's lookup (PR on the directory) beside
# the shell's create of f.md5 (EX) on the same node.  The EX acquire set
# ACQUIRING; a bast_process that entered on the ACQUIRING inode aborted its
# release as orphan-only and set NONE over it (mxfs_bast_nl_entry_cleanup);
# md5sum then sent its own PR request, met the node's fresh EX grant as a
# stale self-hold (-EDEADLK), and P109 released that grant as a phantom.  The
# shell added node14_f20.md5 under an EX the lock manager had handed to test11,
# whose write of the same block dropped it: a synced create with no name.
#
# Shape: one fresh 16-node cluster per lap, rel_abort_keeps_acquiring set on
# every node (control 0, fix 1), crash_consistency once (its own directory,
# CC_TAG), every node's kernel log followed into a file from the lap mark,
# then the cluster unmounted and the platter checked cold.
#   reach (both arms): P-REL-ABORT-UNDER-ACQ — a release aborted under an
#     acquire in flight, the case the knob decides.
#   control: a second slow-path acquire of the same inode on the same node
#     (P-ACQ-CONCURRENT) follows; a lost name and a disconnected inode may.
#   fix: no P-ACQ-CONCURRENT, no P109 phantom release with another acquire in
#     flight, crash_consistency PASS, chk_mxfs no ERROR.
#
# Budget (derived): prep 55 s measured at 16 nodes (board 0.90.132) +
# crash_consistency 46 s measured (budget 90) + knobs, followers and counts
# ~20 s + 16 unmounts ~10 s + cold chk 15 s measured => ~150 s; queue bound
# 300 s.  The lap leaves the cluster unmounted.
#
# Usage: tests/acq_trample_ab.sh <label> <arm: control|fix> [group] [configuration]
set -u
LABEL=${1:?label}; ARM=${2:?arm control|fix}
GROUP=${3:-g16}; CONF=${4:-16/disk/caw/direct}
case "$ARM" in control) KEEP=0 ;; fix) KEEP=1 ;; *) echo "ABORT: arm must be control or fix"; exit 2 ;; esac
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO"
. tools/mxfs_lab.sh
NODES=$(lab_group "$GROUP") || { echo "ABORT: no rig group $GROUP in the lab file"; exit 2; }
MXFS_FORCE_PREP=1 ./run.sh "$CONF" --group "$GROUP" prep_cluster > "tests/evidence/prep_acqtr_${LABEL}.log" 2>&1 ||
    { echo "ABORT: prep of $CONF on $GROUP failed (tests/evidence/prep_acqtr_${LABEL}.log)"; echo "RESULT: ABORT label=$LABEL stage=prep"; exit 2; }
SSH=tools/mxfs_sshpass.sh
. "$(dirname "$0")/lib/rig.sh"
export MXFS_NODE_LIST=${MXFS_NODE_LIST:-"$NODES"}
N1=${NODES%% *}
MNT=${MXFS_MNT:-/mnt/shared}
HOST_IMG=$(tools/mxfs_host_image.sh "$N1") || { echo "$HOST_IMG"; echo "RESULT: ABORT label=$LABEL stage=device"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_acqtrample_${LABEL}
mkdir -p "$OUT"
fails=0
P=/sys/module/mxfs/parameters
KF=/root/acqtr_${LABEL}.kmsg
t0=$(date +%s)

echo "=== acq_trample_ab label=$LABEL arm=$ARM conf=$CONF group=$GROUP nodes=[$NODES] out=$OUT $(date -u +%FT%TZ) ==="
want=$(modinfo mxfs.ko | awk '/^srcversion:/{print $2}')
for n in $NODES; do
    nsv=$(rs 15 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$nsv" = "$want" ] || { echo "ABORT: $n srcversion '$nsv' != tree '$want'"; echo "RESULT: ABORT label=$LABEL stage=build evidence=$OUT"; exit 2; }
done
for n in $NODES; do
    value_now_into kv "$n" 20 "$OUT/knob_$n.txt" '^keep=' "the knob on $n" "echo $KEEP > $P/rel_abort_keeps_acquiring && echo keep=\$(cat $P/rel_abort_keeps_acquiring)"
    ck "$n rel_abort_keeps_acquiring=$KEEP" "$kv" "keep=$KEEP"
done
MARK="ACQTR-$LABEL-$$"
for n in $NODES; do kmsg_follow_start "$n" "$MARK" "$KF"; done

# the workload: crash_consistency once, in a directory of its own
MXFS_TEST_ENV="CC_TAG=$LABEL" ./run.sh "$CONF" --group "$GROUP" crash_consistency > "$OUT/crash_consistency.log" 2>&1
ccrc=$?
cc=$(grep -aoE '^\s+(PASS|FAIL|TIMEOUT)\s+crash_consistency' "$OUT/crash_consistency.log" | awk '{print $1}' | tail -1)
echo "  INFO crash_consistency rc=$ccrc verdict=${cc:-none}: $(grep -aE '^\s+(PASS|FAIL|TIMEOUT)\s+crash_consistency' "$OUT/crash_consistency.log" | tail -1 | cut -c1-220)"
for n in $NODES; do
    value_now_into kv "$n" 20 "$OUT/knob_after_$n.txt" '^keep=' "the knob on $n after the workload" "echo keep=\$(cat $P/rel_abort_keeps_acquiring)"
    ck "$n knob unchanged by the workload" "$kv" "keep=$KEEP"
done

# what each node logged from the mark on: only the lines this lap grades
PAT='P-REL-ABORT-UNDER-ACQ|P-ACQ-CONCURRENT|P109-EDEADLK-NL|P-SELF-STALE-EDEADLK|mxfs-cc-FAIL|BUG:|Oops|blocked for more than|Shutting down filesystem'
for n in $NODES; do
    ( measure "$n" 60 "$OUT/lines_$n.txt" '^WINDOW_END$' "the graded lines on $n" "kill \$(cat $KF.pid) 2>/dev/null; sed -n \"/$MARK/,\\\$p\" $KF | grep -aE '$MARK|$PAT'; echo WINDOW_END" ) || exit 2
    grep -qaF -- "$MARK" "$OUT/lines_$n.txt" || { echo "ABORT: $n's followed log lacks the mark $MARK"; echo "RESULT: ABORT label=$LABEL stage=window evidence=$OUT"; exit 2; }
done
cat "$OUT"/lines_*.txt > "$OUT/all_lines.txt"
count_file_into under0 "$OUT/all_lines.txt" 'P-REL-ABORT-UNDER-ACQ.* keep=0'
count_file_into under1 "$OUT/all_lines.txt" 'P-REL-ABORT-UNDER-ACQ.* keep=1'
count_file_into conc "$OUT/all_lines.txt" 'P-ACQ-CONCURRENT'
count_file_into p109 "$OUT/all_lines.txt" 'P109-EDEADLK-NL '
p109multi=$(grep -a 'P109-EDEADLK-NL ' "$OUT/all_lines.txt" | grep -acvE ' acq=[01] ')
count_file_into selfst "$OUT/all_lines.txt" 'P-SELF-STALE-EDEADLK'
count_file_into ccfail "$OUT/all_lines.txt" 'mxfs-cc-FAIL'
count_file_into splat "$OUT/all_lines.txt" 'BUG:\|Oops\|blocked for more than\|Shutting down filesystem'
echo "  INFO abort_under_acq keep0=$under0 keep1=$under1 acq_concurrent=$conc p109=$p109 p109_with_other_acq=$p109multi self_stale=$selfst cc_fail_lines=$ccfail splats=$splat"
for n in $NODES; do printf '    %-7s under=%s conc=%s p109=%s\n' "$n" "$(grep -ac P-REL-ABORT-UNDER-ACQ "$OUT/lines_$n.txt")" "$(grep -ac P-ACQ-CONCURRENT "$OUT/lines_$n.txt")" "$(grep -ac 'P109-EDEADLK-NL ' "$OUT/lines_$n.txt")"; done
grep -ahE 'P-ACQ-CONCURRENT|P109-EDEADLK-NL ' "$OUT/all_lines.txt" | head -6 | cut -c1-260 | sed 's/^/    /'
ck "zero splats" "$splat" "0"
if [ "$ARM" = control ]; then
    ckge "control reach: a release aborted under an acquire in flight and overwrote ACQUIRING (P-REL-ABORT-UNDER-ACQ keep=0)" "$under0" 1
    ckge "control: a second local acquire of the same inode followed (P-ACQ-CONCURRENT)" "$conc" 1
else
    ckge "fix reach: a release aborted under an acquire in flight (P-REL-ABORT-UNDER-ACQ keep=1)" "$under1" 1
    ck "fix: no second local acquire of an inode with one in flight (P-ACQ-CONCURRENT)" "$conc" "0"
    ck "fix: no phantom release with another acquire in flight (P109 acq>1)" "$p109multi" "0"
    ck "fix: crash_consistency" "${cc:-none}" "PASS"
fi

# the platter, cold
for n in $NODES; do
    ( timeout 90 $SSH "$n" "if grep -q ' $MNT mxfs ' /proc/mounts; then timeout 60 umount $MNT; echo rc=\$?; else echo rc=0; fi" < /dev/null 2>/dev/null | filt | tail -1 > "$OUT/um_$n.txt" ) &
done
wait
ck "cluster unmounted for the oracle" "$(grep -L 'rc=0' "$OUT"/um_*.txt 2>/dev/null | wc -l)" "0"
timeout 120 tools/chk_mxfs -v "$HOST_IMG" > "$OUT/chk.txt" 2>&1; chkrc=$?
[ "$chkrc" != 124 ] || { echo "ABORT: chk_mxfs ran out its 120 s bound"; echo "RESULT: ABORT label=$LABEL stage=capture evidence=$OUT"; exit 2; }
capture_require "$OUT/chk.txt" '^Directory entries' "chk_mxfs -v on the backing image"
count_file_into errs "$OUT/chk.txt" 'ERROR'
disc=$(grep -ao 'disconnected=[0-9]*' "$OUT/chk.txt" | tail -1 | cut -d= -f2)
echo "  INFO chk rc=$chkrc ERROR-lines=$errs disconnected=${disc:-?}"
grep -a 'ERROR' "$OUT/chk.txt" | head -4 | cut -c1-220 | sed 's/^/    /'
[ "$ARM" = fix ] && ck "fix: chk_mxfs reports no ERROR" "$errs" "0"
echo "=== acq_trample_ab $LABEL arm=$ARM: fails=$fails total=$(( $(date +%s) - t0 ))s out=$OUT ==="
echo "RESULT: $([ "$fails" -eq 0 ] && echo PASS || echo FAIL) label=$LABEL arm=$ARM under0=$under0 under1=$under1 conc=$conc p109=$p109 p109multi=$p109multi cc=${cc:-none} chk_errors=$errs evidence=$OUT"
echo "NOTE: the cluster is unmounted — prep before further rig work."
[ "$fails" -eq 0 ]
