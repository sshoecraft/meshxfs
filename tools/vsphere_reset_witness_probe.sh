#!/bin/bash
# vsphere_reset_witness_probe.sh — is a vSphere guest's successful device reset
# on a physical-mode RDM evidence that the ARRAY answered a LOGICAL UNIT RESET?
#
# Usage: tools/vsphere_reset_witness_probe.sh <guest> <esxi-iscsi-ip> <dev> [<drop-s>]
#   e.g. tools/vsphere_reset_witness_probe.sh vstest1 192.168.1.251 /dev/disk/by-id/scsi-26661313331363962
#
# Measured before: `sg_reset -d` (and -b) in the guest reaches clyde's SCST as
# `TM fn LUN_RESET` from the ESXi host's initiator, finished status 0.  That
# shows the reset is forwarded; it does not show the guest's rc=0 depends on
# the array's response.  This makes the array unreachable from that ESXi host
# (clyde drops TCP 3260 to and from <esxi-iscsi-ip>, nothing else: the host's
# NFS datastores and the guests' own iSCSI logins are untouched), issues the
# guest's device reset, and records its rc and wall time.  rc=0 with no TMF
# reaching SCST means the guest's success is ESXi's, not the array's.
#
# The drop is bounded: the rules are removed after <drop-s> (default 90) by
# a watchdog even if this script is killed, and by the exit trap otherwise.
set -u
G=${1:?guest}; IP=${2:?esxi iscsi ip}; DEV=${3:?device}; DROP=${4:-90}
cd "$(dirname "$0")/.." || exit 1
R_IN="INPUT -s $IP -p tcp --dport 3260 -j DROP"
R_OUT="OUTPUT -d $IP -p tcp --sport 3260 -j DROP"
undo() { sudo -n iptables -D $R_IN 2>/dev/null; sudo -n iptables -D $R_OUT 2>/dev/null; }
trap undo EXIT
m="mxfs-resetwit-$(date +%s)"
sudo -n sh -c "echo $m > /dev/kmsg"
sudo -n iptables -I $R_IN && sudo -n iptables -I $R_OUT || { echo "iptables insert failed" >&2; exit 1; }
( sleep "$DROP"; sudo -n iptables -D $R_IN 2>/dev/null; sudo -n iptables -D $R_OUT 2>/dev/null ) >/dev/null 2>&1 &
echo "drop on $IP:3260 from $(date +%T) for at most ${DROP}s"
sleep 20   # let the ESXi session see the loss before the reset goes out
t0=$(date +%s.%N)
out=$(timeout 200 tools/mxfs_sshpass.sh "$G.vm.localdomain" "s=\$(date +%s.%N); sg_reset -v -d $DEV 2>&1; r=\$?; e=\$(date +%s.%N); echo \"rc=\$r guest_wall=\$(echo \"\$e - \$s\" | bc)\"; dmesg | tail -6" 2>&1 | grep -av -i '^warning\|unauthori\|disconnect')
echo "$out"
echo "probe wall $(echo "$(date +%s.%N) - $t0" | bc)s; drop removed at $(undo; date +%T)"
sleep 30
echo "== SCST log after the marker:"
sudo -n dmesg | sed -n "/$m/,\$p" | grep -a -E "TM fn|$IP|esxhost|reset|session|conn" | cut -c1-220 | head -30
