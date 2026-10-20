#!/bin/bash
# tests/mpath/preempt_abort_inflight.sh — how long does a FROZEN initiator's
# in-flight write take to come back after another initiator's PREEMPT AND
# ABORT removed its key, measured at the SCSI layer with no MXFS involved.
#
# For D-FENCED-VICTIM-WITHDRAW-HANGS-IN-SHUTDOWN-LOG-FORCE.  After the fix that
# lets a fenced shutdown skip its log force, a fenced victim's unmount still
# waits for any log write the layer below holds.  Hypothesis H-V3: the
# survivor's fence (PREEMPT AND ABORT) aborts the victim's commands queued at
# the target, and with the Control mode page's TAS bit clear (SCST vdisk
# default, DEF_TAS 0) SCST aborts another initiator's command "without delivery
# or notification" (scst_xmit_process_aborted_cmd), so the victim's initiator
# hears nothing until its SCSI command timeout (180 s on the rig, which
# docs/iscsi_setup.md requires) fires and the error handler runs.
#
# One lap:
#   1. X and Y unmount; every SCSI path of the LUN on X registers KX, on Y KY;
#      Y reserves Write Exclusive - Registrants Only (type 5) with KY
#   2. X runs one fio job: PIA_DEPTH 1 MiB O_DIRECT writes in flight to a
#      scratch region, every completion's latency logged
#   3. after PIA_LOAD_S X is frozen (virsh suspend); after PIA_FREEZE_S Y
#      issues PREEMPT AND ABORT of KX; X is thawed
#   4. the writers are told to stop; the lap waits up to PIA_WAIT_S for every
#      write that was in flight to return, then reads X's kernel log
#   5. Y clears every registration (PR OUT CLEAR)
# Prints held_ms (the longest completion latency of a second or more: the
# guest's clock stands still while it is paused, so that is time after the thaw) and the error-handler lines X logged.  A write still
# outstanding at PIA_WAIT_S is printed as held_ms>=<bound>.
#
# PIA_WAIT_S (200) is the measurement window, not a pass bound: it must outlast
# the 180 s command timeout for the hold to be seen at all.
# The LUN's contents are overwritten: re-prep the group afterwards
# (MXFS_FORCE_PREP=1 ./run.sh <config> --group <group> prep_cluster).
#
# Usage: tests/mpath/preempt_abort_inflight.sh <label> [X=test16] [Y=test15] [dev=/dev/mapper/mpatha]
# Env: PIA_DEPTH (32) PIA_LOAD_S (3) PIA_FREEZE_S (5) PIA_WAIT_S (200)
#      PIA_TRACE=1: X records the scsi and iscsi trace events (command
#      dispatch, completion, timeout, error-handler wakeup, and libiscsi's
#      ISCSI_DBG_* decisions, which reach the trace buffer even with its debug
#      logging off) from just before its writer starts; saved as trace_X.txt
#      PIA_RELEASE=hostreset: PIA_RELEASE_AFTER_S (10) after the thaw, X
#      resets the SCSI host of each of its paths of the LUN (sg_reset -H; on
#      iSCSI a host is one session, and libiscsi's host reset fails and
#      re-establishes that session without any task-management function to
#      the target); saved as release.txt
set -u
LABEL=${1:?label}; X=${2:-test16}; Y=${3:-test15}; DEV=${4:-/dev/mapper/mpatha}
DEPTH=${PIA_DEPTH:-32}; LOAD_S=${PIA_LOAD_S:-3}; FREEZE_S=${PIA_FREEZE_S:-5}; WAIT_S=${PIA_WAIT_S:-200}
cd "$(dirname "$0")/../.." || exit 2
SSH=tools/mxfs_sshpass.sh
VIRSH="virsh -c qemu:///system"
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_preempt_abort_inflight_$LABEL
mkdir -p "$OUT"
KX=0x5a5a00000000a001; KY=0x5a5a00000000a002
RUN=/run/pia.$LABEL
MARK="PIA-$LABEL-$$"
rsx() { local t=$1 n=$2; shift 2; timeout "$t" $SSH "$n" "$*" 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
now_ms() { date +%s%3N; }
# pool VMs nobody holds are shut off by release helpers: hold both for the lap
. tests/lib/runlock.sh
vmhold_take preempt_abort_inflight "$X" "$Y" || { echo "RESULT: ABORT preempt_abort_inflight label=$LABEL -- could not hold $X $Y"; exit 2; }
scripts/clyde_preflight.sh > "$OUT/preflight.txt" 2>&1 || { echo "RESULT: ABORT preempt_abort_inflight label=$LABEL -- host preflight failed ($OUT/preflight.txt)"; exit 2; }
trap 'timeout 30 $VIRSH resume "$X" >/dev/null 2>&1' EXIT

# the LUN's SCSI paths on a node: the slaves of the dm map DEV names
paths_of() { rsx 20 "$1" "d=\$(basename \$(readlink -f $DEV)); ls /sys/block/\$d/slaves"; }
for n in "$X" "$Y"; do
    rsx 45 "$n" "timeout 40 umount /mnt/shared 2>/dev/null; awk '\$3==\"mxfs\"' /proc/mounts | wc -l" > "$OUT/umount_$n.txt"
    m=$(tail -1 "$OUT/umount_$n.txt")
    [ -n "$m" ] || { echo "RESULT: ABORT preempt_abort_inflight label=$LABEL -- could not read $n's mounts (node unreachable?)"; exit 2; }
    [ "$m" = 0 ] || { echo "RESULT: ABORT preempt_abort_inflight label=$LABEL -- $n still has an mxfs mount"; exit 2; }
done
PX=$(paths_of "$X" | tr '\n' ' '); PY=$(paths_of "$Y" | tr '\n' ' ')
echo "paths $X: $PX  $Y: $PY  dev=$DEV out=$OUT"
[ -n "$PX" ] && [ -n "$PY" ] || { echo "RESULT: ABORT preempt_abort_inflight label=$LABEL -- no SCSI paths under $DEV"; exit 2; }
YP=/dev/${PY%% *}

# 1. keys on every path, Y's reservation (clear any leftover first)
rsx 20 "$Y" "sg_persist --out --register-ignore --param-sark=$KY $YP >/dev/null 2>&1; sg_persist --out --clear --param-rk=$KY $YP" > "$OUT/clear_before.txt" 2>&1
for p in $PX; do rsx 20 "$X" "sg_persist --out --register-ignore --param-sark=$KX /dev/$p; echo rc=\$?" >> "$OUT/register.txt"; done
for p in $PY; do rsx 20 "$Y" "sg_persist --out --register-ignore --param-sark=$KY /dev/$p; echo rc=\$?" >> "$OUT/register.txt"; done
rsx 20 "$Y" "sg_persist --out --reserve --param-rk=$KY --prout-type=5 $YP; echo rc=\$?" >> "$OUT/register.txt"
rsx 20 "$Y" "sg_persist --in --read-keys $YP; sg_persist --in --read-reservation $YP" > "$OUT/keys_before.txt"
echo "keys before: $(grep -ac 0x "$OUT/keys_before.txt") descriptor lines; register rcs: $(grep -o 'rc=[0-9]*' "$OUT/register.txt" | tr '\n' ' ')"

# 2. the writer on X: one fio job keeping PIA_DEPTH 1 MiB O_DIRECT writes in
#    flight (a 1 MiB command is sent as 64 KiB unsolicited plus R2T bursts, so
#    some are mid-transfer at any instant), every completion's latency logged.
#    The guest's clock does not run while it is paused, so a latency of a
#    second or more is time the write was held AFTER the thaw.
TR=/sys/kernel/tracing
if [ "${PIA_TRACE:-0}" = 1 ]; then
    rsx 20 "$X" "echo 0 > $TR/tracing_on; echo > $TR/trace; echo 8192 > $TR/buffer_size_kb; for e in scsi/scsi_dispatch_cmd_start scsi/scsi_dispatch_cmd_done scsi/scsi_dispatch_cmd_error scsi/scsi_dispatch_cmd_timeout scsi/scsi_eh_wakeup iscsi; do echo 1 > $TR/events/\$e/enable; done; echo 1 > $TR/tracing_on; echo trace_on=\$(cat $TR/tracing_on)" > "$OUT/trace_arm.txt"
fi
rsx 20 "$X" "rm -rf $RUN; mkdir -p $RUN; echo $MARK > /dev/kmsg; nohup setsid fio --name=pia --filename=$DEV --rw=randwrite --bs=1M --iodepth=$DEPTH --ioengine=libaio --direct=1 --offset=1G --size=8G --time_based --runtime=$((LOAD_S + 4)) --continue_on_error=all --write_lat_log=$RUN/pia --log_avg_msec=0 --output=$RUN/fio.txt < /dev/null > $RUN/fio.out 2>&1 & echo started"
sleep "$LOAD_S"

# 3. freeze, preempt, thaw
t_freeze=$(now_ms); tools/lun_pool.sh fault timeout 30 $VIRSH suspend "$X" >/dev/null 2>&1
st=$($VIRSH domstate "$X" 2>/dev/null | head -1)
[ "$st" = paused ] || { echo "RESULT: ABORT preempt_abort_inflight label=$LABEL -- $X did not freeze (state $st)"; exit 2; }
sleep "$FREEZE_S"
t_pa=$(now_ms)
rsx 20 "$Y" "sg_persist --out --preempt-abort --param-rk=$KY --param-sark=$KX --prout-type=5 $YP; echo rc=\$?" > "$OUT/preempt.txt"
t_pa_done=$(now_ms)
rsx 20 "$Y" "sg_persist --in --read-keys $YP" > "$OUT/keys_after_preempt.txt"
t_thaw=$(now_ms); timeout 30 $VIRSH resume "$X" >/dev/null 2>&1
echo "freeze=$t_freeze preempt=$t_pa..$t_pa_done ($(grep -o 'rc=[0-9]*' "$OUT/preempt.txt")) thaw=$t_thaw kx_left=$(grep -aci "${KX#0x}" "$OUT/keys_after_preempt.txt")"

if [ "${PIA_RELEASE:-}" = hostreset ]; then
    sleep "${PIA_RELEASE_AFTER_S:-10}"
    rsx 120 "$X" "echo PIA-RELEASE-$LABEL > /dev/kmsg; for p in $PX; do s=\$(date +%s%3N); timeout 90 sg_reset -H /dev/\$p; rc=\$?; echo \"\$p host_reset rc=\$rc ms=\$(( \$(date +%s%3N) - s )) inflight=\$(cat /sys/block/\$p/inflight | tr -s ' ')\"; done" > "$OUT/release.txt"
    echo "release (sg_reset -H, $(( $(now_ms) - t_thaw )) ms after the thaw): $(tr '\n' ';' < "$OUT/release.txt")"
fi
# PIA_RELEASE=connkill: X destroys the TCP connection of each iSCSI session
# under its paths of the LUN (ss -K to the session's portal).  libiscsi then
# fails the connection and iscsid recovers the SAME session (the SCSI devices
# stay), requeueing the commands it held; no task-management function reaches
# the target.  Saved as release.txt.
if [ "${PIA_RELEASE:-}" = connkill ]; then
    sleep "${PIA_RELEASE_AFTER_S:-10}"
    rsx 120 "$X" "echo PIA-RELEASE-$LABEL > /dev/kmsg; for p in $PX; do h=\$(readlink -f /sys/block/\$p/device/../..); c=\$(ls -d \$h/connection*/iscsi_connection/connection* 2>/dev/null | head -1); a=\$(cat \$c/persistent_address 2>/dev/null); pt=\$(cat \$c/persistent_port 2>/dev/null); s=\$(date +%s%3N); ss -K dst \$a dport = :\$pt > /dev/null 2>&1; rc=\$?; echo \"\$p session=\$(basename \$h) conn=\$(basename \$c) portal=\$a:\$pt connkill rc=\$rc ms=\$(( \$(date +%s%3N) - s )) inflight=\$(cat /sys/block/\$p/inflight | tr -s ' ')\"; done" > "$OUT/release.txt"
    echo "release (connkill, $(( $(now_ms) - t_thaw )) ms after the thaw): $(tr '\n' ';' < "$OUT/release.txt")"
fi
# 4. fio stops issuing at its runtime and exits once every write in flight has
#    returned: wait for that, up to PIA_WAIT_S
#    and for every command on X's paths of the LUN to come back.  fio's exit
#    alone is not that: measured, a lap whose fio had exited still had a write
#    outstanding on a path that returned 90 s later (cmd_age=90s), so a write
#    counts as returned only when the path's inflight count says so.
deadline=$(( $(now_ms) + WAIT_S * 1000 )); left=1
while [ "$(now_ms)" -lt "$deadline" ]; do
    left=$(rsx 15 "$X" "n=\$(ps -o pid= -C fio | wc -l); for p in $PX; do read r w < /sys/block/\$p/inflight; n=\$(( n + r + w )); done; echo \$n")
    [ "${left:-1}" = 0 ] && break
    sleep 2
done
t_end=$(now_ms)
rsx 15 "$X" "for p in $PX; do echo \$p inflight \$(cat /sys/block/\$p/inflight); done; ps -o pid=,stat=,etimes= -C fio" > "$OUT/inflight_at_end.txt"
rsx 30 "$X" "cat $RUN/pia_clat.1.log" > "$OUT/clat.log"
rsx 30 "$X" "cat $RUN/fio.txt $RUN/fio.out" > "$OUT/fio.txt"
rsx 30 "$X" "dmesg | sed -n '/$MARK/,\$p'" > "$OUT/kmsg_$X.txt"
if [ "${PIA_TRACE:-0}" = 1 ]; then
    rsx 60 "$X" "echo 0 > $TR/tracing_on; cat $TR/trace; echo 0 > $TR/events/enable; echo > $TR/trace" > "$OUT/trace_$X.txt"
fi

# 5. clear every registration
rsx 20 "$Y" "sg_persist --out --clear --param-rk=$KY $YP; echo rc=\$?; sg_persist --in --read-keys $YP" > "$OUT/clear_after.txt"

python3 - "$OUT/clat.log" "$t_thaw" "${left:-?}" "$t_end" "$WAIT_S" <<'EOF' | tee "$OUT/verdict.txt"
import sys
path, tt, left, te, wait_s = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
lat = []
for line in open(path):
    p = [x.strip() for x in line.split(',')]
    if len(p) >= 2 and p[1].isdigit():
        lat.append(int(p[1]) / 1e6)     # fio 3.x logs completion latency in ns
lat.sort()
held = [x for x in lat if x >= 1000]
print(f"writes={len(lat)} max_ms={lat[-1] if lat else 0:.0f} p99_ms={lat[int(len(lat) * 0.99)] if lat else 0:.0f} held_over_1s={len(held)} held_ms={[round(x) for x in held[-8:]]}")
if left not in ('0', '?'):
    print(f"held_ms>={te - tt} (writes still outstanding at the {wait_s} s bound)")
else:
    print(f"held_ms={round(held[-1]) if held else 0}")
EOF
grep -aE 'timing out|abort|Abort|reset|reservation conflict|Failing path|FAILED|cleared by another' "$OUT/kmsg_$X.txt" | cut -c1-200 | head -20
# the oldest command the victim logged returning (the midlayer prints cmd_age
# on a failed command): a write the timeout ladder released after fio exited
age=$(grep -ao 'cmd_age=[0-9]*s' "$OUT/kmsg_$X.txt" | tr -dc '0-9\n' | sort -n | tail -1)
echo "RESULT: MEASURED preempt_abort_inflight label=$LABEL $(tail -1 "$OUT/verdict.txt") max_cmd_age_s=${age:-0} evidence=$OUT"
