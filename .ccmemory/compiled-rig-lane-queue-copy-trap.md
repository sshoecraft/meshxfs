---
name: compiled-rig-lane-queue-copy-trap
description: Assorted single-note group: rig_lane.sh runs its own copy of the queue; editing tests/evidence/lanes/queue_*.txt after start changes nothing the lane…
metadata:
  type: feedback
tags: [compiled, trap, rig_lane, lanes, proposal, release-reviewer]
---

Assorted tail group (one note): a trap about `scripts/rig_lane.sh` lane queue files.

## What bit (`trap-editing-a-lane-queue-file-does-not-change-a-running-lane`)
- A session rewrote a pending verify line in `tests/evidence/lanes/queue_g8b_w12b.txt` (adding `HOLD_A_MS=4000`) while the lane was on step 1, and concluded "the verification line changed before step 2 started".
- `scripts/rig_lane.sh:55` copies the queue into the lane directory at start (`cp "$QUEUE" "$OUT/queue"`) and reads only that copy (`:101 done < "$OUT/queue"`). The verification ran with the old line, `HOLD_A_MS` at its default 8000.
- The next session wrote the verify proposal from the edited original and cited `HOLD_A_MS=4000`. The release-reviewer read the lap logs (`hold_a_ms=8000`) and rejected it (P20261024-0801cb, one review spent).

## How to apply
- A running lane's commands are in `tests/evidence/lanes/<lane>_<stamp>/queue`, never the queue file it was started from. Cite that copy, and read each lap log's own header for the parameters that ran, before writing a proposal.
- To change a step that has not run yet, stop the lane at a step boundary and start a new lane with a new label; an in-place edit of the original has no effect.
