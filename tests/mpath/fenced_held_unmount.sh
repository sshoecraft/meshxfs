#!/bin/bash
# tests/mpath/fenced_held_unmount.sh — a fenced MXFS node whose writes the
# target aborted without answering: how long until they come back and the
# node can unmount?
#
# For D-FENCED-VICTIM-WITHDRAW-HANGS-IN-SHUTDOWN-LOG-FORCE.  A fence is a
# PREEMPT AND ABORT.  iscsi-scst releases the victim's commands it aborts
# without any response, and the victim's initiator holds each one for three
# expiries of its command timeout (540 s at the 180 s MeshXFS asks for); the
# fenced filesystem's unmount waits on them.  A fenced shutdown now runs
# fenced_path_reset_helper (pal/linux/kern.c), which drops the node's own
# iSCSI connections so the held writes are requeued and return RESERVATION
# CONFLICT at once.
#
# path_fenced_return reaches the hold only when its fence lands while the
# target still holds one of the victim's commands, and with the 34 s death
# window it rarely does: the frozen guest's writes mostly wait inside the
# guest and bounce at the thaw.  This lap puts the PREEMPT AND ABORT where
# preempt_abort_inflight.sh caught commands in 3 of 3 laps, FHU_FREEZE_S
# after the freeze, against the victim's own MeshXFS key, and grades the
# filesystem's side: the fenced shutdown, the drain, the unmount.
#
# One lap, on a prepped group (every node mounted):
#   1. Y unmounts; X keeps its mount.  X's fenced_path_reset_helper is set
#      (FHU_HELPER: default keeps the module's path, off empties it) and read
#      back, with whether the helper is installed
#   2. X runs one fio job keeping FHU_DEPTH 1 MiB O_DIRECT writes in flight to
#      a preallocated file on the mount
#   3. after FHU_LOAD_S X is frozen; Y registers KY on its paths and,
#      FHU_FREEZE_S after the freeze, PREEMPT AND ABORTs X's key with the type
#      of X's reservation; X is thawed
#   4. X's writer is killed; the lap waits up to FHU_WAIT_S for X's fio to
#      exit and every one of its paths' in-flight counts to reach 0
#      (drain_ms after the thaw), then unmounts X (umount_rc, umount_ms)
#   5. evidence: X's kernel log from the lap mark, the host's SCST lines
#      around the preempt (the commands of X it caught); Y clears every
#      registration
#
# PASS: the preempt caught at least one command (otherwise VACUOUS: the lap
# measured nothing), X drained within FHU_BOUND_S and unmounted with rc 0.
# FHU_BOUND_S (40) derived from the two ways X learns it was fenced.  The
# fast one: its writes bounce at the thaw, the PR worker's health tick or
# three conflicts start the PR IN inspection, a confirmed "gone" fences the
# mount, the helper drops both connections in ~30 ms and the requeued writes
# bounce (3.2 s measured).  The other: the path that carried a caught command
# can stop answering everything, the PR IN included, until its connection is
# dropped (a2l3: sda's reads and PR IN unanswered for 35 s while sdb
# answered), and then the authority lease ends it: 30 s after the last beat
# that landed before the freeze (25 s or more after the thaw, the freeze
# being FHU_FREEZE_S), noticed within one abandoned heartbeat I/O (8 s) and a
# beat interval (2 s), then the reset and the bounce (~1 s): ~36 s.  A first
# derivation (15 s) counted only the fast way.  The RESULT line names the
# detector (fence=) and when it fired after the thaw (fence_s=, X's clock).
# FHU_WAIT_S (600) is a measurement window, not a pass bound: a lap without
# the reset must outlast three 180 s expiries for its writes to return and
# leave the node reusable.
# X has been fenced: re-prep the group before the next lap
# (MXFS_FORCE_PREP=1 ./run.sh <config> --group <group> prep_cluster).
#
# Usage: tests/mpath/fenced_held_unmount.sh <label> [X=test16] [Y=test15] [dev=/dev/mapper/mpatha]
# Env: FHU_HELPER (default|off) FHU_DEPTH (32) FHU_LOAD_S (3) FHU_FREEZE_S (5)
#      FHU_WAIT_S (600) FHU_BOUND_S (15)
set -u
LABEL=${1:?label}; X=${2:-test16}; Y=${3:-test15}; DEV=${4:-/dev/mapper/mpatha}
HELPER=${FHU_HELPER:-default}; DEPTH=${FHU_DEPTH:-32}; LOAD_S=${FHU_LOAD_S:-3}
FREEZE_S=${FHU_FREEZE_S:-5}; WAIT_S=${FHU_WAIT_S:-600}; BOUND_S=${FHU_BOUND_S:-40}
cd "$(dirname "$0")/../.." || exit 2
SSH=tools/mxfs_sshpass.sh
VIRSH="virsh -c qemu:///system"
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_fenced_held_unmount_$LABEL
mkdir -p "$OUT"
KY=0x5a5a00000000b002
MNT=/mnt/shared
PARAM=/sys/module/mxfs/parameters/fenced_path_reset_helper
RUN=/run/fhu.$LABEL
MARK="FHU-$LABEL-$$"
rsx() { local t=$1 n=$2; shift 2; timeout "$t" $SSH "$n" "$*" 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
now_ms() { date +%s%3N; }
abort() { echo "RESULT: ABORT fenced_held_unmount label=$LABEL -- $* evidence=$OUT"; exit 2; }
case "$HELPER" in default|off) ;; *) abort "FHU_HELPER must be default or off (got $HELPER)" ;; esac
# pool VMs nobody holds are shut off by release helpers: hold both for the lap
. tests/lib/runlock.sh
vmhold_take fenced_held_unmount "$X" "$Y" || abort "could not hold $X $Y"
scripts/clyde_preflight.sh > "$OUT/preflight.txt" 2>&1 || abort "host preflight failed ($OUT/preflight.txt)"
trap 'timeout 30 $VIRSH resume "$X" >/dev/null 2>&1' EXIT

