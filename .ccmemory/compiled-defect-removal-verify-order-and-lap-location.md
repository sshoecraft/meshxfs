---
name: compiled-defect-removal-verify-order-and-lap-location
description: Defect-queue removal: apply an approved verify before filing remove --fixed; run harness-defect laps on the rig node at the configuration seen.
metadata:
  type: feedback
tags: [compiled, defects, release-reviewer, verify, harness]
---

# Defect-queue removal: verify order and where the verify lap runs

Assorted-tail group of one note: how four `remove --fixed` proposals were rejected in one sitting (2026-10-23, P20261023-9b6f3f, -1bcf31, -b32dc8, -7bd24f). Source: `removal-needs-applied-verify-and-a-lap-where-the-defect-lives`.

## 1. Order: verify first, then remove

- `tools/defects.py remove --fixed` refuses unless the fix-on batch is `passed` (defects.py:1752).
- Only an approved, applied `verify` sets `passed`: `propose verify` -> release-reviewer -> `defects.py verify --batch B --approval P`.
- A `harness_batch.py verify` run leaves the batch `open`; it does not set `passed`.
- So file the verify proposal FIRST, apply it, then file the removal. Filing both at once wastes a review.
- Also check the record has a `reproducer` field (defects.py:1736 refuses without one). `removal-needs-applied-verify-and-a-lap-where-the-defect-lives`

## 2. Where the verify lap runs

- A harness defect whose failure happens on a rig node is not proven by a host-only lap. Examples: fsx files moved off an mxfs mount to /root; a rejoined victim's loaded module parameters.
- A host-only lap that runs on /dev/shm, or records the argv a node's shell would get, is rejected by the reviewer: the fix never ran on the path the defect lives on (cross-filesystem copy, CAW vs TCP branch, real module load).
- Design the lap to run on the node, on the configuration the failures were seen on.
- File its ledger rows at the configuration it actually ran. A lap that ran MXFS_CONFIG=8/net/mesh/mpath but recorded 2/net/mesh/direct was also cited.
- Host-only laps are fine for defects that live on the host (tools/*.py, criteria/defects logic). `removal-needs-applied-verify-and-a-lap-where-the-defect-lives`
