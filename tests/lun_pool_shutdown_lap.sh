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
# The bind above is lun_pool.sh's single-path login.  The fix is in all three of
# its logins, and LP_BIND picks the other two (unset: the lap above, unchanged):
#
#   LP_BIND=paths2  the bind is `alloc --paths 2`, the multipath login every
#       */*/mpath configuration binds through (run.sh): a node record per
#       multipath portal, each session bound to a storage NIC, multipathd
#       assembling them as /dev/mapper/mpatha under tools/mpath_settings.sh
#       (replacement_timeout and no_path_retry far shorter than the
#       single-path chain's 120 s).  The pair must reach each portal through a
#       NIC of its own: an mpath-capable group.  Exposure: the recordless boot
#       with the unit inactive, as above, and after the bind /dev/mapper/mpatha
#       present on both nodes with at least two paths under it.
#       Bound: the same steps, the two-path login running inside the same 180 s
#       ssh bound per node and its map read joining the state read after the
#       bind: 1100 s.
#
#   LP_BIND=also    a plain bind, then a second LUN bound beside it with
#       `alloc --also` by the same owner, the login real runs use to mount two
#       filesystems on one host (tests/multi_mount.sh, scripts/drbd_rig.sh).
#       The first bind always runs with LUN_POOL_ISCSI_UNIT=0, so it leaves the
#       unit inactive as every bind did before the fix, and the --also login is
#       the only one that can start it: with the fix in, the first bind would
#       start the unit itself and the lap would say nothing about the --also
#       login.  Exposure: the recordless boot with the unit inactive, and after
#       the first bind both nodes logged in by hand (one record, one session)
#       with the unit still not active.  The --also bind must leave both nodes
#       with two records and two sessions.
#       Bound: the steps above, the free freeing up to two kept allocations
#       (60 s each, one after the other: +60 s), the state read after the first
#       bind (20 s per node, one node after the other: +40 s) and the second
#       bind (+180 s): 1100 + 60 + 40 + 180 = 1380 s.
#
# Each variant prints its own exposure line (LAP lunpool_shutdown <variant>
# exposed: ...) and the same PASS, FAIL and ABORT lines.  A variant's free step
# frees every allocation kept for exactly this pair, so the next lap's binds
# are fresh logins and not an adoption of the last lap's LUN.  A plain lap run
# on a pair an also lap left frees only one of its two kept allocations, and
# its bind can adopt the other without logging in; the lap then ABORTs or,
# worse, passes with no session, so run the also variant on a pair of its own
# or free the pair's allocations first.
#
# LUN_POOL_ISCSI_UNIT in the lap's environment reaches every bind it makes
# (tools/lun_pool.sh: 0 takes the fix out, the control), and the start line
# names it when it is set.
#
# Usage: [LP_BIND=paths2|also] [LUN_POOL_ISCSI_UNIT=0] tests/lun_pool_shutdown_lap.sh <node1> <node2>
# The nodes are left off.  Exit 0 PASS, 1 FAIL, 2 ABORT.
set -u
N1=${1:?node1}; N2=${2:?node2}
cd "$(dirname "$0")/.." || exit 2
. tests/lib/rig.sh
POOL=tools/lun_pool.sh
POWER=scripts/lab_power.sh
UNIT_STATE='u=""; for c in open-iscsi.service iscsi.service; do systemctl cat $c >/dev/null 2>&1 && { u=$c; break; }; done; echo "UNIT ${u:-none} $([ -n "$u" ] && systemctl is-active $u 2>/dev/null) records=$(ls /etc/iscsi/nodes 2>/dev/null | wc -l) sessions=$(iscsiadm -m session 2>/dev/null | grep -c iqn)"'
# the multipath map a two-path bind hands out, and the paths under it
# (lun_pool.sh's NODE_LOGIN_MP counts them the same way)
MAP_STATE='echo "MAP $([ -b /dev/mapper/mpatha ] && echo mpatha || echo none) paths=$(multipath -ll mpatha 2>/dev/null | grep -cE "[0-9]+:[0-9]+:[0-9]+:[0-9]+ +sd[a-z]+ ")"'
BIND=${LP_BIND:-}
case "$BIND" in ""|paths2|also) ;; *) echo "LAP lunpool_shutdown ABORT: LP_BIND is paths2, also or unset, not '$BIND'"; exit 2 ;; esac
# kept allocations the free step frees: the plain lap's one, as it always has;
# a variant's every one bound to this pair (the also lap makes two)
NFREE=1; [ -n "$BIND" ] && NFREE=3

echo "LAP lunpool_shutdown start $(date -u +%FT%TZ) pair=$N1,$N2${BIND:+ bind=$BIND}${LUN_POOL_ISCSI_UNIT+ LUN_POOL_ISCSI_UNIT=$LUN_POOL_ISCSI_UNIT}"
timeout 250 $POWER up "$N1" "$N2" > /dev/null 2>&1 || { echo "LAP lunpool_shutdown ABORT: the pair did not boot before the lap"; exit 2; }
for i in $(seq "$NFREE"); do
    kept=$($POOL lookup --nodes "$N1,$N2" 2>/dev/null | sed -n 's/^POOL_LUN id=\([0-9]*\).*/\1/p' | head -1)
    [ -n "$kept" ] || break
    timeout 60 $POOL free "$kept" --force > /dev/null 2>&1 || { echo "LAP lunpool_shutdown ABORT: could not free lun$kept, kept for $N1,$N2"; exit 2; }
    echo "  INFO freed lun$kept, kept for this pair"
