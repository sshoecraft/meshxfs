#!/bin/bash
# pve_lvm_san_baseline.sh — what a two-host Proxmox pair runs on a shared iSCSI
# LUN without a cluster filesystem: LVM on the LUN, added to Proxmox as shared
# LVM storage (each guest disk a logical volume; Proxmox's cluster lock keeps
# the two hosts from changing the volume group at once).  This is the layout
# Proxmox's own iSCSI guide describes, set up on the LUN MXFS's SAN leg uses
# (scripts/pve_mxfs_san_disk.sh), so the same VM builds can be timed on both
# (scripts/pve_build_compare.sh legs `sanlvm` and `san`).
#
# Usage: scripts/pve_lvm_san_baseline.sh up|down|status
#   up    refuses while anything on SAN_DEV is mounted on either host; whatever
#         is on the LUN is lost (host A wipes it and creates the volume group)
#   down  storage removed, the volume group deactivated on both hosts and
#         removed with its PV label, so the next leg finds a blank LUN
# Env:
#   PVE_PAIR  "<addr> <addr>" (default "192.168.1.80 192.168.1.81"); host A
#             creates the volume group
#   SAN_DEV   the LUN's path on each host (default scripts/pve_caw_lun.sh's)
#   VG/STORE  volume group and Proxmox storage name (default sanvg, sanlvm)
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
read -r -a PAIR <<<"${PVE_PAIR:-192.168.1.80 192.168.1.81}"
SAN_DEV=${SAN_DEV:-/dev/disk/by-path/ip-192.168.1.166:3260-iscsi-iqn.2026-05.local.mxfs:pve-caw-01-lun-0}
VG=${VG:-sanvg}; STORE=${STORE:-sanlvm}

on() {  # <host> <cmd> [timeout]
    timeout "${3:-120}" "$SSHP" "$1" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^$'
    return "${PIPESTATUS[0]}"
}

up() {
    local h
    for h in "${PAIR[@]}"; do
        on "$h" "d=\$(readlink -f $SAN_DEV)
            [ -b \"\$d\" ] || { echo 'REFUSE: no $SAN_DEV'; exit 1; }
            lsblk -nro MOUNTPOINT \"\$d\" | grep -q . && { echo \"REFUSE: something on \$d is mounted\"; exit 1; }
            echo \"PREP_OK \$(hostname) \$d\"" 60 | sed "s/^/$h: /"
        [ "${PIPESTATUS[0]}" = 0 ] || exit 1
    done
    on "${PAIR[0]}" "vgs $VG >/dev/null 2>&1 || { wipefs -a -q $SAN_DEV && pvcreate -q \$(readlink -f $SAN_DEV) && vgcreate -q $VG \$(readlink -f $SAN_DEV); }; vgs $VG" 120 || exit 1
    on "${PAIR[1]}" "pvscan --cache >/dev/null 2>&1; vgs $VG" 60 || exit 1
    on "${PAIR[0]}" "pvesm status --storage $STORE >/dev/null 2>&1 || pvesm add lvm $STORE --vgname $VG --shared 1 --content images; pvesm status --storage $STORE" 60
}

down() {
    local h
    on "${PAIR[0]}" "pvesm status --storage $STORE >/dev/null 2>&1 && pvesm remove $STORE; echo storage $STORE removed" 60
    for h in "${PAIR[@]:1}" "${PAIR[0]}"; do
        on "$h" "vgchange -an $VG >/dev/null 2>&1; echo \"\$(hostname): $VG active LVs \$(lvs --noheadings -o lv_active $VG 2>/dev/null | grep -c active)\"" 60
    done
    on "${PAIR[0]}" "if vgs $VG >/dev/null 2>&1; then vgremove -f -q $VG >/dev/null && pvremove -q \$(readlink -f $SAN_DEV) >/dev/null; fi; echo \"vg removed: \$(vgs $VG >/dev/null 2>&1 && echo no || echo yes)\"" 60
    on "${PAIR[1]}" "pvscan --cache >/dev/null 2>&1; true" 60
}

status() {
    local h
    for h in "${PAIR[@]}"; do
        on "$h" "echo \"\$(hostname) vg=\$(vgs --noheadings -o vg_name,vg_size,vg_free $VG 2>&1 | tr -s ' ')\"" 30
    done
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    status) status ;;
    *) echo "usage: scripts/pve_lvm_san_baseline.sh up|down|status"; exit 2 ;;
esac
