#!/bin/bash
# tests/caw_host_storm_probe.sh — does a burst of buffered writes on the lab
# host's own filesystem hold a COMPARE AND WRITE in the SCST target?
#
# WHY.  D-CAWMPATH-UMOUNT-RELEASE-ALL-CAW-HELD-57S-BOTH-NODES: on
# 2/disk/caw/mpath both nodes' unmounts sat 57 s (13:34:10-13:35:07Z on
# 2026-10-17) in a COMPARE AND WRITE the target did not answer, with no error,
# no SCSI EH and no task-management function on either side, and resumed at
# the same second.  The host's sar for those minutes (/var/log/sysstat/sa17):
# nvme0n1 average await 19, 45 and 69 ms at 13:33, 13:34 and 13:35 (0.4-1.4 ms
# otherwise), queue depth 78-110, dirty pages 3.0, 4.3 and 6.3 G, drained to
# 0.2 G by 13:35:02.  Two tools/lun_pool.sh snapshot copies (cp --sparse=always
# of 20 GiB pool images holding 12-15 G of data each) had started at 13:31:53Z
# and 13:32:07Z onto the ext4 (data=ordered) that holds the pool's LUN files.
# The pool LUNs are vdisk_fileio with o_direct=1, write_through=0 and
# nv_cache=0, so a FUA CAW ends in an fdatasync of its LUN file; that can wait
# on the root filesystem's journal commit, and in data=ordered mode a commit
# waits on the ordered data of every inode in it, the copies' included.  SCST
# serialises COMPARE AND WRITE per device, so one held CAW holds the other
# initiator's.
#
# WHAT IT DOES.  Binds one free pool LUN to <node> alone (tools/lun_pool.sh
# alloc), then runs on the node a loop of tools/caw_verify write (READ(16)
# FUA, COMPARE AND WRITE FUA, READ(16) FUA on one block near the end of the
# LUN) every 200 ms for <secs> s and records each iteration's latency.  <pre>
# seconds in, the host starts the storm: cp --sparse=always of <img_a> and,
# 14 s later (the incident's spacing), of <img_b>, into a fresh directory
# under <storm_dir>.  Every second the host records Dirty/Writeback, and for
# each target thread of the probed LUN (comm mxfspool<NN>*) not idle in
# scst_cmd_thread, its state and kernel stack; iostat -x samples the pool's
# NVMe at 1 s.  The storm files are removed and the LUN freed at the end.
# The source images are read, never written: run it only while no run holds
# their LUNs (tools/lun_pool.sh status shows them free or kept).
#
# PREDICTIONS (H-CAW1, written before the first run):
#   baseline     every iteration before the storm takes < 50 ms
#   storm on /   at least one iteration takes > 10 s, and while it lasts a
#                target thread of the LUN is sampled blocked under ext4/jbd2
#                (ext4_sync_file, jbd2_log_wait_commit,
#                jbd2_complete_transaction) or the block layer
#   storm on a filesystem on another device (/mxfs): no iteration > 1 s
# A storm-on-/ run whose slowest iteration stays under 1 s refutes H-CAW1.
#
# Bound: alloc 60 + node checks 2x20 + the loop <secs>+30 + free 60, and the
# storm runs inside the loop: 410 s at the defaults.
#
# Usage: tests/caw_host_storm_probe.sh <label> <node> <storm_dir> [secs=240] [pre=60] [img_a] [img_b]
#        img_a/img_b default to the pool's lun02.img and lun06.img.
# Exit 0 measured (the verdict lines are printed), 2 ABORT.
set -u
LABEL=${1:?label}; NODE=${2:?node}; STORM_DIR=${3:?storm_dir}
SECS=${4:-240}; PRE=${5:-60}
cd "$(dirname "$0")/.." || exit 2
POOLDIR=$(tools/mxfs_lab.sh get paths pool)
IMG_A=${6:-$POOLDIR/lun02.img}; IMG_B=${7:-$POOLDIR/lun06.img}
SSH=tools/mxfs_sshpass.sh
case "$SECS$PRE" in *[!0-9]*) echo "secs and pre must be numbers of seconds"; exit 2 ;; esac
[ "$PRE" -lt "$SECS" ] || { echo "pre must be less than secs"; exit 2; }
[ -d "$STORM_DIR" ] || { echo "RESULT: ABORT label=$LABEL -- no storm directory $STORM_DIR"; exit 2; }
[ -r "$IMG_A" ] && [ -r "$IMG_B" ] || { echo "RESULT: ABORT label=$LABEL -- cannot read $IMG_A or $IMG_B"; exit 2; }
for img in "$IMG_A" "$IMG_B"; do
    id=$(basename "$img" .img); id=${id#lun}
    st=$(tools/lun_pool.sh status | awk -v l="lun$id" '$1 == l {print $4}')
    case "$st" in free|kept) ;; *) echo "RESULT: ABORT label=$LABEL -- lun$id is '$st', not free or kept: a run may be writing it"; exit 2 ;; esac
