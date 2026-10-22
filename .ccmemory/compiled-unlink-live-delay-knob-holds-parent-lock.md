---
name: compiled-unlink-live-delay-knob-holds-parent-lock
description: Harness traps: dbg_unlink_live_delay_ms holds parent i_rwsem across every local unlink; LUN image kept after chk_clean is post-remount, not audited.
metadata:
  type: feedback
tags: [compiled, trap, unlink, test-knob, harness, i_rwsem, dbg_unlink_live_delay_ms, chk_clean, snapshot, evidence-integrity, lun_pool]
---

Assorted group (two notes, no shared topic; both were single-note tail groups): Part A is the `dbg_unlink_live_delay_ms` test knob, which delays every local unlink and blocks the parent directory while it does; Part B, absorbed from `compiled-kept-lun-image-post-remount-not-audited-state`, is that a LUN image kept after the `chk_clean` cold audit is the post-remount state, not the state the audit graded. Common thread: a harness reads or times a state different from the one it believes it is observing (a knob's side effect on the parent lock; a snapshot taken after remounts).

# Part A: `dbg_unlink_live_delay_ms` holds the parent directory lock

Tail group (`kind: assorted`): one note, no topic neighbours, so it is organised around the single trap it holds -- the `dbg_unlink_live_delay_ms` test knob delays every local unlink and blocks the parent directory while it does.

## Mechanism

- Knob: `dbg_unlink_live_delay_ms`, in `pal/linux/xfs_iops.c` `xfs_vn_unlink`. `trap-unlink-live-delay-holds-every-local-unlink-and-the-parent-lookup`
- It `msleep`s after `xfs_remove` for ANY regular file whose nlink reached 0 with `MXFS_IF_LOCAL_UNLINK` set -- not only the file the harness means to hold.
- The sleep runs inside `vfs_unlink`, so the parent directory's `i_rwsem` is held exclusively for the whole delay. Every other operation that needs that parent (a further unlink, a lookup) waits behind it.

## What it cost

Session 93, `tests/peer_changed_life_ab.sh`, defect `D-LOCAL-UNLINK-INACT-AFTER-GRANT-LOSS-WRITES-STALE-CORE-OVER-PEER-CHANGE`. `trap-unlink-live-delay-holds-every-local-unlink-and-the-parent-lookup`

- A per-iteration `rm -f go h r c` of four signal files paid 4 x 3 s = 12 s an iteration. Lap `pclc2` overran its workload bound; this was the "unexplained ~13 s".
- A shell poll `[ -e $D/f ]` meant to start the next step "once f's name is gone" does not return early: the lookup waits on the same parent lock and answers only after the delay (`pclc2`: `gone_rounds=1` inside a 6.1 s `rm`). The dependent step ran 3 s late and the shape was missed.

## Do instead

`trap-unlink-live-delay-holds-every-local-unlink-and-the-parent-lookup`

- Leave signal/cleanup files in place while the knob is set; remove them after the knob is reset to 0.
- Put a second file whose unlink must not wait in a different directory.
- To know the unlink has committed and the delay began, read the rm's kernel stack: `grep -q msleep /proc/$pid/stack` (pid from `rm f & pid=$!`), not a name lookup in the same directory.

# Part B: a LUN image kept after `chk_clean` is post-remount, not the audited state

Absorbed from `compiled-kept-lun-image-post-remount-not-audited-state` (an assorted-tail group: the clusterer found no sibling topic for the note, so that article was the one note). Central topic: a LUN image kept after the `chk_clean` cold audit is the post-remount state, not the state the audit graded. Source: `trap-kept-lun-image-after-chk-clean-is-post-remount-not-the-audited-state`.

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
