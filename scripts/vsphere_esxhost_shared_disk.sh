#!/bin/bash
#
# vsphere_esxhost_shared_disk.sh — attach one Workstation disk file to both
# nested ESXi host VMs, so each ESXi sees it as a local disk on its own
# controller and a VMFS datastore on it is reachable from both hosts.
#
# Usage: scripts/vsphere_esxhost_shared_disk.sh <disk.vmdk> [<sharedBus>]
#   <sharedBus>: virtual (default) | none
#
# Why: the lab's VMFS datastore for shared guest disks sits on an SCST iSCSI
# LUN, and vCenter refuses Clustered VMDK support on it (NotSupported), so a
# clustered VMDK cannot be measured there.  A disk the ESXi hosts see as
# directly attached is a different device class, and whether ESXi offers
# Clustered VMDK on it is what this sets up to measure.
#
# The disk goes on its own controller, scsi1 (pvscsi), in each host's .vmx:
#   scsi1:0.fileName = <disk>, mode independent-persistent
#   scsi1.sharedBus  = <sharedBus>   Workstation's shared-bus setting (lets two
#                                    VMs open the disk and arbitrates SCSI
#                                    reservations between them); "none" omits it
#   disk.locking = FALSE             two VMX processes open one file
#   diskLib.dataCacheMaxSize = 0     no VMX-side data cache that the other VMX
#                                    could not see
#
# A .vmx can only be edited with its VM off (Workstation rewrites it at
# power-off), so each host is taken down in turn: its guests are shut down
# cleanly (never a hard power-off: a guest may have a shared LUN mounted),
# the host enters maintenance mode and shuts down, the .vmx is edited, the
# host is started and leaves maintenance mode.  Lines already present are
# replaced, not duplicated.  vCenter (its own Workstation VM) stays up.
#
set -u
DISK="${1:?usage: $0 <disk.vmdk> [virtual|none]}"
BUS="${2:-virtual}"
[ -f "$DISK" ] || { echo "no such disk: $DISK" >&2; exit 2; }
case "$BUS" in virtual|none) ;; *) echo "sharedBus must be virtual or none" >&2; exit 2 ;; esac
cd "$(dirname "$0")/.." || exit 1
. scripts/vsphere_env.sh lab >/dev/null 2>&1 || { echo "vsphere_env.sh lab failed" >&2; exit 1; }
export GOVC_INSECURE=1

HOSTS="esxhost1:/home/steve/vms/vmware/esxhost/esxhost.vmx esxhost2:/home/steve/vms/vmware/esxhost2/esxhost2.vmx"

host_path() { timeout 30 govc find /lab/host -type h -name "$1.localdomain" | head -1; }
power() { timeout 30 govc vm.info -json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtualMachines"][0]["runtime"]["powerState"])'; }
running() { vmrun -T ws list 2>/dev/null | grep -qxF "$1"; }

set_vmx() {   # set_vmx <vmx> <key> <value>: replace or append one line
    local vmx=$1 key=$2 val=$3
    python3 - "$vmx" "$key" "$val" <<'EOF'
import sys
vmx, key, val = sys.argv[1:]
lines = open(vmx).read().splitlines()
out = [l for l in lines if l.split("=", 1)[0].strip().lower() != key.lower()]
out.append('%s = "%s"' % (key, val))
open(vmx, "w").write("\n".join(out) + "\n")
EOF
}
del_vmx() {
    python3 - "$1" "$2" <<'EOF'
import sys
vmx, key = sys.argv[1:]
lines = open(vmx).read().splitlines()
open(vmx, "w").write("\n".join(l for l in lines if l.split("=", 1)[0].strip().lower() != key.lower()) + "\n")
EOF
}

for hv in $HOSTS; do
    h=${hv%%:*}; vmx=${hv#*:}
    hp=$(host_path "$h"); [ -n "$hp" ] || { echo "$h: not found in vCenter" >&2; exit 1; }
    echo "== $h ($hp) $vmx"
    hid=$(timeout 30 govc find -i /lab/host -type h -name "$h.localdomain" | head -1 | sed 's/.*://')
    [ -n "$hid" ] || { echo "$h: no host moref" >&2; exit 1; }
    # its powered-on guests, shut down cleanly
    for vm in $(timeout 30 govc find /lab/vm -type m 2>/dev/null); do
        case "$vm" in */vCLS/*) continue ;; esac   # vSphere powers these off itself for maintenance
        [ "$(timeout 30 govc vm.info -json "$vm" | python3 -c 'import json,sys; r=json.load(sys.stdin)["virtualMachines"][0]["runtime"]; print(r["host"]["value"], r["powerState"])')" = "$hid poweredOn" ] || continue
        echo "  guest $vm: shutting down"
        timeout 30 govc vm.power -s "$vm" >/dev/null 2>&1 || echo "  guest $vm: shutdown not accepted; waiting"
        for i in $(seq 1 36); do [ "$(power "$vm")" = poweredOff ] && break; sleep 5; done
        [ "$(power "$vm")" = poweredOff ] || { echo "  guest $vm did not power off; stopping" >&2; exit 1; }
    done
    boot0=$(timeout 20 govc object.collect -s "$hp" runtime.bootTime)
    timeout 300 govc host.maintenance.enter "$hp" >/dev/null 2>&1 || { echo "$h: maintenance enter failed" >&2; exit 1; }
    timeout 60 govc host.shutdown -f "$hp" >/dev/null 2>&1 || { echo "$h: shutdown refused" >&2; exit 1; }
    for i in $(seq 1 60); do running "$vmx" || break; sleep 5; done
    running "$vmx" && { echo "$h: Workstation VM still running 300 s after shutdown" >&2; exit 1; }
    set_vmx "$vmx" scsi1.present TRUE
    set_vmx "$vmx" scsi1.virtualDev pvscsi
    if [ "$BUS" = none ]; then del_vmx "$vmx" scsi1.sharedBus; else set_vmx "$vmx" scsi1.sharedBus "$BUS"; fi
    set_vmx "$vmx" scsi1:0.present TRUE
    set_vmx "$vmx" scsi1:0.fileName "$DISK"
    set_vmx "$vmx" scsi1:0.mode independent-persistent
    set_vmx "$vmx" disk.locking FALSE
    set_vmx "$vmx" diskLib.dataCacheMaxSize 0
    grep -E '^scsi1|^disk\.locking|^diskLib' "$vmx" | sed 's/^/  vmx: /'
    timeout 120 vmrun -T ws start "$vmx" nogui || { echo "$h: vmrun start failed" >&2; exit 1; }
    # back in vCenter: connected under a NEW boot (vCenter keeps reporting the
    # old connection for a while after the restart), then out of maintenance
    ok=0; for i in $(seq 1 60); do
        [ "$(timeout 20 govc object.collect -s "$hp" runtime.connectionState 2>/dev/null)" = connected ] &&
            [ "$(timeout 20 govc object.collect -s "$hp" runtime.bootTime 2>/dev/null)" != "$boot0" ] && { ok=1; break; }; sleep 10
    done
    [ $ok = 1 ] || { echo "$h: not connected 600 s after start" >&2; exit 1; }
    timeout 300 govc host.maintenance.exit "$hp" >/dev/null 2>&1 || { echo "$h: maintenance exit failed" >&2; exit 1; }
    echo "$h: up, connected, out of maintenance"
done
