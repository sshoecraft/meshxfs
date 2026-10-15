#!/bin/bash
# vm_pool.sh — the lab's VMs as a pool: a VM is up while something uses it and
# shut off when nothing does, the way tools/lun_pool.sh hands out LUNs.
#
# WHY.  clyde is a 94 GiB host and a lab guest takes 2-4 GiB.  Runs started
# their nodes and left them up: with 36 guests running and 18 of them idle,
# swap was full (24 of 24 GiB) and the host could not schedule the guests that
# were working.  A guest that is not run for half a second drops its DRBD link
# (PingAck), and one not run for seconds misses heartbeats and lock deadlines,
# so a starved host fabricates exactly the failures the rig is there to find
# in the filesystem.  Memory added to the host is filled the same way.  So a
# VM nobody holds is shut off.
#
# IN USE.  A lab VM is in use while any of these flock(2) locks is held (all
# released by the holder's exit, so a crash leaves nothing behind):
#   /tmp/mxfs_node.<vm>.lock    run.sh's node lock (tests/lib/runlock.sh)
#   /tmp/mxfs_vmhold.<vm>.lock  a hold that outlives one run.sh: a driver that
#                               runs several (tests/mpath/lap_chain.sh, the DRBD
#                               rig) takes it with vmhold_take for its lifetime
#   /tmp/mxfs_run.lock held EXCLUSIVE: a whole-rig run, which may use any rig
#                               node (test*), so every one of them is in use
#
# THE POOL is every libvirt domain on this host that the lab file names
# (tools/mxfs_lab.sh: rig groups, platform sets, fixed addresses).  Any other
# domain is not the lab's and is never touched.
#
# Usage:
#   tools/vm_pool.sh status            each pool VM: state, holder, memory
#   tools/vm_pool.sh idle [--dry-run]  shut off every running pool VM nobody
#                                      holds (scripts/lab_power.sh down: MXFS
#                                      unmounted first, ACPI, destroy past bound)
#   tools/vm_pool.sh release --after <pid> [--grace <s>] <vm>...
#                                      once <pid> has exited, shut off those of
#                                      <vm> nobody has held for <s> seconds
#                                      (default 600): run.sh's exit, whose own
#                                      node locks go with it, while a driver's
#                                      next run.sh takes them back in seconds
#   tools/vm_pool.sh up <vm>...        start the ones that are off and wait for
#                                      them (scripts/lab_power.sh up)
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VIRSH="sudo virsh -c qemu:///system"
LAB="${MXFS_LAB:-$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)/.config/mxfslab/lab}"

pool_vms() {  # every libvirt domain the lab file names, once each
    local named
    named=$(awk '$1=="group" || $1=="nodes" || $1=="pair" || $1=="addr" {
                 for (i = 2; i <= NF; i++) { n = index($i, "="); if (!n) continue
                     if ($1 == "addr") print substr($i, 1, n - 1)
                     else { s = substr($i, n + 1); gsub(",", "\n", s); print s } } }' "$LAB" | awk 'NF && !seen[$0]++')
    timeout 30 $VIRSH list --all --name 2>/dev/null | awk 'NF' | grep -Fxf <(printf '%s\n' "$named")
}

lock_held() {  # <file> <shared|exclusive> -> 0 iff another process holds it in a way that blocks <mode>
    local file=$1 flag=-x fd
    [ "$2" = shared ] && flag=-s
    [ -e "$file" ] || return 1
    exec {fd}<"$file" || return 1
    if flock -n $flag "$fd"; then exec {fd}<&-; return 1; fi
    exec {fd}<&-
    return 0
}

holder() {  # <vm> -> what holds it, or nothing
    local v=$1
    lock_held "/tmp/mxfs_node.$v.lock" exclusive && { echo "run: $(head -1 "/tmp/mxfs_node.$v.lock")"; return; }
    lock_held "/tmp/mxfs_vmhold.$v.lock" exclusive && { echo "hold: $(tail -1 "/tmp/mxfs_vmhold.$v.lock")"; return; }
    case $v in test*) lock_held /tmp/mxfs_run.lock shared && { echo "whole-rig run: $(head -1 /tmp/mxfs_run.lock)"; return; } ;; esac
}

state() { timeout 20 $VIRSH domstate "$1" 2>/dev/null | head -1; }

idle_set() {  # [<vm>...] -> the running pool VMs among them (default all) nobody holds
    local v
    for v in ${*:-$(pool_vms)}; do
        [ "$(state "$v")" = running ] || continue
        [ -z "$(holder "$v")" ] && echo "$v"
    done
}

case "${1:-}" in
status)
    for v in $(pool_vms); do
        st=$(state "$v"); h=$(holder "$v")
        mem=""; [ "$st" = running ] && mem=$(timeout 20 $VIRSH dommemstat "$v" 2>/dev/null | awk '$1=="rss" {printf "%d MiB", $2/1024}')
        printf '%-14s %-9s %-9s %s\n' "$v" "$st" "$mem" "${h:-idle}"
    done ;;
idle)
    vms=$(idle_set | tr '\n' ' ')
    [ -n "$vms" ] || { echo "vm_pool: no idle VM running"; exit 0; }
    echo "vm_pool: idle: $vms"
    [ "${2:-}" = --dry-run ] && exit 0
    "$REPO/scripts/lab_power.sh" down $vms ;;
release)
    [ "${2:-}" = --after ] || { echo "usage: $0 release --after <pid> [--grace <s>] <vm>..." >&2; exit 2; }
    pid=${3:?pid}; shift 3
    # Started in the background by run.sh, this process inherits run.sh's
    # open lock descriptors; holding them would keep every node "in use" and
    # refuse the next run its node locks.  Close those (only: bash reads this
    # script through a descriptor of its own).
    for fd in $(ls /proc/$$/fd); do
        case "$(readlink "/proc/$$/fd/$fd" 2>/dev/null)" in
            /tmp/mxfs_node.*.lock|/tmp/mxfs_vmhold.*.lock|/tmp/mxfs_run.lock|/tmp/mxfs_config.*.lock)
                eval "exec $fd>&-" ;;
        esac
    done
    grace=600
    [ "${1:-}" = --grace ] && { grace=${2:?seconds}; shift 2; }
    while [ -d "/proc/$pid" ]; do sleep 2; done
    # A driver that runs run.sh several times in a row starts the next one
    # within seconds, and its node locks hold the VMs again: only a VM that
    # stays unheld for the whole grace is shut off.
    keep=$(idle_set "$@" | tr '\n' ' ')
    waited=0
    while [ -n "$keep" ] && [ "$waited" -lt "$grace" ]; do
        sleep 30; waited=$((waited + 30))
        keep=$(idle_set $keep | tr '\n' ' ')
    done
    vms=$keep
    [ -n "$vms" ] || exit 0
    echo "vm_pool: released by $pid: $vms"
    "$REPO/scripts/lab_power.sh" down $vms ;;
up)
    shift
    off=""; for v in "$@"; do [ "$(state "$v")" = running ] || off="$off $v"; done
    [ -n "$off" ] || exit 0
    "$REPO/scripts/lab_power.sh" up $off ;;
*) sed -n '2,40p' "$0"; exit 2 ;;
esac
