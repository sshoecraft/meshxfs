#!/bin/bash
# fourkn_mount_probe.sh — format, mount on two nodes, exchange data and
# unmount on a shared LUN, step by step and outside run.sh: the probe for a
# device run.sh has never prepared, such as the 4K-native LUN
# tests/fourkn_lun.sh makes.
#
# Each step prints one line, OK or FAIL with what it saw, and the nodes' kernel
# lines since the probe's start are printed at the end.  The module is the
# tree's /src/mxfs/mxfs.ko as tests/setup/prep_node.sh loads it (no parameters:
# CAW; MODARGS="force_transport=1" for the TCP lock network), and the loaded
# srcversion is checked against the tree's.
#
# Bounds: insmod 30 s, mkfs 300 s (tools/mkfs_mxfs formats a 20 GB LUN in
# well under 1 s; the bound covers zeroing the regions on a slow target), mount
# 120 s (a CAW mount's slot claim and the TCP membership wait are each under
# 60 s on the rig), a 64 MiB write and read 60 s each, umount 60 s.
#
# TREE names another built tree under ~/src (a published version's source, say
# ~/src/mxfs-v130) whose module and tools the nodes load instead; the nodes see
# it as /src/<its name>.  MKFS_ARGS is passed to mkfs, which lays the volume
# out for the device's logical block size (512 or 4096) on its own.
#
# ONE=1 mounts the first node only: it writes a 64 MiB file, unmounts, mounts
# again and reads it back (the remount 120 s, the read 60 s).  Two nodes
# writing inodes of the same 4096-byte blocks, which the merged inode-cluster
# write exists for (docs/4kn-support.md), is tests/fourkn_merge_2node.sh.
#
# Usage: [MODARGS="..."] [MKFS_ARGS="..."] [ONE=1] [TREE=<path>] tests/fourkn_mount_probe.sh <dev> <node1> <node2>
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/tools/mxfs_lab.sh"
SSH="$HERE/tools/mxfs_sshpass.sh"
DEV=${1:?device}; N1=${2:?node1}; N2=${3:?node2}
MODARGS=${MODARGS:-}
MKFS_ARGS=${MKFS_ARGS:-}
ONE=${ONE:-0}
TREE=${TREE:-$HERE}
NREPO=/src/$(basename "$TREE")
MNT=/mnt/fourkn
SV=$(modinfo -F srcversion "$TREE/mxfs.ko")
MARK="FOURKN-PROBE-$(date -u +%Y%m%dT%H%M%SZ)"
on() { timeout "$3" "$SSH" "$(lab_addr "$1")" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'; }
step() { echo "$(date -u +%FT%TZ) $*"; }

for n in "$N1" "$N2"; do
    on "$n" "echo $MARK > /dev/kmsg" 10 >/dev/null
    # the tree reaches a node over NFS, as tests/setup/prep_node.sh mounts it
    on "$n" "mountpoint -q /src || { mkdir -p /src; timeout 30 mount -t nfs 192.168.120.1:/src /src -o rw,vers=4.1,hard,timeo=600,retrans=2,tcp,rsize=1048576,wsize=1048576; }" 40 >/dev/null
    # a module of another build still loaded (an earlier probe's) is unloaded
    # first; nothing is mounted between probes
    r=$(on "$n" "if lsmod | grep -q '^mxfs '; then [ \"\$(cat /sys/module/mxfs/srcversion)\" = $SV ] || rmmod mxfs; fi; lsmod | grep -q '^mxfs ' || insmod $NREPO/mxfs.ko $MODARGS; cat /sys/module/mxfs/srcversion; blockdev --getss $DEV; blockdev --getpbsz $DEV" 30 | tr '\n' ' ')
    case $r in "$SV "*) step "OK insmod $n srcversion/logical/physical: $r" ;; *) step "FAIL insmod $n: $r (want srcversion $SV)"; exit 1 ;; esac
done

r=$(on "$N1" "$NREPO/tools/mkfs_mxfs $MKFS_ARGS -f $DEV 2>&1 | tail -4; echo mkfs_rc=\${PIPESTATUS[0]}" 300)
case $r in *mkfs_rc=0*) step "OK mkfs on $N1: $(echo "$r" | tr '\n' '|')" ;; *) step "FAIL mkfs on $N1: $(echo "$r" | tr '\n' '|')" ;; esac

