#!/bin/bash
#
# vsphere_cvmdk_datastore.sh — make a VMFS6 datastore on the disk both nested
# ESXi hosts share at the Workstation level (scripts/vsphere_esxhost_shared_disk.sh),
# and ask vCenter for Clustered VMDK support on it.
#
# Usage: scripts/vsphere_cvmdk_datastore.sh [<size-MB>] [<datastore>]
#   <size-MB>   the shared disk's size, which is how it is found among each
#               host's devices (default 30720)
#   <datastore> default mxfs-cvmdk
#
# Prints, per host, how ESXi classifies the device (local or shared, its
# VAAI/ATS status, its path's transport), creates the datastore from esxhost1
# if it does not exist, rescans esxhost2 and checks it mounts there too, then
# runs tools/vsphere_clustered_vmdk.py status and enable.
set -u
SIZE=${1:-30720}
DS=${2:-mxfs-cvmdk}
cd "$(dirname "$0")/.." || exit 1
. scripts/vsphere_env.sh lab >/dev/null 2>&1 || { echo "vsphere_env.sh lab failed" >&2; exit 1; }
export GOVC_INSECURE=1
PYVMOMI=${PYVMOMI:-/home/steve/.venvs/pyvmomi/bin/python3}
H1=/lab/host/lab/esxhost1.localdomain
H2=/lab/host/lab/esxhost2.localdomain

find_dev() {   # <host>: the device id whose size is SIZE MB and vendor VMware
    timeout 60 govc host.esxcli -json -host "$1" storage core device list | python3 -c '
import json, sys
for d in json.load(sys.stdin).get("values") or []:
    if str(d.get("Size", [""])[0]) == sys.argv[1] and "VMware" in (d.get("Vendor") or [""])[0]:
        print(d["Device"][0]); break
' "$SIZE"
}

for h in $H1 $H2; do
    timeout 120 govc host.storage.info -host "$h" -rescan >/dev/null 2>&1
    d=$(find_dev "$h")
    echo "== ${h##*/}: device=${d:-<none of $SIZE MB>}"
    [ -n "$d" ] || continue
    timeout 60 govc host.esxcli -host "$h" storage core device list -d "$d" | grep -E 'Display Name|Is Local|Is SSD|Is Shared Clusterwide|Is Perennially|SCSI Level|Status|Vendor|Model' | sed 's/^/  /'
    timeout 60 govc host.esxcli -host "$h" storage core device vaai status get -d "$d" | grep -E 'ATS|Zero|Clone' | sed 's/^/  /'
    timeout 60 govc host.esxcli -host "$h" storage core path list -d "$d" | grep -E 'Transport|Adapter Identifier|Runtime Name|Target Identifier' | sed 's/^/  /'
done

d1=$(find_dev $H1)
[ -n "$d1" ] || { echo "esxhost1 does not see the shared disk" >&2; exit 1; }
if ! timeout 30 govc datastore.info "$DS" >/dev/null 2>&1; then
    timeout 300 govc datastore.create -type vmfs -name "$DS" -disk "$d1" -version 6 "$H1" || { echo "datastore create on $d1 failed" >&2; exit 1; }
fi
timeout 120 govc host.storage.info -host $H2 -rescan >/dev/null 2>&1
timeout 60 govc host.esxcli -host $H2 storage filesystem rescan >/dev/null 2>&1
echo "== datastore $DS mounts:"
for h in $H1 $H2; do
    echo "  ${h##*/}: $(timeout 60 govc host.esxcli -host "$h" storage filesystem list | grep -w "$DS" | tr -s ' ')"
done
timeout 60 "$PYVMOMI" tools/vsphere_clustered_vmdk.py status "$DS"
timeout 120 "$PYVMOMI" tools/vsphere_clustered_vmdk.py enable "$DS"; echo "enable rc=$?"
timeout 60 "$PYVMOMI" tools/vsphere_clustered_vmdk.py status "$DS"
