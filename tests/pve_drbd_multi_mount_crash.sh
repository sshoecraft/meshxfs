#!/bin/bash
# pve_drbd_multi_mount_crash.sh — two MXFS filesystems on two DRBD resources of
# one Proxmox pair, and one host of the pair destroyed with both mounted.
#
# Each host writes and fsyncs files on every resource's mount and reads the
# other's back.  Then the victim (a nested VM, destroyed through libvirt) dies
# with every mount up.  The survivor must fence it on EVERY resource (each
# resource's fence-peer handler; the survivor is participant 0, the lower
# DRBD address, so it wins every split), take fsynced writes again on every
# mount within RECOVER_BOUND_S, and read back the victim's fsynced files.  The
# victim then boots, and its mxfs-drbd@ units must bring EVERY resource back:
# each exclusion released on that resource's own evidence (a peer still
# holding one resource mounted must not keep another one excluded), every
# mount up within MOUNT_BOUND_S of the boot, and the victim reading the
# survivor's post-crash files.
#
# Usage: tests/pve_drbd_multi_mount_crash.sh
# Env:   PVE_PAIR   "<survivor addr> <victim addr>" (default the nested pair
#                   B, 192.168.120.211 192.168.120.212); the survivor must be
#                   participant 0, the lower address
#        VICTIM_DOM libvirt domain of the victim (default pve9-4)
#        MOUNTS     "<resource>:<mountpoint> ..." (default
#                   "mxfs:/mnt/shared mxfs2:/mnt/shared2")
#
# Budget (TIMEOUTS ARE PERFORMANCE ASSERTIONS): DRBD notices the lost peer in
# ~7 s (ping-int 3), the fence-peer handler isolates it at once, and the
# module declares the death on its lock link's timeout and grace and replays:
# the rig's network transport recovers a dead node in ~68 s (62 s window +
# takeover), so RECOVER_BOUND_S=120.  The victim's boot ~60 s plus its units'
# own MOUNT_BUDGET (300 s in scripts/pve_pair_update.sh: the heartbeat scan
# ~64 s, DRBD connect and resync, twice over): MOUNT_BOUND_S=360.
set -u
cd "$(dirname "$0")/.."
REPO=$PWD
SSHP="$REPO/tools/mxfs_sshpass.sh"
read -r -a PAIR <<<"${PVE_PAIR:-192.168.120.211 192.168.120.212}"
S=${PAIR[0]}; V=${PAIR[1]}
VICTIM_DOM=${VICTIM_DOM:-pve9-4}
read -r -a MOUNTS <<<"${MOUNTS:-mxfs:/mnt/shared mxfs2:/mnt/shared2}"
RECOVER_BOUND_S=120
MOUNT_BOUND_S=360

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT=$REPO/tests/evidence/pve_drbd_multi_mount/$STAMP-$(cat VERSION)
mkdir -p "$OUT"
exec > >(tee "$OUT/run.log") 2>&1
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
on() {  # <host> <bound s> <command>
    timeout "$2" "$SSHP" "$1" "$3" </dev/null 2>&1 | grep -avE '^Warning:|^$'
}
mnt_list() { local x; for x in "${MOUNTS[@]}"; do echo -n "${x#*:} "; done; }
res_list() { local x; for x in "${MOUNTS[@]}"; do echo -n "${x%%:*} "; done; }

echo "pve_drbd_multi_mount_crash: survivor=$S victim=$V ($VICTIM_DOM) mounts=[${MOUNTS[*]}] evidence=$OUT"
for h in "$S" "$V"; do
    r=$(on "$h" 30 "for m in $(mnt_list); do grep -q \" \$m mxfs \" /proc/mounts && echo MOUNTED \$m || echo MISSING \$m; done; for r in $(res_list); do [ \"\$(systemctl is-enabled mxfs-drbd@\$r)\" = enabled ] || echo NOT_ENABLED mxfs-drbd@\$r; done; cat /sys/module/mxfs/version")
    echo "$h: $(echo $r)"
    grep -q MISSING <<<"$r" && { echo "ABORT: $h does not have every mount up"; exit 2; }
    # the victim's rejoin is its units starting at boot, as docs/drbd-setup.md
    # sets them up; a unit that is not enabled would read as a failed rejoin
    grep -q NOT_ENABLED <<<"$r" && { echo "ABORT: $h: $(grep NOT_ENABLED <<<"$r" | tr '\n' ' ')(systemctl enable it)"; exit 2; }
done
TAG=PDMM-$STAMP
for h in "$S" "$V"; do on "$h" 10 "echo $TAG > /dev/kmsg"; done

# Every host writes 2 x 8 MiB, fsynced, on every mount.
for h in "$S" "$V"; do
    on "$h" 60 "for m in $(mnt_list); do d=\$m/pdmm/\$(hostname); mkdir -p \$d; for i in 1 2; do head -c 8388608 /dev/urandom > \$d/f\$i && sync -f \$d/f\$i || echo WRITE_FAIL \$m; done; echo SUM \$m \$(cd \$d && md5sum f1 f2 | awk '{print \$1}' | tr '\n' ' '); done" > "$OUT/sums.$h"
    grep -q WRITE_FAIL "$OUT/sums.$h" && fail "$h write: $(grep WRITE_FAIL "$OUT/sums.$h")"
