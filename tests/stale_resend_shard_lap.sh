#!/bin/bash
# stale_resend_shard_lap.sh -- one lap of
# D-TCP-STALE-RESEND-CANDIDATES-SHARE-ONE-ROUTING-SHARD-SO-ONE-MASTER-DRAW:
# tests/tcp_stale_resend.sh needs one candidate file remotely mastered from W,
# and the master is decided per routing shard (routing hash v2 clears an inode
# number's low three bits, include/mxfs/mxfs_tauth.h).  Eight files written back
# to back are one or two shards, so the search was one draw where the harness
# meant eight, and on a 2-node pair it ABORTed whenever that draw was local to
# W.  Whether that draw is local is a hash, so a lap graded by the ABORT would
# expose the defect only some of the time; the lap grades the property the
# defect is about instead, which the candidates' inode numbers show every lap.
#
# The lap runs the harness once on the formed pair (test1/test2), with
# SR_SHARD_SELECT passed through (0 is the harness's own same-build control:
# eight files back to back), and reads the candidates it made, H's
# h_setup.txt, from the harness's output directory.
#
#   PASS  the candidates span at least 8 distinct routing shards (8 draws)
#   FAIL  fewer: the search for a remotely mastered candidate is fewer draws
#         than the eight candidates it makes
#   ABORT the harness made no candidates (pair not formed, srcversion, setup)
#
# Bound, derived: the harness's own budget (its header: 254 s) + 10 s to read
# the candidates = 264 s.
#
# Usage: tests/stale_resend_shard_lap.sh <label>   (MXFS_GROUP=g2, the pair formed)
# Exit: 0 PASS, 1 FAIL, 2 ABORT (measured nothing).
set -u
LABEL=${1:?label}
cd "$(dirname "$0")/.." || exit 2
NEED=8

echo "LAP sr_shard start $(date -u +%FT%TZ) label=$LABEL shard_select=${SR_SHARD_SELECT:-1}"
hlog=$(mktemp)
timeout -k 10 254 tests/tcp_stale_resend.sh "srlap_$LABEL" < /dev/null > "$hlog" 2>&1
hrc=$?
grep -a '^===\|INFO candidates\|INFO [0-9]* candidates\|^ABORT\|^RESULT' "$hlog" | cut -c1-240
out=$(sed -n 's/^=== tcp_stale_resend .* out=\([^ ]*\) .*/\1/p' "$hlog" | head -1)
rm -f "$hlog"
[ "$hrc" = 124 ] && echo "LAP sr_shard: the harness overran its 254 s budget (rc 124)"
setup="$out/h_setup.txt"
if [ -z "$out" ] || [ ! -s "$setup" ]; then
    echo "LAP sr_shard ABORT: no candidates in [${setup}] (harness rc=$hrc): the pair was not formed or the setup failed"
    exit 2
fi
n=$(grep -ac . "$setup")
shards=$(awk '$2 ~ /^[0-9]+$/ {print int($2 / 8)}' "$setup" | sort -u | grep -ac .)
inos=$(awk '{printf "%s ", $2}' "$setup")
echo "LAP sr_shard candidates=$n shards=$shards harness_rc=$hrc inos=[${inos% }] setup=$setup"
if [ "$shards" -ge "$NEED" ]; then
    echo "LAP sr_shard PASS: $n candidates in $shards distinct routing shards ($shards draws for a remotely mastered one)"
    exit 0
fi
echo "LAP sr_shard FAIL: $n candidates in $shards distinct routing shards: the search is $shards draw(s), not $NEED"
exit 1
