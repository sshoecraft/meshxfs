#!/bin/bash
# fourkn_merge_disk_load_ab.sh — does a saturated host disk under the pool LUNs
# reproduce the merged-write lap that stalled, and what does a stalled step
# wait on?
#
# D-FOURKN-MERGE-LAP-REMOUNT-HUNG-68S-AND-WORKERS-RAN-3-OF-20-ROUNDS-UNEXPLAINED:
# in one lap of tests/fourkn_merge_2node.sh both workers ran 3 and 2 of 20
# rounds in 13 s (6.2-8.4 s for all 20 in the batch's other laps), and the
# remount after chk_mxfs did not return for 68 s.  It ran while a recursive
# read saturated /dev/sda, the SSD under every pool LUN image, but the lap kept
# no node kernel log, so nothing measured whether the disk was what it waited
# on (review data/reviews/P20261024-a96a97.md).
#
# One lap of tests/fourkn_merge_2node.sh, with:
#   LOAD=1  a host-side read of a free pool LUN's image for the lap's whole
#           length: fio --readonly, O_DIRECT, sequential 1 MiB at QD16, which
#           read ~500 MB/s like the grep did; LOAD=0 none (the quiet arm)
#   each node's /dev/kmsg followed into /root from before the lap to an end
#   mark after it, so the run's kernel log survives however the lap ends
#   a sampler on each node: every 2 s, every task in D state, its comm, wchan
#   and /proc/<pid>/stack, so a stalled mount or worker says what it waits on
#   the host's iostat -x for sda every second
#
# Grading.  The lap's own verdict line and wall are printed as they are.
# LOAD-SAW-SATURATION is printed when sda's %util stayed at or above 90 for at
# least half the lap's seconds (the load arm's exposure).  STALL is printed for
# each task the sampler saw in D state over 10 s, with its stack.  The two
# arms are compared by whoever reads them; this script decides nothing about
# MeshXFS.
#
# Bounds: the lap's own, 130 s (the batch's); the followers and samplers 10 s to
# start and 30 s to collect; the load stops with the lap.
#
# Usage: LOAD=0|1 tests/fourkn_merge_disk_load_ab.sh <label> <dev> <node1> <node2>
# Exit: the lap's own exit code; 2 when this script could not set up.
set -u
LABEL=${1:?label}; DEV=${2:?device}; N1=${3:?node1}; N2=${4:?node2}
LOAD=${LOAD:-0}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$HERE
while [ "$REPO" != / ] && [ ! -f "$REPO/tools/mxfs_lab.sh" ]; do REPO=$(dirname "$REPO"); done
[ -f "$REPO/tools/mxfs_lab.sh" ] || { echo "RESULT: ABORT label=$LABEL stage=root"; exit 2; }
cd "$REPO" || exit 2
. tools/mxfs_lab.sh
SSH=tools/mxfs_sshpass.sh
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_mergeload_$LABEL
mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1
on() { timeout "$3" "$SSH" "$(lab_addr "$1")" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'; }
MARK="MERGELOAD-$LABEL-$$"
KL=/root/mergeload.$LABEL.$$.kmsg
DS=/root/mergeload.$LABEL.$$.dstate
echo "=== fourkn_merge_disk_load_ab label=$LABEL load=$LOAD dev=$DEV nodes=$N1,$N2 out=$OUT $(date -u +%FT%TZ) ==="

stop_all() {
    local n
    [ -n "${FIOPID:-}" ] && kill "$FIOPID" 2>/dev/null
    [ -n "${IOSPID:-}" ] && kill "$IOSPID" 2>/dev/null
    for n in "$N1" "$N2"; do
        on "$n" "echo '$MARK-END' > /dev/kmsg; sleep 1; kill \$(cat $KL.pid $DS.pid 2>/dev/null) 2>/dev/null; awk '/$MARK\$/{f=1} f' $KL | cut -c1-700; echo KMSG_END" 30 > "$OUT/kmsg_$n.txt"
        on "$n" "cat $DS; rm -f $KL $KL.pid $DS $DS.pid" 30 > "$OUT/dstate_$n.txt"
    done
}
trap stop_all EXIT

for n in "$N1" "$N2"; do
    on "$n" "rm -f $KL $KL.pid $DS $DS.pid; nohup setsid sh -c 'echo \$\$ > $KL.pid; exec cat /dev/kmsg > $KL' > /dev/null 2>&1 < /dev/null &
        nohup setsid sh -c 'echo \$\$ > $DS.pid; while :; do t=\$(date +%s); for s in /proc/[0-9]*/stat; do p=\${s#/proc/}; p=\${p%/stat}; st=\$(cut -d\" \" -f3 \$s 2>/dev/null); [ \"\$st\" = D ] || continue; echo \"DSTATE t=\$t pid=\$p comm=\$(cat /proc/\$p/comm 2>/dev/null) wchan=\$(cat /proc/\$p/wchan 2>/dev/null)\"; sed \"s/^/  /\" /proc/\$p/stack 2>/dev/null; done; sleep 2; done >> $DS' > /dev/null 2>&1 < /dev/null &
        sleep 1; echo $MARK > /dev/kmsg; sleep 1; echo FOLLOW_MARK=\$(grep -c '$MARK\$' $KL)" 10 > "$OUT/follow_$n.txt"
    grep -q '^FOLLOW_MARK=1$' "$OUT/follow_$n.txt" || { echo "ABORT: $n's kernel-log follower did not start: $(tr '\n' ' ' < "$OUT/follow_$n.txt")"; echo "RESULT: ABORT label=$LABEL stage=follow evidence=$OUT"; exit 2; }
done

iostat -x -y -t 1 sda > "$OUT/iostat_sda.txt" 2>&1 &
IOSPID=$!
if [ "$LOAD" = 1 ]; then
    lun=$(timeout 20 tools/lun_pool.sh status | awk '$5 == "free" {print $1; exit}')
    img=/home/steve/disks/pool/$lun.img
    [ -n "$lun" ] && [ -f "$img" ] || { echo "ABORT: no free pool LUN image to read ($lun)"; echo "RESULT: ABORT label=$LABEL stage=load evidence=$OUT"; exit 2; }
    echo "INFO load: fio --readonly O_DIRECT sequential 1 MiB QD16 on $img (free in the pool)"
    fio --name=load --filename="$img" --readonly --rw=read --direct=1 --bs=1M --iodepth=16 --ioengine=libaio --time_based --runtime=150 --output="$OUT/fio_load.txt" > /dev/null 2>&1 &
    FIOPID=$!
    sleep 5
fi

t0=$(date +%s)
MXFS_CONFIG=${MXFS_CONFIG:-2/disk/caw/direct4k} timeout -k 5 130 tests/fourkn_merge_2node.sh "$DEV" "$N1" "$N2" > "$OUT/lap.txt" 2>&1
rc=$?
wall=$(( $(date +%s) - t0 ))
grep -a '^=== fourkn_merge_2node: \|WORKER_\|FAIL \|ABORT\|VACUOUS\|OK mount\|OK umount' "$OUT/lap.txt" | cut -c1-220
echo "LAP rc=$rc wall=${wall}s load=$LOAD"
stop_all
trap - EXIT

n_sec=$(grep -cE '^sda ' "$OUT/iostat_sda.txt")
n_sat=$(awk '$1 == "sda" && $NF + 0 >= 90 {n++} END {print n + 0}' "$OUT/iostat_sda.txt")
echo "INFO sda: $n_sat of $n_sec one-second samples at >= 90% util"
[ "$n_sec" -gt 0 ] && [ $(( n_sat * 2 )) -ge "$n_sec" ] && echo "LOAD-SAW-SATURATION: sda at >= 90% util in $n_sat of $n_sec seconds"
for n in "$N1" "$N2"; do
    grep -q "$MARK\$" "$OUT/kmsg_$n.txt" && grep -q "$MARK-END\$" "$OUT/kmsg_$n.txt" || echo "INFO $n's kernel log is not whole (both marks not read)"
    grep -a 'BUG:\|Oops\|Shutting down\|blocked for more than\|P-ACQ-STUCK\|P-SLIFE-READY\|P-BARRIER-CLOCK\|Reservation\|timed out' "$OUT/kmsg_$n.txt" | cut -c1-220 | head -12 | sed "s/^/  $n: /"
    awk '/^DSTATE/ {split($2, a, "="); split($3, b, "="); k = b[2] " " $4; if (!(k in first)) first[k] = a[2]; last[k] = a[2]}
         END {for (k in first) if (last[k] - first[k] >= 10) print "STALL '"$n"' " k " in D state " last[k] - first[k] "+ s"}' "$OUT/dstate_$n.txt"
done
echo "RESULT: LAP label=$LABEL load=$LOAD rc=$rc wall=${wall}s evidence=$OUT"
exit $rc
