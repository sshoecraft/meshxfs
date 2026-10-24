---
name: compiled-lane-queue-label-reuse-overwrites-evidence
description: Lane queue files are named by session-chosen attempt label; reusing a label with open('w') overwrote committed lane evidence; check labels first.
metadata:
  type: feedback
tags: [compiled, rig, lanes, evidence, trap]
---

Assorted group (one note); topic: lane queue file naming under tests/evidence/lanes/.

Lane queues live at `tests/evidence/lanes/queue_<group>_<label>.txt`. The label (a14, a15, a16, a17, w12, ...) is chosen by each session; nothing reserves it. `trap-lane-queue-label-reused-overwrites-an-earlier-attempts-queue-file`

Failure: session 66 (2026-10-24) wrote new queues as `queue_g2_a16.txt` and `queue_host_a16.txt` with Python `open('w')`. Both names already belonged to lanes an earlier session ran (`g2_a16_20261024T010135Z`, `host_a16_20261024T010132Z`). The writes silently replaced committed evidence. `trap-lane-queue-label-reused-overwrites-an-earlier-attempts-queue-file`

Recovery: `rig_lane.sh` copies its queue into the lane's own directory at start (`tests/evidence/lanes/<lane>_<stamp>/queue`). The originals were copied back from there and the new queues renamed to an unused label. `trap-lane-queue-label-reused-overwrites-an-earlier-attempts-queue-file`

How to apply:
- Before writing a queue file, `ls tests/evidence/lanes/ | grep _<label>` and pick a label with no queue file and no lane directory.
- Never write a queue with `open('w')` or `>` to a name you have not checked; the Write tool refuses an unread existing file, which is the safer path.
- If one is overwritten, its lane directory's `queue` file is the copy that ran. `trap-lane-queue-label-reused-overwrites-an-earlier-attempts-queue-file`