done
SN=$(on "$S" 10 hostname); VN=$(on "$V" 10 hostname)
check_read() {  # <reader addr> <writer host name> <writer sums file> <what>
    local m want got
    for m in $(mnt_list); do
        want=$(echo $(awk -v m=$m '$1 == "SUM" && $2 == m {$1 = ""; $2 = ""; print}' "$3"))
        got=$(echo $(on "$1" 30 "cd $m/pdmm/$2 && md5sum f1 f2" | awk 'NF == 2 {print $1}'))
        [ -n "$want" ] && [ "$want" = "$got" ] || fail "$1 reads $4$2's files on $m: got [$got] want [$want]"
    done
}
check_read "$S" "$VN" "$OUT/sums.$V" ""
check_read "$V" "$SN" "$OUT/sums.$S" ""
echo "cross-read: both hosts read each other's files on every mount"
[ "$FAILS" = 0 ] || { echo "RESULT: FAIL stage=before fails=$FAILS evidence=$OUT"; exit 1; }

echo "crash: destroying $VICTIM_DOM ($V) with every mount up"
timeout 60 sudo virsh -c qemu:///system destroy "$VICTIM_DOM" >/dev/null 2>&1 || fail "virsh destroy $VICTIM_DOM"
on "$S" $((RECOVER_BOUND_S + 10)) "t0=\$(date +%s%N); for m in $(mnt_list); do ( mkdir -p \$m/post && head -c 1048576 /dev/urandom > \$m/post/f && sync -f \$m/post/f && echo POST_OK \$m \$(( (\$(date +%s%N) - t0) / 1000000 )) \$(md5sum < \$m/post/f | cut -c1-32) ) & done; wait" > "$OUT/post"
for m in $(mnt_list); do
    l=$(awk -v m=$m '$1 == "POST_OK" && $2 == m' "$OUT/post")
    if [ -n "$l" ]; then
        echo "recovered $m on $SN: wrote again $(awk '{print $3}' <<<"$l") ms after the crash"
    else
        echo "recovered $m on $SN: NEVER within ${RECOVER_BOUND_S}s"
    fi
    [ -n "$l" ] || fail "$SN: $m took no write within ${RECOVER_BOUND_S}s of $VN's death"
done
check_read "$S" "$VN" "$OUT/sums.$V" "the dead "
on "$S" 30 "for r in $(res_list); do echo \"fence \$r: \$(tail -1 /var/lib/mxfs/drbd-fence.\$r 2>/dev/null)\"; /usr/sbin/mxfs-drbd-fence-self status $VN \$r 2>/dev/null | head -2; done" | sed 's/^/  /'

timeout 60 sudo virsh -c qemu:///system start "$VICTIM_DOM" >/dev/null 2>&1 || fail "virsh start $VICTIM_DOM"
t0=$(date +%s)
back=0
while [ $(( $(date +%s) - t0 )) -lt $MOUNT_BOUND_S ]; do
    r=$(on "$V" 10 "for m in $(mnt_list); do grep -q \" \$m mxfs \" /proc/mounts && echo MOUNTED \$m; done")
    [ "$(grep -c MOUNTED <<<"$r")" = "${#MOUNTS[@]}" ] && { back=1; break; }
    sleep 10
done
echo "victim back: $back after $(( $(date +%s) - t0 )) s (bound $MOUNT_BOUND_S s)"
on "$V" 30 "for r in $(res_list); do echo \"\$r: unit=\$(systemctl is-active mxfs-drbd@\$r) role=\$(drbdadm role \$r) ds=\$(drbdadm dstate \$r)\"; done; journalctl -b -u 'mxfs-drbd@*' --no-pager 2>/dev/null | grep -aE 'waiting|excluded|released|mounting|refused' | tail -8" | sed 's/^/  /'
on "$S" 30 "for r in $(res_list); do echo \"fence \$r: \$(tail -1 /var/lib/mxfs/drbd-fence.\$r 2>/dev/null)\"; done" | sed 's/^/  /'
if [ "$back" = 1 ]; then
    for m in $(mnt_list); do
        want=$(awk -v m=$m '$1 == "POST_OK" && $2 == m {print $4}' "$OUT/post")
        got=$(on "$V" 30 "md5sum < $m/post/f" | awk 'NF == 2 {print $1}')
        [ -n "$want" ] && [ "$want" = "$got" ] || fail "$VN reads the survivor's post-crash file on $m: got [$got] want [$want]"
    done
else
    fail "$VN did not bring every mount back within ${MOUNT_BOUND_S}s of its start"
fi

for h in "$S" "$V"; do
    on "$h" 30 "dmesg | sed -n '/$TAG/,\$p'" > "$OUT/dmesg.$h"
    bad=$(grep -aE 'BUG:|Oops|WARNING:|[Cc]orrupt[^=]|[Cc]orruption|EUCLEAN|Busy inodes' "$OUT/dmesg.$h" | head -3)
    [ -z "$bad" ] || fail "$h kernel: $bad"
done
echo "RESULT: $([ "$FAILS" = 0 ] && echo PASS || echo FAIL) survivor=$SN victim=$VN mounts=[${MOUNTS[*]}] fails=$FAILS evidence=$OUT"
[ "$FAILS" = 0 ]
