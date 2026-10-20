---
name: compiled-mxfs-publish-drain-and-dead-dentry-traps
description: Two MXFS traps (assorted): demoting non-routed child after failed claim wedges on pub_claim_write_guard; xfs_mxfs_dentry.c is dead code.
metadata:
  type: feedback
tags: [compiled, mxfs, publish-drain, d_revalidate, trap]
---

Assorted group: two unrelated MXFS code-location traps. Common thread: reusing or editing the wrong code path (a primitive from the wrong arm; a file that is not built).

## Publish drain: never demote a non-routed child after a failed claim

Source: `trap-publish-drain-demote-without-grant-wedges-on-claim-write-guard`

- In `xfs/xfs_mxfs_publish.c` the routed arm (CAW inode-cluster) demotes each popped child in the drain worker (`bast_process`: writeback, durable dinode, local NL). That is legal there only because a routed inode's grant is on the cluster resource.
- A NON-routed child (every TCP inode, CAW directories) may not have its live core written home without its own grant: `pal/linux/xfs_buf.c` `pub_claim_write_guard` masks the slot (`P-PUB-CLAIM-WRITE-MASKED`) while the child is on `m_mxfs_pubclaim_list`, because a peer may still hold the number's previous life.
- How it bit (0.90.131, D-SURVIVOR-DEFERRED-PUBLISH-EX-CLAIM-FAILS...): a fallback that demoted a non-routed child after its claim failed looped forever on the masked flush: 2000 `P-PUB-CLAIM-WRITE-MASKED` lines from `mxfsaild` in under a second, the drain worker and the peer's `ls` stuck, 10 D-state tasks on the creator (`tests/evidence/pcf1.console`, sibling build A84ED974BF5C12C8C151F20).
- Ending the pubclaim tracking first would unmask the write but put a core home with no grant, which is what the guard forbids.
- Rule: after a failed non-routed claim the only legal moves are to keep the claim in flight and ask again (`pub_claim_retry`) or to keep the child unpublished; never write it home. Before reusing a primitive from the routed arm on the non-routed arm, check the `i_dlm_routed_iclus` gates in `xfs_buf.c`.

## `xfs/xfs_mxfs_dentry.c` is not compiled; live d_revalidate is in pal/linux/xfs_super.c

Source: `trap-xfs-mxfs-dentry-c-is-dead-code-live-drevalidate-in-pal-xfs-super`

- `xfs/xfs_mxfs_dentry.c` defines a `mxfs_drevalidate` and `mxfs_dentry_operations`, but no Kbuild/Makefile line builds it.
- The dentry operations the module installs (`set_default_d_op` / `sb->s_d_op`) are the static `mxfs_dentry_operations` in `pal/linux/xfs_super.c` (~line 4700); its `mxfs_drevalidate` (~4150-4690) is the live one.
- The live function already drops a dentry whose inode carries `i_dlm_stale`, `XFS_ISTALE_CAW` or `MXFS_IF_INCARN_STALE` ahead of every fast path, then has the epoch and affine fast paths and the GENMISS / RESURRECT / TYPEMISS platter checks (all gated on the child's cached grant being NL).
- How it bit: a fix written into the dentry.c copy built into a module whose srcversion was identical to the build without it, and `tools/sibling_sync.sh <dir> <marker>` reported `marker=MISSING`. The hypothesis it was meant to test (d_revalidate approving a poisoned dentry) was also false, because the live function already handles that case.
- Before changing VFS-facing behaviour, confirm the file is in the build (`grep -rn <file-stem> Kbuild Makefile*`) and pass a marker string to `sibling_sync.sh` so a missing change shows up as `marker=MISSING`.
