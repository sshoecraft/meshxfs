---
name: removal-control-must-grade-the-records-own-failure-and-every-changed-file
description: release-reviewer rejects remove-fixed when the control only flips the switch's branch, or when a fix file the attempt manifests show changed is unmea…
metadata:
  type: feedback
---

Three remove-fixed rejections in one session (0.90.134, 2026-10-24) share a pattern worth checking BEFORE proposing:

- **The control must reproduce the record's own failure, not just take the fix's branch.** D-CAWMPATH-NLINK1 (P20261024-9cdfae): lap:relog_auth forced the re-log arm on a directory whose in-core and on-disk copies were equal, so 8/8 control FAIL only showed the knob picks its branch. The record's failure (chk_clean CORRUPT, a file named twice with nlink 1 after path_answer_lost) was never run fix-off. The reviewer wants a fix-off calibration graded on the record's own check, at every node count the record was seen at (4 AND 8).
- **Every file the fix changed must be measured.** D-MEASURE-REFUSES (P20261024-ce5c62): the reviewer diffed tools/harness_batch.py's sha256 between attempt manifests (tests/evidence/candidates/<ver>_<freeze>.files.json) and found a second change the lap only grepped the source for. Grep-for-text checks are not measurement. Give each part its own switch and a lap case that calls the code path.
- **Every trigger the summary names must have a lap.** D-DRBD-WRITE-BOUND-ARM (P20261024-87729d): summary said "bare count, and with MXFS_NODES unset"; laps only set MXFS_NODES=2.
- An infra-proven settlement of an INCOMPLETE lap (P20261024-982314) needs the nodes' kernel logs for the window AND the unmeasured tail between the prep's last logged step and the kill; pool-lock log lines alone were not enough.
- A record whose next step defers to the owner (tauth Makefile edit) cannot be removed by arguing around it; the reviewer holds it for an owner ruling.

How to apply: before `defects.py propose remove-fixed`, re-read the record's summary for every trigger and configuration, diff the frozen manifests for every file the fix touched, and confirm the control's FAIL is the record's symptom.
