---
name: compiled-unlink-live-delay-knob-holds-parent-lock
description: dbg_unlink_live_delay_ms msleeps in every local regular-file unlink under the parent's i_rwsem; rm cleanups and name polls pay the delay
metadata:
  type: feedback
tags: [compiled, trap, unlink, test-knob, harness, i_rwsem, dbg_unlink_live_delay_ms]
---

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
