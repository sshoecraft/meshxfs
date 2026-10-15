---
name: compiled-inode-reuse-repros-probe-visibility-and-in-place-fork-rebuilds
description: Cross-host inode-reuse repros need the reusing host to have allocated; repros must grade reach; mxfs_probe is pr_debug; MXFS fork rebuilds must reset…
metadata:
  type: feedback
tags: [compiled, inode-reuse, repro, mxfs_probe, xfs_ifork]
---

Assorted group (one note) on repro design and instrument visibility for inode reuse; source: `trap-inode-reuse-repro-needs-the-reusing-host-to-have-allocated-the-numbers`.

**Inode-number reuse across hosts.** On MXFS each host allocates new inodes from its own AG, not near the parent directory. A repro where host A creates and deletes files and host B then creates new ones reuses nothing: B's numbers came from ~16.9M (its AG) while A's frees were in AG 0 (tests/pve_recycled_btree_inode.sh lap a1, reused=0, measured nothing). For B to get a number back, B must have created the original files. Make A touch them (utime + read) so B's cached copy goes stale and B reloads it from disk, then have A delete them. In the fixed harness, B reused 40 of 40 numbers per lap.

**Make a repro grade its own reach.** Have the harness count reused numbers (`comm -12` of old vs new `ls -i`) and FAIL when the count is 0. Otherwise a clean run is vacuous.

**mxfs_probe / mxfs_probe_ratelimited are pr_debug** (pal/mxfs_probe.h:58), so they are silent unless dynamic debug is on. A new instrument meant to print on the rig must be pr_warn. Earlier probe families (P9-NLEDGE reset4create, P-RECYCLE-GATE) are absent from a normal journal, and their absence proves nothing.

**MXFS rebuilds live forks in place.** These include mxfs_dlm_reset_inode_for_create, the peer-freed shell reset in xfs_icache.c, and the reload adopt. Upstream never reuses a destroyed fork, so upstream code cannot be relied on to reset every fork field. if_needextents survived into a new file this way and oopsed qemu-img in xfs_bmbt_init_cursor (fixed in xfs_idestroy_fork, 0.90.129). When adding a field to xfs_ifork, check that every MXFS rebuild path resets it.