if [ "$ONE" = 1 ]; then
    mounted=""
    r=$(on "$N1" "mkdir -p $MNT; timeout 110 mount -t mxfs $DEV $MNT; echo mount_rc=\$?" 120)
    case $r in *mount_rc=0*) step "OK mount $N1 (alone)"; mounted=" $N1" ;; *) step "FAIL mount $N1: $(echo "$r" | tr '\n' '|')" ;; esac
    if [ -n "$mounted" ]; then
        r=$(on "$N1" "dd if=/dev/urandom of=$MNT/from_$N1 bs=1M count=64 status=none && sync && md5sum < $MNT/from_$N1" 60)
        w1=$(echo "$r" | awk '{print $1}' | tail -1)
        r=$(on "$N1" "timeout 55 umount $MNT; echo umount_rc=\$?" 60)
        case $r in *umount_rc=0*) step "OK umount $N1 after the write" ;; *) step "FAIL umount $N1: $(echo "$r" | tr '\n' '|')" ;; esac
        r=$(on "$N1" "timeout 110 mount -t mxfs $DEV $MNT; echo mount_rc=\$?" 120)
        case $r in *mount_rc=0*) step "OK remount $N1" ;; *) step "FAIL remount $N1: $(echo "$r" | tr '\n' '|')"; mounted="" ;; esac
        if [ -n "$mounted" ]; then
            r2=$(on "$N1" "echo 3 > /proc/sys/vm/drop_caches; md5sum < $MNT/from_$N1" 60)
            w2=$(echo "$r2" | awk '{print $1}' | tail -1)
            [ -n "$w1" ] && [ "$w1" = "$w2" ] && step "OK $N1 reads its 64 MiB file intact after the remount ($w1)" || step "FAIL read after remount: wrote [$w1] read [$r2]"
        fi
    fi
    for n in $mounted; do
        r=$(on "$n" "timeout 55 umount $MNT; echo umount_rc=\$?" 60)
        case $r in *umount_rc=0*) step "OK umount $n" ;; *) step "FAIL umount $n: $(echo "$r" | tr '\n' '|')" ;; esac
    done
    echo "--- $N1 kernel lines since $MARK (mxfs, XFS, I/O and SCSI errors)"
    on "$N1" "dmesg | sed -n '/$MARK/,\$p' | grep -aiE 'mxfs|xfs|blocksize|sector|i/o error|sense|caw|compare|error|fail' | tail -60" 30
    exit 0
fi

mounted=""
for n in "$N1" "$N2"; do
    r=$(on "$n" "mkdir -p $MNT; timeout 110 mount -t mxfs $DEV $MNT; echo mount_rc=\$?" 120)
    case $r in *mount_rc=0*) step "OK mount $n"; mounted="$mounted $n" ;; *) step "FAIL mount $n: $(echo "$r" | tr '\n' '|')" ;; esac
done

if [ "$mounted" = " $N1 $N2" ]; then
    r=$(on "$N1" "dd if=/dev/urandom of=$MNT/from_$N1 bs=1M count=64 status=none && sync && md5sum < $MNT/from_$N1" 60)
    w1=$(echo "$r" | awk '{print $1}' | tail -1)
    r2=$(on "$N2" "md5sum < $MNT/from_$N1" 60)
    w2=$(echo "$r2" | awk '{print $1}' | tail -1)
    [ -n "$w1" ] && [ "$w1" = "$w2" ] && step "OK $N2 reads $N1's 64 MiB file intact ($w1)" || step "FAIL cross-node read: $N1=[$r] $N2=[$r2]"
    r=$(on "$N2" "dd if=/dev/urandom of=$MNT/from_$N2 bs=1M count=64 status=none && sync && md5sum < $MNT/from_$N2" 60)
    w1=$(echo "$r" | awk '{print $1}' | tail -1)
    r2=$(on "$N1" "md5sum < $MNT/from_$N2; ls $MNT | wc -l" 60)
    w2=$(echo "$r2" | awk 'NR==1 {print $1}')
    [ -n "$w1" ] && [ "$w1" = "$w2" ] && step "OK $N1 reads $N2's 64 MiB file intact ($w1)" || step "FAIL cross-node read: $N2=[$r] $N1=[$r2]"
fi

for n in $mounted; do
    r=$(on "$n" "timeout 55 umount $MNT; echo umount_rc=\$?" 60)
    case $r in *umount_rc=0*) step "OK umount $n" ;; *) step "FAIL umount $n: $(echo "$r" | tr '\n' '|')" ;; esac
done
for n in "$N1" "$N2"; do
    echo "--- $n kernel lines since $MARK (mxfs, XFS, I/O and SCSI errors)"
    on "$n" "dmesg | sed -n '/$MARK/,\$p' | grep -aiE 'mxfs|xfs|blocksize|sector|i/o error|sense|caw|compare|error|fail' | tail -40" 30
done
