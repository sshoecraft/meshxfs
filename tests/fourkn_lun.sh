#!/bin/bash
# fourkn_lun.sh — a shared LUN with 4096-byte logical blocks on clyde's SCST
# target, bound to two rig nodes, outside the LUN pool.
#
# WHY.  Most new arrays present 4K-native LUNs (4096-byte logical blocks), and
# a tester formatted 0.90.130 on one (gyptazy, "Sector size (logical/physical):
# 4096 bytes / 16384 bytes").  Every rig LUN is a pool LUN with 512-byte
# blocks (scripts/scst_setup.sh blocksize=512), so no mounted MeshXFS had ever
# run on a 4K-native device.  This makes one, with the same SCST objects and
# the same node login the pool uses, so run.sh can be pointed at it with
# MXFS_DEV and run its usual prep and rows.
#
# OUTSIDE THE POOL.  The image is <pool dir>/fourkn01.img, which the pool's
# lunNN.img listing never matches, so no pool allocation can hand it to a run.
# Everything that touches the target or logs a node in holds the pool lock,
# as tools/lun_pool.sh does: a run's host preflight samples the host kernel
# log's rate under that lock, and a login's ~20 lines must not land in it.
#
# Usage:
#   tests/fourkn_lun.sh up <size> <node1> <node2>   create, export, bind; prints MXFS_DEV=<path>
#   tests/fourkn_lun.sh down <node1> <node2>        unbind the nodes, remove the target, device and image
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/tools/mxfs_lab.sh"
SSH="$HERE/tools/mxfs_sshpass.sh"
PORTAL=$(lab_need storage portal) || exit 2
PORTAL=${PORTAL%%:*}
POOL=$(lab_need paths pool) || exit 2
T=/sys/kernel/scst_tgt/targets/iscsi
TGT=iqn.2026-05.local.mxfs:fourkn-01
DEV=mxfs4kn01
IMG=$POOL/fourkn01.img
DEVPATH=/dev/disk/by-path/ip-$PORTAL:3260-iscsi-$TGT-lun-0