done
if [ -n "$BIND" ] && [ -n "$($POOL lookup --nodes "$N1,$N2" 2>/dev/null | grep -a '^POOL_LUN ')" ]; then
    echo "LAP lunpool_shutdown ABORT: an allocation is still kept for $N1,$N2 after $NFREE frees"; exit 2
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
if [ -z "$BIND" ]; then
    echo "LAP lunpool_shutdown exposed: both nodes booted with no node record and the iSCSI unit inactive"
else
    echo "  INFO both nodes booted with no node record and the iSCSI unit inactive"
fi

case "$BIND" in
    "")
        line=$(timeout 400 $POOL alloc --owner $$ --what "lun_pool_shutdown_lap" "$N1" "$N2" 2>&1 | grep -a '^POOL_LUN ' | tail -1)
        [ -n "$line" ] || { echo "LAP lunpool_shutdown ABORT: the bind failed"; exit 2; }
        echo "  INFO bound: $(echo "$line" | cut -c1-200)"
        for n in "$N1" "$N2"; do
            s=$(rs 20 "$n" "$UNIT_STATE" | grep -a '^UNIT ' | tail -1)
            echo "  INFO $n after the bind: ${s:-unreachable}"
        done ;;
    paths2)
        line=$(timeout 400 $POOL alloc --paths 2 --owner $$ --what "lun_pool_shutdown_lap paths2" "$N1" "$N2" 2>&1 | grep -a '^POOL_LUN ' | tail -1)
        [ -n "$line" ] || { echo "LAP lunpool_shutdown ABORT: the two-path bind failed"; exit 2; }
        echo "  INFO bound: $(echo "$line" | cut -c1-200)"
        case "$line" in *" dev=/dev/mapper/mpatha "*) ;; *) echo "LAP lunpool_shutdown ABORT: the two-path bind handed out no /dev/mapper/mpatha"; exit 2 ;; esac
        mapped=1
        for n in "$N1" "$N2"; do
            out=$(rs 20 "$n" "$UNIT_STATE; $MAP_STATE")
            s=$(echo "$out" | grep -a '^UNIT ' | tail -1)
            m=$(echo "$out" | grep -a '^MAP ' | tail -1)
            echo "  INFO $n after the bind: ${s:-unreachable} ${m:-MAP unread}"
            case "$m" in "MAP mpatha paths="[2-9]|"MAP mpatha paths="[1-9][0-9]) ;; *) mapped=0 ;; esac
        done
        [ "$mapped" = 1 ] || { echo "LAP lunpool_shutdown ABORT: not exposed (a node has no /dev/mapper/mpatha on two paths after the bind)"; exit 2; }
        echo "LAP lunpool_shutdown paths2 exposed: both nodes booted with no node record and the iSCSI unit inactive, and the bind assembled /dev/mapper/mpatha on two paths" ;;
    also)
        line=$(LUN_POOL_ISCSI_UNIT=0 timeout 400 $POOL alloc --owner $$ --what "lun_pool_shutdown_lap also, first bind" "$N1" "$N2" 2>&1 | grep -a '^POOL_LUN ' | tail -1)
        [ -n "$line" ] || { echo "LAP lunpool_shutdown ABORT: the first bind failed"; exit 2; }
        echo "  INFO first bound (LUN_POOL_ISCSI_UNIT=0): $(echo "$line" | cut -c1-200)"
        exposed=1
        for n in "$N1" "$N2"; do
            s=$(rs 20 "$n" "$UNIT_STATE" | grep -a '^UNIT ' | tail -1)
            echo "  INFO $n after the first bind: ${s:-unreachable}"
            case "$s" in "UNIT "*" records=1 sessions=1") ;; *) exposed=0 ;; esac
            case "$s" in *" active records="*) exposed=0 ;; esac
        done
        [ "$exposed" = 1 ] || { echo "LAP lunpool_shutdown ABORT: not exposed (after the first bind a node is not logged in by hand on one session with its unit inactive)"; exit 2; }
        echo "LAP lunpool_shutdown also exposed: after a recordless boot the first bind left both nodes logged in by hand with the iSCSI unit inactive"
        line=$(timeout 400 $POOL alloc --also --owner $$ --what "lun_pool_shutdown_lap also, --also bind" "$N1" "$N2" 2>&1 | grep -a '^POOL_LUN ' | tail -1)
        [ -n "$line" ] || { echo "LAP lunpool_shutdown ABORT: the --also bind failed"; exit 2; }
        echo "  INFO bound --also: $(echo "$line" | cut -c1-200)"
        beside=1
        for n in "$N1" "$N2"; do
            s=$(rs 20 "$n" "$UNIT_STATE" | grep -a '^UNIT ' | tail -1)
            echo "  INFO $n after the --also bind: ${s:-unreachable}"
            case "$s" in "UNIT "*" records=2 sessions=2") ;; *) beside=0 ;; esac
        done
        [ "$beside" = 1 ] || { echo "LAP lunpool_shutdown ABORT: the --also bind did not leave both nodes with two records and two sessions"; exit 2; } ;;
esac

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
