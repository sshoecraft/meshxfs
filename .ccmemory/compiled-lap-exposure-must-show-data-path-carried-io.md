---
name: compiled-lap-exposure-must-show-data-path-carried-io
description: A lap's EXPOSED must show the hazard's own data path carried I/O (specific sdev counters, both arms), not that the load ran by any path
metadata:
  type: feedback
tags: [compiled, feedback, testing, exposure, late-register, multipath, verification]
---

Opening line: group was kind `assorted` with a single note; the common topic is how a lap/verification batch must prove the hazard's trigger actually occurred before a verify or removal is proposed.

## Rule
A lap's EXPOSED that only proves the load ran (by any path) is not exposure. Read the specific path/sdev's own data counters in both arms first. `exposure-must-show-the-data-path-carried-io-not-just-the-load-ran`

## What happened
`tests/late_register_hold_lap.sh` (defect D-LATE-PATH-REGISTER-TIMED-OUT-MAY-EXECUTE-AFTER-A-FENCE-AND-RESTORE-THE-KEY, 2026-10-24) passed a 10/10 control and a 6/6 verification at two configurations, and the removal and one verify were still rejected (`data/reviews/P20261024-e7d188.md`, `data/reviews/P20261024-229ee1.md`). `exposure-must-show-the-data-path-carried-io-not-just-the-load-ran`

- EXPOSED printed when the victim's load completed operations through the multipath map by ANY path. The late path's own counters (sdb reads/writes in `state_<node>_*.txt`) did not move in either arm. With the other path up, dm-multipath sent nothing down the returning path, so the trigger (a write behind an unresolved REGISTER) was never reached. `exposure-must-show-the-data-path-carried-io-not-just-the-load-ran`
- The control's FAIL was the fix's own flag (held=0) plus requests_sent=7-8. That count is multipathd's 2 s checker TURs over a 15 s window, not data. `exposure-must-show-the-data-path-carried-io-not-just-the-load-ran`
- Two reviewers split on the same evidence: the one that read the counters rejected, the other approved. Do not apply an approval the evidence contradicts. `exposure-must-show-the-data-path-carried-io-not-just-the-load-ran`

## How to apply
Before proposing any verify or remove-fixed, open one control lap and one verify lap and confirm, from the instrument nearest the hazard (the specific sdev's data counters, the specific lock's grant), that the trigger happened in the control and in every counted verify lap. Make sure the control's failure checks do not include the fix's own switch, and that FAIL counts only the hazard's own events (data writes, not checker or PR commands). `exposure-must-show-the-data-path-carried-io-not-just-the-load-ran`
