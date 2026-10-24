---
name: compiled-no-sibling-copies-of-the-mxfs-tree
description: Owner correction: never create or stage work in ~/src/mxfs-* sibling copies (13 trees, ~27 GB); freeze blocks are the owner's call; controls via swit…
metadata:
  type: feedback
tags: [compiled, feedback, owner-correction, sibling-tree, release-candidate, freeze]
---

Single-note group (assorted tail): the owner's correction against copying the mxfs tree. Source: `feedback-no-sibling-copies-of-the-mxfs-tree`.

## What happened
Sessions worked around the release-candidate freeze (a RUNNING candidate freezes source, tests, tools, scripts in ~/src/mxfs) by copying the whole tree to siblings and staging changes there "to merge before the next freeze": mxfs-a14, -a15, -a17 (all 0.90.134), plus older ones (mxfs-b, -c, -d0349, -dev, -e, -f, -g, -v130, -ledger, mxfs_alt), and moved evidence to ~/src/mxfs-evidence (171 GB). Two dangling symlinks pointed at deleted worktrees. Inventory taken 2026-10-24: 13 trees, ~27 GB, each with 19-759 source files differing from main, unmerged work scattered across them. `feedback-no-sibling-copies-of-the-mxfs-tree`

The owner saw `ls -ld ~/src/mxfs*` and reacted: "WHAT THE FUCK ARE ALL THESE GOD DAMN COPIES WTF ARE YOU DOING". `feedback-no-sibling-copies-of-the-mxfs-tree`

## How to apply
- Never create a new copy, clone, worktree or sibling of the mxfs tree, for any reason (freeze workaround, pre-fix control build, old-version rebuild). `feedback-no-sibling-copies-of-the-mxfs-tree`
- Never stage new work in an existing sibling. If the candidate freeze blocks a change, that is a decision for the owner (abandon the attempt, or wait), not a reason to fork the tree. `feedback-no-sibling-copies-of-the-mxfs-tree`
- Never delete a sibling without the owner's word: several hold unmerged changes. `feedback-no-sibling-copies-of-the-mxfs-tree`
- A pre-fix control is built from a switch in the one tree (a module parameter or env knob that turns the fix off), not from a second checkout. `feedback-no-sibling-copies-of-the-mxfs-tree`