# 1. X alone keeps the mount
[ "$(rsx 20 "$X" "awk '\$2==\"$MNT\" && \$3==\"mxfs\"' /proc/mounts | wc -l")" = 1 ] ||
    abort "$X has no mxfs mount at $MNT (prep the group first)"
rsx 60 "$Y" "timeout 50 umount $MNT; echo rc=\$?; awk '\$3==\"mxfs\"' /proc/mounts | wc -l" > "$OUT/umount_$Y.txt"
[ "$(tail -1 "$OUT/umount_$Y.txt")" = 0 ] || abort "$Y still has an mxfs mount ($(head -1 "$OUT/umount_$Y.txt"))"
paths_of() { rsx 20 "$1" "d=\$(basename \$(readlink -f $DEV)); ls /sys/block/\$d/slaves"; }
PX=$(paths_of "$X" | tr '\n' ' '); PY=$(paths_of "$Y" | tr '\n' ' ')
[ -n "$PX" ] && [ -n "$PY" ] || abort "no SCSI paths under $DEV"
YP=/dev/${PY%% *}
[ "$HELPER" = off ] && rsx 15 "$X" "echo > $PARAM"
hv=$(rsx 15 "$X" "cat $PARAM" | tr -d '\r\n')
inst=$(rsx 15 "$X" "test -x /usr/sbin/mxfs_fenced_path_reset.sh && md5sum /usr/sbin/mxfs_fenced_path_reset.sh | cut -c1-8 || echo missing")
echo "helper arm=$HELPER param='$hv' installed=$inst ($(md5sum tools/mxfs_fenced_path_reset.sh | cut -c1-8) in the tree)  paths $X: $PX $Y: $PY  out=$OUT"
if [ "$HELPER" = off ]; then
    [ -z "$hv" ] || abort "$X's fenced_path_reset_helper did not empty (got '$hv')"
else
    [ "$hv" = /usr/sbin/mxfs_fenced_path_reset.sh ] || abort "$X's fenced_path_reset_helper is '$hv', not the default"
    [ "$inst" != missing ] || abort "the helper is not installed on $X"