done
need=$(( $(stat -c '%b * %B' "$IMG_A") + $(stat -c '%b * %B' "$IMG_B") ))
free=$(df -PB1 "$STORM_DIR" | awk 'NR==2{print $4}')
floor=$(( ${MXFS_PREFLIGHT_MIN_FREE_GB:-10} * 1073741824 ))
[ $((free - need)) -ge "$floor" ] || { echo "RESULT: ABORT label=$LABEL -- $STORM_DIR has $((free / 1073741824))G free; the storm can write $((need / 1073741824))G and the host floor is ${MXFS_PREFLIGHT_MIN_FREE_GB:-10}G"; exit 2; }

. tests/lib/runlock.sh
runlock_take "$RUNLOCK" shared "caw_host_storm_probe $LABEL" || { echo "RESULT: ABORT label=$LABEL -- the rig is held exclusively: $(runlock_holder "$RUNLOCK")"; exit 2; }
runlock_nodes "caw_host_storm_probe $LABEL" "$NODE" || { echo "RESULT: ABORT label=$LABEL -- $NODE is held by another run"; exit 2; }
vmhold_take "caw_host_storm_probe $LABEL" "$NODE" || { echo "RESULT: ABORT label=$LABEL -- could not hold $NODE"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_caw_host_storm_$LABEL
mkdir -p "$OUT"
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
echo "=== caw_host_storm_probe label=$LABEL node=$NODE storm_dir=$STORM_DIR ($(df -PT "$STORM_DIR" | awk 'NR==2{print $1, $2}')) secs=$SECS pre=$PRE img_a=$IMG_A img_b=$IMG_B out=$OUT $(date -u +%FT%TZ) ==="

line=$(timeout 60 tools/lun_pool.sh alloc --owner $$ --what "caw_host_storm_probe $LABEL" "$NODE" 2>&1 | tee "$OUT/alloc.log" | grep '^POOL_LUN' | tail -1)
[ -n "$line" ] || { echo "RESULT: ABORT label=$LABEL stage=alloc evidence=$OUT"; exit 2; }
LID=$(echo "$line" | sed -n 's/.* id=\([0-9]*\) .*/\1/p')
DEV=$(echo "$line" | sed -n 's/.* dev=\([^ ]*\) .*/\1/p')
SIZE=$(echo "$line" | sed -n 's/.* size=\([0-9]*\) .*/\1/p')
LBA=$(( SIZE / 512 - 8 ))
echo "lun$LID dev=$DEV lba=$LBA"
release() { timeout 60 tools/lun_pool.sh free "$LID" --owner $$ > "$OUT/free.log" 2>&1; echo "freed lun$LID rc=$?"; }
rs 20 "$NODE" "test -b $DEV && /src/mxfs/tools/caw_verify write $DEV $LBA 5a 2>&1 | tail -1" > "$OUT/first_caw.txt"
grep -q '^\[write\] OK:' "$OUT/first_caw.txt" || { echo "RESULT: ABORT label=$LABEL -- the first CAW on $NODE:$DEV did not answer: $(cat "$OUT/first_caw.txt") evidence=$OUT"; release; exit 2; }

# the target threads serving this LUN, named after its SCST device
TPIDS=""
for c in /proc/[0-9]*/comm; do
    case "$(cat "$c" 2>/dev/null)" in "mxfspool$LID"*) p=${c#/proc/}; TPIDS="$TPIDS ${p%/comm}" ;; esac
done
echo "target threads of mxfspool$LID:$TPIDS"
[ -n "$TPIDS" ] || { echo "RESULT: ABORT label=$LABEL -- no target thread named mxfspool$LID* evidence=$OUT"; release; exit 2; }

# the node's clock against the host's, so the node's latencies land on the
# host's storm timeline
h0=$(date +%s%N); n0=$(rs 20 "$NODE" "date +%s%N" | tr -dc 0-9); h1=$(date +%s%N)
OFF_MS=$(( (n0 - (h0 + h1) / 2) / 1000000 ))
echo "node clock offset: ${OFF_MS} ms (node - host, ssh round trip $(( (h1 - h0) / 1000000 )) ms)"

cat > "$OUT/caw_loop.sh" <<EOF
end=\$((\$(date +%s) + $SECS)); i=0
while [ \$(date +%s) -lt \$end ]; do
    i=\$((i + 1)); t0=\$(date +%s%N)
    /src/mxfs/tools/caw_verify write $DEV $LBA \$(printf %02x \$((i % 256))) > /dev/null 2>&1; rc=\$?
    t1=\$(date +%s%N)
    echo "CAWLAT i=\$i t0=\$t0 ms=\$(( (t1 - t0) / 1000000 )) rc=\$rc"
    sleep 0.2
done
EOF
iostat -x -d -t 1 "$(basename "$(df -P "$POOLDIR" | awk 'NR==2{print $1}' | sed 's/p[0-9]*$//')")" > "$OUT/iostat.txt" 2>&1 & iop=$!
: > "$OUT/.sampling"
(
    while [ -e "$OUT/.sampling" ]; do
        ts=$(date +%s%N)
        echo "MEM ts=$ts $(awk '/^Dirty:|^Writeback:/{printf "%s%s ", $1, $2}' /proc/meminfo)"
        for p in $TPIDS; do
            stk=$(sudo -n cat "/proc/$p/stack" 2>/dev/null | awk '{print $2}' | paste -sd' ')
            case "$stk" in scst_cmd_thread*) ;; *) echo "THR ts=$ts pid=$p state=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null) stack=$stk" ;; esac
        done
        sleep 1
    done
) > "$OUT/host_samples.txt" 2>&1 & smp=$!
timeout $((SECS + 30)) "$SSH" "$NODE" "bash -s" < "$OUT/caw_loop.sh" > "$OUT/caw_lat.txt" 2>&1 & lp=$!
sleep "$PRE"
SD=$(mktemp -d "$STORM_DIR/caw_storm.XXXXXX") || { echo "RESULT: ABORT label=$LABEL -- cannot make a storm directory under $STORM_DIR"; rm -f "$OUT/.sampling"; kill $iop 2>/dev/null; wait $lp; release; exit 2; }
S0=$(date +%s%N); echo "STORM-START ts=$S0 dir=$SD"
cp --sparse=always "$IMG_A" "$SD/storm_a.img" & ca=$!
sleep 14
cp --sparse=always "$IMG_B" "$SD/storm_b.img" & cb=$!
wait $ca; ra=$?; wait $cb; rb=$?
S1=$(date +%s%N); echo "STORM-COPIES-DONE ts=$S1 wall=$(( (S1 - S0) / 1000000000 ))s rc_a=$ra rc_b=$rb written=$(du -sh "$SD" | cut -f1)"
wait $lp; lrc=$?
rm -f "$OUT/.sampling"; wait $smp; kill $iop 2>/dev/null; wait $iop 2>/dev/null
rm -f -- "$SD/storm_a.img" "$SD/storm_b.img"; rmdir -- "$SD"
release
echo "caw loop rc=$lrc iterations=$(grep -c '^CAWLAT' "$OUT/caw_lat.txt") failed=$(grep '^CAWLAT' "$OUT/caw_lat.txt" | grep -vc ' rc=0$')"

