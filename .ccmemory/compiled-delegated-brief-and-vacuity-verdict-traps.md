---
name: compiled-delegated-brief-and-vacuity-verdict-traps
description: Assorted: every Agent brief carries the no-bash-c line even for scouts; a VACUOUS rule keyed on one node's probe lines hides a stall via the peer
metadata:
  type: feedback
tags: [compiled, feedback, delegation, bash-c, vacuity, jdt]
---

Assorted group (loose tail the clusterer could not fit to one topic): two feedback lessons about what a turn should have known before accepting a delegated or graded result.

## Every delegated brief carries the no-`bash -c` line, read-only scouts included
Source: `feedback-every-delegated-brief-carries-the-no-bash-c-line-even-for-read-only-scouts`

- Failure: a scout briefed only "read-only, no git, no pgrep" built its survey as `timeout 60 bash -c '...for n in ...; do ... done'` piped to a scratchpad file. Claude Code raised "This shell -c script runs rm and could not be checked" and stalled the unattended run. The owner answered "dont do this again".
- The rule already existed (compiled-ccloop-keepgoing-stop-hook-vs-agent-waits, permission prompts section), but the brief left it out, and a subagent sees only its brief.
- How to apply:
  - Every Agent brief that may run shell, read-only scouts, miners and log-sweepers included, carries verbatim: "Do not write shell functions or `bash -c` / `sh -c` programs; run each command as its own plain Bash call, or write a script under the session scratchpad and run that by path."
  - Ask for per-file loops as separate plain commands or a scratchpad script, never an inline multi-line loop.

## A vacuity rule keyed on one node's probe lines hides a stall reached through the peer
Source: `trap-a-vacuity-rule-keyed-on-one-nodes-probe-lines-hides-a-stall-reached-through-the-peer`

- Failure: `join_during_takeover.sh` ARM=stall graded lap jsp191 (lane g2_a19 step 14) `RESULT: VACUOUS stage=no-transition` because B logged no P960-AUTH-TRANSITION line of its own.
- The same lap printed `max_stall_ms=90007` for B's mount: A's join prepare met the held pass on the SB summary lock's page, A's watchdog failed it twice (P960-AUTH-TRANSITION-STALLED, P-JOIN-PREPARE-RETRY), and B sat in its settle gate (P-SETTLE-GATE-REFUSED at 60 s, then P1-AGWAIT) for 86.5 s.
- The vacuity rule overrode three FAILs and the 86.5 s mount went unrecorded for a session; recorded later as D-JOINER-MOUNT-RETRIES-AG0-WITHOUT-BOUND-WHILE-THE-INCUMBENT-CANNOT-JOIN.
- How to apply:
  - Before accepting a VACUOUS or UNMEASURED verdict, read the lap's own timed operations (`max_stall_ms=`, `ms=` lines) and both nodes' logs for the hazard reached by another route; a VACUOUS lap with a timed operation over stall_limit_s is a finding, not nothing.
  - When a vacuity rule names one node's probe lines, check whether the hazard can reach the measured operation through the other node (here the incumbent's stalled prepare held the joiner at its settle gate).
  - When a record's next step says "still does not reach the case", re-read the lap output lines above its RESULT line first.
