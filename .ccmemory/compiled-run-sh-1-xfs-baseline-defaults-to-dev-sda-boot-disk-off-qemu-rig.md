---
name: compiled-run-sh-1-xfs-baseline-defaults-to-dev-sda-boot-disk-off-qemu-rig
description: run.sh 1/xfs defaults MXFS_DEV to /dev/sda, the boot disk on vSphere/physical nodes; always pass the LUN by-path off the qemu rig.
metadata:
  type: feedback
tags: [compiled, vsphere, run.sh, 1/xfs, mkfs, safety, MXFS_DEV]
---

Assorted group of one note: a safety trap in `run.sh`'s native-XFS baseline, `1/xfs`, on any platform other than the qemu rig. Source: `trap-1-xfs-baseline-default-dev-sda-is-the-boot-disk-off-the-qemu-rig`.

## The trap

`run.sh` takes the `1/xfs` native-XFS baseline's device from `data/configurations.json`, and that default is `/dev/sda`. It means "whatever LUN the live rig presents at sda", which is true only on the qemu rig. Multi-node configurations borrow a pool LUN instead, so they never hit this.

On 2026-10-13, `MXFS_NODE_LIST=vstest1 ./run.sh 1/xfs prep_cluster` on a vSphere guest:
- sent `sg_persist --clear` to the boot disk;
- ran `mkfs.xfs -f /dev/sda`.

The kernel refused the exclusive open ("/dev/sda: Can't open blockdev") because sda's partitions were mounted. That is the only reason the root filesystem survived.

## Guard and what to do anyway

`tests/setup/refuse_inuse_dev.sh` now guards both preps: it refuses a device with partitions, holders, mounts, or swap/LVM/RAID signatures. Still:
- Off the qemu rig, ALWAYS pass `MXFS_DEV` as the shared LUN's stable by-path link, e.g. `MXFS_DEV=/dev/disk/by-path/ip-192.168.120.1:3260-iscsi-iqn.2026-05.local.mxfs:pool-10-lun-0` on vstest1.
- `1/xfs` also needs `MXFS_NODE_LIST` with exactly one node, and its own `prep_cluster` before `fio_perf`.
- On vSphere the shared LUN is sdb; sda is the VMware boot disk.

Never trust a harness's default device on a platform it was not written for. Read `lsblk` on the node first.

Provenance: ccloop run 8bd0eed0, session 3.
