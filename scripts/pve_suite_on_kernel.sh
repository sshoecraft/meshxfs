#!/bin/bash
#
# pve_suite_on_kernel.sh <kernel> <label> — the Proxmox VE 9 SAN suite on the
# nested hosts pve9-5/6/7, booted into one claimed kernel, with this tree's
# module: what tools/release_status.py needs for each "Proxmox VE 9 hosts on a
# multipath SAN, kernel <k>" row, one run per kernel.
#
#   1. hold the three VMs in the VM pool for the whole run and start the ones
#      that are off
#   2. on every host not already running <kernel>: install it (with its
#      headers, which DKMS and the tree build need), pin it with
#      proxmox-boot-tool and reboot into it
#   3. scripts/pve_tree_install.sh (the tree built and loaded on every host)
#   4. scripts/pve_mxfs_san_disk.sh join (mount the existing LUN; never `up`,
#      which reformats it and loses template VM 9000)
#   5. scripts/pve_full_suite.sh <label>, whose last line is SUITE: PASS|FAIL
#
# Usage: scripts/pve_suite_on_kernel.sh 7.0.14-24-pve v130k70
#        scripts/pve_suite_on_kernel.sh 6.17.2-1-pve v130k617
# Env:   SHUTDOWN=1  power the three VMs off at the end (default 1; 0 leaves
#                    them up for a second kernel's run)
#
# Bounds, measured on the 0.90.129 runs: the VMs answer ssh ~20 s after a
# start and a reboot takes ~60 s (bound 240 s each); the kernel install is an
# apt download of ~150 MB (bound 600 s); the tree install measured under 7 min
# per host (its own BUILD_BUDGET, 960 s here as then); join 400 s as then.  The
# suite enforces its own per-step budgets and is not wrapped.
#
# Output: tests/evidence/pve_suite_on_kernel_<label>.log (this script's steps)
# and tests/evidence/pve_full_suite_<label>.out (the suite).  Exit status is
# the suite's.

set -u
K=${1:?usage: $0 <kernel> <label>}
LABEL=${2:?usage: $0 <kernel> <label>}
SHUTDOWN=${SHUTDOWN:-1}
REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO" || exit 1
. tests/lib/runlock.sh
VMS="pve9-5 pve9-6 pve9-7"
HOSTS="192.168.120.213 192.168.120.214 192.168.120.215"
SAN_DEV=/dev/disk/by-id/dm-uuid-mpath-23335366365663866
VIRSH="sudo virsh -c qemu:///system"
L=tests/evidence/pve_suite_on_kernel_$LABEL.log
SSH=tools/mxfs_sshpass.sh

say() { echo "$(date -u +%FT%TZ) $*" | tee -a "$L"; }
on() { timeout "$2" "$SSH" "$1" "$3" < /dev/null 2>&1 | grep -av -E 'Warning: Permanently|Unauthorized access|authorized user'; }
krel() {	# <host>: the host's running kernel release, or nothing (an ssh error
	# line is not an answer: `on` carries ssh's own stderr)
    on "$1" 8 'uname -r' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-' | tail -1
}
wait_ssh() {	# <host> <bound-s> [<kernel>] -> 0 once it answers (on <kernel>)
    local s=$SECONDS r
    while [ $((SECONDS - s)) -lt "$2" ]; do
        r=$(krel "$1")
        if [ -n "$r" ] && { [ -z "${3:-}" ] || [ "$r" = "$3" ]; }; then return 0; fi
        sleep 5
    done
    return 1
}

: > "$L"
# The rig's run lock, taken shared as a group run takes it: a whole-rig run.sh
# then waits for this suite, and this suite does not start under one.  It used
# to take nothing, and its SCST target changes landed beside running boards.
runlock_take "$RUNLOCK" shared "pve_suite_on_kernel $LABEL" 0 \
    || { say "FAIL: the rig's run lock is held exclusively: $(runlock_holder "$RUNLOCK")"; exit 1; }
