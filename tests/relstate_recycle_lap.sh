#!/bin/bash
# relstate_recycle_lap.sh -- one batch lap of
# D-16CAWMPATH-REJOINED-NODE-OPEN-SPINS-ON-WEDGED-INODE-AFTER-PATH-ALL-LOST.
#
# The record's run (16/disk/caw/mpath path_all_lost, 20261011T225324Z-g16) is the one CHANGELOG.md's
# 0.90.124 removal of D-RECYCLED-INODE-INHERITS-WEDGED-REL-STATE traced: test16's unmount wedged an
# inode at teardown, it remounted, and the first acquire on 125829259, an inode the new mount had
# just read, was refused as wedged with no wedge of it in that mount.  mxfs_dlm_inode_init never
# assigned i_mxfs_rel_state, and the slab hands out objects unzeroed, so a new inode in memory whose
# last occupant wedged started WEDGED.  The fix starts every new inode ACTIVE
# (relstate_init_active=1, the default).
#
# A lap: a fresh prep at <configuration> (a control lap leaves wedged inodes cached on A for the
# life of its mount), then tests/relstate_recycle_inject.sh on the formation's first two nodes:
# B creates the files, A caches and then frees them with dbg_relstate_wedge_on_free set, and A
# reads and appends to every file.
#   EXPOSED  A allocated a new inode in poisoned memory (P-RELSTATE-RECYCLED >= 1)
#   PASS     every read and append on A returned, and no acquire was refused as wedged
#   FAIL     an operation failed or an acquire was refused as wedged (P-INODE-WEDGE-FENCE)
#   VACUOUS  no new inode landed in poisoned memory, so nothing was measured
#   ABORT    the prep failed or the inner lap printed no verdict
# ARM=1 (default) runs the module's default; ARM=0 sets relstate_init_active=0 on A for the
# operations, the read before the fix (the same-build control).
#
# Bound: the inner lap's header derives ~30 s at 200 files; the prep is the configuration's
# prep_cluster, bounded by PREP_BOUND (seconds, default 240: twice a 16-node prep's ~2 min).  A
# caller bounds the lap at twice what the precheck measures.
#
# Usage: tests/relstate_recycle_lap.sh <label> <configuration>
#        (the group's env exported: MXFS_GROUP, MXFS_MARKER, MXFS_NODE_LIST of at least 2 nodes)
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}
CONFIG=${2:?configuration}
cd "$(dirname "$0")/.." || exit 2
NODES=${MXFS_NODE_LIST:?MXFS_NODE_LIST}
A=${NODES%%,*}
REST=${NODES#*,}
B=${REST%%,*}
ARM=${ARM:-1}
PREP_BOUND=${PREP_BOUND:-240}
case "$ARM" in
    0|1) ;;
    *) echo "LAP relstate_recycle ABORT: ARM=$ARM is neither 1 nor 0"; exit 2 ;;
esac
echo "LAP relstate_recycle start $(date -u +%FT%TZ) label=$LABEL at=$CONFIG A=$A B=$B arm=$ARM"
prep=$(MXFS_FORCE_PREP=1 timeout -k 5 "$PREP_BOUND" ./run.sh "$CONFIG" ${MXFS_GROUP:+--group "$MXFS_GROUP"} prep_cluster < /dev/null 2>&1)
rc=$?
[ "$rc" = 0 ] || { echo "LAP relstate_recycle ABORT: prep_cluster rc=$rc: $(echo "$prep" | tail -2 | tr '\n' ' ' | cut -c1-240)"; exit 2; }
out=$(RRI_INIT_ACTIVE=$ARM timeout -k 5 120 tests/relstate_recycle_inject.sh "$LABEL" "$A" "$B" 200 < /dev/null 2>&1)
irc=$?
echo "$out" | grep -a '^===\|^  INFO\|^  FAIL\|^EXPOSED\|^RESULT\|^ABORT' | cut -c1-300
result=$(echo "$out" | grep -a '^RESULT: ' | tail -1)
recyc=$(echo "$result" | grep -ao 'recycled=[0-9]*' | cut -d= -f2)
case "$result" in
    "RESULT: PASS "*|"RESULT: FAIL "*) ;;
    *) echo "LAP relstate_recycle ABORT: the inner lap printed no verdict (inner rc=$irc): $(echo "$result" | cut -c1-200)"; exit 2 ;;
esac
if [ "${recyc:-0}" -lt 1 ]; then
    echo "LAP relstate_recycle VACUOUS: no new inode on $A landed in poisoned memory (recycled=${recyc:-none})"; exit 3
fi
case "$result" in
    "RESULT: PASS "*)
        echo "LAP relstate_recycle PASS: $A's new inodes in poisoned memory started ACTIVE, every read and append returned (arm=$ARM)"; exit 0 ;;
esac
echo "LAP relstate_recycle FAIL: $(echo "$result" | cut -c1-200) (arm=$ARM)"
exit 1
