#!/bin/bash
#
# vsphere_freeze_catch.sh — take a memory snapshot of a vSphere guest WHILE it
# is frozen.
#
# Usage: tools/vsphere_freeze_catch.sh <vm> <max_seconds> [snapshot-name]
#
# A guest that stops scheduling work (a vCPU stranded in idle, its timers
# never firing) shows it first in the hypervisor's own log: VMware Tools'
# heartbeat from the guest stops and vmware.log records "Tools heartbeat
# timeout" about 20 s in.  That line comes from the VMX, outside the guest,
# so it is reliable exactly when nothing inside the guest is.  This watches
# the VM's vmware.log (on the `vms` datastore) every 10 s and, on the first
# NEW timeout line, takes a memory snapshot (vmem + vmsn in the VM folder) so
# the frozen state can be read with vmss2core + tools/vmss_cpu_state.py.
#
# Exits 0 after the snapshot, 1 if no freeze began within max_seconds, 2 on a
# usage or govc error.  Nothing is reset or powered; the snapshot must be
# removed afterwards with `govc snapshot.remove -vm <vm> <name>`.

set -uo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 <vm> <max_seconds> [snapshot-name]" >&2
    exit 2
fi
vm=$1; max=$2; name=${3:-freeze-$(date -u +%H%M%S)}

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$here/../scripts/vsphere_env.sh" lab

last_timeout() {
    timeout 30 govc datastore.tail -ds vms -n 80 "$vm/vmware.log" 2>/dev/null |
        grep 'Tools heartbeat timeout' | tail -1
}

base=$(last_timeout)
echo "$(date -u +%T) watching $vm (last timeout so far: ${base:-none})"
deadline=$(( $(date +%s) + max ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 10
    cur=$(last_timeout)
    if [ -n "$cur" ] && [ "$cur" != "$base" ]; then
        echo "$(date -u +%T) freeze detected: $cur"
        t0=$(date +%s)
        if timeout 180 govc snapshot.create -vm "$vm" -m=true -q=false "$name"; then
            echo "$(date -u +%T) snapshot $name taken in $(( $(date +%s) - t0 )) s"
            exit 0
        fi
        echo "$(date -u +%T) snapshot $name FAILED" >&2
        exit 2
    fi
done
echo "$(date -u +%T) no freeze began within ${max}s"
exit 1
