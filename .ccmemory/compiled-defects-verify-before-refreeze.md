---
name: compiled-defects-verify-before-refreeze
description: defects.py verify: apply a passed verify before re-freezing the candidate attempt, else its laps stop counting; removals survive a re-freeze
metadata:
  type: feedback
tags: [compiled, defects-py, verify, release-candidate, attempt, trap]
---

Assorted-tail group (the clusterer found no peers): one trap about the order of `tools/defects.py verify` against re-freezing a release candidate's attempt. `trap-apply-a-verify-before-refreezing-or-its-laps-stop-counting`

## Rule: apply a passed verify while its attempt is current

- A passed verification batch must be applied (`tools/defects.py verify <id> --batch <b> --approval <P>`) while the attempt its laps ran on is still the candidate's current attempt. `trap-apply-a-verify-before-refreezing-or-its-laps-stop-counting`

## Why a re-freeze voids it

- `unplanned_variant()` in tools/defects.py (the lines under "a candidate is its version: a lap from before its current attempt was frozen ran another tree") drops every lap whose `iso` is earlier than `criteria.attempt_began(candidate)`. `trap-apply-a-verify-before-refreezing-or-its-laps-stop-counting`
- A new `release_candidate.py create` moves `attempt_began` forward. A verify batch that passed on the old attempt then has zero countable laps and can never be applied; its rig time is lost. `trap-apply-a-verify-before-refreezing-or-its-laps-stop-counting`
- `verified_at` also carries the attempt, so an applied verify stops clearing anything once the attempt changes. `trap-apply-a-verify-before-refreezing-or-its-laps-stop-counting`

## What survives a re-freeze: a removal

- `cmd_remove` checks only that the control is closed with k>=1 and the fix-on batch is `passed` and sized from that control. It does not check the attempt. `trap-apply-a-verify-before-refreezing-or-its-laps-stop-counting`
- Order before retiring an attempt: (1) apply every passed verify that a removal needs, (2) abandon/re-freeze, (3) propose the removals. Learned in the session of 2026-10-23, the 4K merged-write record. `trap-apply-a-verify-before-refreezing-or-its-laps-stop-counting`

## Source and tool changes

- A source or tool change needs the attempt retired first (every frozen file is checked for drift). Batch the next attempt's changes and convert verifies to removals promptly; a verify left unremoved is redone on the next attempt. `trap-apply-a-verify-before-refreezing-or-its-laps-stop-counting`
