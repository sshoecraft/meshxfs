#!/bin/bash
#
# drbd_release_verify.sh — everything a release that claims 2/net/mesh/drbd
# must pass on the build being released, in one run, detached.
#
# 2/net/mesh/drbd has no pool LUN to share and no SCSI fence, so it is not a
# column of the board the other configurations are graded on; it is verified
# by its own rig (scripts/drbd_rig.sh) and its own board
# (tests/evidence/drbd_rig/criteria.json).  That made it easy to leave
# out: 0.90.42 and the first run of 0.90.48 re-verified sixteen configurations
# and never ran this one.  scripts/release.sh --publish now refuses a version
# whose evidence file from this script does not end in a PASS
# (data/configurations.json, released_by_own_rig).
#
# Usage: [MXFS_GROUP=g2] tests/drbd_release_verify.sh VERSION
#
# Steps, each a scripts/drbd_rig.sh subcommand with its own bounds, each
# logged with its exit code; a failing step does not stop the run, so one run
# shows every failure:
#   up                 two VMs, a LUN each, DRBD dual-primary, the fence authority
#   mxfs + suite       the cluster suite on /dev/drbd0 (its own board)
#   remount-test       clean unmount/remount, a crash-cut retirement, a whole-cluster restart
#   death-test         a node destroyed with MXFS mounted: fenced, certified, replayed, rejoined
#   fence-test         the replication link cut: one node powers the other off and resumes
#   split-test         the link cut on both sides at once: exactly one winner
#   resolve-test       /dev/drbd0 is never resolved to its backing disk; a loop mount is refused
#   outage-test        both nodes die at once and the pair recovers every fsynced file
#   takeover-test      a pair outage whose recovery owner fails: taken over by itself, and by the peer
#   down               unmount, DRBD down, both LUNs returned
# `mxfs` (load, mkfs, mount on both) runs before every test, so each starts
# from a formed pair whatever the test before it left.
#
# The module verified is the tree's mxfs.ko; its srcversion is on the first
# line, and the verdict line names it.
#
# Output: tests/evidence/drbd_release_verify_<VERSION>.out, last line
#   DRBD_RELEASE_VERIFY PASS|FAIL version=<V> srcversion=<S> failed=[...]
#
# Never run beside a board on the same rig group: run.sh treats this rig's
# lock holders as orphans of a dead run and kills them.
#
set -u
V="${1:?usage: tests/drbd_release_verify.sh VERSION}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1
# Hold the pair's VMs for the whole run (tools/vm_pool.sh): the steps between
# the suite's run.sh and the end -- death, fence, outage, takeover -- run no
# run.sh to hold them, and each run.sh releases its nodes when it ends.  Once
# this script ends they are shut off after the pool's grace.
. tests/lib/runlock.sh
RIG_VMS=$(tools/mxfs_lab.sh group "${MXFS_GROUP:-g2}")
vmhold_take "drbd_release_verify $V" $RIG_VMS || { echo "could not hold [$RIG_VMS]"; exit 1; }
( setsid tools/vm_pool.sh release --after $$ $RIG_VMS </dev/null >/dev/null 2>&1 & )   # never a child a bare wait would block on
# Named by the release candidate when this runs for one (tools/release_run.py
# sets MXFS_LOGTAG), so one candidate is never graded on another's run.
O="tests/evidence/drbd_release_verify_${MXFS_LOGTAG:-$V}.out"
SV=$(modinfo -F srcversion mxfs.ko 2>/dev/null)
MV=$(modinfo -F version mxfs.ko 2>/dev/null)
: > "$O"
echo "=== $(date -u +%FT%TZ) drbd_release_verify version=$V module_version=$MV srcversion=$SV group=${MXFS_GROUP:-g2} ===" >> "$O"
[ "$MV" = "$V" ] || { echo "DRBD_RELEASE_VERIFY FAIL version=$V srcversion=$SV failed=[the tree's mxfs.ko is version '$MV', not $V]" >> "$O"; exit 1; }
failed=""
step() {  # step <label> <drbd_rig args...>
    local label=$1 rc
    shift
    echo "=== $(date -u +%FT%TZ) STEP $label: scripts/drbd_rig.sh $* ===" >> "$O"
    scripts/drbd_rig.sh "$@" >> "$O" 2>&1
    rc=$?
    echo "=== STEP $label rc=$rc ($(date -u +%FT%TZ)) ===" >> "$O"
    [ "$rc" = 0 ] || failed="$failed $label"
    return $rc
}
# The suite step's own exit code is run.sh's, and run.sh exits 0 with rows
# failed: this verification printed PASS over a red board.  The suite step
# passes only when the DRBD board itself reads green, graded for the release
# candidate when there is one.
board_green() {
    local out
    # harness-lint: ok - graded for the candidate, a board this run did not record reads NOT RUN, never a previous run's PASS
    out=$(python3 tools/criteria.py 2/net/mesh/drbd ${MXFS_CANDIDATE:+--candidate "$MXFS_CANDIDATE"} 2>&1)
    echo "$out" | grep -E '^Total:|^VERDICT:' >> "$O"
    if echo "$out" | grep -q 'VERDICT: every criterion green'; then
        echo "=== STEP suite-board rc=0 ===" >> "$O"
        return 0
    fi
    echo "$out" | grep -E '^[0-9]+ +\|' | grep -vE '\| PASS ' >> "$O"
    echo "=== STEP suite-board rc=1 ===" >> "$O"
    failed="$failed suite-board"
    return 1
}
if step up up; then
    step mxfs-suite mxfs && step suite suite
    board_green
    for t in remount-test death-test fence-test split-test resolve-test outage-test; do
        step "mxfs-$t" mxfs && step "$t" "$t"
    done
    for who in self foreign; do
        step "mxfs-takeover-$who" mxfs && step "takeover-$who" takeover-test "$who"
    done
fi
step down down
if [ -z "$failed" ]; then
    echo "DRBD_RELEASE_VERIFY PASS version=$V srcversion=$SV failed=[]" >> "$O"
    exit 0
fi
echo "DRBD_RELEASE_VERIFY FAIL version=$V srcversion=$SV failed=[${failed# }]" >> "$O"
exit 1
