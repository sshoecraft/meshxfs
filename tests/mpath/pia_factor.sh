#!/bin/bash
# tests/mpath/pia_factor.sh — which one difference between a prepped node and a
# freshly booted one makes a frozen initiator's writes stay held after a peer's
# PREEMPT AND ABORT (D-FENCED-VICTIM-WITHDRAW-HANGS-IN-SHUTDOWN-LOG-FORCE).
#
# Measured with tests/mpath/tas_pia_ab.sh: a preempt_abort_inflight lap held
# the victim's writes past its 200 s window on 8 of 8 laps run right after a
# prep, and on 0 of 6 laps run right after a victim reset.  The victim's state
# in the two cases differed in its SCSI command timeout (prep writes 180, a
# fresh boot has 30), in mxfs.ko being loaded, and in its uptime at the lap
# (~75 s after a prep, ~22 s after a reset).
#
# Each lap resets the victim, waits for both of its paths and for an uptime of
# PF_UPTIME_FLOOR_S (so uptime is the same in every arm), applies ONE factor,
# then runs one tests/mpath/preempt_abort_inflight.sh lap:
#   none     nothing
#   t180     every SCSI path of the LUN gets a 180 s command timeout
#   insmod   mxfs.ko from the tree is loaded (no mount)
#   both     t180 and insmod
#
# Usage: tests/mpath/pia_factor.sh <label> <factor,factor,...> [group=g2b]
#   e.g. tests/mpath/pia_factor.sh f1 none,t180,insmod,t180,insmod,none
# Budget per lap: reset 120 s + uptime floor + the probe (PIA_WAIT_S 200 s + ~40 s).
# The LUN is overwritten: re-prep the group afterwards.
set -u
LABEL=${1:?label}; FACTORS=${2:?factors}; GROUP=${3:-g2b}
UPFLOOR=${PF_UPTIME_FLOOR_S:-75}
cd "$(dirname "$0")/../.." || exit 2
SSH=tools/mxfs_sshpass.sh
VIRSH="virsh -c qemu:///system"
set -- $(tools/mxfs_lab.sh group "$GROUP")
[ $# -ge 2 ] || { echo "group $GROUP has fewer than 2 nodes"; exit 2; }
S=$1; eval "V=\${$#}"
OUT=tests/evidence/pia_factor_$LABEL
mkdir -p "$OUT"
rsx() { local t=$1 n=$2; shift 2; timeout "$t" $SSH "$n" "$*" 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
. tests/lib/runlock.sh
vmhold_take pia_factor "$@" || { echo "RESULT: ABORT pia_factor $LABEL -- could not hold $*"; exit 2; }
[ -f mxfs.ko ] || { echo "RESULT: ABORT pia_factor $LABEL -- no mxfs.ko in the tree"; exit 2; }
KO_MD5=$(md5sum mxfs.ko | cut -d' ' -f1)
reset_victim() {
    timeout 60 $VIRSH destroy "$V" >/dev/null 2>&1
    timeout 60 $VIRSH start "$V" >/dev/null 2>&1 || return 1
    local i
    for i in $(seq 1 30); do
        [ "$(rsx 8 "$V" "multipath -ll 2>/dev/null | grep -c 'active ready running'")" = 2 ] && return 0
        sleep 4
    done
    return 1
}
apply() {
    case "$1" in
        none) ;;
        t180) rsx 20 "$V" "for s in /sys/block/\$(basename \$(readlink -f /dev/mapper/mpatha))/slaves/*; do echo 180 > \$s/device/timeout; done" ;;
        insmod) rsx 60 "$V" "modprobe libcrc32c 2>/dev/null; cp -f /src/mxfs/mxfs.ko /root/mxfs.ko.pf && [ \$(md5sum < /root/mxfs.ko.pf | cut -d' ' -f1) = $KO_MD5 ] && insmod /root/mxfs.ko.pf; echo insmod_rc=\$?" ;;
        both) apply t180; apply insmod ;;
        *) echo "unknown factor $1"; return 1 ;;
    esac
}
state_of() {
    rsx 20 "$V" "echo uptime=\$(cut -d' ' -f1 /proc/uptime) mxfs=\$(grep -c '^mxfs ' /proc/modules); for s in /sys/block/\$(basename \$(readlink -f /dev/mapper/mpatha))/slaves/*; do echo \$(basename \$s) timeout=\$(cat \$s/device/timeout); done" | tr '\n' ' '
}
l=0
for f in ${FACTORS//,/ }; do
    l=$(( l + 1 ))
    reset_victim || { echo "lap $l $f: ABORT -- $V's two paths did not come back"; continue; }
    while :; do
        up=$(rsx 8 "$V" "cut -d. -f1 /proc/uptime"); [ "${up:-0}" -ge "$UPFLOOR" ] && break; sleep 3
    done
    apply "$f" > "$OUT/apply_lap$l.txt" 2>&1
    st=$(state_of)
    r=$(tests/mpath/preempt_abort_inflight.sh "${LABEL}l$l$f" "$V" "$S" 2>&1 | tee "$OUT/lap$l.txt" | grep -a '^RESULT' | tail -1)
    ev=$(sed -n 's/.*evidence=\([^ ]*\).*/\1/p' <<<"$r")
    fails=$(grep -ac 'reservation conflict error, dev dm' "$ev/kmsg_$V.txt" 2>/dev/null)
    pa=$(sed -n 's/.*preempt=\([0-9]*\)\.\..*/\1/p' "$OUT/lap$l.txt" | head -1)
    caught="?"
    if [ -n "$pa" ]; then
        journalctl -k --since "@$(( pa / 1000 - 1 ))" --until "@$(( pa / 1000 + 3 ))" --no-pager > "$OUT/host_lap$l.txt" 2>/dev/null
        caught=$(awk '/Aborting task set/{t=1} /Resetting LUN/{t=0} /Aborted cmd/{if (t) c++} END{print c+0}' "$OUT/host_lap$l.txt")
    fi
    echo "lap $l factor=$f [$st] ${r#RESULT: MEASURED preempt_abort_inflight } dm_conflicts=${fails:-?} preempt_caught=$caught$([ "$caught" = 0 ] && echo ' VACUOUS')"
done
echo "RESULT: pia_factor label=$LABEL factors=$FACTORS evidence=$OUT (re-prep $GROUP before using it again)"
