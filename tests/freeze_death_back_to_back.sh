#!/bin/bash
#
# freeze_death_back_to_back.sh — a platform's two freeze laps in the order
# tests/full_verify.sh runs them, with the victim's mount holders read between.
#
# D-FREEZE-TEST-LEAVES-VICTIM-DD-HOLDING-MOUNT-NEXT-PREP-FORMATS-UNDER-IT: after
# the 2/disk/caw/direct lap, full_verify's unmount found the fenced victim's
# mount still busy (left=1) and the 2/net/mesh/direct lap's prep failed on it
# (pve92 for 0.90.131; ubuntu2404 and rhel9 for 0.90.132).  This runs the same
# sequence and, between the laps, lists every task on each node with an fd or
# cwd under the mount, with its state, wait channel and kernel stack, then does
# full_verify's unmount and records what it leaves.
#
# Usage: MXFS_LAB=<a platform lab file> tests/freeze_death_back_to_back.sh <platform> [laps]
#   The lab file is the one tests/full_verify.sh writes for the platform
#   (~/.config/mxfslab/lab.<platform>): its set and its pool LUN.  laps
#   (default 1) repeats the pair of laps.
# Budget: each freeze lap ~90 s (prep 10 s + death 40-70 s + write + 20 s
# settle), the census and unmount seconds; the laps enforce their own.
#
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/tools/mxfs_lab.sh"
P=${1:?usage: $0 <platform> [laps]}
LAPS=${2:-1}
SSH="$HERE/tools/mxfs_sshpass.sh"
EV="$HERE/tests/evidence/freeze_death_back_to_back/$(date +%Y%m%dT%H%M%S)_$P"
mkdir -p "$EV"
exec > >(tee -a "$EV/run.log") 2>&1
SET=$(lab_nodes "$P") || exit 2
MNT=/mnt/mxfs
census() {  # <label>: every node's mount and the tasks holding it
    local h
    for h in $SET; do
        timeout 30 "$SSH" "$(lab_addr $h)" "
            echo \"$h mounted=\$(grep -c ' $MNT mxfs ' /proc/mounts) uptime=\$(cut -d' ' -f1 /proc/uptime)\"
            for p in /proc/[0-9]*; do
                x=\$( { readlink \$p/cwd; ls -l \$p/fd 2>/dev/null | sed 's/.*-> //'; } 2>/dev/null | grep -m1 '^$MNT')
                [ -n \"\$x\" ] && echo \"$h HOLDER pid=\${p#/proc/} comm=\$(cat \$p/comm) state=\$(cut -d' ' -f3 \$p/stat) ppid=\$(cut -d' ' -f4 \$p/stat) pgid=\$(cut -d' ' -f5 \$p/stat) wchan=\$(cat \$p/wchan) holds=\$x stack=\$(tr '\n' ' ' < \$p/stack 2>/dev/null | cut -c1-400)\"
            done; true" </dev/null 2>/dev/null | sed "s/^/[$1] /"
    done
}
rc_all=0
for lap in $(seq 1 "$LAPS"); do
    echo "=== lap $lap: 2/disk/caw/direct"
    CONFIG=2/disk/caw/direct PREP=$P "$HERE/tests/tcp_peer_freeze_death.sh"; echo "caw_lap_rc=$?"
    census after-caw-lap
    # tests/full_verify.sh unmount_pairs, verbatim in effect
    for h in $SET; do
        timeout 75 "$SSH" "$(lab_addr $h)" 'for m in $(grep " mxfs " /proc/mounts | cut -d" " -f2); do timeout 60 umount $m; done; echo left=$(grep -c " mxfs " /proc/mounts)' \
            </dev/null 2>&1 | grep -E 'left=|umount' | sed "s/^/$h /"
    done
    census after-unmount
    echo "=== lap $lap: 2/net/mesh/direct"
    CONFIG=2/net/mesh/direct PREP=$P "$HERE/tests/tcp_peer_freeze_death.sh"; r=$?; echo "tcp_lap_rc=$r"
    [ "$r" = 0 ] || rc_all=1
done
echo "done: $EV rc=$rc_all"
exit $rc_all
