---
name: compiled-release-status-reporting-afk-conduct-and-bmbt-reclaim-test-traps
description: Assorted: "status"/release matrix = one table via tools/release_status.py, one row per unit; user AFK = never block; drop_caches/reclaim traps.
metadata:
  type: feedback
tags: [compiled, release, reporting, feedback, afk, xfs-reclaim]
---

Assorted group (clusterer could not fit a single topic): two notes on how to report release status, one on AFK conduct, one test-harness trap about inode reclaim.

## Release status / release matrix reporting (User, 2026-10-14)

`feedback-status-means-the-release-table-including-the-physical-drbd-pair`
- User: "When I ask for status from now on, I mean show me the release table as defined previously. Include in the release table the drbd dual primary physical nodes." Then asked for check marks on ready rows, approved the format ("Perfect."), and asked for a script (`watch -n 10 tools/release_status.py`).
- When a row lumping kernels 6.17 + 7.0 hid the 6.17 pass behind the 7.0 "not yet": "Why would I want a check mark with a ready if it's going to be hidden? That doesn't make any sense at all."
- "status" = run `tools/release_status.py` (`data/release_table.json` defines the rows) and show its table; nothing around it.
- ONE ROW PER INDEPENDENTLY VERIFIED UNIT: each configuration's board (2, 4, 8, 16 nodes separately), each kernel's run, each platform. Never a range row like "2-16" or "kernels 6.17 and 7.0" that can only go green when everything inside it does: a unit that passed must show ready immediately.
- Status cell: "✅ Ready", "⏳ In progress", or "❌ Not ready: <short reason>". No build/kernel/evidence qualifiers in the cell.
- Always include the physical pve1/pve2 DRBD row, separate from the test1/test2 rig DRBD row, and a row per released platform (`data/platforms.json`).

`feedback-release-matrix-is-one-table-of-every-configuration-with-its-status` (tags: release, reporting, proxmox)
- After being shown the board as three tables (release matrix, own-rig, withdrawn) each with notes, user: "the next time I asked you for the release matrix, I want you to show me a single table - the complete matrix, no 800 diff tables each with their own explanations - I don't care about them. One table that has everything we're going to release and what the status is of each."
- One table, one row per configuration intended for release (rig matrix, DRBD pair, Proxmox suite, anything else); columns only what it is and its status. No sub-tables, no per-section prose, no excluded-record footnotes.
- Why: once all green it becomes the Proxmox-forum call-for-testers post: "here's all the configurations it supports - period." Same one-table shape goes in the public text.
- Detail (builds, defect ids, dates) only when the user asks.

## User AFK: never block on a question

`feedback-user-afk-never-block-on-a-question-proceed-on-stated-approvals`
- User, 2026-10-14: "why are you waiting on me for anything ive been afk ... dont wait for me ... im afk dont wait for me or ask any questions".
- Context: user had already said "i am ok with fencing/taking down a node for the final validation run", yet the session asked for confirmation before the pve2 hard reset and parked the step on the answer.
- Do not hold work on a confirmation question; if an earlier message approved the action, act on it.
- If something genuinely needs the user, state it in the report and carry on with every other independent piece of work; never end a turn whose only content is waiting for an answer.
- Physical pve1/pve2 hard resets: approved for the final release-validation run (p1-crash of pve2, participant 1). Still never reset pve1 (participant 0) under the default tie-break, which cannot recover from losing it.

## Trap: inode reclaim vs drop_caches in bmbt join-window test

`trap-drop-caches-cannot-reclaim-an-inode-without-its-buffers-and-xfs-reclaim-walk-cursor`
Four traps that made `tests/bmbt_join_window_repro.sh` read VACUOUS/CLEAN for months (D-BMBT-TENURE-END, closed 0.90.129):
- A node-side script launched from `$PWD` on clyde is `/home/steve/src/mxfs/...`; nodes mount the tree only at `/src/mxfs`. The loop never ran and every arm graded on silence. Launch node-side scripts from `/src/mxfs/$OUT/...`.
- `echo 2|3 > drop_caches` cannot produce "inode reclaimed, its cached metadata buffers still there". drop_slab runs the xfs buftarg shrinker in the same pass and loops until little is freed, so the bmbt buffers die first/with the inode (measured: buffers gone, inode and its DLM grant kept). To end one inode's tenure without the buffer shrinker use an in-kernel injector: xfs_iget(INCORE) -> d_mark_dontcache -> d_prune_aliases -> xfs_irele -> xfs_reclaim_inodes_nr (see `dbg_join_window_reclaim_ino` in `xfs/xfs_mxfs_join.c`).
- `xfs_iget(..., XFS_IGET_INCORE)` failing does not mean the inode left the cache: it also refuses a cached IRECLAIMABLE / inactivating inode, which still holds its grant. Read pag_ici_root directly (radix_tree_lookup under RCU) and report i_flags.
- One `xfs_reclaim_inodes_nr` call can miss an inode: the RECLAIM walk starts at pag_ici_reclaim_cursor and stops at the AG end (resetting the cursor to 0). Call it twice.
- General: a mode-2 "positive control" that loops drop+read every round also races the census; a single-shot control (once, then idle) is what proved the census could see blocks at all.
