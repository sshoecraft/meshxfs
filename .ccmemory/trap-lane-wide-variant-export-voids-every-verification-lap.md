---
name: trap-lane-wide-variant-export-voids-every-verification-lap
description: A lane queue's `export MXFS_TEST_ENV=` / `MXFS_MPATH_TMO=` makes every verify/calibrate lap a variant that counts nothing; nothing warned (25 laps lo…
metadata:
  type: feedback
---

A calibration or verification batch declared with no `--variant` counts no lap whose ledger `variant` is non-empty (`tools/defects.py` `unplanned_variant`). run.sh derives a lap's variant from MXFS_TEST_ENV, MXFS_MPATH_TMO, MXFS_EXTRA_MODARGS, MXFS_RIG_BUDGETS, MXFS_RETIRE_CONTRACT, MXFS_STRACE_RANK (and tools/batch_lap.py also adds the marker's prep modargs).

What bit: lane g8b_a22 exported `MXFS_TEST_ENV=PF_KEEP_KMSG=1` at the top of its queue so the control's kernel logs were kept; the same export ran under the verification step, so all 25 laps of the 39-lap 8-node NLINK1 verification (b20261024-802114) were variants and counted zero. The session that queued it reported "21 of 21 passed with exposure" and held the next freeze ~2.5 h for it. Nothing refused or warned before the attempt-23 draft of D-VERIFY-LAPS-UNDER-A-LANE-WIDE-TEST-ENV-RUN-AS-VARIANTS-AND-COUNT-NOTHING.

How to apply:
- Never put a variant-making export at the top of a lane queue that runs a verify or calibrate batch. Set it inline on the control's run.sh calls only (`MXFS_TEST_ENV=PF_KEEP_KMSG=1 MXFS_BATCH=$B ./run.sh ...`), or `env -u NAME` on the batch line.
- A calibration that needs kept logs declares them as its `--variant` (run.sh appends `batch:<variant>`, which then matches).
- Before trusting a running batch's progress, read its ledger lines' `variant` field (`grep '"batch": "<id>"' data/criteria.runs.jsonl`), not the lane log's PASS lines.
