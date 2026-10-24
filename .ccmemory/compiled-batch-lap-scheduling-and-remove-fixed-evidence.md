---
name: compiled-batch-lap-scheduling-and-remove-fixed-evidence
description: Assorted lessons (0.90.134): keep precheck/power-up lanes off mid-batch lanes; what release-reviewer demands before remove-fixed is accepted.
metadata:
  type: feedback
tags: [compiled, batch-laps, release-reviewer, defects, run.sh]
---

Assorted group (two notes, no single topic beyond "what burns lap/batch places and what gets a defect removal rejected"); both come from the 0.90.134 session of 2026-10-24.

## Precheck lanes beside batch lanes (`precheck-lanes-beside-batch-lanes-spend-their-plan-places`)

- Laps such as tests/peer_window_lap.sh (prep bound 120 s) and tests/live_holder_shard_lap.sh (88 s) time their own `run.sh prep_cluster`, and that bound counts run.sh's pre-prep waits: the LUN pool lock and the shared power-up lock (scripts/lab_power.sh up holds /tmp/mxfs_host_powerup.lock exclusive until its guests answer ssh; the preflight takes it shared).
- Observed 2026-10-24: a precheck holding the pool lock 20 s on purpose (batch_lap_wait) made an 8-node prep wait 37 s, and some other power-up made a 2-node prep's preflight wait 31 s; both laps ended rc=2 'prep_cluster rc=124' after the prep itself printed OK.
- An INCOMPLETE lap uses up a place in the batch plan (defects.plan_laps counts PASS/FAIL/INCOMPLETE), so the control can never be measured without a reviewed settlement, which needs node kernel logs that an aborted prep never collected.
- A bare (groupless) run.sh takes /tmp/mxfs_run.lock EXCLUSIVELY (run.sh:432-446) and refuses beside any group run, so a lap whose control arm runs a bare prep (in_gate_prep) can only measure with no other lane up.
- How to apply: run prechecks that power VMs up or hold the pool lock only when no batch lane is mid-batch, or in a solo lane; schedule laps that need exclusivity in a solo lane started when every other lane is DONE.

## What release-reviewer rejects for remove-fixed (`removal-control-must-grade-the-records-own-failure-and-every-changed-file`)

Three remove-fixed rejections in one session share a pattern; check BEFORE proposing:

- **The control must reproduce the record's own failure, not just take the fix's branch.** D-CAWMPATH-NLINK1 (P20261024-9cdfae): lap:relog_auth forced the re-log arm on a directory whose in-core and on-disk copies were equal, so 8/8 control FAIL only showed the knob picks its branch. The record's failure (chk_clean CORRUPT, a file named twice with nlink 1 after path_answer_lost) was never run fix-off. The reviewer wants a fix-off calibration graded on the record's own check, at every node count the record was seen at (4 AND 8).
- **Every file the fix changed must be measured.** D-MEASURE-REFUSES (P20261024-ce5c62): the reviewer diffed tools/harness_batch.py's sha256 between attempt manifests (tests/evidence/candidates/<ver>_<freeze>.files.json) and found a second change the lap only grepped the source for. Grep-for-text checks are not measurement. Give each part its own switch and a lap case that calls the code path.
- **Every trigger the summary names must have a lap.** D-DRBD-WRITE-BOUND-ARM (P20261024-87729d): summary said "bare count, and with MXFS_NODES unset"; laps only set MXFS_NODES=2.
- An infra-proven settlement of an INCOMPLETE lap (P20261024-982314) needs the nodes' kernel logs for the window AND the unmeasured tail between the prep's last logged step and the kill; pool-lock log lines alone were not enough.
- A record whose next step defers to the owner (tauth Makefile edit) cannot be removed by arguing around it; the reviewer holds it for an owner ruling.
- How to apply: before `defects.py propose remove-fixed`, re-read the record's summary for every trigger and configuration, diff the frozen manifests for every file the fix touched, and confirm the control's FAIL is the record's symptom.
