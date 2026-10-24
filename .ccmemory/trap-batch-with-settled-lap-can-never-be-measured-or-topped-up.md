---
name: trap-batch-with-settled-lap-can-never-be-measured-or-topped-up
description: A control/calibration batch holding a settled INCOMPLETE lap: check_batch_lap refuses a replacement lap and measure refuses at planned-1
metadata:
  type: feedback
---

**Trap.** Settling an INCOMPLETE lap of a control or calibration batch (infra-proven or detector-defect approval) does not let the batch close. `tools/defects.py check_batch_lap` counts PASS, FAIL and INCOMPLETE laps against `planned` and refuses a lap past it, and `tools/harness_batch.py --batch B` resumes with `planned - every recorded lap` = 0, so no replacement lap can run. `cmd_measure` meanwhile requires PASS + FAIL == planned, so it refuses ("planned 10 laps and has 9; run the rest first"). Chaining "the batch's last lap" after a settlement therefore runs nothing (observed: lane g8b_a17b, control b20261024-1d2fde, 2026-10-24; plan-verify then refused "no measured rate").

**What to do.** Do not queue a follow-up lap for a settled batch. Until measure counts a settled lap toward the plan (D-MEASURE-REFUSES-A-BATCH-WHOSE-SETTLED-LAP-CHECK-BATCH-LAP-COUNTED-AS-RUN, draft fix with MXFS_MEASURE_COUNT_SETTLED=0 as its control), such a batch stays open; once the fix is in the frozen tree, measure it directly. If neither is possible, declare a fresh control batch rather than trying to top the old one up.

**Why it matters.** Each settled-lap follow-up costs a lane power cycle and a chained wait on a configuration lock for zero laps, and the failed plan-verify reads like progress in the lane summary.
