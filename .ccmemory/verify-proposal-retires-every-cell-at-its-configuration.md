---
name: verify-proposal-retires-every-cell-at-its-configuration
description: A verify approval retires every cell the record names at that configuration; a cell whose own reason is another failure gets the verify rejected
metadata:
  type: feedback
---

Applying a verify (`tools/defects.py verify`) calls `retire_cells` for every run the record names at the batch's configuration (tools/defects.py:1292-1295), and the release process counts that as a reviewed disposition. So the release-reviewer checks every such cell, not just the batch.

Evidence: P20261023-b45350 (open-EFI verify, 2026-10-23) met all five verify checks and was still REJECTED. One cell, a control lap at 2/net/mesh/direct, was a FAIL "elapsed>360s: the harness overran its bound" after a 207 s pair rebuild. Nothing tied that to the defect, so approving would have marked an unexplained timeout as verified. The fix was a record of its own naming that run, then resubmitting the same batch (nothing re-run). Cost: one ~340K-token review.

Before proposing a verify or a removal:
- List every cell of the record from data/criteria.runs.jsonl: outcome, reason, measured.
- Any cell whose reason is not this record's cause (bound overrun, stall, mount timeout, another check) first goes to a record of its own (`defects.py add --cell`), or its log must prove this cause.
- A removal's scope is every configuration the record reaches. A record left at its fail-closed default (1/any) needs runs at each lock manager, attachment and node count it claims, or a reviewed narrowing first. Code reading does not count (P20261023-2ed8d3 rejected the last-member-unmount removal for this).

Each review costs about 340K tokens, the same whether it approves or rejects, so the check is cheaper than the rejection.
