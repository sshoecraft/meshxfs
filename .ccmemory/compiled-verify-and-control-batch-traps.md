---
name: compiled-verify-and-control-batch-traps
description: Assorted defects.py batch traps: variant-prepped verify laps count zero, verify args claiming empty-input branches, settled-lap batches cannot measur…
metadata:
  type: feedback
tags: [compiled, feedback, defects-py, verify, control-batch, release-gate, trap, release-reviewer]
---

Assorted group (loosely joined): three traps in `tools/defects.py` verification and control batches, where the batch or proposal looks sound but the gate counts nothing or rejects it.

# 1. Verify laps on a variant-prepped pair never count

Source: `trap-verify-laps-on-a-variant-prepped-pair-never-count`.

**Trap.** A verification batch has no variant (plan-verify takes no --variant), and `tools/defects.py unplanned_variant` drops every lap whose ledger run carries any variant. A batch lap run on a pair that `run.sh prep_cluster` formed with `MXFS_EXTRA_MODARGS=...` is recorded with `variant: marker_modargs=<those args>` (taken from the cluster marker), even when the lap's own command sets nothing. So six exposed PASSes of b20261024-565ac2 (8/disk/caw/mpath, prepped with dead_timeout_ms=12000) counted zero, after the release-reviewer had approved the verify proposal. The refusal text then said "PASS without exposure", which points at the probe, not the variant (D-VERIFY-REFUSAL-NAMES-VARIANT-LAPS-AS-UNEXPOSED).

**What to do.** Before queueing a verification batch, check the prep step that forms its pair: no MXFS_EXTRA_MODARGS and no MXFS_TEST_ENV that run.sh records as a variant. Controls may run on a variant (the knob is their variant), but the fix-on batch must run the candidate as frozen. If the defect only shows with a non-default module argument, find an exposure that needs none (the rejoin lap now exposes on prep's own log_repeat_limit=0 against the module default 1) before spending rig time on the verification. A quick check after lap 1: `grep '"batch": *"<bid>"' data/criteria.runs.jsonl | head -1` and read its `variant` field.

# 2. A verify argument must not claim a branch whose input was empty on the rig

Source: `trap-verify-argument-claiming-a-branch-whose-input-was-empty-on-the-rig`.

**Trap.** When a lap compares values between nodes (module parameters, keys, contract strings), a branch whose input is empty on this rig compares empty with empty and passes however the code behaves. Claiming it as covered in a verify proposal gets the proposal rejected even when the batch itself is sound. Observed on P20261024-52e185 (rejoin module arguments): the argument named target_retire_contract as "the contract argument whose quoting the rejection named", but prep on the rig reports `PREP retire-contract: NONE`, so neither node loaded one.

The same review also rejected two overstatements about the control: (1) "with no extra arguments nothing is measured", when the control also failed on a non-extra argument (log_repeat_limit); (2) implying the control produced the defect's user-visible effect (mixed death windows), when the candidate's default window equalled the variant's (12 s) so the effective windows matched.

**What to do before filing a verify.** For each compared field, read one control lap's and one fix-on lap's captured values and list as untested every field that was empty or equal by default on both sides. State what the control's failures actually were (every differing field, from its own lines), and say plainly whether the control showed the downstream effect or only the root difference. No new runs were needed to fix the argument; the resubmission was P20261024-d7c365.

# 3. A batch with a settled lap can never be measured or topped up

Source: `trap-batch-with-settled-lap-can-never-be-measured-or-topped-up`.

**Trap.** Settling an INCOMPLETE lap of a control or calibration batch (infra-proven or detector-defect approval) does not let the batch close. `tools/defects.py check_batch_lap` counts PASS, FAIL and INCOMPLETE laps against `planned` and refuses a lap past it, and `tools/harness_batch.py --batch B` resumes with `planned - every recorded lap` = 0, so no replacement lap can run. `cmd_measure` meanwhile requires PASS + FAIL == planned, so it refuses ("planned 10 laps and has 9; run the rest first"). Chaining "the batch's last lap" after a settlement therefore runs nothing (observed: lane g8b_a17b, control b20261024-1d2fde, 2026-10-24; plan-verify then refused "no measured rate").

**What to do.** Do not queue a follow-up lap for a settled batch. Until measure counts a settled lap toward the plan (D-MEASURE-REFUSES-A-BATCH-WHOSE-SETTLED-LAP-CHECK-BATCH-LAP-COUNTED-AS-RUN, draft fix with MXFS_MEASURE_COUNT_SETTLED=0 as its control), such a batch stays open; once the fix is in the frozen tree, measure it directly. If neither is possible, declare a fresh control batch rather than trying to top the old one up.

**Why it matters.** Each settled-lap follow-up costs a lane power cycle and a chained wait on a configuration lock for zero laps, and the failed plan-verify reads like progress in the lane summary.
