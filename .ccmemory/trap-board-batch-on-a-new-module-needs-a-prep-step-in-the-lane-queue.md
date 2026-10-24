---
name: trap-board-batch-on-a-new-module-needs-a-prep-step-in-the-lane-queue
description: harness_batch.py --board laps never prep: after a new build/freeze, a queue must run prep_cluster (with the arm's MXFS_EXTRA_MODARGS) before each bat…
metadata:
  type: feedback
---

`tools/harness_batch.py control|verify ... --board` runs each lap as `MXFS_BATCH=<b> ./run.sh <config> <row>`, a filtered row. A filtered row refuses an unprepped group ("Run './run.sh <config> prep_cluster' first") when the group's marker was written by another module, and harness_batch then stops: "the lap recorded nothing (refused?); stopping", the control closes "0 of 0", and the verify that follows dies on "no measured rate".

Seen 2026-10-24 (session 67): queue_g2b_w12's path_mount_degraded control b20261024-544904 at 2/disk/caw/mpath ran 21 s and recorded nothing, right after a fresh `make modules` + freeze (module BE3695D2590A65F742F9816). The queue had been written a session earlier, when the group was prepped on the old module.

How to apply:
- In every lane queue, put `MXFS_EXTRA_MODARGS=<arm's args> MXFS_FORCE_PREP=1 ./run.sh <config> --group <g> prep_cluster` before a `--board` control. Put a plain prep before the `--board` verify, so the marker matches what each arm loads.
- Lane queue files (tests/evidence/lanes/queue_*.txt) are not in the candidate's frozen list, so a queue not yet started can be fixed after a freeze. Never edit the queue of a running lane: rig_lane.sh runs its own copy.
- A follow-on lane on the same configuration cannot start until the first lane exits (rig_lane.sh holds each configuration it names for its whole life).
