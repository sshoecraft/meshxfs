#!/bin/bash
# drbd_third_vote_lap.sh -- one batch lap of
# D-DRBD-PAIR-WITHOUT-QDEVICE-OR-NODE-FENCE-P1-DOES-NOT-SURVIVE-P0-DEATH, on the DRBD rig (g2).
#
# A pair with no /etc/mxfs/drbd-fence.conf, or agent=self alone, decides a lost link by its fixed
# tie-break, under which participant 1 cannot tell participant 0's death from a cut link: it
# froze, restarted and stayed out.  The fix refuses such a pair at mount
# (mxfs_drbd_judge_third_vote, drbd_third_vote=1, the default).
#
# A lap: the rig's pair taken down and built again (scripts/drbd_rig.sh down, up, mxfs: DRBD
# dual-primary on two fresh pool LUNs, mkfs, both mounted under the rig's node fence), then
# `scripts/drbd_rig.sh third-vote-test $ARM`, then down again.
#   EXPOSED  the pair with agent=self alone asked to mount on both nodes
#   PASS     ARM=1: both mounts refused naming the missing third vote;
#            ARM=0: participant 1 recovered participant 0's slice after its death
#   FAIL     ARM=1: a node mounted the pair, or refused it for another reason;
#            ARM=0: participant 1 did not carry on (the defect)
#   ABORT    the pair could not be built, or the test printed no verdict
# ARM=1 (default) runs the module's default; ARM=0 loads it with drbd_third_vote=0, the
# same-build control.
#
# Bound: up measured 5.5 min, of which 2.5 min is the fio of the backing LUNs that this lap skips
# (DRBD_RIG_NO_BASELINE=1) and 140 s the 20 GiB sync (tests/evidence/drbd_rig/20261010T111148Z-up),
# mxfs ~25 s, the test: arm 1 two mount attempts and a remount (~1 min), arm 0 two mounts, the
# death and 74 s of watching (~2 min), down ~15 s.  About 6 min a lap; each drbd_rig.sh step
# carries its own bounds, and a caller bounds the lap at twice what the precheck measures.
#
# Usage: tests/drbd_third_vote_lap.sh <label>   (MXFS_GROUP: the DRBD rig's group, default g2)
# Exit 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
cd "$(dirname "$0")/.." || exit 2
ARM=${ARM:-1}
case "$ARM" in 0|1) ;; *) echo "LAP third_vote ABORT: ARM=$ARM is neither 1 nor 0"; exit 2 ;; esac
export MXFS_GROUP=${MXFS_GROUP:-g2}
export DRBD_RIG_NO_BASELINE=1
echo "LAP third_vote start $(date -u +%FT%TZ) label=$LABEL group=$MXFS_GROUP arm=$ARM srcversion=$(modinfo -F srcversion mxfs.ko)"
scripts/drbd_rig.sh down > /dev/null 2>&1
for s in up mxfs; do
    out=$(scripts/drbd_rig.sh "$s" 2>&1)
    rc=$?
    [ "$rc" = 0 ] || { echo "LAP third_vote ABORT: drbd_rig.sh $s rc=$rc: $(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-240)"; scripts/drbd_rig.sh down > /dev/null 2>&1; exit 2; }
done
out=$(ARM=$ARM scripts/drbd_rig.sh third-vote-test "$ARM" 2>&1)
rc=$?
echo "$out" | grep -a -E '^\[|^THIRDVOTE' | cut -c1-300
scripts/drbd_rig.sh down > /dev/null 2>&1
grep -aq '^THIRDVOTE EXPOSED' <<<"$out" && echo "EXPOSED: the pair with agent=self alone asked to mount on both nodes (arm $ARM)"
if grep -aq '^THIRDVOTE PASS' <<<"$out"; then
    echo "LAP third_vote PASS: $(grep -a '^THIRDVOTE PASS' <<<"$out" | cut -c17-240) (arm=$ARM)"; exit 0
fi
if grep -aq '^THIRDVOTE FAIL' <<<"$out"; then
    echo "LAP third_vote FAIL: $(grep -a '^THIRDVOTE FAIL' <<<"$out" | cut -c17-240) (arm=$ARM)"; exit 1
fi
echo "LAP third_vote ABORT: third-vote-test rc=$rc printed no verdict: $(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-240)"
exit 2
