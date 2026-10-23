#!/bin/bash
# recov_bmbt_reuse_abort_lap.sh -- one lap of D-RECOV-BMBT-REUSE-ABORT-LEAVES-THE-DESTROYED-VICTIM-POWERED-OFF:
# tests/recov_bmbt_reuse.sh ends in an ABORT after it has destroyed its victim,
# and the victim must be running again, with the tree on /src, when it exits.
#
# The lap is the capture gate's fault lap of that one entry
# (tests/capture_fault_gate.sh with tests/recov_bmbt_reuse_abort.manifest): the
# gate forms the pair when the last lap left it unformed (a victim powered off
# included), then runs the harness with MXFS_FAULT_RSX_NTH=1, so its first
# measurement, the kernel log after V's death, fails and the harness aborts.
# The harness destroys V before that measurement, so a lap is exposed when its
# log shows the destroy before the injection.  After the gate, the lap reads V
# itself: libvirt's state, ssh, and /src mounted.
#
#   PASS  exposed, and V is running, answers ssh and has /src
#   FAIL  exposed, and V is off, does not answer, or has no /src
#   ABORT the gate could not form the pair, or the abort came before the destroy
#
# Bound, derived: the gate's pair formation (a started VM answers ssh in
# 40-90 s, bounded 120 s; prep_cluster's manifest budget 300 s) + the fault
# lap's manifest bound 360 s, which includes the harness's own restore (120 s
# to ssh, 60 s to mount /src) + this lap's reads (ssh 10 s, /src 10 s) = 800 s.
#
# Usage: tests/recov_bmbt_reuse_abort_lap.sh <label>   (the pair is test1/test2: MXFS_GROUP=g2)
# Exit: 0 PASS, 1 FAIL, 2 ABORT (measured nothing).
set -u
LABEL=${1:?label}
cd "$(dirname "$0")/.." || exit 2
V=test2
VIRSH="sudo -n virsh -c qemu:///system"
. tests/lib/rig.sh

echo "LAP rbr_abort start $(date -u +%FT%TZ) label=$LABEL victim=$V"
glog=$(mktemp)
timeout -k 10 790 tests/capture_fault_gate.sh "rbrabort_$LABEL" tests/recov_bmbt_reuse_abort.manifest < /dev/null > "$glog" 2>&1
grc=$?
grep -a '^GATE \|^RESULT: \|^ABORT' "$glog" | cut -c1-240
out=$(sed -n 's/.*evidence=\([^ ]*\).*/\1/p' "$glog" | tail -1)
rm -f "$glog"
[ "$grc" = 124 ] && { echo "LAP rbr_abort FAIL: the gate overran its 790 s share of the lap's bound"; exit 1; }
flog=$(ls "$out"/*recov_bmbt_reuse*_fault.log 2>/dev/null | head -1)
[ -n "$flog" ] || { echo "LAP rbr_abort ABORT: no fault-lap log under [$out] (gate rc=$grc): the pair was not formed or the entry did not run"; exit 2; }
dl=$(grep -an "INFO virsh destroy $V rc=0" "$flog" | head -1 | cut -d: -f1)
fl=$(grep -an 'STAGE FAULT:' "$flog" | head -1 | cut -d: -f1)
if [ -z "$dl" ] || [ -z "$fl" ] || [ "$dl" -gt "$fl" ]; then
    echo "LAP rbr_abort ABORT: not exposed (destroy at line [${dl:-none}], injection at line [${fl:-none}] of $flog)"
    exit 2
fi
echo "LAP rbr_abort exposed: $V destroyed at line $dl, the injected abort at line $fl of $flog"
grep -a '^CLEANUP' "$flog" | cut -c1-200

st=$($VIRSH domstate "$V" 2>&1 | head -1)
ssh_ok=$(rs 10 "$V" "echo SSH_UP" 2>/dev/null | grep -c SSH_UP)
src_ok=$(rs 10 "$V" "mountpoint -q /src && echo SRC_OK" 2>/dev/null | grep -c SRC_OK)
echo "LAP rbr_abort $V state=[$st] ssh=$ssh_ok src=$src_ok"
if [ "$st" = running ] && [ "$ssh_ok" = 1 ] && [ "$src_ok" = 1 ]; then
    echo "LAP rbr_abort PASS: $V is running with /src after the harness aborted past its destroy"
    exit 0
fi
echo "LAP rbr_abort FAIL: $V state=[$st] ssh=$ssh_ok src=$src_ok after the harness aborted past its destroy"
exit 1
