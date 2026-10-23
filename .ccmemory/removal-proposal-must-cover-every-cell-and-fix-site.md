---
name: removal-proposal-must-cover-every-cell-and-fix-site
description: release-reviewer rejects a remove-fixed whose batches miss any cell's cause, any fix hunk/site, or whose control isn't the candidate's exact source
metadata:
  type: feedback
---

Read from 13 rejected reviews (data/reviews/P2026102{2,3}-*.md, 2026-10-23 sweep). Before proposing `remove-fixed`, check all of these or it comes back REJECT:

- **Every cell is retired as `fixed`.** Each run in the record's `cells` must show THIS cause in its own log. A cell whose log shows another failure (a stall, a mount timeout, a different contract check) must first move to the record that owns it (or a new one) — e.g. D-RELEASE-RUN-BOARD-VERDICT's `release:drbd` cell, D-8NETMESH-FALSE-FRESH's 75 s stall + rejoin timeout, D-PRESTEPS' three presteps runs.
- **Every fix site/hunk is exercised.** A record holding several sites (LUN pool: single-path, multipath and `--also` logins; EUI64: rig.sh hunks plus contract 11b and 13j; BOARD-VERDICT: plus a `check_cells` fix) needs control+verify per site, or a split into records of their own first. The summary text becomes the CHANGELOG line and may state only what was proven.
- **Control = candidate's source with only the fix reverted, hash-proven.** Either in place immediately before a fresh freeze (nothing written in between; `harness_batch.py proof`) or in a copy of the frozen file list. A control on a dev tree, or with any lap input changed after it, fails. A knob control must restore the pre-fix behaviour exactly (FORCE_MS=0 left the fix's unheld workload in place → rejected).
- **The control must reproduce the record's failure with evidence in each failing lap** — laps killed by a bound (rc=124) with no abort/activation line are not the failure.
- **Product (kernel/dlm) records need exposure at the configuration cleared, on the candidate's module** (board-row laps, kernel-log probe). In-process tauth simulations are supporting evidence only unless a `--transfer` is accepted.
- **Every op in a lap is graded against stall_limit_s** (a 31 s last-member unmount inside a PASS lap failed the verify).
- A verify batch must be applied (`defects.py verify` with its own approved proposal) before a removal can use it.
