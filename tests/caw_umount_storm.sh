#!/bin/bash
# tests/caw_umount_storm.sh — does a write storm on the lab host's root
# filesystem hold a two-node CAW cluster's unmount, and where does the target
# wait while it does?
#
# WHY.  D-CAWMPATH-UMOUNT-RELEASE-ALL-CAW-HELD-57S-BOTH-NODES: both nodes of a
# 2/disk/caw/mpath cluster sat 57 s in a COMPARE AND WRITE at unmount
# (release_all slot clears) and resumed in the same second, inside a host write
# storm (two lun_pool.sh snapshot copies onto /, nvme0n1 average await 45-69
# ms, 6.3 G dirty).  The held CAWs were on different sectors, which SCST does
# not serialise, so the block was common to the LUN or the host.  A lone
# initiator's CAW under a heavier storm (tests/caw_host_storm_probe.sh hcs1)
# peaked at 1.95 s: the storm alone did not reproduce it.  This lap reproduces
# the incident's shape instead: both nodes mounted on multipath with held
# locks, the storm, then both unmount at once.
#
# WHAT IT DOES.  prep_cluster formats and mounts <config> on <group>'s two
# nodes; each node creates <files> files in a directory of its own and lists
# the other's, so each holds many inode grants; with <storm>=1 the host copies
# <src_a> and, 14 s later, <src_b> (cp --sparse=always) into a fresh directory
# under <storm_dir> and waits until dirty pages pass 3 G or 60 s; then both
# nodes unmount at once.  Throughout, the host samples at 10 Hz every target
# thread of the group's pool LUN (comm mxfspool<NN>*) not idle in
# scst_cmd_thread and the root filesystem's jbd2 thread when in D, with their
# kernel stacks, plus Dirty/Writeback; each node samples every sd* device's
# inflight counts at 1 Hz and, if its unmount outlasts 10 s, the unmount's
# kernel stack at 10, 20 and 40 s.  Kept files are removed at the end.  Run it
# while no other lap runs: the storm slows every LUN on the host.
#
# PREDICTIONS (H-CAW2, written before the first run):
#   storm=0  both unmounts finish in < 10 s.
#   storm=1  at least one unmount takes > 30 s; while it lasts, target threads
#            of the LUN are sampled in D under ext4 or jbd2 (start_this_handle,
#            jbd2_log_wait_commit, __jbd2_log_wait_for_space, file_update_time,
#            ext4_dirty_inode, or an i_rwsem wait), and the jbd2 thread in D
#            flushing ordered data (jbd2_journal_commit_transaction,
#            jbd2_journal_finish_inode_data_buffers, filemap_fdatawait*).
# Three storm=1 laps with every unmount under 10 s refute H-CAW2.
#
# Bound: prep_cluster 300 + workload 120 + storm wait 60 + unmount 120 + stack
# and sample collection 2x30 + cleanup 60 = 720 s; a lap that sets
# CUS_STORM_WAIT_S adds what it waits beyond 60 s.
#
# WHAT LAP cus3 COULD NOT SEE, AND THE SAMPLES ADDED FOR IT.  Its slow unmount
# (60.1 s in blk_execute_rq for a release-all CAW) came while the LUN's target
# threads were idle in 596 of 600 samples, and every sd* inflight count read 0:
# /sys/block/sd*/inflight does not count a passthrough request, which is what
# a COMPARE AND WRITE is, and the target-thread match covers only the LUN's
# per-initiator pools (SCST names them <dev><initiator>_<n>, scst_main.c, so
# mxfspool01's are mxfspool010_*, mxfspool011_*, ...), not SCST's global
# command threads (scstd*) or iscsi-scst's per-connection receive and send
# threads (iscsird*, iscsiwr*), where a command that never reached a pool
# waits.  So each lap now also samples, at the same 10 Hz, every one of those
# threads, kswapd* and the root jbd2 thread found in D, with its stack (HD
# lines); times a 4 KiB write + fdatasync on the storm's filesystem once a
# second (FSYNC lines: the length of the journal commits a target write waits
# behind); adds nvme0n1's write count, write ms and in-flight I/O to each MEM
# line; and on each node counts, per sd* device, the SCSI commands dispatched
# and not completed (iorequest_cnt - iodone_cnt, which counts passthrough
# commands) and the device state (SCSI lines).
#
# Storm intensity, by environment (defaults are the first design's):
#   CUS_DIRTY_KB      Dirty kB to wait for before the unmount (3145728 = 3 G).
#   CUS_STORM_WAIT_S  longest wait for it, seconds (46).
#   CUS_STORM_MIN_S   the unmount never starts sooner than this many seconds
#                     after the storm (0).
#
# Usage: tests/caw_umount_storm.sh <label> <storm 0|1> [config=2/disk/caw/mpath] [group=g2b]
#        [files=2000] [src_a] [src_b] [storm_dir=/home/steve/disks]
#        src_a/src_b default to the two oldest images in /mxfs/snapshots.
# Exit 0 measured (the verdict line is printed), 2 ABORT.
set -u
LABEL=${1:?label}; STORM=${2:?storm 0|1}
CONFIG=${3:-2/disk/caw/mpath}; GROUP=${4:-g2b}; FILES=${5:-2000}
SRC_A=${6:-$(ls -tr /mxfs/snapshots/*.img 2>/dev/null | sed -n 1p)}
SRC_B=${7:-$(ls -tr /mxfs/snapshots/*.img 2>/dev/null | sed -n 2p)}
STORM_DIR=${8:-/home/steve/disks}
DIRTY_KB=${CUS_DIRTY_KB:-3145728}; STORM_WAIT_S=${CUS_STORM_WAIT_S:-46}; STORM_MIN_S=${CUS_STORM_MIN_S:-0}
case "$STORM" in 0|1) ;; *) echo "storm must be 0 or 1"; exit 2 ;; esac
case "$FILES" in ''|*[!0-9]*) echo "files must be a number"; exit 2 ;; esac
case "$DIRTY_KB$STORM_WAIT_S$STORM_MIN_S" in *[!0-9]*) echo "CUS_DIRTY_KB, CUS_STORM_WAIT_S and CUS_STORM_MIN_S must be numbers"; exit 2 ;; esac
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
read -r A B rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${A:-}" ] && [ -n "${B:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
if [ "$STORM" = 1 ]; then
    [ -r "$SRC_A" ] && [ -r "$SRC_B" ] || { echo "RESULT: ABORT label=$LABEL -- cannot read storm sources '$SRC_A' '$SRC_B'"; exit 2; }
    need=$(( $(stat -c '%b * %B' "$SRC_A") + $(stat -c '%b * %B' "$SRC_B") ))
    free=$(df -PB1 "$STORM_DIR" | awk 'NR==2{print $4}')
    [ $((free - need)) -ge $(( ${MXFS_PREFLIGHT_MIN_FREE_GB:-10} * 1073741824 )) ] || { echo "RESULT: ABORT label=$LABEL -- $STORM_DIR has $((free / 1073741824))G free; the storm can write $((need / 1073741824))G"; exit 2; }
fi
. tests/lib/runlock.sh
vmhold_take "caw_umount_storm $LABEL" "$A" "$B" || { echo "RESULT: ABORT label=$LABEL -- could not hold $A $B"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_caw_umount_storm_$LABEL
mkdir -p "$OUT"
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
echo "=== caw_umount_storm label=$LABEL storm=$STORM $CONFIG $GROUP [$A $B] files=$FILES build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
for n in $A $B; do
    [ "$(rs 20 "$n" "grep -c ' /mnt/shared mxfs ' /proc/mounts")" = 1 ] || { echo "RESULT: ABORT label=$LABEL -- $n has no mxfs at /mnt/shared after prep evidence=$OUT"; exit 2; }
done
LID=$(tools/lun_pool.sh lookup --nodes "$A,$B" | sed -n 's/.* id=\([0-9]*\) .*/\1/p')
[ -n "$LID" ] || { echo "RESULT: ABORT label=$LABEL -- no pool LUN bound to [$A $B] evidence=$OUT"; exit 2; }

t0=$(date +%s)
for n in $A $B; do
    rs 120 "$n" "d=/mnt/shared/cus.$LABEL.$n; mkdir -p \$d && for i in \$(seq 1 $FILES); do echo \$i > \$d/f\$i; done && echo created" > "$OUT/${n}_create.out" & eval "w_$n=\$!"
done
wait "$(eval echo \$w_$A)"; wait "$(eval echo \$w_$B)"
rs 60 "$A" "ls -l /mnt/shared/cus.$LABEL.$B | wc -l" > "$OUT/${A}_list.out"
rs 60 "$B" "ls -l /mnt/shared/cus.$LABEL.$A | wc -l" > "$OUT/${B}_list.out"
echo "workload: $(( $(date +%s) - t0 ))s  $A created=$(cat "$OUT/${A}_create.out") listed=$(cat "$OUT/${A}_list.out")  $B created=$(cat "$OUT/${B}_create.out") listed=$(cat "$OUT/${B}_list.out")"

TPIDS=""; JPID=""; WPIDS=""
ROOTDEV=$(basename "$(df -P "$STORM_DIR" | awk 'NR==2{print $1}')")
for c in /proc/[0-9]*/comm; do
    m=$(cat "$c" 2>/dev/null); p=${c#/proc/}; p=${p%/comm}
    case "$m" in
        "mxfspool$LID"*) TPIDS="$TPIDS $p" ;;
        "jbd2/$ROOTDEV"*) JPID=$p ;;
        scstd*|scst_*|iscsird*|iscsiwr*|iscsi-scstd|kswapd*) WPIDS="$WPIDS $p" ;;
    esac
