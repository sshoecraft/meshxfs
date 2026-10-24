---
name: compiled-batch-lane-control-and-verify-hazards
description: Assorted lane lessons: a service-killing control arm leaves iscsid dead for later steps; verify N is sized from the control's k/n, so check it before…
metadata:
  type: feedback
tags: [compiled, harness-batch, lane, control, verify, iscsid]
---

Assorted group (loose tail): two lessons about batch lanes (`tools/harness_batch.py`, `tools/defects.py`), both about how a control arm's outcome affects what runs after it in the same lane.

## A control arm that kills node services degrades later lane steps

Source: `control-arm-that-kills-node-services-degrades-later-lane-steps`

Control b20261024-37b839 (D-MERGE-OVERRUN-LAP-CLEANUP-FUSER-KILLS-ROOT-FS-USERS-WHEN-NOT-MOUNTED, MERGE_CLEANUP_GATE=0) SIGKILLed sshd, journald, udevd and iscsid on test31/test32 by design. systemd restarted sshd/journald/udevd, but iscsid stayed in the failed state for the rest of the control, the whole fix-on batch and the next verification in the same lane (found by the release-reviewer from the lap's 'before [..] after [.. 0]' pid line, batch_laps/b20261024-37b839/*-f7ade8cb.log:6-7). With iscsid dead an iSCSI connection drop cannot recover, so a later lap on those nodes can fail in a way that looks like the filesystem's.

- After any control arm whose defect kills or disturbs node services, put a step in the lane that restores the nodes before anything else runs on them: `systemctl start iscsid` (it adopts existing sessions), or a forced prep / VM reboot.
- When reading a lane's later results on such nodes, check `systemctl is-active iscsid` was active in that window.

## Verify batch size follows the control's rate: check before queueing

Source: `verify-batch-size-follows-control-rate-check-before-queueing`

A lane step `tools/harness_batch.py verify <record> --control <bid>` calls `defects.py plan-verify` when it starts and runs every lap of the N it prints (Clopper-Pearson lower bound of the control's k/n at delta=alpha=0.005). A weak control makes N huge: D-FENCED-NODE-INODE-LOCK-EIO's control b20261024-f40646 failed 2 of 10 (2 of 6 exposed) and its verify was declared at 281 laps of ~162 s, about 12.5 h on test1/test2, blocking the rest of the g2 lane and the solo lane behind it.

- 10/10 gives N=6, 9/10 about 9; 7/7 needs 9; 20/20 needs 4. Anything under ~5/10 is the arithmetic saying "build a better reproducer first" (tools/defects.py header).
- Before queueing a verify behind a control that is still running, decide what the lane does if the control comes in weak; after it closes, run `defects.py plan-verify ... ` by hand (it only declares) or read the control's k/n and skip the verify step.
- Stopping a running verify step without orphaning its lap: `kill -STOP <harness_batch pid>` (found by walking /proc/<lane pid>/task/*/children, never ps/pgrep), wait for the lap's batch_lap.py child to exit (it becomes a zombie; `tail --pid` does not notice a zombie, so check /proc/<pid>/stat state Z), then `kill -TERM` and `kill -CONT` the driver. Its handler restores the tree and the lane goes on to its next step (rc=143). The batch stays open; note it on the record so nobody resumes it.
