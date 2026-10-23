---
name: trap-a-fix-switch-exported-to-a-batch-step-also-switches-the-batch-tools
description: A knob control sets its fix switch in the lap's own env (`-- env K=0 <lap>`), never `export K=0`: several switches also govern harness_batch/batch_lap
metadata:
  type: feedback
tags: [harness_batch, control, knob, switch, batch_lap, trap]
---

When a tooling record's fix sits behind an environment switch and its control runs through
`tools/harness_batch.py control ... --knob ... -- <lap>`, put the switch on the lap command only:

    python3 tools/harness_batch.py control R --knob "K=0 (...)" ... -- env K=0 tests/<lap>

never `export K=0` on the lane step before it.

Why: several of these switches also govern the machinery that runs and records the control
(found while queuing attempt 2026-10-23T15:56:24Z of 0.90.134, lane
tests/evidence/lanes/local_a11_tooling_20261023T155735Z):
- `MXFS_HARNESS_BATCH_REREAD=0` makes tools/harness_batch.py itself keep its stale ledger copy, so
  the control batch would stop after its first lap exactly as the defect did.
- `MXFS_BATCH_LAP_KILLPG=0` and `MXFS_BATCH_LAP_STALL=0` change how tools/batch_lap.py bounds and
  grades every lap of the batch, the control's own laps included.
- `MXFS_RELEASE_STEP_SETTLE=0` reverts tools/defects.py parse_cell to the first-two-colons split,
  which mis-parses every `lap:<harness>` cell the batch tools name (row `lap`, stamp
  `<harness>:...`).

An exported switch measures the fixed tool with broken recording machinery, not the defect.
`env K=0` in the lap command scopes it to the code under test; the verification step runs the
lap with no switch at all (default on). The g2 lanes of 2026-10-23 already did this for
BMBT_SKIP_READS (`-- env ROUNDS=3 BMBT_SKIP_READS=1 ...`); the exported form (`export
SR_SHARD_SELECT=0`) is safe only for a switch nothing but the harness reads.
