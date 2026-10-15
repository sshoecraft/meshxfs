#!/bin/bash
#
# vsphere_freeze_check.sh — list every guest freeze a vSphere VM's own VMX log
# recorded since a given time
#
# Usage: tools/vsphere_freeze_check.sh <since: UTC ISO, e.g. 2026-10-13T07:00> <vm> [<vm> ...]
#
# VMware Tools heartbeats from inside the guest to the VMX; when the guest
# stops making progress the VMX logs "Tools: Tools heartbeat timeout." about
# 20 s in, and "Tools: Running status rpc handler: 0 => 1." when it comes back.
# Those lines are written outside the guest, so they are trustworthy exactly
# when the guest's own logs are not.  A board run on vSphere is only evidence
# about MeshXFS if neither guest froze during it: a guest whose clock stops
# for minutes is fenced by its peer and self-fences on thaw, correctly, and
# every row in flight fails with it.
#
# Reads every vmware*.log in the VM's folder on the `vms` datastore (the VMX
# rotates them at each power-on).  Prints one line per timeout or recovery
# at or after <since>, then FREEZES <vm> <n>; exit 0 when no VM froze, 1 when
# any did, 2 on a usage or govc error.

set -uo pipefail
if [ $# -lt 2 ]; then
    echo "usage: $0 <since-UTC-ISO> <vm> [<vm> ...]" >&2
    exit 2
fi
since=$1; shift

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$here/../scripts/vsphere_env.sh" lab
export GOVC_INSECURE=1

rc=0
for vm in "$@"; do
    logs=$(timeout 30 govc datastore.ls -ds vms "$vm" 2>/dev/null | grep -E '^vmware(-[0-9]+)?\.log$')
    [ -n "$logs" ] || { echo "$vm: no vmware*.log on datastore vms (govc failed?)" >&2; exit 2; }
    lines=$(for f in $logs; do
                timeout 60 govc datastore.download -ds vms "$vm/$f" - 2>/dev/null |
                    grep -a -E 'Tools heartbeat timeout|Running status rpc handler: 0 => 1'
            done | sort | awk -v s="$since" '$1 >= s')
    [ -n "$lines" ] && echo "$lines" | sed "s/^/$vm: /" | cut -c1-140
    n=$(printf '%s\n' "$lines" | grep -c 'Tools heartbeat timeout')
    echo "FREEZES $vm $n"
    [ "$n" = 0 ] || rc=1
done
exit $rc
