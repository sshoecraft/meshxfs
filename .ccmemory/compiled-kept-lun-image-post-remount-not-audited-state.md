---
name: compiled-kept-lun-image-post-remount-not-audited-state
description: Kept LUN image after run.sh chk_clean is post-remount (ranks 2..N mounted, orphans reaped); chk_audit.log is the only audited state
metadata:
  type: feedback
tags: [compiled, harness, chk_clean, snapshot, evidence-integrity, lun_pool]
---

Assorted-tail group: the clusterer found no sibling topic for this note, so the article is that one note. Central topic: a LUN image kept after the `chk_clean` cold audit is the post-remount state, not the state the audit graded. Source: `trap-kept-lun-image-after-chk-clean-is-post-remount-not-the-audited-state`.

## Trap

`tests/tooling/chk_clean.sh` is the cold audit behind `./run.sh <cfg> --group <g> chk_clean`. Once rank 1's audit is done it remounts every rank except a CORRUPT rank 1 (chk_clean.sh:306-315; the rank-1-only exception is at :308, and its comment at :271-278 says the harness has no verdict channel to stop the others). `trap-kept-lun-image-after-chk-clean-is-post-remount-not-the-audited-state`

Harnesses that keep the image AFTER that call copy a LUN that N-1 nodes have just mounted:
- `tests/churn_rows_audit.sh` (:193-196)
- `tests/noino_gen0_ab.sh` (CORRUPT branch, `lun_pool.sh snapshot`)
- any other harness that snapshots after chk_clean

In that copy, mount recovery and the unlinked-list processing have already run, and those nodes are live writers while `cp` runs. `lun_pool.sh`'s own comment at its snapshot says to copy only while no node writes. `trap-kept-lun-image-after-chk-clean-is-post-remount-not-the-audited-state`

## What it cost

crl8m1 (8/net/mesh/mpath, D-NETMESH-LIVE-FILE):
- The audit listed ino 8411809 as an allocated directory on AG 2 bucket 2 (mode 040755, nlink 0) with two nlink ERRORs.
- The kept image showed the same inode FREED: mode 0, generation +1, cc 88.
- The free was a remounting rank reaping the bucket member, ~12 s before the copy.
- Reading the image as "the audited state" would have produced a false contradiction.

`trap-kept-lun-image-after-chk-clean-is-post-remount-not-the-audited-state`

## What to do

- Treat `chk_audit.log` (the audit's own `chk_mxfs -v` output, copied into the lap dir) as the only record of the audited state.
- Read a kept image only for what a remount cannot change, and say so. Example: a freed dinode keeps its old literal-area bytes. In crl8m1 the zombie's former shortform header was still at offset 0xb0, count=0 and parent=128, which proved its `..` named root.
- The exception to the trap is `tests/peer_open_unlinked_chain.sh`: it keeps its image and audits it (`image audit ... before any replay`) before it remounts.

`trap-kept-lun-image-after-chk-clean-is-post-remount-not-the-audited-state`

## Provenance

Found in session 61 (2026-10-18) by a scout read of chk_clean.sh and the crl8m1 file timestamps. `trap-kept-lun-image-after-chk-clean-is-post-remount-not-the-audited-state`