die() { echo "fourkn_lun: $*" >&2; exit 1; }
ssh_n() { timeout "${3:-30}" "$SSH" "$(lab_addr "$1")" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'; }
pool_lock() { exec {LOCKFD}>>"$POOL/.lock" || die "cannot open $POOL/.lock"; flock -w 300 "$LOCKFD" || die "pool lock not taken in 300 s"; }

NODE_UNMOUNT='
    for m in $(awk "\$3 == \"mxfs\" {print \$2}" /proc/mounts); do
        for t in 1 2 3 4 5; do
            awk -v m="$m" "\$2 == m && \$3 == \"mxfs\" {f=1} END {exit !f}" /proc/mounts || break
            if mountpoint -q "$m"; then fuser -km "$m" 2>/dev/null; sleep 1; fi
            timeout 30 umount "$m" 2>/dev/null && break
            sleep 1
        done
    done
    if grep -q " mxfs " /proc/mounts; then echo UNMOUNT_FAIL; exit 0; fi'

NODE_LOGIN=$NODE_UNMOUNT'
    for t in 1 2 3 4 5; do lsmod | grep -q "^mxfs " || break; rmmod mxfs 2>/dev/null && break; sleep 2; done
    lsmod | grep -q "^mxfs " && { echo LOGIN_FAIL mxfs still loaded; exit 0; }
    for try in 1 2 3; do
        iscsiadm -m node -u >/dev/null 2>&1
        iscsiadm -m node -o delete >/dev/null 2>&1
        iscsiadm -m node -o new -T TGT -p PORTAL:3260 >/dev/null 2>&1
        iscsiadm -m node -T TGT -p PORTAL:3260 --login >/dev/null 2>&1
        iscsiadm -m session --rescan >/dev/null 2>&1
        sleep 2
        d=$(readlink -f DEVPATH 2>/dev/null)
        if [ -b "$d" ]; then
            echo "LOGIN_OK dev=$d logical=$(blockdev --getss $d) physical=$(blockdev --getpbsz $d) wwid=$(cat /sys/block/$(basename $d)/device/wwid 2>/dev/null | tr -d " ")"
            exit 0
        fi
        sleep 3
    done
    echo LOGIN_FAIL no device'

NODE_LOGOUT=$NODE_UNMOUNT'
    for t in 1 2 3 4 5; do lsmod | grep -q "^mxfs " || break; rmmod mxfs 2>/dev/null && break; sleep 2; done
    iscsiadm -m node -T TGT -p PORTAL:3260 -u >/dev/null 2>&1
    iscsiadm -m node -T TGT -p PORTAL:3260 -o delete >/dev/null 2>&1
    echo LOGOUT_OK'

fill() { echo "$1" | sed -e "s|TGT|$TGT|g" -e "s|PORTAL|$PORTAL|g" -e "s|DEVPATH|$DEVPATH|g"; }

case "${1:-}" in
up)
    SIZE=${2:?size}; N1=${3:?node1}; N2=${4:?node2}
    pool_lock
    [ -e "$IMG" ] || fallocate -l "$SIZE" "$IMG" || die "fallocate $IMG"
    MXFS_SCST_IMG=$IMG MXFS_SCST_DEV=$DEV MXFS_SCST_TGT=$TGT MXFS_SCST_PORTAL_IP=$PORTAL \
        MXFS_SCST_DEVPARAMS="filename=$IMG; blocksize=4096; async=1; o_direct=1" \
        timeout 60 "$HERE/scripts/scst_setup.sh" setup | grep -E 'SCST_SETUP|FAIL'
    bs=$(sudo cat "/sys/kernel/scst_tgt/devices/$DEV/blocksize" 2>/dev/null | head -1)
    [ "$bs" = 4096 ] || die "SCST device $DEV blocksize is '$bs', not 4096"
    g=$T/$TGT/ini_groups
    [ -d "$g/alloc" ] || echo "create alloc" | sudo tee "$g/mgmt" >/dev/null || die "ini group"
    [ -d "$g/alloc/luns/0" ] || echo "add $DEV 0" | sudo tee "$g/alloc/luns/mgmt" >/dev/null || die "group lun"
    [ -d "$T/$TGT/luns/0" ] && { echo "del 0" | sudo tee "$T/$TGT/luns/mgmt" >/dev/null || die "default lun"; }
    for n in "$N1" "$N2"; do
        ini=$(ssh_n "$n" 'sed -n "s/^InitiatorName=//p" /etc/iscsi/initiatorname.iscsi' | grep -a '^iqn\.' | tail -1)
        [ -n "$ini" ] || die "no initiator name from $n"
        [ -e "$g/alloc/initiators/$ini" ] || echo "add $ini" | sudo tee "$g/alloc/initiators/mgmt" >/dev/null || die "initiator $ini"
    done
    for n in "$N1" "$N2"; do
        r=$(ssh_n "$n" "$(fill "$NODE_LOGIN")" 120)
        echo "$n: $r"
        case $r in *LOGIN_OK*logical=4096*) ;; *) die "$n did not log in to a 4096-byte LUN" ;; esac
    done
    echo "MXFS_DEV=$DEVPATH"
    ;;
down)
    N1=${2:?node1}; N2=${3:?node2}
    pool_lock
    for n in "$N1" "$N2"; do echo "$n: $(ssh_n "$n" "$(fill "$NODE_LOGOUT")" 120)"; done
    if [ -d "$T/$TGT" ]; then
        echo "del_target $TGT" | sudo tee "$T/mgmt" >/dev/null || die "del target"
    fi
    if [ -d "/sys/kernel/scst_tgt/devices/$DEV" ]; then
        echo "del_device $DEV" | sudo tee /sys/kernel/scst_tgt/handlers/vdisk_fileio/mgmt >/dev/null || die "del device"
    fi
    # SCST keeps a device's persistent reservations in a file named for it and
    # restores them when a device of that name is created again: a node that
    # departed dirty leaves its key registered as a fence target, so the next
    # `up` would hand back a LUN that refuses every write (reservation
    # conflict at mkfs's first one).  The image goes with them.
    sudo rm -f "/var/lib/scst/pr/$DEV" "/var/lib/scst/pr/$DEV.1"
    rm -f "$IMG"
    echo DOWN_OK
    ;;
*) echo "usage: $0 up <size> <node1> <node2> | down <node1> <node2>" >&2; exit 2 ;;
esac
