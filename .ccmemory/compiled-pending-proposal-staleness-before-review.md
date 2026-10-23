---
name: compiled-pending-proposal-staleness-before-review
description: Before sending a pending defects.py proposal to release-reviewer, read the record's latest next and newer reviews; a stale proposal wastes a run.
metadata:
  type: feedback
tags: [compiled, defects, release-reviewer, proposals]
---

Single-note group (kind assorted, tail the clusterer could not fit to a topic): checking a pending `tools/defects.py` proposal before dispatching release-reviewer.

A proposal left `pending` by an earlier session is not necessarily ready for review (`pending-proposal-may-be-stale-read-record-next-first`). Two verify proposals (P20261023-0344fd, P20261023-495519) sat pending while their records' `next` fields had since been updated after rejected removals, saying the very laps those verifies rest on measured nothing at the configuration (host-only laps, no VM, wrong MXFS_CONFIG). Both release-reviewer runs came back REJECT, two agent runs spent for nothing.

**Why:** the reviewer checks the record's own `next`, and a rejection's findings are written there first; a proposal drafted before it does not know.

**How to apply:** before dispatching release-reviewer on a pending proposal, read the last `=====` section of the record's `next` (and any `data/reviews/` file newer than the proposal). If it says the proposal's batch or lap is unfit, do not send it; rework the lap first. `tools/release_blockers.py --pending` lists the pending ones; `tools/defects.py show <id>` gives the `next`.
