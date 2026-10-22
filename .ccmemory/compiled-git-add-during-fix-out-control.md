---
name: compiled-git-add-during-fix-out-control
description: harness_batch.py control and control_precheck.sh revert a fix in the shared tree; git add -A while one runs commits the source without the fix.
metadata:
  type: feedback
tags: [compiled, git, commit, control-batch, harness_batch, control_precheck, revert, lane]
---

Assorted-tail group of one note, no sibling topic. It is a single trap: `git add -A` while a fix-out control has a fix reverted in the shared working tree commits and pushes the source without the fix. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`

## Mechanism: the fix is out of the shared tree for the length of a control

- `tools/harness_batch.py control --revert <fix.diff>` and `tools/control_precheck.sh` take a fix out by applying its diff in reverse in the working tree (`patch -p1 -R`), run laps, then put it back. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`
- A detached lane (`scripts/rig_lane.sh`) can be in that window for many minutes. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`

## What happened (0.90.134, 2026-10-22)

- A lane was running the D-CHK-FREESPACE-REBUILD fix-out control, so `tools/chk_mxfs.c` had the free-space rebuild fix removed.
- The session ran its pre-push memory-compaction commit with `git add -A` (the commit-everything rule) and pushed. Commit 2ae126a published `tools/chk_mxfs.c` WITHOUT the integrity fix.
- `git status --porcelain` printed ` M tools/chk_mxfs.c` in the same command and was not read before the add. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`

## Apply

- Before any commit, read `git status --porcelain`. A modified file named in a `+++ b/` line of a `tests/evidence/controls/*.fix.diff`, while a lane's `summary.log` shows a control or control_precheck step started and not ended, means a fix is out. Wait for that step's `restored:` / `the fix is back in` line, then commit.
- If it already happened: commit the restored file as soon as the control restores it, with a message that says the previous commit carried the reverted file, and push.
- Schedule commits and pushes between control steps, or before launching a lane that reverts. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`
