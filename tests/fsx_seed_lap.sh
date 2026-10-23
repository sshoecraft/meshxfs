#!/bin/bash
# fsx_seed_lap.sh -- one lap of D-FSX-RANDOM-SEED-ABOVE-INT-MAX-MAKES-FSX-EXIT-WITH-USAGE-AND-LOGS-ARE-DELETED:
# tests/suite/fsx.sh run with its seed drawn from four bytes that read as
# 2^32-1, the largest draw /dev/urandom can give it.
#
# fsx keeps its -S in an int and prints its usage for a negative one, so a draw
# past INT_MAX made both checks exit 90 at once, a FAIL that exercised nothing.
# On the board that happens in about half the runs; here it is made certain: in
# a mount namespace of its own, a file of four 0xff bytes is bound over
# /dev/urandom, so the draw is 4294967295 every lap and every lap is exposed.
# FSX_SEED is cleared, since a seed given that way bypasses the draw.
#
# fsx.sh runs as it does on a node (as root, which it needs for its log under
# /root), on a scratch directory of the host's tmpfs instead of the mount: the
# defect is in the seed fsx.sh hands the vendored binary, not in the filesystem
# under it.
#
#   PASS  fsx.sh reports RESULT: PASS with seed=<1..2^31-1>: both checks ran
#   FAIL  fsx.sh reports anything else (RESULT: FAIL, or no RESULT line)
#
# Bound, derived: fsx.sh's two checks (100k and 50k operations) took 2.34-2.35 s
# in three runs on a scratch directory of /dev/shm (on the host's ext4 /tmp,
# 32-37 s, which is why the lap uses tmpfs); twice that is 4.7 s, plus 1 s for
# the namespace and the bind; 6 s.  The lap fails when fsx.sh overruns it.
#
# Usage: tests/fsx_seed_lap.sh
# Exit: 0 PASS, 1 FAIL, 2 the lap could not measure (no sudo, no namespace).

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
FSXSH="$HERE/suite/fsx.sh"
BOUND=6

D=$(mktemp -d -p /dev/shm) || { echo "LAP fsx_seed ABORT: no scratch directory"; exit 2; }
R="$D/urandom_ff"
printf '\377\377\377\377\377\377\377\377' > "$R"
chmod 755 "$D"

echo "LAP fsx_seed start $(date -u +%FT%TZ) draw=4294967295 (4 bytes 0xff bound over /dev/urandom) fsx.sh=$FSXSH"
out=$(timeout -k 5 "$BOUND" sudo -n env -u FSX_SEED MXFS_NODES=1 unshare -m sh -c \
      'mount --bind "$1" /dev/urandom || exit 97; exec "$2" "$3"' sh "$R" "$FSXSH" "$D" 2>&1)
rc=$?
# A failing check leaves its log under /root, named for the seed fsx.sh used.
sudo -n rm -f /root/fsx.4294967295.100000.log /root/fsx.4294967295.50000.log
rm -f "$R"
sudo -n rmdir "$D" 2>/dev/null || rmdir "$D" 2>/dev/null

echo "$out" | grep -a '^RESULT: ' | cut -c1-400
case "$rc" in
    97) echo "LAP fsx_seed ABORT: the bind over /dev/urandom failed"; exit 2 ;;
    124|137) echo "LAP fsx_seed FAIL: fsx.sh overran its ${BOUND}s bound"; exit 1 ;;
esac
res=$(echo "$out" | grep -a '^RESULT: ' | tail -1)
seed=$(echo "$res" | grep -o 'seed=[0-9]*' | head -1 | cut -d= -f2)
if [ -z "$res" ]; then
    if echo "$out" | grep -q 'sudo'; then echo "LAP fsx_seed ABORT: sudo refused: $(echo "$out" | head -2 | tr '\n' ' ')"; exit 2; fi
    echo "LAP fsx_seed FAIL: fsx.sh printed no RESULT line (rc=$rc): $(echo "$out" | tail -3 | tr '\n' ' ' | cut -c1-300)"
    exit 1
fi
case "$res" in
    "RESULT: PASS "*)
        if [ -n "$seed" ] && [ "$seed" -ge 1 ] && [ "$seed" -le 2147483647 ]; then
            echo "LAP fsx_seed PASS seed=$seed: both checks ran"
            exit 0
        fi
        echo "LAP fsx_seed FAIL: PASS reported with seed=$seed outside 1..2147483647"
        exit 1 ;;
esac
echo "LAP fsx_seed FAIL seed=$seed: $(echo "$res" | cut -c1-300)"
exit 1
