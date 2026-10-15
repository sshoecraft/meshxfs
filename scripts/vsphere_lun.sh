#!/bin/bash
# vsphere_lun.sh — one iSCSI LUN from clyde's SCST target, shared by the nested
# ESXi hosts (esxhost1, esxhost2) as a VMFS6 datastore: the storage under the
# VMware shared-disk tests (multi-writer VMDK, clustered VMDK, physical RDM).
#
# Kept out of the rig's LUN pool (tools/lun_pool.sh) for the same reason as
# scripts/pve_caw_lun.sh: pool LUNs are formatted by whichever run borrows
# them, and pool `alloc` drives a Linux initiator over ssh, which an ESXi host
# is not.  The image lives outside the pool directory, so the pool never sees it.
#
#   IMG (fully allocated, fixed size) -> SCST vdisk_fileio device DEV
#     -> iSCSI target TGT on PORTAL
#     -> LUN 0 in ini_group `esx`, which holds the ESXi hosts' initiator names
#        and nobody else's.
#
# Each host gets a STATIC target for TGT on its software iSCSI adapter, never
# a SendTargets entry: dynamic discovery would log the host in to every pool
# target on the portal.  The ESXi side is driven through vCenter with govc
# (scripts/vsphere_env.sh), so no password reaches a command line.
#
# SCST objects are runtime-only: after a clyde restart run `setup` again (it
# reuses the image and is idempotent).
#
# Usage: scripts/vsphere_lun.sh setup | datastore | status | teardown
#   setup      create the image if missing, register it with SCST, add the
#              static target on each host and rescan; every host must see one
#              device with the same id (SCST reports an eui. id, not naa.)
#   datastore  format the device as VMFS6 datastore DS from the first host and
#              rescan the rest (refuses if DS already exists)
#   status     SCST side, each host's sessions, the device and the datastore
#   teardown   remove the datastore, each host's static target, then the SCST
#              target and device (image kept)
# Env: IMG (/home/steve/disks/vsphere/vsphere01.img)  SIZE (100G)  DEV (vsphere01)
#      TGT (iqn.2026-05.local.mxfs:vsphere-01)  PORTAL (192.168.1.166)
#      ESX_HOSTS ("esxhost1 esxhost2")  ESX_PATH (/lab/host/lab)  HBA (vmhba65)
#      DS (mxfs-shared)
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
IMG=${IMG:-/home/steve/disks/vsphere/vsphere01.img}
SIZE=${SIZE:-100G}
DEV=${DEV:-vsphere01}
TGT=${TGT:-iqn.2026-05.local.mxfs:vsphere-01}
PORTAL=${PORTAL:-192.168.1.166}
read -r -a HOSTS <<<"${ESX_HOSTS:-esxhost1 esxhost2}"
ESX_PATH=${ESX_PATH:-/lab/host/lab}
HBA=${HBA:-vmhba65}
DS=${DS:-mxfs-shared}
T=/sys/kernel/scst_tgt/targets/iscsi

die() { echo "vsphere_lun: $*" >&2; exit 1; }

. "$HERE/scripts/vsphere_env.sh" lab || die "no vCenter credentials"

hpath() { echo "$ESX_PATH/$1.localdomain"; }
esx() { local h=$1; shift; timeout 60 govc host.esxcli -host "$(hpath "$h")" "$@"; }

initiator_of() { esx "$1" iscsi adapter get -A "$HBA" 2>/dev/null | sed -n 's/^Name: *//p' | grep '^iqn\.' | head -1; }

# The device id behind TGT on host <h>, from its path list.
device_of() {
    timeout 60 govc host.esxcli -json -host "$(hpath "$1")" storage core path list 2>/dev/null |
        python3 -c '
import json, sys
tgt = sys.argv[1]
for p in json.load(sys.stdin).get("values") or []:
    if tgt in " ".join(p.get("TargetIdentifier", [])) and p.get("State", [""])[0] == "active":
        print(p["Device"][0]); break
' "$TGT"
}

