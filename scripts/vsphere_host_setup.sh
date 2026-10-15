#!/bin/bash
#
# vsphere_host_setup.sh — give a (re)built nested ESXi host everything the
# MXFS vSphere lab expects of a host, the way esxhost1 is set up
#
# Usage: scripts/vsphere_host_setup.sh <host>      (esxhost1 | esxhost2)
#
# Through vCenter with govc (scripts/vsphere_env.sh), idempotent:
#   - vSwitch1, MTU 9000, uplink vmnic1, port group "192.168.120.0:24": the
#     lab network the test guests sit on (clyde's DHCP, SCST portal, /src).
#     vmnic1 is the host VM's second NIC, which Workstation bridges onto br0
#     (ethernet1 on vmnet2/vmnet3 -> clyde interface esx1/esx2); a host VM
#     without that NIC has no vmnic1 and the script stops.
#   - vMotion enabled on vmk0, so guests can be moved between the hosts.
#   - NFS datastores from clyde, read-write: vms (192.168.120.1:/home/steve/vms/vsphere)
#     and iso (192.168.120.1:/data/media/cdimages/os).  govc mounts NFS
#     read-only unless told otherwise.
#   - the software iSCSI adapter, then scripts/vsphere_lun.sh setup and
#     datastore for every host named in ESX_HOSTS, so this host's initiator is
#     admitted to the shared LUN and mounts the mxfs-shared VMFS datastore.
#   - out of maintenance mode.
# Ends with VSPHERE_HOST_OK <host> or exits non-zero naming the step.
#
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:?usage: $0 <host>}"
ESX_PATH=${ESX_PATH:-/lab/host/lab}
H="$ESX_PATH/$HOST.localdomain"
LABNET="192.168.120.0:24"

die() { echo "vsphere_host_setup: $HOST: $*" >&2; exit 1; }
. "$HERE/scripts/vsphere_env.sh" lab || die "no vCenter credentials"
esx() { timeout 60 govc host.esxcli -host "$H" "$@"; }

[ "$(timeout 30 govc object.collect -s "$H" runtime.connectionState 2>/dev/null)" = connected ] \
    || die "not connected to vCenter"

# lab network
esx network nic list 2>/dev/null | grep -q '^vmnic1 ' \
    || die "no vmnic1: the host VM needs ethernet1 on its vmnet bridged to br0"
if ! esx network vswitch standard list 2>/dev/null | grep -q 'Name: *vSwitch1$'; then
    esx network vswitch standard add -v vSwitch1 >/dev/null || die "add vSwitch1"
fi
esx network vswitch standard set -v vSwitch1 -m 9000 >/dev/null || die "vSwitch1 MTU"
esx network vswitch standard list -v vSwitch1 2>/dev/null | grep -q 'Uplinks: *vmnic1' \
    || esx network vswitch standard uplink add -v vSwitch1 -u vmnic1 >/dev/null || die "uplink vmnic1"
esx network vswitch standard portgroup list 2>/dev/null | grep -q "^$LABNET " \
    || esx network vswitch standard portgroup add -v vSwitch1 -p "$LABNET" >/dev/null || die "port group $LABNET"
# The same policies as esxhost1: vmnic1 ACTIVE (an uplink added to an existing
# switch lands as standby), forged transmits and MAC changes allowed on the
# switch, and promiscuous/forged/MAC allowed on the port group.  vMotion
# refuses to move a guest between port groups whose policies differ.
esx network vswitch standard policy failover set -v vSwitch1 -a vmnic1 >/dev/null || die "vmnic1 active"
esx network vswitch standard policy security set -v vSwitch1 -f true -m true -p false >/dev/null || die "vSwitch1 security"
esx network vswitch standard portgroup policy security set -p "$LABNET" -f true -m true -o true >/dev/null || die "$LABNET security"
echo "network: vSwitch1 mtu 9000 uplink vmnic1 (active), port group $LABNET (promiscuous, forged, MAC change allowed)"

# vMotion on vmk0
esx network ip interface tag get -i vmk0 2>/dev/null | grep -q VMotion \
    || esx network ip interface tag add -i vmk0 -t VMotion >/dev/null || die "vMotion tag on vmk0"
echo "vmk0: $(esx network ip interface tag get -i vmk0 2>/dev/null | sed 's/^ *Tags: *//')"

# NFS datastores from clyde
nfs_ds() {  # name path
    if esx storage nfs list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; then
        esx storage nfs list 2>/dev/null | awk -v n="$1" '$1 == n && $5 == "true" {f=1} END {exit !f}' \
            || die "datastore $1 is mounted but not accessible"
    else
        timeout 120 govc datastore.create -type nfs -mode readWrite -name "$1" \
            -remote-host 192.168.120.1 -remote-path "$2" "$H" >/dev/null || die "mount NFS datastore $1"
    fi
}
nfs_ds vms /home/steve/vms/vsphere
nfs_ds iso /data/media/cdimages/os
echo "nfs: $(esx storage nfs list 2>/dev/null | awk 'NR > 2 {printf "%s(accessible=%s) ", $1, $5}')"

# software iSCSI, then the shared LUN on every lab host
esx iscsi software get 2>/dev/null | grep -qi true || esx iscsi software set -e true >/dev/null || die "enable software iSCSI"
hba=$(esx iscsi adapter list 2>/dev/null | awk '$2 == "iscsi_vmk" {print $1; exit}')
[ -n "$hba" ] || die "no software iSCSI adapter after enabling it"
[ "$hba" = "${HBA:-vmhba65}" ] || die "software iSCSI adapter is $hba, scripts/vsphere_lun.sh expects ${HBA:-vmhba65} (set HBA=$hba)"
ESX_HOSTS="${ESX_HOSTS:-esxhost1 esxhost2}" "$HERE/scripts/vsphere_lun.sh" setup || die "shared LUN setup"
ESX_HOSTS="${ESX_HOSTS:-esxhost1 esxhost2}" "$HERE/scripts/vsphere_lun.sh" datastore || die "mxfs-shared datastore"

if [ "$(timeout 30 govc object.collect -s "$H" runtime.inMaintenanceMode 2>/dev/null)" = true ]; then
    timeout 300 govc host.maintenance.exit "$H" >/dev/null || die "exit maintenance mode"
fi
echo "VSPHERE_HOST_OK $HOST"
