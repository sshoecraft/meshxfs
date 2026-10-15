#!/bin/bash
# vsphere_poweroff_key_probe.sh — does ESXi drop a VM's SCSI-3 PR registration
# when the VM is powered off?
#
# Usage: tools/vsphere_poweroff_key_probe.sh <survivor> <victim> <dev>
#   e.g. tools/vsphere_poweroff_key_probe.sh vstest1 vstest2 /dev/disk/by-id/scsi-26661313331363962
#
# The death oracle hard-powers a guest off (tools/node_power.sh destroy) and the
# survivor then fences it with PREEMPT AND ABORT.  On the cross-host
# physical-mode RDM the survivor found the victim's key ALREADY absent at the
# fence, so it could prove nothing and refused the replay.  This measures
# whether the power-off itself removes the key: both guests register a raw key
# (no MXFS mounted), the survivor reads the registrations, the victim is
# powered off, the survivor reads them again at +2 s and +15 s, then the victim
# is powered back on and they are read once more.  Every read prints the
# PRgeneration, so a change made by anyone shows up even if the keys look the
# same.
#
# Unmounts /mnt/shared on both guests first (bounded); the guests are
# disposable and the next prep re-formats the LUN anyway.
set -u
S=${1:?survivor}; V=${2:?victim}; DEV=${3:?device}
cd "$(dirname "$0")/.." || exit 1
SSH=tools/mxfs_sshpass.sh
KS=0x5151; KV=0x5252
rs() { timeout "$1" $SSH "$2.vm.localdomain" "$3" 2>&1 | grep -av -i '^warning\|unauthori\|disconnect'; }
keys() { echo "--- $1: keys and reservation as $S sees them ---"; rs 20 "$S" "sg_persist -n -k $DEV; sg_persist -n -r $DEV"; }

for n in "$S" "$V"; do
    echo "umount $n: $(rs 60 "$n" "umount /mnt/shared 2>&1; echo rc=\$?" | tail -1)"
done
echo "register $S $KS: $(rs 20 "$S" "sg_persist -n --out --register-ignore --param-sark=$KS $DEV 2>&1; echo rc=\$?" | tail -1)"
echo "register $V $KV: $(rs 20 "$V" "sg_persist -n --out --register-ignore --param-sark=$KV $DEV 2>&1; echo rc=\$?" | tail -1)"
keys "both registered"
t0=$(date +%s)
echo "power off $V: $(tools/node_power.sh destroy "$V" 2>&1 | tail -1) at $(date -u +%T)"
sleep 2; keys "+$(( $(date +%s)-t0 ))s after power-off"
sleep 13; keys "+$(( $(date +%s)-t0 ))s after power-off"
echo "power on $V: $(tools/node_power.sh start "$V" 2>&1 | tail -1)"
up=0; for i in $(seq 1 40); do timeout 8 $SSH "$V.vm.localdomain" true >/dev/null 2>&1 && { up=1; break; }; sleep 3; done
echo "$V ssh up=$up after $(( $(date +%s)-t0 ))s"
keys "after $V power-on"
echo "unregister $S: $(rs 20 "$S" "sg_persist -n --out --register-ignore --param-sark=0 $DEV 2>&1; echo rc=\$?" | tail -1)"
[ "$up" = 1 ] && echo "unregister $V: $(rs 20 "$V" "sg_persist -n --out --register-ignore --param-sark=0 $DEV 2>&1; echo rc=\$?" | tail -1)"
keys "after cleanup"
