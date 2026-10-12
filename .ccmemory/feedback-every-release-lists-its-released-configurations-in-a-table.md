---
name: feedback-every-release-lists-its-released-configurations-in-a-table
description: USER directive: every release lists the supported/released configurations in a TABLE, with any pertinent info before or after the table, not a prose…
metadata:
  type: feedback
---

USER 2026-10-10, quoting the README's prose "What 0.90.116 was validated on" list (six shared-LUN configurations in one run-on bullet, 2/net/mesh/drbd in another): "add a memory: anytime you do a release you list the supported/released configurations in a table and provide any pertinent info before or after the table".

**How to apply, on every release (README release section AND the GitHub release notes, i.e. the released version's CHANGELOG section):**
- One table row per released configuration (e.g. `2/net/mesh/direct` ... `16/disk/caw/direct`, `2/net/mesh/drbd`), with columns for what a user needs: nodes, how the nodes reach the storage, and what it was validated on (rig suite, platforms with installed packages, physical hosts / failover suite).
- Put pertinent context (test rig details, platform list shared by all rows, configurations explicitly NOT claimed, the same-version-on-every-host rule) in short text immediately before or after the table, not inside run-on bullets.
- No "and nothing else" after it: the table's scope is implied (see feedback-release-headline-sells-the-whole-release-to-its-users-not-the-last-internal-fix).
