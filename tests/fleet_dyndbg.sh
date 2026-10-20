#!/bin/bash
# fleet_dyndbg.sh — turn mxfs's dynamic-debug print sites on or off on every
# node of the rig, and read back how many of them are enabled (per-node rc +
# counts).
#
# Usage: tests/fleet_dyndbg.sh <+p|-p> [nodes=32] [outfile]
#
# nodes is a count (test1..testN) or a comma list of node names, for a rig
# group's nodes (e.g. test29,test30 for g2c).
#
# The rig's prep (tests/setup/prep_node.sh) loads mxfs with dyndbg=+p and
# log_repeat_limit=0, so every pr_debug probe in a hot path prints; the
# packages load it with neither.  A pace measurement meant to stand for the
# shipped module turns the sites off first and records that it did: each node
# prints sites=<mxfs sites> on=<sites with p set>, and -p must read on=0.
#
# budget: each ssh is bounded (40 s); the whole fleet runs in parallel.
# the unkillable-wedge rule: no pgrep -f / ps; per-node rc files; nothing unbounded.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
FLAG=${1:?"+p or -p"}; NODES=${2:-32}; OUTF=${3:-}
case "$FLAG" in +p|-p) ;; *) echo "usage: $0 <+p|-p> [nodes] [outfile]"; exit 2 ;; esac
SSH=tools/mxfs_sshpass.sh
CMD="c=/proc/dynamic_debug/control; [ -w \$c ] || c=/sys/kernel/debug/dynamic_debug/control; echo 'module mxfs $FLAG' > \$c 2>/dev/null || echo SETFAIL=dyndbg; echo sites=\$(grep -c '\[mxfs\]' \$c) on=\$(grep '\[mxfs\]' \$c | grep -c ' =p');"
case "$NODES" in
    *[!0-9]*) NODE_LIST=$(printf '%s\n' "$NODES" | tr ',' ' ') ;;
    *)        NODE_LIST=$(seq 1 "$NODES" | sed 's/^/test/') ;;
esac
NN=$(printf '%s\n' $NODE_LIST | grep -c .)
D=$(mktemp -d)
for n in $NODE_LIST; do
    ( timeout 40 $SSH "$n" "$CMD echo ver=\$(cat /sys/module/mxfs/srcversion 2>/dev/null) m=\$(grep -c ' mxfs ' /proc/mounts)" >"$D/t.$n" 2>/dev/null; echo $? >"$D/rc.$n" ) &
done
wait
for n in $NODE_LIST; do
    echo "$n rc=$(cat "$D/rc.$n") $(grep -av '^Unauthorized\|^Warning:\|^If you' "$D/t.$n" | tr '\n' ' ')"
done > "$D/dyndbg.txt"
[ -n "$OUTF" ] && cp "$D/dyndbg.txt" "$OUTF"
cat "$D/dyndbg.txt"
echo "mounted: $(grep -c 'm=1' "$D/dyndbg.txt")/$NN  rc0: $(grep -c ' rc=0 ' "$D/dyndbg.txt")/$NN"
if grep -q SETFAIL "$D/dyndbg.txt"; then echo "FAIL: dynamic debug control refused on some node(s)"; exit 2; fi
if [ "$FLAG" = -p ] && grep -q ' on=[1-9]' "$D/dyndbg.txt"; then echo "FAIL: some node still has mxfs print sites on"; exit 2; fi
exit 0
