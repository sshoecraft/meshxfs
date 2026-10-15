#!/bin/bash
#
# quorum_dinq_probe.sh — one D_inq sample on this node (docs/quorum-takeover.md):
# how long votequorum still calls this node quorate after its traffic to the
# peer (and, with a qnetd address, to qnetd as well) is dropped
#
# Usage: quorum_dinq_probe.sh <peer addr> [<qnetd addr>]
#
# Run on a corosync node with MeshXFS NOT mounted under fence=quorum: the cut
# makes this node inquorate, which resets a node that has it mounted.
#
# Prints one line:
#   DINQ cut_delay=<s> dinq=<s> reform=<s>
# cut_delay  the random 0-3 s wait before the cut, which moves it across the
#            token rotation and the QDevice heartbeat
# dinq       from the cut to the first `corosync-quorumtool -s` that says
#            "Quorate: No" (polled every 50 ms, /proc/uptime clock)
# reform     from lifting the cut to "Total votes: 3" again
# or DINQ_ERR <why>.  The cut is always lifted before exit.
set -u
peer=${1:?peer addr}; qnetd=${2:-}
T=vsfdinq
up() { cut -d' ' -f1 /proc/uptime; }
sub() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", a - b }'; }
quorate() { corosync-quorumtool -s 2>/dev/null | awk '/^Quorate:/ { print $2 }'; }
lift() { nft delete table inet $T 2>/dev/null; }
trap lift EXIT

[ "$(quorate)" = Yes ] || { echo "DINQ_ERR not quorate before the cut"; exit 1; }
corosync-quorumtool -s | grep -q '^Total votes: *3' || { echo "DINQ_ERR not 3 votes before the cut"; exit 1; }
grep -q ' mxfs ' /proc/mounts && { echo "DINQ_ERR mxfs is mounted here"; exit 1; }
delay=$(awk 'BEGIN { srand(); printf "%.3f", rand() * 3 }')
sleep "$delay"
lift
nft add table inet $T &&
nft add chain inet $T in '{ type filter hook input priority -300; }' &&
nft add chain inet $T out '{ type filter hook output priority -300; }' &&
nft add rule inet $T in ip saddr "$peer" drop &&
nft add rule inet $T out ip daddr "$peer" drop || { echo "DINQ_ERR nft"; exit 1; }
if [ -n "$qnetd" ]; then
    nft add rule inet $T in ip saddr "$qnetd" drop &&
    nft add rule inet $T out ip daddr "$qnetd" drop || { echo "DINQ_ERR nft qnetd"; exit 1; }
fi
t0=$(up)
while :; do
    q=$(quorate); t=$(up)
    [ "$q" = No ] && break
    # 120 s: well past the 45 s takeover bound, so a node that never goes
    # inquorate is reported as such rather than cut short
    [ "$(sub "$t" "$t0" | cut -d. -f1)" -ge 120 ] && { lift; echo "DINQ_ERR still quorate after 120 s"; exit 1; }
    sleep 0.05
done
dinq=$(sub "$t" "$t0")
lift
t1=$(up)
while ! corosync-quorumtool -s 2>/dev/null | grep -q '^Total votes: *3'; do
    [ "$(sub "$(up)" "$t1" | cut -d. -f1)" -ge 60 ] && { echo "DINQ cut_delay=$delay dinq=$dinq reform=NONE"; exit 1; }
    sleep 0.2
done
echo "DINQ cut_delay=$delay dinq=$dinq reform=$(sub "$(up)" "$t1")"
