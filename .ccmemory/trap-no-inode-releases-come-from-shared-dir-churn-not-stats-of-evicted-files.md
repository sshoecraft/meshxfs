---
name: trap-no-inode-releases-come-from-shared-dir-churn-not-stats-of-evicted-files
description: A peer's stat of files a node evicted draws PR BASTs served without the no-inode drain fence; force no-inode releases with shared-dir churn (pathload)
metadata:
  type: feedback
---

**What bit us:** a lap meant to drive MXFS's no-inode release path (xfs/xfs_mxfs_noino.c, mxfs_noino_drain_fence) did it this way:
- node S created 40 files, synced, and ran `echo 2 > /proc/sys/vm/drop_caches`;
- the peer then stat'ed them.

The peer drew 40 `v5_bast ... mode=3` BASTs on S, each served in ~10 ms, and no fence line ever appeared. That was VACUOUS 6 of 6 laps across two lanes. Those BASTs are not no-inode releases.

**Separate trap:** with the frozen item the only thing in the AIL, the fence's push target (`ail_max`) is that item itself, so the fence lands at once. The node must keep committing newer items behind it.

**What works:** run tests/mpath/pathload.py on both nodes. Its create/rename/unlink churn in one shared directory makes a peer reuse inode numbers this node still holds a corpse grant for, and that is the no-inode release. tests/noino_acq_takeover_ab.sh documents the mechanism (H-AT1).

Exposure is still probabilistic: about one 30 s window in two at 2 nodes. Size control and verification batches on exposed laps.

**Also: never edit a lap script while a lane is running it.** bash reads scripts incrementally. Two edits mid-lane here made those laps' results meaningless; write a new queue after the lane ends.

Lap: tests/evidence/drafts/noino_fence_efd_hold_lap.sh. Record: D-8CAWMPATH-SURVIVOR-SHUTS-DOWN-ON-NOINO-EFI-WEDGE-DURING-PEER-FENCE.