scripts/clyde_preflight.sh >> "$L" 2>&1 || { say "FAIL: the host-safety preflight failed (scripts/clyde_preflight.sh; the lines above)"; exit 3; }
vmhold_take "pve_suite_on_kernel $LABEL" $VMS || { say "FAIL: could not hold [$VMS] in the VM pool"; exit 1; }
say "=== pve_suite_on_kernel kernel=$K label=$LABEL tree=$(cat VERSION) ==="
for v in $VMS; do
    [ "$($VIRSH domstate "$v" 2>/dev/null)" = running ] || $VIRSH start "$v" >> "$L" 2>&1
done
for h in $HOSTS; do
    wait_ssh "$h" 240 || { say "FAIL: $h does not answer ssh within 240 s of its start"; exit 1; }
done
for h in $HOSTS; do
    cur=$(krel "$h")
    if [ "$cur" = "$K" ]; then say "$h already runs $K"; continue; fi
    say "$h runs $cur: installing, pinning and booting $K"
    on "$h" 600 "DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-kernel-$K-signed proxmox-headers-$K > /root/pve_kernel_$K.log 2>&1; echo APT_RC=\$?; proxmox-boot-tool kernel pin $K 2>&1 | tail -2; echo PIN_RC=\${PIPESTATUS[0]}" | tee -a "$L"
    on "$h" 10 'systemctl reboot' > /dev/null
    sleep 10
    wait_ssh "$h" 240 "$K" || { say "FAIL: $h is not up on $K within 240 s of its reboot"; exit 1; }
    say "$h up on $K"
done
# The SAN LUN's SCST target is runtime-only and is gone after the target is
# reset (0.90.130: pve-caw-02 was missing, the hosts booted with no session and
# every mount failed "Can't lookup blockdev"); setup reuses the image and the
# same names, so the WWID the suite names comes back.  Idempotent.
s=$SECONDS
# The target is reconfigured under the LUN pool's SCST lock, as every pool
# reconfiguration is (tools/lun_pool.sh): an injector cutting a path for a board
# must not land in the middle of it.  Bound 90 s: the longest a fault injector
# holds it shared, as lun_pool.sh's own waits.
. tools/mxfs_lab.sh
SCSTLOCK="$(lab_need paths pool)/.scst.lock"
IMG=/home/steve/disks/pve/pvecaw02.img SIZE=30G DEV=pvecaw02 TGT=iqn.2026-05.local.mxfs:pve-caw-02 \
    PORTALS="192.168.121.1 192.168.123.1" PVE_PAIR="$HOSTS" \
    flock -w 90 "$SCSTLOCK" timeout 900 scripts/pve_caw_lun.sh setup >> "$L" 2>&1
rc=$?; say "LUN_RC=$rc wall=$((SECONDS - s))s"
grep -q "PVE_CAW_LUN_OK .* dev=$SAN_DEV" "$L" || { say "FAIL: the SAN LUN is not $SAN_DEV on every host"; exit 1; }
s=$SECONDS
timeout 960 env PVE_HOSTS="$HOSTS" scripts/pve_tree_install.sh >> "$L" 2>&1
rc=$?; say "TREE_RC=$rc wall=$((SECONDS - s))s"
[ "$rc" = 0 ] || exit 1
s=$SECONDS
PVE_PAIR="$HOSTS" SAN_DEV=$SAN_DEV timeout 400 scripts/pve_mxfs_san_disk.sh join >> "$L" 2>&1
rc=$?; say "JOIN_RC=$rc wall=$((SECONDS - s))s"
[ "$rc" = 0 ] || exit 1
scripts/pve_full_suite.sh "$LABEL" > "tests/evidence/pve_full_suite_$LABEL.out" 2>&1
src=$?
say "SUITE_RC=$src $(grep -a '^SUITE: ' "tests/evidence/pve_full_suite_$LABEL.out" | tail -1)"
if [ "$SHUTDOWN" = 1 ]; then
    for h in $HOSTS; do on "$h" 10 'shutdown -P now' > /dev/null; done
    say "VMs shut down"
fi
exit "$src"
