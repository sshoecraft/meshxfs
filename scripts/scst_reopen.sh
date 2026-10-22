#!/bin/bash
# scst_reopen.sh -- move the image files behind SCST devices without SCST
# writing to the copies left behind.
#
# WHY.  An SCST vdisk_fileio device holds its image open.  Moving the image to
# another filesystem copies it and unlinks the old file, but the device keeps
# the old inode: every write after the move lands in a deleted file, the space
# is never freed, and the copy at the new place goes stale.  The device has to
# let go of the file before it moves and open it again after.
#
# WHAT IT DOES, for every vdisk_fileio device whose image path begins with
# PREFIX:
#   - records the device's parameters (filename, blocksize, async, o_direct,
#     size), its identity (t10_dev_id, eui64_id, naa_id: what an initiator reads
#     as the disk's WWID) and every LUN that maps it, in a target's own LUNs or
#     in an initiator group's;
#   - refuses when any target that maps one of them has a session: removing a
#     device under a logged-in initiator fails its commands;
#   - removes the devices, runs COMMAND (the move), then adds each device again
#     with the same parameters, puts back any identity that came out different,
#     and maps every LUN as it was;
#   - checks each device is back with its file, size, identity and mappings.
# A device's persistent reservations are SCST's own (/var/lib/scst/pr/<name>)
# and are restored when a device of that name is added again.
#
# The image paths themselves do not change: COMMAND must leave each file
# reachable at the path it had, e.g. by moving the directory and leaving a
# symlink in its place.
#
# Usage: scripts/scst_reopen.sh <prefix> <command...>
# Exit 0 every device is back as it was, 1 a step failed, 2 refused.
set -u
PREFIX=${1:?image path prefix}; shift
[ $# -ge 1 ] || { echo "usage: $0 <prefix> <command...>" >&2; exit 2; }
D=/sys/kernel/scst_tgt/devices
H=/sys/kernel/scst_tgt/handlers/vdisk_fileio
T=/sys/kernel/scst_tgt/targets/iscsi
say() { echo "$(date +%T) $*"; }
rd() { sudo -n cat "$1" 2>/dev/null | head -1; }

DEVS=()
for d in "$D"/*; do
    [ "$(basename "$(readlink -f "$d/handler")")" = vdisk_fileio ] || continue
    f=$(rd "$d/filename")
    case $f in "$PREFIX"*) DEVS+=("$(basename "$d")") ;; esac
done
[ "${#DEVS[@]}" -gt 0 ] || { say "no vdisk_fileio device has an image under $PREFIX"; exit 2; }

declare -A FILE BS ASYNC ODIRECT SIZE T10 EUI NAA
MAPS=()   # "<lun mgmt dir> <lun> <device>"
for n in "${DEVS[@]}"; do
    FILE[$n]=$(rd "$D/$n/filename"); BS[$n]=$(rd "$D/$n/blocksize"); ASYNC[$n]=$(rd "$D/$n/async")
    ODIRECT[$n]=$(rd "$D/$n/o_direct"); SIZE[$n]=$(rd "$D/$n/size"); T10[$n]=$(rd "$D/$n/t10_dev_id")
    EUI[$n]=$(rd "$D/$n/eui64_id"); NAA[$n]=$(rd "$D/$n/naa_id")
    say "device $n file=${FILE[$n]} blocksize=${BS[$n]} async=${ASYNC[$n]} o_direct=${ODIRECT[$n]} size=${SIZE[$n]} t10_dev_id=${T10[$n]}"
done
for t in "$T"/*/; do
    for l in "$t"luns/[0-9]* "$t"ini_groups/*/luns/[0-9]*; do
        [ -e "$l/device" ] || continue
        dev=$(basename "$(readlink "$l/device")")
        case " ${DEVS[*]} " in *" $dev "*) ;; *) continue ;; esac
        if [ -n "$(ls "${t}sessions" 2>/dev/null)" ]; then
            say "REFUSED $(basename "$t") maps $dev and has a session: $(ls "${t}sessions" | tr '\n' ' ')"
            exit 2
        fi
        MAPS+=("$(dirname "$l") $(basename "$l") $dev")
        say "map $(dirname "$l")/$(basename "$l") -> $dev"
    done
done

for n in "${DEVS[@]}"; do
    echo "del_device $n" | sudo -n tee "$H/mgmt" >/dev/null || { say "FAIL del_device $n"; exit 1; }
    [ -d "$D/$n" ] && { say "FAIL $n still present after del_device"; exit 1; }
done
say "removed ${#DEVS[@]} devices; running: $*"
"$@"; rc=$?
say "command rc=$rc"

bad=0
for n in "${DEVS[@]}"; do
    [ -e "${FILE[$n]}" ] || { say "FAIL ${FILE[$n]} is not there after the command: $n not added"; bad=1; continue; }
    echo "add_device $n filename=${FILE[$n]}; blocksize=${BS[$n]}; async=${ASYNC[$n]}; o_direct=${ODIRECT[$n]}" | sudo -n tee "$H/mgmt" >/dev/null \
        || { say "FAIL add_device $n"; bad=1; continue; }
    for a in t10_dev_id eui64_id naa_id; do
        case $a in t10_dev_id) want=${T10[$n]} ;; eui64_id) want=${EUI[$n]} ;; naa_id) want=${NAA[$n]} ;; esac
        [ "$(rd "$D/$n/$a")" = "$want" ] && continue
        echo "$want" | sudo -n tee "$D/$n/$a" >/dev/null
        [ "$(rd "$D/$n/$a")" = "$want" ] || { say "FAIL $n $a is '$(rd "$D/$n/$a")', was '$want'"; bad=1; }
    done
done
for m in "${MAPS[@]}"; do
    set -- $m
    [ -e "$1/$2/device" ] && continue
    echo "add $3 $2" | sudo -n tee "$1/mgmt" >/dev/null || { say "FAIL add $3 $2 in $1"; bad=1; }
done
for n in "${DEVS[@]}"; do
    [ -d "$D/$n" ] || { bad=1; continue; }
    got="$(rd "$D/$n/filename") $(rd "$D/$n/blocksize") $(rd "$D/$n/size") $(rd "$D/$n/t10_dev_id")"
    want="${FILE[$n]} ${BS[$n]} ${SIZE[$n]} ${T10[$n]}"
    if [ "$got" = "$want" ]; then say "OK $n back: $(readlink -f "${FILE[$n]}") blocksize=${BS[$n]} size=${SIZE[$n]}"; else say "FAIL $n is [$got], was [$want]"; bad=1; fi
done
for m in "${MAPS[@]}"; do
    set -- $m
    [ "$(basename "$(readlink "$1/$2/device" 2>/dev/null)")" = "$3" ] || { say "FAIL $1/$2 does not map $3"; bad=1; }
done
[ "$rc" -eq 0 ] && [ "$bad" -eq 0 ] && { say "every device back as it was"; exit 0; }
exit 1
