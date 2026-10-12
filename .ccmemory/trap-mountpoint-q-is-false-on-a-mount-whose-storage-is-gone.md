---
name: trap-mountpoint-q-is-false-on-a-mount-whose-storage-is-gone
description: TRAP (0.90.123): mountpoint -q stats the mount root; with the LUN gone it gets EIO and says "not mounted" while /proc/mounts still lists it.
metadata:
  type: feedback
---

`mountpoint -q /mnt/shared` returns 1 when the mount's root answers stat with EIO (MXFS mounted on a pool LUN that was rebound to another group: `dlm_caw: read_slot ... I/O error -5` forever). tools/lun_pool.sh's NODE_UNMOUNT broke out of its loop on that and never called umount, so every bind over those nodes failed UNMOUNT_FAIL (test8-16, 2026-10-11) — yet a plain `umount` succeeded instantly (dirty departure, P277-FINAL-FLUSH-FAILED, PR key retained as fence target).

Rule: decide "is it still mounted" from /proc/mounts (awk on field 2/3), and use `mountpoint -q` only to gate `fuser -km` (on a non-mountpoint fuser resolves to / and kills sshd). Also: the D-state task on such a node is mxfs-worker bast_poll_fn in msleep (uninterruptible sleep counts as D) — not a stuck umount.
