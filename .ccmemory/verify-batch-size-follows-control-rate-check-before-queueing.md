---
name: verify-batch-size-follows-control-rate-check-before-queueing
description: harness_batch.py verify sizes N from the control's k/n at run time; a 2-of-10 control gave 281 laps (12.5 h). Check N before queueing a verify.
metadata:
  type: feedback
---

A lane step `tools/harness_batch.py verify <record> --control <bid>` calls `defects.py plan-verify` when it starts and runs every lap of the N it prints (Clopper-Pearson lower bound of the control's k/n at delta=alpha=0.005). A weak control makes N huge: D-FENCED-NODE-INODE-LOCK-EIO's control b20261024-f40646 failed 2 of 10 (2 of 6 exposed) and its verify was declared at 281 laps of ~162 s, about 12.5 h on test1/test2, blocking the rest of the g2 lane and the solo lane behind it.

- 10/10 gives N=6, 9/10 about 9; 7/7 needs 9; 20/20 needs 4. Anything under ~5/10 is the arithmetic saying "build a better reproducer first" (tools/defects.py header).
- Before queueing a verify behind a control that is still running, decide what the lane does if the control comes in weak; after it closes, run `defects.py plan-verify ... ` by hand (it only declares) or read the control's k/n and skip the verify step.
- Stopping a running verify step without orphaning its lap: `kill -STOP <harness_batch pid>` (found by walking /proc/<lane pid>/task/*/children, never ps/pgrep), wait for the lap's batch_lap.py child to exit (it becomes a zombie; `tail --pid` does not notice a zombie, so check /proc/<pid>/stat state Z), then `kill -TERM` and `kill -CONT` the driver. Its handler restores the tree and the lane goes on to its next step (rc=143). The batch stays open; note it on the record so nobody resumes it.
