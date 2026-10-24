---
name: remove-fixed-needs-reproducer-and-approved-verify-first
description: defects.py remove --fixed refuses without a --reproducer on the record and a batch recorded by `verify`, which needs its OWN approved verify proposal
metadata:
  type: feedback
---

`tools/defects.py remove <id> --fixed --control C --fixon F --approval P` refused even after the release-reviewer approved the remove-fixed proposal (P20261024-f84fc6, 2026-10-24), for two reasons:

- `no reproducer: name the test that reaches the cause (update --reproducer)`
- `<fixon> is not a verification batch that passed (defects.py verify)`

`defects.py verify <id> --batch F --approval P` then refused: `proposal P... is for remove-fixed, not verify`. The removal applies only after a verify proposal (`propose verify --record --batch --at --argument --evidence`) has been reviewed in its own right.

How to apply: before dispatching the reviewer for a removal, (1) run `update <id> --reproducer "..."`, then (2) file both `propose verify` for the fix-on batch and `propose remove-fixed`, and send both proposal ids to ONE release-reviewer call. That saves a review round trip.