done
echo "lun$LID target threads:$TPIDS  jbd2 thread: ${JPID:-none}  scst/iscsi/kswapd threads watched: $(echo $WPIDS | wc -w)"
: > "$OUT/.sampling"
(
    while [ -e "$OUT/.sampling" ]; do
        ts=$(date +%s%N)
        echo "MEM ts=$ts $(awk '/^Dirty:|^Writeback:/{printf "%s%s ", $1, $2}' /proc/meminfo)nvme=$(awk '$3=="nvme0n1"{print $8 ":" $11 ":" $12}' /proc/diskstats)"
        for p in $TPIDS; do
            stk=$(sudo -n cat "/proc/$p/stack" 2>/dev/null | awk '{print $2}' | paste -sd' ')
            case "$stk" in scst_cmd_thread*) ;; *) echo "THR ts=$ts pid=$p state=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null) stack=$stk" ;; esac
        done
        for p in $WPIDS; do
            [ "$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)" = D ] || continue
            echo "HD ts=$ts pid=$p comm=$(cat "/proc/$p/comm" 2>/dev/null) stack=$(sudo -n cat "/proc/$p/stack" 2>/dev/null | awk '{print $2}' | paste -sd' ')"
        done
        if [ -n "$JPID" ] && [ "$(awk '{print $3}' "/proc/$JPID/stat" 2>/dev/null)" = D ]; then
            echo "JBD2 ts=$ts stack=$(sudo -n cat "/proc/$JPID/stack" 2>/dev/null | awk '{print $2}' | paste -sd' ')"
        fi
        sleep 0.1
    done
) > "$OUT/host_samples.txt" 2>&1 & smp=$!
# Every host task in D at 2 Hz, whatever it is (AD lines): with async=1 a pool
# thread hands its internal READ16/WRITE16 off and goes idle, so a completion
# held elsewhere (an unwritten-extent conversion worker waiting for a journal
# handle, writeback, reclaim) shows only here.  /proc/<pid>/stat and
# /proc/<pid>/stack are read, never cmdline or maps.
(
    while [ -e "$OUT/.sampling" ]; do
        ts=$(date +%s%N)
        for s in /proc/[0-9]*/stat; do
            read -r p c st rest < "$s" 2>/dev/null || continue
            [ "$st" = D ] || continue
            echo "AD ts=$ts pid=$p comm=$c stack=$(sudo -n cat "/proc/$p/stack" 2>/dev/null | awk '{print $2}' | paste -sd' ')"
        done
        sleep 0.5
    done
) > "$OUT/host_alld.txt" 2>&1 & adp=$!
(
    while [ -e "$OUT/.sampling" ]; do
        t0=$(date +%s%N)
        dd if=/dev/zero of="$OUT/fsync_probe.bin" bs=4096 count=1 conv=fdatasync,notrunc status=none 2>/dev/null
        echo "FSYNC ts=$t0 ms=$(( ($(date +%s%N) - t0) / 1000000 ))"
        sleep 1
    done
) > "$OUT/fsync_probe.txt" 2>&1 & fsp=$!
for n in $A $B; do
    timeout 400 "$SSH" "$n" "for i in \$(seq 1 360); do echo \"SCSI ts=\$(date +%s%N) \$(for d in /sys/block/sd*; do q=\$d/device; printf '%s=%s:%s ' \$(basename \$d) \$(( \$(cat \$q/iorequest_cnt) - \$(cat \$q/iodone_cnt) )) \$(cat \$q/state); done)\"; [ -e /tmp/cus_stop.$LABEL ] && break; sleep 1; done" < /dev/null > "$OUT/${n}_inflight.txt" 2>&1 & eval "s_$n=\$!"
