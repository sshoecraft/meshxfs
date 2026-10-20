---
name: compiled-caw-held-rawmode-pr-reads-as-ex
description: CAW held_rawmode maps any slot bit (PR too) to EX; authority checks needing EX must use inode_granted_mode (relog_authorized corruption, 0.90.131)
metadata:
  type: feedback
tags: [compiled, caw, dlm, trap, relog, corruption]
---

Compiled from a single note (kind: assorted tail group; the one note is about the CAW held-rawmode trap).

## Trap: `mxfs_v5_dlm_inode_held_rawmode()` reports a PR hold as EX on CAW
Source: `trap-caw-held-rawmode-reports-pr-hold-as-ex`

- `mxfs_v5_dlm_inode_held_rawmode()` (dlm/v5_mount.c) returns `mxfs_dlm_caw_held() ? MXFS_LOCK_EX : MXFS_LOCK_NL` on CAW: any bit of this node in the slot, holders_pr included, reads as EX. On TCP it returns the real mirror mode. So `held_mode >= MXFS_LOCK_EX` is NOT an EX test on CAW.
- `mxfs_v5_dlm_inode_granted_mode()` returns the real per-node mode on both transports (CAW via `mxfs_dlm_caw_granted_mode` / `node_held_mode`).

## What it cost
- `mxfs_dlm_relog_authorized` (xfs/xfs_mxfs_relbar.c) gated the release drain's synthetic re-log (P146V) on held_rawmode, so a node releasing a PR hold of a shortform directory re-logged its stale in-core image over the EX holder's newer platter image.
- Measured on 4- and 8-node disk/caw/mpath boards (0.90.131): a removed LOCK/<node> entry came back, its inode number was freed and reused, chk_mxfs found nlink 1 named by two entries (D-CAW-MPATH-8NODE-REUSED-INODE-NAMED-BY-TWO-DIRENTS-NLINK-1-AFTER-SUITE).
- Signature: P-RELFLUSH-NOTENURE held_mode=3, P146V-UNLANDED, P58-DIRPIN-NONEX dlm_mode=0, P56-DIRWRITE mode=0 write=[...].

## How to apply
- Any new check meaning "this node may write as owner" must read the granted mode (`mxfs_v5_dlm_inode_granted_mode`).
- Grep for `held_rawmode(` callers comparing against EX before trusting them on CAW.
- Directed repro: tests/relog_pr_release_auth.sh (dbg_relog_force_ino on a PR release, fresh prep, foreign=0 laps only).
