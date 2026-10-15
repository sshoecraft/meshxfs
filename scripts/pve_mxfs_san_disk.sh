#!/bin/bash
# pve_mxfs_san_disk.sh — MXFS on the physical pair's shared iSCSI LUN
# (scripts/pve_caw_lun.sh), the SAN use case: one LUN both hosts reach, the
# CAW lock transport (SCSI COMPARE AND WRITE on the LUN), SCSI persistent
# reservations for fencing, mounted on both hosts and added to Proxmox as a
# shared directory storage, as a user with a SAN would set it up.  The same VM
# builds can then be timed on it (scripts/pve_build_compare.sh leg `san`)
# against Proxmox's own shared LVM on the same LUN (leg `sanlvm`,
# scripts/pve_lvm_san_baseline.sh).
#
# The packaged module options form new clusters on TCP (force_transport=1).
# This volume is mounted with -o transport=caw, which names its transport
# whatever the module parameter says, so the hosts' other MXFS volumes (the
# pair's DRBD /mnt/shared) keep theirs and the parameter is never touched.
#
# Usage: scripts/pve_mxfs_san_disk.sh up|off|status
#   up   refuses while anything on SAN_DEV is mounted on either host; formats
#        it from host A (whatever is on it is lost), mounts it on both at once,
#        adds the storage
#   join mount the volume on every host that does not hold it (a host back
#        from a reset), joining the cluster the others hold, and adds the
#        storage back if `off` removed it; never formats
#   off  storage removed, both unmounted (bounded), the LUN left as it is
# Env:
#   PVE_PAIR  "<addr> <addr> ..." (default "192.168.1.80 192.168.1.81"): host A
#             (formats) then the others; every host mounts at once
#   SAN_DEV   the LUN's path on each host (default the by-path link of
#             scripts/pve_caw_lun.sh's target)
#   MNT/STORE mount point and Proxmox storage name (default /mnt/mxfssan, mxfssan)
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
read -r -a PAIR <<<"${PVE_PAIR:-192.168.1.80 192.168.1.81}"
SAN_DEV=${SAN_DEV:-/dev/disk/by-path/ip-192.168.1.166:3260-iscsi-iqn.2026-05.local.mxfs:pve-caw-01-lun-0}
MNT=${MNT:-/mnt/mxfssan}; STORE=${STORE:-mxfssan}
P=/sys/module/mxfs/parameters/force_transport

on() {  # <host> <cmd> [timeout]
    timeout "${3:-120}" "$SSHP" "$1" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^$'
    return "${PIPESTATUS[0]}"
}
die() { echo "pve_mxfs_san_disk: $*"; exit 1; }

up() {
    local h d i rc=0
    for h in "${PAIR[@]}"; do
        on "$h" "set -u
            d=\$(readlink -f $SAN_DEV)
            [ -b \"\$d\" ] || { echo 'REFUSE: no $SAN_DEV (scripts/pve_caw_lun.sh login)'; exit 1; }
            lsblk -nro MOUNTPOINT \"\$d\" | grep -q . && { echo \"REFUSE: something on \$d is mounted\"; exit 1; }
            [ -r $P ] || modprobe mxfs || { echo 'REFUSE: mxfs module not loaded'; exit 1; }
            mkdir -p $MNT
            echo \"PREP_OK \$(hostname) dev=\$d force_transport=\$(cat $P)\"" 60 | tail -2 | sed "s/^/$h: /"
        [ "${PIPESTATUS[0]}" = 0 ] || exit 1
    done
    on "${PAIR[0]}" "wipefs -a -q $SAN_DEV && mkfs.mxfs -f $SAN_DEV 2>&1 | tail -3; echo \"mkfs rc=\${PIPESTATUS[0]}\"" 300 \
        | sed "s/^/${PAIR[0]}: /" | tee /dev/stderr | grep -q 'mkfs rc=0' || die "mkfs.mxfs failed"
    # both at once, each forming on CAW
    d=$(mktemp -d) || exit 1
    i=0
    pids=()
    for h in "${PAIR[@]}"; do
        on "$h" "timeout 300 mount -t mxfs -o transport=caw $SAN_DEV $MNT; mrc=\$?
            echo \"\$(hostname): mount rc=\$mrc mnt=\$(findmnt -n -o TARGET,FSTYPE,OPTIONS $MNT | tr -s ' ')\"" 360 > "$d/$i" 2>&1 &
        pids+=($!)
        i=$(( i + 1 ))
    done
    wait "${pids[@]}"
    cat "$d"/[0-9]*
    for (( i = 0; i < ${#PAIR[@]}; i++ )); do grep -q 'mount rc=0' "$d/$i" || rc=1; done
    rm -rf "$d"
    [ "$rc" = 0 ] || die "the volume did not mount on every host"
    for h in "${PAIR[@]}"; do
        on "$h" "dmesg | grep -aE 'mxfs: .*(transport|CAW)' | tail -2" 30 | sed "s/^/$h: /"
    done
    on "${PAIR[0]}" "pvesm status --storage $STORE >/dev/null 2>&1 || pvesm add dir $STORE --path $MNT --shared 1 --is_mountpoint yes --content images; pvesm status --storage $STORE" 60
}

join() {   # mount on every host of PAIR that does not have it; never formats
    local h r rc=0
    for h in "${PAIR[@]}"; do
        r=$(on "$h" "if grep -q ' $MNT mxfs ' /proc/mounts; then echo \"\$(hostname): already mounted\"; exit 0; fi
            [ -r $P ] || modprobe mxfs || { echo 'REFUSE: mxfs module not loaded'; exit 1; }
            mkdir -p $MNT
            timeout 300 mount -t mxfs -o transport=caw $SAN_DEV $MNT; mrc=\$?
            echo \"\$(hostname): mount rc=\$mrc mnt=\$(findmnt -n -o TARGET,FSTYPE $MNT | tr -s ' ')\"" 360)
        echo "$h: $r"
        [[ "$r" == *"already mounted"* || "$r" == *"mount rc=0"* ]] || rc=1
    done
    [ "$rc" = 0 ] || die "the volume did not mount on every host"
    # `off` removes the storage; a join after it (a module update) puts it back
    on "${PAIR[0]}" "pvesm status --storage $STORE >/dev/null 2>&1 || pvesm add dir $STORE --path $MNT --shared 1 --is_mountpoint yes --content images; pvesm status --storage $STORE" 60
}

off() {
    local h
    on "${PAIR[0]}" "pvesm status --storage $STORE >/dev/null 2>&1 && pvesm remove $STORE; echo storage $STORE removed" 60
    # B then A; each unmount bounded: one that hangs is a defect to report,
    # never a reason to force it
    for h in "${PAIR[@]:1}" "${PAIR[0]}"; do
        on "$h" "if grep -q ' $MNT mxfs ' /proc/mounts; then timeout 120 umount $MNT; echo \"\$(hostname): umount rc=\$?\"; else echo \"\$(hostname): not mounted\"; fi" 150
    done
}

status() {
    local h
    for h in "${PAIR[@]}"; do
        on "$h" "echo \"\$(hostname): dev=\$(readlink -f $SAN_DEV) mnt=\$(findmnt -n -o FSTYPE $MNT) force_transport=\$(cat $P 2>/dev/null)\"" 30
    done
}

case "${1:-}" in
    up) up ;;
    join) join ;;
    off) off ;;
    status) status ;;
    *) echo "usage: scripts/pve_mxfs_san_disk.sh up|join|off|status"; exit 2 ;;
esac
