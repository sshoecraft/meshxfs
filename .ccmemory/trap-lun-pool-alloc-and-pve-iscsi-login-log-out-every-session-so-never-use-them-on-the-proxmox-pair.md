---
name: trap-lun-pool-alloc-and-pve-iscsi-login-log-out-every-session-so-never-use-them-on-the-proxmox-pair
description: TRAP: tools/lun_pool.sh alloc and scripts/pve_iscsi_login.sh log out ALL iSCSI, unmount mxfs, rmmod; on pve1/pve2 use scripts/pve_caw_lun.sh
metadata:
  type: feedback
---

The physical Proxmox pair (pve1 192.168.1.80, pve2 192.168.1.81) runs other work at the same time (DRBD legs on sdb, guests). Two existing helpers are built for disposable rig VMs and are destructive there:

- `tools/lun_pool.sh alloc` (NODE_LOGIN): logs the node out of every target, deletes every node record, fuser -km + umounts every mxfs, rmmods mxfs, rewrites multipath config. It also hands pool LUNs to rig runs that format them, and an image placed in the pool dir (`/home/steve/disks/pool/lunNN.img`) becomes allocatable.
- `scripts/pve_iscsi_login.sh`: `iscsiadm -m node -u` + `-o delete` for ALL records first.

For a SAN LUN on the pair use `scripts/pve_caw_lun.sh` (setup/login/status/logout/teardown): image `/home/steve/disks/pve/pvecaw01.img` outside the pool, target `iqn.2026-05.local.mxfs:pve-caw-01`, portal 192.168.1.166 only (the pool targets are not allowed there, so discovery finds only this one), LUN 0 in ini_group `pve` with the two hosts' IQNs, targeted login with node.startup=automatic. SCST objects are runtime-only: after a clyde restart rerun `setup`. Verified 2026-10-10: both hosts /dev/sdd, same WWID, CAW cross-host, miscompare refused, PR key visible across hosts.
