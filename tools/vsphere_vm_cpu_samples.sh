#!/bin/bash
#
# vsphere_vm_cpu_samples.sh — the hypervisor's own per-20 s CPU accounting for a
# vSphere guest, one row per interval.
#
# Usage: tools/vsphere_vm_cpu_samples.sh <vm> [samples] [from-HH:MM] [to-HH:MM]
#
# Prints, from vCenter's realtime statistics (20 s intervals, the last hour,
# summed over the VM's vCPUs, in ms per interval): run, ready, costop, wait and
# idle.  A guest that "froze" because the hypervisor stopped running it shows
# ready/costop climbing toward 20000 ms per vCPU; a guest that froze inside its
# own kernel shows run near zero with ready flat; a guest that is busy shows run
# high.  Timestamps are UTC; from/to narrow the rows printed.

set -uo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <vm> [samples] [from-HH:MM] [to-HH:MM]" >&2
    exit 2
fi
vm=$1; n=${2:-180}; from=${3:-00:00}; to=${4:-23:59}

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$here/../scripts/vsphere_env.sh" lab

path=$(timeout 30 govc find / -type m -name "$vm" | head -1)
if [ -z "$path" ]; then
    echo "vsphere_vm_cpu_samples: no VM named $vm" >&2
    exit 2
fi

timeout 90 govc metric.sample -json -n "$n" "$path" \
    cpu.run.summation cpu.ready.summation cpu.costop.summation \
    cpu.wait.summation cpu.idle.summation |
python3 -c '
import json, sys
frm, to = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)
rows = {}
cols = ["cpu.run.summation", "cpu.ready.summation", "cpu.costop.summation",
        "cpu.wait.summation", "cpu.idle.summation"]
for s in d.get("Sample") or d.get("sample") or []:
    info = s.get("SampleInfo") or s.get("sampleInfo") or []
    for v in s.get("Value") or s.get("value") or []:
        name = v.get("Name", v.get("name"))
        if v.get("Instance", v.get("instance")) not in ("", None):
            continue
        for t, x in zip(info, v.get("Value", v.get("value")) or []):
            ts = t.get("Timestamp", t.get("timestamp"))
            rows.setdefault(ts, {})[name] = x
print("%-22s %8s %8s %8s %8s %8s" % ("utc", "run", "ready", "costop", "wait", "idle"))
for ts in sorted(rows):
    hm = ts[11:16]
    if not (frm <= hm <= to):
        continue
    r = rows[ts]
    print("%-22s %8s %8s %8s %8s %8s" % ((ts[:19],) + tuple(r.get(c, "-") for c in cols)))
' "$from" "$to"
