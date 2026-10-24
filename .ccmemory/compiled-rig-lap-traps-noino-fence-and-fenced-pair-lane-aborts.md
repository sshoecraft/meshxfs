---
name: compiled-rig-lap-traps-noino-fence-and-fenced-pair-lane-aborts
description: Assorted rig-lap traps: forcing no-inode releases needs pathload dir churn; a fenced pair leaves an inhibit that aborts later lane batches
metadata:
  type: feedback
tags: [compiled, rig, lap, noino, fence, drbd, harness]
---

Assorted group (loose tail the clusterer could not fit to one topic): two traps about rig laps that measure nothing, one for the no-inode release path, one for lane batches after a fenced pair.

## No-inode release laps: stat of evicted files is vacuous
Source: `trap-no-inode-releases-come-from-shared-dir-churn-not-stats-of-evicted-files`

**What bit us:** a lap meant to drive MXFS's no-inode release path (xfs/xfs_mxfs_noino.c, mxfs_noino_drain_fence) did it this way:
- node S created 40 files, synced, and ran `echo 2 > /proc/sys/vm/drop_caches`;
- the peer then stat'ed them.

The peer drew 40 `v5_bast ... mode=3` BASTs on S, each served in ~10 ms, and no fence line ever appeared. That was VACUOUS 6 of 6 laps across two lanes. Those BASTs are not no-inode releases (they are PR BASTs served without the no-inode drain fence).

**Separate trap:** with the frozen item the only thing in the AIL, the fence's push target (`ail_max`) is that item itself, so the fence lands at once. The node must keep committing newer items behind it.

**What works:** run tests/mpath/pathload.py on both nodes. Its create/rename/unlink churn in one shared directory makes a peer reuse inode numbers this node still holds a corpse grant for, and that is the no-inode release. tests/noino_acq_takeover_ab.sh documents the mechanism (H-AT1).

Exposure is still probabilistic: about one 30 s window in two at 2 nodes. Size control and verification batches on exposed laps.

**Also: never edit a lap script while a lane is running it.** bash reads scripts incrementally. Two edits mid-lane here made those laps' results meaningless; write a new queue after the lane ends.

Lap: tests/evidence/drafts/noino_fence_efd_hold_lap.sh. Record: D-8CAWMPATH-SURVIVOR-SHUTS-DOWN-ON-NOINO-EFI-WEDGE-DURING-PEER-FENCE.

## Lane batches after a fenced pair abort and get named to the wrong record
Source: `trap-lane-batches-after-a-fenced-pair-abort-and-get-named-to-the-wrong-record`

**What bit us (session after 67, 0.90.134):** the g2 lane ran the third_vote verification and then the yield-scan, marker and fsx batches. Third_vote lap 3 restored the rig's ssh node fence, and test1 power-fenced test2 during the remount. tools/rig_fence_virsh.sh left `~/.local/state/mxfs-rig-fence/test2.inhibit`, and nothing in scripts/drbd_rig.sh step_third_vote_test releases it.

**What followed:**
- Lap 4 aborted at power-up.
- Then two whole controls ran 10 laps each in 24 s, all ABORT at prep with exposure 0, and printed "10 of 10 laps failed with the fix out".
- `harness_batch.py control` attached all 20 aborts as cells of the yield-scan and marker records.
- The stored rates were exposure-filtered ("0 of 0"), so no false rate was recorded.

**How to apply:**
- After any DRBD or fence lap in a lane, read the lane's next step logs for `fenced and inhibited` / `could not start` before trusting a control.
- A control that finishes 10 laps in seconds measured nothing.
- Move the aborted laps' cells with `tools/defects.py update <wrong record> --drop-cell ... --drop-why` to a record that names the real cause.
- Release a stale inhibit only with `tools/rig_fence_virsh.sh release <target> <episode> <requester>`, after its episode is over.
- Guest journals on test1..32 are `Storage=volatile`, so a powered-off or fenced boot's logs are gone. Evidence must be captured inside the step: dmesg, `drbdsetup events`, the fence handler's own log.
- Record: D-DRBD-THIRD-VOTE-RESTORE-POWER-FENCED-LIVE-TEST2-AND-LEFT-IT-INHIBITED.