fi
rsx 20 "$Y" "sg_persist --in --read-keys $YP; sg_persist --in --read-reservation $YP" > "$OUT/keys_before.txt"
KX=$(grep -ai '^ *0x[0-9a-f]*$' "$OUT/keys_before.txt" | tr -d ' ' | sort -u)
[ "$(grep -c . <<<"$KX")" = 1 ] || abort "expected exactly one registered key (X's) once $Y unmounted, got: $(tr '\n' ' ' <<<"$KX")"
# the reservation's own line ("scope: LU_SCOPE,  type: ..."), not the
# "Peripheral device type: disk" line sg_persist prints first
rtype=$(grep -ai 'scope:.*type:' "$OUT/keys_before.txt" | sed 's/.*type: *//' | head -1)
case "$rtype" in
    "Write Exclusive, registrants only"*) T=5 ;;
    "Exclusive Access, registrants only"*) T=6 ;;
    "Write Exclusive, all registrants"*) T=7 ;;
    "Exclusive Access, all registrants"*) T=8 ;;
    "Write Exclusive"*) T=1 ;;
    "Exclusive Access"*) T=3 ;;
    *) abort "could not read X's reservation type ('$rtype')" ;;
esac
echo "X's key $KX holds a type $T reservation ($rtype)"

# 2. the writer
rsx 30 "$X" "rm -rf $RUN; mkdir -p $RUN; echo $MARK > /dev/kmsg; f=$MNT/fhu_writer_$X; fallocate -l 1G \$f && { nohup setsid fio --name=fhu --filename=\$f --rw=randwrite --bs=1M --iodepth=$DEPTH --ioengine=libaio --direct=1 --size=1G --time_based --runtime=$(( LOAD_S + 60 )) --continue_on_error=all --output=$RUN/fio.txt < /dev/null > $RUN/fio.out 2>&1 & echo \$! > $RUN/fio.pid; echo started; }" > "$OUT/writer.txt"
grep -q '^started' "$OUT/writer.txt" || abort "$X's writer did not start ($(tr '\n' ' ' < "$OUT/writer.txt"))"
sleep "$LOAD_S"
rsx 15 "$X" "for p in $PX; do echo \$p \$(cat /sys/block/\$p/inflight); done" > "$OUT/inflight_at_freeze.txt"

