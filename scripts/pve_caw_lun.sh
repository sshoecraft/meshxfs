#!/bin/bash
# pve_caw_lun.sh — one CAW-capable iSCSI LUN from clyde's SCST target, shared
# by the physical Proxmox pair (pve1, pve2): the SAN use case, two hosts on one
# LUN with SCSI COMPARE AND WRITE and persistent reservations, which MXFS's
# disk/caw transport runs on.
#
# Kept apart from the rig's LUN pool (tools/lun_pool.sh) on purpose: the pool
# hands its LUNs to rig runs, which format them, and its `alloc` logs a node out
# of every target, unmounts every mxfs and unloads the module, which on a
# Proxmox host would stop whatever else it runs.  This LUN lives outside the
# pool directory, so the pool never sees it, and a host's login here touches no
# other session.
#
#   IMG (fully allocated, fixed size) -> SCST vdisk_fileio device DEV
#     -> iSCSI target TGT, allowed on PORTAL only
#     -> LUN 0 in ini_group `pve`, which holds the pair's initiator names and
#        nobody else's: anything else on the LAN that logs in sees no disk.
#
# SCST objects are runtime-only: after a clyde restart run `setup` again (it
# reuses the image and is idempotent).  The hosts' node records are set to log
# in at boot.
#
# Usage: scripts/pve_caw_lun.sh setup | login | status | logout | teardown
#   setup     create the image if missing, register it with SCST, then `login`
#   login     log each host in to TGT alone; every host must read one WWID
#   status    the SCST side and each host's session and device
#   logout    log each host out of TGT and delete its node record
#   teardown  logout, then remove the SCST target and device (image kept)
# Env: IMG (/home/steve/disks/pve/pvecaw01.img)  SIZE (120G: seven 16 GiB thick LVs for the shared-LVM leg)  DEV (pvecaw01)
#      TGT (iqn.2026-05.local.mxfs:pve-caw-01)  PORTAL (192.168.1.166)
#      PVE_PAIR ("192.168.1.80 192.168.1.81")
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$HERE/tools/mxfs_sshpass.sh"
IMG=${IMG:-/home/steve/disks/pve/pvecaw01.img}
SIZE=${SIZE:-120G}
DEV=${DEV:-pvecaw01}
TGT=${TGT:-iqn.2026-05.local.mxfs:pve-caw-01}
PORTAL=${PORTAL:-192.168.1.166}
read -r -a HOSTS <<<"${PVE_PAIR:-192.168.1.80 192.168.1.81}"
T=/sys/kernel/scst_tgt/targets/iscsi
BYPATH="/dev/disk/by-path/ip-$PORTAL:3260-iscsi-$TGT-lun-0"

