---
name: trap-lane-batches-after-a-fenced-pair-abort-and-get-named-to-the-wrong-record
description: A DRBD lap that fences a node leaves it inhibited; every later lane batch aborts at prep and harness_batch names those aborts as cells of its record
metadata:
  type: feedback
---

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