# 3. freeze, preempt, thaw
t_freeze=$(now_ms); tools/lun_pool.sh fault timeout 30 $VIRSH suspend "$X" >/dev/null 2>&1
st=$($VIRSH domstate "$X" 2>/dev/null | head -1)
[ "$st" = paused ] || abort "$X did not freeze (state $st)"
for p in $PY; do rsx 20 "$Y" "sg_persist --out --register-ignore --param-sark=$KY /dev/$p; echo rc=\$?"; done > "$OUT/register.txt"
rest=$(( t_freeze + FREEZE_S * 1000 - $(now_ms) ))
[ "$rest" -gt 0 ] && sleep "$(( rest / 1000 )).$(printf '%03d' $(( rest % 1000 )))"
t_pa=$(now_ms)
rsx 20 "$Y" "sg_persist --out --preempt-abort --param-rk=$KY --param-sark=$KX --prout-type=$T $YP; echo rc=\$?" > "$OUT/preempt.txt"
t_pa_done=$(now_ms)
rsx 20 "$Y" "sg_persist --in --read-keys $YP" > "$OUT/keys_after_preempt.txt"
t_thaw=$(now_ms); timeout 30 $VIRSH resume "$X" >/dev/null 2>&1
echo "freeze=$t_freeze preempt=$t_pa..$t_pa_done ($(grep -o 'rc=[0-9]*' "$OUT/preempt.txt")) thaw=$t_thaw kx_left=$(grep -aci "${KX#0x}" "$OUT/keys_after_preempt.txt") register_rcs=$(grep -o 'rc=[0-9]*' "$OUT/register.txt" | tr '\n' ' ')"

# 4. stop the writer; wait for it and every path to drain; unmount
rsx 20 "$X" "echo $MARK-THAWED > /dev/kmsg; kill -9 \$(cat $RUN/fio.pid) 2>/dev/null; echo killed"> "$OUT/kill.txt"
deadline=$(( t_thaw + WAIT_S * 1000 )); left=1; samples=0
while [ "$(now_ms)" -lt "$deadline" ]; do
    left=$(rsx 15 "$X" "n=\$(ps -o pid= -C fio | wc -l); for p in $PX; do read r w < /sys/block/\$p/inflight; n=\$(( n + r + w )); done; echo \$n")
    [ "${left:-1}" = 0 ] && break
    samples=$(( samples + 1 ))
    sleep 2
done
t_drained=$(now_ms)
drain_ms=$(( t_drained - t_thaw ))
rsx 15 "$X" "for p in $PX; do echo \$p inflight \$(cat /sys/block/\$p/inflight); done; ps -o pid=,stat=,etimes= -C fio" > "$OUT/inflight_at_end.txt"
umount_rc=- umount_ms=-
if [ "${left:-1}" = 0 ]; then
    t_u=$(now_ms)
    umount_rc=$(rsx 60 "$X" "timeout 50 umount $MNT; echo \$?" | tail -1)
    umount_ms=$(( $(now_ms) - t_u ))
else
    drain_ms=">=$drain_ms"
fi

# 5. evidence; clear every registration
rsx 30 "$X" "dmesg | sed -n '/$MARK/,\$p'" > "$OUT/kmsg_$X.txt"
journalctl -k --since "@$(( t_pa / 1000 - 1 ))" --until "@$(( t_pa_done / 1000 + 3 ))" --no-pager > "$OUT/host_preempt.txt" 2>/dev/null
journalctl -k --since "@$(( t_freeze / 1000 - 5 ))" --no-pager 2>/dev/null | grep -a 'scst\|iscsi' > "$OUT/host_lap.txt"
caught=$(awk '/Aborting task set/{t=1} /Resetting LUN/{t=0} /Aborted cmd/{if (t) c++} END{print c+0}' "$OUT/host_preempt.txt")
rsx 20 "$Y" "sg_persist --out --clear --param-rk=$KY $YP; echo rc=\$?; sg_persist --in --read-keys $YP" > "$OUT/clear_after.txt"
age=$(grep -ao 'cmd_age=[0-9]*s' "$OUT/kmsg_$X.txt" | tr -dc '0-9\n' | sort -n | tail -1)
resets=$(grep -ac 'P-FENCED-PATH-RESET' "$OUT/kmsg_$X.txt")
# which detector fenced X, and when, on X's own clock from the thaw mark
fence=$(grep -ao 'P131-SELF-FENCE \[[A-Z_]*\]' "$OUT/kmsg_$X.txt" | head -1 | tr -d '[]' | cut -d' ' -f2)
fence_s=$(awk -v m="$MARK-THAWED" 'index($0, m) {t = substr($0, 2, index($0, "]") - 2) + 0} /P131-SELF-FENCE/ && t {f = substr($0, 2, index($0, "]") - 2) + 0; printf "%.1f", f - t; exit}' "$OUT/kmsg_$X.txt")
grep -a 'P-FENCED-PATH-RESET\|P277-FENCED-SELF-WITHDRAW\|P131-SELF-FENCE\|Shutting down filesystem\|P-LOG-FENCED-SHUTDOWN\|detected conn error' "$OUT/kmsg_$X.txt" | cut -c1-220 | head -14
v=FAIL
if [ "$caught" = 0 ]; then
    v=VACUOUS
elif [ "${left:-1}" = 0 ] && [ "$drain_ms" -le $(( BOUND_S * 1000 )) ] && [ "$umount_rc" = 0 ]; then
    v=PASS
fi
echo "RESULT: $v fenced_held_unmount label=$LABEL helper=$HELPER caught=$caught drain_ms=$drain_ms umount_rc=$umount_rc umount_ms=$umount_ms max_cmd_age_s=${age:-0} resets=$resets fence=${fence:-none} fence_s=${fence_s:--} bound_s=$BOUND_S evidence=$OUT"
