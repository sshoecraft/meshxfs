---
name: compiled-harness-batch-board-lane-prep
description: harness_batch --board laps never prep: prep before each batch on a new module; a failing lap leaves the group down; lane queue rules
metadata:
  type: feedback
tags: [compiled, harness_batch, run.sh, lanes, prep_cluster]
---

Kind: assorted (a single trap note; central topic is `tools/harness_batch.py --board` laps and lane queues). Source: `trap-board-batch-on-a-new-module-needs-a-prep-step-in-the-lane-queue`.

## Mechanism
`tools/harness_batch.py control|verify ... --board` runs each lap as `MXFS_BATCH=<b> ./run.sh <config> <row>`, a filtered row. A filtered row refuses an unprepped group ("Run './run.sh <config> prep_cluster' first"). harness_batch then stops with "the lap recorded nothing (refused?); stopping", and the verify that follows dies on "no measured rate". `trap-board-batch-on-a-new-module-needs-a-prep-step-in-the-lane-queue`

## Two ways it bit (2026-10-24, session 67, path_mount_degraded controls, module BE3695D2590A65F742F9816)
1. **New module.** queue_g2b_w12's control b20261024-544904 at 2/disk/caw/mpath recorded nothing in 21 s, right after a fresh `make modules` + freeze. The queue had been written when the group was prepped on the old module.
2. **A failing lap leaves the group down.** g4c_w12's control b20261024-239fb6 at 4/disk/caw/mpath ran 3 FAIL laps (late_stall_ms 35-42 s), then lap 4 was refused. A failing path row leaves the victim unmounted, and a board lap never re-forms the group. Every control of a defect that fails a node-killing row hits this after its first exposed lap. `trap-board-batch-on-a-new-module-needs-a-prep-step-in-the-lane-queue`

## How to apply
- Before a `--board` control, put `MXFS_EXTRA_MODARGS=<arm's args> MXFS_FORCE_PREP=1 ./run.sh <config> --group <g> prep_cluster`. Before the `--board` verify, put a plain prep, so the marker matches what each arm loads.
- For a control whose laps fail on a row that takes a node down, choose one of:
  - declare the batch yourself with `tools/defects.py batch <id> --kind control ... --leaves-cluster`, so run.sh re-forms the group before every lap, then drive it with `harness_batch.py control --batch <b> --board`;
  - or alternate a prep with `harness_batch.py control --batch <b> --board` (it continues the declared batch until a lap is refused). queue_g4c_w12b.txt and queue_g2b_w12c.txt do this.
- Lane queue files (tests/evidence/lanes/queue_*.txt) are not in the candidate's frozen list, so a queue that has not started can be fixed after a freeze. Never edit a running lane's queue: rig_lane.sh runs its own copy.
- A follow-on lane on the same configuration cannot start until the first lane exits, because rig_lane.sh holds each configuration it names for its whole life. Two lanes on overlapping node groups (g4c test7-10 vs g8 test7-14) are not caught by that hold: order them with scripts/lane_after.sh. `trap-board-batch-on-a-new-module-needs-a-prep-step-in-the-lane-queue`
