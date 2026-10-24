---
name: compiled-race-lap-design-per-worker-directories
description: Assorted tail (one note): designing node-local race laps - one shared directory serializes inode-lock acquires; use a dir per worker, count overlaps,…
metadata:
  type: feedback
tags: [compiled, trap, lap-design, race, i_rwsem, harness]
---

Assorted tail group (single note, no sibling topic): how to design a lap that must overlap per-node inode-DLM acquires. Source: `trap-one-shared-directory-serializes-a-nodes-inode-lock-race-workload`.

## What bit
- A lap meant to make the cached-AG yield scan (run before every slow-path inode DLM acquire) overlap on one node ran 8 create/unlink workers per node in ONE shared directory: 0 overlaps in 4280 pairs.
- Cause: VFS takes the parent directory's i_rwsem exclusive for create and unlink, so a node's workers queue on it and only one inode-lock acquire per node is ever in flight.
- Context: defect D-YIELD-SCAN-SAVE-RESTORE-OF-AG-BAST-STALL-ITERS-RACES-AND-STICKS-AT-200; prechecks in tests/evidence/lanes/g2_pre_attempt15*_20261024*. `trap-one-shared-directory-serializes-a-nodes-inode-lock-race-workload`

## Second trap
- With a directory per worker index (worker w of both nodes in dir w), scans overlapped once per node in ~2300, and no scan drained inline: an MXFS hot-path scan with nothing to do lasts microseconds, so a save-restore race window stays closed under a natural workload.
- A test-only hold inside the scan (dbg_yield_scan_hold_us, written at runtime on both arms) gave ~720 overlaps per node, and the old code stuck on both nodes. `trap-one-shared-directory-serializes-a-nodes-inode-lock-race-workload`

## How to apply
- For node-local concurrency in a lap, give each worker its own directory; share the directory across nodes, not across a node's workers.
- Count what the lap means to trigger (a counter of calls and of overlaps) before reading a zero result as "fixed".
- A hold that widens a window goes on both arms alike, at runtime (not in the prep's module arguments, which make the lap a variant tools/batch_lap.py refuses to count toward a verification), and is declared in the lap header and the proposal. `trap-one-shared-directory-serializes-a-nodes-inode-lock-race-workload`
