#!/bin/bash
# caw_register_hard_waiter.sh — D-CAW-REGISTER-WAITER-HARD-ERROR-LEAVES-ORPHAN-WAITER-BIT
#
# A swap that registers this node as a waiter on an inode lock may land on the
# target and still end in a hard error (an I/O error on every retry, a failed
# generation-verify read, -ESHUTDOWN).  The waiter bit is then on the platter
# with no request behind it: peers defer readers to it, and a releaser's direct
# handoff can grant it a lock its node never learns it holds.  The fix drops
# the bit on that exit as every other give-up does.
#
# Choreography, on a 2-node CAW cluster:
#   1. Holder H writes file F and keeps writing it (H holds F's EX lock).
#   2. Requester R arms caw_inject_register_hard_n=3: each of its next three
#      swaps that write its waiter bit land and then fail every attempt with
#      -EIO.  R reads F (the lookup may hit the parent directory's lock
#      first).  Each hit ends at the hard-error exit, which reads the slot
#      back and logs P-CAW-REGISTER-HARD-EXIT waiter_bit_on_disk=0|1.
#      Whether R then shuts down depends on whether its retries are hit too:
#      without the fix a retry finds the orphan already registered, adopts
#      it and is granted, so the slot heals before anything later could see
#      it; the orphan does harm when no retry follows (a bounded caller, a
#      killed task, the last attempt).  So the exit's own read-back is the
#      measurement.
#   3. H stops writing.  Each hit inode's slot is read from the platter
#      (tools/caw_slotdump) after H's writer has released.
# Asserts:
#   P1 reach: every injection ended at the hard-error exit and was read back
#   P2 at every exit R's waiter bit is off the platter
#   P2b afterwards no hit slot carries R's waiter bits
#   P3 H, after dropping its cached lock, reads F within READ_BOUND s (a fresh
#      shared acquire is not deferred to a phantom exclusive waiter)
#   P4 no new kernel BUG/WARNING/Oops/hung task on either node; H not shut down
# R is left shut down; the caller remounts or re-preps it.
#
# Usage: tests/caw_register_hard_waiter.sh [H] [R]   (default test1 test2)
# Budget: setup ~5 s, the three failed attempts ~2 s (5 retries with 10-160 ms
# backoff each, 50 ms between attempts), H's release and slot read ~10 s, the
# read bound 10 s: ~30 s; run.sh-free, so the caller bounds it at 90 s.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSH="$REPO/tools/mxfs_sshpass.sh"
H="${1:-test1}"
R="${2:-test2}"
. "$(dirname "$0")/lib/rig.sh"
mxfs_dev_resolve "$H"; DEV=$MXFS_DEV_RESOLVED
MNT=/mnt/shared
DUMP=/src/mxfs/tools/caw_slotdump
KNOB=/sys/module/mxfs/parameters/caw_inject_register_hard_n
READ_BOUND=${READ_BOUND:-10}
F=$MNT/.crhw_$$
fail=0
on() { timeout "${3:-30}" "$SSH" "$1" "$2" </dev/null 2>/dev/null; }
ck() { if [ "$2" = 1 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

echo "=== caw_register_hard_waiter: H=$H R=$R dev=$DEV ==="
for h in "$H" "$R"; do
    [ "$(on "$h" "awk '\$2 == \"$MNT\" && \$3 == \"mxfs\" {print \"Y\"}' /proc/mounts")" = Y ] \
        || { echo "ABORT: $h has no mxfs mount at $MNT"; exit 2; }
    [ "$(on "$h" "[ -w $KNOB ] && echo Y")" = Y ] || { echo "ABORT: $h's module has no $KNOB"; exit 2; }
done
T0=$(on "$H" "date +%s")
T0R=$(on "$R" "date +%s")

# 1. H creates F and keeps writing it
on "$H" "dd if=/dev/urandom of=$F bs=64k count=16 conv=fsync 2>/dev/null; stat -c %i $F" > /dev/null
INO=$(on "$H" "stat -c %i $F")
[ -n "$INO" ] || { echo "ABORT: could not create $F on $H"; exit 2; }
on "$H" "nohup bash -c 'while [ ! -e /tmp/crhw.stop ]; do dd if=/dev/urandom of=$F bs=64k count=16 conv=notrunc,fsync 2>/dev/null; done' >/dev/null 2>&1 & echo started" > /dev/null
sleep 2
echo "--- F=$F ino=$INO; $H writing it"

# 2. R arms and reads F
on "$R" "echo 3 > $KNOB; cat $KNOB" > /dev/null
on "$R" "timeout 20 cat $F > /dev/null 2>&1; echo READ_RC=\$?" 25 | sed "s/^/  $R: /"
left=$(on "$R" "cat $KNOB")
on "$R" "echo 0 > $KNOB" > /dev/null
on "$H" "touch /tmp/crhw.stop" > /dev/null
on "$R" "journalctl -k --since @$T0R --no-pager -o cat" 30 > "/tmp/crhw.$R.log"
# the lookup may take the parent directory's lock before F's (H created F in
# it, so H holds that too): the inode under test is whichever the three
# registrations were for, and all three must be the same one
grep -oE 'P-CAW-REGISTER-HARD-(INJECT|EXIT) .*' "/tmp/crhw.$R.log" | sed 's/ -- .*//' | sed "s/^/  $R: /"
inj=$(grep -c 'P-CAW-REGISTER-HARD-INJECT' "/tmp/crhw.$R.log")
exits=$(grep -c 'P-CAW-REGISTER-HARD-EXIT' "/tmp/crhw.$R.log")
left_on=$(grep -c 'P-CAW-REGISTER-HARD-EXIT .*waiter_bit_on_disk=1' "/tmp/crhw.$R.log")
read_bad=$(grep 'P-CAW-REGISTER-HARD-EXIT' "/tmp/crhw.$R.log" | grep -vc 'read_rc=0 ')
inos=$(grep -o 'P-CAW-REGISTER-HARD-INJECT .* ino=[0-9]*' "/tmp/crhw.$R.log" | sed 's/.*ino=//' | sort -u)
self=$(grep -m1 -o 'P-CAW-REGISTER-HARD-INJECT .*self=0x[0-9a-f]*' "/tmp/crhw.$R.log" | sed 's/.*self=//')
down=$(grep -c 'DLM inode lock unrecoverable' "/tmp/crhw.$R.log")
echo "--- R: injections=$inj exits=$exits on ino(s) $(tr '\n' ' ' <<<"$inos")(knob left=$left) self=${self:-?} lock-error shutdowns=$down"
ck "P1 reach: $inj registrations hit on $R, each ended at the hard-error exit ($exits), each read back ($read_bad unread)" \
    "$([ "$inj" -ge 1 ] && [ "$exits" = "$inj" ] && [ "$read_bad" = 0 ] && [ -n "$self" ] && echo 1)"
ck "P2 at every hard-error exit $R's waiter bit is off the platter ($left_on left on)" "$([ "$left_on" = 0 ] && echo 1)"

# 3. H's writer stops and releases; each hit inode's slot from the platter
sleep 3
on "$H" "rm -f /tmp/crhw.stop" > /dev/null
hit=0
for INO in $inos; do
    row=$(on "$H" "$DUMP $DEV --type inode --max 200000 | grep -E ' ino=$INO '")
    [ -n "$row" ] || row="<none: the slot of ino $INO is empty>"
    echo "--- slot: $row"
    grep -q '^<none' <<<"$row" && row=""
    if [ -n "$self" ] && [ -n "$row" ]; then
        # waiter sets only: a holder bit of R's afterwards may be the lock
        # its successful retry really holds (P2 measures the orphan at the
        # exit, before any retry)
        for f in $(grep -oE '\b(wait|wait_ex)=0x[0-9a-f]+' <<<"$row"); do
            v=${f#*=}
            if [ $(( v & self )) -ne 0 ]; then echo "  $R's bit is in ino $INO's ${f%%=*}"; hit=1; fi
        done
    fi
done
ck "P2b afterwards no hit inode's slot carries any of $R's bits" "$([ -n "$self" ] && [ "$hit" = 0 ] && echo 1)"

# 4. H drops its cached lock and reads F again
on "$H" "sync; echo 3 > /proc/sys/vm/drop_caches" > /dev/null
t=$(on "$H" "s=\$(date +%s%N); timeout $READ_BOUND cat $F > /dev/null; rc=\$?; echo \$rc \$(( (\$(date +%s%N) - s) / 1000000 ))" $((READ_BOUND + 10)))
echo "--- $H re-read: rc and ms = $t"
ck "P3 $H reads F within ${READ_BOUND}s" "$([ "${t%% *}" = 0 ] && echo 1)"

# 5. kernel health
on "$H" "journalctl -k --since @$T0 --no-pager -o cat" 30 > "/tmp/crhw.$H.log"
# Every kernel fault prints one of these headers before its trace.  A bare
# Call Trace with dump_stack on top is a rig debug probe's own stack
# (mxfs_probe_stack, e.g. P131 when the survivor's replay barrier meets a
# committed AG buffer, which the next check retains): reported, not a fault.
bad=$(cat "/tmp/crhw.$H.log" "/tmp/crhw.$R.log" | grep -cE 'BUG:|WARNING:|Oops|blocked for more than|general protection|Kernel panic')
echo "--- probe stacks (dump_stack, not faults): $(cat "/tmp/crhw.$H.log" "/tmp/crhw.$R.log" | grep -c '^ dump_stack+')"
hsd=$(grep -cE 'Filesystem has been shut down|shutting down filesystem' "/tmp/crhw.$H.log")
ck "P4 no BUG/WARNING/Oops/hung task on either node ($bad), $H not shut down ($hsd)" \
    "$([ "$bad" = 0 ] && [ "$hsd" = 0 ] && echo 1)"
[ "$bad" = 0 ] || cat "/tmp/crhw.$H.log" "/tmp/crhw.$R.log" | grep -E 'BUG:|WARNING:|Oops|blocked for more than' | head -5

on "$H" "rm -f $F" > /dev/null
[ "$fail" = 0 ] && { echo "=== caw_register_hard_waiter PASS ==="; exit 0; }
echo "=== caw_register_hard_waiter FAIL ==="; exit 1
