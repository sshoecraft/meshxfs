---
name: trap-draft-run-sh-in-drafts-tree-becomes-lap-tree-root
description: Laps find the tree root by walking up to run.sh; a draft run.sh in tests/evidence/drafts/tree hijacks draft laps there — also require tools/mxfs_lab.…
metadata:
  type: feedback
---

Draft laps under tests/evidence/drafts/tree/tests/ locate the repo by walking up until a run.sh exists. Copying run.sh into drafts/tree (to draft a run.sh fix) made that the root, and three merge-overrun laps aborted in 8 s (no tools/mxfs_lab.sh there), writing evidence under drafts/tree/tests/evidence/ (2026-10-24, session 8815bf68).

How to apply: root walks use `while { [ ! -f run.sh ] || [ ! -f tools/mxfs_lab.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done`. Before copying run.sh into drafts/tree, check no draft lap there is running or queued.

Related lane trap: scripts/lane_after.sh picks `ls -dt lanes/<name>_*`, which also matches `<name>_wait.log`; a wait log newer than the lane dir keeps it waiting.
