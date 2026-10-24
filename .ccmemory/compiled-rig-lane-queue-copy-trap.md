---
name: compiled-rig-lane-queue-copy-trap
description: Assorted: rig_lane.sh lane queues (running lane uses its own queue copy) and harness_batch --board laps (need prep before each batch; failing lap lea…
metadata:
  type: feedback
tags: [compiled, trap, rig_lane, lanes, harness_batch, run.sh, prep_cluster, proposal, release-reviewer]
---

Assorted group (the articles share no single topic beyond rig lane/batch mechanics): traps in `scripts/rig_lane.sh` lane queue files, and in `tools/harness_batch.py --board` laps that run from those queues. Merged from this article and `compiled-harness-batch-board-lane-prep`.

## Editing a lane queue file does not change a running lane (`trap-editing-a-lane-queue-file-does-not-change-a-running-lane`)
- A session rewrote a pending verify line in `tests/evidence/lanes/queue_g8b_w12b.txt` (adding `HOLD_A_MS=4000`) while the lane was on step 1, and concluded "the verification line changed before step 2 started".
- `scripts/rig_lane.sh:55` copies the queue into the lane directory at start (`cp "$QUEUE" "$OUT/queue"`) and reads only that copy (`:101 done < "$OUT/queue"`). The verification ran with the old line, `HOLD_A_MS` at its default 8000.
- The next session wrote the verify proposal from the edited original and cited `HOLD_A_MS=4000`. The release-reviewer read the lap logs (`hold_a_ms=8000`) and rejected it (P20261024-0801cb, one review spent).

### How to apply
- A running lane's commands are in `tests/evidence/lanes/<lane>_<stamp>/queue`, never the queue file it was started from. Cite that copy, and read each lap log's own header for the parameters that ran, before writing a proposal.
- To change a step that has not run yet, stop the lane at a step boundary and start a new lane with a new label; an in-place edit of the original has no effect.

## Board batch on a new module needs a prep step in the lane queue (`compiled-harness-batch-board-lane-prep`, source note `trap-board-batch-on-a-new-module-needs-a-prep-step-in-the-lane-queue`)
### Mechanism
`tools/harness_batch.py control|verify ... --board` runs each lap as `MXFS_BATCH=<b> ./run.sh <config> <row>`, a filtered row. A filtered row refuses an unprepped group ("Run './run.sh <config> prep_cluster' first"). harness_batch then stops with "the lap recorded nothing (refused?); stopping", and the verify that follows dies on "no measured rate".

### Two ways it bit (2026-10-24, session 67, path_mount_degraded controls, module BE3695D2590A65F742F9816)
1. **New module.** queue_g2b_w12's control b20261024-544904 at 2/disk/caw/mpath recorded nothing in 21 s, right after a fresh `make modules` + freeze. The queue had been written when the group was prepped on the old module.
2. **A failing lap leaves the group down.** g4c_w12's control b20261024-239fb6 at 4/disk/caw/mpath ran 3 FAIL laps (late_stall_ms 35-42 s), then lap 4 was refused. A failing path row leaves the victim unmounted, and a board lap never re-forms the group. Every control of a defect that fails a node-killing row hits this after its first exposed lap.

### How to apply
- Before a `--board` control, put `MXFS_EXTRA_MODARGS=<arm's args> MXFS_FORCE_PREP=1 ./run.sh <config> --group <g> prep_cluster`. Before the `--board` verify, put a plain prep, so the marker matches what each arm loads.
- For a control whose laps fail on a row that takes a node down, choose one of:
  - declare the batch yourself with `tools/defects.py batch <id> --kind control ... --leaves-cluster`, so run.sh re-forms the group before every lap, then drive it with `harness_batch.py control --batch <b> --board`;
  - or alternate a prep with `harness_batch.py control --batch <b> --board` (it continues the declared batch until a lap is refused). queue_g4c_w12b.txt and queue_g2b_w12c.txt do this.
- Lane queue files (tests/evidence/lanes/queue_*.txt) are not in the candidate's frozen list, so a queue that has not started can be fixed after a freeze. Never edit a running lane's queue: rig_lane.sh runs its own copy (see the section above).
- A follow-on lane on the same configuration cannot start until the first lane exits, because rig_lane.sh holds each configuration it names for its whole life. Two lanes on overlapping node groups (g4c test7-10 vs g8 test7-14) are not caught by that hold: order them with scripts/lane_after.sh.
