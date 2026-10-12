---
name: compiled-interrupted-tool-call-state-check-and-backup-verification
description: Assorted group (1 note): a rejected/interrupted Bash call may have already run; verify state and that backups differ before redoing or reporting.
metadata:
  type: feedback
tags: [compiled, bash, interrupted-call, backup, trap]
---

Assorted tail group (one note the clusterer could not fit to a larger topic); the common thread is mutating shell calls that are interrupted and then retried.

A Bash call the harness reports as "rejected / interrupted by user" may already have executed some or all of its commands, because the rejection can land after the command started. This was found in the 0.90.116 release. One command did `mkdir next-0.90.117; cp newer files -> next-0.90.117; cp verified copies -> tree`, and the user interrupted it. The retry then ran `cp tree -> tree/*.backup; cp verified -> tree`. The tree had already been restored by the "rejected" call, so the `.backup` files held the VERIFIED code. The handoff still told the user the newer work was in `.backup`. The newer work survived only in a scratch directory under /tmp, and was found by its directory mtime. Source: [[trap-an-interrupted-tool-call-may-have-already-run-so-check-state-before-redoing-its-steps]].

Rules that follow:
- After any interrupted or rejected call that mutates files, check what it left before re-issuing its steps. Look at mtimes, run `cmp`, and look for the directories it would have created.
- A backup step must check that the backup DIFFERS from the version about to overwrite it. Checking only that the copy equals its source is not enough, since a backup identical to the restored version saves nothing.
- Before reporting "saved as X", diff X against what it is supposed to be distinct from.
