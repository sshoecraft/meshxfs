---
name: feedback-pool-luns-stay-on-the-sata-870-capture-yardsticks-there
description: Pool LUN images stay on /mxfs (SATA Samsung 870, ~512 MiB/s); owner said NO to moving them back to NVMe. Re-capture yardsticks on the 870.
metadata:
  type: feedback
---

The rig's pool LUN images (`~/disks` -> `/mxfs/disks`, `/mxfs` = `/dev/sda`, a SATA Samsung SSD 870) moved off the NVMe root on 2026-10-22 by the owner's direction. When a session recommended moving them back to the NVMe (990 EVO Plus) because native XFS on a pool LUN measured only 511 MiB/s sequential write, the owner answered: "LOL -NO-".

Apply:
- Never propose moving the pool LUNs (or the VMs, or evidence) back to the NVMe. The 870 is the rig's LUN backing.
- A native-XFS yardstick measured on a pool LUN is bounded by the 870's SATA link: `host_disk[sda ... MiBs_max=512]` in the capture's own sampler. 511 MiB/s seq write and 539 MiB/s seq read on the 4K-native LUN (2026-10-22) are the disk, not XFS.
- Yardsticks captured before the move (the 512-byte `.xfs_fio_baseline.disk-caw-*.scst-fio.json`, 2026-10-01/04, 1133/1291 MiB/s) were measured on the NVMe and are stale for every board run on the 870: `tools/xfs_baseline_refresh.sh` says to re-measure whenever the LUN backing changes. Re-capture them on the 870 before grading any board's `fio_perf_vs_xfs`.
- Capture only on a quiet host: a board run or a package build on the lab VMs (whose disks are also on `/mxfs`) loads the same 870 and biases the yardstick low.