# Rescan through vCenter: an esxcli rescan on the host leaves vCenter's view of
# the host's datastores stale, and govc reads that view.
rescan() {
    timeout 120 govc host.storage.info -host "$(hpath "$1")" -rescan -rescan-vmfs -refresh >/dev/null 2>&1
}

# 0 iff host <h> has datastore DS mounted and accessible, read from the
# datastore's own host list (datastore.info has no per-host filter).
ds_mounted_on() {
    local moref
    # `govc ls -i <host>` lists the host's children; find names the host itself
    moref=$(timeout 30 govc find -i "$ESX_PATH" -type h -name "$1.localdomain" 2>/dev/null | sed -n 's/^HostSystem://p' | head -1)
    [ -n "$moref" ] || return 1
    timeout 30 govc datastore.info -json "$DS" 2>/dev/null | python3 -c '
import json, sys
for d in json.load(sys.stdin).get("datastores") or []:
    for m in d.get("host") or []:
        if m["key"]["value"] == sys.argv[1]:
            i = m.get("mountInfo") or {}
            sys.exit(0 if i.get("mounted") and i.get("accessible") else 1)
sys.exit(1)
' "$moref"
}

cmd_setup() {
    local bytes h ini g d naa="" bad=""
    bytes=$(numfmt --from=iec "$SIZE") || die "bad size $SIZE"
    if [ ! -e "$IMG" ]; then
        mkdir -p "$(dirname "$IMG")" || die "cannot create $(dirname "$IMG")"
        fallocate -l "$bytes" "$IMG" || die "fallocate $SIZE $IMG failed"
        [ "$(( $(stat -c %b "$IMG") * $(stat -c %B "$IMG") ))" -ge "$bytes" ] \
            || die "$IMG is not fully allocated after fallocate"
        echo "created $IMG ($SIZE)"
    fi
    MXFS_SCST_IMG=$IMG MXFS_SCST_DEV=$DEV MXFS_SCST_TGT=$TGT MXFS_SCST_PORTAL_IP=$PORTAL \
        timeout 60 "$HERE/scripts/scst_setup.sh" setup | grep -E 'SCST_SETUP_OK' >/dev/null \
        || die "scst_setup.sh setup failed for $TGT"
    g=$(sudo cat "/sys/kernel/scst_tgt/devices/$DEV/filename" 2>/dev/null | head -1)
    [ "$g" = "$IMG" ] || die "SCST device $DEV holds '$g', not $IMG"
    g=$T/$TGT/ini_groups
    [ -d "$g/esx" ] || echo "create esx" | sudo tee "$g/mgmt" >/dev/null || die "cannot create ini_group esx"
    [ -d "$g/esx/luns/0" ] || echo "add $DEV 0" | sudo tee "$g/esx/luns/mgmt" >/dev/null || die "cannot map LUN 0 in ini_group esx"
    if [ -d "$T/$TGT/luns/0" ]; then
        echo "del 0" | sudo tee "$T/$TGT/luns/mgmt" >/dev/null || die "cannot remove the default LUN 0"
    fi
    for h in "${HOSTS[@]}"; do
        ini=$(initiator_of "$h")
        [ -n "$ini" ] || die "no initiator name from $h ($HBA)"
        [ -e "$g/esx/initiators/$ini" ] || echo "add $ini" | sudo tee "$g/esx/initiators/mgmt" >/dev/null \
            || die "cannot add $h's initiator $ini"
    done
    echo "SCST: $TGT LUN 0 = $DEV ($IMG) on $PORTAL for: $(ls "$g/esx/initiators" | grep -v '^mgmt$' | tr '\n' ' ')"
    for h in "${HOSTS[@]}"; do
        if ! esx "$h" iscsi adapter discovery statictarget list -A "$HBA" 2>/dev/null | grep -q "$TGT"; then
            esx "$h" iscsi adapter discovery statictarget add -A "$HBA" -a "$PORTAL:3260" -n "$TGT" >/dev/null \
                || die "$h: cannot add static target $TGT"
        fi
        rescan "$h"
        d=""
        for i in 1 2 3 4 5; do d=$(device_of "$h"); [ -n "$d" ] && break; sleep 2; rescan "$h"; done
        echo "$h: ${d:-no device}"
        if [ -z "$d" ]; then bad="$bad $h(no device)"; continue; fi
        [ -z "$naa" ] && naa=$d
        [ "$d" = "$naa" ] || bad="$bad $h($d!=$naa)"
    done
    [ -z "$bad" ] || die "setup FAIL:$bad"
    echo "VSPHERE_LUN_OK target=$TGT device=$naa"
}

