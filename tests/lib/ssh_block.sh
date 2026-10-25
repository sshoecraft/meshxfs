#!/bin/bash
# ssh_block.sh <seconds> — TEST ONLY: this node drops every packet to its ssh port for <seconds>,
# then lets them in again.
#
# A lap whose exit must meet a node that does not answer (tests/lap_load_end_lap.sh MODE=unreach,
# through tests/noino_fence_efd_hold_lap.sh LAP_UNREACH_S) runs this on that node, detached.  An
# ssh to the node then times out, as the one to S did when the record
# D-NOINO-LAP-ABORT-LEAVES-ITS-LOADS-RUNNING-INTO-THE-NEXT-LAP was filed (rc=124).  The rule is
# taken out after <seconds> and lives only in the running kernel, so a power cycle clears it too.
# Prints one 'SSH-BLOCK <tool> <s>s' line when the rule is in, and 'SSH-BLOCK-END' when it is out;
# exit 1 when neither nft nor iptables can put it in.
set -u
s=${1:?seconds}
case $s in ''|*[!0-9]*) echo "SSH-BLOCK seconds must be a number"; exit 1;; esac
# the ssh that started this ends first, so its own session is not caught in the drop
sleep 2
if command -v nft > /dev/null 2>&1; then
    nft add table inet lapsshblk || exit 1
    if ! nft add chain inet lapsshblk in '{ type filter hook input priority -10 ; }' \
        || ! nft add rule inet lapsshblk in tcp dport 22 drop; then
        nft delete table inet lapsshblk
        exit 1
    fi
    echo "SSH-BLOCK nft ${s}s"
    sleep "$s"
    nft delete table inet lapsshblk
elif command -v iptables > /dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport 22 -j DROP || exit 1
    echo "SSH-BLOCK iptables ${s}s"
    sleep "$s"
    iptables -D INPUT -p tcp --dport 22 -j DROP
else
    echo "SSH-BLOCK none: no nft or iptables on $(hostname)"
    exit 1
fi
echo SSH-BLOCK-END
