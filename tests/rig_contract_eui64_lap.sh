#!/bin/bash
# rig_contract_eui64_lap.sh -- one lap of D-RIG-LIB-CONTRACT-ACCEPTED-ONLY-NAA-SO-AN-EUI-64-LUN-FAILED-11B-AND-13B:
# tests/rig_lib_contract.sh run as the release's presteps run it (tools/release_run.py
# presteps_env: MXFS_NODE_LIST, MXFS_GROUP and MXFS_MARKER of the pair g2 formed at
# 2/net/mesh/direct), on that pair's pool LUN, which carries an EUI-64 identifier.  Held to the
# NAA forms, check 11b counted no DEVICE line (its wwid begins eui.) and 13b handed the resolver a
# wwn-0x<id> alias udev never makes for an EUI-64 LUN, which aborted the contract; 13h, reached
# only past 13b, held its by-id link to the same wwn-0x form.
#
#   EXPOSED  test1's LUN reports an EUI-64 WWID (an NAA one passes either way)
#   PASS     the contract's checks 11b, 13b and 13h all PASS
#   FAIL     11b or 13h FAILs, or 13b FAILs or ABORTs the contract
#   ABORT    the contract stopped before it measured them (the rig needs a prep)
#
# MXFS_CONTRACT_EUI64 passes through: 0 holds the three checks to the NAA forms, the control.
#
# Bound, derived: the contract's own 300 s (its header: ~150 s measured with the unmount and
# remount of test2) and one read of test1's WWID (20 s); 330 s.
#
# Usage: tests/rig_contract_eui64_lap.sh <label>   (the pair g2 formed at 2/net/mesh/direct)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?usage: rig_contract_eui64_lap.sh <label>}
cd "$(dirname "$0")/.." || exit 2
. tests/lib/rig.sh
S=$(mktemp -d /tmp/mxfs_contract_eui64.XXXXXX) || { echo "CONTRACT_EUI64_LAP ABORT: no scratch directory"; exit 2; }
trap 'rm -rf -- "$S"' EXIT

wwid=$(rs 20 test1 "cat /sys/block/sda/device/wwid" | tail -1)
echo "INFO test1 sda wwid='$wwid' switch MXFS_CONTRACT_EUI64=${MXFS_CONTRACT_EUI64:-1}"
case $wwid in
    eui.*) echo "EXPOSED: test1's pool LUN is EUI-64 ($wwid)" ;;
    naa.*) echo "INFO the LUN is NAA: the lap cannot tell the forms apart" ;;
    *) echo "CONTRACT_EUI64_LAP ABORT: test1 reports no LUN identifier ('$wwid')"; exit 2 ;;
esac

env MXFS_NODE_LIST=test1,test2 MXFS_GROUP=g2 MXFS_MARKER="$PWD/.cluster_marker.g2.json" \
    timeout 300 tests/rig_lib_contract.sh "$LABEL" test1 < /dev/null > "$S/contract.out" 2>&1
rc=$?
grep -aE '^\s+(PASS|FAIL) (11b|13b|13h) |^ABORT: |^RESULT: ' "$S/contract.out" | cut -c1-300
# one verdict per check: PASS, FAIL, ABORT (the contract stopped at it) or none (not reached)
v() {
    local id=$1 line
    line=$(grep -aE "^\s+(PASS|FAIL) $id " "$S/contract.out" | head -1)
    case $line in
        *" PASS $id "*) echo PASS ;;
        *" FAIL $id "*) echo FAIL ;;
        *) grep -aq "^ABORT: '$id " "$S/contract.out" && echo ABORT || echo none ;;
    esac
}
r11b=$(v 11b); r13b=$(v 13b); r13h=$(v 13h)
echo "INFO contract rc=$rc 11b=$r11b 13b=$r13b 13h=$r13h ($(grep -a '^RESULT: ' "$S/contract.out" | tail -1 | cut -c1-200))"
if [ "$r11b" = FAIL ] || [ "$r13b" = FAIL ] || [ "$r13b" = ABORT ] || [ "$r13h" = FAIL ]; then
    echo "CONTRACT_EUI64_LAP FAIL 11b=$r11b 13b=$r13b 13h=$r13h on an LUN of wwid $wwid"
    exit 1
fi
if [ "$r11b" = PASS ] && [ "$r13b" = PASS ] && [ "$r13h" = PASS ]; then
    echo "CONTRACT_EUI64_LAP PASS 11b, 13b and 13h on an LUN of wwid $wwid"
    exit 0
fi
echo "CONTRACT_EUI64_LAP ABORT: the contract did not reach the three checks (11b=$r11b 13b=$r13b 13h=$r13h, rc=$rc)"
exit 2