cmd_datastore() {
    local h naa
    naa=$(device_of "${HOSTS[0]}")
    [ -n "$naa" ] || die "${HOSTS[0]} sees no device on $TGT (run setup)"
    # An existing DS is reused only when it lives on this device; a rerun after
    # a host missed the rescan then just mounts it there.
    if timeout 30 govc datastore.info "$DS" >/dev/null 2>&1; then
        timeout 30 govc datastore.info -json "$DS" | grep -q "\"$naa\"" \
            || die "datastore $DS exists on a device other than $naa"
        echo "$DS already on $naa"
    else
        timeout 120 govc datastore.create -type vmfs -version 6 -name "$DS" -disk "$naa" "$(hpath "${HOSTS[0]}")" \
            || die "VMFS6 create on $naa failed"
    fi
    for h in "${HOSTS[@]:1}"; do rescan "$h"; done
    for h in "${HOSTS[@]}"; do
        ds_mounted_on "$h" && echo "$h: $DS mounted" || die "$h does not have $DS mounted after a rescan"
    done
    echo "VSPHERE_DS_OK name=$DS device=$naa"
}

cmd_status() {
    local h
    MXFS_SCST_IMG=$IMG MXFS_SCST_DEV=$DEV MXFS_SCST_TGT=$TGT "$HERE/scripts/scst_setup.sh" status | sed -n '/=== target/,/=== iscsi/p'
    echo "  initiators: $(ls "$T/$TGT/ini_groups/esx/initiators" 2>/dev/null | grep -v '^mgmt$' | tr '\n' ' ')"
    echo "  sessions: $(sudo ls "$T/$TGT/sessions" 2>/dev/null | grep -v '^mgmt$' | tr '\n' ' ')"
    for h in "${HOSTS[@]}"; do
        echo "$h: device=$(device_of "$h") $DS=$(ds_mounted_on "$h" && echo mounted || echo absent)"
    done
    timeout 30 govc datastore.info "$DS" 2>&1 | grep -E 'Name:|Type:|Capacity:|Free:'
}

cmd_teardown() {
    local h
    if timeout 30 govc datastore.info "$DS" >/dev/null 2>&1; then
        timeout 120 govc datastore.remove -ds "$DS" "$(hpath "${HOSTS[0]}")" || die "cannot remove datastore $DS"
    fi
    for h in "${HOSTS[@]}"; do
        esx "$h" iscsi adapter discovery statictarget remove -A "$HBA" -a "$PORTAL:3260" -n "$TGT" >/dev/null 2>&1
        rescan "$h"
        echo "$h: static target removed"
    done
    MXFS_SCST_IMG=$IMG MXFS_SCST_DEV=$DEV MXFS_SCST_TGT=$TGT "$HERE/scripts/scst_setup.sh" teardown
}

case "${1:-}" in
    setup)     cmd_setup ;;
    datastore) cmd_datastore ;;
    status)    cmd_status ;;
    teardown)  cmd_teardown ;;
    *) echo "usage: $0 setup | datastore | status | teardown" >&2; exit 2 ;;
esac
