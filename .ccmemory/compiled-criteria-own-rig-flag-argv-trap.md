---
name: compiled-criteria-own-rig-flag-argv-trap
description: criteria.py sets MXFS_OWN_RIG at import from any argv naming an own-rig config (2/net/mesh/drbd); a probe with config in argv masks own-rig bugs
metadata:
  type: feedback
tags: [compiled, criteria.py, MXFS_OWN_RIG, control-batch, harness_batch, probe, drbd, release_run]
---

Assorted-tail group of one note (the clusterer found no sibling); the single topic is that a probe or lap carrying an own-rig configuration in `argv` cannot reproduce the orchestrator's environment, because `tools/criteria.py` sets `MXFS_OWN_RIG` from `sys.argv` at import. Source: `trap-criteria-import-sets-own-rig-flag-from-any-argv-config`.

## Mechanism

- `tools/criteria.py` runs, at import time (criteria.py:106-113), a scan of `sys.argv[1:]`. If any argument matches `<n>/<class>/<method>/<attach>` and that attachment has its own board (`data/configurations.json` `attaches.<a>.board`, e.g. drbd), it does `os.environ.setdefault("MXFS_OWN_RIG", "1")` and switches CRITERIA to that board. `trap-criteria-import-sets-own-rig-flag-from-any-argv-config`
- That is a property of the PROCESS's command line, not of the call. A probe that imports criteria (directly, or through `tools/release_run.py`, `tools/defects.py`, ...) and passes `2/net/mesh/drbd` as a command-line argument gets the own-rig flag for free, so it cannot observe a bug whose whole shape is "the flag was not set". The orchestrator, `release_run.py start <candidate>`, names no configuration in its argv. `trap-criteria-import-sets-own-rig-flag-from-any-argv-config`

## What happened (0.90.134, D-RELEASE-RUN-BOARD-VERDICT-GRADED-NO-ROW-OF-AN-OWN-RIG-BOARD)

- The lap `tests/release_board_verdict_lap.py` called `board_verdict(cand, sys.argv[3], ...)` in a `python3 -c PROBE root cand 2/net/mesh/drbd board` subprocess. `trap-criteria-import-sets-own-rig-flag-from-any-argv-config`
- The fix-out control b20261022-ec8648 passed 20 of 20 laps (measured nothing). With the inputs moved to environment variables, control b20261022-4233e9 failed 20 of 20 with the fix out, and the fixed tree passes. `trap-criteria-import-sets-own-rig-flag-from-any-argv-config`

## Apply

- A probe or lap that must reproduce the orchestrator's environment passes configurations through env vars or stdin, never argv, and pops `MXFS_OWN_RIG` and `MXFS_CRIT` from the child env. `trap-criteria-import-sets-own-rig-flag-from-any-argv-config`
- Before running a control batch, apply the fix diff in reverse by hand and run ONE lap: if it does not fail, the lap is not measuring the defect. A control that passes is a recorded, closed batch that bounds nothing. `trap-criteria-import-sets-own-rig-flag-from-any-argv-config`
