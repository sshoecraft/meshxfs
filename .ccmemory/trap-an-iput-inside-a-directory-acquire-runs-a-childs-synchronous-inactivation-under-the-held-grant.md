---
name: trap-an-iput-inside-a-directory-acquire-runs-a-childs-synchronous-inactivation-under-the-held-grant
description: TRAP (0.90.123): on a cluster the last iput inactivates synchronously and takes the inode's DLM lock; doing it inside a dir acquire deadlocks cross-n…
metadata:
  type: feedback
---

On a multi-node mount, `xfs_inode_mark_reclaimable` (xfs/xfs_icache.c) runs `xfs_inactive` SYNCHRONOUSLY in whatever task drops an inode's last reference (journal_info == NULL), and inactivation takes that inode's DLM lock (EX). So any `iput`/`xfs_irele`/`shrink_dcache_parent`/`d_prune_aliases` is a potential cross-node lock acquire.

While a directory's acquire is open (i_dlm_state ACQUIRING = 4) the grant is already on disk and every peer BAST is deferred until the acquire ends. Dropping a child's last reference inside that window (the dir reload's `shrink_dcache_parent` did, at the end of `mxfs_dlm_reload_inode`) waits for the child's lock while holding the parent; a peer in `rmdir` (xfs_lock_two_inodes: child, then parent) holds the child and waits for the parent. Measured 16/disk/caw/mpath 0.90.122: 480 s until the child lock timed out, 15 nodes stuck (D-DIR-RELOAD-CHILD-INACTIVATION-DEADLOCK).

How it showed: peers' P-ACQ-STUCK on the dir with hpr=<one slot> unchanged for minutes; that node's P-DIRBAST shows state=4 ex=0 pr=0 (no local holder, yet never released); its own P-ACQ-STUCK on a child; P35-ACQBAST-HONOR for the dir in the same millisecond the child lock returned. The holder's stack was never captured — the timing pinned it.

Rule of thumb: never drop an inode reference inside an acquire window or under a held DLM grant; queue it (0.90.123 i_mxfs_dshrink_work on the inode-bast wq, igrab-held, arm-gated). P-SYNC-INACT-SLOW (>=10 s) prints the dropping caller's stack; P-DSHRINK-INACT witnesses the deferred path.

Reading cross-node timelines: map each node's kmsg monotonic time to its wall clock with the median of (realms= minus mono ms) over its own lines, then subtract the clock_test<N> node-minus-host offset; a holder bit hpr/hex=0x4000 is disklock slot 14, read a node's own slot from its P291-EXWIN slot= lines.