done

SD=""
if [ "$STORM" = 1 ]; then
    SD=$(mktemp -d "$STORM_DIR/caw_storm.XXXXXX") || { echo "RESULT: ABORT label=$LABEL -- cannot make a storm directory"; rm -f "$OUT/.sampling"; exit 2; }
    S0=$(date +%s%N); echo "STORM-START ts=$S0 dir=$SD"
    cp --sparse=always "$SRC_A" "$SD/storm_a.img" & ca=$!
    sleep 14
    cp --sparse=always "$SRC_B" "$SD/storm_b.img" & cb=$!
    for i in $(seq 1 "$STORM_WAIT_S"); do
        [ "$(awk '/^Dirty:/{print $2}' /proc/meminfo)" -ge "$DIRTY_KB" ] && [ $(( ($(date +%s%N) - S0) / 1000000000 )) -ge "$STORM_MIN_S" ] && break
        sleep 1
    done
    echo "storm: dirty $(awk '/^Dirty:/{print $2}' /proc/meminfo) kB at unmount, $(( ($(date +%s%N) - S0) / 1000000000 ))s after its start"
fi

cat > "$OUT/umount.sh" <<'EOF'
umount /mnt/shared & p=$!; t0=$(date +%s%N); k=0
while kill -0 $p 2>/dev/null; do
    k=$((k + 1)); sleep 1
    case $k in 10|20|40) echo "STACK at=${k}s $(tr '\n' ' ' < /proc/$p/stack)" ;; esac
    [ $k -ge 120 ] && { echo "UMOUNT still running at 120s"; break; }
