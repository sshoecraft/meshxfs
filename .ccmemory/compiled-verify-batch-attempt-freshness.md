---
name: compiled-verify-batch-attempt-freshness
description: A passed verification batch must be applied (propose verify, reviewed) before the next release_candidate freeze; after a re-freeze it is dead and mus…
metadata:
  type: feedback
tags: [compiled, defects, verify, release-candidate, tools]
---

Assorted single-note group (kind assorted); central topic: when a defects.py verification batch can still be applied.

- A verification batch can only be applied (`propose verify`) while the attempt its laps ran on is current; after a re-freeze it is dead. `verify-batch-must-be-applied-on-the-attempt-it-ran`
- `tools/defects.py` `unplanned_variant` (:994-996) treats any lap stamped before the candidate's current attempt began (`criteria.attempt_began`) as run on another tree. So a `verify` proposal for a batch whose laps ran on an earlier attempt of the same version is rejected. Case: review P20261024-b148a3 rejected b20261023-756620 (6 of 6 PASS on attempt 2026-10-23T20:41:09Z), proposed after seven later freezes. `verify-batch-must-be-applied-on-the-attempt-it-ran`
- Laps that ran after their attempt was marked INVALID (drift) also do not count, even before the next freeze. `verify-batch-must-be-applied-on-the-attempt-it-ran`
- An APPLIED verify (batch state `passed`) is not re-checked against the attempt at `remove --fixed` (cmd_remove only checks kind/state and the control link), so applied verifies survive later freezes. `verify-batch-must-be-applied-on-the-attempt-it-ran`
- How to apply: before `tools/release_candidate.py create` freezes a new attempt, propose and get reviewed a `verify` for every verification batch that passed on the current attempt. Never leave a passed batch unapplied across a freeze, or it must be rerun (and its control re-shown on the new build via a fresh control or a checkable `--transfer`). `verify-batch-must-be-applied-on-the-attempt-it-ran`
