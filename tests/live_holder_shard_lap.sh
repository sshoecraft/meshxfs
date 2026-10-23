#!/bin/bash
# live_holder_shard_lap.sh -- one lap of
# D-LIVE-HOLDER-WAIT-FINDS-NO-REMOTE-MASTERED-INODE-AND-ABORTS-BEFORE-MEASURING:
# tests/live_holder_wait.sh needs one candidate inode remotely mastered from W,
# and the master is decided per routing shard (routing hash v2 clears an inode
# number's low three bits, include/mxfs/mxfs_tauth.h), re-decided at every
# cluster formation.  Its eight candidates, made back to back, were one or two
# shards, so the search was one or two draws where the harness meant eight, and
# on a 2-node pair it ABORTed whenever those draws were local to W (the 0.90.134
# dry run's capture gate, attempt 20261021T230333Z).  Whether a draw is local is
# a hash, so a lap graded by the ABORT would expose the defect only some of the
# time; the lap grades the property the defect is about instead, which the
# candidates' inode numbers show on every lap.
#
# The lap runs the harness's setup alone (LH_SETUP_ONLY=1: H makes its
# candidates, lists them, removes them and exits) on the formed pair, with
# LH_SHARD_SELECT passed through (0 is the harness's own same-build control:
# eight candidates back to back, all kept), and counts the distinct routing
# shards of the CANDIDATE lines it printed.
#
#   PASS  the candidates span at least 8 distinct routing shards (8 draws)
#   FAIL  fewer: the search for a remotely mastered candidate is fewer draws
#         than the eight candidates the harness meant
#   ABORT the harness made no candidates (pair not formed, srcversion, setup)
#
# Exposure: every lap that prints its candidates reaches the code the defect is
# in (the candidate selection), so the lap prints `EXPOSED: candidates=<n>`.
#
# Bound, derived: the harness reached and removed its candidates in 4-5 s on
# test15/test16 (lane g2b_lhshard_precheck_20261023T072946Z, four laps); its own
# bounds on that path are the setup's 13 s and the removal's 20 s, and the checks
# before it measured under 3 s (6 s at 2x): 40 s for the harness, 50 s a lap.
#
# Usage: tests/live_holder_shard_lap.sh <label> [H=test1] [W=test2]   (the pair formed)
# Exit: 0 PASS, 1 FAIL, 2 ABORT (measured nothing).
set -u
LABEL=${1:?label}
H=${2:-test1}; W=${3:-test2}
cd "$(dirname "$0")/.." || exit 2
NEED=8

echo "LAP lh_shard start $(date -u +%FT%TZ) label=$LABEL H=$H W=$W shard_select=${LH_SHARD_SELECT:-1}"
hlog=$(mktemp)
LH_SETUP_ONLY=1 timeout -k 5 40 tests/live_holder_wait.sh "lhlap_$LABEL" "$H" "$W" < /dev/null > "$hlog" 2>&1
hrc=$?
grep -a '^===\|^CANDIDATE\|^SETUP-ONLY\|^ABORT\|^RESULT' "$hlog" | cut -c1-240
n=$(grep -ac '^CANDIDATE ' "$hlog")
shards=$(awk '$1 == "CANDIDATE" && $3 ~ /^[0-9]+$/ {print int($3 / 8)}' "$hlog" | sort -u | grep -ac .)
inos=$(awk '$1 == "CANDIDATE" {printf "%s ", $3}' "$hlog")
rm -f "$hlog"
[ "$hrc" = 124 ] && echo "LAP lh_shard: the harness overran its 40 s bound (rc 124)"
if [ "$n" = 0 ]; then
    echo "LAP lh_shard ABORT: the harness listed no candidates (rc=$hrc): the pair was not formed or the setup failed"
    exit 2
fi
echo "EXPOSED: candidates=$n"
echo "LAP lh_shard candidates=$n shards=$shards harness_rc=$hrc inos=[${inos% }]"
if [ "$shards" -ge "$NEED" ]; then
    echo "LAP lh_shard PASS: $n candidates in $shards distinct routing shards ($shards draws for a remotely mastered one)"
    exit 0
fi
echo "LAP lh_shard FAIL: $n candidates in $shards distinct routing shards: the search is $shards draw(s), not $NEED"
exit 1