done
wait $p; rc=$?
echo "UMOUNT ms=$(( ($(date +%s%N) - t0) / 1000000 )) rc=$rc mounted=$(grep -c ' /mnt/shared mxfs ' /proc/mounts)"
EOF
U0=$(date +%s%N); echo "UNMOUNT-START ts=$U0"
for n in $A $B; do
    timeout 150 "$SSH" "$n" "bash -s" < "$OUT/umount.sh" > "$OUT/${n}_umount.out" 2>&1 & eval "u_$n=\$!"
done
wait "$(eval echo \$u_$A)"; wait "$(eval echo \$u_$B)"
for n in $A $B; do rs 20 "$n" "touch /tmp/cus_stop.$LABEL"; done
wait "$(eval echo \$s_$A)"; wait "$(eval echo \$s_$B)"
for n in $A $B; do rs 20 "$n" "rm -f /tmp/cus_stop.$LABEL; dmesg | tail -400" > "$OUT/${n}_kmsg_tail.txt"; done
rm -f "$OUT/.sampling"; wait $smp; wait $fsp; wait $adp
rm -f -- "$OUT/fsync_probe.bin"
if [ -n "$SD" ]; then
    wait $ca; wait $cb
    rm -f -- "$SD/storm_a.img" "$SD/storm_b.img"; rmdir -- "$SD"
