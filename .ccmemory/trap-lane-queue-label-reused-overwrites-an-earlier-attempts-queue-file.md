---
name: trap-lane-queue-label-reused-overwrites-an-earlier-attempts-queue-file
description: Lane queue files are named by attempt label (a15, a16); a label is reused across sessions, so open('w') on queue_<g>_<label>.txt overwrote a ran lane…
metadata:
  type: feedback
---

Lane queues live at tests/evidence/lanes/queue_<group>_<label>.txt, and the label (a14, a15, a16, a17, w12, ...) is chosen by each session; nothing reserves it. Session 66 (2026-10-24) wrote new queues as queue_g2_a16.txt and queue_host_a16.txt with Python open('w'), and both names already belonged to lanes an earlier session ran (g2_a16_20261024T010135Z, host_a16_20261024T010132Z). The writes silently replaced committed evidence.

Recovered because rig_lane.sh copies its queue into the lane's own directory at start (tests/evidence/lanes/<lane>_<stamp>/queue): the originals were copied back from there and the new queues renamed to an unused label.

How to apply:
- Before writing a queue file, `ls tests/evidence/lanes/ | grep _<label>` and pick a label with no queue file and no lane directory.
- Never write a queue with open('w') or `>` to a name you have not checked; the Write tool refuses an unread existing file, which is the safer path.
- If one is overwritten, its lane directory's `queue` file is the copy that ran.
