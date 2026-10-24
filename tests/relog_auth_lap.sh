#!/bin/bash
# relog_auth_lap.sh -- one batch lap of D-CAWMPATH-NLINK1-FILE-NAMED-TWICE-AFTER-ANSWER-LOST.
#
# The record's two corrupt audits (4/ and 8/disk/caw/mpath chk_clean, 2026-10-19T15:13:51Z and
# 15:20:43Z, build 8DAEC6B8298ADB049222D74) are the ones CHANGELOG.md's 0.90.131 removal of
# D-CAW-MPATH-8NODE-REUSED-INODE-NAMED-BY-TWO-DIRENTS-NLINK-1-AFTER-SUITE traced: a node holding
# the workload's LOCK directory only SHARED was authorized to re-log its out-of-date directory
# core at release (mxfs_dlm_relog_authorized read the CAW slot as held-or-not, and a shared bit
# read as exclusive), so the copy that still named LOCK/test28 was written over test28's removal;
# the number was then freed and reused as test28/f0000811, named twice with nlink 1.  The fix
# authorizes the re-log only on the mode the node was granted (relog_auth_granted_mode=1).
#
# A lap: a fresh prep at <configuration> (the inner lap needs one: a second run on the same load
# reuses numbers whose old incarnations the first node still caches), then one lap of
# tests/relog_pr_release_auth.sh on the formation's first two nodes, one arm: A holds a fresh
# directory shared with its next release drain forced onto the re-log arm (dbg_relog_force_ino),
# and B creates in it.
#   EXPOSED  the forced arm ran on A under a shared grant (P146V-FORCE, granted_mode=3, no dead
#            prior incarnation): the inner verdict is anything but UNREACHED
#   PASS     A refused the re-log (no P146V-RELOG-HOLDERS) and every check of the inner lap held
#            (both nodes list b1 b2, B's create rc=0, no shutdown or corruption line)
#   FAIL     A re-logged the directory core under its shared hold, or an inner check failed
#   VACUOUS  the forced arm did not run under a shared grant, so nothing was measured
#   ABORT    the prep failed or the inner lap printed no verdict
# ARM=1 (default) runs the module's default relog_auth_granted_mode=1; ARM=0 sets it to 0 on both
# nodes for the lap, the read before the fix (the same-build control).
#
# Bound: prep_cluster at 4/disk/caw/mpath measured 50-58 s (lane
# g4_nlink_relabort_off_20261023T230646Z steps 2 and 4), bound 130 s; the inner lap's header
# derives 30 s for one lap, bound 60 s.  A caller bounds the lap at twice what the precheck
# measures.
#
# Usage: tests/relog_auth_lap.sh <label> <configuration>
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
case "$ARM" in
    1) RA=F ;;
    0) RA=C ;;
    *) echo "LAP relog_auth ABORT: ARM=$ARM is neither 1 nor 0"; exit 2 ;;
esac
echo "LAP relog_auth start $(date -u +%FT%TZ) label=$LABEL at=$CONFIG A=$A B=$B arm=$ARM"
prep=$(MXFS_FORCE_PREP=1 timeout -k 5 130 ./run.sh "$CONFIG" ${MXFS_GROUP:+--group "$MXFS_GROUP"} prep_cluster < /dev/null 2>&1)
rc=$?
[ "$rc" = 0 ] || { echo "LAP relog_auth ABORT: prep_cluster rc=$rc: $(echo "$prep" | tail -2 | tr '\n' ' ' | cut -c1-240)"; exit 2; }
out=$(RELOG_ARM=$RA timeout -k 5 60 tests/relog_pr_release_auth.sh "$A" "$B" 1 "$LABEL" < /dev/null 2>&1)
irc=$?
echo "$out" | grep -a '^===\|^  RESULT\|^  INFO\|^RESULT\|^  FAIL' | cut -c1-300
verdict=$(echo "$out" | grep -ao '^  RESULT lap1[CF] .*' | grep -ao 'verdict=[A-Z-]*' | head -1 | cut -d= -f2)
checks=$(echo "$out" | grep -ac '^  FAIL ')
case "$verdict" in
    FIXED|CONTROL-REFUSED|REPRODUCED|FIX-RELOGGED)
        echo "EXPOSED: A's release drain of the directory took the forced re-log arm under a shared grant (verdict=$verdict)" ;;
    UNREACHED)
        echo "LAP relog_auth VACUOUS: the forced re-log arm did not run under a shared grant (inner rc=$irc)"; exit 3 ;;
    *)
        echo "LAP relog_auth ABORT: the inner lap printed no verdict (inner rc=$irc)"; exit 2 ;;
esac
case "$verdict" in
    REPRODUCED|FIX-RELOGGED)
        echo "LAP relog_auth FAIL: A re-logged the directory core under its shared hold (verdict=$verdict, arm=$ARM)"; exit 1 ;;
esac
if [ "$checks" != 0 ]; then
    echo "LAP relog_auth FAIL: $checks check(s) of the inner lap failed (verdict=$verdict, arm=$ARM)"; exit 1
fi
echo "LAP relog_auth PASS: A refused the re-log under its shared hold and both nodes list b1 b2 (verdict=$verdict, arm=$ARM)"
exit 0
