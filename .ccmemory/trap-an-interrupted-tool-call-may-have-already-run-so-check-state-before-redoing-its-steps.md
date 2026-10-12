---
name: trap-an-interrupted-tool-call-may-have-already-run-so-check-state-before-redoing-its-steps
description: TRAP: a Bash call the user interrupted/rejected had already restored files; the retry then "backed up" the restored tree, so the backups held nothing…
metadata:
  type: feedback
---

A Bash call that the harness reports as "rejected / interrupted by user" may have ALREADY EXECUTED part or all of its commands. The rejection can land after the command started.

What happened (0.90.116 release, 2026-10-10): one command did `mkdir next-0.90.117; cp newer files -> next-0.90.117; cp verified copies -> tree`. The user interrupted it ("don't overwrite anything since 5am"). The retry then ran `cp tree -> tree/*.backup; cp verified -> tree`. The tree had already been restored by the "rejected" call, so the `.backup` files were copies of the VERIFIED code, and the handoff told the user the newer work was in `.backup`. The newer work survived only in the scratch dir (/tmp, gone on reboot), found by its directory mtime.

**How to apply:**
- After any interrupted or rejected call that mutates files, check what it left (mtimes, `cmp`, the directories it would have created) BEFORE re-issuing its steps.
- A backup step must check that the backup DIFFERS from the thing it protects against (e.g. `cmp` the backup against the version about to overwrite it), not only that the copy equals its source. A backup identical to the restored version saves nothing.
- Before reporting "saved as X", diff X against what it is supposed to be distinct from.
