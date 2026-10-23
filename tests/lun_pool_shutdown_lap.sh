#!/bin/bash
# lun_pool_shutdown_lap.sh -- one lap of D-LUN-POOL-HAND-LOGIN-AFTER-A-RECORDLESS-BOOT-IS-NEVER-LOGGED-OUT-AT-SHUTDOWN:
# a pair that booted with no iSCSI node record is bound to a pool LUN by
# tools/lun_pool.sh and then shut down as scripts/lab_power.sh does it.
#
# A node that boots with no node record skips the distribution's iSCSI login
# unit (its condition is a non-empty node directory), and that unit's stop is
# what logs every session out before the network goes.  A bind logs the node in
# by hand.  Unless the bind starts the unit, the session is still up when
# systemd takes the network down; lvm2-monitor's stop then reads the LUN, a
# device that arrived after its boot-time hints, through the dead path and
# waits out the session's 120 s replacement timeout, so the node overruns
# lab_power.sh's 90 s shutdown bound and is destroyed
# (tests/fourkn_lun_shutdown_probe.sh found the chain on the 4K-native LUN).
#
# Each lap: the pair is powered on; the allocation bound to exactly this pair,
# if one is kept, is freed, and every node record left on either node is
# deleted, both while the nodes are up (a free of a pair the last lap left off
# could not reach them, and they booted with the old record and the unit
# active); the pair is powered off and on, so both boot with no record; the lap
# reads, on each node, the node record count and the unit's state (exposure: no
# record, no session, the unit not active); a 512-byte pool LUN is allocated to
# the pair; the unit's state is read again; the pair is powered down with
# lab_power.sh, and its log says for each node whether the ACPI shutdown
# finished or the node was destroyed.
#
#   PASS  exposed, and both nodes shut off within lab_power.sh's bound
#   FAIL  exposed, and a node overran the bound and was destroyed
#   ABORT not exposed, or a free, power or bind step failed (measured nothing)
#
# Bound, derived from the steps' own bounds: power up 240 s (lab_power.sh
# BOOT_S, nodes in parallel), free 60 s (one ssh logout per node, in
# parallel), the record deletes 20 s, power down from running 180 s
# (lab_power.sh: 75 s for the unmounts, 90 s to the destroy, its 30 s domstate
# reads overlapping), power up again 240 s, the bind 180 s (the pool's ssh
# bound per node, in parallel), power down again 180 s:
# 240 + 60 + 20 + 180 + 240 + 180 + 180 = 1100 s.
#
# Usage: tests/lun_pool_shutdown_lap.sh <node1> <node2>
# The nodes are left off.  Exit 0 PASS, 1 FAIL, 2 ABORT.
set -u
N1=${1:?node1}; N2=${2:?node2}
cd "$(dirname "$0")/.." || exit 2
. tests/lib/rig.sh
POOL=tools/lun_pool.sh
POWER=scripts/lab_power.sh
UNIT_STATE='u=""; for c in open-iscsi.service iscsi.service; do systemctl cat $c >/dev/null 2>&1 && { u=$c; break; }; done; echo "UNIT ${u:-none} $([ -n "$u" ] && systemctl is-active $u 2>/dev/null) records=$(ls /etc/iscsi/nodes 2>/dev/null | wc -l) sessions=$(iscsiadm -m session 2>/dev/null | grep -c iqn)"'

echo "LAP lunpool_shutdown start $(date -u +%FT%TZ) pair=$N1,$N2"
timeout 250 $POWER up "$N1" "$N2" > /dev/null 2>&1 || { echo "LAP lunpool_shutdown ABORT: the pair did not boot before the lap"; exit 2; }
kept=$($POOL lookup --nodes "$N1,$N2" 2>/dev/null | sed -n 's/^POOL_LUN id=\([0-9]*\).*/\1/p' | head -1)
if [ -n "$kept" ]; then
    timeout 60 $POOL free "$kept" --force > /dev/null 2>&1 || { echo "LAP lunpool_shutdown ABORT: could not free lun$kept, kept for $N1,$N2"; exit 2; }
    echo "  INFO freed lun$kept, kept for this pair"
fi
for n in "$N1" "$N2"; do
    r=$(rs 20 "$n" "iscsiadm -m node -u >/dev/null 2>&1; iscsiadm -m node -o delete >/dev/null 2>&1; echo RECORDS \$(ls /etc/iscsi/nodes 2>/dev/null | wc -l)" | grep -a '^RECORDS ')
    [ "$r" = "RECORDS 0" ] || { echo "LAP lunpool_shutdown ABORT: $n still has node records after the delete [${r:-unreachable}]"; exit 2; }
done
timeout 180 $POWER down "$N1" "$N2" > /dev/null 2>&1 || { echo "LAP lunpool_shutdown ABORT: the pair did not power off before the lap"; exit 2; }
timeout 250 $POWER up "$N1" "$N2" > /dev/null 2>&1 || { echo "LAP lunpool_shutdown ABORT: the pair did not boot"; exit 2; }

exposed=1
for n in "$N1" "$N2"; do
    s=$(rs 20 "$n" "$UNIT_STATE" | grep -a '^UNIT ' | tail -1)
    echo "  INFO $n after boot: ${s:-unreachable}"
    case "$s" in "UNIT "*" records=0 sessions=0") ;; *) exposed=0 ;; esac
    case "$s" in *" active records="*) exposed=0 ;; esac
done
[ "$exposed" = 1 ] || { echo "LAP lunpool_shutdown ABORT: not exposed (a node booted with a node record, a session or its unit active)"; exit 2; }
echo "LAP lunpool_shutdown exposed: both nodes booted with no node record and the iSCSI unit inactive"

line=$(timeout 400 $POOL alloc --owner $$ --what "lun_pool_shutdown_lap" "$N1" "$N2" 2>&1 | grep -a '^POOL_LUN ' | tail -1)
[ -n "$line" ] || { echo "LAP lunpool_shutdown ABORT: the bind failed"; exit 2; }
echo "  INFO bound: $(echo "$line" | cut -c1-200)"
for n in "$N1" "$N2"; do
    s=$(rs 20 "$n" "$UNIT_STATE" | grep -a '^UNIT ' | tail -1)
    echo "  INFO $n after the bind: ${s:-unreachable}"
done

plog=$(timeout 200 $POWER down "$N1" "$N2" 2>&1)
echo "$plog" | grep -a "$N1\|$N2" | sed 's/^/  POWER /'
destroyed=$(echo "$plog" | grep -ac 'still up after .* destroying')
off=$(echo "$plog" | grep -ac ': off after ')
if [ "$destroyed" -gt 0 ]; then
    echo "LAP lunpool_shutdown FAIL: $destroyed node(s) overran the shutdown bound and were destroyed"
    exit 1
fi
[ "$off" = 2 ] || { echo "LAP lunpool_shutdown ABORT: the power-down log shows $off node(s) off and none destroyed"; exit 2; }
echo "LAP lunpool_shutdown PASS: both nodes shut off within the bound"
exit 0
