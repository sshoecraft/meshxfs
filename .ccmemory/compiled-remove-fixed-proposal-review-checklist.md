---
name: compiled-remove-fixed-proposal-review-checklist
description: release-reviewer REJECT checklist for remove-fixed: every cell's cause, every fix site, hash-proven control, product exposure, stall grading
metadata:
  type: feedback
tags: [compiled, release-reviewer, defects, remove-fixed, verification]
---

Tail group: one note the clusterer could not fit to a topic. It is the release-reviewer's rejection checklist for a `remove-fixed` proposal, read from 13 rejected reviews (`data/reviews/P2026102{2,3}-*.md`, 2026-10-23 sweep) `removal-proposal-must-cover-every-cell-and-fix-site`.

Before proposing `remove-fixed`, check every item below or the proposal comes back REJECT `removal-proposal-must-cover-every-cell-and-fix-site`.

## Every cell is retired as `fixed`

- Each run in the record's `cells` must show THIS cause in its own log.
- A cell whose log shows another failure (a stall, a mount timeout, a different contract check) must first move to the record that owns it, or to a new one. Cases that were rejected for this: D-RELEASE-RUN-BOARD-VERDICT's `release:drbd` cell; D-8NETMESH-FALSE-FRESH's 75 s stall + rejoin timeout; D-PRESTEPS' three presteps runs `removal-proposal-must-cover-every-cell-and-fix-site`.

## Every fix site/hunk is exercised

- A record holding several sites needs control+verify per site, or a split into records of their own first. Multi-site records seen: LUN pool (single-path, multipath and `--also` logins); EUI64 (rig.sh hunks plus contract 11b and 13j); BOARD-VERDICT (plus a `check_cells` fix).
- The summary text becomes the CHANGELOG line and may state only what was proven `removal-proposal-must-cover-every-cell-and-fix-site`.

## The control

- Control = the candidate's source with only the fix reverted, hash-proven. Two accepted forms: in place immediately before a fresh freeze (nothing written in between; `harness_batch.py proof`), or in a copy of the frozen file list.
- A control on a dev tree fails. A control with any lap input changed after it fails.
- A knob control must restore the pre-fix behaviour exactly. `FORCE_MS=0` left the fix's unheld workload in place, so it was rejected.
- The control must reproduce the record's failure with evidence in each failing lap. Laps killed by a bound (rc=124) with no abort/activation line are not the failure `removal-proposal-must-cover-every-cell-and-fix-site`.

## Exposure and per-op grading

- Product (kernel/dlm) records need exposure at the configuration cleared, on the candidate's module (board-row laps, kernel-log probe). In-process tauth simulations are supporting evidence only, unless a `--transfer` is accepted.
- Every op in a lap is graded against `stall_limit_s`. A 31 s last-member unmount inside a PASS lap failed the verify `removal-proposal-must-cover-every-cell-and-fix-site`.

## Ordering

- A verify batch must be applied (`defects.py verify` with its own approved proposal) before a removal can use it `removal-proposal-must-cover-every-cell-and-fix-site`.
