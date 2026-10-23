#!/bin/bash
# evidence_link_lap.sh -- one lap of D-NODES-CANNOT-WRITE-TESTS-EVIDENCE-IT-LINKS-TO-THE-HOSTS-OWN-MXFS-DISK:
# a node writes through a link in the tree it sees over the NFS export of /src, and the host reads
# back what it wrote through the same link.
#
# tests/evidence is a symlink out of the tree.  A row that writes its evidence from a node goes
# through /src/mxfs/tests/evidence on the node, where the link resolves in the node's own
# namespace: a target only the host has (/mxfs/evidence, the defect) is a missing directory there,
# and the node cannot create its evidence directory (alloc_witness: witness_dir=unwritable).
#
# The lap makes a link of its own beside tests/evidence, tests/.evidence_link_lap.<label>.<stamp>,
# to the target tests/evidence has (the tree as it is), or to EVIDENCE_LINK_TARGET when that is
# set (the control: /mxfs/evidence, the target the defect had).  Its own link, so a control never
# swaps the link every other lane writes through.  The node creates a directory directly under the
# link (mkdir without -p: a missing target is a failure, never a directory made on the node's own
# disk) and a file in it, and the host reads the file through the same link.  With the tree's own
# target the node then writes through tests/evidence itself, and the host reads that back too.
#
#   EXPOSED  the node attempted its write through the link (printed before it does)
#   PASS     every file the node wrote is the one the host reads
#   FAIL     the node could not write, or the host reads something else
#
# Bound, derived: four ssh calls, each under a second measured and each bounded 20 s by itself,
# and two local reads: 4 * 20 = 80 s.
#
# Usage: tests/evidence_link_lap.sh <label> <node>
# Exit: 0 PASS, 1 FAIL, 2 the lap could not measure (node unreachable, no tree at /src/mxfs).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
LABEL=${1:?usage: evidence_link_lap.sh <label> <node>}
NODE=${2:?usage: evidence_link_lap.sh <label> <node>}
SSH="$REPO/tools/mxfs_sshpass.sh"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
TOKEN="$LABEL.$STAMP.$$.$RANDOM"
LEAF="evidence_link_lap_${LABEL}_$STAMP"

TREE_TARGET=$(readlink "$REPO/tests/evidence")
[ -n "$TREE_TARGET" ] || { echo "ABORT: tests/evidence is not a link"; exit 2; }
TARGET=${EVIDENCE_LINK_TARGET:-$TREE_TARGET}
LINK="tests/.evidence_link_lap.$LABEL.$STAMP"

on_node() {  # one command on the node, bounded; its last line
    timeout 20 "$SSH" "$NODE" "$1" 2>&1 < /dev/null | tr -d '\r' | tail -1
}

src=$(on_node "mountpoint -q /src && [ -r /src/mxfs/run.sh ] && echo src=1 || echo src=0")
[ "$src" = "src=1" ] || { echo "ABORT: $NODE does not see the tree at /src/mxfs (got '$src')"; exit 2; }
ln -s "$TARGET" "$REPO/$LINK" || { echo "ABORT: cannot make $LINK"; exit 2; }
trap 'rm -f "$REPO/$LINK"' EXIT
echo "INFO tests/evidence -> $TREE_TARGET; this lap's $LINK -> $TARGET"
echo "INFO $NODE resolves the lap's link to: $(on_node "readlink -f /src/mxfs/$LINK || echo unresolved")"

echo "EXPOSED: $NODE writes $LEAF/probe through $LINK"
w=$(on_node "mkdir /src/mxfs/$LINK/$LEAF && echo $TOKEN > /src/mxfs/$LINK/$LEAF/probe && echo wrote=1 || echo wrote=0")
got=$(cat "$REPO/$LINK/$LEAF/probe" 2>/dev/null)
echo "INFO $NODE: '$w'; the host reads '${got:-<nothing>}' through $LINK"
fail=""
[ "$w" = "wrote=1" ] || fail="$NODE could not write through $LINK ($w)"
[ -z "$fail" ] && [ "$got" != "$TOKEN" ] && fail="the host reads '${got:-<nothing>}' through $LINK, not what $NODE wrote"

if [ -z "$fail" ] && [ "$TARGET" = "$TREE_TARGET" ]; then
    w2=$(on_node "echo $TOKEN.tree > /src/mxfs/tests/evidence/$LEAF/tree && echo wrote=1 || echo wrote=0")
    got2=$(cat "$REPO/tests/evidence/$LEAF/tree" 2>/dev/null)
    echo "INFO $NODE through tests/evidence: '$w2'; the host reads '${got2:-<nothing>}'"
    [ "$w2" = "wrote=1" ] && [ "$got2" = "$TOKEN.tree" ] \
        || fail="$NODE's write through tests/evidence is not what the host reads ($w2, '${got2:-<nothing>}')"
fi

if [ -n "$fail" ]; then
    echo "EVIDENCE_LINK_LAP FAIL $fail"
    exit 1
fi
echo "EVIDENCE_LINK_LAP PASS $NODE wrote through a link to $TARGET and the host read it back"
exit 0
