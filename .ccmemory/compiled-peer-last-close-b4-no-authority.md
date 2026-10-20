---
name: compiled-peer-last-close-b4-no-authority
description: A peer's last close of an inode another node unlinked skips the free (B4 no-authority); repros needing the peer to free it are vacuous
metadata:
  type: feedback
tags: [compiled, mxfs, inactivation, unlinked-list, repro-design, vacuous-lap, B4]
---

Assorted group: a single note the clusterer could not fit to a sibling topic. Its subject is the MXFS authority check that decides which node frees an unlinked inode at inactivation (B4 no-authority), and the repro-design failure that follows from it. Source: `trap-peer-last-close-never-frees-an-inode-it-did-not-unlink-b4-skip`.

## Trap: a peer's last close does not free an inode another node unlinked

A node frees an unlinked inode only if it unlinked it itself (`MXFS_IF_LOCAL_UNLINK` / adopted unlink) or holds it EX in `i_dlm_mode`. The inactivation's own raw EX (`P-INACT-EX gmode=5`) does NOT set `i_dlm_mode`, and the last close publishes its open-clear by riding a demote first. `trap-peer-last-close-never-frees-an-inode-it-did-not-unlink-b4-skip`

So when node B holds a file open that node A unlinked, B's last close logs `P19-B3DEC ... b4_noauth=1` and `INACT-SKIP-STALE reason=no-authority-unlocked-not-unlinked`, and the free is left to A (its reaper, or A's next drop of a pinned reference). `trap-peer-last-close-never-frees-an-inode-it-did-not-unlink-b4-skip`

## What it broke

Session 86: the directed H-IU1 queue (`tests/peer_open_unlinked_chain.sh`, owner rm z then y, peer holds y and closes it inside z's widened predecessor wait) ran six laps, all PASS, all `held_moved=0`. The peer never freed y, so the race the queue was built to force never happened; the queue measured nothing for its hypothesis. `trap-peer-last-close-never-frees-an-inode-it-did-not-unlink-b4-skip`

## How a peer does get authority

Through EX taken by an operation, then the last reference dropping while that EX is still cached. `trap-peer-last-close-never-frees-an-inode-it-did-not-unlink-b4-skip`

- fn32's test1 took the peer's zombie's EX through `touch` (`P6H-ADOPT comm=touch`, then `P9-NLEDGE from_disk old=1 new=0`) and its next iput ran the inactivation with EX held.
- The noino_gen0 workload's lookup/stat loops produce this naturally (lap ifd2: `P-UNLPREV-MOVED ... comm=stat`).

## How to apply

Before building a repro where one node must free an inode another node unlinked, check that the freeing node will hold `i_dlm_mode == EX` at the inactivation, not just an open file it closes. Grade reach in the harness with a counter that must be > 0, so a structurally vacuous lap reads VACUOUS instead of PASS. `trap-peer-last-close-never-frees-an-inode-it-did-not-unlink-b4-skip`
