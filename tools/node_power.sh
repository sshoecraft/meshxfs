#!/bin/bash
#
# node_power.sh — kill a test node's VM outright, or start it, on whichever
# hypervisor hosts it.
#
# Usage: tools/node_power.sh destroy|start <node>
#
#   destroy  the VM stops at once with no shutdown, no unmount and no message
#            to its peers — the "node died" every death test needs.
#   start    the VM is powered on again (returns once the hypervisor has
#            accepted the power-on; the guest is still booting).
#
# The qemu rig's nodes (test1..testN) are libvirt domains on this host and go
# through `virsh destroy|start`.  The vSphere guests (vstest1, vstest2) are not
# libvirt domains: `virsh destroy vstest2` exits 1 and the node keeps running,
# so a death test that called virsh directly waited out its whole detection
# window for a death that never happened (crash_audit on vSphere, 2026-10-13:
# 'virsh destroy vstest2 rc=1', then no replay verdict within 150 s).  A node
# that libvirt does not know is looked up in vCenter and killed with a forced
# power-off, which is the vSphere equivalent: the VM stops executing at once.
#
# A node neither hypervisor knows is an error (exit 2), never a silent no-op.
# Exit status otherwise is the hypervisor command's.

set -uo pipefail

if [ $# -ne 2 ] || { [ "$1" != destroy ] && [ "$1" != start ]; }; then
    echo "usage: $0 destroy|start <node>" >&2
    exit 2
fi
op=$1; node=${2%%.*}
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

VIRSH="sudo virsh -c qemu:///system"
if timeout 20 $VIRSH dominfo "$node" >/dev/null 2>&1; then
    exec timeout 60 $VIRSH "$op" "$node"
fi

# Sourced scripts see this script's positional parameters; name the entry.
. "$here/../scripts/vsphere_env.sh" lab || exit 2
vm=$(timeout 30 govc find / -type m -name "$node" 2>/dev/null | head -1)
if [ -z "$vm" ]; then
    echo "node_power: $node is neither a libvirt domain here nor a vSphere VM" >&2
    exit 2
fi
case $op in
    destroy) exec timeout 60 govc vm.power -off -force "$vm" ;;
    start)   exec timeout 120 govc vm.power -on "$vm" ;;
esac
