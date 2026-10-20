#!/bin/bash
#
# release_followon.sh — the release steps that come after the rig chain, run
# only when every step of the chain passed: the DRBD release verification,
# then the Proxmox VE 9 SAN suite on each claimed kernel, all on the module
# the chain verified.
#
# WHY.  tests/release_verify_chain.sh holds every rig VM for hours; the DRBD
# rig (group g2) and the three nested Proxmox hosts cannot run beside it
# without sharing the host's memory and the one NVMe that carries every LUN,
# which is how timing rows fail for the host's sake.  Run after it, unattended,
# they keep the release moving without a session having to start each one.
# Beside each other they are five guests (g2's two at 4 GiB, the three Proxmox
# hosts at 8 GiB: 32 GiB of the host's 94) on a host the chain has powered
# down, so the DRBD verification runs alongside the Proxmox suite instead of
# ahead of it: run one after the other, 0.90.130's took 52 + 60 + 63 minutes.
#
# WHAT IT DOES
#  1. waits for RELEASE_CHAIN_DONE in tests/evidence/release_verify_<V>.log,
#     newer than that log's newest "=== release_verify_chain <V>" line, for at
#     most <chain-bound-s>: the chain's own derived bound, never a guess.
#     Reaching it is a refusal, never a start.
#  2. requires every "=== rc=N:" line of that chain run to read rc=0, except
#     its window laps ("w <configuration> lap i/n"): a window lap exits 1
#     whenever the board still shows the FLAKY cell it is there to age out,
#     with every row of its own passing, and the boards that follow read every
#     lap back, so a lap whose rows failed fails a board here.  Anything else
#     ends here with FOLLOWON verdict=FAIL and the rig left alone: a failed
#     chain step is read before anything else runs.
#  3. MXFS_GROUP=g2 tests/drbd_release_verify.sh <V> in the background, whose
#     last line must be "DRBD_RELEASE_VERIFY PASS version=<V> ...".
#  4. meanwhile scripts/pve_suite_on_kernel.sh <kernel> <label> for each kernel
#     given, in order, the VMs left up between kernels and shut down after the
#     last; each must exit 0 (SUITE: PASS).  A failed kernel ends the suite,
#     and the DRBD verification is still waited for, so both verdicts are
#     logged before FOLLOWON-END.
#  Every step enforces its own budget; nothing here wraps one in a timeout.
#
# Log: tests/evidence/release_followon_<V>.log, lines FOLLOWON-BEGIN,
# FOLLOWON-CHAIN, FOLLOWON-DRBD, FOLLOWON-PVE and FOLLOWON-END.
#
# Usage: nohup setsid tests/release_followon.sh <V> <chain-bound-s> <kernel>... \
#            > tests/evidence/release_followon_<V>.out 2>&1 < /dev/null &
set -u
V=${1:?version}
BOUND=${2:?chain bound in seconds}
shift 2
[ $# -ge 1 ] || { echo "at least one Proxmox kernel is required" >&2; exit 2; }
cd "$(dirname "$0")/.." || exit 2
L=tests/evidence/release_followon_$V.log
CL=tests/evidence/release_verify_$V.log
say() { echo "$(date -u +%FT%TZ) $*" | tee -a "$L"; }

say "FOLLOWON-BEGIN version=$V chain_bound=${BOUND}s kernels=[$*]"
[ -r "$CL" ] || { say "FOLLOWON-END verdict=FAIL reason=no chain log $CL"; exit 1; }

# the newest chain run in the log, and its end
chain_run() { awk -v v="$V" 'index($0, "=== release_verify_chain " v " ") == 1 { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$CL"; }
t0=$(date +%s)
while ! chain_run | grep -q '^RELEASE_CHAIN_DONE '; do
    if [ $(( $(date +%s) - t0 )) -ge "$BOUND" ]; then
        say "FOLLOWON-END verdict=FAIL reason=chain not done within ${BOUND}s"
        exit 1
    fi
    sleep 60
done
bad=$(chain_run | grep -E '^=== rc=[0-9]+:' | grep -v -E '^=== rc=0:' | grep -v -E '^=== rc=[0-9]+: w [0-9]+/[a-z]+/[a-z]+/[a-z]+ lap [0-9]+/[0-9]+ ' | head -5)
steps=$(chain_run | grep -c -E '^=== rc=[0-9]+:')
if [ -n "$bad" ]; then
    say "FOLLOWON-CHAIN verdict=FAIL steps=$steps first_failures:"
    echo "$bad" | tee -a "$L"
    say "FOLLOWON-END verdict=FAIL reason=chain step failed"
    exit 1
fi
say "FOLLOWON-CHAIN verdict=PASS steps=$steps"

MXFS_GROUP=g2 tests/drbd_release_verify.sh "$V" > "tests/evidence/drbd_release_verify_$V.launch.log" 2>&1 &
drbd_pid=$!
say "FOLLOWON-DRBD started pid=$drbd_pid, beside the Proxmox suite"

short=${V//./}
n=$#
i=0
pve_fail=""
for k in "$@"; do
    i=$((i + 1))
    label="v${short}k$(echo "$k" | cut -d- -f1 | tr -d .)"
    shut=0
    [ "$i" -eq "$n" ] && shut=1
    SHUTDOWN=$shut scripts/pve_suite_on_kernel.sh "$k" "$label" >> "tests/evidence/pve_suite_$V.chain.log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        say "FOLLOWON-PVE kernel=$k label=$label verdict=FAIL rc=$rc"
        pve_fail=$k
        break
    fi
    say "FOLLOWON-PVE kernel=$k label=$label verdict=PASS"
done

wait "$drbd_pid"
rc=$?
last=$(tail -n 1 "tests/evidence/drbd_release_verify_$V.out" 2>/dev/null)
drbd_ok=0
case $last in
    "DRBD_RELEASE_VERIFY PASS version=$V "*) drbd_ok=1; say "FOLLOWON-DRBD verdict=PASS rc=$rc $last" ;;
    *) say "FOLLOWON-DRBD verdict=FAIL rc=$rc last=[$last]" ;;
esac
if [ "$drbd_ok" = 0 ] || [ -n "$pve_fail" ]; then
    say "FOLLOWON-END verdict=FAIL reason=${pve_fail:+pve $pve_fail }$([ "$drbd_ok" = 0 ] && echo drbd)"
    exit 1
fi
say "FOLLOWON-END verdict=PASS"