# phases on the host's clock: before the storm, from its start until the
# copies are done and the dirty pages are back under 100 MB, and after
DRAIN=$(awk -v s1="$S1" '$1 == "MEM" { split($2, a, "="); if (a[2] > s1) { for (i = 3; i <= NF; i++) if ($i ~ /^Dirty:/) { v = substr($i, 7) + 0; if (v < 102400) { print a[2]; exit } } } }' "$OUT/host_samples.txt")
DRAIN=${DRAIN:-$S1}
echo "storm window: start $S0 copies done $S1 dirty drained $DRAIN (host ns)"
awk -v off="$OFF_MS" -v s0="$S0" -v s2="$DRAIN" '
    $1 == "CAWLAT" {
        split($3, t, "="); split($4, m, "="); ms = m[2] + 0
        ht = t[2] - off * 1000000
        ph = (ht < s0) ? "baseline" : (ht <= s2) ? "storm" : "after"
        n[ph]++; if (ms > max[ph]) { max[ph] = ms; at[ph] = $2 }
        if (ms > 1000) gt1[ph]++
        if (ms > 10000) gt10[ph]++
    }
    END {
        split("baseline storm after", o, " ")
        for (k = 1; k <= 3; k++) { p = o[k]
            printf "PHASE %s iterations=%d max_ms=%d (%s) over_1s=%d over_10s=%d\n", p, n[p], max[p], at[p], gt1[p], gt10[p] }
    }' "$OUT/caw_lat.txt" | tee "$OUT/phases.txt"
echo "target thread samples not idle: $(grep -c '^THR' "$OUT/host_samples.txt"); their stacks, most frequent:"
grep '^THR' "$OUT/host_samples.txt" | sed 's/.* stack=//' | sort | uniq -c | sort -rn | head -8
echo "RESULT: MEASURED caw_host_storm_probe label=$LABEL node=$NODE storm_fs=$(df -PT "$STORM_DIR" | awk 'NR==2{print $1}') $(tr '\n' ' ' < "$OUT/phases.txt" | sed 's/PHASE /phase_/g; s/ iterations=/:n=/g') evidence=$OUT"
exit 0
