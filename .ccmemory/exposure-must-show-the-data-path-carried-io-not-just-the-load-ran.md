---
name: exposure-must-show-the-data-path-carried-io-not-just-the-load-ran
description: A lap's EXPOSED that only proves the load ran (by any path) is not exposure: read the specific path/sdev's own data counters in both arms first
metadata:
  type: feedback
---

tests/late_register_hold_lap.sh (D-LATE-PATH-REGISTER-TIMED-OUT-MAY-EXECUTE-AFTER-A-FENCE-AND-RESTORE-THE-KEY, 2026-10-24) passed a 10/10 control and a 6/6 verification at two configurations, and the removal and one verify were still rejected (data/reviews/P20261024-e7d188.md, P20261024-229ee1.md):

- EXPOSED printed when the victim's load completed operations through the multipath map by ANY path. The late path's own counters (sdb reads/writes in state_<node>_*.txt) did not move in either arm. With the other path up, dm-multipath sent nothing down the returning path, so the trigger (a write behind an unresolved REGISTER) was never reached.
- The control's FAIL was the fix's own flag (held=0) plus requests_sent=7-8. That count is multipathd's 2 s checker TURs over a 15 s window, not data.
- Two reviewers split on the same evidence: the one that read the counters rejected, the other approved. Do not apply an approval the evidence contradicts.

How to apply: before proposing any verify or remove-fixed, open one control lap and one verify lap and confirm, from the instrument nearest the hazard (the specific sdev's data counters, the specific lock's grant), that the trigger happened in the control and in every counted verify lap. Make sure the control's failure checks do not include the fix's own switch, and that FAIL counts only the hazard's own events (data writes, not checker or PR commands).
