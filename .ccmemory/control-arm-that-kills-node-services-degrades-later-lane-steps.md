---
name: control-arm-that-kills-node-services-degrades-later-lane-steps
description: A fix-off control that reproduces a service-killing harness defect leaves those nodes degraded (iscsid stayed dead) for every later step of the lane.
metadata:
  type: feedback
---

Control b20261024-37b839 (D-MERGE-OVERRUN-LAP-CLEANUP-FUSER-KILLS-ROOT-FS-USERS-WHEN-NOT-MOUNTED, MERGE_CLEANUP_GATE=0) SIGKILLed sshd, journald, udevd and iscsid on test31/test32 by design. systemd restarted sshd/journald/udevd, but iscsid stayed in the failed state for the rest of the control, the whole fix-on batch and the next verification in the same lane (found by the release-reviewer from the lap's 'before [..] after [.. 0]' pid line, batch_laps/b20261024-37b839/*-f7ade8cb.log:6-7). With iscsid dead an iSCSI connection drop cannot recover, so a later lap on those nodes can fail in a way that looks like the filesystem's.

- After any control arm whose defect kills or disturbs node services, put a step in the lane that restores the nodes before anything else runs on them: `systemctl start iscsid` (it adopts existing sessions), or a forced prep / VM reboot.
- When reading a lane's later results on such nodes, check `systemctl is-active iscsid` was active in that window.
