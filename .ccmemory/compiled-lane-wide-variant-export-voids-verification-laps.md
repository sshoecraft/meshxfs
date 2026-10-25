---
name: compiled-lane-wide-variant-export-voids-verification-laps
description: Lane-queue exports of MXFS_TEST_ENV/MXFS_MPATH_TMO make every verify/calibrate lap a variant that counts zero; set inline or declare --variant.
metadata:
  type: feedback
tags: [compiled, defects, verification, run.sh, lane-queue]
---

Assorted tail (one note): a trap about variant-making environment exports in lane queues voiding verification and calibration batches.

## Mechanism
- A calibration or verification batch declared with no `--variant` counts no lap whose ledger `variant` is non-empty (`tools/defects.py` `unplanned_variant`). run.sh derives a lap's variant from MXFS_TEST_ENV, MXFS_MPATH_TMO, MXFS_EXTRA_MODARGS, MXFS_RIG_BUDGETS, MXFS_RETIRE_CONTRACT, MXFS_STRACE_RANK; `tools/batch_lap.py` also adds the marker's prep modargs. `trap-lane-wide-variant-export-voids-every-verification-lap`

## What bit
- Lane g8b_a22 exported `MXFS_TEST_ENV=PF_KEEP_KMSG=1` at the top of its queue so the control's kernel logs were kept. The same export ran under the verification step, so all 25 laps of the 39-lap 8-node NLINK1 verification (b20261024-802114) were variants and counted zero. `trap-lane-wide-variant-export-voids-every-verification-lap`
- The session that queued it reported "21 of 21 passed with exposure" and held the next freeze ~2.5 h for it. Nothing refused or warned before the attempt-23 draft of D-VERIFY-LAPS-UNDER-A-LANE-WIDE-TEST-ENV-RUN-AS-VARIANTS-AND-COUNT-NOTHING. `trap-lane-wide-variant-export-voids-every-verification-lap`

## How to apply
- Never put a variant-making export at the top of a lane queue that runs a verify or calibrate batch. Set it inline on the control's run.sh calls only (`MXFS_TEST_ENV=PF_KEEP_KMSG=1 MXFS_BATCH=$B ./run.sh ...`), or `env -u NAME` on the batch line. `trap-lane-wide-variant-export-voids-every-verification-lap`
- A calibration that needs kept logs declares them as its `--variant` (run.sh appends `batch:<variant>`, which then matches). `trap-lane-wide-variant-export-voids-every-verification-lap`
- Before trusting a running batch's progress, read its ledger lines' `variant` field (`grep '"batch": "<id>"' data/criteria.runs.jsonl`), not the lane log's PASS lines. `trap-lane-wide-variant-export-voids-every-verification-lap`
