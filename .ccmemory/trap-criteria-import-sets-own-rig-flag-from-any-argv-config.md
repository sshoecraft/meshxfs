---
name: trap-criteria-import-sets-own-rig-flag-from-any-argv-config
description: criteria.py sets MXFS_OWN_RIG at import when ANY argv names an own-rig config (2/net/mesh/drbd); a probe with the config in argv masks own-rig bugs
metadata:
  type: feedback
tags: [criteria.py, MXFS_OWN_RIG, control-batch, harness_batch, probe, drbd, release_run]
---

`tools/criteria.py` runs, at import time (criteria.py:106-113), a scan of `sys.argv[1:]`: if any argument matches `<n>/<class>/<method>/<attach>` and that attachment has its own board (data/configurations.json `attaches.<a>.board`, e.g. drbd), it does `os.environ.setdefault("MXFS_OWN_RIG", "1")` and switches CRITERIA to that board.

That is a property of the PROCESS's command line, not of the call. A probe that imports criteria (directly, or through tools/release_run.py, tools/defects.py, ...) and passes `2/net/mesh/drbd` as a command-line argument gets the own-rig flag for free, so it cannot observe a bug whose whole shape is "the flag was not set" (the orchestrator, `release_run.py start <candidate>`, names no configuration in its argv).

What happened (0.90.134, D-RELEASE-RUN-BOARD-VERDICT-GRADED-NO-ROW-OF-AN-OWN-RIG-BOARD): the lap `tests/release_board_verdict_lap.py` called `board_verdict(cand, sys.argv[3], ...)` in a `python3 -c PROBE root cand 2/net/mesh/drbd board` subprocess. The fix-out control b20261022-ec8648 passed 20 of 20 laps (measured nothing). With the inputs moved to environment variables, control b20261022-4233e9 failed 20 of 20 with the fix out and the fixed tree passes.

Apply:
- A probe or lap that must reproduce the orchestrator's environment passes configurations through env vars or stdin, never argv, and pops MXFS_OWN_RIG and MXFS_CRIT from the child env.
- Before running a control batch, apply the fix diff in reverse by hand and run ONE lap: if it does not fail, the lap is not measuring the defect. A control that passes is a recorded, closed batch that bounds nothing.
