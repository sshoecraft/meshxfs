---
name: trap-a-harness-with-fixed-file-names-allocates-nothing-on-its-second-run-on-one-mkfs
description: TRAP: `: > dir/x$i` on a fs a prior run left behind truncates, allocates nothing; alloc_witness repeats read INSUFFICIENT. Use a per-run-id dir.
metadata:
  type: feedback
---

A test that "creates" files with fixed names (`: > $D/x$i`, `r<rank>_<i>`, `u<i>`) and is run twice on the same filesystem without a mkfs between does NOT allocate on the second run: `: >` opens and truncates the predecessor's file. Anything measuring allocation (carves, finobt transitions, inode reuse, occupant manifests built by globbing the directory) then reads vacuous or wrong.

Measured 16/disk/caw/mpath, 0.90.124: alloc_witness+chk_clean run three times after one prep. Run 1 passed; runs 2 and 3 had 12 of 16 nodes with zero phase-1 carves (each re-touched exactly the 192 files run 1 made), own_ag and overlap INSUFFICIENT, chk_clean release=VACUOUS. The release gates never showed it because every repeat there followed a fresh mkfs.

Fix: put the row's working tree under a per-run directory (`$MNT/alloc_witness/$RUN_ID`). Also: when repeating a row by hand to test a fix, decide whether the repeats should share a mkfs, because the results answer different questions.

Related in the same row: a "fill until the reserve is exhausted" loop that stops at the end of the batch in which the carve appeared leaves 0-63 free inodes, which at 16 nodes (~7 creates/s per node in a shared dir) delays a node's first phase-1 carve by up to ~9 s. Top it up until the live chunk query (alloc_witness_chunk) shows freecount=0.
