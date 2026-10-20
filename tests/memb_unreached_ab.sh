#!/bin/bash
# memb_unreached_ab.sh — a TCP mount that cannot discover its live peer: is it
# refused at the membership-settle gate with the cause and the fix named, or
# does it spend the root inode's lock retries, shut its filesystem down and
# leave mount(8) printing "can't read superblock" about 40 s later?
#
# For D-A-MOUNT-THAT-CANNOT-DISCOVER-ITS-LIVE-PEER-FAILS-AS-CANT-READ-SUPERBLOCK.
# The incident (0.89.84, test3/test4, QNAP LUN): multicast DROP rules left on
# both nodes by an aborted harness round, test3 mounted, test4's plain mount
# logged 'discovery broadcast failed', P-MEMB-SETTLE-TIMEOUT at +11 s, three
# root-inode EX lock failures after 60 retries, a filesystem shutdown,
# P-WITHDRAW, P960-REFUSED-MOUNT-NOCOVER, and mount rc=32 "can't read
# superblock" at ~40 s.  Here the same condition is made on purpose and on B
# only: B drops all multicast (224.0.0.0/4, in and out), which carries both
# discovery and the lease, and mounts with no peer= while A stays mounted.
#
# One same-build knob between the arms: memb_unreached_refuse (dlm/v5_mount.c),
# written on B and read back before anything else; 0 is the control.
#
# Steps: knob on B -> A starts a write loop (one 4 KiB file + fsync a second,
# for the whole lap) -> B unmounts -> B starts a kernel-log capture -> B drops
# multicast -> B mounts with no peer= (timed; stderr kept) -> B's capture read
# -> multicast restored on B -> B mounts again (rc and wall) -> A's loop
# stopped and its errors counted.  Multicast is restored on every exit.
#
# Usage: tests/memb_unreached_ab.sh <label> <knob 0|1> <A> <B>
#   The group must already be prepared (2/net/mesh/direct or mpath) with both
#   nodes mounted; the LUN is resolved from B's live mount.
# Prints one line:
#   RESULT: MEASURED|ABORT label=<l> knob=<k> mount_rc=<rc|hung> mount_ms=<ms>
#     late_mount=<0|1|-> refuse_line=<n> err_msg=<0|1> err_errno=<0|1> err_msg_fc=<0|1|->
#     superblock_msg=<0|1> settle_timeout=<n> lockfail=<n> park=<n>
#     withdraw=<n> shutdown=<n> remount_rc=<rc> remount_ms=<ms> a_writes=<n>
#     a_errors=<n> evidence=<dir>
#   err_msg: mount(8)'s stderr carries the refusal's reason.  This rig's
#   mount(8) is util-linux 2.39, which mounts through fsopen/fsconfig and never
#   reads the mount context, so no kernel text can reach it there; err_errno:
#   its stderr names the cause by the errno alone ("No route to host");
#   err_msg_fc: the fix arm mounts once more under the drop through
#   tests/fsopen_mount.py, which reads the context as util-linux >= 2.40 does,
#   and the reason names the cause ('-' on the control, which does not).
#   lockfail/park: the root inode's exhausted retry rounds and P-LKRETRY-PARK
#   lines, the path a mount past the settle gate takes.  mount_rc=hung: the
#   mount answered neither its TERM at 70 s nor its KILL at 100 s; late_mount:
#   whether such a mount ended mounted once multicast was restored.
#   The arm grades nothing; the queue that runs it carries the rules.
#
# derived bound: knob write and read-back 15 + A's loop start 15 + B's umount
# 30 + capture start 15 + multicast drop 15 + the mount 110 (the control's
# measured ~40 s on 0.89.84, the 70 s observation window for it, the KILL 30 s
# later, a 10 s ssh margin) + capture read 30 + the fix arm's context mount 35
# (the 15 s gate, a 5 s liveness pass, the teardown) + restore 15 + a hung
# mount's late answer 75 (control only; a fix arm never hangs) + the remount 40
# (a joining mount ~5-8 s on this rig, plus a settle) + A's loop stop and read
# 20 = 415 s; a fix arm, which refuses in ~17 s and never hangs, 300 s.
set -u
LABEL=${1:?label}; K=${2:?knob 0|1}; A=${3:?A}; B=${4:?B}
case $K in 0|1) ;; *) echo "RESULT: ABORT label=$LABEL -- knob must be 0 or 1"; exit 2 ;; esac
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO" || exit 2
SSH=tools/mxfs_sshpass.sh
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_memb_unreached_$LABEL
mkdir -p "$OUT"
. tests/lib/rig.sh
MARK="MUA-$LABEL-$$"
P=/sys/module/mxfs/parameters
on() { local n=$1 t=$2; shift 2; timeout "$t" $SSH "$n" "$*" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
BLK="if command -v iptables >/dev/null; then iptables -I INPUT -d 224.0.0.0/4 -j DROP && iptables -I OUTPUT -d 224.0.0.0/4 -j DROP && echo blocked; else nft add table inet mxfs_mua && nft add chain inet mxfs_mua in { type filter hook input priority 0 \\; } && nft add chain inet mxfs_mua out { type filter hook output priority 0 \\; } && nft add rule inet mxfs_mua in ip daddr 224.0.0.0/4 drop && nft add rule inet mxfs_mua out ip daddr 224.0.0.0/4 drop && echo blocked; fi"
UNBLK="if command -v iptables >/dev/null; then while iptables -D INPUT -d 224.0.0.0/4 -j DROP 2>/dev/null; do :; done; while iptables -D OUTPUT -d 224.0.0.0/4 -j DROP 2>/dev/null; do :; done; echo unblocked; else nft delete table inet mxfs_mua 2>/dev/null; echo unblocked; fi"
BLOCKED=0
restore() { [ "$BLOCKED" = 1 ] && on "$B" 15 "$UNBLK" > "$OUT/unblock.txt"; BLOCKED=0; }
trap restore EXIT
abort() { echo "RESULT: ABORT label=$LABEL knob=$K -- $1 evidence=$OUT"; exit 2; }

# the LUN as B mounts it now; a pool rig names its allocation by node set, and
# the resolver's ABORT lines must reach the console the queue reads
export MXFS_NODE_LIST=${MXFS_NODE_LIST:-$A,$B}
mxfs_dev_resolve "$B"; LUN=$MXFS_DEV_RESOLVED
echo "DEVICE node=$B path=$LUN source=$MXFS_DEV_SOURCE wwid=$MXFS_DEV_WWID fsid=$MXFS_DEV_FSID" > "$OUT/device.txt"
got=$(on "$B" 15 "echo $K > $P/memb_unreached_refuse && cat $P/memb_unreached_refuse")
echo "$B memb_unreached_refuse=$got" | tee "$OUT/knob.txt"
[ "$got" = "$K" ] || abort "$B did not read memb_unreached_refuse back as $K ($got)"

# A writes for the whole lap; every failed write is an ERR line
on "$A" 15 "mkdir -p /mnt/shared/mua_$LABEL && rm -f /run/mua_$LABEL.stop && nohup sh -c 'i=0; while [ ! -e /run/mua_$LABEL.stop ] && [ \$i -lt 400 ]; do i=\$((i+1)); if dd if=/dev/zero of=/mnt/shared/mua_$LABEL/f\$i bs=4k count=1 conv=fsync 2>/dev/null; then echo OK \$i; else echo ERR \$i; fi; sleep 1; done' > /run/mua_$LABEL.a 2>&1 < /dev/null & echo started" > "$OUT/a_start.txt"
grep -q started "$OUT/a_start.txt" || abort "A's write loop did not start"

U=$(on "$B" 30 "echo $MARK-UMOUNT > /dev/kmsg; timeout 25 umount /mnt/shared; echo urc=\$?")
echo "$U" > "$OUT/umount.txt"
echo "$U" | grep -q 'urc=0' || abort "B's unmount failed ($U)"
on "$B" 15 "rm -f /run/mua_$LABEL.k; nohup dmesg --follow-new < /dev/null > /run/mua_$LABEL.k 2>/dev/null & echo \$! > /run/mua_$LABEL.k.pid; echo cap" > "$OUT/cap_start.txt"
grep -q cap "$OUT/cap_start.txt" || abort "B's kernel-log capture did not start"
b=$(on "$B" 15 "$BLK")
echo "$b" > "$OUT/block.txt"
[ "$b" = blocked ] || abort "multicast could not be dropped on B ($b)"
BLOCKED=1

M=$(on "$B" 110 "echo $MARK-MOUNT > /dev/kmsg; t0=\$(date +%s%3N); timeout -k 30 70 mount -t mxfs $LUN /mnt/shared > /run/mua_$LABEL.err 2>&1; rc=\$?; echo mount_rc=\$rc mount_ms=\$(( \$(date +%s%3N) - t0 )); sed 's/^/stderr: /' /run/mua_$LABEL.err")
echo "$M" | tee "$OUT/mount.txt"
MRC=$(echo "$M" | grep -o 'mount_rc=[0-9]*' | cut -d= -f2); MMS=$(echo "$M" | grep -o 'mount_ms=[0-9]*' | cut -d= -f2)
# a mount that outlives its TERM at 70 s and its KILL at 100 s never answers
# the ssh: that is a hang, measured as one (lap muc2, 0.90.131: the mount
# ignored both and completed once multicast came back)
if [ -z "$MRC" ]; then
    echo "$B's mount still running at the 110 s ssh bound: a hang" | tee -a "$OUT/mount.txt"
    MRC=hung; MMS=110000
fi
sleep 3
on "$B" 30 "kill \$(cat /run/mua_$LABEL.k.pid) 2>/dev/null; cat /run/mua_$LABEL.k" > "$OUT/kmsg_$B.txt"
grep -q "$MARK-MOUNT" "$OUT/kmsg_$B.txt" || abort "B's kernel-log capture holds no mount marker"
KF="$OUT/kmsg_$B.txt"
REFUSE=$(grep -ac 'P-MEMB-UNREACHED-REFUSE' "$KF")
TMO=$(grep -ac 'P-MEMB-SETTLE-TIMEOUT' "$KF")
WD=$(grep -ac 'P-WITHDRAW' "$KF")
SD=$(grep -aci 'shutting down filesystem' "$KF")
ERRMSG=0; echo "$M" | grep -q 'cluster discovery never reached' && ERRMSG=1
ERRNO=0; echo "$M" | grep -qi 'no route to host' && ERRNO=1
SBMSG=0; echo "$M" | grep -qi "can't read superblock" && SBMSG=1
LKFAIL=$(grep -ac 'lock request failed after [0-9]* retries' "$KF")
PARK=$(grep -ac 'P-LKRETRY-PARK' "$KF")
# a mount that succeeded under the drop is unmounted before the restore
[ "$MRC" = 0 ] && on "$B" 30 "timeout 25 umount /mnt/shared; echo post_urc=\$?" >> "$OUT/mount.txt"

# the refusal's reason as the mount context carries it: the fix arm only, and
# after the capture, so the counts above see one refusal
FC=-
if [ "$K" = 1 ] && [ "$MRC" != 0 ]; then
    F=$(on "$B" 35 "timeout 30 python3 /src/mxfs/tests/fsopen_mount.py mxfs $LUN /mnt/shared; echo fsopen_rc=\$?")
    echo "$F" | tee "$OUT/fsopen.txt"
    FC=0; echo "$F" | grep -q '^fc: .*cluster discovery never reached' && FC=1
    echo "$F" | grep -q '^result: rc=0 ' && on "$B" 30 "timeout 25 umount /mnt/shared; echo post_urc=\$?" >> "$OUT/fsopen.txt"
fi

restore
cat "$OUT/unblock.txt"
# a hung mount is left to answer now that the peer is reachable: whether it
# ends mounted (late_mount=1) is recorded, and B is unmounted for the remount
LATE=-
if [ "$MRC" = hung ]; then
    L=$(on "$B" 75 "w=0; while ps -C mount > /dev/null && [ \$w -lt 60 ]; do sleep 1; w=\$((w+1)); done; ps -o pid,stat,etime,wchan:30,cmd -C mount; echo waited=\$w; grep -c ' mxfs ' /proc/mounts | sed 's/^/mounted=/'")
    echo "$L" | tee "$OUT/late.txt"
    LATE=$(echo "$L" | grep -o 'mounted=[0-9]*' | cut -d= -f2)
    [ "$LATE" = 1 ] && on "$B" 30 "timeout 25 umount /mnt/shared; echo late_urc=\$?" | tee -a "$OUT/late.txt"
fi
R=$(on "$B" 45 "t0=\$(date +%s%3N); timeout 40 mount -t mxfs $LUN /mnt/shared 2>&1 | tail -2; echo remount_rc=\${PIPESTATUS[0]} remount_ms=\$(( \$(date +%s%3N) - t0 )); mountpoint -q /mnt/shared && ls /mnt/shared > /dev/null && echo remounted=1")
echo "$R" | tee "$OUT/remount.txt"
RRC=$(echo "$R" | grep -o 'remount_rc=[0-9]*' | cut -d= -f2); RMS=$(echo "$R" | grep -o 'remount_ms=[0-9]*' | cut -d= -f2)

on "$A" 20 "touch /run/mua_$LABEL.stop; sleep 2; cat /run/mua_$LABEL.a" > "$OUT/a_loop.txt"
AW=$(grep -c '^OK ' "$OUT/a_loop.txt"); AE=$(grep -c '^ERR ' "$OUT/a_loop.txt")
echo "RESULT: MEASURED label=$LABEL knob=$K mount_rc=$MRC mount_ms=${MMS:-?} late_mount=$LATE refuse_line=$REFUSE err_msg=$ERRMSG err_errno=$ERRNO err_msg_fc=$FC superblock_msg=$SBMSG settle_timeout=$TMO lockfail=$LKFAIL park=$PARK withdraw=$WD shutdown=$SD remount_rc=${RRC:-?} remount_ms=${RMS:-?} a_writes=$AW a_errors=$AE evidence=$OUT"