die() { echo "pve_caw_lun: $*" >&2; exit 1; }
on() { timeout "${3:-60}" "$SSH" "$1" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you'; }

initiator_of() { on "$1" 'sed -n "s/^InitiatorName=//p" /etc/iscsi/initiatorname.iscsi' | grep -a '^iqn\.' | tail -1; }

cmd_setup() {
    local bytes h ini g
    bytes=$(numfmt --from=iec "$SIZE") || die "bad size $SIZE"
    if [ ! -e "$IMG" ]; then
        mkdir -p "$(dirname "$IMG")" || die "cannot create $(dirname "$IMG")"
        fallocate -l "$bytes" "$IMG" || die "fallocate $SIZE $IMG failed"
        [ "$(( $(stat -c %b "$IMG") * $(stat -c %B "$IMG") ))" -ge "$bytes" ] \
            || die "$IMG is not fully allocated after fallocate"
        echo "created $IMG ($SIZE)"
    elif [ "$(stat -c %s "$IMG")" -lt "$bytes" ]; then
        # grown, never shrunk: the hosts re-read the size at the login rescan
        fallocate -l "$bytes" "$IMG" || die "fallocate $SIZE $IMG failed"
        [ "$(( $(stat -c %b "$IMG") * $(stat -c %B "$IMG") ))" -ge "$bytes" ] \
            || die "$IMG is not fully allocated after growing it"
        grown=1
        echo "grew $IMG to $SIZE"
    fi
    MXFS_SCST_IMG=$IMG MXFS_SCST_DEV=$DEV MXFS_SCST_TGT=$TGT MXFS_SCST_PORTAL_IP=$PORTAL \
        timeout 60 "$HERE/scripts/scst_setup.sh" setup | grep -E 'SCST_SETUP_OK' >/dev/null \
        || die "scst_setup.sh setup failed for $TGT"
    g=$(sudo cat "/sys/kernel/scst_tgt/devices/$DEV/filename" 2>/dev/null | head -1)
    [ "$g" = "$IMG" ] || die "SCST device $DEV holds '$g', not $IMG"
    if [ "${grown:-0}" = 1 ]; then
        echo 1 | sudo tee "/sys/kernel/scst_tgt/devices/$DEV/resync_size" >/dev/null \
            || die "SCST did not re-read the size of $DEV"
        echo "SCST $DEV size now $(sudo cat "/sys/kernel/scst_tgt/devices/$DEV/size_mb" | head -1) MB"
    fi
    g=$T/$TGT/ini_groups
    [ -d "$g/pve" ] || echo "create pve" | sudo tee "$g/mgmt" >/dev/null || die "cannot create ini_group pve"
    [ -d "$g/pve/luns/0" ] || echo "add $DEV 0" | sudo tee "$g/pve/luns/mgmt" >/dev/null || die "cannot map LUN 0 in ini_group pve"
    if [ -d "$T/$TGT/luns/0" ]; then
        echo "del 0" | sudo tee "$T/$TGT/luns/mgmt" >/dev/null || die "cannot remove the default LUN 0"
    fi
    for h in "${HOSTS[@]}"; do
        ini=$(initiator_of "$h")
        [ -n "$ini" ] || die "no initiator name from $h"
        [ -e "$g/pve/initiators/$ini" ] || echo "add $ini" | sudo tee "$g/pve/initiators/mgmt" >/dev/null \
            || die "cannot add $h's initiator $ini"
    done
    echo "SCST: $TGT LUN 0 = $DEV ($IMG) on $PORTAL for: $(ls "$g/pve/initiators" | grep -v '^mgmt$' | tr '\n' ' ')"
    cmd_login
}

# On the host: this target's node record only, logged in at boot; other
# sessions are left alone.
HOST_LOGIN='
    systemctl start iscsid >/dev/null 2>&1
    iscsiadm -m discovery -t st -p PORTAL:3260 >/dev/null 2>&1
    iscsiadm -m node -T TGT -p PORTAL:3260 >/dev/null 2>&1 || iscsiadm -m node -o new -T TGT -p PORTAL:3260 >/dev/null 2>&1
    iscsiadm -m node -T TGT -p PORTAL:3260 --op update -n node.startup -v automatic >/dev/null 2>&1
    iscsiadm -m session 2>/dev/null | grep -q "TGT\$\|TGT " || iscsiadm -m node -T TGT -p PORTAL:3260 --login >/dev/null 2>&1
    iscsiadm -m node -T TGT -p PORTAL:3260 --rescan >/dev/null 2>&1
    for i in $(seq 1 20); do [ -e BYPATH ] && break; iscsiadm -m session --rescan >/dev/null 2>&1; sleep 1; done
    d=$(readlink -f BYPATH 2>/dev/null)
    if [ -b "$d" ]; then echo "LOGIN_OK dev=$d size=$(blockdev --getsize64 $d) wwid=$(cat /sys/block/$(basename $d)/device/wwid 2>/dev/null | tr -d " ")"
    else echo "LOGIN_FAIL no device at BYPATH"; fi'

HOST_LOGOUT='
    iscsiadm -m node -T TGT -p PORTAL:3260 -u >/dev/null 2>&1
    iscsiadm -m node -T TGT -p PORTAL:3260 -o delete >/dev/null 2>&1
    echo LOGOUT_OK'

subst() { local s=${1//TGT/$TGT}; s=${s//PORTAL/$PORTAL}; echo "${s//BYPATH/$BYPATH}"; }

cmd_login() {
    local h line w wwid="" bad=""
    for h in "${HOSTS[@]}"; do
        line=$(on "$h" "$(subst "$HOST_LOGIN")" 120 | grep -aE '^LOGIN_(OK|FAIL)' | tail -1)
        echo "$h: ${line:-unreachable}"
        case "$line" in
            LOGIN_OK*) w=$(sed -n 's/.* wwid=\([^ ]*\).*/\1/p' <<<"$line")
                       [ -z "$wwid" ] && wwid=$w
                       [ -n "$w" ] && [ "$w" = "$wwid" ] || bad="$bad $h(wwid=$w)" ;;
            *) bad="$bad $h" ;;
        esac
    done
    [ -z "$bad" ] || die "login FAIL:$bad"
    echo "PVE_CAW_LUN_OK target=$TGT wwid=$wwid dev=$BYPATH"
}

cmd_logout() {
    local h
    for h in "${HOSTS[@]}"; do echo "$h: $(on "$h" "$(subst "$HOST_LOGOUT")" 60 | grep -a LOGOUT_OK || echo 'no clean logout')"; done
}

cmd_status() {
    local h
    MXFS_SCST_DEV=$DEV MXFS_SCST_TGT=$TGT "$HERE/scripts/scst_setup.sh" status | sed -n '/=== target/,/=== iscsi/p'
    echo "  initiators: $(ls "$T/$TGT/ini_groups/pve/initiators" 2>/dev/null | grep -v '^mgmt$' | tr '\n' ' ')"
    for h in "${HOSTS[@]}"; do
        echo "$h: $(on "$h" "iscsiadm -m session 2>/dev/null | grep -c '$TGT'; readlink -f '$BYPATH' 2>/dev/null" | tr '\n' ' ')"
    done
}

case "${1:-}" in
    setup)    cmd_setup ;;
    login)    cmd_login ;;
    status)   cmd_status ;;
    logout)   cmd_logout ;;
    teardown) cmd_logout
              MXFS_SCST_IMG=$IMG MXFS_SCST_DEV=$DEV MXFS_SCST_TGT=$TGT "$HERE/scripts/scst_setup.sh" teardown ;;
    *) echo "usage: $0 setup | login | status | logout | teardown" >&2; exit 2 ;;
esac