fi
ua=$(sed -n 's/^UMOUNT ms=\([0-9]*\).*/\1/p' "$OUT/${A}_umount.out"); ub=$(sed -n 's/^UMOUNT ms=\([0-9]*\).*/\1/p' "$OUT/${B}_umount.out")
for n in $A $B; do echo "$n: $(grep -a 'UMOUNT\|STACK' "$OUT/${n}_umount.out" | cut -c1-400)"; done
echo "target thread samples not idle: $(grep -c '^THR' "$OUT/host_samples.txt") (D: $(grep -c '^THR.* state=D ' "$OUT/host_samples.txt")); most frequent stacks:"
grep '^THR' "$OUT/host_samples.txt" | sed 's/.* stack=//' | sort | uniq -c | sort -rn | head -6 | cut -c1-300
echo "jbd2 samples in D: $(grep -c '^JBD2' "$OUT/host_samples.txt"); most frequent stacks:"
grep '^JBD2' "$OUT/host_samples.txt" | sed 's/.* stack=//' | sort | uniq -c | sort -rn | head -4 | cut -c1-300
echo "scst/iscsi/kswapd samples in D: $(grep -c '^HD' "$OUT/host_samples.txt"), by thread and stack:"
grep '^HD' "$OUT/host_samples.txt" | sed -E 's/.* comm=([^ ]*[^0-9 ])[0-9_]* stack=/\1 /' | sort | uniq -c | sort -rn | head -8 | cut -c1-300
echo "host tasks in D (2 Hz scan): $(grep -c '^AD' "$OUT/host_alld.txt") samples; by command and top three frames:"
grep '^AD' "$OUT/host_alld.txt" | sed -E 's/.* comm=\(([^)]*)\) stack=([^ ]* [^ ]* [^ ]*).*/\1 \2/; s/^([a-z_/.-]*[^0-9 :])[0-9:_]* /\1 /' | sort | uniq -c | sort -rn | head -10 | cut -c1-300
fmax=$(sed -n 's/^FSYNC .* ms=//p' "$OUT/fsync_probe.txt" | sort -n | tail -1)
echo "root fdatasync probe: $(grep -c '^FSYNC' "$OUT/fsync_probe.txt") samples, max ${fmax:-none} ms, over 1000 ms: $(sed -n 's/^FSYNC .* ms=//p' "$OUT/fsync_probe.txt" | awk '$1 > 1000' | wc -l)"
for n in $A $B; do echo "$n SCSI commands outstanding (max per device over the lap): $(grep -a '^SCSI' "$OUT/${n}_inflight.txt" | tr ' ' '\n' | grep -a '^sd[a-z]*=' | awk -F'[=:]' '{if ($2 > m[$1]) m[$1] = $2; s[$1] = s[$1] == "" ? $3 : s[$1]} END {for (d in m) printf "%s=%d ", d, m[d]}')"; done
echo "RESULT: MEASURED caw_umount_storm label=$LABEL storm=$STORM $CONFIG umount_ms_$A=${ua:-none} umount_ms_$B=${ub:-none} thr_d=$(grep -c '^THR.* state=D ' "$OUT/host_samples.txt") jbd2_d=$(grep -c '^JBD2' "$OUT/host_samples.txt") hd=$(grep -c '^HD' "$OUT/host_samples.txt") fsync_max_ms=${fmax:-none} evidence=$OUT"
exit 0
