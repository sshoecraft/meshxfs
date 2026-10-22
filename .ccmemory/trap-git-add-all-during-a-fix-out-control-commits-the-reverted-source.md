---
name: trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source
description: A control batch or control_precheck reverts the fix IN THE SHARED TREE; a git add -A while one runs commits and pushes the source with its fix taken…
metadata:
  type: feedback
tags: [git, commit, control-batch, harness_batch, control_precheck, revert, lane]
---

`tools/harness_batch.py control --revert <fix.diff>` and `tools/control_precheck.sh` take a fix out by applying its diff in reverse in the working tree (patch -p1 -R), run laps, then put it back. A detached lane (scripts/rig_lane.sh) can be in that window for many minutes.

What happened (0.90.134, 2026-10-22): a lane was running the D-CHK-FREESPACE-REBUILD fix-out control, so tools/chk_mxfs.c had the free-space rebuild fix removed. The session ran its pre-push memory-compaction commit with `git add -A` (the commit-everything rule) and pushed: commit 2ae126a published chk_mxfs.c WITHOUT the integrity fix. `git status --porcelain` printed ` M tools/chk_mxfs.c` in the same command and was not read before the add.

Apply:
- Before any commit, read `git status --porcelain`: a modified file named in a `+++ b/` line of a tests/evidence/controls/*.fix.diff while a lane's summary.log shows a control or control_precheck step started and not ended means a fix is out. Wait for that step's `restored:` / `the fix is back in` line, then commit.
- If it already happened: commit the restored file as soon as the control restores it, with a message that says the previous commit carried the reverted file, and push.
- Schedule commits and pushes between control steps, or before launching a lane that reverts.
