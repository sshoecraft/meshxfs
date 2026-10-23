---
name: compiled-verify-and-removal-review-cell-coverage
description: A verify retires every cell the record names at that configuration; list all cells and split foreign-cause failures out first, or the review rejects
metadata:
  type: feedback
tags: [compiled, defects, release-reviewer, verify, removal, release-gate]
---

Assorted tail group (a single note the clusterer could not fit to a sibling topic): what the release-reviewer checks before approving a `tools/defects.py verify` or a removal, and what to prepare before proposing either.

## What an approved verify does

- Applying a verify (`tools/defects.py verify`) calls `retire_cells` for every run the record names at the batch's configuration (tools/defects.py:1292-1295), and the release process counts that as a reviewed disposition. So the release-reviewer checks every such cell, not just the batch. `verify-proposal-retires-every-cell-at-its-configuration`

## Evidence: P20261023-b45350 (open-EFI verify, 2026-10-23), REJECTED

- It met all five verify checks and was still REJECTED. `verify-proposal-retires-every-cell-at-its-configuration`
- One cell, a control lap at 2/net/mesh/direct, was a FAIL "elapsed>360s: the harness overran its bound" after a 207 s pair rebuild. Nothing tied that to the defect, so approving would have marked an unexplained timeout as verified. `verify-proposal-retires-every-cell-at-its-configuration`
- The fix was a record of its own naming that run, then resubmitting the same batch (nothing re-run). Cost: one ~340K-token review. `verify-proposal-retires-every-cell-at-its-configuration`

## Before proposing a verify or a removal

- List every cell of the record from data/criteria.runs.jsonl: outcome, reason, measured. `verify-proposal-retires-every-cell-at-its-configuration`
- Any cell whose reason is not this record's cause (bound overrun, stall, mount timeout, another check) first goes to a record of its own (`defects.py add --cell`), or its log must prove this cause. `verify-proposal-retires-every-cell-at-its-configuration`
- A removal's scope is every configuration the record reaches. A record left at its fail-closed default (1/any) needs runs at each lock manager, attachment and node count it claims, or a reviewed narrowing first. Code reading does not count (P20261023-2ed8d3 rejected the last-member-unmount removal for this). `verify-proposal-retires-every-cell-at-its-configuration`

## Cost

- Each review costs about 340K tokens, the same whether it approves or rejects, so the check is cheaper than the rejection. `verify-proposal-retires-every-cell-at-its-configuration`
