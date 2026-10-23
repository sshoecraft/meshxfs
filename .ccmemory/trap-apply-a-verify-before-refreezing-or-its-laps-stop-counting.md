---
name: trap-apply-a-verify-before-refreezing-or-its-laps-stop-counting
description: defects.py verify counts only laps after the candidate's current attempt was frozen; re-freezing before applying a passed verify voids it
metadata:
  type: feedback
---

A passed verification batch must be applied (`tools/defects.py verify <id> --batch <b> --approval <P>`) while the attempt its laps ran on is still the candidate's current attempt.

Why: `unplanned_variant()` in tools/defects.py (the lines under "a candidate is its version: a lap from before its current attempt was frozen ran another tree") drops every lap whose `iso` is earlier than `criteria.attempt_began(candidate)`. A new `release_candidate.py create` moves attempt_began forward, so a verify batch that passed on the old attempt then has zero countable laps and can never be applied; its rig time is lost. `verified_at` also carries the attempt, so an applied verify stops clearing anything once the attempt changes.

What survives a re-freeze: a removal. `cmd_remove` checks only that the control is closed with k>=1 and the fix-on batch is `passed` and sized from that control; it does not check the attempt. So the order before retiring an attempt is: apply every passed verify that a removal needs, then abandon/re-freeze, then propose the removals (session of 2026-10-23, the 4K merged-write record).

Also: a source or tool change needs the attempt retired first (every frozen file is checked for drift), so batch the next attempt's changes and convert verifies to removals promptly; a verify left unremoved is redone on the next attempt.
