---
name: compiled-kept-snapshots-fill-clyde-root-and-host-io-storms
description: Kept LUN snapshots filled clyde's / then /mxfs; /mxfs holds only ~/disks, test VMs, evidence; host write storms stall every LUN - read sar first
metadata:
  type: feedback
tags: [compiled, rig, clyde, preflight, snapshots, lun_pool, sar, host-io, scst, disk-space, mxfs-disk, evidence, owner-directive]
---

# Kept snapshot images fill clyde's disks; what /mxfs is for; host write storms stall every pool LUN

Host-side failure modes on clyde that look like MXFS or rig faults but are the host's own state, and the owner's rule for the disk added to stop them. Provenance: run 7e16fd1d, session 31 (2026-10-17) for sections 1-2; 2026-10-22 for section 3. Sources: `trap-kept-snapshots-fill-clyde-root-and-host-write-storms-stall-every-lun`, `feedback-mxfs-disk-is-for-lun-images-test-vms-and-evidence`.

## 1. A burst of `RESULT: ABORT ... stage=prep` within seconds, across every queue, is the host preflight

From `trap-kept-snapshots-fill-clyde-root-and-host-write-storms-stall-every-lun`:

- Seen: from 14:04Z every queued lap on every pair (hf8b, hf6t, hf7c: 16 laps) aborted at prep in 8-22 s; all queues reached QUEUE DONE with nothing measured.
- Read the lap's `prep.log` first. Here: `clyde_preflight: FAIL ... test LUN pool (/dev/nvme0n1p2): 100% used, 7G free (limit: >=10G free)`.
- Cause: `tools/lun_pool.sh snapshot` (called by `tests/noino_gen0_ab.sh` on every CORRUPT audit) copied each 20 GiB pool LUN (12-15 G of data) into `/home/steve/disks/snapshots` on the root ext4 with no check; 22 images = 285 G.
- Since 0.90.131 the snapshot refuses a copy that could leave its filesystem below `MXFS_PREFLIGHT_MIN_FREE_GB` (10 G) and honours `MXFS_SNAPSHOT_DIR`.
- SUPERSEDED (2026-10-22, section 3): this note went on to send kept images to `/mxfs/snapshots` and to put `MXFS_SNAPSHOT_DIR=/mxfs/snapshots` on queue lines. The owner rejected that use of `/mxfs`; the 84 images there (1.2T) were deleted on the owner's approval. `tests/linked_corpse_reuse_ab.sh`, `tests/ilock_eagain_park_ab.sh` (`MXFS_SNAPSHOT_DIR` default) and `lun_pool.sh snapshot` (default `$(dirname $POOL)/snapshots`, now on `/mxfs`) still default to keeping copies; changing that awaits the owner.
- Never clear or skip the preflight to get moving; free the space.

## 2. A snapshot copy (or any big buffered write on /) is a host-wide I/O storm

From `trap-kept-snapshots-fill-clyde-root-and-host-write-storms-stall-every-lun`:

- Until 2026-10-22 the pool LUNs, the 32 guest images and the journal shared nvme0n1p2; they now live on `/mxfs` (`/dev/sda`, a Samsung 870 SATA SSD), so read `sda` as well as `nvme0n1` for later storms. Two snapshot copies took nvme0n1 average await from ~0.5 ms to 20-70 ms (aqu-sz ~110) and dirty pages to 6-7 G for about two minutes.
- Two unexplained stalls on concurrent laps sat inside such storms: a 57 s CAW hold at unmount on 2/disk/caw/mpath (13:34Z) and a 35 s path-down stall on an 8-node board (13:14Z).
- Measured with `tests/caw_host_storm_probe.sh`: a lone initiator's CAW latency rose from 10 ms to 1.95 s under a 28 G storm. That is 200x, but not tens of seconds, so the storm alone did not reproduce the 57 s hold.
- Before diagnosing any stall, timeout or budget overrun on the rig as an MXFS fault, read the host's own history for that minute: `LC_ALL=C sar -f /var/log/sysstat/saDD -s HH:MM:00 -e HH:MM:00 -d -p | grep -E 'DEV|nvme0n1$|sda$'` (DEV is the last column, so do not grep `'nvme0n1 '`), and `-r` for kbdirty. sar uses local time (CDT = Z-5).
- `make modules` in the main tree took 376 s instead of ~38 s while a 285 G move ran on the same NVMe.

## 3. The /mxfs disk holds ~/disks, the test VMs and evidence, and nothing else unasked

From `feedback-mxfs-disk-is-for-lun-images-test-vms-and-evidence` (owner, 2026-10-22):

- The owner added the 2 TB disk at `/mxfs` for exactly three things:
  - `~/disks` (SCST pool LUN images, the pve and 4Kn LUN images): `~/disks` is a symlink to `/mxfs/disks`;
  - the libvirt test VMs (test1-32, pve9-*, pve92-*, alma/rhel/debian/ubuntu guests): `~/vms/qemu` is a symlink to `/mxfs/vms/qemu`;
  - rig evidence: the data lives in `/mxfs/evidence` ("from now on put evidence in /mxfs/evidence ... move the current one there"). `tests/evidence` is a symlink to `/src/mxfs-evidence`, a bind mount of `/mxfs/evidence` (host `/etc/fstab`), and `/src` is exported with `crossmnt`, so the link resolves to the same directory on a node. Never point the link straight at `/mxfs/evidence`: a node has no `/mxfs`, the link resolved to nothing there, and every row writing evidence from a node failed (alloc_witness `witness_dir=unwritable`, then chk_clean found no sealed witness; D-NODES-CANNOT-WRITE-TESTS-EVIDENCE-IT-LINKS-TO-THE-HOSTS-OWN-MXFS-DISK, 2026-10-22).
- NOT on `/mxfs`: the vmware/vcenter VMs (`~/vms/vmware`, `~/vms/vsphere`, the latter NFS-exported to the nested ESXi lab) stay in `~/vms`. ISOs live in `/iso`, not in the home dir.
- What went wrong: sessions moved 84 kept LUN copies (1.2T, `lunNN-*-2026101[789]*.img`) onto `/mxfs/snapshots` and left the VM disks and LUN images on `/`, which sat at 91%. Owner: "I INSTALLED THAT 2TB DISK _JUST_ FOR THIS PURPOSE AND YOU FILLED IT UP WITH WHAT?? CRAP?" No defect cited any single image.
- A harness that wants to keep a LUN image asks first, or keeps it under the run's own evidence dir, never a standing `snapshots/` pile on either disk.
- After a mass delete on XFS, re-read `df` a few seconds later before reporting free space: XFS frees large files in the background, and a reading taken at once showed 803G used where 148G was true.
- Moving a file SCST holds open (pool LUN images) leaves the device writing the deleted copy: `scripts/scst_reopen.sh <prefix> <move command>` removes the devices, runs the move and re-creates each with its parameters, identity and LUN mappings. A libvirt-owned image (root 0600) needs `sudo mv`; a cross-filesystem `mv` that hits an unreadable file copies the rest and deletes nothing, so finish with `sudo rsync -aH --remove-source-files`.
