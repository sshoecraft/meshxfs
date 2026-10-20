---
name: compiled-scst-sampling-sibling-lap-binaries-and-free-inode-adopt-traps
description: Lap/rig traps: SCST target + sd-inflight sampling blind spots, main-tree make clean aborts sibling laps, free-image adopt keeps dead-life nblocks
metadata:
  type: feedback
tags: [compiled, scst, caw, lap, sampling, sibling-checkout, reload, adopt, icache, nblocks, verifier, chk_mxfs]
---

Assorted group: the tail the clusterer could not fit to one topic, organised by area. Three MXFS lap/rig traps from sessions 37-39. Common thread: the real state sits behind something that looks authoritative and is not. Probes read idle / `0:0` / CLEAN while a command is held or a block count is corrupt (sections 1 and 3), and a sibling-checkout lap depends on the main tree's `tools/` binaries without announcing it (section 2).

## 1. SCST target-side and node-side sampling blind spots

Source: `trap-scst-target-sampling-blind-spots`. Facts read from the SCST source in `~/src/scst` (session 39, defect `D-CAWMPATH-UMOUNT-RELEASE-ALL-CAW-HELD-57S-BOTH-NODES`), each of which a target-side probe gets wrong if it guesses:

- **Thread names.** A device's per-initiator command threads are created with `"%.10s%d_%d"` (`scst/src/scst_main.c:1722`): the first 10 chars of the device name, the initiator (tgt_dev) index, `_`, the thread number. So pool LUN `mxfspool01`'s threads are `mxfspool010_*`, `mxfspool011_*`, ... (one pool per initiator path). A match on `mxfspool01_*` matches nothing; `mxfspool01*` is right. Global command threads are `scstd<n>`; iscsi-scst's per-connection threads are `iscsird<n>_<m>` / `iscsiwr<n>_<m>`.
- **PERSISTENT RESERVE OUT blocks the whole LUN.** Its cdb entry carries `SCST_SERIALIZED` (`scst/src/scst_lib.c:1197`), and a serialized command calls `scst_block_dev()` (`scst_lib.c:13881-13889`): every other command to that device, from every initiator, waits in the blocked list until it completes. Its execution persists the PR state to a file on the lab host's root filesystem and fsyncs it (`scst_pr_sync_device_file` -> `vfs_fsync`), so under a host write storm one PR OUT holds the LUN for the length of a root-ext4 journal commit. Seen in lap cus1/cus3 stacks: `jbd2_log_wait_commit <- ext4_sync_file <- vfs_fsync <- scst_pr_sync_device_file <- scst_persistent_reserve_out_local`.
- **async=1 hides the wait from the pool threads.** With vdisk_fileio async=1 a pool thread submits a CAW's internal READ16/WRITE16 and goes idle; a completion held elsewhere (kworker, writeback, reclaim) leaves every pool thread sampled idle. Sample all D-state host tasks (`/proc/*/stat` + `/proc/<pid>/stack`, both safe) instead of only the pool.
- **Node side: `/sys/block/sdX/inflight` does not show a COMPARE AND WRITE.** It counts filesystem I/O; a passthrough request (`blk_execute_rq`) is not counted. Lap cus3 read `0:0` on every sd* for the whole 60 s a CAW sat in `blk_execute_rq`. Count `device/iorequest_cnt - device/iodone_cnt` (hex, includes passthrough) and read `device/state`.

`tests/caw_umount_storm.sh` samples all four ways since session 39. `trap-scst-target-sampling-blind-spots`

## 2. `make clean` / rebuild in the main tree aborts sibling-checkout laps in prep

Source: `trap-main-tree-make-clean-aborts-sibling-lap-prep`. A lap started from a sibling checkout (`~/src/mxfs-b`, `-c`, `-e`) loads the sibling's `mxfs.ko`, but its node-side prep formats the LUN with `/src/mxfs/tools/mkfs_mxfs` and its audit runs `/src/mxfs/tools/chk_mxfs` -- the MAIN tree's binaries (`/src/mxfs` is `~/src/mxfs` over NFS).

- `make clean` in the main tree (it runs `make -C tools clean`) deletes the binaries every sibling lap is about to exec.
- Observed (session 38, 2026-10-17): the main tree was rebuilt at 18:00:16Z between two laps of a sibling queue; the next two laps started their prep inside the ~45 s build and ABORTed at stage=prep with `FS_PREP_FAIL: mkfs_mxfs -f -n 4 /dev/mapper/mpatha returned 127` (command not found). Two A/B laps lost and rerun.
- **How to apply:** before rebuilding the main tree, read every running queue's log (all checkouts, `tests/evidence/lapq_*.log`). Rebuild only when no lap of ANY checkout is in prep or audit, or build tools elsewhere and install them with an atomic rename. A lap's prep is its first ~20-140 s; its audit is near its end.

## 3. `xfs_inode_from_disk` on a FREE dinode adopts only `di_gen` and `di_mode`

Source: `trap-xfs-inode-from-disk-free-image-adopts-only-gen-and-mode`. Upstream `xfs_inode_from_disk` returns right after copying `di_gen` and `di_mode` when the mode is 0 ("If the inode is unused ... we shouldn't mess with the uninitialized part of it"). Upstream only ever fills a freshly zeroed in-core inode, so that is safe there.

- **MXFS adopts into live inodes.** Reloads adopt platter images INTO live in-core inodes (`P116-ZOMBIE-ADOPT`, `P103-RELOAD-REUSE-ADOPT`, the recycle gate). Adopting a peer's FREE image therefore leaves the dead life's `i_nblocks`, `i_disk_size`, data/attr fork state and intent flags (`MXFS_IF_LOCAL_UNLINK`) in core under a mode-0 shell.
- **What it broke** (`D-CREATE-ON-ZOMBIE-SHELL-INHERITS-DEAD-LIFE-NBLOCKS`, found session 37 on lap q6dc1, 2/net/mesh/direct): a create recycled such a shell, the recycle's `P-RECYCLE-SANITIZE` arm was gated on `i_mode != 0`, and `xfs_inode_init` only ASSERTs `i_nblocks == 0` (compiled out). The new empty file's core went home with nblocks 1 and no extents and failed `xfs_dinode_verify` (`xfs_inode_buf.c` 'nextents + naextents == 0 && nblocks != 0') on every node. A new file that got extents carried a silently inflated count.
- **How to apply:**
  - Any code that adopts a free image into an existing in-core inode must reset the in-core fields itself (the `P-RECYCLE-SANITIZE` arm / `mxfs_dlm_reset_inode_for_create` are the existing resets); never assume `xfs_inode_from_disk` did.
  - A cold audit reading CLEAN said nothing about block counts until `chk_mxfs` gained the `P-NBLOCKS-MISMATCH` check (session 37 source): CAW laps pwc1/pwc2 carried this corruption and were judged CLEAN.
  - `+0x80a` of `xfs_dinode_verify.part.0` is the nblocks-without-extents check only for builds of that source; resolve offsets with `nm mxfs.ko | grep 'xfs_dinode_verify\.part\.0$'` then `gdb -batch -ex 'info line *(0x<addr>+0x80a)' mxfs.ko` (gdb cannot parse the `.part.0` name directly).
