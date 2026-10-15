#!/bin/bash
#
# refuse_inuse_dev.sh — refuse to let a prep format a device this node is
# using for something else
#
# Usage: tests/setup/refuse_inuse_dev.sh <device>
# Prints DEV_FREE <device> and exits 0, or DEV_IN_USE <device>: <why> and exits 1.
# Run it on the node, after the prep has unmounted its own mountpoint.
#
# A shared LUN the harness formats is a bare disk: no partition table, nothing
# mounted, no LVM, swap or RAID signature, nothing stacked on it.  A device that
# has any of those is somebody's disk.  Measured 2026-10-13: the 1/xfs
# baseline's default device is /dev/sda, which on the qemu rig is a lent LUN
# and on a vSphere guest is the boot disk; prep ran `mkfs.xfs -f /dev/sda` on
# vstest1, and only the kernel refusing an exclusive open of a disk whose
# partitions were mounted kept the root filesystem.  The mxfs prep's holder
# check would not have caught it either: the boot disk's holders hang off its
# LVM partition, not the disk.
set -u
dev=${1:?usage: $0 <device>}
[ -b "$dev" ] || { echo "DEV_IN_USE $dev: not a block device"; exit 1; }
real=$(readlink -f "$dev")
base=$(basename "$real")

why=""
# anything stacked on the whole device (a dm map, md, bcache)
h=$(ls -A "/sys/class/block/$base/holders" 2>/dev/null | tr '\n' ' ')
[ -n "$h" ] && why="$why held by: $h;"
# every node beneath it: partitions, LVM volumes, maps over its partitions
kids=$(lsblk -nrpo NAME,TYPE "$real" 2>/dev/null | awk 'NR>1 {print $1"("$2")"}' | tr '\n' ' ')
[ -n "$kids" ] && why="$why carries: $kids;"
# mounts and signatures anywhere in that tree
mnts=$(lsblk -nrpo NAME,MOUNTPOINT "$real" 2>/dev/null | awk '$2 != "" {print $1"->"$2}' | tr '\n' ' ')
[ -n "$mnts" ] && why="$why mounted: $mnts;"
sigs=$(lsblk -nrpo NAME,FSTYPE "$real" 2>/dev/null | awk '$2 ~ /^(LVM2_member|swap|linux_raid_member|crypto_LUKS|zfs_member)$/ {print $1"="$2}' | tr '\n' ' ')
[ -n "$sigs" ] && why="$why signatures: $sigs;"
grep -q "^$real " /proc/swaps 2>/dev/null && why="$why active swap;"

if [ -n "$why" ]; then
    echo "DEV_IN_USE $dev:$why"
    exit 1
fi
echo "DEV_FREE $dev"
