---
name: trap-a-vacuity-rule-keyed-on-one-nodes-probe-lines-hides-a-stall-reached-through-the-peer
description: A lap's VACUOUS rule that reads only the measured node's own probe lines can hide a real stall reached through the peer (jdt stall arm jsp191)
metadata:
  type: feedback
---

join_during_takeover.sh ARM=stall graded lap jsp191 (lane g2_a19 step 14) `RESULT: VACUOUS stage=no-transition` because B logged no P960-AUTH-TRANSITION line of its own. But the same lap printed `max_stall_ms=90007` for B's mount: A's join prepare met the held pass on the SB summary lock's page, A's watchdog failed it twice (P960-AUTH-TRANSITION-STALLED, P-JOIN-PREPARE-RETRY), and B sat in its settle gate (P-SETTLE-GATE-REFUSED at 60 s, then P1-AGWAIT) for 86.5 s. The vacuity rule overrode three FAILs and the 86.5 s mount went unrecorded for a session, recorded later as D-JOINER-MOUNT-RETRIES-AG0-WITHOUT-BOUND-WHILE-THE-INCUMBENT-CANNOT-JOIN.

How to apply:
- Before accepting a VACUOUS or UNMEASURED verdict, read the lap's own timed operations (max_stall_ms=, ms= lines) and both nodes' logs for the hazard reached by another route; a VACUOUS lap with a timed operation over stall_limit_s is a finding, not nothing.
- When a vacuity rule names one node's probe lines, check whether the hazard can reach the measured operation through the other node (here the incumbent's stalled prepare held the joiner at its settle gate).
- When a record's next step says "still does not reach the case", re-read the lap output lines above its RESULT line first.
