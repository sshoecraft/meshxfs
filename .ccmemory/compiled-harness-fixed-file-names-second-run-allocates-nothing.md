---
name: compiled-harness-fixed-file-names-second-run-allocates-nothing
description: Assorted group (1 note): fixed-name test files truncate instead of allocate on a repeat run without mkfs; use a per-run dir and top up the reserve.
metadata:
  type: feedback
tags: [compiled, test-harness, alloc_witness, mkfs]
---

Assorted group (single note, no wider topic): a harness trap about repeating allocation-measuring rows on one filesystem. Source: `trap-a-harness-with-fixed-file-names-allocates-nothing-on-its-second-run-on-one-mkfs`.

- Failure mode: a test that "creates" files with fixed names (`: > $D/x$i`, `r<rank>_<i>`, `u<i>`) and runs twice on the same filesystem without an intervening mkfs allocates nothing the second time. `: >` opens and truncates the predecessor's file. Anything measuring allocation (carves, finobt transitions, inode reuse, occupant manifests built by globbing the directory) reads vacuous or wrong.
- Evidence (16/disk/caw/mpath, 0.90.124): alloc_witness+chk_clean three times after one prep. Run 1 passed. Runs 2 and 3: 12 of 16 nodes had zero phase-1 carves (each re-touched exactly the 192 files from run 1); own_ag and overlap INSUFFICIENT; chk_clean release=VACUOUS. Release gates never exposed it because every repeat there followed a fresh mkfs.
- Fix: put the row's working tree under a per-run directory (`$MNT/alloc_witness/$RUN_ID`). When repeating a row by hand to test a fix, decide up front whether repeats share a mkfs; the two choices answer different questions.
- Related: a "fill until the reserve is exhausted" loop that stops at the end of the batch in which the carve appeared leaves 0-63 free inodes. At 16 nodes (~7 creates/s per node in a shared dir) that delays a node's first phase-1 carve by up to ~9 s. Top up until the live chunk query (alloc_witness_chunk) shows freecount=0.
